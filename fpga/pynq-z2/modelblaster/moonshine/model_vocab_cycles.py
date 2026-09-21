#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""What a static lm_head prune is worth in cycles, priced on the board records, both halves.

Lab B30's own verdict on the lm_head split was MISSED "because the weight-image build was priced
at zero".  So this prices it, on both sides, and reports the COLD (first inference from a cold
image cache) and STEADY (every inference after) savings SEPARATELY -- they move by very
different amounts and blending them into one RTF is how the last estimate went wrong.

WHICH RECORD IS THE BASELINE
----------------------------
b28_dec_t4_run.json has engine.calls_fallback = 24: lm_head is 9,437,184 raw weight bytes and
mbxr_rt_image refuses anything over the 8 MB MBXR_RT_ROW_STAGE buffer, so lm_head never reached
the engine there -- its 306.2 M cycles are the CPU fallback's.  b30_lmhead_split_run.json splits
lm_head into 2 x N=16384 so it passes the guard (calls_fallback 0), and is the engine baseline.

Two further cautions about those two records, which do not use the same arithmetic:

  * (this is L296/MOONSHINE-MODEL's correction, found independently by the coordinator and
    reached again here from the same arithmetic.)  scripts/58 keys per-dispatch cycles by IR OP NAME (`ops[o["name"]] = cycles`), and the
    unrolled decoder reuses one name across all 24 steps, so every row of a name carries the
    LAST dispatch's value.  Observable: all 24 lm_head rows are 12,757,577 to the digit, and
    the step-0 and step-23 totals of every linear shape are equal.  The one-time image build
    happens on FIRST use, so it is not in that value -- b28's dispatch_cycles_total excludes
    the image build, and its steady_cycles = total - image_cycles subtracts it a second time.
    b28's steady is therefore 660.1 M as printed but 779.3 M as measured (median - image).
  * b30's numbers were parsed from the console by hand (its own `source` field says report.py
    raised), and its per_op sum 942,710,032 lands within 0.13 % of median_cycles 943,902,149 --
    so those ARE whole sums and DO contain the image build, exactly as its steady_cycles
    assumes.  The two records' per-op tables are not comparable; their FIRMWARE COUNTERS are.

So nothing below uses a per-op table.  Everything is derived from median_cycles and the
MB_ROCCMOON counters (image_cycles, image_bytes, cycles_h0, calls_engine, bytes_wgt), which
both records collect the same way.

    python3 model_vocab_cycles.py --json model_vocab_cycles.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import engine_traffic as et  # noqa: E402

CLK = 34482759.0
WINDOW_S = 4.0
KP = 288
STAGE_GUARD = 8 << 20


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--b28", default=os.path.join(HERE, "board", "b28_dec_t4_run.json"))
    ap.add_argument("--b30", default=os.path.join(HERE, "board", "b30_lmhead_split_run.json"))
    ap.add_argument("--keep", type=int, nargs="+", default=[16384, 11000])
    # dec_cse_on, from its WALL CLOCK minus its image build -- not from L295's per-op table.
    # 4aac1ef: report.py joined per-dispatch cycles by op NAME, and the unrolled decoder has 80
    # names borne by 24 ops each, so 1,840 of 4,488 dispatches took another op's cycles and every
    # decoder per-op figure published before it is contaminated.  L295's 449,725,043 is one of
    # them.  The wall median (863,504,701) and image_cycles (416,668,282, unchanged by CSE since
    # image_bytes is identical on both arms) are firmware/wall measurements and are not.
    ap.add_argument("--cse-steady", type=float, default=863504701.0 - 416668282.0,
                    help="per-iteration decoder cycles WITH ir_cse: dec_cse_on's wall median minus "
                         "its image build.  The prune lands after CSE, so the saving is also "
                         "quoted against this")
    ap.add_argument("--cse-cold", type=float, default=863504701.0)
    ap.add_argument("--wer-json", default=os.path.join(HERE, "model_vocab_int8.json"),
                    help="model_vocab_int8.py's record, for the MEASURED mean emitted-token count "
                         "per V: the pruned model emits slightly MORE tokens, and with the early "
                         "exit that is real work the per-step saving does not show")
    ap.add_argument("--json", required=True)
    a = ap.parse_args()

    b28 = json.load(open(a.b28))["models"]["dec_q16"]
    b30 = json.load(open(a.b30))
    e28, e30 = b28["engine"], b30["engine"]
    steps = len(b28["rows"]) and 24

    # --- what the records say, as measured -------------------------------------------------
    m28 = int(b28["run_line"].split("median=")[1].split()[0])
    m30 = b30["median_cycles"]
    img28, img30 = e28["image_cycles"], e30["image_cycles"]
    steady28, steady30 = m28 - img28, m30 - img30           # one definition, applied to both

    # --- lm_head's engine cost, from the counters, two independent ways ---------------------
    # (1) the hart-0 engine-cycle counter: mbxr_rt.h documents cycles_h0 as "hart-0 wall cycles
    #     inside engine calls, hand-off included" and the image build has its own counter, so
    #     the delta is lm_head's engine dispatches and nothing else.
    lm_engine_h0 = e30["cycles_h0"] - e28["cycles_h0"]
    # (2) the medians: everything but lm_head is the same graph in both runs, so
    #     steady30 - steady28 = lm_head_engine - lm_head_fallback.
    lm_fallback = 306181848                                  # b28, 24 x 12,757,577 (the fallback)
    lm_engine_med = steady30 - steady28 + lm_fallback

    # --- the engine is weight-bandwidth-bound: fit cycles = A*calls + B*weight_bytes --------
    # two points, both firmware counters: b28's 1296 non-lm_head engine calls, and the 48 calls
    # b30 adds for lm_head.  A comes out tiny, which is the confirmation, not an assumption.
    c1, w1, y1 = e28["calls_engine"], e28["bytes_wgt"], e28["cycles_h0"]
    c2 = e30["calls_engine"] - e28["calls_engine"]
    w2 = e30["bytes_wgt"] - e28["bytes_wgt"]
    y2 = lm_engine_h0
    B = (y1 * c2 - y2 * c1) / (w1 * c2 - w2 * c1)
    A = (y2 - B * w2) / c2

    # --- the image build: measured rates, large and small ----------------------------------
    img_lm = img30 - img28                                   # lm_head's 2 chunks, 9,961,472 B
    bytes_lm = e30["image_bytes"] - e28["image_bytes"]
    rate_lm = img_lm / bytes_lm                              # cycles per image byte, LARGE image
    rate_small = img28 / e28["image_bytes"]                  # the 54 layer images, all < 700 kB

    full = et.wimage_plan(32768, KP)["bytes"]
    out = {"what": __doc__.split("\n")[0], "clock_hz": CLK, "window_s": WINDOW_S,
           "n_steps": steps,
           "records": {
               "b28_fallback": {"median_cycles": m28, "image_cycles": img28,
                                "image_bytes": e28["image_bytes"], "steady_cycles": steady28,
                                "calls_fallback": e28["calls_fallback"],
                                "steady_cycles_as_printed": b28["steady_cycles"],
                                "note": "the printed steady subtracts the image build from a "
                                        "dispatch total that never contained it; steady_cycles "
                                        "here is median - image, the same definition b30 uses"},
               "b30_engine_split": {"median_cycles": m30, "image_cycles": img30,
                                    "image_bytes": e30["image_bytes"], "steady_cycles": steady30,
                                    "calls_fallback": e30["calls_fallback"]}},
           "lm_head": {
               "shape": {"M": 1, "K": KP, "N": 32768},
               "raw_weight_bytes": 32768 * KP,
               "image_bytes": full,
               "stage_guard_bytes": STAGE_GUARD,
               "passes_stage_guard": 32768 * KP <= STAGE_GUARD,
               "fallback_cycles_24_steps": lm_fallback,
               "engine_cycles_24_steps_from_cycles_h0": lm_engine_h0,
               "engine_cycles_24_steps_from_medians": lm_engine_med,
               "engine_speedup_vs_fallback": lm_fallback / lm_engine_h0,
               "image_build_cycles": img_lm, "image_build_bytes": bytes_lm,
               "image_build_cycles_per_byte": rate_lm},
           "b30_per_shape_not_used": {
               "figure": 267018404,
               "what": "b30 linear_by_shape[\"M=1;K=288;N=32768\"], 24 dispatches",
               "why_not_used": "it is not consistent with b30's own median and counters.  If "
                               "lm_head's dispatches cost 267.0 M and its image build 294.2 M, "
                               "b30's median would be b28's 901.7 M - 306.2 M (the fallback it "
                               "replaced) + 267.0 M + 294.2 M = 1,156.7 M; the measured median "
                               "is 943.9 M.  The two routes used above -- the cycles_h0 delta "
                               "and the median delta -- give 53.4 M and 54.2 M independently and "
                               "are consistent with the median by construction.  b30's per_op "
                               "TOTAL is sound (942,710,032, within 0.13 % of its median); it is "
                               "the per-shape attribution that is not.",
               "implied_lm_head_engine_cycles_if_it_were_used": 267018404 - 294155420},
           "engine_fit": {"form": "cycles = A*calls + B*weight_bytes",
                          "A_cycles_per_call": A, "B_cycles_per_weight_byte": B,
                          "points": [{"calls": c1, "weight_bytes": w1, "cycles": y1,
                                      "what": "b28 non-lm_head engine calls"},
                                     {"calls": c2, "weight_bytes": w2, "cycles": y2,
                                      "what": "the 48 calls b30 adds for lm_head"}],
                          "per_call_share_of_lm_head": A * c2 / y2},
           "image_rate": {"large_image_measured": rate_lm, "small_images_measured": rate_small,
                          "used_for_prediction": "large_image_measured",
                          "why": "V=11000's image is 3.34 MB and its staging 3.17 MB, both far "
                                 "over any cache here, so it is in the same regime as lm_head's "
                                 "4.98 MB chunks and not the 54 sub-700 kB layer images; taking "
                                 "the small-image rate would be pricing a hoped-for effect"},
           "predictions": []}

    for V in a.keep:
        p = et.wimage_plan(V, KP)
        ib, raw = p["bytes"], V * KP
        chunks = 1 if raw <= STAGE_GUARD else -1
        eng = steps * (A + B * ib)
        # V=16384's image is exactly one of b30's two chunks: a measured half, not a fit
        exact_half = (ib == bytes_lm // 2)
        build = img_lm / 2 if exact_half else ib * rate_lm
        build_lo = ib * rate_small
        rec = {
            "V": V, "raw_weight_bytes": raw, "image_bytes": ib,
            "image_bytes_vs_full": ib / full,
            "passes_stage_guard": raw <= STAGE_GUARD, "chunks_needed": chunks,
            "engine_dispatch_cycles_24_steps": eng,
            "image_build_cycles": build,
            "image_build_cycles_optimistic": build_lo,
            "image_build_is_a_measured_half_of_b30": exact_half,
            "vs_b30_engine_split": {
                "steady_saving": lm_engine_h0 - eng,
                "steady_saving_pct_of_decoder_steady": 100.0 * (lm_engine_h0 - eng) / steady30,
                "steady_cycles": steady30 - (lm_engine_h0 - eng),
                "cold_saving": (img_lm - build),
                "cold_saving_pct_of_image_cycles": 100.0 * (img_lm - build) / img30,
                "cold_total_saving": (lm_engine_h0 - eng) + (img_lm - build),
                "cold_total_saving_pct": 100.0 * ((lm_engine_h0 - eng) + (img_lm - build)) / m30,
                "cold_total_cycles": m30 - (lm_engine_h0 - eng) - (img_lm - build)},
            "vs_dec_cse_on": {
                "note": "dec_cse_on (L295/MOONSHINE-MODEL) at wall median 863,504,701 less its "
                        "image build 416,668,282 = 446,836,419 steady.  Taken this way and not "
                        "from L295's per-op total, which 4aac1ef showed is name-joined and low. "
                        "image_bytes is 19,988,480 on both CSE arms -- CSE removes permutes, not "
                        "weight images -- so the lm_head saving is additive and its SHARE of "
                        "decoder steady rises because the denominator fell",
                "steady_saving": lm_engine_h0 - eng,
                "steady_saving_pct_of_decoder_steady": 100.0 * (lm_engine_h0 - eng) / a.cse_steady,
                "steady_cycles": a.cse_steady - (lm_engine_h0 - eng),
                "cold_saving": img_lm - build,
                "cold_total_cycles": a.cse_cold - (lm_engine_h0 - eng) - (img_lm - build),
                "cold_total_saving_pct": 100.0 * ((lm_engine_h0 - eng) + (img_lm - build)) / a.cse_cold,
                "image_bytes_after": e30["image_bytes"] - (full - ib)},
            "vs_b28_deployed_fallback": {
                "steady_saving": lm_fallback - eng,
                "steady_saving_pct_of_decoder_steady": 100.0 * (lm_fallback - eng) / steady28,
                "steady_cycles": steady28 - (lm_fallback - eng),
                "cold_extra_image": build,
                "cold_total_saving": (lm_fallback - eng) - build,
                "cold_total_cycles": m28 - (lm_fallback - eng) + build},
        }
        for k, base in (("vs_b30_engine_split", steady30), ("vs_dec_cse_on", a.cse_steady),
                        ("vs_b28_deployed_fallback", steady28)):
            rec[k]["rtf_steady_before"] = base / (CLK * WINDOW_S)
            rec[k]["rtf_steady_after"] = rec[k]["steady_cycles"] / (CLK * WINDOW_S)
        # The early exit makes a decode cost (mean emitted tokens) x (per-step cost), not 24 x it,
        # and the pruned model emits MORE tokens -- an offsetting term, priced rather than ignored.
        try:
            w = json.load(open(a.wer_json))
            per_step_base = a.cse_steady / steps
            per_step_lm_base, per_step_lm_V = lm_engine_h0 / steps, eng / steps
            ms = {}
            for sname, sr in w["sets"].items():
                m0 = sr["baseline"]["mean_steps"]
                m1 = sr["variants"][str(V)]["mean_steps"]
                c0 = m0 * per_step_base
                c1 = m1 * (per_step_base - per_step_lm_base + per_step_lm_V)
                ms[sname] = {
                    "mean_steps_baseline": m0, "mean_steps_pruned": m1,
                    "mean_steps_pct_more": 100.0 * (m1 - m0) / m0,
                    "cycles_per_utterance_baseline": c0, "cycles_per_utterance_pruned": c1,
                    "saving": c0 - c1, "saving_pct": 100.0 * (c0 - c1) / c0,
                    "saving_pct_if_steps_were_unchanged":
                        100.0 * m0 * (per_step_lm_base - per_step_lm_V) / c0}
            rec["per_utterance_with_early_exit"] = {
                "note": "the board image walks all 24 steps, so this term is invisible in b28/b30 "
                        "and appears only once the driver's early exit is in the loop",
                "basis": "dec_cse_on per-iteration cycles / 24, with lm_head swapped",
                "sets": ms}
        except (OSError, KeyError, ValueError) as e:
            rec["per_utterance_with_early_exit"] = {"unavailable": str(e)}
        out["predictions"].append(rec)

    json.dump(out, open(a.json, "w"), indent=1)
    print(f"steady definition: median - image_cycles, applied to both records")
    print(f"  b28 (lm_head on the CPU fallback) steady {steady28:,}   cold {m28:,}")
    print(f"  b30 (lm_head on the engine, split)  steady {steady30:,}   cold {m30:,}")
    print(f"lm_head on the engine, 24 steps: {lm_engine_h0:,} (cycles_h0) / "
          f"{lm_engine_med:,} (medians); on the fallback {lm_fallback:,}")
    print(f"engine fit: {A:,.0f} cycles/call + {B:.5f} cycles/weight byte "
          f"(per-call share of lm_head {100*A*c2/y2:.2f} %)")
    print(f"image build: {rate_lm:.2f} cyc/byte large (lm_head), {rate_small:.2f} small (54 layers)")
    for r in out["predictions"]:
        print(f"\nV={r['V']}  image {r['image_bytes']:,} B ({r['image_bytes_vs_full']:.3f}x), "
              f"guard {'PASS' if r['passes_stage_guard'] else 'FAIL'}, no split needed")
        g = r["vs_b30_engine_split"]
        print(f"  vs b30: STEADY -{g['steady_saving']:,.0f} cycles "
              f"({g['steady_saving_pct_of_decoder_steady']:.2f} % of decoder steady), "
              f"RTF {g['rtf_steady_before']:.3f} -> {g['rtf_steady_after']:.3f}")
        print(f"          COLD   -{g['cold_saving']:,.0f} cycles of image build "
              f"({g['cold_saving_pct_of_image_cycles']:.1f} % of image_cycles); "
              f"cold total -{g['cold_total_saving']:,.0f} ({g['cold_total_saving_pct']:.1f} %)")
        c = r["vs_dec_cse_on"]
        print(f"  vs dec_cse_on (where this will land): STEADY -{c['steady_saving']:,.0f} "
              f"({c['steady_saving_pct_of_decoder_steady']:.2f} % of decoder steady), RTF "
              f"{c['rtf_steady_before']:.3f} -> {c['rtf_steady_after']:.3f}; COLD total "
              f"{c['cold_total_cycles']:,.0f} (-{c['cold_total_saving_pct']:.1f} %), "
              f"image_bytes -> {c['image_bytes_after']:,}")
        pu = r.get("per_utterance_with_early_exit", {}).get("sets")
        if pu:
            for sn, v in pu.items():
                print(f"  per utterance ({sn}, early exit): {v['mean_steps_baseline']:.3f} -> "
                      f"{v['mean_steps_pruned']:.3f} steps (+{v['mean_steps_pct_more']:.2f} %), "
                      f"saving {v['saving_pct']:.2f} % -- against "
                      f"{v['saving_pct_if_steps_were_unchanged']:.2f} % if the step count held")
        d = r["vs_b28_deployed_fallback"]
        print(f"  vs b28 (what is deployed): STEADY -{d['steady_saving']:,.0f} "
              f"({d['steady_saving_pct_of_decoder_steady']:.2f} %), RTF "
              f"{d['rtf_steady_before']:.3f} -> {d['rtf_steady_after']:.3f}; "
              f"COLD +{d['cold_extra_image']:,.0f} image, net -{d['cold_total_saving']:,.0f}")
    print(f"\nwrote {a.json}")


if __name__ == "__main__":
    main()
