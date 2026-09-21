#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""R's split stem, axis by axis: the WER/stem-cycles curve (MOONSHINE_MODEL.md section 2.6).

Lab B30 measured candidate R on the board at steady encoder RTF 5.321 with **the stem 53.56 % of
it**, because R splits every stem convolution into 8 dispatches:

    2 input halves (bits.x = 16)  x  2 weight row groups (wgroups = 2)  x  2 output ranges (multi = [1, 64])

s8.13 ablated the INPUT axis only (dropping it gives 57 % WER, so it is load-bearing).  Nobody has
ablated one output range or one weight group on its own.  This file prices every intermediate
point in host float simulation -- quant_fix.build + fq.FQInterp, the same machinery s8.13 selected
its candidates with -- on the FULL 765-utterance dev-clean set, and puts the stem cycles beside
each WER so the trade is visible in both units.

**These WERs are float-simulation ESTIMATES**, as s8.12 says of every fq.py number: only generated
integer C counts as a measurement.  The point of the sweep is to find which configurations are
worth lowering to C, not to replace that step.

**Naming.** A configuration is named by what it KEEPS.  `in2.wg2.r2` is R itself; `in2.wg1.r2`
drops the weight-group axis; `in2.wg2.rC` keeps only the coarse output range; and so on.

    PYTHONPATH=$ZCS:$MOONSHINE_DIR/pylib python3 model_stemsplit.py --json model_stemsplit.json
"""
from __future__ import annotations

import argparse
import copy
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
import quant_fix as qf  # noqa: E402

STEM_MODS = ("stem.conv1", "stem.conv2", "stem.conv3")
STEM_NODES = ("stem_conv1", "stem_conv2", "stem_conv3")
# the stem activations R carries at int16; x is the encoder input, the rest are hart-0 producers
# feeding a convolution, so each of them makes its consumer's input a hi/lo pair
INPUT16 = ("x", "stem_groupnorm", "stem_gelu2", "stem_tanh", "stem_gelu3")

# Lab B30, measured: R's stem and the unsplit saving.  s2.6.1 fits these.
R_STEM_M = 393.0
UNSPLIT_SAVING_M = (260.0, 309.0)
PER_MAC_MULTIPLE_M = R_STEM_M / 4.0          # 4.00x = 2 input x 2 range, exact from the IR shapes


def configs(base: dict) -> dict:
    """Every point on the axis lattice, built by editing R's own knobs."""
    out = {}

    def mk(label, inp, wg, rng, note):
        k = copy.deepcopy(base)
        k["bits"] = {n: 16 for n in INPUT16} if inp == 2 else {}
        k["wgroups"] = {m: wg for m in STEM_MODS}
        if rng == "2":
            k["multi"] = {n: [1, 64] for n in STEM_NODES}
        elif rng == "C":
            k["multi"] = {n: [1] for n in STEM_NODES}
        elif rng == "F":
            # NOTE: this is NOT "fine only".  fq_tensor's "multi" kind ALWAYS computes the coarse
            # grid and only OVERLAYS the finer ratios where they do not saturate, so [64] is
            # bit-identical to [1, 64].  Kept in the sweep as a deliberate duplicate of R: it is
            # the control that proves the two specs are the same object, and it is why a true
            # "one finer dispatch" point needs the CLIP sweep below, not a shorter multi list.
            k["multi"] = {n: [64] for n in STEM_NODES}
        else:
            k.pop("multi", None)
        # "F" is bit-identical to "2" (see the note above), so it costs what "2" costs --
        # 2 dispatches and 2x MACs on the range axis, not 1.  Getting this wrong would have
        # credited a duplicate of R with a 196.5 M saving it does not have.
        nrange = 2 if rng in ("2", "F") else 1
        macs = (2 if inp == 2 else 1) * nrange
        disp = (2 if inp == 2 else 1) * wg * nrange
        rec = {"knobs": k, "mac_multiple": macs, "dispatches_per_conv": disp,
               "input_halves": inp, "weight_groups": wg, "ranges": rng, "note": note}
        if rng == "F":
            rec["duplicate_of"] = "in2.wg2.r2"
        out[label] = rec

    mk("in2.wg2.r2", 2, 2, "2", "candidate R itself, as section 8.13 built it")
    mk("in2.wg1.r2", 2, 1, "2", "drop the WEIGHT-GROUP axis, keep input and range")
    mk("in2.wg2.rC", 2, 2, "C", "drop one output range, keep the COARSE one (ratio 1)")
    mk("in2.wg2.rF", 2, 2, "F", "drop one output range, keep the FINE one (ratio 64)")
    mk("in2.wg1.rC", 2, 1, "C", "drop the weight group AND one range, coarse kept")
    mk("in1.wg2.r2", 1, 2, "2", "drop the INPUT split (section 8.13 measured ~57 %); the control")
    mk("in1.wg1.r1", 1, 1, "1", "unsplit stem: one dispatch per convolution")
    return out


def clip_configs(base: dict, pols=("p99.99", "p99.9", "p99", "mse")) -> dict:
    """The intermediate the axis lattice cannot express.

    Dropping an output range is not "use the finer grid" -- the multi scheme always keeps the
    coarse grid and overlays the fine one, so there is no way to ask for one finer dispatch by
    shortening the list.  The way to ask for it is a SINGLE dispatch on a CLIPPED range: choose a
    calibration percentile instead of the max, accept that the outlier channels saturate, and get
    the resolution of a fine grid for ONE dispatch.  That halves the stem's MACs on the range axis
    and is lowerable to today's engine, because it is only a different per-tensor scale."""
    out = {}
    for pol in pols:
        for wg in (2, 1):
            k = copy.deepcopy(base)
            k["bits"] = {n: 16 for n in INPUT16}
            k["wgroups"] = {m: wg for m in STEM_MODS}
            k.pop("multi", None)
            cn = dict(k.get("calib_nodes", {}))
            cn.update({n: pol for n in ("stem_conv1", "stem_conv2", "stem_conv3",
                                        "stem_gelu2", "stem_gelu3", "stem_groupnorm")})
            k["calib_nodes"] = cn
            out[f"in2.wg{wg}.clip-{pol}"] = {
                "knobs": k, "mac_multiple": 2, "dispatches_per_conv": 2 * wg,
                "input_halves": 2, "weight_groups": wg, "ranges": f"1 clipped at {pol}",
                "note": f"ONE output range on a {pol}-clipped scale instead of two dispatches"}
    return out


def qatu_configs(base: dict, pols=("p99.99", "p99.9", "max")) -> dict:
    """The UNSPLIT W8A8 deployment, swept over activation-calibration policy.

    Run with MOONSHINE_DIR pointing at the QAT checkpoint and this measures the point
    MOONSHINE_MODEL.md s2.6.3 calls "QAT, unsplit"; run it against the stock checkpoint and the
    same rows are the control -- the same graph on weights that were never trained for it, which
    separates what QAT bought from what the calibration policy bought."""
    out = {}
    for pol in pols:
        k = {"calib": pol}
        out[f"unsplit.W8A8.calib-{pol}"] = {
            "knobs": k, "mac_multiple": 1, "dispatches_per_conv": 1,
            "input_halves": 1, "weight_groups": 1, "ranges": f"1 at {pol}",
            "note": f"unsplit stem, plain per-tensor W8A8, {pol} activation calibration"}
    return out


def stem_cycles(mac_multiple: int) -> dict:
    """Section 2.6.1's fitted model: cycles are MAC-proportional, the per-dispatch term second order."""
    m = PER_MAC_MULTIPLE_M * mac_multiple
    return {"stem_M_cycles": m, "saving_vs_R_M": R_STEM_M - m,
            "encoder_M_cycles": 733.9 - R_STEM_M + m,
            "label": "DERIVED from Lab B30's measured 393.0 M stem and 260-309 M unsplit saving"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--ncal", type=int, default=64)
    ap.add_argument("--n", type=int, default=0, help="evenly spaced dev subset (0 = all 765)")
    ap.add_argument("--only", default=None, help="|-separated config labels")
    ap.add_argument("--qatu", action="store_true",
                    help="sweep the unsplit W8A8 deployment over calibration policy (use with "
                         "MOONSHINE_DIR pointing at the QAT checkpoint)")
    ap.add_argument("--clip", action="store_true",
                    help="sweep the single-dispatch clipped-range points instead of the lattice")
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = fq.device()
    M = qf.Model(dev, a.ncal)
    dec = fq.Decoder(dev, 40)

    corpus, allidx = ls.tune_set()
    idx = ls.even(allidx, a.n) if a.n else allidx
    refs = [corpus.texts[i] for i in idx]
    xs = [me.input_tensor(corpus.wav(i)).to(dev) for i in idx]
    fl = [fq.FQInterp(M.gm, {}).run(x) for x in xs]
    fl_txt = dec(fl)
    float_wer = fq.wer(refs, fl_txt)["wer"]
    print(f"[stem] dev-clean {len(idx)} utterances, {fq.wer(refs, refs)['words']} words; "
          f"float {float_wer*100:.2f} %  ({time.time()-t0:.0f} s)", flush=True)

    base = json.load(open(os.path.join(HERE, "q16_plan_R.json")))["knobs"]
    cfgs = qatu_configs(base) if a.qatu else (clip_configs(base) if a.clip else configs(base))
    if a.only:
        want = set(a.only.split("|"))
        cfgs = {k: v for k, v in cfgs.items() if k in want}

    out = {"what": __doc__.split("\n")[0],
           "method": "host float simulation (quant_fix.build + fq.FQInterp), the machinery "
                     "section 8.13 selected its candidates with.  These WERs are ESTIMATES: only "
                     "generated integer C counts as a measurement (section 8.12).",
           "set": {"name": f"dev-clean <= {me.WINDOW_S} s", "utterances": len(idx),
                   "speakers": len({corpus.speakers[i] for i in idx}),
                   "words": fq.wer(refs, refs)["words"], "subset_of_765": a.n or None},
           "bars": {"campaign_s8_13_dev": 0.0930, "user_guideline_dev": 0.085,
                    "note": "named on every row; the long QAT run's own evals are on a 256-utterance "
                            "dev SUBSET and are a third denominator, not comparable to these"},
           "float_wer_vs_reference": float_wer,
           "checkpoint_dir": str(me.moonshine_dir()),
           "cycle_model": {"R_stem_M": R_STEM_M, "unsplit_saving_measured_M": UNSPLIT_SAVING_M,
                           "per_mac_multiple_M": PER_MAC_MULTIPLE_M,
                           "encoder_steady_M": 733.9,
                           "conv2_range_asymmetry_M": {"coarse_4_dispatches": 127.2,
                                                       "fine_4_dispatches": 65.9},
                           "label": "fitted to Lab B30's measured anchors; see section 2.6.1"},
           "configs": {}}

    for label, c in cfgs.items():
        t1 = time.time()
        try:
            r, txt = None, None
            cfg, wcfg, wover, bover, pre_div, post_mul, notes = qf.build(M, c["knobs"])
            M.ws.apply(wcfg, wover, bover)
            outs = [fq.FQInterp(M.gm, cfg, pre_div=pre_div, post_mul=post_mul).run(x) for x in xs]
            M.ws.restore()
            txt = dec(outs)
            wer_ref = fq.wer(refs, txt)
            rec = {**{k: v for k, v in c.items() if k != "knobs"},
                   "wer_vs_reference": wer_ref["wer"], "errors": wer_ref["errors"],
                   "wer_vs_float": fq.wer(fl_txt, txt)["wer"],
                   "sqnr_db": fq.sqnr_db(fl, outs),
                   "delta_vs_R_points": None,
                   **stem_cycles(c["mac_multiple"]),
                   "under_campaign_bar": wer_ref["wer"] <= 0.0930,
                   "under_user_guideline": wer_ref["wer"] <= 0.085,
                   "seconds": round(time.time() - t1, 1)}
        except Exception as e:                       # a knob combination the builder refuses
            M.ws.restore()
            rec = {**{k: v for k, v in c.items() if k != "knobs"}, "error": repr(e)[:300]}
        out["configs"][label] = rec
        if "error" in rec:
            print(f"  {label:12s} ERROR {rec['error'][:90]}", flush=True)
        else:
            print(f"  {label:12s} {rec['wer_vs_reference']*100:7.2f} %  SQNR {rec['sqnr_db']:5.2f} dB  "
                  f"MACs {rec['mac_multiple']}x  disp {rec['dispatches_per_conv']}  stem "
                  f"{rec['stem_M_cycles']:6.1f} M  saves {rec['saving_vs_R_M']:6.1f} M  "
                  f"({rec['seconds']:.0f} s)", flush=True)

    R = out["configs"].get("in2.wg2.r2", {})
    if "wer_vs_reference" in R:
        for label, rec in out["configs"].items():
            if "wer_vs_reference" in rec:
                rec["delta_vs_R_points"] = 100.0 * (rec["wer_vs_reference"] - R["wer_vs_reference"])
    out["elapsed_s"] = time.time() - t0
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({out['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
