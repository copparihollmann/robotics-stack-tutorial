#!/usr/bin/env python3
"""Emit b67_cat2_cases.h: every (scale0, scale1, scale_out, amin, amax) the decoder's IR
carries for cat2_c1_s8, exactly as float32."""
import json, os, numpy as np, sys

G = os.environ["IISWC_ROOT"] + "/out/b63c_dec_on/ir_cse/graph.json"
G2 = os.environ["IISWC_ROOT"] + "/out/decint8/ir/graph.json"

def f32(x):
    return float(np.float32(x))

seen, rows = set(), []
for path, tag in ((G, "cse"), (G2, "raw")):
    g = json.load(open(path))
    for o in g["ops"]:
        if o["op"] != "cat2_c1_s8":
            continue
        q = o["quant"]
        k = (f32(q["scales_in"][0]), f32(q["scales_in"][1]), f32(q["scale_out"]),
             q["activation_min"], q["activation_max"])
        if k in seen:
            continue
        seen.add(k)
        rows.append(k)

out = []
out.append("/* SPDX-License-Identifier: Apache-2.0 */")
out.append("/* @generated -- every distinct (scale0, scale1, scale_out, amin, amax) that")
out.append(" * cat2_c1_s8 carries in the Moonshine decoder's IR, before and after the CSE")
out.append(" * pass, as exact float32 hex literals.  cat2_c1_s8 does not appear in the")
out.append(" * encoder at all (checked over every graph.json in out/).")
out.append(" *")
out.append(" * Regenerate: fpga/pynq-z2/modelblaster/kernels/pext_nl/test/b67_gen_cases.py */")
out.append("#ifndef B67_CAT2_CASES_H")
out.append("#define B67_CAT2_CASES_H")
out.append("")
out.append("typedef struct { float s0, s1, so; int amin, amax; } b67_case_t;")
out.append("")
out.append("static const b67_case_t b67_cases[] = {")
for s0, s1, so, lo, hi in rows:
    out.append("\t{ %sf, %sf, %sf, %d, %d }," % (s0.hex(), s1.hex(), so.hex(), lo, hi))
out.append("};")
out.append("#define B67_NCASES ((int)(sizeof(b67_cases) / sizeof(b67_cases[0])))")
out.append("")
out.append("#endif /* B67_CAT2_CASES_H */")
open(sys.argv[1], "w").write("\n".join(out) + "\n")
print("cases:", len(rows))
