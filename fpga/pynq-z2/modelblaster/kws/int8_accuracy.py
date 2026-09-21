#!/usr/bin/env python3
"""Run ModelBlaster's int8 graph over the whole held-out set, in the codegen's arithmetic.

ModelBlaster bakes ONE golden output for ONE input.  That proves the generated C matches
its own quantisation; it says nothing about whether the quantised network still
recognises words, which is the only accuracy number worth reporting.

So the int8 graph is re-executed here in numpy -- and the simulator is REQUIRED to
reproduce the baked test_golden.bin bit-exactly on the baked test_input.bin before any
accuracy number is printed.  That gate is what makes this the same arithmetic rather
than a second opinion: the requant is CMSIS-NN's Q0.31 multiply-and-rounding-shift, the
same expression pext.h's MBP.QMUL/CLIP8 pair implements, and getting it subtly wrong
(round-half-away-from-zero instead of round-half-up, say) shows up as a golden mismatch
and not as a plausible accuracy figure.
"""
from __future__ import annotations

import argparse, json, os, pathlib, sys
import numpy as np


def requant(acc, mult, shift, amin, amax, off=0):
    """acc(int32) -> int8, CMSIS-NN convention, exactly as the kernels do it.

    mult and shift may be scalars (per-tensor) or per-output-channel arrays broadcast
    over axis 1 -- the _pc variants carry them as weight blobs.  Both roundings are
    round-half-UP on signed types, which is what the reference expression does and what
    pext.h's MBP.QMUL + arithmetic shift reproduce; round-half-away-from-zero would be
    1 LSB out on roughly half of all negative outputs.
    """
    mult = np.asarray(mult, dtype=np.int64)
    shift = np.asarray(shift, dtype=np.int64)
    acc = acc.astype(np.int64)
    if mult.ndim:                       # per output channel: [N, C, ...] or [M, N]
        sh = (1, -1) + (1,) * (acc.ndim - 2) if acc.ndim > 2 else (1, -1)
        mult = mult.reshape(sh)
        shift = shift.reshape(sh)
    p = (acc * mult + (1 << 30)) >> 31
    rnd = np.where(shift > 0, np.int64(1) << np.maximum(shift - 1, 0), 0)
    p = np.where(shift > 0, (p + rnd) >> np.maximum(shift, 0), p)
    return np.clip(p + off, amin, amax).astype(np.int8)


def _mult_shift(o, q, W):
    """Per-tensor scalars, or the per-output-channel arrays the _pc ops name."""
    if "output_multiplier_per_oc_key" in q:
        return W[q["output_multiplier_per_oc_key"]], W[q["output_shift_per_oc_key"]]
    return q["output_multiplier"], q["output_shift"]


def conv2d(x, w, b, s, q, mult, shift, depthwise=False):
    N, IC, IH, IW = x.shape
    OC, OH, OW = s["OC"], s["OH"], s["OW"]
    KH, KW, SH, SW, PH, PW = s["KH"], s["KW"], s["SH"], s["SW"], s["PH"], s["PW"]
    xp = np.pad(x.astype(np.int32), ((0, 0), (0, 0), (PH, PH), (PW, PW)))
    out = np.zeros((N, OC, OH, OW), dtype=np.int64)
    for oh in range(OH):
        for ow in range(OW):
            patch = xp[:, :, oh * SH:oh * SH + KH, ow * SW:ow * SW + KW]
            if depthwise:
                out[:, :, oh, ow] = (patch * w[:, 0][None]).sum((2, 3))
            else:
                out[:, :, oh, ow] = np.einsum("nchw,ochw->no", patch, w.astype(np.int32))
    if b is not None:
        out += b.astype(np.int64)[None, :, None, None]
    return requant(out, mult, shift, q["activation_min"], q["activation_max"],
                   q.get("output_offset", 0))


def run_graph(gdir, x_i8):
    g = json.load(open(gdir / "graph.json"))
    W = np.load(gdir / "weights.npz")
    gi = g["input"]
    name = gi["tensor"] if isinstance(gi, dict) else gi
    env = {name: x_i8}
    for o in g["ops"]:
        op, s, q = o["op"], o.get("shape", {}), o.get("quant", {})
        a = env[o["inputs"][0]]
        if op in ("conv2d_s8", "conv2d_s8_pc", "depthwise_conv2d_s8",
                  "depthwise_conv2d_s8_pc"):
            w = W[o["weight"]]
            b = W[o["bias"]] if o.get("bias") else None
            dw = op.startswith("depthwise")
            mult, shift = _mult_shift(o, q, W)
            r = conv2d(a.reshape(s["N"], s["OC"] if dw else s["IC"], s["IH"], s["IW"]),
                       w, b, s, q, mult, shift, depthwise=dw)
        elif op == "maxpool2d_s8":
            N, C, IH, IW = s["N"], s["C"], s["IH"], s["IW"]
            v = a.reshape(N, C, IH, IW)
            r = np.full((N, C, s["OH"], s["OW"]), -128, dtype=np.int8)
            for oh in range(s["OH"]):
                for ow in range(s["OW"]):
                    r[:, :, oh, ow] = v[:, :, oh * s["SH"]:oh * s["SH"] + s["KH"],
                                        ow * s["SW"]:ow * s["SW"] + s["KW"]].max((2, 3))
        elif op == "avgpool2d_s8":
            N, C, IH, IW = s["N"], s["C"], s["IH"], s["IW"]
            v = a.reshape(N, C, IH, IW).astype(np.int32)
            win = s["KH"] * s["KW"]
            acc = np.zeros((N, C, s["OH"], s["OW"]), dtype=np.int32)
            for oh in range(s["OH"]):
                for ow in range(s["OW"]):
                    acc[:, :, oh, ow] = v[:, :, oh * s["SH"]:oh * s["SH"] + s["KH"],
                                          ow * s["SW"]:ow * s["SW"] + s["KW"]].sum((2, 3))
            # the reference kernel divides then requantises; both roundings are
            # round-half-away-from-zero on the C side via roundf()
            sc = q.get("scale_in", 1.0) / max(q.get("scale_out", 1.0), 1e-30) / win
            r = np.clip(np.floor(np.abs(acc * sc) + 0.5) * np.sign(acc),
                        q.get("activation_min", -128),
                        q.get("activation_max", 127)).astype(np.int8)
        elif op in ("linear_s8", "linear_s8_pc"):
            w = W[o["weight"]].astype(np.int32)
            b = W[o["bias"]].astype(np.int64) if o.get("bias") else 0
            acc = a.reshape(s["M"], s["K"]).astype(np.int32) @ w.T.astype(np.int32)
            mult, shift = _mult_shift(o, q, W)
            r = requant(acc.astype(np.int64) + b, mult, shift,
                        q["activation_min"], q["activation_max"],
                        q.get("output_offset", 0))
        elif op in ("view", "relu_s8"):
            r = a if op == "view" else np.maximum(a, 0).astype(np.int8)
        else:
            raise SystemExit("int8_accuracy.py does not model op %r" % op)
        env[o["outputs"][0]] = r
    go = g["output"]
    outname = go["tensor"] if isinstance(go, dict) else go
    if isinstance(outname, list):
        outname = outname[0]
    return env[outname].ravel()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--archs", required=True)
    ap.add_argument("--feat", required=True)
    a = ap.parse_args()
    run = pathlib.Path(a.run); feat = pathlib.Path(a.feat)
    xt = np.load(feat / "test_x.npy").astype(np.int8)
    yt = np.load(feat / "test_y.npy")
    meta = json.load(open(feat / "meta.json"))
    res = {}
    for arch in a.archs.split():
        gdir = run / arch / "scalar" / "ir"
        gen = run / arch / "scalar" / "gen"
        if not (gdir / "graph.json").exists():
            continue
        # -- the gate: reproduce the BAKED golden bit-exactly ------------------------
        gin = np.fromfile(gen / "test_input.bin", dtype=np.int8)
        gold = np.fromfile(gen / "test_golden.bin", dtype=np.int8)
        got = run_graph(gdir, gin.reshape(1, 1, meta["nframes"], meta["ncoef"]))
        err = int(np.abs(got.astype(int) - gold.astype(int)).max())
        print("  %-9s simulator vs baked golden: max_abs_err = %d  %s"
              % (arch, err, "OK" if err == 0 else "MISMATCH -- accuracy below is NOT valid"))
        if err != 0:
            res[arch] = {"simulator_matches_golden": False}
            continue
        # -- the sweep ---------------------------------------------------------------
        pred = np.empty(len(xt), dtype=np.int64)
        for i in range(len(xt)):
            pred[i] = int(np.argmax(run_graph(gdir, xt[i:i + 1]).astype(np.int32)))
            if i % 1000 == 0:
                print("    %d/%d" % (i, len(xt)), flush=True)
        acc = float((pred == yt).mean())
        per = {meta["labels"][c]: float((pred[yt == c] == c).mean())
               for c in range(len(meta["labels"])) if (yt == c).any()}
        res[arch] = {"simulator_matches_golden": True, "int8_test_acc": acc,
                     "n_test": int(len(xt)), "per_class_recall": per}
        print("  %-9s int8 accuracy on %d held-out clips: %.2f%%" % (arch, len(xt), acc * 100))
    json.dump(res, open(run / "int8_accuracy.json", "w"), indent=2)


if __name__ == "__main__":
    main()
