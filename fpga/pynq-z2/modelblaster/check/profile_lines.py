#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Where the instructions actually go, per source line.

spike's `-g` PC histogram is exact -- it counts every retire, it does not sample -- and
`objdump -dl` maps every PC to the source line it came from.  Joining the two gives a
profile with no estimation anywhere in it, which is what "iterate on performance
honestly" needs: the first version of the conv kernel looked like it should be bound by
DOT8 and was in fact bound by register spills, and no amount of reading the C would have
said so.

-g is added to the build for the line table only; it changes no code.

Usage:
    python3 profile_lines.py [--elf ELF] [--top N] [--filter SUBSTRING]
"""

from __future__ import annotations

import argparse
import collections
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
CROSS = os.environ.get("CROSS_COMPILE", "riscv64-zephyr-elf-")
SPIKE = os.environ.get("TACIT_SPIKE",
                       os.path.join(ROOT, "third_party", "riscv-isa-sim",
                                    "build", "spike"))


def pc_to_line(elf: str):
    """{pc: (file, line, function)} from objdump -dl."""
    out = subprocess.run([CROSS + "objdump", "-dl", elf],
                         text=True, capture_output=True, check=True).stdout
    cur_file, cur_line, cur_fn = "?", 0, "?"
    m = {}
    for line in out.splitlines():
        fm = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if fm:
            cur_fn = fm.group(1)
            continue
        lm = re.match(r"^(/\S+|\S+\.[ch]):(\d+)", line)
        if lm:
            cur_file, cur_line = lm.group(1), int(lm.group(2))
            continue
        im = re.match(r"^\s+([0-9a-f]+):\s+[0-9a-f]+", line)
        if im:
            m[int(im.group(1), 16)] = (cur_file, cur_line, cur_fn)
    return m


def histogram(elf: str):
    proc = subprocess.run([SPIKE, "-g", elf], text=True, capture_output=True,
                          timeout=3600)
    text = proc.stdout + proc.stderr
    hist = {}
    seen = False
    for line in text.splitlines():
        if line.startswith("PC Histogram size:"):
            seen = True
            continue
        if not seen:
            continue
        parts = line.split()
        if len(parts) == 2:
            try:
                hist[int(parts[0], 16)] = int(parts[1])
            except ValueError:
                pass
    if not hist:
        print(text[-2000:], file=sys.stderr)
        raise SystemExit("spike produced no histogram -- is it built with -g support?")
    return hist


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--elf", default=os.path.join(ROOT, "out", "pext_icount",
                                                  "pext_nowarmup", "icount.elf"))
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--filter", default=None,
                    help="only show lines whose file path contains this")
    args = ap.parse_args()

    pcs = pc_to_line(args.elf)
    hist = histogram(args.elf)

    by_fn = collections.Counter()
    by_line = collections.Counter()
    total = 0
    for pc, n in hist.items():
        total += n
        f, ln, fn = pcs.get(pc, ("?", 0, "?"))
        by_fn[fn] += n
        by_line[(os.path.basename(f), ln, fn)] += n

    print(f"total retired: {total:,}   elf: {args.elf}")
    print()
    print("by function")
    for fn, n in by_fn.most_common(15):
        print(f"  {n:>12,}  {100.0*n/total:5.1f}%  {fn}")
    print()
    print(f"by source line (top {args.top})")
    for (f, ln, fn), n in by_line.most_common(200):
        if args.filter and args.filter not in f:
            continue
        print(f"  {n:>12,}  {100.0*n/total:5.1f}%  {f}:{ln}  [{fn}]")
        args.top -= 1
        if args.top <= 0:
            break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
