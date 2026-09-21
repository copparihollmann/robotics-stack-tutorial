#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""How many M-extension instructions Moonshine's encoder executes on hart 0, per kernel.

The question (ROCC_DECOUPLED.md s8.14 audit): the big Rocket core's multiplier is iterative
(WithNBigCores: MulDivParams(mulUnroll = 8, mulEarlyOut = true, divEarlyOut = true)), so every
mul/mulh costs several cycles, and nearly every hart-0 software op multiplies.  Before pricing a
faster multiplier, count the work.

METHOD.  check/count_instructions.py's bare-metal spike harness, unchanged: the generated
model.c/kernels.c/weights.c/buffers.c of one Lab B26 image, compiled with the board's own flags
(riscv64-zephyr-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2,
MB_PEXT_HW=1 so the MBP instructions are the real encodings), one inference (no warm-up), run on
spike (patched with the MBP instructions) with `-g`, spike's exact PC histogram.  Every PC that
holds an M-extension encoding is decoded from the instruction word, and its count is
attributed to the function symbol it lies in.  These are INSTRUCTION COUNTS on an instruction-set
model: exact counts of work, not cycles.

WHAT IT DOES NOT SEE.  A roccmoon image's linear/conv kernels run on the engine on the board; on
spike they take their MBP fallback.  The per-function split lets the engine case exclude them.

    python3 count_muldiv.py --gen out/rocket_moonshine_enc_smx/enc_ew_smx/gen --label ew_smx \
        --cflags "-DMB_PEXT_CONV_MAXROWS=2048 -DMB_PEXT_CONV_WBYTES=2097152" --json muldiv_ew_smx.json
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(os.path.dirname(HERE), "check")
sys.path.insert(0, CHECK)
import count_instructions as ci  # noqa: E402

# RV64M, decoded from the word: opcode 0x33 (OP) or 0x3b (OP-32), funct7 = 1.
MNEM = {(0x33, 0): "mul", (0x33, 1): "mulh", (0x33, 2): "mulhsu", (0x33, 3): "mulhu",
        (0x33, 4): "div", (0x33, 5): "divu", (0x33, 6): "rem", (0x33, 7): "remu",
        (0x3b, 0): "mulw", (0x3b, 4): "divw", (0x3b, 5): "divuw", (0x3b, 6): "remw", (0x3b, 7): "remuw"}


def m_pcs(elf: str) -> dict:
    out = subprocess.run([ci.CROSS + "objdump", "-d", elf], text=True, capture_output=True, check=True).stdout
    pcs, func = {}, None
    funcs = {}
    for line in out.splitlines():
        m = re.match(r"^([0-9a-f]+) <([^>]+)>:", line)
        if m:
            func = m.group(2)
            continue
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s", line)
        if m:
            pc, v = int(m.group(1), 16), int(m.group(2), 16)
            funcs[pc] = func
            op, f3, f7 = v & 0x7f, (v >> 12) & 7, v >> 25
            if f7 == 1 and (op, f3) in MNEM:
                pcs[pc] = MNEM[(op, f3)]
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{4})\s", line)
        if m:
            funcs[int(m.group(1), 16)] = func
    return pcs, funcs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--cflags", default="")
    ap.add_argument("--build-dir", default=None)
    ap.add_argument("--heap-mb", type=int, default=64,
                    help="heap for kernels whose host fallback allocates (the NHWC engine conv relays "
                         "through malloc off the board): picolibc's sbrk between _stack_top and +N MB")
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    bd = a.build_dir or os.path.join(ci.ROOT, "out", "moonshine_muldiv")
    os.makedirs(bd, exist_ok=True)
    extra = ["-DMB_PEXT_HW=1", "-DMB_ICOUNT_WARMUP=0"] + [f for f in a.cflags.split() if f]
    # ci.build's source list, plus a stub for picolibc's `stdout`: int_nonlin.c's host-side
    # self-test references printf, which the bare-metal harness never calls.
    d = os.path.join(bd, a.label)
    os.makedirs(d, exist_ok=True)
    stub = os.path.join(d, "stdout_stub.c")
    open(stub, "w").write("#include <stdio.h>\nFILE *const stdout = 0;\n")
    elf = os.path.join(d, "icount.elf")
    srcs = [os.path.join(ci.ICOUNT, f) for f in ("crt.S", "htif.c", "icount_main.c")] + \
           [os.path.join(a.gen, f) for f in ("model.c", "kernels.c", "weights.c", "buffers.c", "test_io.S")] + [stub]
    cmd = ([ci.CROSS + "gcc"] + ci.CFLAGS + extra + ci.EXTRA +
           [f"-I{ci.SHIM}", f"-I{a.gen}", f"-I{ci.PEXT_H_DIR}"] + srcs + ci.LDFLAGS +
           ["-T", os.path.join(ci.ICOUNT, "link.ld"), "-o", elf,
            "-Wl,--defsym=__heap_start=_stack_top",
            f"-Wl,--defsym=__heap_end=_stack_top+{a.heap_mb * 1024 * 1024}"] + ci.LDLIBS)
    subprocess.run(cmd, check=True, capture_output=True)
    pcs, funcs = m_pcs(elf)
    proc = subprocess.run([ci.SPIKE, "-g", elf], text=True, capture_output=True, timeout=7200)
    text = proc.stdout + proc.stderr
    tot = None
    for line in text.splitlines():
        m = re.match(r"MB_ICOUNT_TOTAL instret=(\d+) output_mismatches=(\d+)", line)
        if m:
            tot, mism = int(m.group(1)), int(m.group(2))
    if tot is None:
        print(text[-3000:], file=sys.stderr)
        raise SystemExit("spike produced no MB_ICOUNT_TOTAL")
    per_mn = collections.Counter()
    per_fn = collections.defaultdict(collections.Counter)
    all_fn = collections.Counter()
    program_total = 0
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            pc, n = int(parts[0], 16), int(parts[1])
        except ValueError:
            continue
        program_total += n
        fn = funcs.get(pc, "?")
        all_fn[fn] += n
        if pc in pcs:
            per_mn[pcs[pc]] += n
            per_fn[fn][pcs[pc]] += n
    ops = [dict(op) for op in []]
    out = {"what": "M-extension instruction counts per function, one Moonshine encoder inference, spike -g "
                   "(exact PC histogram) on the board's own compile flags; instruction counts, not cycles",
           "gen": os.path.abspath(a.gen), "label": a.label, "cflags": extra,
           "inference_instret": tot, "output_mismatches": mism, "histogram_total": program_total,
           "m_ext_total": sum(per_mn.values()), "per_mnemonic": dict(per_mn),
           "per_function": {f: dict(c) for f, c in sorted(per_fn.items(), key=lambda kv: -sum(kv[1].values()))},
           "instructions_per_function_top": dict(all_fn.most_common(40))}
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"{a.label}: {tot:,} instructions per inference, output mismatches {mism}; "
          f"M-extension {out['m_ext_total']:,} ({dict(per_mn)})")
    for f, c in list(out["per_function"].items())[:15]:
        print(f"  {f:48s} {sum(c.values()):>13,}  {c}")
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
