#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Export a Q16 candidate's engine dispatches as tb_mbxr case files (the split-dispatch check).

ROCC_DECOUPLED.md s8.13 prices R and R3 on TODAY's engine (0x5A5A0010): the int16 stem becomes
split dispatches -- hi/lo input halves, output ranges differing in multiplier and shift, row
groups -- all stock conv2d_s8, plus the 36 stock linear_s8.  This writes every one of those
dispatches, with the candidate's own weights, bias, requantisation and INPUT ACTIVATIONS from
its integer golden (patches/0103's extract_q16, out/q16/<cand>/ir), in the engine's byte order:

  conv2d_s8 (NCHW in the IR): input gathered to window order x[w*IC + c]; weight rows
  reordered to [kw*IC + ic] and zero-padded to a multiple of 8, exactly as
  roccmoon_conv2d_s8_roccmoon_engine.c's mbxr_conv_row does; expected output transposed to
  [pixel, channel].
  linear_s8: [M, K] as it is.

The expected output is the integer golden's own activation, not a model of the engine.
tb_mbxr.cpp --casedir runs each through the engine RTL under the board's driver and compares
every byte.

    python3 engine_cases.py --cand R --ir out/q16/R/ir --out <dir>
Case file (little-endian): "MBXRCASE", u32 kind (0 linear, 1 conv), u32 npix, u32 K (padded),
u32 N, u32 astride (words), i32 mult, i32 shift, i32 amin, i32 amax, u64 in_bytes, input bytes,
N*K weight bytes, N i32 bias, npix*N expected bytes; then the name as the rest of the file.
"""
from __future__ import annotations

import argparse
import json
import os
import struct

import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cand", required=True)
    ap.add_argument("--ir", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    g = json.load(open(os.path.join(a.ir, "graph.json")))
    acts = np.load(os.path.join(a.ir, "acts.npz"))
    wts = np.load(os.path.join(a.ir, "weights.npz"))
    os.makedirs(a.out, exist_ok=True)
    man = []
    for i, o in enumerate(g["ops"]):
        if o["op"] not in ("linear_s8", "conv2d_s8"):
            continue
        q, s = o["quant"], o["shape"]
        assert (q["input_offset"], q["filter_offset"], q["output_offset"]) == (0, 0, 0), o["name"]
        x = acts[o["inputs"][0]].astype(np.int8).reshape(-1)
        y = acts[o["outputs"][0]].astype(np.int8).reshape(-1)
        w = wts[o["weight"]].astype(np.int8)
        b = wts[o["bias"]].astype(np.int32).reshape(-1) if o.get("bias") else np.zeros(w.shape[0], np.int32)
        if o["op"] == "linear_s8":
            M, K, N = s["M"], s["K"], s["N"]
            assert K % 8 == 0
            kind, npix, Kp, astride = 0, M, K, K // 8
            xin = x.reshape(M, K)
            wrows = w.reshape(N, K)
            exp = y.reshape(M, N)
        else:
            N_, IC, IH, IW, OC, OH, OW = s["N"], s["IC"], s["IH"], s["IW"], s["OC"], s["OH"], s["OW"]
            KH, KW, SH, SW, PH, PW = s["KH"], s["KW"], s["SH"], s["SW"], s["PH"], s["PW"]
            assert N_ == 1 and IH == 1 and KH == 1 and PH == 0 and PW == 0 and (IC * SW) % 8 == 0, o["name"]
            K = IC * KW
            Kp = (K + 7) & ~7
            kind, npix, N, astride = 1, OW, OC, SW * IC // 8
            xin = x.reshape(IC, IW).T.copy()                       # [w, c]
            wr = w.reshape(OC, IC, KW).transpose(0, 2, 1).reshape(OC, K)   # [n, kw*IC + ic]
            wrows = np.zeros((OC, Kp), np.int8)
            wrows[:, :K] = wr
            exp = y.reshape(OC, OW).T.copy()                       # [p, n]
        inb = xin.astype(np.int8).tobytes()
        name = f"{a.cand}/{i:03d}/{o['name']}"
        path = os.path.join(a.out, f"{a.cand}_{i:03d}_{o['op']}.bin")
        with open(path, "wb") as f:
            f.write(b"MBXRCASE")
            f.write(struct.pack("<IIIIIiiiiQ", kind, npix, Kp, N, astride, q["output_multiplier"], q["output_shift"],
                                q["activation_min"], q["activation_max"], len(inb)))
            f.write(inb)
            f.write(wrows.astype(np.int8).tobytes())
            f.write(b.astype("<i4").tobytes())
            f.write(exp.astype(np.int8).tobytes())
            f.write(name.encode())
        man.append({"file": os.path.basename(path), "name": o["name"], "op": o["op"], "npix": npix, "K": Kp, "N": N,
                    "astride": astride, "shift": q["output_shift"], "mult": q["output_multiplier"]})
    json.dump({"candidate": a.cand, "ir": os.path.abspath(a.ir), "cases": man},
              open(os.path.join(a.out, f"{a.cand}_manifest.json"), "w"), indent=1)
    print(f"{a.cand}: {len(man)} cases -> {a.out}")


if __name__ == "__main__":
    main()
