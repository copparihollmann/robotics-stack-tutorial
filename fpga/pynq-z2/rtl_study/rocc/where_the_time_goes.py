#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""What is left of the LeNet MBP kernel stream, by category.

PEXT_KERNELS.md section 4 gives the profile by FUNCTION -- mb_pext_conv_pixel 59.0 %,
mb_pext_conv_gather 21.7 %, and so on.  That is the right granularity for "is the
gather worth attacking"; it is the wrong granularity for "would a co-processor help",
because 59 % of the stream sitting in one function says nothing about whether that
function is arithmetic, address arithmetic, or a call frame.

This splits it by SOURCE LINE and buckets the lines, reusing
modelblaster/check/profile_lines.py's exact machinery: spike's -g PC histogram (every
retire, not sampled) joined to objdump -dl's line table.  Nothing is estimated and
nothing is written; it re-runs the same ELF the instruction counts came from.

    PATH=<zephyr-sdk>/gnu/riscv64-zephyr-elf/bin:$PATH python3 where_the_time_goes.py

Line ranges below are the ones kernels.c has in out/rocket_mb_lenet_int8_pext/model/gen
for the LeNet build; they are re-derived, not memorised, if that file is regenerated --
check them against the source before trusting a changed number.
"""
from __future__ import annotations
import collections, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "fpga", "pynq-z2", "modelblaster", "check"))
from profile_lines import pc_to_line, histogram          # noqa: E402

ELF = os.environ.get("MBX_ELF",
                     os.path.join(ROOT, "out", "pext_icount", "pext_nowarmup", "icount.elf"))

KERNEL_FNS = ("mb_pext_conv_pixel", "mb_pext_conv_gather", "kernel_conv2d_s8_lenet",
              "mb_pext_lin_dot4", "mb_pext_lin_dot1", "kernel_linear_s8_lenet",
              "kernel_maxpool2d_s8_lenet", "dispatch_lenet")

# pext.h line -> which MBP instruction the `.insn` on that line is
PEXT_H = {179: "MBP dot8 + the weight ld on the same line",
          187: "MBP max8",
          195: "MBP qmul",
          204: "MBP clip8",
          215: "MBP relu (max8 against x0)"}


def bucket(fname: str, line: int, fn: str) -> str:
    base = fn.split(".")[0]
    if fname == "pext.h":
        return PEXT_H.get(line, "pext.h line %d" % line)
    if base == "mb_pext_conv_gather":
        return "conv: patch gather"
    if base == "mb_pext_conv_pixel":
        if 313 <= line <= 321 or 343 <= line <= 349 or 366 <= line <= 370:
            return "conv: MAC loop operand/accumulate/control"
        if 322 <= line <= 335 or 350 <= line <= 359 or 371 <= line <= 374:
            return "conv: output stage, scalar glue"
        return "conv: per-pixel and per-block setup"
    if base == "kernel_conv2d_s8_lenet":
        if 389 <= line <= 427:
            return "conv: weight repack, once per dispatch"
        if 471 <= line <= 495:
            return "conv: row and pixel driver loops"
        return "conv: dispatch setup"
    if base in ("mb_pext_lin_dot4", "mb_pext_lin_dot1"):
        return "linear: MAC loop"
    if base == "kernel_linear_s8_lenet":
        return "linear: driver, shifted copy, output"
    if base == "kernel_maxpool2d_s8_lenet":
        return "maxpool (whole kernel)"
    return "dispatch wrappers"


def main() -> int:
    pcs = pc_to_line(ELF)
    hist = histogram(ELF)
    by_bucket, by_fn, by_line = collections.Counter(), collections.Counter(), collections.Counter()
    total = 0
    for pc, n in hist.items():
        f, ln, fn = pcs.get(pc, ("?", 0, "?"))
        base = fn.split(".")[0]
        if not any(base.startswith(k) for k in KERNEL_FNS):
            continue                       # htif_puts, _start, the golden check
        total += n
        by_bucket[bucket(os.path.basename(f), ln, fn)] += n
        by_fn[base] += n
        by_line[(os.path.basename(f), ln, base)] += n

    print(f"elf: {ELF}")
    print(f"kernel instructions attributed: {total:,}\n")
    print("by category")
    for c, n in by_bucket.most_common():
        print(f"  {n:>8,}  {100.0*n/total:6.2f}%  {c}")
    print("\nby function (cross-check against PEXT_KERNELS.md section 4)")
    for fn, n in by_fn.most_common(8):
        print(f"  {n:>8,}  {100.0*n/total:6.2f}%  {fn}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
