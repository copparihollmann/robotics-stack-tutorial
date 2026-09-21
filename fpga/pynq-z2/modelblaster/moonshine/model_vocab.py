#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""How much of Moonshine Tiny's 32,768-row lm_head an English demo actually uses, and what the
ways of not fetching the rest cost in accuracy.

lm_head is 9,961,472 of the 19,988,480 bytes the decoder re-reads per token (model_cost.json:
49.8 %, 76.3 ms of a 343.4 ms token).  It is TIED to model.decoder.embed_tokens, so it is also
34.8 % of the checkpoint's 27.09 M parameters.  This file measures four ways to stop fetching
all of it, on the pinned LibriSpeech sets (librispeech_sets.py):

  static prune   keep V' rows, mask the rest.  APPROXIMATE: a masked row can never be emitted.
                 Selected on dev-clean, reported once on test-clean.
  norm bound     keep a table of per-row |w_v| (int16, 64 kB), visit rows in descending |w_v|
                 and stop when |h| * |w_v| <= the best score so far.  EXACT top-1, but the rows
                 fetched depend on the input, so what is measured is the DISTRIBUTION.
  cluster, open  k-means the rows, score the C centroids, fetch only the best cluster(s).
                 APPROXIMATE; measured as top-1 agreement against the exact argmax.
  cluster, bound the same clusters with a radius bound, opened in bound order until the bound
                 falls below the best score.  EXACT top-1; again a distribution.

Each utterance is the 4.0 s window moonshine_enc.window() builds, the encoder is HF float (the
port is checked against it by moonshine_enc.py --check-hf) and decoding is greedy, 40 new
tokens, exactly as fq.Decoder does, so the WERs are comparable with q16_fidelity_*.json.
Intervals are paired bootstrap over utterances, as fq/q16_fidelity do.

    PYTHONPATH=$MOONSHINE_DIR/pylib python3 model_vocab.py --sets dev test --json model_vocab.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402

MAX_NEW = 40
SPECIAL = (0, 1, 2)          # <unk>, <s>, </s>


def load_hf(dev):
    from transformers import MoonshineForConditionalGeneration, PreTrainedTokenizerFast
    m = MoonshineForConditionalGeneration.from_pretrained(str(me.moonshine_dir())).eval().to(dev)
    t = PreTrainedTokenizerFast(tokenizer_file=os.path.join(str(me.moonshine_dir()), "tokenizer.json"))
    return m, t


@torch.no_grad()
def decode_set(model, tok, corpus, idx, dev, batch=32, keep_mask=None, num_beams=1,
               max_new=MAX_NEW, capture_h=False):
    """Greedy (or beam) decode of a set.  Returns texts, per-utterance id lists, and -- for
    greedy with capture_h -- the hidden state fed to lm_head at every step."""
    texts, ids_out, hs = [], [], []
    proc = None
    if keep_mask is not None:
        from transformers import LogitsProcessorList, LogitsProcessor
        km = torch.as_tensor(keep_mask, device=dev, dtype=torch.bool)

        class KeepOnly(LogitsProcessor):
            def __call__(self, input_ids, scores):
                return scores.masked_fill(~km, torch.finfo(scores.dtype).min)
        proc = LogitsProcessorList([KeepOnly()])
    for i in range(0, len(idx), batch):
        chunk = idx[i:i + batch]
        x = np.stack([me.window(corpus.wav(j)) for j in chunk]).astype(np.float32)
        xv = torch.from_numpy(x).to(dev)
        enc = model.model.encoder(xv)
        gen = model.generate(encoder_outputs=enc, max_new_tokens=max_new, do_sample=False,
                             num_beams=num_beams, logits_processor=proc)
        texts += [tok.decode(r, skip_special_tokens=True) for r in gen]
        ids_out += [[int(v) for v in r] for r in gen]
        if capture_h and num_beams == 1:
            # re-run the decoder teacher-forced on the generated prefix: the last hidden state
            # at position p is exactly the vector lm_head saw when it chose token p+1
            out = model.model.decoder(input_ids=gen[:, :-1],
                                      encoder_hidden_states=enc.last_hidden_state)
            h = out.last_hidden_state                                   # [B, L, 288]
            for b, r in enumerate(gen):
                n = int((r != model.config.eos_token_id).sum())         # steps before EOS
                n = min(max(n, 1), h.shape[1])
                hs.append(h[b, :n].float().cpu().numpy())
    return texts, ids_out, hs


def image_bytes(V: int, K: int = 288) -> int:
    import engine_traffic as et
    return et.wimage_plan(V, K)["bytes"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", nargs="+", default=["dev"], choices=("dev", "test"))
    ap.add_argument("--json", required=True)
    ap.add_argument("--n", type=int, default=0, help="evenly spaced subset (0 = whole set)")
    ap.add_argument("--keep-sizes", type=int, nargs="+",
                    default=[32768, 16384, 8192, 4096, 2048, 1024, 512, 256])
    ap.add_argument("--clusters", type=int, nargs="+", default=[64, 256, 1024])
    ap.add_argument("--source", choices=("dev", "train"), default="dev",
                    help="where the kept set is chosen: dev-clean emissions, or (the honest "
                         "one) the rows the model emits on train-clean-100, which is disjoint "
                         "from both reported sets")
    ap.add_argument("--train-counts", default=None,
                    help="model_train_row_counts.npy from model_trainset.py --emit")
    ap.add_argument("--byte-fallback", action="store_true",
                    help="always keep the 256 <0xNN> byte rows, so a word outside the kept set "
                         "can still be spelled out instead of being replaced")
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = fq.device()
    model, tok = load_hf(dev)
    W = model.proj_out.weight.detach().float()                    # [32768, 288]
    V, D = W.shape

    out = {"what": __doc__.split("\n")[0], "vocab": V, "hidden": D,
           "lm_head_tied_to_embed_tokens": True,
           "window_s": me.WINDOW_S, "max_new_tokens": MAX_NEW, "sets": {}}

    # ---- what the tokenizer's rows even are ------------------------------------------------
    tj = json.load(open(os.path.join(str(me.moonshine_dir()), "tokenizer.json")))
    bpe = tj["model"]["vocab"]
    added = {int(x["id"]): x["content"] for x in tj.get("added_tokens", [])}
    ascii_ok = {i for s, i in bpe.items() if all(ord(c) < 128 or c == "▁" for c in s)}
    out["row_inventory"] = {
        "bpe_entries": len(bpe), "added_token_rows": len(added),
        "rows_above_bpe_vocab": V - len(bpe),
        "rows_with_only_ascii_or_wordmark": len(ascii_ok),
        "rows_with_a_non_ascii_character": len(bpe) - len(ascii_ok),
        "note": "the checkpoint carries a 32,000-entry Llama-style SentencePiece BPE plus 768 "
                "rows above it; the non-ASCII rows (CJK, Cyrillic, accented Latin) cannot be "
                "produced by an English transcript"}

    per_set = {}
    for sname in a.sets:
        corpus, idx = ls.tune_set() if sname == "dev" else ls.eval_set()
        if a.n:
            idx = ls.even(idx, a.n)
        refs = [corpus.texts[i] for i in idx]
        txt, ids, hs = decode_set(model, tok, corpus, idx, dev, capture_h=True)
        ref_ids = [tok(r)["input_ids"] for r in refs]
        emitted = [[t for t in r if t not in SPECIAL] for r in ids]
        flat = [t for r in emitted for t in r]
        set_rec = {
            "name": f"{corpus.name} <= {me.WINDOW_S} s", "utterances": len(idx),
            "speakers": len({corpus.speakers[i] for i in idx}),
            "words": int(sum(len(r.split()) for r in refs)),
            "float_wer_vs_reference": fq.wer(refs, txt)["wer"],
            "tokens_emitted_total": len(flat),
            "tokens_per_utterance_mean": len(flat) / max(len(idx), 1),
            "tokens_per_utterance_p50": float(np.percentile([len(r) for r in emitted], 50)),
            "tokens_per_utterance_p95": float(np.percentile([len(r) for r in emitted], 95)),
            "tokens_per_utterance_max": int(max(len(r) for r in emitted)),
            "distinct_rows_emitted": len(set(flat)),
            "distinct_rows_in_reference_tokenisation": len({t for r in ref_ids for t in r}),
            "max_row_id_emitted": int(max(flat)) if flat else 0,
        }
        # cumulative coverage of the emitted tokens by the most frequent rows
        cnt = np.bincount(np.asarray(flat, dtype=np.int64), minlength=V)
        order = np.argsort(-cnt)
        cum = np.cumsum(cnt[order]) / max(cnt.sum(), 1)
        set_rec["frequency_coverage"] = {str(m): float(cum[min(m, V) - 1])
                                         for m in (64, 128, 256, 512, 1024, 2048, 4096, 8192)}
        per_set[sname] = dict(rec=set_rec, corpus=corpus, idx=idx, refs=refs, txt=txt,
                              ids=ids, emitted=emitted, cnt=cnt, hs=hs)
        out["sets"][sname] = set_rec
        print(f"[{sname}] {len(idx)} utt, float WER {set_rec['float_wer_vs_reference']*100:.2f} %, "
              f"{set_rec['distinct_rows_emitted']} distinct rows emitted of {V}, "
              f"{set_rec['tokens_per_utterance_mean']:.1f} tokens/utt  ({time.time()-t0:.0f} s)")

    # ---- the kept set is chosen on DEV ONLY --------------------------------------------------
    if "dev" in per_set or a.source == "train":
        if a.source == "train":
            cnt_dev = np.load(a.train_counts)
            sel_label = ("rows the float model EMITS on LibriSpeech train-clean-100 "
                         "(model_trainset.py --emit), most frequent first; disjoint from "
                         "dev-clean and test-clean")
        else:
            cnt_dev = per_set["dev"]["cnt"]
            sel_label = ("the rows the float model EMITS on dev-clean (765 utterances), most "
                         "frequent first; dev only, never test")
        order_dev = np.argsort(-cnt_dev, kind="stable")
        always = list(SPECIAL) + (list(range(3, 259)) if a.byte_fallback else [])
        keep_sets = {}
        for m in a.keep_sizes:
            k = np.zeros(V, dtype=bool)
            k[order_dev[:m]] = True
            for s_ in always:
                k[s_] = True
            keep_sets[m] = k
        out["kept_set_selection"] = {
            "source": a.source, "rule": sel_label,
            "always_kept": ("<unk>/<s>/</s>" + (" + the 256 <0xNN> byte-fallback rows"
                                                if a.byte_fallback else "")),
            "byte_fallback": bool(a.byte_fallback),
            "rows_emitted_by_the_source": int((cnt_dev > 0).sum()),
            "source_tokens": int(cnt_dev.sum()),
        }

        # coverage of a dev-chosen set on each set, and the WER it costs
        out["static_prune"] = []
        for m in a.keep_sizes:
            k = keep_sets[m]
            row = {"V_kept": int(k.sum()),
                   "fetched_bytes": image_bytes(int(k.sum())),
                   "fetched_bytes_vs_full": image_bytes(int(k.sum())) / image_bytes(V)}
            for sname, p in per_set.items():
                flat = [t for r in p["emitted"] for t in r]
                miss = sum(1 for t in flat if not k[t])
                utt_miss = sum(1 for r in p["emitted"] if any(not k[t] for t in r))
                row[f"{sname}_tokens_outside_kept_pct"] = 100.0 * miss / max(len(flat), 1)
                row[f"{sname}_utterances_touched_pct"] = 100.0 * utt_miss / max(len(p["emitted"]), 1)
            out["static_prune"].append(row)
            print(f"  keep {row['V_kept']:6d} rows -> {row['fetched_bytes']/1e6:.3f} MB  " +
                  "  ".join(f"{s}: {row[f'{s}_tokens_outside_kept_pct']:.3f} % tokens outside"
                            for s in per_set))

        # WER of the masked decode, on every set present
        out["static_prune_wer"] = []
        base_e, base_n = {}, {}
        for sname, p in per_set.items():
            base_e[sname], base_n[sname] = q16f.utt_errors(p["refs"], p["txt"])
        for m in a.keep_sizes:
            if m >= V:
                continue
            k = keep_sets[m]
            rec = {"V_kept": int(k.sum()), "fetched_bytes": image_bytes(int(k.sum()))}
            for sname, p in per_set.items():
                txt, _, _ = decode_set(model, tok, p["corpus"], p["idx"], dev, keep_mask=k)
                e, n = q16f.utt_errors(p["refs"], txt)
                rec[sname] = {"wer_vs_reference": float(e.sum() / n.sum()),
                              "delta_vs_float": q16f.paired_bootstrap(e, base_e[sname], n)}
            out["static_prune_wer"].append(rec)
            print(f"  keep {rec['V_kept']:6d}: " + "  ".join(
                f"{s} WER {rec[s]['wer_vs_reference']*100:.2f} % "
                f"(delta {rec[s]['delta_vs_float']['delta_wer']*100:+.2f})" for s in per_set))

    # ---- exact and approximate two-stage schemes, on the captured hidden states -------------
    Wc = W.to(dev)
    nrm = Wc.norm(dim=1)                                          # |w_v|
    order_norm = torch.argsort(nrm, descending=True)
    nrm_sorted = nrm[order_norm]
    Wsorted = Wc[order_norm]
    two = {"note": "measured on the hidden states the float model actually fed to lm_head, one "
                   "per decoded token, over the sets below"}
    for sname, p in per_set.items():
        H = torch.from_numpy(np.concatenate(p["hs"], 0)).to(dev)   # [steps, 288]
        S = H @ Wc.T
        best = S.max(1)
        exact = best.indices
        hn = H.norm(dim=1)
        # norm bound: the smallest m with |h| * |w_(m)| <= best score
        Ssorted = H @ Wsorted.T
        run = torch.cummax(Ssorted, dim=1).values
        bound = hn[:, None] * nrm_sorted[None, :]
        # rows visited = first index where the bound has fallen below the running best
        stop = (bound <= run).float()
        first = torch.where(stop.any(1), stop.argmax(1) + 1, torch.full_like(exact, V))
        two.setdefault("norm_bound", {})[sname] = {
            "steps": int(H.shape[0]),
            "rows_visited_mean": float(first.float().mean()),
            "rows_visited_p50": float(first.float().median()),
            "rows_visited_p95": float(torch.quantile(first.float(), 0.95)),
            "fraction_of_rows_mean": float(first.float().mean()) / V,
            "exact": True,
            "extra_table_bytes": 2 * V,
            "why": "|h|.|w_v| is a loose bound: the best row's cosine with h is far below 1, so "
                   "the bound of a high-norm row stays above the winning score"}
        # frequency-ordered first stage: is the exact argmax inside the top-M frequent rows?
        pass  # the frequency ranking is cnt_dev, chosen above
        two.setdefault("frequency_ranking_source", "dev-clean" if "dev" in per_set else sname)
        ford = torch.from_numpy(np.argsort(-cnt_dev).copy()).to(dev)
        rank = torch.empty(V, dtype=torch.long, device=dev)
        rank[ford] = torch.arange(V, device=dev)
        r_exact = rank[exact]
        two.setdefault("frequency_first_stage", {})[sname] = {
            str(M): float((r_exact < M).float().mean()) for M in (256, 512, 1024, 2048, 4096, 8192)}
        # k-means clusters
        for C in a.clusters:
            g = torch.Generator(device="cpu").manual_seed(0)
            cent = Wc[torch.randperm(V, generator=g)[:C].to(dev)].clone()
            for _ in range(15):
                asg = (Wc @ cent.T - 0.5 * cent.pow(2).sum(1)[None, :]).argmax(1)
                acc = torch.zeros_like(cent).index_add_(0, asg, Wc)
                nn_ = torch.bincount(asg, minlength=C).clamp(min=1).float()[:, None]
                keepc = torch.bincount(asg, minlength=C) > 0
                cent = torch.where(keepc[:, None], acc / nn_, cent)
            asg = (Wc @ cent.T - 0.5 * cent.pow(2).sum(1)[None, :]).argmax(1)
            size = torch.bincount(asg, minlength=C).float()
            d2 = (Wc - cent[asg]).norm(dim=1)
            rad = torch.zeros(C, device=dev).index_reduce_(0, asg, d2, "amax", include_self=False)
            Sc = H @ cent.T
            ordc = torch.argsort(Sc, dim=1, descending=True)
            # approximate: open the k best clusters by h.mu
            topk = {}
            for kk in (1, 2, 4, 8, 16):
                if kk > C:
                    continue
                sel = ordc[:, :kk]
                hit = (asg[exact][:, None] == sel).any(1).float().mean()
                rows = size[sel].sum(1)
                topk[str(kk)] = {"exact": False, "top1_agreement": float(hit),
                                 "rows_fetched_mean": float(rows.mean()),
                                 "fraction_of_rows_mean": float(rows.mean()) / V,
                                 "stage1_bytes": C * D}
            bestc = ordc[:, 0]
            opened_rows = size[bestc]
            in_best = (asg[exact] == bestc).float().mean()
            # exact: open clusters in bound order until the bound <= best found
            ub = Sc + hn[:, None] * rad[None, :]
            o = torch.argsort(ub, dim=1, descending=True)
            ub_s = torch.gather(ub, 1, o)
            sz_s = size[o]
            # best score achievable after opening the first j clusters, per step: approximate
            # it by the exact best (a lower bound on the running best -> an UPPER bound on the
            # clusters opened would need the running max; use the exact best, which is what the
            # first cluster containing the argmax gives, and report both)
            need = (ub_s > best.values[:, None]).float()
            n_open = need.sum(1) + 1
            rows_open = (torch.cumsum(sz_s, 1).gather(1, (n_open.long() - 1).clamp(max=C - 1)[:, None])
                         .squeeze(1))
            two.setdefault("clusters", {}).setdefault(str(C), {})[sname] = {
                "open_best_cluster_only": {
                    "exact": False,
                    "top1_agreement": float(in_best),
                    "rows_fetched_mean": float(opened_rows.mean()),
                    "fraction_of_rows_mean": float(opened_rows.mean()) / V,
                    "stage1_bytes": C * D},
                "open_top_k_clusters": topk,
                "bound_branch_and_bound": {
                    "exact": True,
                    "clusters_opened_mean": float(n_open.mean()),
                    "rows_fetched_mean": float(rows_open.mean()),
                    "fraction_of_rows_mean": float(rows_open.mean()) / V,
                    "stage1_bytes": C * D},
            }
        print(f"  [{sname}] norm bound visits {two['norm_bound'][sname]['fraction_of_rows_mean']*100:.1f} % "
              f"of rows on average (exact)")
    out["two_stage"] = two
    out["elapsed_s"] = time.time() - t0
    with open(a.json, "w") as f:
        json.dump(out, f, indent=1)
    print(f"wrote {a.json}  ({out['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
