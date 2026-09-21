#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Host gates for Moonshine's encoder on ModelBlaster (no board, no simulator).

  (a) golden   the generated C with ModelBlaster's REFERENCE kernels, compiled for the host,
               against the Python int8 golden (extract_graph's simulator, run with
               MB_INT8_GOLDEN_C_FLOAT=1 and MB_INT8_DUMP_ACTIVATIONS) at EVERY dispatch
  (b) kernels  the curated pext_nl kernels, check_bitexact-style:
                 1. ModelBlaster's own host verify (pipeline/verify_kernel.py) at atol 0
                 2. stress_moonshine.c at -O2 with full enumerations, and again at -O1
                    under ASan+UBSan with misaligned buffers: every int8 operand pair at
                    random, adversarial and tie-heavy scales, every accumulator value for
                    the matmul requantise, fexact32.h against the host FPU
                 3. model data: every dispatch of the kinds below run on its GOLDEN input
                    through the reference and through the curated kernel, compared
                 4. whole model: each variant's generated C end to end, every intermediate
                    against the golden, plus the slow-path counts of the exact kernels;
                    the variant's output is written as its host-C golden for the board
               and, per new kernel, the object file cross-compiled for the board
               (rv64imac, -DMB_PEXT_HW=1): custom-0 encodings, soft-float and libm
               relocations -- "no float instruction executes" checked, not asserted.

    python3 check_moonshine.py --ir IR_DIR --acts ACTS.npz --ref-gen DIR \
        --variant nl:GEN_DIR --variant ew:GEN_DIR --workdir DIR --json host_gates.json
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import struct
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

# (op, curated file relative to kernels/, accuracy class claimed)
CURATED = [
    ("tanh_s8", "pext/pext_tanh_s8_pext_memo_lut.c", "bit_exact"),
    ("add_s8", "pext_nl/pext_nl_add_s8_pext_int_add.c", "bit_exact"),
    ("mul_s8", "pext_nl/pext_nl_mul_s8_pext_int_mul.c", "bit_exact"),
    ("rope_s8", "pext_nl/pext_nl_rope_s8_pext_int_rot.c", "bit_exact"),
    ("matmul_b_s8", "pext_nl/pext_nl_matmul_b_s8_pext_dot8_exact.c", "bit_exact"),
    ("groupnorm_s8", "pext_nl/pext_nl_groupnorm_s8_pext_int_rsqrt.c", "numeric_drift"),
    # already registered by patches/0060; in the stress TU for the model-data comparison
    ("gelu_s8", "pext_nl/pext_nl_gelu_s8_pext_int_lut.c", "numeric_drift"),
    ("layernorm_s8", "pext_nl/pext_nl_layernorm_s8_pext_int_rsqrt.c", "numeric_drift"),
    ("softmax_s8", "pext_nl/pext_nl_softmax_s8_pext_int_row.c", "numeric_drift"),
]
KIND = {"tanh_s8": 1, "groupnorm_s8": 2, "rope_s8": 3, "add_s8": 4, "matmul_b_s8": 5,
        "gelu_s8": 6, "layernorm_s8": 7, "softmax_s8": 8}


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw)


def rk():
    try:
        import modelblaster  # noqa: F401  -- PYTHONPATH decides which checkout
    except ImportError:
        sys.path.insert(0, ZCS)
    from modelblaster.pipeline import reference_kernels
    return reference_kernels


# ---------------------------------------------------------------------------- (b)1
def pipeline_verify() -> list:
    from modelblaster.pipeline.verify_kernel import verify
    os.environ["CPATH"] = SW + (os.pathsep + os.environ["CPATH"] if os.environ.get("CPATH") else "")
    specs = rk().KERNEL_SPECS
    out = []
    for op, rel, cls in CURATED[:6]:
        spec = specs[op]
        src = open(os.path.join(KDIR, rel)).read()
        if op == "matmul_b_s8":
            # its KernelSpec (from the export path) declares placeholder argtypes and
            # "host-verify disabled"; the stress and model-data checks below cover it
            out.append({"op": op, "kernel": rel, "claimed": cls, "ok_at_atol0": None,
                        "message": "host-verify disabled in KernelSpec; see b2/b3"})
            continue
        res = verify(spec, src, spec.extra_shapes, n_trials=5, atol=0.0, rtol=0.0, seed=11)
        out.append({"op": op, "kernel": rel, "claimed": cls, "ok_at_atol0": bool(res.ok),
                    "max_abs_err": res.max_abs_err, "message": res.message.splitlines()[0]})
        print(f"  verify_kernel {op:13s} atol=0 {'PASS' if res.ok else 'FAIL'}  "
              f"{res.message.splitlines()[0][:110]}")
    return out


# ---------------------------------------------------------------------------- (b)2
def build_stress(work: str) -> dict:
    os.makedirs(work, exist_ok=True)
    specs = rk().KERNEL_SPECS
    ops = [c[0] for c in CURATED]
    ref = os.path.join(work, "ref_kernels.c")
    with open(ref, "w") as f:
        f.write("/* @generated: ModelBlaster KernelSpec.reference_impl, verbatim */\n"
                "#include <stddef.h>\n#include <stdint.h>\n#include <float.h>\n#include <math.h>\n")
        for op in ops:
            f.write(specs[op].reference_impl + "\n")
    # Two candidate TUs.  The kernels patches/0100 adds are compiled with the full UBSan
    # set.  The ones that include int_nonlin.c (patches/0060's GELU / layer norm / softmax,
    # and the group norm here, which reuses its helpers) are one TU -- int_nonlin.c defines
    # globals and may be included once per link -- and that TU is ALSO run with shift
    # checking on, separately, so what it reports is recorded rather than hidden.
    prolog = "#include <stddef.h>\n#include <stdint.h>\n#include <float.h>\n#include <math.h>\n"
    tus = {"cand_new": [c for c in CURATED if "int_nonlin" not in open(os.path.join(KDIR, c[1])).read()],
           "cand_nl": [c for c in CURATED if "int_nonlin" in open(os.path.join(KDIR, c[1])).read()]}
    for tu, items in tus.items():
        with open(os.path.join(work, tu + ".c"), "w") as f:
            f.write(prolog)
            for _, rel, _ in items:
                f.write(f"/* ---- {rel} ---- */\n" + open(os.path.join(KDIR, rel)).read() + "\n")
    renames = [f"-Dkernel_{op}=ref_kernel_{op}" for op in ops]
    exes = {}
    for label, opt, san in (("full", "-O2", []),
                            ("san", "-O1", ["-fsanitize=address,undefined",
                                            "-fno-sanitize-recover=all", "-g"])):
        d = os.path.join(work, label)
        os.makedirs(d, exist_ok=True)
        common = [CC, opt, "-std=gnu11", "-w", "-ffp-contract=off", "-DMB_PEXT_HW=0",
                  "-DFX_STATS", f"-I{SW}", *san]
        noshift = ["-fno-sanitize=shift"] if san else []
        # -fno-sanitize=shift on the ORACLE, as check_bitexact.py does
        sh(common + noshift + renames + ["-c", ref, "-o", os.path.join(d, "ref.o")])
        sh(common + ["-c", os.path.join(work, "cand_new.c"), "-o", os.path.join(d, "cand_new.o")])
        sh(common + noshift + ["-c", os.path.join(work, "cand_nl.c"), "-o", os.path.join(d, "cand_nl.o")])
        exe = os.path.join(d, "stress")
        sh(common + [os.path.join(HERE, "stress_moonshine.c"), os.path.join(d, "ref.o"),
                     os.path.join(d, "cand_new.o"), os.path.join(d, "cand_nl.o"), "-o", exe, "-lm"])
        exes[label] = exe
        if san:
            # the int_nonlin.c TU once more with shift checking ON, recoverable, to record
            # what it reports
            sh(common[:-2] + ["-fsanitize=address,undefined", "-g", "-c",
                              os.path.join(work, "cand_nl.c"), "-o", os.path.join(d, "cand_nl_shift.o")])
            exe2 = os.path.join(d, "stress_shift")
            sh(common + [os.path.join(HERE, "stress_moonshine.c"), os.path.join(d, "ref.o"),
                         os.path.join(d, "cand_new.o"), os.path.join(d, "cand_nl_shift.o"),
                         "-o", exe2, "-lm"])
            exes["san_shift"] = exe2
    return exes


def parse(lines: str, tag: str) -> list:
    rows = []
    for l in lines.splitlines():
        if l.startswith(tag + " "):
            d = dict(re.findall(r"(\w+)=(\S+)", l))
            for k, v in list(d.items()):
                if re.fullmatch(r"-?\d+", v):
                    d[k] = int(v)
            rows.append(d)
    return rows


# ---------------------------------------------------------------------------- (b)3
def write_cases(ir: dict, acts, weights, path: str) -> int:
    n = 0
    with open(path, "wb") as f:
        for op in ir["ops"]:
            k = KIND.get(op["op"])
            if k is None:
                continue
            q, s = op.get("quant", {}), op.get("shape", {})
            f32 = lambda v: float(np.float32(v))

            def arr_i8(t):
                a = np.ascontiguousarray(acts[t].reshape(-1).astype(np.int8))
                return struct.pack("<iq", 1, a.size) + a.tobytes()

            def arr_f32(key):
                a = np.ascontiguousarray(weights[key].reshape(-1).astype(np.float32))
                return struct.pack("<iq", 2, a.size) + a.tobytes()

            if k == 1 or k == 6:
                p = [s["n"], f32(q["scale_in"]), f32(q["scale_out"]), q["activation_min"], q["activation_max"]]
                arrs = [arr_i8(op["inputs"][0])]
            elif k == 2:
                p = [s["N"], s["C"], s["H"], s["W"], f32(q["scale_in"]), f32(q["scale_out"]),
                     f32(q["eps"]), q["activation_min"], q["activation_max"]]
                arrs = [arr_i8(op["inputs"][0]), arr_f32(op["weight"]), arr_f32(op["bias"])]
            elif k == 3:
                p = [s["T"], s["H"], s["D"], s["R"], f32(q["scale_in"]), f32(q["scale_out"]),
                     q["activation_min"], q["activation_max"]]
                arrs = [arr_i8(op["inputs"][0]), arr_f32(op["weight"]), arr_f32(op["bias"])]
            elif k == 4:
                p = [s["n"], f32(q["scale_a"]), f32(q["scale_b"]), f32(q["scale_out"]),
                     q["activation_min"], q["activation_max"]]
                arrs = [arr_i8(op["inputs"][0]), arr_i8(op["inputs"][1])]
            elif k == 5:
                p = [s["B"], s["M"], s["K"], s["N"], f32(q["scale_a"]), f32(q["scale_b"]),
                     f32(q["scale_out"]), q.get("transpose_b", 0), f32(q.get("scale_div_sqrt_dk", 1.0)),
                     q["activation_min"], q["activation_max"]]
                arrs = [arr_i8(op["inputs"][0]), arr_i8(op["inputs"][1])]
            elif k == 7:
                p = [s["M"], s["K"], f32(q["scale_in"]), f32(q["scale_out"]), f32(q["eps"]),
                     q["activation_min"], q["activation_max"]]
                arrs = [arr_i8(op["inputs"][0]), arr_f32(op["weight"]), arr_f32(op["bias"])]
            else:
                p = [s["M"], s["K"], f32(q["scale_in"]), f32(q["scale_out"])]
                arrs = [arr_i8(op["inputs"][0])]
            nm = f"{op['name']}:{op['op']}".encode()
            f.write(struct.pack("<ii", k, len(nm)) + nm)
            f.write(struct.pack("<i", len(p)) + struct.pack(f"<{len(p)}d", *[float(x) for x in p]))
            for a in arrs:
                f.write(a)
            n += 1
    return n


# ---------------------------------------------------------------------------- objects
def object_float_check() -> list:
    gcc = (glob.glob(os.path.join(ZCS, "tools-manual", "**", "riscv64-zephyr-elf-gcc"), recursive=True)
           + glob.glob(os.path.join(os.environ.get("ZEPHYR_SDK_INSTALL_DIR", "/nonexistent"),
                                    "**", "riscv64-zephyr-elf-gcc"), recursive=True))
    if not gcc:
        return [{"error": "riscv64-zephyr-elf-gcc not found"}]
    gcc = gcc[0]
    objdump = gcc[:-3] + "objdump"
    out = []
    for op, rel, cls in CURATED[:6]:
        src = os.path.join(KDIR, rel)
        obj = os.path.join("/tmp" if not os.environ.get("TMPDIR") else os.environ["TMPDIR"],
                           f"mbmoon_{op}_{os.getpid()}.o")
        sh([gcc, "-O2", "-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany",
            "-DMB_PEXT_HW=1", f"-I{SW}", "-c", src, "-o", obj])
        dis = sh([objdump, "-dr", obj]).stdout
        words = re.findall(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", dis, re.M)
        c0 = sum(1 for w in words if (int(w, 16) & 0x7f) == 0x0b)
        relocs = re.findall(r"R_RISCV_CALL\S*\s+(\S+)", dis)
        sf = sorted({r for r in relocs if re.match(r"__(add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)\w*(sf|df)\w*$", r)})
        lm = sorted({r for r in relocs if re.match(r"(exp|erf|log|sqrt|tanh|pow|round|lrint)f?$", r)})
        other = sorted({r for r in relocs} - set(sf) - set(lm))
        out.append({"op": op, "kernel": rel, "custom0_encodings": c0,
                    "softfloat_relocs": len([r for r in relocs if r in sf]), "softfloat_symbols": sf,
                    "libm_relocs": len([r for r in relocs if r in lm]), "libm_symbols": lm,
                    "other_calls": other})
        os.unlink(obj)
        print(f"  {rel:48s} custom-0={c0:3d} soft-float={out[-1]['softfloat_relocs']} {sf} "
              f"libm={out[-1]['libm_relocs']} {lm} other={other}")
    return out


# ---------------------------------------------------------------------------- (a) / (b)4
def model_run(label: str, gen: str, ir_path: str, acts_npz: str, work: str, write_golden: str | None):
    exe = hostrun.build(gen, os.path.join(work, label), extra_cflags=["-DFX_STATS"])
    d = hostrun.dump(exe, gen, os.path.join(work, label, "dump.bin"))
    rows = hostrun.compare_to_golden(gen, ir_path, acts_npz, d)
    kinds = {}
    for r in rows:
        k = kinds.setdefault(r["op"], {"dispatches": 0, "elements": 0, "n_differ": 0, "max_abs_err": 0})
        k["dispatches"] += 1
        k["elements"] += r["elements"]
        k["n_differ"] += r["n_differ"]
        k["max_abs_err"] = max(k["max_abs_err"], r["max_abs_err"])
    first = next((r for r in rows if r["max_abs_err"]), None)
    golden = np.fromfile(os.path.join(gen, "test_golden.bin"), dtype=np.int8)
    outp = d["__output__"]
    res = {"gen": gen, "per_kind": kinds, "first_differing_dispatch": first,
           "output_elements": int(outp.size),
           "output_vs_python_golden_max_abs_err": int(np.abs(outp.astype(int) - golden.astype(int)).max()),
           "output_vs_python_golden_n_differ": int((outp != golden).sum()),
           "every_dispatch_bit_exact": all(r["max_abs_err"] == 0 for r in rows),
           "dispatches": len(rows), "slow_path": d.get("__fxstats__", []),
           "rows": rows}
    if write_golden:
        outp.astype(np.int8).tofile(write_golden)
        res["host_c_golden"] = write_golden
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ir", required=True)
    ap.add_argument("--acts", required=True)
    ap.add_argument("--ref-gen", required=True)
    ap.add_argument("--variant", action="append", default=[], help="label:GEN_DIR")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--skip-stress", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.workdir, exist_ok=True)
    ir_path = os.path.join(a.ir, "graph.json")
    ir = json.load(open(ir_path))
    acts = np.load(a.acts)
    weights = np.load(os.path.join(a.ir, "weights.npz"))
    out = {"ir": a.ir}

    print("(a) reference kernels, host C vs the Python golden, every dispatch")
    out["a_reference_vs_golden"] = model_run("ref", a.ref_gen, ir_path, a.acts, a.workdir, None)
    ra = out["a_reference_vs_golden"]
    print(f"  {ra['dispatches']} dispatches, every one bit-exact: {ra['every_dispatch_bit_exact']}; "
          f"output max_abs_err {ra['output_vs_python_golden_max_abs_err']}")

    print("(b)1 ModelBlaster's own host verify at atol = 0")
    out["b1_pipeline_verify"] = pipeline_verify()

    print("(b) objects cross-compiled for the board")
    out["objects"] = object_float_check()

    exes = build_stress(os.path.join(a.workdir, "stress"))
    cases = os.path.join(a.workdir, "model_cases.bin")
    ncases = write_cases(ir, acts, weights, cases)
    print(f"(b)3 model data: {ncases} dispatches on their golden inputs")
    txt = sh([exes["full"], "1", "model", cases]).stdout
    model_rows = parse(txt, "MODEL")
    per = {}
    for r in model_rows:
        op = r["dispatch"].split(":")[-1]
        p = per.setdefault(op, {"dispatches": 0, "elements": 0, "mismatches": 0, "max_abs_err": 0})
        p["dispatches"] += 1
        p["elements"] += r["elements"]
        p["mismatches"] += r["mismatches"]
        p["max_abs_err"] = max(p["max_abs_err"], r["max_abs_err"])
    for op, p in per.items():
        print(f"  {op:13s} {p['dispatches']:3d} dispatches {p['elements']:9d} elements "
              f"mismatches {p['mismatches']:7d} max_abs_err {p['max_abs_err']}")
    out["b3_model_data"] = {"per_kind": per, "rows": model_rows}
    san = subprocess.run([exes["san"], "0", "model", cases], text=True, capture_output=True)
    out["b3_model_data_asan_ubsan"] = {"returncode": san.returncode,
                                       "same_results": parse(san.stdout, "MODEL") == model_rows,
                                       "stderr": san.stderr[-3000:]}
    shf = subprocess.run([exes["san_shift"], "0", "model", cases], text=True, capture_output=True)
    shift_reports = sorted(set(re.findall(r"(\S+\.c:\d+:\d+: runtime error: [^\n]+)", shf.stderr)))
    out["b3_int_nonlin_tu_shift_ubsan_reports"] = shift_reports
    print(f"  ASan+UBSan model-data run: rc={san.returncode}, same results: "
          f"{out['b3_model_data_asan_ubsan']['same_results']}; shift-UBSan reports in the "
          f"int_nonlin.c TU: {len(shift_reports)}")
    for r in shift_reports[:12]:
        print("    " + r)

    if not a.skip_stress:
        for label, level in (("full", "1"), ("san", "0")):
            print(f"(b)2 stress [{label}]")
            proc = subprocess.run([exes[label], level], text=True, capture_output=True)
            rows = parse(proc.stdout, "RESULT")
            for r in rows:
                print("  " + " ".join(f"{k}={v}" for k, v in r.items()))
            out[f"b2_stress_{label}"] = {"rows": rows, "returncode": proc.returncode,
                                          "stderr_tail": proc.stderr[-2000:]}

    for v in a.variant:
        label, gen = v.split(":")
        print(f"(b)4 whole model, variant {label}")
        hc = os.path.join(a.workdir, f"host_c_golden_{label}.bin")
        r = model_run(label, gen, ir_path, a.acts, a.workdir, hc)
        out[f"b4_model_{label}"] = r
        print(f"  output vs Python golden: max_abs_err {r['output_vs_python_golden_max_abs_err']}, "
              f"{r['output_vs_python_golden_n_differ']} of {r['output_elements']} differ; "
              f"first differing dispatch: {(r['first_differing_dispatch'] or {}).get('name')}; "
              f"slow path {r['slow_path']}")
        for k, s in r["per_kind"].items():
            print(f"    {k:13s} {s['dispatches']:3d} dispatches  n_differ {s['n_differ']:8d} / "
                  f"{s['elements']:8d}  max {s['max_abs_err']}")
    json.dump(out, open(a.json, "w"), indent=1, default=str)
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
