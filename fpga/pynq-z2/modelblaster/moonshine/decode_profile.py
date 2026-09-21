#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The decoder residue, split into the BLOCKS a hardware lane would remove, for a measured model.

ROCC_DECOUPLED.md s8.15.15.  decode_compose.py gives the residue as one number and a split by op
KIND; a lane removes a BLOCK -- the attention unit takes the scores, the softmax, the weighted sum
AND the rotary; the LayerNorm lane takes the norms -- and those cut across kinds, because the
rotary is priced as mul/neg/add ops.  This groups reprice_port's own decoder op list by block, with
each block's unit costs named, and says what each lane removes.

    python3 decode_profile.py --calib board/b30_q16r_run.json --calib-int-model enc_q16 \
        --tokens 11.976 --gemm-ms 92.3 --json decode_profile_R.json
"""
from __future__ import annotations
import argparse, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import decode_compose as dc    # noqa: E402
import reprice_port as rp      # noqa: E402

CLK = rp.CLK


def block_of(o):
    n, k = o["name"], o["kind"]
    if ".rope." in n:   return "rotary"
    if n.endswith(".gate"):  return "gate multiply"
    if k == "silu":     return "SiLU"
    if k == "matmul":   return "attention matmul"
    if k == "softmax":  return "attention softmax"
    if k == "layernorm":return "LayerNorm"
    if k == "add":      return "residual adds"
    if k == "embed":    return "embed"
    return k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--calib", required=True)
    ap.add_argument("--calib-int-model")
    ap.add_argument("--tokens", type=float, default=11.976)
    ap.add_argument("--gemm-ms", type=float, default=92.3, help="GEMM ms/token at the chosen port")
    ap.add_argument("--once-ms", type=float, default=392.6, help="cross-attention K,V per utterance")
    ap.add_argument("--target-rtf", type=float, default=0.50)
    ap.add_argument("--json", required=True)
    a = ap.parse_args()

    cost = dc.calibrate(a.calib, a.calib_int_model, None)
    saved, rp.COST = rp.COST, cost
    try:
        T, _ = rp.encoder(4.0)
        ops = rp.decoder_token(T, max(1, int(round(a.tokens + 1)) // 2))
        blocks, est_blocks = {}, set()
        for o in ops:
            if o["kind"] == "linear":
                continue                       # the GEMMs are measured dispatches, not residue
            cy, est = rp.core_cycles(o, "nl+ew")
            b = block_of(o)
            blocks[b] = blocks.get(b, 0.0) + cy
            if est:
                est_blocks.add(b)
        # the rotary TENSOR's elements, not the op list's: the four ops per (layer, position)
        # -- mul, neg, mul, add -- all describe the same H*ROT elements, so count one of them.
        rope_els = sum(o["els"] for o in ops if o["name"].endswith(".cos"))
    finally:
        rp.COST = saved

    ms = {b: c / CLK * 1e3 for b, c in blocks.items()}
    out = {"what": __doc__.split("\n")[0], "calib": os.path.abspath(a.calib),
           "int_model": dc.calibrate.models[0], "unit_cost_kinds": dc.calibrate.kinds,
           "tokens": a.tokens, "gemm_ms_per_token": a.gemm_ms, "cross_attention_once_ms": a.once_ms,
           "blocks_ms": ms, "blocks_with_estimates": sorted(est_blocks),
           "rotary_elements_per_token": rope_els}
    # the measured rope kernel, if the calibration run has one, replaces the mul/neg/add estimate
    if dc.calibrate.rope_c_el:
        meas = rope_els * dc.calibrate.rope_c_el / CLK * 1e3
        out["rotary_measured_ms"] = meas
        out["rotary_estimate_ms"] = ms.get("rotary", 0.0)
        ms["rotary"] = meas
        est_blocks.discard("rotary")
    res = sum(ms.values())
    out["residue_ms_per_token"] = res
    out["residue_estimate_share"] = sum(ms[b] for b in est_blocks) / res if res else 0
    T2 = ms.get("attention matmul", 0) + ms.get("attention softmax", 0) + ms.get("rotary", 0)
    T3 = ms.get("LayerNorm", 0)
    T4 = ms.get("SiLU", 0) + ms.get("gate multiply", 0) + ms.get("residual adds", 0)
    out["lane_removes_ms"] = {"T2 attention unit": T2, "T3 LayerNorm lane": T3,
                              "T4 LUT/GroupNorm/add lanes": T4}
    tok = a.gemm_ms + res
    budget = (a.target_rtf * 4000.0 - a.once_ms) / a.tokens
    out["token_ms"] = {"as composed": tok, "after T2": tok - T2, "after T2+T3": tok - T2 - T3,
                       "after T2+T3+T4": tok - T2 - T3 - T4}
    out["budget_ms_per_token"] = budget
    out["decoder_rtf"] = {k: (a.once_ms + a.tokens * v) / 4000.0 for k, v in out["token_ms"].items()}
    print("unit costs from %s: %s" % (out["int_model"], out["unit_cost_kinds"]))
    print("residue %.1f ms/token, %.0f %% of it estimate" % (res, 100 * out["residue_estimate_share"]))
    for b, v in sorted(ms.items(), key=lambda kv: -kv[1]):
        print("   %-19s %6.2f ms  %5.1f %%%s" % (b, v, 100 * v / res, "  (estimate)" if b in est_blocks else ""))
    print("\nlanes: T2 removes %.1f, T3 removes %.1f, T4 removes %.1f" % (T2, T3, T4))
    print("token at GEMM %.1f: %s" % (a.gemm_ms, {k: round(v, 1) for k, v in out["token_ms"].items()}))
    print("budget for decoder RTF %.2f at %.3f tokens: %.1f ms/token" % (a.target_rtf, a.tokens, budget))
    print("decoder RTF: %s" % {k: round(v, 3) for k, v in out["decoder_rtf"].items()})
    json.dump(out, open(a.json, "w"), indent=1)
    print("wrote %s" % a.json)


if __name__ == "__main__":
    main()
