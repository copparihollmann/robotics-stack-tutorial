#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Hidden libcalls in hart 0's kernels: every call site of a libgcc soft-float (or bit-count)
routine, how often it runs in one Moonshine encoder inference, and what it costs.

The board's big core has no FPU (rv64imac) and no Zbb, so a float compare, conversion or
arithmetic -- or a __builtin_clz -- that GCC leaves inside a hot loop becomes a libcall on every
element.  ROCC_DECOUPLED.md s8.15.6 found one: the reference permute's `scale_in == scale_out`,
28.5 M instructions of __eqsf2 per inference.  This lists them all (s8.15.7).

METHOD.  count_muldiv.py's build (the generated C of one Lab B26 image, the board's flags,
MB_PEXT_HW=1) on spike -g, spike's exact PC histogram:
  * a call site is a `jal`/`call` whose target is a libgcc routine; its EXECUTIONS are the
    histogram count at that PC (exact);
  * a routine's INSTRUCTIONS are the histogram counts over its own address range (exact),
    including what it calls (e.g. __mulsf3 -> __clzdi2 is counted under __clzdi2's range, and
    __clzdi2's own call sites are listed too);
  * a site's instructions are the routine's total split in proportion to executions -- an
    ATTRIBUTION, because the per-call cost of a soft-float routine depends on its operands;
  * a site is LOOP-BORNE when it runs more often than its function is entered (entries = the
    histogram count at the function's first instruction).  Loop-borne sites are the candidates;
    whether one is hoistable is read from the kernel source, by hand, and recorded.

    python3 softfloat_audit.py --gen out/rocket_moonshine_enc_perm/enc_ew_eng_smx2_nhwc_perm/gen \
        --label perm --cflags "..." --json softfloat_audit_perm.json
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
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "check"))
import count_instructions as ci  # noqa: E402

LIB = re.compile(r"^__(add|sub|mul|div|neg|eq|ne|lt|le|gt|ge|unord|fix|fixuns|float|floatun|extend|trunc|cmp)"
                 r"(sf|df|tf|si|di|ti)[0-9a-z]*$|^__(clz|ctz|popcount|parity|bswap)(si|di)2$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--cflags", default="")
    ap.add_argument("--build-dir", default=None)
    ap.add_argument("--heap-mb", type=int, default=64)
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    d = os.path.join(a.build_dir or os.path.join(ci.ROOT, "out", "softfloat_audit"), a.label)
    os.makedirs(d, exist_ok=True)
    stub = os.path.join(d, "stdout_stub.c")
    open(stub, "w").write("#include <stdio.h>\nFILE *const stdout = 0;\n")
    elf = os.path.join(d, "icount.elf")
    extra = ["-DMB_PEXT_HW=1", "-DMB_ICOUNT_WARMUP=0"] + [f for f in a.cflags.split() if f]
    srcs = [os.path.join(ci.ICOUNT, f) for f in ("crt.S", "htif.c", "icount_main.c")] + \
           [os.path.join(a.gen, f) for f in ("model.c", "kernels.c", "weights.c", "buffers.c", "test_io.S")] + [stub]
    cmd = ([ci.CROSS + "gcc"] + ci.CFLAGS + extra + ci.EXTRA +
           [f"-I{ci.SHIM}", f"-I{a.gen}", f"-I{ci.PEXT_H_DIR}"] + srcs + ci.LDFLAGS +
           ["-T", os.path.join(ci.ICOUNT, "link.ld"), "-o", elf, "-Wl,--defsym=__heap_start=_stack_top",
            f"-Wl,--defsym=__heap_end=_stack_top+{a.heap_mb * 1024 * 1024}"] + ci.LDLIBS)
    subprocess.run(cmd, check=True, capture_output=True)

    dis = subprocess.run([ci.CROSS + "objdump", "-d", elf], text=True, capture_output=True, check=True).stdout
    func_at, func_start, sites = {}, {}, []
    cur = None
    for line in dis.splitlines():
        m = re.match(r"^([0-9a-f]+) <([^>]+)>:", line)
        if m:
            cur = m.group(2)
            func_start[cur] = int(m.group(1), 16)
            continue
        m = re.match(r"^\s+([0-9a-f]+):\s+[0-9a-f]+\s+(\S+)\s+(.*)$", line)
        if not m or cur is None:
            continue
        pc = int(m.group(1), 16)
        func_at[pc] = cur
        t = re.search(r"<([^>+]+)>", m.group(3))
        if m.group(2) in ("jal", "jalr", "call", "tail", "j", "jr") and t and LIB.match(t.group(1)):
            sites.append({"pc": pc, "caller": cur, "callee": t.group(1), "insn": m.group(2)})

    proc = subprocess.run([ci.SPIKE, "-g", elf], text=True, capture_output=True, timeout=7200)
    text = proc.stdout + proc.stderr
    hist = collections.Counter()
    tot = mism = None
    for line in text.splitlines():
        m = re.match(r"MB_ICOUNT_TOTAL instret=(\d+) output_mismatches=(\d+)", line)
        if m:
            tot, mism = int(m.group(1)), int(m.group(2))
        p = line.split()
        if len(p) == 2:
            try:
                hist[int(p[0], 16)] += int(p[1])
            except ValueError:
                pass
    if tot is None:
        raise SystemExit("spike produced no MB_ICOUNT_TOTAL:\n" + text[-2000:])

    per_func = collections.Counter()
    for pc, n in hist.items():
        per_func[func_at.get(pc, "?")] += n
    for s in sites:
        s["executions"] = hist.get(s["pc"], 0)
        s["caller_entries"] = hist.get(func_start.get(s["caller"], -1), 0)
        s["loop_borne"] = s["executions"] > max(1, s["caller_entries"])
    calls = collections.Counter()
    for s in sites:
        calls[s["callee"]] += s["executions"]
    routines = {r: per_func.get(r, 0) for r in calls}
    for s in sites:
        c = calls[s["callee"]]
        s["instructions_attributed"] = int(round(routines[s["callee"]] * s["executions"] / c)) if c else 0
        s["pc"] = hex(s["pc"])
    live = sorted([s for s in sites if s["executions"]], key=lambda s: -s["instructions_attributed"])
    out = {"what": __doc__.strip().splitlines()[0], "gen": os.path.abspath(a.gen), "label": a.label, "cflags": extra,
           "inference_instret": tot, "output_mismatches": mism,
           "routine_instructions": dict(sorted(routines.items(), key=lambda kv: -kv[1])),
           "routine_calls": dict(calls), "sites_executed": live,
           "sites_never_executed": len(sites) - len(live)}
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"{a.label}: {tot:,} instructions, output mismatches {mism}; libcall instructions "
          f"{sum(routines.values()):,} over {len(live)} executed call sites")
    for s in live[:25]:
        print(f"  {s['caller']:42s} {s['pc']:>12s} -> {s['callee']:10s} x{s['executions']:>10,} "
              f"(entries {s['caller_entries']:>8,}) ~{s['instructions_attributed']:>11,} instr"
              f"{'  LOOP' if s['loop_borne'] else ''}")
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
