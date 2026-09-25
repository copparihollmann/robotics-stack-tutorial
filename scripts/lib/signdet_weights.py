#!/usr/bin/env python3
"""Read a lowered SignDetLite gen tree's weights manifest, for a shell `read -r`.

Prints three whitespace-separated fields on one line:

    <weights_mode> <out_scale_ppb> <replay_gate>

scripts/84_signdet_lower.sh writes signdet_weights.json into the gen tree it produces and
scripts/91_signdet_install_model.sh writes one for an installed real model.  scripts/90
reads it BEFORE it builds, so which weights are in the image is announced rather than
inferred later from a gate that disagreed.

A MISSING OR UNREADABLE MANIFEST IS 'unknown' AND 'applicable'.  That is the safe direction:
a gen tree somebody lowered themselves has no manifest, and treating it as real means the
replay gate fails loudly if the model is wrong, instead of being quietly excused.  The
fallback output scale is 7874016 ppb (1e9/127), which is what both the real model and the
random initialiser produce and what samples/signdet_live defaults to.
"""
import json
import os
import sys

DEFAULT_PPB = 7874016


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    m = {}
    if path and os.path.exists(path):
        try:
            m = json.load(open(path))
        except (ValueError, OSError):
            m = {}
    if not isinstance(m, dict):
        m = {}
    mode = str(m.get("weights_mode", "unknown")).strip() or "unknown"
    try:
        ppb = int(m.get("out_scale_ppb", DEFAULT_PPB))
    except (TypeError, ValueError):
        ppb = DEFAULT_PPB
    gate = str(m.get("replay_gate", "applicable")).strip() or "applicable"
    # One line, three fields, no spaces inside a field -- the caller is `read -r a b c`.
    print("%s %d %s" % (mode.replace(" ", "_"), ppb, gate.replace(" ", "_")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
