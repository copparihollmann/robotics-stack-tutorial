#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The generated-C WERs of the quant_fix.py candidates side by side, with paired intervals.

Reads what q16_fidelity.py wrote for each candidate and set (its JSON, and the per-utterance
transcripts it keeps beside the host build) and writes one record:

  per candidate, per set, per build (ref, nl):
      WER against the LibriSpeech reference and against the float encoder's transcripts, with
      utterance and word counts; C minus the float simulation (paired bootstrap, from
      q16_fidelity.py's own run)
  pairwise between candidates, on the pext_nl builds (what a board runs):
      WER(a) - WER(b) against the reference and against float, with a paired bootstrap 95 %
      interval over utterances (both systems keep each resample), and whether it includes 0
  per utterance: word edits against the reference and against float for every build, so every
      interval here can be recomputed from this file alone

Every system is scored on the SAME utterances with the SAME float transcripts (checked).

    python3 q16_compare.py --fid-dir out/q16 --json q16_results.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402

CANDS = ("R", "R3", "F3PR")
SETS = ("dev", "test")


def edits(refs, hyps):
    e, n = [], []
    for r, h in zip(refs, hyps):
        w = fq.wer([r], [h])
        e.append(w["errors"])
        n.append(w["words"])
    return np.asarray(e, dtype=np.int64), np.asarray(n, dtype=np.int64)


def boot(e_a, e_b, n, reps=2000, seed=7):
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(n), size=(reps, len(n)))
    ds = (e_a[idx].sum(1) - e_b[idx].sum(1)) / n[idx].sum(1)
    d = float(e_a.sum() - e_b.sum()) / float(n.sum())
    lo, hi = float(np.percentile(ds, 2.5)), float(np.percentile(ds, 97.5))
    return {"delta": d, "ci95": [lo, hi], "ci_includes_zero": bool(lo <= 0.0 <= hi), "resamples": reps}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fid-dir", required=True, help="where q16_fidelity_<cand>_<set>.json and the workdirs live")
    ap.add_argument("--workdir-pattern", default="final_{cand}_{set}",
                    help="q16_fidelity.py --workdir of each run, relative to --fid-dir")
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    out = {"what": "WER of ModelBlaster's GENERATED C for the quant_fix.py candidates (host builds, bit-exact "
                   "with the device by q16_gates.py), HF float decoder greedy 40 tokens; paired bootstrap 95 % "
                   "intervals over utterances. dev-clean selected; test-clean run once per candidate.",
           "sets": {}, "candidates": {}, "pairwise_nl": {}, "per_utterance": {}}
    for s in SETS:
        ids = float_txt = refs = None
        per = {}
        fj = None
        for c in CANDS:
            fj = json.load(open(os.path.join(a.fid_dir, f"q16_fidelity_{c}_{s}.json")))
            wd = os.path.join(a.fid_dir, a.workdir_pattern.format(cand=c, set=s))
            cand = out["candidates"].setdefault(c, {})
            cand.setdefault("quant_fix_key", fj.get("float_sim", {}).get("quant_fix_key"))
            row = {"utterances": fj["set"]["utterances"], "speakers": fj["set"]["speakers"],
                   "words": fj["set"]["words"],
                   "float": {"wer_vs_reference": fj["float"]["wer_vs_reference"]["wer"]},
                   "float_sim": {"wer_vs_reference": fj["float_sim"]["wer_vs_reference"]["wer"],
                                 "wer_vs_float": fj["float_sim"]["wer_vs_float"]["wer"]}}
            for build in ("ref", "nl"):
                v = fj["variants"][f"{c}_{build}"]
                t = json.load(open(os.path.join(wd, f"{c}_{build}", f"transcripts_{s}.json")))
                if ids is None:
                    ids = [u["id"] for u in t]
                    refs = [u["reference"] for u in t]
                    float_txt = [u["float"] for u in t]
                if [u["id"] for u in t] != ids or [u["float"] for u in t] != float_txt:
                    raise SystemExit(f"{c} {build} {s}: utterances or float transcripts differ from the first run")
                hyp = [u["c"] for u in t]
                e_r, n_r = edits(refs, hyp)
                e_f, n_f = edits(float_txt, hyp)
                assert int(e_r.sum()) == v["wer_vs_reference"]["errors"]
                assert int(e_f.sum()) == v["wer_vs_float"]["errors"]
                row[build] = {"wer_vs_reference": v["wer_vs_reference"]["wer"], "errors_vs_reference": int(e_r.sum()),
                              "wer_vs_float": v["wer_vs_float"]["wer"], "errors_vs_float": int(e_f.sum()),
                              "float_words": int(n_f.sum()),
                              "c_minus_float_sim": {"delta": v["minus_float_sim"]["delta_wer"],
                                                    "ci95": v["minus_float_sim"]["ci95"]},
                              "kernel_picks": v["kernel_picks"]}
                per[(c, build)] = (e_r, n_r, e_f, n_f)
                pu = out["per_utterance"].setdefault(s, {"ids": ids, "reference_words": [int(x) for x in n_r],
                                                         "float_words": [int(x) for x in n_f]})
                pu[f"{c}_{build}"] = {"edits_vs_reference": [int(x) for x in e_r],
                                      "edits_vs_float": [int(x) for x in e_f]}
            cand[s] = row
        out["sets"][s] = {"utterances": len(ids), "name": fj["set"]["name"], "words": fj["set"]["words"]}
        pw = {}
        for x, y in (("R3", "F3PR"), ("R", "F3PR"), ("R", "R3")):
            ex_r, n_r, ex_f, n_f = per[(x, "nl")]
            ey_r, _, ey_f, _ = per[(y, "nl")]
            pw[f"{x} - {y}"] = {"vs_reference": boot(ex_r, ey_r, n_r), "vs_float": boot(ex_f, ey_f, n_f)}
        out["pairwise_nl"][s] = pw
    import re  # noqa: PLC0415
    text = json.dumps(out, indent=1)
    # the per-utterance integer lists on one line each
    text = re.sub(r"\[\s*(-?\d+(?:,\s*-?\d+)*)\s*\]",
                  lambda m: "[" + ",".join(x.strip() for x in m.group(1).split(",")) + "]", text)
    with open(a.json, "w") as f:
        f.write(text + "\n")
    for s in SETS:
        print(f"\n{s}-clean <= 4 s: {out['sets'][s]['utterances']} utterances, {out['sets'][s]['words']} words")
        print(f"  {'':6s} {'float sim':>15s} {'C ref':>15s} {'C nl':>15s}   (WER % vs reference / vs float)")
        print(f"  {'float':6s} {100 * out['candidates']['R'][s]['float']['wer_vs_reference']:7.2f}")
        for c in CANDS:
            r = out["candidates"][c][s]
            g = r["nl"]["c_minus_float_sim"]
            print(f"  {c:6s} {100 * r['float_sim']['wer_vs_reference']:7.2f}/{100 * r['float_sim']['wer_vs_float']:5.2f}"
                  f"   {100 * r['ref']['wer_vs_reference']:7.2f}/{100 * r['ref']['wer_vs_float']:5.2f}"
                  f"   {100 * r['nl']['wer_vs_reference']:7.2f}/{100 * r['nl']['wer_vs_float']:5.2f}"
                  f"   nl - sim {100 * g['delta']:+.2f} [{100 * g['ci95'][0]:+.2f}, {100 * g['ci95'][1]:+.2f}]")
        for k, v in out["pairwise_nl"][s].items():
            vr, vf = v["vs_reference"], v["vs_float"]
            print(f"  {k:10s} vs ref {100 * vr['delta']:+.2f} [{100 * vr['ci95'][0]:+.2f}, {100 * vr['ci95'][1]:+.2f}]"
                  f"{' includes 0' if vr['ci_includes_zero'] else ' EXCLUDES 0'}   vs float {100 * vf['delta']:+.2f} "
                  f"[{100 * vf['ci95'][0]:+.2f}, {100 * vf['ci95'][1]:+.2f}]"
                  f"{' includes 0' if vf['ci_includes_zero'] else ' EXCLUDES 0'}")
    print(f"\nwrote {a.json}")


if __name__ == "__main__":
    main()
