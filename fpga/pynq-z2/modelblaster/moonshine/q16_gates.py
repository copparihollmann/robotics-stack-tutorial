#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Host gates for the integer lowering of a quant_fix.py candidate (patches/0103).

  (a) golden   the generated C with REFERENCE kernels, compiled for the host (hostrun.py),
               against extract_q16's integer golden at EVERY dispatch -- the new int16 /
               per-channel / split-dispatch kinds and the stock kinds alike
  (b) kernels  the curated pext_nl kernels of the new kinds:
                 1. model data: a build with the curated NEW kinds and the REFERENCE for
                    every stock kind, against the golden at every dispatch (so the new
                    kernels see exactly their golden inputs)
                 2. q16_stress.c against each KernelSpec's reference, -O2 and again at -O1
                    under ASan+UBSan: rail codes, full int16 range, extreme multipliers,
                    constant samples, padding, and both paths of every two-path kernel
                 3. every new kernel (reference and curated) cross-compiled for the board
                    (rv64imac, -DMB_PEXT_HW=1): custom-0 encodings, soft-float and libm
                    relocations, other calls (128-bit division is libgcc's __udivti3)
  (c) deploy   the pext_nl build a board would run (curated kernels everywhere, so the
               stock drift kernels of patches/0060 too): per dispatch against the golden,
               and its output written as the host-C golden a board run must reproduce

    PYTHONPATH=zephyr-chipyard-sw python3 q16_gates.py --label R --ir IR --ref-gen G1 \\
        --cur-gen G2 --ew-gen G3 --workdir WD --json q16_gates_R.json
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hostrun  # noqa: E402

MBDIR = os.path.dirname(HERE)
KDIR = os.path.join(MBDIR, "kernels")
SW = os.path.join(os.path.dirname(MBDIR), "sw")
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
ZCS = os.environ.get("ZCS", os.path.join(ROOT, "zephyr-chipyard-sw"))
CC = os.environ.get("HOST_CC", "cc")

NEW_KINDS = ["split16_s8", "mrcombine_s16", "lut16_s16", "lut16_pc_s8", "groupnorm_s16",
             "layernorm_pc_s8", "layernorm_s16_s8", "add_pc_s8", "add_s16_pc_s8",
             "conv2d_s16_pc", "permute4_s16"]
# (op, curated file relative to kernels/)
CURATED = [
    ("add_pc_s8", "pext_nl/pext_nl_add_pc_s8_pext_int_block.c"),
    ("add_s16_pc_s8", "pext_nl/pext_nl_add_s16_pc_s8_pext_int_block.c"),
    ("mrcombine_s16", "pext_nl/pext_nl_mrcombine_s16_pext_fine_first.c"),
    ("groupnorm_s16", "pext_nl/pext_nl_groupnorm_s16_pext_int_memo.c"),
    ("conv2d_s16_pc", "pext_nl/pext_nl_conv2d_s16_pc_pext_split_dot8.c"),
]


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw)


def rk():
    try:
        import modelblaster  # noqa: F401  -- PYTHONPATH decides which checkout
    except ImportError:
        sys.path.insert(0, ZCS)
    from modelblaster.pipeline import reference_kernels
    return reference_kernels


def model_run(label, gen, ir_path, acts_npz, work, write_golden=None):
    exe = hostrun.build(gen, os.path.join(work, label))
    d = hostrun.dump(exe, gen, os.path.join(work, label, "dump.bin"))
    rows = hostrun.compare_to_golden(gen, ir_path, acts_npz, d)
    kinds = {}
    for r in rows:
        k = kinds.setdefault(r["op"], {"dispatches": 0, "elements": 0, "n_differ": 0, "max_abs_err": 0})
        k["dispatches"] += 1
        k["elements"] += r["elements"]
        k["n_differ"] += r["n_differ"]
        k["max_abs_err"] = max(k["max_abs_err"], r["max_abs_err"])
    golden = np.fromfile(os.path.join(gen, "test_golden.bin"), dtype=np.int8)
    outp = d["__output__"]
    picks = json.load(open(os.path.join(gen, "kernel_picks.json")))["picks"]
    res = {"gen": gen, "kernel_picks": {k: (v.get("algorithm") or v.get("source")) for k, v in picks.items()},
           "dispatches": len(rows), "every_dispatch_bit_exact": all(r["max_abs_err"] == 0 for r in rows),
           "first_differing_dispatch": next((r for r in rows if r["max_abs_err"]), None),
           "per_kind": kinds,
           "output_vs_golden_max_abs_err": int(np.abs(outp.astype(int) - golden.astype(int)).max()),
           "output_vs_golden_n_differ": int((outp != golden).sum()), "output_elements": int(outp.size)}
    if write_golden:
        outp.astype(np.int8).tofile(write_golden)
        res["host_c_golden"] = write_golden
    print(f"  [{label}] {len(rows)} dispatches, bit-exact at every one: {res['every_dispatch_bit_exact']}; "
          f"first differing: {(res['first_differing_dispatch'] or {}).get('name')}; output vs golden max "
          f"{res['output_vs_golden_max_abs_err']} ({res['output_vs_golden_n_differ']} of {res['output_elements']})")
    return res


def stress(work, scale):
    os.makedirs(work, exist_ok=True)
    specs = rk().KERNEL_SPECS
    ref = os.path.join(work, "q16_ref.c")
    with open(ref, "w") as f:
        f.write("/* @generated by q16_gates.py: KernelSpec.reference_impl, verbatim, renamed ref_* */\n")
        for op, _ in CURATED:
            f.write(f"#define kernel_{op} ref_kernel_{op}\n{specs[op].reference_impl}\n#undef kernel_{op}\n")
    out = {}
    for label, opt, san in (("full", "-O2", []),
                            ("san", "-O1", ["-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-g"])):
        d = os.path.join(work, label)
        os.makedirs(d, exist_ok=True)
        common = [CC, opt, "-std=gnu11", "-w", "-DMB_PEXT_HW=0", f"-I{SW}", *san]
        objs = [os.path.join(d, "ref.o")]
        sh(common + ["-c", ref, "-o", objs[0]])
        for op, rel in CURATED:
            o = os.path.join(d, f"cur_{op}.o")
            sh(common + [f"-Dkernel_{op}=cur_kernel_{op}", "-c", os.path.join(KDIR, rel), "-o", o])
            objs.append(o)
        exe = os.path.join(d, "stress")
        sh(common + [os.path.join(HERE, "q16_stress.c"), *objs, "-o", exe])
        r = subprocess.run([exe, str(scale if label == "full" else max(1, scale // 10))],
                           text=True, capture_output=True)
        m = re.search(r"RESULT cases=(\d+) mismatches=(\d+)", r.stdout)
        out[label] = {"returncode": r.returncode, "cases": int(m.group(1)) if m else None,
                      "mismatches": int(m.group(2)) if m else None,
                      "per_kernel": [l.strip() for l in r.stdout.splitlines() if "cases" in l and "RESULT" not in l],
                      "stderr_tail": r.stderr[-2000:]}
        print(f"  stress {label}: rc={r.returncode} {m.group(0) if m else r.stderr[-300:]}")
    return out


def objects(work):
    gcc = (glob.glob(os.path.join(ROOT, "zephyr-chipyard-sw", "tools-manual", "**", "riscv64-zephyr-elf-gcc"),
                     recursive=True)
           + glob.glob(os.path.join(os.environ.get("ZEPHYR_SDK_INSTALL_DIR", "/nonexistent"),
                                    "**", "riscv64-zephyr-elf-gcc"), recursive=True))
    if not gcc:
        return [{"error": "riscv64-zephyr-elf-gcc not found"}]
    gcc = gcc[0]
    objdump = gcc[:-3] + "objdump"
    specs = rk().KERNEL_SPECS
    os.makedirs(work, exist_ok=True)
    srcs = [(op, "reference", None) for op in NEW_KINDS] + [(op, "curated", rel) for op, rel in CURATED]
    out = []
    for op, what, rel in srcs:
        src = os.path.join(KDIR, rel) if rel else os.path.join(work, f"ref_{op}.c")
        if not rel:
            open(src, "w").write(specs[op].reference_impl)
        obj = os.path.join(work, f"{what}_{op}.o")
        sh([gcc, "-O2", "-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany",
            "-DMB_PEXT_HW=1", f"-I{SW}", "-c", src, "-o", obj])
        dis = sh([objdump, "-dr", obj]).stdout
        words = re.findall(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", dis, re.M)
        c0 = sum(1 for w in words if (int(w, 16) & 0x7f) == 0x0b)
        relocs = re.findall(r"R_RISCV_CALL\S*\s+(\S+)", dis)
        sf = sorted({r for r in relocs if re.match(r"__(add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)\w*(sf|df)\w*$", r)})
        lm = sorted({r for r in relocs if re.match(r"(exp|erf|log|sqrt|tanh|pow|round|lrint)f?$", r)})
        other = sorted(set(relocs) - set(sf) - set(lm))
        out.append({"op": op, "kernel": rel or "KernelSpec.reference_impl", "custom0_encodings": c0,
                    "softfloat_symbols": sf, "libm_symbols": lm, "other_calls": other})
        print(f"  {what:9s} {op:17s} custom-0={c0:3d} soft-float={sf} libm={lm} other={other}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--ir", required=True)
    ap.add_argument("--acts", default=None, help="default: IR/acts.npz")
    ap.add_argument("--ref-gen", required=True)
    ap.add_argument("--cur-gen", required=True)
    ap.add_argument("--ew-gen", default=None)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--stress-scale", type=int, default=20)
    ap.add_argument("--skip-stress", action="store_true")
    a = ap.parse_args()
    for k in ("ir", "acts", "ref_gen", "cur_gen", "ew_gen", "workdir", "json"):
        if getattr(a, k):
            setattr(a, k, os.path.abspath(getattr(a, k)))      # hostrun builds with cwd = the gen dir
    ir_path = os.path.join(a.ir, "graph.json")
    acts = a.acts or os.path.join(a.ir, "acts.npz")
    ir = json.load(open(ir_path))
    out = {"what": "host gates, patches/0103 lowering of a quant_fix.py candidate",
           "label": a.label, "q16_plan": ir.get("q16_plan"), "ir": a.ir,
           "ops": len(ir["ops"]), "dispatches": len(ir["dispatches"])}
    print(f"(a) reference build vs golden")
    out["a_reference_vs_golden"] = model_run("ref", a.ref_gen, ir_path, acts, a.workdir)
    print(f"(b)1 curated new kinds, reference stock kinds, vs golden")
    cur = model_run("cur", a.cur_gen, ir_path, acts, a.workdir)
    new_used = sorted(k for k in cur["kernel_picks"] if k in NEW_KINDS)
    cur["curated_new_kinds_picked"] = {k: cur["kernel_picks"][k] for k in new_used}
    out["b1_curated_new_kinds_vs_golden"] = cur
    if not a.skip_stress:
        print(f"(b)2 stress")
        out["b2_stress"] = stress(os.path.join(a.workdir, "stress"), a.stress_scale)
    print(f"(b)3 objects")
    out["b3_objects"] = objects(os.path.join(a.workdir, "objects"))
    if a.ew_gen:
        print(f"(c) deploy build (pext_nl, curated everywhere)")
        out["c_deploy_pext_nl"] = model_run("ew", a.ew_gen, ir_path, acts, a.workdir,
                                            write_golden=os.path.join(a.workdir, f"host_c_golden_{a.label}_ew.bin"))
    ok = (out["a_reference_vs_golden"]["every_dispatch_bit_exact"]
          and out["b1_curated_new_kinds_vs_golden"]["every_dispatch_bit_exact"]
          and all(v.get("mismatches") == 0 and v.get("returncode") == 0
                  for v in out.get("b2_stress", {}).values())
          and all(not o.get("error") and not o.get("softfloat_symbols") and not o.get("libm_symbols")
                  for o in out["b3_objects"]))
    out["pass"] = bool(ok)
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"{'PASS' if ok else 'FAIL'} -> {a.json}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
