#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The static lm_head prune re-measured on the INT8 path, and the pruned int8 checkpoint.

model_vocab.py measured static pruning on the FLOAT model (HF encoder, HF decoder, float
argmax).  The board model is int8: both halves are ModelBlaster's generated C, the decoder's
logits are an int8 tensor with one scale per step, and the argmax the driver takes is over
int8 CODES with a lowest-index tie break.  Coarse codes tie; ties are where a prune can change
an answer that the float model would never have changed.  So the float delta is not the board's
delta and has to be re-measured here.

WHAT MAKES MASKING THE ARGMAX EXACTLY EQUAL TO A PRUNED CHECKPOINT
-----------------------------------------------------------------
lm_head is a per-tensor symmetric int8 linear: s_w = max|W| / 127 over the whole matrix, and the
row that attains max|W| is ROW 1 (`<s>`, the decoder start token), which every kept set contains
by construction.  So a kept set's s_w is the unpruned s_w, W_q[S] is a bit-identical row subset,
and -- holding the per-step output scale s_out fixed as well, which is always legal because the
pruned logits are a subset of the same values and cannot newly saturate -- every kept row's int8
logit code is bit-identical to the unpruned model's.  Restricting the argmax to S therefore IS
the pruned model, exactly, and the pruned checkpoint needs no recalibration pass.

THE TIED EMBEDDING
------------------
lm_head.weight IS model.decoder.embed_tokens.weight (one tensor, `tied ptr` checked below).  In
the deployed decoder the two roles are split in representation -- the graph holds int8 lm_head
weights, the driver holds a float32 embedding table it indexes by the argmax -- but not in
content: pruning a row removes it from both.  The closure condition is therefore

    { rows the pruned model can EMBED } must contain { start } U { rows it can EMIT } = {1} U S

which holds because row 1 is always kept, and decoding still terminates because row 2 (</s>) is
always kept.  The driver refuses a mask without EOS rather than running to N_STEPS in silence.

Build the driver first -- dec_driver_mask.c, against a COPY of the generated decoder (copy it,
do not build in out/decint8/: another workstream owns that tree, and a snapshot is also what
makes the measurement quotable):

    GEN=$SNAP/gen_nl; MB=fpga/pynq-z2/modelblaster; SW=fpga/pynq-z2/sw
    cc -O0 -c -w -I$GEN $GEN/weights.c -o weights.o
    cc -O2 -w -std=gnu11 -ffp-contract=off -DMB_PEXT_HW=0 -I$MB/check/shim -I$GEN -I$SW \
       dec_driver_mask.c $GEN/model.c $GEN/kernels.c $GEN/buffers.c $GEN/test_io.S \
       weights.o -o dec_driver_mask -lm

    python3 model_vocab_int8.py --sets dev test --keep 16384 11000 \
        --exe ./dec_driver_mask --ir $SNAP/ir --work $WORK --json model_vocab_int8.json --ckpt 11000
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import librispeech_sets as ls  # noqa: E402
import moonshine_dec as md  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402

R = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
SPECIAL = (0, 1, 2)
BYTE_FALLBACK = tuple(range(3, 259))


def sha(p: str) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def keep_mask(cnt: np.ndarray, m: int, V: int) -> np.ndarray:
    """model_vocab.py's rule, verbatim: the rows the float model emits on train-clean-100,
    most frequent first (stable, so zero-count rows fall in index order), plus the specials and
    the 256 byte-fallback rows."""
    order = np.argsort(-cnt, kind="stable")
    k = np.zeros(V, dtype=bool)
    k[order[:m]] = True
    for s in list(SPECIAL) + list(BYTE_FALLBACK):
        k[s] = True
    return k


def build_inputs(setname, ir, encgen, work, jobs=8, n=0, jitter=0.0, tag=""):
    """The decoder graph's packed input for every utterance of a set: h0 (the start embedding)
    and the cross-attention K/V the float prologue produces from the INT8 encoder's output.

    This is model_dec_run.py's construction with its float 24-step rollout dropped -- that
    rollout only produced a float token reference, and nothing here is scored against it."""
    import model_vocab as mv
    pk = {p["name"]: p for p in ir["input"]["packed_inputs"]}
    sc = {n: ir["tensors"][n]["quant"]["scale"] for n in ir["input"]["tensors"]}
    NB = ir["input"]["packed_bytes"]
    hf, tok = mv.load_hf("cpu")
    sd = hf.state_dict()
    emb = sd["model.decoder.embed_tokens.weight"]
    start = hf.config.decoder_start_token_id
    pro = md.load_prologue(md.MbCrossPrologue().eval(), sd)

    corpus, idx = ls.tune_set() if setname == "dev" else ls.eval_set()
    if n:
        idx = idx[:n]
    refs = [corpus.texts[i] for i in idx]

    import hostrun
    eir = json.load(open(os.path.join(os.path.dirname(encgen.rstrip("/")), "ir", "graph.json")))
    es_in = eir["tensors"][eir["input"]["tensor"]]["quant"]["scale"]
    eo = eir["tensors"][eir["output"]["tensors"][0]]
    es_out, (eT, eD) = eo["quant"]["scale"], [int(v) for v in eo["shape"][-2:]]
    xs = np.stack([np.pad(corpus.wav(i), (0, me.N_SAMPLES - len(corpus.wav(i)))) for i in idx]
                  ).astype(np.float32)
    xq = np.clip(np.rint(xs / es_in), -127, 127).astype(np.int8)
    eexe = hostrun.build(encgen, os.path.join(work, "encbuild"))
    yq = q16f.run_parallel(eexe, xq, eT * eD, os.path.join(work, "encbatch"), jobs)

    X = []
    with torch.no_grad():
        for j in range(len(idx)):
            e = yq[j].astype(np.float32) * np.float32(es_out)
            if jitter:
                # A SECOND DRAW, not noise for its own sake.  The decoder's cross-attention K/V
                # are quantised to int8 at ~0.5 % of full scale, so a relative perturbation of
                # 1e-6 on the encoder's hidden state flips of order 100 of an utterance's 570,240
                # codes by one step, and greedy decoding amplifies that.  Running the same
                # comparison on a perturbed draw says whether a measured delta survives the
                # chaos or is an artefact of one draw.
                g = np.random.default_rng(1000 + j)
                e = e * (1.0 + jitter * g.standard_normal(e.shape).astype(np.float32))
            enc = torch.from_numpy(e).reshape(1, eT, eD)
            kxvx = pro(enc)
            kx, vx = kxvx[:md.LAYERS], kxvx[md.LAYERS:]
            buf = np.zeros(NB, dtype=np.int8)
            pairs = [("h0", emb[start].view(1, 1, md.D))] \
                + [(f"kx{i}", kx[i]) for i in range(md.LAYERS)] \
                + [(f"vx{i}", vx[i]) for i in range(md.LAYERS)]
            for n, t in pairs:
                q = np.clip(np.rint(t.reshape(-1).numpy() / sc[n]), -127, 127).astype(np.int8)
                buf[pk[n]["byte_offset"]: pk[n]["byte_offset"] + q.size] = q
            X.append(buf)
    inp = os.path.join(work, f"in_{setname}{tag}.bin")
    np.stack(X).tofile(inp)
    return inp, len(idx), refs, tok


def decode(exe, inp, embp, work, tag, n_utt, n_steps, maskp=None):
    outp = os.path.join(work, f"tok_{tag}.bin")
    statp = os.path.join(work, f"stat_{tag}.txt")
    cmd = [exe, inp, embp, outp, str(n_utt), maskp or "-", statp]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"driver failed for {tag}: {r.stderr.strip()}")
    stat = dict(l.split() for l in open(statp).read().strip().splitlines())
    stat = {k: int(v) for k, v in stat.items()}
    raw = np.fromfile(outp, dtype=np.int32).reshape(n_utt, n_steps + 1)
    toks = [list(raw[j, 1:1 + int(raw[j, 0])]) for j in range(n_utt)]
    return toks, stat


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", nargs="+", default=["dev", "test"], choices=("dev", "test"))
    ap.add_argument("--keep", type=int, nargs="+", default=[16384, 11000])
    ap.add_argument("--exe", required=True)
    ap.add_argument("--ir", required=True)
    ap.add_argument("--enc", default=os.path.join(R, "out/qatu_long/gen_nl"))
    ap.add_argument("--counts", default=os.path.join(R, "out/moonshine/librispeech/model_train_row_counts.npy"))
    ap.add_argument("--jitter", type=float, default=0.0,
                    help="relative perturbation of the encoder hidden state: a SECOND DRAW "
                         "of the same operating point, to separate the prune's delta from "
                         "the int8 decoder's sensitivity to its own input")
    ap.add_argument("--n", type=int, default=0, help="first n utterances (0 = whole set); a subset is a SMOKE TEST, not a report")
    ap.add_argument("--work", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--ckpt", default=None, help="write the pruned int8 checkpoint for this V")
    a = ap.parse_args()
    t0 = time.time()
    os.makedirs(a.work, exist_ok=True)
    torch.set_grad_enabled(False)

    ir = json.load(open(os.path.join(a.ir, "graph.json")))
    W = np.load(os.path.join(a.ir, "weights.npz"))["lm_head.weight_q"]
    V, D = W.shape
    N_STEPS = len(ir["output"]["tensors"])

    import model_vocab as mv
    hf, tok = mv.load_hf("cpu")
    start, eos = hf.config.decoder_start_token_id, hf.config.eos_token_id
    Wf = hf.proj_out.weight.detach().float().numpy()
    tied = hf.proj_out.weight.data_ptr() == hf.model.decoder.embed_tokens.weight.data_ptr()
    s_w = float(np.abs(Wf).max()) / 127.0
    max_row = int(np.abs(Wf).max(axis=1).argmax())

    cnt = np.load(a.counts)
    out = {"what": __doc__.split("\n")[0],
           "ir": a.ir, "ir_graph_sha256": sha(os.path.join(a.ir, "graph.json")),
           "ir_weights_sha256": sha(os.path.join(a.ir, "weights.npz")),
           "exe": a.exe, "encoder_gen": a.enc,
           "vocab": V, "hidden": D, "n_steps": N_STEPS,
           "lm_head": {"tied_to_embed_tokens": bool(tied),
                       "weight_scale_s_w": s_w,
                       "row_attaining_max_abs_w": max_row,
                       "start_token": int(start), "eos_token": int(eos),
                       "bias_all_zero": bool((np.load(os.path.join(a.ir, "weights.npz"))["lm_head.bias_q"] == 0).all()),
                       "output_scale_per_step": [ir["tensors"]["lm_head" if k == 0 else f"lm_head_{k}"]["quant"]["scale"]
                                                 for k in range(N_STEPS)]},
           "kept_set_selection": {
               "source": "train",
               "rule": "rows the float model EMITS on LibriSpeech train-clean-100 "
                       "(model_trainset.py --emit), most frequent first; disjoint from dev-clean "
                       "and test-clean -- model_vocab.py's rule, verbatim",
               "always_kept": "<unk>/<s>/</s> + the 256 <0xNN> byte-fallback rows",
               "rows_emitted_by_the_source": int((cnt > 0).sum()),
               "source_tokens": int(cnt.sum())},
           "sets": {}, "jitter": None}

    masks = {}
    for m in a.keep:
        k = keep_mask(cnt, m, V)
        assert k[start] and k[eos], "start/eos must be kept"
        mp = os.path.join(a.work, f"mask_{m}.u8")
        k.astype(np.uint8).tofile(mp)
        masks[m] = (k, mp)
        out.setdefault("keep_sets", {})[str(m)] = {
            "V_kept": int(k.sum()),
            "max_abs_w_over_kept": float(np.abs(Wf[k]).max()),
            "s_w_unchanged": bool(np.abs(Wf[k]).max() == np.abs(Wf).max()),
            "start_kept": bool(k[start]), "eos_kept": bool(k[eos]),
            "rows_kept_in_ascending_id_order": True}

    embp = os.path.join(a.work, "emb.f32")
    if not os.path.exists(embp):
        hf.state_dict()["model.decoder.embed_tokens.weight"].numpy().astype(np.float32).tofile(embp)

    out["jitter"] = a.jitter or None
    for sname in a.sets:
        inp, n_utt, refs, _ = build_inputs(sname, ir, a.enc, a.work, n=a.n, jitter=a.jitter,
                                           tag=("_j%g" % a.jitter) if a.jitter else "")
        print(f"[{sname}] {n_utt} utterances, input {inp}  ({time.time()-t0:.0f} s)", flush=True)
        rec = {"utterances": n_utt, "whole_set": not a.n, "words": int(sum(len(r.split()) for r in refs)), "variants": {}}

        jt = ("_j%g" % a.jitter) if a.jitter else ""
        base_toks, base_stat = decode(a.exe, inp, embp, a.work, f"{sname}{jt}_base", n_utt, N_STEPS)
        base_hyp = [tok.decode(t, skip_special_tokens=True) for t in base_toks]
        e_b, nw = q16f.utt_errors(refs, base_hyp)

        # THE INSTRUMENT GATE.  A WER computed over nothing must not look like a good one.
        def gate(stat, hyps, e, n):
            why = []
            if stat["utts"] != n_utt:
                why.append(f"driver decoded {stat['utts']} of {n_utt} utterances")
            if stat["compared_steps"] == 0:
                why.append("no argmax was ever taken: nothing was compared")
            if int(n.sum()) == 0:
                why.append("zero reference words")
            if sum(len(h.strip()) > 0 for h in hyps) == 0:
                why.append("every hypothesis is empty")
            g = {"meaning": "compared" if not why else "not_compared", "why": why or None,
                 "utterances_decoded": stat["utts"], "argmax_steps": stat["compared_steps"],
                 "non_empty_hypotheses": int(sum(len(h.strip()) > 0 for h in hyps))}
            # 438eb27's rule, applied to a WER: a number computed over nothing must not be
            # indistinguishable from a good one.  Refuse rather than print it.
            if g["meaning"] != "compared":
                raise SystemExit("REFUSING to report a WER: " + "; ".join(why))
            return g

        rec["baseline"] = {
            "V_kept": V, "wer_vs_reference": float(e_b.sum() / nw.sum()),
            "errors": int(e_b.sum()), "words": int(nw.sum()),
            "mean_steps": float(np.mean([len(t) for t in base_toks])),
            "gate": gate(base_stat, base_hyp, e_b, nw)}
        print(f"  baseline V={V}  WER {rec['baseline']['wer_vs_reference']*100:.3f} %  "
              f"({rec['baseline']['gate']['meaning']}, {base_stat['compared_steps']} argmax steps)",
              flush=True)

        for m in a.keep:
            k, mp = masks[m]
            toks, stat = decode(a.exe, inp, embp, a.work, f"{sname}{jt}_{m}", n_utt, N_STEPS, mp)
            hyp = [tok.decode(t, skip_special_tokens=True) for t in toks]
            e_c, nw2 = q16f.utt_errors(refs, hyp)
            assert (nw2 == nw).all()
            g = gate(stat, hyp, e_c, nw2)
            # every emitted row must be embeddable on the next step: the closure check, run
            # on what was actually emitted rather than asserted from the construction
            emitted = {t for r in toks for t in r}
            rec["variants"][str(m)] = {
                "V_kept": int(k.sum()),
                "wer_vs_reference": float(e_c.sum() / nw2.sum()),
                "errors": int(e_c.sum()), "words": int(nw2.sum()),
                "mean_steps": float(np.mean([len(t) for t in toks])),
                "identical_sequences_to_baseline": int(sum(g_ == b_ for g_, b_ in zip(toks, base_toks))),
                "utterances_changed": int(sum(g_ != b_ for g_, b_ in zip(toks, base_toks))),
                "argmax_redirected_steps": stat["argmax_changed"],
                "emitted_rows_all_kept": bool(all(k[t] for t in emitted)),
                "emitted_rows_all_embeddable": bool(all(k[t] for t in emitted) and k[start]),
                "minus_int8_baseline": q16f.paired_bootstrap(e_c, e_b, nw),
                "gate": g}
            v = rec["variants"][str(m)]
            print(f"  V={m:6d}  WER {v['wer_vs_reference']*100:.3f} %  "
                  f"delta {v['minus_int8_baseline']['delta_wer']*100:+.3f} pp "
                  f"[{v['minus_int8_baseline']['ci95'][0]*100:+.3f}, "
                  f"{v['minus_int8_baseline']['ci95'][1]*100:+.3f}]  "
                  f"{v['utterances_changed']} utterances changed, "
                  f"{v['argmax_redirected_steps']} argmax steps redirected "
                  f"({g['meaning']})", flush=True)
        out["sets"][sname] = rec
        json.dump(out, open(a.json, "w"), indent=1)

    if a.ckpt:
        m = a.keep[0] if a.ckpt == "auto" else int(a.ckpt)
        k, _ = masks[m]
        rows = np.flatnonzero(k).astype(np.int32)          # ASCENDING: preserves the tie break
        Wp = W[rows]
        embf = hf.state_dict()["model.decoder.embed_tokens.weight"].numpy().astype(np.float32)[rows]
        p = os.path.join(a.work, f"lm_head_pruned_V{m}.npz")
        # embed_tokens_f32 IS the float lm_head: the tensor is tied, so one array serves both
        # the driver's embedding table and any re-extraction of the pruned float model.
        np.savez(p, lm_head_weight_q=Wp, row_ids=rows,
                 embed_tokens_f32=embf,
                 s_w=np.float64(s_w),
                 lm_head_output_scale_per_step=np.asarray(
                     [ir["tensors"]["lm_head" if k == 0 else f"lm_head_{k}"]["quant"]["scale"]
                      for k in range(N_STEPS)], dtype=np.float64),
                 eos_compact=np.int32(int(np.searchsorted(rows, eos))),
                 start_compact=np.int32(int(np.searchsorted(rows, start))))
        out["checkpoint"] = {
            "path": p, "V": int(k.sum()), "K": int(D),
            "lm_head_weight_q_bytes": int(Wp.nbytes),
            "embed_tokens_f32_bytes": int(embf.nbytes),
            "bit_identical_row_subset": bool((Wp == W[rows]).all()),
            "rows_ascending": bool((np.diff(rows) > 0).all()),
            "eos_compact_index": int(np.searchsorted(rows, eos)),
            "start_compact_index": int(np.searchsorted(rows, start)),
            "s_w": s_w, "s_w_unchanged_from_the_unpruned_model": True,
            "output_scales_unchanged": True,
            "row_order": "ASCENDING original token id -- the driver breaks argmax ties by "
                         "lowest index, so a frequency-ordered compaction would change "
                         "which row wins a tie and would not be this measurement's model",
            "embed_tokens_f32_is_the_float_lm_head": True,
            "sha256": sha(p)}
    out["elapsed_s"] = round(time.time() - t0, 1)
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({out['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
