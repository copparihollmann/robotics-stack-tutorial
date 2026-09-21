#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The quantisation PLAN of one quant_fix.py candidate, frozen for ModelBlaster's integer lowering.

quant_fix.py's build(M, knobs) is the reference for every range and transform of the
candidates ROCC_DECOUPLED.md section 8.13 selected in float simulation.  This script runs it
once, on the same 64 dev-clean calibration windows, and writes what it decided -- per tensor,
per weight -- as JSON, so the extractor (patches/0103, pipeline/extract_q16.py) lowers exactly
what fq.py simulated rather than re-deriving it:

  tensors  node -> {"kind": "pt",    "bits": 8|16, "range": r}
                   {"kind": "pc",    "bits": 8,    "ranges": [r_c], "dim": d}
                   {"kind": "multi", "bits": 8,    "range": r, "ratios": [1, ...]}
           (scale = range / (2^(bits-1) - 1); SDPA's internal tensors as <node>__scores and
           <node>__probs; pass-through view/permute/reshape nodes carry their root's codes and
           are not listed)
  weights  module -> {"grid": "pt"} | {"grid": "pc"} |
                     {"grid": "rg", "groups": [[row, ...], ...]}   (fq.WeightState's own split)
  rows     module -> [a_c]: weight rows and bias divided by a_c (float32) before the grid is
                     taken; the output tensor then carries scale * a_c per channel

The candidate keys are quant_fix.py's, verbatim; their knobs are read from the committed
records rather than rebuilt, so a later edit of quant_fix.py's candidate list cannot change a
plan silently.

    PYTHONPATH=zephyr-chipyard-sw:$MOONSHINE_DIR/pylib python3 q16_plan.py --candidate R --out q16_plan_R.json

The committed plans (q16_plan_{R,R3,F3PR}.json) are what scripts/53_moonshine_q16_host.sh
lowers; --replan there rebuilds them.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import quant_fix as qf  # noqa: E402

# WARNING TO ANYONE DEFINING A NEW STEM-SPLIT CANDIDATE (measured, L272/MOONSHINE-MODEL):
#
#   * The WEIGHT-GROUP axis (`wgroups`) looks like an obvious simplification to drop.  It is not.
#     It costs +1.55 WER points on dev-clean 765 (R 8.19 -> 9.74 %, float sim) and saves ZERO
#     cycles, because splitting rows between dispatches changes no MACs.  Dropping it is a pure
#     loss.  KEEP IT.
#   * `multi = [64]` is NOT "the fine range only".  fq.fq_tensor's "multi" kind always computes
#     the coarse grid and only OVERLAYS the finer ratios where they do not saturate, so [64] is
#     bit-identical to [1, 64].  To ask for one finer dispatch, drop `multi` and clip the range
#     with `calib_nodes` instead.
#   * Only the INPUT and RANGE axes multiply MACs (2x each); R is 4.00x an unsplit stem, not 8x.
#
# MOONSHINE_MODEL.md s2.6 carries the whole curve.
CANDIDATES = {
    "R": ("quant_fix_final_dev2.json",
          "FINAL R: split stem (1, 64), stem weights 2 group(s), adds per-channel + o_proj/fc2 rows"),
    "R3": ("quant_fix_final_dev2.json",
           "FINAL R: split stem (1, 16, 256), stem weights 4 group(s), adds per-channel + o_proj/fc2 rows"),
    "F3PR": ("quant_fix_codesign_dev.json",
             "CD F3PR: stem int16 + adds per-channel + rows + per-row"),
    # The QAT-unsplit point of MOONSHINE_MODEL.md s2.6.3's curve.  Run it with MOONSHINE_DIR
    # pointing at the QAT checkpoint -- the knobs describe the quantisation, the checkpoint
    # supplies the weights that were trained against it.
    "QATU": ("model_qat_unsplit_knobs.json",
             "QATU: unsplit stem, plain per-tensor W8A8, p99.9 activation calibration"),
}


def plan_of(M: qf.Model, label: str) -> dict:
    rec, key = CANDIDATES[label]
    r = json.load(open(os.path.join(HERE, rec)))
    cand = r["candidates"][key]
    knobs = cand["knobs"]
    cfg, wcfg, wover, bover, pre_div, post_mul, _ = qf.build(M, knobs)
    if pre_div:
        raise SystemExit(f"{label}: migration (pre_div) is not lowered by extract_q16")
    tensors = {}
    for n, s in cfg.items():
        if s[0] == "pt":
            tensors[n] = {"kind": "pt", "bits": int(s[1]), "range": float(s[2])}
        elif s[0] == "pc":
            tensors[n] = {"kind": "pc", "bits": int(s[1]),
                          "ranges": [float(v) for v in s[2].detach().cpu().float()], "dim": int(s[3])}
        elif s[0] == "multi":
            tensors[n] = {"kind": "multi", "bits": int(s[1]), "range": float(s[2]),
                          "ratios": sorted(int(v) for v in s[3])}
        elif s[0] == "dual":
            tensors[n] = {"kind": "multi", "bits": int(s[1]), "range": float(s[2]),
                          "ratios": [1, int(s[3])]}
        else:
            raise SystemExit(f"{label}: tensor grid {s[0]} not lowered")
    weights = {}
    for mod, spec in wcfg.items():
        if spec is None:
            raise SystemExit(f"{label}: float weights on {mod} are not lowered")
        if spec[1] != 8:
            raise SystemExit(f"{label}: {spec[1]}-bit weights on {mod} are not lowered")
        if spec[0] == "pt":
            weights[mod] = {"grid": "pt"}
        elif spec[0] == "pc":
            weights[mod] = {"grid": "pc"}
        elif spec[0] == "rg":
            # fq.WeightState.apply's own split, on the weight it quantises
            w = wover[mod]
            rmax = w.abs().reshape(w.shape[0], -1).amax(dim=1)
            order = torch.argsort(rmax)
            weights[mod] = {"grid": "rg", "groups": [sorted(int(i) for i in g) for g in torch.chunk(order, int(spec[2]))]}
        else:
            raise SystemExit(f"{label}: weight grid {spec[0]} not lowered")
    rows = {}
    for mod in knobs.get("rows", {}):
        node = qf.node_of(mod)
        a, _dim = post_mul[node]
        rows[mod] = [float(v) for v in a.detach().cpu().float()]
    return {"what": "quantisation plan of one quant_fix.py candidate (fq.py float simulation), "
                    "frozen for patches/0103's integer lowering",
            "candidate": label, "quant_fix_key": key, "record": rec, "knobs": knobs,
            "calibration_windows": len(M.cal),
            "float_sim_dev_clean": {"wer_vs_reference": cand["wer_vs_reference"],
                                    "wer_vs_float": cand.get("wer_vs_float")},
            "tensors": tensors, "weights": weights, "rows": rows,
            "passthrough": sorted(M.passthrough)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True, choices=sorted(CANDIDATES))
    ap.add_argument("--out", required=True)
    ap.add_argument("--ncal", type=int, default=64)
    a = ap.parse_args()
    torch.set_grad_enabled(False)
    M = qf.Model(fq.device(), a.ncal)
    p = plan_of(M, a.candidate)
    with open(a.out, "w") as f:
        f.write(json.dumps(p, separators=(",", ":")) + "\n")
    print(f"wrote {a.out}: {len(p['tensors'])} tensors, {len(p['weights'])} weights, {len(p['rows'])} row sets")


if __name__ == "__main__":
    main()
