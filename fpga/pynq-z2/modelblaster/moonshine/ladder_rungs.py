#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Which rungs a shape ladder should have, and what each one serves.

ROCC_DECOUPLED.md s8.15.11 prices a ladder of IR builds -- same weights, different activation
shapes -- chosen by the measured audio length.  This says which rungs to build, from the audio
this tutorial actually runs and from the encoder cost MEASURED on 0x5A5A0028.

THE COST LAW IS MEASURED, THE RUNG COST IS A PREDICTION.  Of the 518,530,641-cycle steady encoder
measured at 4.0 s (Lab B26 on 0x5A5A0028, board/b28_enc_run.json), 47.8 % is O(T^2) -- the
attention matmul 37.7 % and softmax 10.1 % -- and 52.2 % is O(T).  A rung at fraction f of 4 s
therefore costs (0.522 f + 0.478 f^2) of it, and its RTF over its OWN audio is
(0.522 + 0.478 f) x 3.759.  Per-call overheads do not shrink with T, so short rungs will land
ABOVE that line; the quadratic term is the part to trust.  Nothing here is measured at any
length but 4.0 s.

An utterance is served by the SMALLEST rung not shorter than it (rounding up, never cropping),
so a ladder never changes what the model sees except by padding less.  The lengths come from the
same speech split moonshine_enc.py uses (librispeech_sets.py: LibriSpeech dev_clean and
test_clean, every utterance of 4 s or less -- the same 1,537 the model-side study reports on,
not the 16-utterance dummy split moonshine_enc.py calibrates with).

    python3 ladder_rungs.py [--json ladder_rungs.json]
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

RTF_4S = 3.759            # measured, incremental placement on, 0x5A5A0028
LIN, QUAD = 0.522, 0.478  # measured shares of the steady encoder: O(T) and O(T^2)
SR = 16000

LADDERS = {
    "1: no ladder (today)": [4.0],
    "2: two rungs": [2.5, 4.0],
    "3: three rungs": [2.0, 3.0, 4.0],
    "4: four rungs": [1.5, 2.5, 3.25, 4.0],
    "5: half-second rungs, none below 2 s": [2.0, 2.5, 3.0, 3.5, 4.0],
    "7: half-second rungs": [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
}


def rtf_of_rung(window_s: float, audio_s: float) -> float:
    """Cycles for a rung of `window_s`, divided by the utterance's OWN seconds."""
    f = window_s / 4.0
    return (LIN * f + QUAD * f * f) * RTF_4S * 4.0 / audio_s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default=os.path.join(HERE, "ladder_rungs.json"))
    a = ap.parse_args()
    import moonshine_enc as me
    import librispeech_sets as ls
    secs = []
    for name in ("dev_clean", "test_clean"):
        c = ls.Corpus(name)
        secs += [n / SR for n in c.lens]
    secs = sorted(s for s in secs if s <= 4.0)
    n = len(secs)
    out = {"what": __doc__.strip().splitlines()[0], "utterances": n,
           "rtf_4s_measured": RTF_4S, "shares": {"linear": LIN, "quadratic": QUAD},
           "audio_s": {"mean": sum(secs) / n, "p10": secs[n // 10], "p50": secs[n // 2],
                       "p90": secs[9 * n // 10], "max": secs[-1]},
           "ladders": {}}
    print("%d utterances <= 4 s; mean %.2f s, p50 %.2f, p90 %.2f"
          % (n, out["audio_s"]["mean"], out["audio_s"]["p50"], out["audio_s"]["p90"]))
    for name, rungs in LADDERS.items():
        rows, tot_rtf, pad = [], 0.0, 0.0
        for i, r in enumerate(rungs):
            lo = rungs[i - 1] if i else 0.0
            served = [s for s in secs if lo < s <= r]
            rows.append({"window_s": r, "frames": me.conv_out(me.conv_out(
                me.conv_out(int(SR * r), 127, 64), 7, 3), 3, 2),
                "utterances": len(served), "fraction": len(served) / n,
                "mean_audio_s": (sum(served) / len(served)) if served else None,
                "mean_rtf": (sum(rtf_of_rung(r, s) for s in served) / len(served)) if served else None})
            tot_rtf += sum(rtf_of_rung(r, s) for s in served)
            pad += sum(r - s for s in served)
        mean_rtf = tot_rtf / n
        base = sum(rtf_of_rung(4.0, s) for s in secs) / n
        out["ladders"][name] = {"rungs": rows, "mean_rtf": mean_rtf, "mean_padding_s": pad / n,
                                "speedup_vs_no_ladder": base / mean_rtf,
                                "image_mb_one_blob": 7.4 + 0.06 * len(rungs),
                                "image_mb_separate": 7.65 * len(rungs),
                                "build_minutes": 3 * len(rungs)}
        print("\n%s  mean RTF %.3f (%.2fx the padded %.3f), mean padding %.2f s, "
              "one image %.1f MB, build ~%d min"
              % (name, mean_rtf, base / mean_rtf, base, pad / n,
                 out["ladders"][name]["image_mb_one_blob"], out["ladders"][name]["build_minutes"]))
        for r in rows:
            print("    %4.2f s (T=%3d): %5.1f %% of utterances, mean audio %s, mean RTF %s"
                  % (r["window_s"], r["frames"], 100 * r["fraction"],
                     "%.2f s" % r["mean_audio_s"] if r["mean_audio_s"] else "-",
                     "%.3f" % r["mean_rtf"] if r["mean_rtf"] else "-"))
    json.dump(out, open(a.json, "w"), indent=1)
    print("\nwrote %s" % a.json)


if __name__ == "__main__":
    main()
