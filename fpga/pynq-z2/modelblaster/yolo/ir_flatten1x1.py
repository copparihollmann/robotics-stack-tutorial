"""Lab B106 -- flatten every 1x1 stride-1 unpadded conv2d_s8 to the engine's 1-D form.

WHY THIS IS A RESHAPE AND NOT AN APPROXIMATION.  For KH = KW = 1, SH = SW = 1,
PH = PW = 0, N = 1, groups = 1, NCHW:

    out[oc][oh][ow] = bias[oc] + sum_ic in[ic][oh][ow] * w[oc][ic]

The spatial indices appear on both sides and nowhere else -- there is no window, no
stride and no padding to make (oh, ow) interact.  In NCHW, plane `ic` is a CONTIGUOUS
run of IH*IW bytes, so relabelling that run as a single axis `p in [0, IH*IW)` names the
same bytes in the same order:

    IH -> 1,  IW -> IH*IW,  OH -> 1,  OW -> OH*OW

***No buffer moves, no byte is copied and no arithmetic changes.***  What changes is that
`roccmoon_conv2d_s8_roccmoon_engine.c`'s guard -- `IH == 1 && KH == 1 && PH == 0` -- now
holds, so the dispatch reaches the decoupled engine instead of falling back to the curated
MBP convolution on hart 0.

WHAT IT DELIBERATELY DOES NOT TOUCH.  Anything with KH > 1, a stride, padding, groups > 1
or N > 1 is left exactly as it was: for those the flattening is NOT an identity (a 3x3
window crosses rows, and after flattening it would cross the row BOUNDARY instead), and
an IR pass that got that wrong would produce a wrong answer that a cycle count cannot see.
The predicate is therefore written as a whitelist, and every rejected op is reported.

The other guard terms the engine applies are checked here too -- IC % 8, the MIN_MACS
floor, the 8 MB staging limits -- not to enforce them, but so the pass can SAY how many
dispatches it expects to reach the engine.  That number is the prediction the board's
`calls_engine` counter either meets or does not.
"""
from __future__ import annotations

import argparse
import json
import shutil
import pathlib

MBXR_RT_MIN_MACS = 16384
STAGE_LIMIT = 8 << 20


def flattenable(s: dict) -> bool:
    return (s.get("N", 1) == 1 and s["KH"] == 1 and s["KW"] == 1
            and s["SH"] == 1 and s["SW"] == 1
            and s["PH"] == 0 and s["PW"] == 0
            and s.get("groups", 1) == 1
            and s.get("DH", 1) == 1 and s.get("DW", 1) == 1)


def reaches_engine(s: dict) -> bool:
    """The engine kernel's own guard, on the POST-flatten shape."""
    OW = (s["IW"] - s["KW"]) // (s["SW"] or 1) + 1
    K = s["IC"] * s["KW"]
    return (s.get("N", 1) == 1 and s["IH"] == 1 and s["KH"] == 1
            and s["PH"] == 0 and s["PW"] == 0 and s["SW"] > 0 and s["IW"] >= s["KW"]
            and (s["IC"] * s["SW"]) % 8 == 0
            and OW * K * s["OC"] >= MBXR_RT_MIN_MACS
            and s["IW"] * s["IC"] + 64 <= STAGE_LIMIT
            and OW * s["OC"] <= STAGE_LIMIT)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    src, dst = pathlib.Path(a.in_dir), pathlib.Path(a.out_dir)
    dst.mkdir(parents=True, exist_ok=True)
    for f in ("weights.npz", "io.npz"):
        shutil.copy2(src / f, dst / f)          # untouched: not one weight byte changes
    if (src / "PROVENANCE.txt").exists():
        shutil.copy2(src / "PROVENANCE.txt", dst / "PROVENANCE.txt")

    g = json.loads((src / "graph.json").read_text())
    n_flat = n_eng_before = n_eng_after = n_conv = 0
    rejected: list[tuple[str, str]] = []
    for o in g["ops"]:
        if o["op"] != "conv2d_s8":
            continue
        s = o["shape"]
        n_conv += 1
        n_eng_before += reaches_engine(s)
        if not flattenable(s):
            rejected.append((o["name"], f"{s['KH']}x{s['KW']} s{s['SH']}{s['SW']} p{s['PH']}{s['PW']}"))
            continue
        # The identity.  OH/OW are recomputed rather than copied, so a graph whose stored
        # OH/OW disagreed with its own geometry fails here instead of being propagated.
        if s["OH"] != s["IH"] or s["OW"] != s["IW"]:
            raise SystemExit(f"{o['name']}: 1x1 s1 p0 but OH/OW {s['OH']}x{s['OW']} "
                             f"!= IH/IW {s['IH']}x{s['IW']} -- refusing to flatten")
        p = s["IH"] * s["IW"]
        s["IH"], s["IW"], s["OH"], s["OW"] = 1, p, 1, p
        n_flat += 1
        n_eng_after += reaches_engine(s)

    g.setdefault("passes", []).append("b106_flatten1x1")
    (dst / "graph.json").write_text(json.dumps(g, indent=1))
    print(f"conv2d_s8 dispatches           {n_conv}")
    print(f"flattened (1x1 s1 p0)          {n_flat}")
    print(f"reach the engine guard BEFORE  {n_eng_before}")
    print(f"reach the engine guard AFTER   {n_eng_after}")
    if n_flat and n_eng_after == n_eng_before:
        raise SystemExit("the pass flattened ops and moved NOTHING onto the engine -- "
                         "either the guard model here is wrong or the shapes are.")
    from collections import Counter
    for geo, k in Counter(r[1] for r in rejected).most_common():
        print(f"  left alone: {k:3d} x {geo}")


if __name__ == "__main__":
    main()
