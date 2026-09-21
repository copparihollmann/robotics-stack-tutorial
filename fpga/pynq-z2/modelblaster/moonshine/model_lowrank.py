#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Is lm_head low rank?  The SVD of the 32768 x 288 tied projection, what truncating it does to
the argmax and to WER, and what it costs in bytes on the engine.

A rank-r factorisation replaces one dispatch of N = V, K = 288 with two: N = r, K = 288 then
N = V, K = r.  The second still has V rows, so r x V dominates unless V is pruned too -- which is
the honest note this file exists to put a number on.  Bytes come from model_cost.lmhead_image
(engine_traffic's own planar-image planner), WER from the ordinary greedy decode.

    PYTHONPATH=$MOONSHINE_DIR/pylib python3 model_lowrank.py --sets dev test --json model_lowrank.json
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
import model_cost as mc  # noqa: E402
import model_vocab as mv  # noqa: E402
import q16_fidelity as q16f  # noqa: E402

RANKS = (16, 32, 48, 64, 96, 128, 160, 192, 224, 256, 288)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", nargs="+", default=["dev", "test"], choices=("dev", "test"))
    ap.add_argument("--json", required=True)
    ap.add_argument("--wer-ranks", type=int, nargs="+", default=[64, 128, 192])
    ap.add_argument("--n", type=int, default=0)
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = fq.device()
    model, tok = mv.load_hf(dev)
    W = model.proj_out.weight.detach().float().to(dev)          # [32768, 288]
    V, D = W.shape
    U, S, Vh = torch.linalg.svd(W, full_matrices=False)          # S: [288]
    energy = (S ** 2).cumsum(0) / (S ** 2).sum()

    out = {"what": __doc__.split("\n")[0], "V": V, "D": D,
           "singular_value_energy": {str(r): float(energy[r - 1]) for r in RANKS},
           "spectral_flatness": float(S.min() / S.max()),
           "note": "a 32768 x 288 matrix has rank at most 288; the question is only whether its "
                   "spectrum decays, and the energy column says it barely does",
           "ranks": []}

    per_set = {}
    for sname in a.sets:
        corpus, idx = ls.tune_set() if sname == "dev" else ls.eval_set()
        if a.n:
            idx = ls.even(idx, a.n)
        refs = [corpus.texts[i] for i in idx]
        txt, ids, hs = mv.decode_set(model, tok, corpus, idx, dev, capture_h=True)
        e0, n0 = q16f.utt_errors(refs, txt)
        per_set[sname] = dict(corpus=corpus, idx=idx, refs=refs, txt=txt,
                              H=torch.from_numpy(np.concatenate(hs, 0)).to(dev), e0=e0, n0=n0,
                              wer=float(e0.sum() / n0.sum()))
        out.setdefault("sets", {})[sname] = {
            "name": f"{corpus.name} <= 4 s", "utterances": len(idx),
            "words": int(n0.sum()), "float_wer": per_set[sname]["wer"],
            "lm_head_steps_captured": int(per_set[sname]["H"].shape[0])}

    # ---- top-1 agreement against the exact argmax, per rank --------------------------------
    for r in RANKS:
        Wr = (U[:, :r] * S[:r]) @ Vh[:r]
        row = {"rank": r, "energy": float(energy[r - 1])}
        # bytes: two dispatches, A = [r, 288] and B = [V, r] (r rounded up to 8 bytes)
        ab = mc.lmhead_image(r, D)["fetched_bytes"]
        bb = mc.lmhead_image(V, max(8, (r + 7) // 8 * 8))["fetched_bytes"]
        row.update(fetched_bytes=ab + bb, fetched_bytes_vs_full=(ab + bb) / mc.lmhead_image(V)["fetched_bytes"])
        for sname, p in per_set.items():
            ex = (p["H"] @ W.T).argmax(1)
            ap_ = (p["H"] @ Wr.T).argmax(1)
            row[f"{sname}_top1_agreement"] = float((ex == ap_).float().mean())
        out["ranks"].append(row)
        print(f"  rank {r:4d}  energy {row['energy']:.4f}  bytes {row['fetched_bytes']/1e6:6.3f} MB "
              f"({row['fetched_bytes_vs_full']:.2f}x)  " +
              "  ".join(f"{s} top1 {row[f'{s}_top1_agreement']*100:.2f} %" for s in per_set))

    # ---- WER at a few ranks, the honest measure ---------------------------------------------
    out["wer"] = []
    orig = model.proj_out.weight.data.clone()
    for r in a.wer_ranks:
        Wr = (U[:, :r] * S[:r]) @ Vh[:r]
        model.proj_out.weight.data.copy_(Wr.to(orig.dtype))
        rec = {"rank": r}
        for sname, p in per_set.items():
            txt, _, _ = mv.decode_set(model, tok, p["corpus"], p["idx"], dev)
            e, n = q16f.utt_errors(p["refs"], txt)
            rec[sname] = {"wer": float(e.sum() / n.sum()),
                          "delta_vs_float": q16f.paired_bootstrap(e, p["e0"], p["n0"])}
        out["wer"].append(rec)
        print(f"  rank {r:4d}  " + "  ".join(
            f"{s} WER {rec[s]['wer']*100:.2f} % (delta {rec[s]['delta_vs_float']['delta_wer']*100:+.2f})"
            for s in per_set))
    model.proj_out.weight.data.copy_(orig)

    # ---- the honest note, with numbers: rank r on a PRUNED vocabulary -----------------------
    out["rank_with_pruning"] = []
    for Vk in (32768, 11000, 4096, 2048):
        for r in (32, 64, 128, 288):
            ab = mc.lmhead_image(r, D)["fetched_bytes"]
            bb = mc.lmhead_image(Vk, max(8, (r + 7) // 8 * 8))["fetched_bytes"]
            full = mc.lmhead_image(Vk, D)["fetched_bytes"]
            out["rank_with_pruning"].append(
                {"V": Vk, "rank": r, "factorised_bytes": ab + bb, "plain_bytes": full,
                 "factorisation_helps": (ab + bb) < full})
    out["elapsed_s"] = time.time() - t0
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({out['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
