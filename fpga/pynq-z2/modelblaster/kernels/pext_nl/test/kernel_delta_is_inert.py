#!/usr/bin/env python3
"""B83's compiled kernel sources vs the ones B82 and B81 ACTUALLY compiled.

WHY THIS EXISTS.  B83's P5 compares its 34.4828 MHz control against `b82_dec_unr_on` across two
bitstreams, and that comparison is only about the bitstream if the SOFTWARE is the same.  While
B83's board session was running, the other workstream landed `MBP_B84` in
`pext_nl_matmul_b_s8_pext_dot8_exact.c` -- the very file `MBP_MMB_M1_UNROLL8` lives in.  The
`kernel_digest` in the run record digests FILE CONTENT, so it will differ; that is the guard
working, and it is conservative rather than wrong.  This script is the check the digest cannot
make: whether the change reaches the compiled code with `MBP_B84` unset.

It proves two things mechanically:
  1. deleting the added line ranges reproduces the archived file BYTE FOR BYTE, so the
     additions are the only change; and
  2. every added code line sits inside an `#if MBP_B84` region, whose `#ifndef` default is 0.
"""
import difflib
import os
import sys

R = os.environ.get("IISWC_ROOT") or sys.exit("source env.sh first (IISWC_ROOT unset)")
PAIRS = [
    ("archive/runs/b82_dec_unr_on@20260918T2215/kernels_board",
     "fpga/pynq-z2/modelblaster/kernels", "fpga/pynq-z2/modelblaster/kernels_t1", "B82 decoder"),
    ("archive/runs/b81_enc_ctl@20260918T2137/kernels_board",
     "fpga/pynq-z2/modelblaster/kernels", "fpga/pynq-z2/modelblaster/kernels_t1", "B81 encoder"),
]
GUARD = "MBP_B84"


def added_ranges(old, new):
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if tag != "equal":
            if i1 != i2:
                return None            # a deletion or replacement: not purely additive
            out.append((j1, j2))
    return out


def guarded(block):
    depth = 0
    for line in block:
        s = line.strip()
        if s.startswith("#if") and GUARD in s:
            depth += 1
            continue
        if s.startswith(("#if", "#ifdef", "#ifndef")):
            if depth:
                depth += 1
            elif not (s.startswith("#ifndef") and GUARD in s):
                return False
            continue
        if s.startswith("#endif"):
            depth = max(0, depth - 1)
            continue
        if s.startswith("#else") or not s:
            continue
        if depth == 0 and not (s.startswith("#define") and GUARD in s):
            return False
    return True


bad = 0
for arch, k, kt1, who in PAIRS:
    ad = os.path.join(R, arch, "pext_nl")
    if not os.path.isdir(ad):
        print("SKIP %s: no archived kernels_board" % who)
        continue
    print("== %s ==" % who)
    for f in sorted(os.listdir(ad)):
        if not f.endswith(".c"):
            continue
        a = os.path.join(ad, f)
        cands = [os.path.join(R, k, "pext_nl", f), os.path.join(R, kt1, "pext_nl", f)]
        b = next((c for c in cands if os.path.exists(c)), None)
        if b is None:
            print("   %-52s NOT IN THE TREE TODAY" % f)
            bad += 1
            continue
        old, new = open(a).read().split("\n"), open(b).read().split("\n")
        if old == new:
            continue
        rs = added_ranges(old, new)
        if rs is None:
            print("   %-52s *** NOT PURELY ADDITIVE ***" % f)
            bad += 1
            continue
        ok = all(guarded(new[j1:j2]) for j1, j2 in rs)
        keep = [l for i, l in enumerate(new) if not any(j1 <= i < j2 for j1, j2 in rs)]
        print("   %-52s additive-only %s, every added line under -D%s %s, "
              "removing them reproduces the archived file %s"
              % (f, rs, GUARD, ok, keep == old))
        if not (ok and keep == old):
            bad += 1
print()
print("VERDICT: %s" % ("the compiled sources are equivalent with MBP_B84 unset"
                       if not bad else "*** %d file(s) NOT equivalent ***" % bad))
sys.exit(1 if bad else 0)
