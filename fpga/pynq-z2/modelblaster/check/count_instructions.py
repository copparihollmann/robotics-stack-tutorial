#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Per-dispatch dynamic instruction counts for LeNet, scalar reference vs MBP kernels.

Method, stated plainly because the number is only as good as it:

  * `minstret`, retired instructions, read by the guest itself on either side of each
    dispatch and corrected for the two counter reads.  Not a cycle count -- no bitstream
    contains the extension yet, so a cycle count does not exist and an estimate of one
    would be an estimate, not a measurement.  This is the same counter PEXT_SPEC.md
    section 5 used to size the extension in the first place.

  * spike, from third_party/riscv-isa-sim, built with patches/0006-spike-mbp-pext-insns
    so the four MBP encodings execute rather than trap.  The instructions being counted
    are therefore the REAL ones: MB_PEXT_HW=1, `.insn r 0x0b, ...` in the disassembly,
    decoded by the simulator.  (The host checks in check_bitexact.py exercise pext.h's
    software model instead; the two are bit-identical by construction and this harness
    re-checks the model output against the baked golden on every run, so a divergence
    between them would show up here as a FAIL rather than as a quietly wrong count.)

  * Zephyr SDK riscv64-zephyr-elf-gcc, -march=rv64imac_zicsr_zifencei -mabi=lp64
    -mcmodel=medany -O2 -- the exact multilib and optimisation level the board image
    uses (CONFIG_SPEED_OPTIMIZATIONS=y).

  * The two builds differ in ONE file, the generated kernels.c.  model.c, weights.c,
    buffers.c and the harness are identical, so the delta is the kernels.

Usage:
    python3 count_instructions.py [--gen-dir DIR] [--pext-gen-dir DIR] [--json OUT]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ICOUNT = os.path.join(HERE, "icount")
SHIM = os.path.join(HERE, "shim")
MBDIR = os.path.dirname(HERE)
FPGA = os.path.dirname(MBDIR)
ROOT = os.path.dirname(os.path.dirname(FPGA))
PEXT_H_DIR = os.path.join(FPGA, "sw")

CROSS = os.environ.get("CROSS_COMPILE", "riscv64-zephyr-elf-")
SPIKE = os.environ.get("TACIT_SPIKE",
                       os.path.join(ROOT, "third_party", "riscv-isa-sim",
                                    "build", "spike"))

# The board's own flags. scripts/24_rocket_modelblaster.sh's ELF gate records them and
# fpga/pynq-z2/docs/MODELBLASTER_ON_ROCKET.md quotes the compiler line that reaches
# kernels.c: -mabi=lp64 -march=rv64imac_zicsr_zifencei -mcmodel=medany, -O2.
CFLAGS = [
    "-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany", "-O2",
    "-ffreestanding", "-fno-builtin-printf", "-Wall",
    # -g is for the line table only (profile_lines.py); it changes no code.
    "-g",
]
LDFLAGS = ["-nostdlib", "-nostartfiles", "-Wl,--no-relax", "-static"]

# Libraries appended AFTER the objects, so they are searched, not linked wholesale.
#
# LeNet does not need either of these: its kernels are integer-only, which is the
# whole point of int8, and with -nostdlib the link resolved with nothing extra.
# DroNet does.  Its reference add_s8 / batchnorm2d_s8 / sigmoid_s8 dequantize to
# float -- 22 of the 43 _s8 KernelSpecs do, per MODELBLASTER_ON_ROCKET.md sect 2 --
# and on this WithoutFPU core that is libgcc soft-float (__mulsf3, __divsf3,
# __floatsisf, __fixsfsi) plus roundf and expf.  Without these the scalar
# baseline does not LINK, so the very cost we are here to measure cannot be
# measured.
#
# Note -lc, not just -lm: in this SDK's picolibc, libm.a is a stub and roundf /
# expf are defined in libc.a.  -lm is kept ahead of it so the list still reads
# correctly against a toolchain that does split them, and -lgcc goes last so it
# can satisfy libc's own soft-float references.
#
# Appending them is additive and leaves LeNet byte-identical: a searched archive
# contributes nothing when nothing references it.  Verified by re-running the
# LeNet counts after this change -- same totals.
LDLIBS = ["-lm", "-lc", "-lgcc"]

# Extra -D/-f flags for BOTH images, from the environment, so a tuning knob that
# lives in a curated kernel as `#ifndef X / #define X <default>` can be swept
# without editing the kernel.  Used to size the conv kernel's output-channel
# block (MB_PEXT_CONV_WBYTES) against DroNet's deepest layers.  Empty by default,
# so the numbers this file prints are the shipped defaults unless asked otherwise.
EXTRA = [f for f in os.environ.get("MB_EXTRA_CFLAGS", "").split() if f]


def build(build_dir: str, gen: str, label: str, extra_cflags=()) -> str:
    d = os.path.join(build_dir, label)
    os.makedirs(d, exist_ok=True)
    elf = os.path.join(d, "icount.elf")
    srcs = [
        os.path.join(ICOUNT, "crt.S"),
        os.path.join(ICOUNT, "htif.c"),
        os.path.join(ICOUNT, "icount_main.c"),
        os.path.join(gen, "model.c"),
        os.path.join(gen, "kernels.c"),
        os.path.join(gen, "weights.c"),
        os.path.join(gen, "buffers.c"),
        os.path.join(gen, "test_io.S"),
    ]
    cmd = ([CROSS + "gcc"] + CFLAGS + list(extra_cflags) + EXTRA +
           [f"-I{SHIM}", f"-I{gen}", f"-I{PEXT_H_DIR}"] +
           srcs + LDFLAGS + ["-T", os.path.join(ICOUNT, "link.ld"), "-o", elf] +
           LDLIBS)
    print("  $", " ".join(cmd[:6]), "...", f"-o {elf}")
    subprocess.run(cmd, check=True)
    return elf


def run_spike(elf: str) -> dict:
    proc = subprocess.run([SPIKE, elf], text=True, capture_output=True, timeout=1800)
    text = proc.stdout + proc.stderr
    ops = []
    total = None
    mism = None
    for line in text.splitlines():
        m = re.match(r"MB_ICOUNT_OP id=(\d+) name=(\S+) op=(\S+) shape=(\S+) "
                     r"instret=(\d+)", line)
        if m:
            ops.append({"id": int(m.group(1)), "name": m.group(2),
                        "op": m.group(3), "shape": m.group(4),
                        "instret": int(m.group(5))})
        m = re.match(r"MB_ICOUNT_TOTAL instret=(\d+) output_mismatches=(\d+)", line)
        if m:
            total, mism = int(m.group(1)), int(m.group(2))
    if total is None:
        print(text[-3000:], file=sys.stderr)
        raise SystemExit(f"spike produced no MB_ICOUNT_TOTAL for {elf}")
    return {"ops": ops, "total": total, "output_mismatches": mism, "raw": text}


def count_mbp(elf: str) -> dict:
    """How many MBP instructions the image contains, statically, by mnemonic."""
    out = subprocess.run([CROSS + "objdump", "-d", elf],
                         text=True, capture_output=True, check=True).stdout
    counts = {}
    for mn in ("dot8", "max8", "qmul", "clip8"):
        counts[mn] = len(re.findall(r"\bmbp\.%s\b" % mn, out))
    # The Zephyr SDK's objdump does not know these mnemonics; it prints them as
    # `.insn 4, 0x........`. Decode the raw words instead, which is what PEXT_SPEC.md
    # section 4 does by hand.
    if not any(counts.values()):
        counts = {"dot8": 0, "max8": 0, "qmul": 0, "clip8": 0}
        for word in re.findall(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", out, re.M):
            v = int(word, 16)
            if (v & 0x7f) == 0x0b and (v >> 25) == 0:
                f3 = (v >> 12) & 7
                counts[["dot8", "max8", "qmul", "clip8"][f3]] += 1 if f3 < 4 else 0
    return counts


MBP_MNEMONIC = ("dot8", "max8", "qmul", "clip8")


def mbp_pc_map(elf: str) -> dict:
    """{pc: mnemonic} for every MBP encoding in the image.

    Decoded from the raw instruction word rather than from a mnemonic, because the
    Zephyr SDK's objdump has never heard of these and prints them as
    `.insn 4, 0x00b5068b`.  Decode is the table in PEXT_SPEC.md section 3.0: opcode
    0x0b, funct7 0, funct3 selects the op.
    """
    out = subprocess.run([CROSS + "objdump", "-d", elf],
                         text=True, capture_output=True, check=True).stdout
    pcs = {}
    for pc, word in re.findall(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s", out, re.M):
        v = int(word, 16)
        if (v & 0x7f) == 0x0b and (v >> 25) == 0 and ((v >> 12) & 7) < 4:
            pcs[int(pc, 16)] = MBP_MNEMONIC[(v >> 12) & 7]
    return pcs


def dynamic_mix(elf: str) -> dict:
    """How often each MBP instruction actually executes in ONE inference.

    spike's `-g` PC histogram, summed over the PCs that hold an MBP encoding.  The image
    passed here is built with MB_ICOUNT_WARMUP=0 so exactly one inference runs and the
    counts are per-frame rather than per-frame-times-two.  Exact, not sampled: spike
    counts every retire.
    """
    pcs = mbp_pc_map(elf)
    proc = subprocess.run([SPIKE, "-g", elf], text=True, capture_output=True,
                          timeout=3600)
    text = proc.stdout + proc.stderr
    counts = {m: 0 for m in MBP_MNEMONIC}
    total = 0
    in_hist = False
    for line in text.splitlines():
        if line.startswith("PC Histogram size:"):
            in_hist = True
            continue
        if not in_hist:
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            pc, n = int(parts[0], 16), int(parts[1])
        except ValueError:
            continue
        total += n
        if pc in pcs:
            counts[pcs[pc]] += n
    return {"per_mnemonic": counts, "mbp_total": sum(counts.values()),
            "program_total": total}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen-dir",
                    default=os.path.join(ROOT, "out", "rocket_mb_lenet_int8",
                                         "model", "gen"))
    ap.add_argument("--pext-gen-dir",
                    default=os.path.join(ROOT, "out", "rocket_mb_lenet_int8_pext",
                                         "model", "gen"))
    ap.add_argument("--build-dir",
                    default=os.path.join(ROOT, "out", "pext_icount"))
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    if shutil.which(CROSS + "gcc") is None:
        raise SystemExit(f"{CROSS}gcc not on PATH -- source env.sh")
    if not os.path.exists(SPIKE):
        raise SystemExit(f"no spike at {SPIKE} -- run scripts/05_build_tacit_tools.sh")

    if os.path.isdir(args.build_dir):
        shutil.rmtree(args.build_dir)
    os.makedirs(args.build_dir)

    print("building scalar-reference image")
    elf_ref = build(args.build_dir, args.gen_dir, "scalar")
    print("building pext image (MB_PEXT_HW=1, real custom-0 encodings)")
    elf_pext = build(args.build_dir, args.pext_gen_dir, "pext",
                     extra_cflags=["-DMB_PEXT_HW=1"])

    static = count_mbp(elf_pext)
    static_ref = count_mbp(elf_ref)
    print(f"  static MBP instructions: pext image {static}, "
          f"scalar image {static_ref}")
    if sum(static.values()) == 0:
        raise SystemExit("the pext image contains no MBP encodings at all -- "
                         "MB_PEXT_HW did not reach kernels.c")
    if sum(static_ref.values()) != 0:
        raise SystemExit("the scalar image contains MBP encodings -- the two builds "
                         "are not what they claim to be")

    print("running both on spike")
    r_ref = run_spike(elf_ref)
    r_pext = run_spike(elf_pext)
    for label, r in (("scalar", r_ref), ("pext", r_pext)):
        if r["output_mismatches"]:
            raise SystemExit(f"{label} image produced the wrong model output "
                             f"({r['output_mismatches']} elements) -- an instruction "
                             f"count from it would be meaningless")

    by_op = {}
    print()
    print(f"{'dispatch':<8} {'op':<14} {'shape':<52} "
          f"{'scalar':>12} {'pext':>12} {'speedup':>9}")
    for a, b in zip(r_ref["ops"], r_pext["ops"]):
        assert a["name"] == b["name"], (a, b)
        sp = a["instret"] / b["instret"] if b["instret"] else float("nan")
        print(f"{a['name']:<8} {a['op']:<14} {a['shape']:<52} "
              f"{a['instret']:>12,} {b['instret']:>12,} {sp:>8.2f}x")
        by_op[a["name"]] = {"op": a["op"], "shape": a["shape"],
                            "scalar": a["instret"], "pext": b["instret"],
                            "speedup": sp}
    tot_sp = r_ref["total"] / r_pext["total"]
    print(f"{'TOTAL':<8} {'':<14} {'':<52} "
          f"{r_ref['total']:>12,} {r_pext['total']:>12,} {tot_sp:>8.2f}x")
    print()
    print("dynamic MBP mix, one inference, spike -g PC histogram")
    elf_hist = build(args.build_dir, args.pext_gen_dir, "pext_nowarmup",
                     extra_cflags=["-DMB_PEXT_HW=1", "-DMB_ICOUNT_WARMUP=0"])
    mix = dynamic_mix(elf_hist)
    for mn in MBP_MNEMONIC:
        n = mix["per_mnemonic"][mn]
        print(f"  mbp.{mn:<6} {n:>10,}   "
              f"{100.0 * n / r_pext['total']:5.2f}% of the kernels' instructions")
    print(f"  {'all four':<11} {mix['mbp_total']:>10,}   "
          f"{100.0 * mix['mbp_total'] / r_pext['total']:5.2f}%")
    print(f"  (kernel instructions {r_pext['total']:,}; whole program including "
          f"startup and the golden check {mix['program_total']:,})")

    result = {
        "method": "spike minstret, per dispatch, real MBP encodings "
                  "(patches/0006-spike-mbp-pext-insns.patch)",
        "spike": SPIKE,
        "cflags": CFLAGS,
        "per_dispatch": by_op,
        "total": {"scalar": r_ref["total"], "pext": r_pext["total"],
                  "speedup": tot_sp},
        "static_mbp_instructions": static,
        "dynamic_mbp_mix": mix,
        "output_mismatches": {"scalar": r_ref["output_mismatches"],
                              "pext": r_pext["output_mismatches"]},
    }
    if args.json:
        with open(args.json, "w") as f:
            json.dump(result, f, indent=2)
        print(f"wrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
