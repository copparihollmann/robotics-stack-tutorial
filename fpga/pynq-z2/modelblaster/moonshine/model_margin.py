#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Can candidate R's 8.46 % carry a programme-level goal whose bound is 8.5 %?

`TODO.md`'s standing goal (commit 45b970e) is RTF_e2e < 1.0 for a model that transcribes, at
**WER <= 8.5 % on dev-clean, the full 765-utterance set**.  Candidate R measures **8.46 %** there
(ROCC_DECOUPLED.md s8.13, the pext_nl build).  It clears by **0.04 points**.  This file asks
whether that margin means anything, three ways, using the per-utterance edit counts
q16_results.json already carries -- so nothing is re-run and nothing is re-decoded.

  1. EXACTLY, on the fixed set.  The bound is defined on 765 named utterances, so the question
     "does R clear it" has no sampling error at all: count the word errors and compare.  What the
     count does tell you is how FRAGILE the margin is -- how many additional word errors, out of
     5,944 reference words, would put the model over the bound.
  2. AS AN ESTIMATE of accuracy on speech like dev-clean, which is what a programme goal is
     really asserting.  Bootstrap over utterances (the same resampling q16_fidelity.py uses for
     its paired intervals) and ask what fraction of resamples land above the bound.
  3. AGAINST THINGS THAT ARE NOT THE MODEL.  s8.13 measured the SAME candidate twice, built with
     reference kernels and with the curated ones: R_ref against R_nl.  That difference is a
     build choice, not a model change, and if it is bigger than the margin then the margin is
     not a property of the model at all.

    python3 model_margin.py --json model_margin.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

BOUND = 0.085           # TODO.md's standing goal, dev-clean
REPS = 20000
SEED = 20260917


def load():
    with open(os.path.join(HERE, "q16_results.json")) as f:
        return json.load(f)["per_utterance"]


def boot(edits: np.ndarray, words: np.ndarray, reps=REPS, seed=SEED) -> dict:
    """Bootstrap the ABSOLUTE WER over utterances: resample utterances with replacement and
    recompute sum(edits)/sum(words), which is how a word error rate is actually formed."""
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(words), size=(reps, len(words)))
    w = edits[idx].sum(1) / words[idx].sum(1)
    return {"wer": float(edits.sum() / words.sum()),
            "ci95": [float(np.percentile(w, 2.5)), float(np.percentile(w, 97.5))],
            "se": float(w.std(ddof=1)),
            "p_above_bound": float((w > BOUND).mean()),
            "resamples": reps}


def fragility(edits: np.ndarray, words: np.ndarray) -> dict:
    """How many extra word errors, out of the whole set, would put this model over the bound --
    and how many fewer would be needed if it were already over."""
    e, n = int(edits.sum()), int(words.sum())
    need = int(np.floor(BOUND * n)) + 1          # the first integer error count that EXCEEDS it
    return {"errors": e, "reference_words": n, "wer": e / n,
            "errors_at_the_bound": BOUND * n,
            "first_error_count_over_the_bound": need,
            "extra_word_errors_to_cross": need - e,
            "utterances_that_would_have_to_change": None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    pu = load()
    out = {"what": __doc__.split("\n")[0],
           "bound": BOUND,
           "bound_source": "TODO.md standing goal, commit 45b970e: RTF_e2e < 1.0 for a model that "
                           "transcribes, WER <= 8.5 % on dev-clean, the full 765-utterance set",
           "source_record": "q16_results.json per_utterance (ROCC_DECOUPLED.md s8.13); nothing "
                            "re-run here, only re-analysed",
           "method": {"1_exact": "the bound is on a FIXED set, so clearing it has no sampling "
                                 "error; what is reported is fragility in word errors",
                      "2_bootstrap": "resample utterances with replacement, recompute "
                                     "sum(edits)/sum(words); the same resampling q16_fidelity.py "
                                     "uses for its paired intervals",
                      "3_build": "R_ref against R_nl is the SAME candidate built with reference "
                                 "kernels and with the curated ones -- a build choice, not a model"},
           "sets": {}}

    for sname in ("dev", "test"):
        s = pu[sname]
        words = np.asarray(s["reference_words"], dtype=np.int64)
        rec = {"utterances": len(words), "reference_words": int(words.sum()), "candidates": {}}
        for cand in sorted(k for k in s if k.endswith(("_ref", "_nl"))):
            e = np.asarray(s[cand]["edits_vs_reference"], dtype=np.int64)
            r = boot(e, words)
            r.update(fragility(e, words))
            r["margin_to_bound_points"] = 100.0 * (BOUND - r["wer"])
            r["margin_in_bootstrap_se"] = (BOUND - r["wer"]) / max(r["se"], 1e-12)
            rec["candidates"][cand] = r
        # the build effect: same candidate, two kernel selections, paired over utterances
        rng = np.random.default_rng(SEED + 1)
        idx = rng.integers(0, len(words), size=(REPS, len(words)))
        for base in ("R", "R3", "F3PR"):
            kr, kn = f"{base}_ref", f"{base}_nl"
            if kr not in s or kn not in s:
                continue
            er = np.asarray(s[kr]["edits_vs_reference"], dtype=np.int64)
            en = np.asarray(s[kn]["edits_vs_reference"], dtype=np.int64)
            d = (en[idx].sum(1) - er[idx].sum(1)) / words[idx].sum(1)
            rec.setdefault("build_effect_nl_minus_ref", {})[base] = {
                "delta_wer_points": 100.0 * float((en.sum() - er.sum()) / words.sum()),
                "ci95_points": [100.0 * float(np.percentile(d, 2.5)),
                                100.0 * float(np.percentile(d, 97.5))],
                "what_changed": "which kernels the build selects; the model and its weights are "
                                "identical"}
        out["sets"][sname] = rec

    # R with beam 2, from the 2x2 this workstream measured (aggregates only; the paired interval
    # on the beam's own effect is what bounds it)
    try:
        cd = json.load(open(os.path.join(HERE, "model_compose_dev.json")))
        R = cd["encoders"]["R"]
        out["r_with_beam2_dev"] = {
            "greedy_full_vocabulary": R["cells"]["base"]["wer"],
            "beam2_full_vocabulary": R["cells"]["beam"]["wer"],
            "beam2_pruned_16384": R["cells"]["both"]["wer"],
            "beam_delta": R["delta_beam"],
            "margin_to_bound_points_beam2": 100.0 * (BOUND - R["cells"]["beam"]["wer"]),
            "margin_to_bound_points_beam2_pruned": 100.0 * (BOUND - R["cells"]["both"]["wer"]),
            "worst_case_margin_at_the_beam_intervals_pessimistic_end": 100.0 * (
                BOUND - (R["cells"]["base"]["wer"] + R["delta_beam"]["ci95"][1])),
            "source": "model_compose_dev.json, MOONSHINE_MODEL.md s4.3",
            "note": "beam 2 costs decoder RTF, not encoder RTF, so it buys accuracy margin out of "
                    "a budget the stem argument does not compete for"}
    except Exception as e:         # pragma: no cover
        out["r_with_beam2_dev"] = {"unavailable": str(e)}

    json.dump(out, open(a.json, "w"), indent=1)
    for sname, rec in out["sets"].items():
        print(f"=== {sname}: {rec['utterances']} utterances, {rec['reference_words']} words, "
              f"bound {BOUND*100:.1f} %")
        for c, r in rec["candidates"].items():
            print(f"  {c:10s} {r['wer']*100:6.2f} %  [{r['ci95'][0]*100:.2f}, {r['ci95'][1]*100:.2f}]"
                  f"  SE {r['se']*100:.2f}  margin {r['margin_to_bound_points']:+.2f} pts "
                  f"= {r['margin_in_bootstrap_se']:+.2f} SE   P(over bound) {r['p_above_bound']*100:5.1f} %"
                  f"   {r['errors']} errors, {r['extra_word_errors_to_cross']} more would cross")
        for b, d in rec.get("build_effect_nl_minus_ref", {}).items():
            print(f"  build {b:5s} nl - ref {d['delta_wer_points']:+.2f} pts "
                  f"[{d['ci95_points'][0]:+.2f}, {d['ci95_points'][1]:+.2f}]")
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
