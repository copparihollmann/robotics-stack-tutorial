#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""How much the IR ladder is worth is a property of the AUDIO, not of the model.

MOONSHINE_MODEL.md section 2.4 prices the ladder on LibriSpeech's own length distribution and gets
-18 % for three rungs and -25 % for seven.  That number does not transfer: the demo's utterances
are not LibriSpeech's, and the whole saving comes from padding that a shorter window does not have
to compute.  This prices the same ladders over several length distributions so the reader can see
the range rather than one point, and so a demo whose audio is known can be priced directly.

THE COST LAW IS MEASURED, THE DISTRIBUTIONS OTHER THAN LIBRISPEECH ARE ASSUMED and labelled so.
cost(T) is fitted from model_len.json's T1 curve (itself normalised to the measured 4 s encoder),
which is quadratic in T because 43.1 % of the 4 s encoder is O(T^2) attention.  That quadratic is
also why the ladder does NOT simply add to the stem and lane savings: those shrink the linear part,
and shrinking the window shrinks the quadratic part fastest, so the two overlap.

    python3 model_ladder_dist.py [--json model_ladder_dist.json]
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SR = 16000
FRAMES_PER_S = 165 / 4.0          # ladder_rungs.py: 4.0 s -> 165 frames
LADDERS = {
    "1: no ladder (today)": [4.0],
    "3: three rungs": [2.0, 3.0, 4.0],
    "5: five rungs": [2.0, 2.5, 3.0, 3.5, 4.0],
    "7: seven rungs": [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
}


def fit_cost():
    """cost(T) = c0 + c1 T + c2 T^2, least squares over model_len.json's T1 curve."""
    d = json.load(open(os.path.join(HERE, "model_len.json")))
    rows = d["length_model"]["T1"]
    T = np.array([r["T"] for r in rows], float)
    y = np.array([r["model_seconds"] for r in rows], float)
    A = np.vstack([np.ones_like(T), T, T * T]).T
    c, *_ = np.linalg.lstsq(A, y, rcond=None)
    resid = float(np.max(np.abs(A @ c - y) / y))
    return c, resid


def price(lengths: np.ndarray, rungs: list, c) -> dict:
    """Each utterance is served by the smallest rung not shorter than it (never cropped)."""
    r = np.array(sorted(rungs), float)
    idx = np.searchsorted(r, lengths, side="left")
    idx = np.clip(idx, 0, len(r) - 1)
    win = r[idx]
    T = np.round(win * FRAMES_PER_S)
    quad = c[2] * T * T
    cost = c[0] + c[1] * T + quad
    return {"mean_encoder_s": float(cost.mean()),
            "wall_over_audio": float(cost.sum() / lengths.sum()),
            "mean_padding_s": float((win - lengths).mean()),
            # the share of what REMAINS that is O(T^2) attention.  This is why the ladder does not
            # simply add to an attention unit: the ladder eats the quadratic part fastest, so
            # whatever is left for a T^2 accelerator to remove is a smaller slice than before.
            "quadratic_share": float(quad.sum() / cost.sum()),
            "occupancy": {f"{v:.1f}": float((win == v).mean()) for v in r}}


def distributions(n=20000, seed=20260917):
    """LibriSpeech's is MEASURED; the other three are ASSUMED shapes for a demo, labelled so."""
    out = {}
    import librispeech_sets as ls
    L = []
    for name in ("dev_clean", "test_clean"):
        c = ls.Corpus(name)
        L += [int(n) / SR for n in c.lens if int(n) <= 4 * SR]
    out["LibriSpeech <= 4 s (MEASURED)"] = np.array(L, float)
    rng = np.random.default_rng(seed)
    out["short commands, mean 1.6 s (ASSUMED)"] = np.clip(rng.gamma(6.0, 0.27, n), 0.4, 4.0)
    out["mixed demo, mean 2.4 s (ASSUMED)"] = np.clip(rng.normal(2.4, 0.7, n), 0.4, 4.0)
    out["long sentences, mean 3.5 s (ASSUMED)"] = np.clip(rng.normal(3.5, 0.35, n), 0.4, 4.0)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default=os.path.join(HERE, "model_ladder_dist.json"))
    a = ap.parse_args()
    c, resid = fit_cost()
    print(f"cost(T) = {c[0]:.3f} + {c[1]:.5f} T + {c[2]:.3e} T^2 s   (max fit error {resid*100:.1f} %)")
    out = {"what": __doc__.strip().splitlines()[0], "cost_fit": list(map(float, c)),
           "cost_fit_max_error": resid, "frames_per_s": FRAMES_PER_S, "distributions": {}}
    for dname, L in distributions().items():
        base = price(L, [4.0], c)
        rec = {"n": int(L.size), "mean_audio_s": float(L.mean()), "ladders": {}}
        print(f"\n{dname}  n = {L.size}, mean audio {L.mean():.2f} s")
        print(f"  {'ladder':24s} {'mean enc s':>11s} {'wall/audio':>11s} {'vs today':>9s} {'padding s':>10s} {'T^2 left':>9s}")
        for lname, rungs in LADDERS.items():
            p = price(L, rungs, c)
            p["vs_no_ladder"] = p["mean_encoder_s"] / base["mean_encoder_s"]
            rec["ladders"][lname] = p
            print(f"  {lname:24s} {p['mean_encoder_s']:11.2f} {p['wall_over_audio']:11.2f} "
                  f"{(p['vs_no_ladder']-1)*100:+8.1f} % {p['mean_padding_s']:10.2f} "
                  f"{p['quadratic_share']*100:8.1f} %")
        out["distributions"][dname] = rec
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"\nwrote {a.json}")


if __name__ == "__main__":
    main()
