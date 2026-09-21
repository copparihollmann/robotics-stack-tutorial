#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Free-running the unrolled int8 decoder through dec_driver.c, and scoring it.

The graph computes; the DRIVER closes the loop.  What this checks, in order:

    1. the loop closes          token counts match the float reference's, per utterance
    2. it transcribes           the transcripts are printed, not just scored
    3. WER                      int8 encoder + int8 decoder, against the float decoder's 10.60 %

A silent off-by-one in the early exit produces a plausible transcript and a WER that looks like
quantisation, so (1) is checked before (3) is believed.

    python3 model_dec_run.py --n 8 --json model_dec_run_dev.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import struct
import subprocess
import sys
import time

import hashlib

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import moonshine_dec as md  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402

R = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))


def sha(p: str) -> str:
    """sha256 of a file.  A run that cannot be re-derived from its own record is not evidence:
    the 14.401 % baseline this file produced on 2026-09-17 is unreproducible for exactly want of
    the three fields below (L300/MOONSHINE-MODEL), because in.bin was later overwritten and
    nothing said which IR or which binary had built it."""
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=0, help="0 = the whole served set")
    ap.add_argument("--ir", default=os.path.join(R, "out/decint8/ir"))
    ap.add_argument("--exe", default=os.path.join(R, "out/decint8/hostbuild/dec_driver"))
    ap.add_argument("--work", default=os.path.join(R, "out/decint8/run"))
    ap.add_argument("--enc", default=None, help="int8 encoder gen dir; omit for the float encoder")
    # --pro-int8 (Lab B112).  THE PROLOGUE IS IN THE GRAPH, SO THE PACKING CHANGES.
    #
    # Without it the host runs MbCrossPrologue in float and packs twelve [1, 165, 288] kx/vx
    # tensors -- 570,240 of the 577,152 packed bytes.  With it the target computes them, and
    # what the host packs is the encoder's ONE hidden state: 47,520 B, 90.57 % less.
    #
    # It is a DECLARATION, checked against the IR both ways below, because the two packings
    # are the same buffer at different offsets: pack kx/vx into a graph that wants `enc` and
    # every dispatch still runs, on the wrong bytes, and produces plausible tokens.
    ap.add_argument("--pro-int8", dest="pro_int8", action="store_true",
                    help="the IR computes the cross-attention prologue itself: pack the "
                         "encoder hidden state as `enc` instead of twelve float-computed "
                         "kx/vx tensors")
    # --e2e (Lab B114).  THE ENCODER IS IN THE GRAPH TOO, so the packed input is the AUDIO
    # WINDOW and not an encoder hidden state.  There is no `enc` field, nothing to requantise
    # at the encoder/decoder boundary and nothing for --enc to run: the same generated C the
    # board runs takes 64,000 int8 samples in and emits tokens.  Checked against the IR the
    # same way --pro-int8 is, and for the same reason -- the packings are the same buffer at
    # different offsets, so getting it wrong is a transcript rather than an error.
    ap.add_argument("--e2e", action="store_true",
                    help="the IR is encoder + prologue + decoder: pack the int8 AUDIO WINDOW")
    ap.add_argument("--json", default=os.path.join(HERE, "model_dec_run_dev.json"))
    a = ap.parse_args()
    t0 = time.time()
    os.makedirs(a.work, exist_ok=True)
    import model_dec_build as mb
    import model_vocab as mv

    ir = json.load(open(os.path.join(a.ir, "graph.json")))
    pk = {p["name"]: p for p in ir["input"]["packed_inputs"]}
    sc = {n: ir["tensors"][n]["quant"]["scale"] for n in ir["input"]["tensors"]}
    NB, N = ir["input"]["packed_bytes"], len(ir["output"]["tensors"])
    # The IR's own answer, against the flag's claim.  Refused rather than reconciled: a
    # wrongly packed input is not an error at any later stage, it is a different transcript.
    ir_has_enc = "enc" in pk
    # THE AUDIO FIELD: the one packed field that is not an `h<k>` slot.  Read off the IR
    # rather than named, so a graph with a different input name is a refusal and not a
    # mis-packing.
    aud = sorted(n for n in pk if not re.fullmatch(r"h\d+", n))
    if a.e2e:
        if a.enc:
            raise SystemExit("--e2e and --enc are exclusive: the encoder is IN this graph, so "
                             "a second encoder's output would be packed over its own input")
        if a.pro_int8:
            raise SystemExit("--e2e implies the prologue is in the graph as well; --pro-int8 "
                             "names the OTHER packing (an `enc` field) and there is none")
        if len(aud) != 1 or ir_has_enc:
            raise SystemExit("--e2e wants exactly one non-`h` packed field and no `enc`; this "
                             "IR has %s" % (", ".join(aud) or "none"))
        if pk[aud[0]]["size"] != me.N_SAMPLES:
            raise SystemExit("--e2e: packed field %r is %d B, not the %d-sample window"
                             % (aud[0], pk[aud[0]]["size"], me.N_SAMPLES))
    if ir_has_enc != bool(a.pro_int8):
        raise SystemExit(
            "--pro-int8 %s but this IR's packed input %s an `enc` field (%s).  The two "
            "packings are the same buffer at different offsets, so getting this wrong "
            "produces plausible tokens rather than an error."
            % ("was passed" if a.pro_int8 else "was NOT passed",
               "HAS" if ir_has_enc else "has NO", ", ".join(sorted(pk))[:120]))

    hf, tok = mv.load_hf("cpu")
    sd = hf.state_dict()
    emb = sd["model.decoder.embed_tokens.weight"]
    start, eos = hf.config.decoder_start_token_id, hf.config.eos_token_id
    um = md.load_unrolled(md.make_unrolled(N), sd)
    pro = md.load_prologue(md.MbCrossPrologue().eval(), sd)

    corpus = ls.Corpus("dev_clean")
    idx = [i for i in range(len(corpus.ids)) if corpus.lens[i] <= me.N_SAMPLES]
    if a.n:
        idx = idx[: a.n]
    refs = [corpus.texts[i] for i in idx]

    embp = os.path.join(a.work, "emb.f32")
    if not os.path.exists(embp):
        emb.detach().numpy().astype(np.float32).tofile(embp)

    # The encoder half.  --enc runs ModelBlaster's generated int8 encoder and dequantises its
    # output, so that "both halves int8" means both halves, not the decoder alone.
    enc_hs, enc_q = None, None
    if a.enc:
        import hostrun
        eir = json.load(open(os.path.join(os.path.dirname(a.enc.rstrip("/")), "ir", "graph.json")))
        emeta = eir["tensors"][eir["input"]["tensor"]]
        es_in = emeta["quant"]["scale"]
        eo = eir["tensors"][eir["output"]["tensors"][0]]
        es_out, (eT, eD) = eo["quant"]["scale"], [int(v) for v in eo["shape"][-2:]]
        xs = np.stack([np.pad(corpus.wav(i), (0, me.N_SAMPLES - len(corpus.wav(i))))
                       for i in idx]).astype(np.float32)
        # THE INPUT GRID IS THE IR'S, NOT ALWAYS int8.  q16_fidelity.py:151 has had this case
        # since the q16 candidates existed; this file never learned it, so `--enc` on any
        # int16-input graph wrote half the samples and died three stages later on an output
        # length ("out0.bin: 2233440 bytes, expected 4514400" -- Lab B111 on candidate R, whose
        # input scale is 1.6818e-05, a number that only makes sense over +/-32767).  The int8
        # branch below is the original line, so every existing record reproduces unchanged.
        if emeta.get("dtype") == "i16":
            xq = np.clip(np.rint(xs.astype(np.float64) / es_in),
                         -32768, 32767).astype(np.int16)
        else:
            xq = np.clip(np.rint(xs / es_in), -127, 127).astype(np.int8)
        eexe = hostrun.build(a.enc, os.path.join(a.work, "encbuild"))
        yq = q16f.run_parallel(eexe, xq, eT * eD, os.path.join(a.work, "encbatch"), 8)
        enc_hs = [torch.from_numpy(y.astype(np.float32) * np.float32(es_out)).reshape(1, eT, eD)
                  for y in yq]
        enc_q = yq
        print(f"int8 encoder: {len(enc_hs)} hidden states, {eT} x {eD}")

    X, float_toks = [], []
    handoff_err = None          # see the identity check below
    with torch.no_grad():
        for jj, i in enumerate(idx):
            w = np.pad(corpus.wav(i), (0, me.N_SAMPLES - len(corpus.wav(i)))).astype(np.float32)
            enc = enc_hs[jj] if enc_hs is not None else \
                hf.model.encoder(torch.from_numpy(w[None, :])).last_hidden_state
            hs, kx, vx, ft = mb.float_rollout(um, emb, enc, pro, start, eos, N)
            float_toks.append(ft)
            buf = np.zeros(NB, dtype=np.int8)
            if a.e2e:
                # THE WHOLE CHAIN IS THE TARGET'S.  `w` is the same padded float window the
                # encoder bank quantises (model_dec_run's --enc path, three lines up), at the
                # merged graph's own `x` scale.
                pairs = [("h0", hs[0]), (aud[0], torch.from_numpy(w))]
            elif a.pro_int8:
                # ONE tensor instead of twelve.  kx/vx are still computed above, in float,
                # for the float reference rollout -- they are simply not packed.
                pairs = [("h0", hs[0]), ("enc", enc)]
            else:
                pairs = [("h0", hs[0])] + [(f"kx{j}", kx[j]) for j in range(md.LAYERS)] \
                                        + [(f"vx{j}", vx[j]) for j in range(md.LAYERS)]
            for n, t in pairs:
                q = np.clip(np.rint(t.reshape(-1).numpy() / sc[n]), -127, 127).astype(np.int8)
                buf[pk[n]["byte_offset"]: pk[n]["byte_offset"] + q.size] = q
                # THE HANDOFF IS A COPY, AND THIS IS WHERE THAT IS CHECKED RATHER THAN
                # ASSUMED.  b112_pro_lower.py pins the decoder's `enc` scale to the ENCODER
                # graph's own output scale, so requantising the dequantised encoder output
                # has to return the encoder's own bytes.  If it ever does not, the two models
                # disagree about the boundary and every token after it is measured through a
                # silent requantisation.
                if n == "enc" and enc_q is not None:
                    d = int(np.abs(q.astype(np.int64)
                                   - enc_q[jj].reshape(-1).astype(np.int64)).max())
                    handoff_err = d if handoff_err is None else max(handoff_err, d)
            X.append(buf)
    inp = os.path.join(a.work, "in.bin")
    np.stack(X).tofile(inp)
    outp = os.path.join(a.work, "tok.bin")
    subprocess.run([a.exe, inp, embp, outp, str(len(X))], check=True)

    raw = np.fromfile(outp, dtype=np.int32).reshape(len(X), N + 1)
    got = [list(raw[j, 1:1 + int(raw[j, 0])]) for j in range(len(X))]

    # (1) the loop closes: token counts against the float reference
    same_n = sum(len(g) == len(f) for g, f in zip(got, float_toks))
    exact = sum(g == f for g, f in zip(got, float_toks))
    print(f"loop check: token count matches float on {same_n}/{len(got)}; "
          f"sequence exact on {exact}/{len(got)}")
    for j in range(min(4, len(got))):
        print(f"  [{j}] float {len(float_toks[j]):2d} tok  {tok.decode(float_toks[j], skip_special_tokens=True)!r}")
        print(f"      int8  {len(got[j]):2d} tok  {tok.decode(got[j], skip_special_tokens=True)!r}")
    hyp = [tok.decode(g, skip_special_tokens=True) for g in got]
    flt = [tok.decode(f, skip_special_tokens=True) for f in float_toks]
    e_c, nw = q16f.utt_errors(refs, hyp)
    e_f, _ = q16f.utt_errors(refs, flt)
    rec = {"what": "int8 unrolled decoder, free-running through dec_driver.c",
           "set": {"name": "dev_clean <= 4 s", "utterances": len(idx),
                   "words": int(nw.sum()), "speakers": len({corpus.speakers[i] for i in idx})},
           "encoder": ("IN THE GRAPH (--e2e): the target computes it from the audio window"
                       if a.e2e else "HF float" if not a.enc else a.enc), "n_steps": N,
           "e2e": ({"audio_field": aud[0], "audio_bytes": pk[aud[0]]["size"],
                    "audio_scale": sc[aud[0]],
                    "packed_bytes_per_utterance": NB,
                    "fed_from_the_host": "the int8 audio window and the start token's "
                                         "embedding row -- nothing else",
                    "accuracy_claim": "NONE.  Timing and identity only.  The per-tensor "
                                      "prologue's accuracy on board-computed features is "
                                      "still unmeasured (B112), and the wer_* fields below "
                                      "are the harness working, not a licence."}
                   if a.e2e else None), "n_utts": len(idx),
           # PROVENANCE.  Enough to re-derive this number, or to say which input it was not.
           "provenance": {"ir": os.path.abspath(a.ir),
                          "ir_graph_sha256": sha(os.path.join(a.ir, "graph.json")),
                          "exe": os.path.abspath(a.exe), "exe_sha256": sha(a.exe),
                          "input_bin": os.path.abspath(inp), "input_sha256": sha(inp),
                          "input_bytes": os.path.getsize(inp),
                          "emb_f32_sha256": sha(embp),
                          "utterances": len(X), "packed_bytes_per_utterance": NB},
           "loop": {"token_count_matches_float": same_n, "sequence_exact": exact,
                    "mean_steps_int8": float(np.mean([len(g) for g in got])),
                    "mean_steps_float": float(np.mean([len(f) for f in float_toks]))},
           # THE PROLOGUE BLOCK.  Present only when --pro-int8, and it says in the record
           # itself that the WER beside it is not a prologue accuracy result: the twelve
           # weights are PER-TENSOR (the engine has no _pc linear kernel) and their scales
           # are derived, provisional and downstream of the encoder's calibration.
           **({"prologue": {
               "where": "IN THE GRAPH -- the target computes kx/vx from `enc`",
               "weights": "int8 PER-TENSOR, max-abs/127",
               "packed_bytes_per_utterance": NB,
               "encoder_handoff_max_abs_err": handoff_err,
               "encoder_handoff_meaning":
                   "0 means the decoder's packed `enc` field is the encoder's own int8 "
                   "output bytes, unchanged -- no requantisation between the two models.  "
                   "None means --enc was not given, so there was nothing to compare.",
               "accuracy_claim": "NONE.  The accuracy of a per-tensor prologue on "
                                 "board-computed features is unknown and unmeasured.  The "
                                 "wer_* fields below are the harness working, not a "
                                 "licence, and the three published prologue figures are "
                                 "per-channel on HF float features and do not apply.",
              }} if a.pro_int8 else {}),
           "wer_int8_decoder": float(e_c.sum() / nw.sum()),
           "wer_float_decoder": float(e_f.sum() / nw.sum()),
           "minus_float": q16f.paired_bootstrap(e_c, e_f, nw),
           "elapsed_s": round(time.time() - t0, 1)}
    print(f"WER int8 decoder {rec['wer_int8_decoder']*100:.2f} %   "
          f"float decoder {rec['wer_float_decoder']*100:.2f} %   "
          f"delta {rec['minus_float']['delta_wer']*100:+.2f} "
          f"[{rec['minus_float']['ci95'][0]*100:+.2f}, {rec['minus_float']['ci95'][1]*100:+.2f}]")
    json.dump(rec, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({rec['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
