#!/usr/bin/env python3
"""Run ModelBlaster's int8 graph over the whole held-out set, in the codegen's arithmetic.

ModelBlaster bakes ONE golden output for ONE input.  That proves the generated C matches
its own quantisation; it says nothing about whether the quantised network still finds
people, which is the only accuracy number worth reporting.

So the int8 graph is re-executed here in numpy -- and the simulator is REQUIRED to
reproduce the baked test_golden.bin bit-exactly on the baked test_input.bin before any
accuracy number is printed.  That gate is what makes this the same arithmetic rather than
a second opinion.

Same shape as fpga/pynq-z2/modelblaster/kws/int8_accuracy.py, with two differences that
are forced by the workload rather than chosen:

  * it is BATCHED.  10,928 held-out frames through a 27-dispatch MobileNet with a
    Python loop per output pixel is hours; the whole test set goes through in one pass
    per chunk because every kernel here is already written over a leading N axis.
  * it knows about `avgpool2d_s8` and `depthwise_conv2d_s8`, which the MLPerf Tiny
    reference architecture needs and a keyword spotter did not.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from vision_models import FEED, FEED_SHAPE   # noqa: E402


def requant(acc, mult, shift, amin, amax, off=0):
    """acc(int32) -> int8, CMSIS-NN convention, exactly as the kernels do it.

    Both roundings are round-half-UP on signed types, which is what the reference
    expression does and what pext.h's MBP.QMUL + arithmetic shift reproduce;
    round-half-away-from-zero would be 1 LSB out on roughly half of all negative outputs.
    """
    mult = np.asarray(mult, dtype=np.int64)
    shift = np.asarray(shift, dtype=np.int64)
    acc = acc.astype(np.int64)
    if mult.ndim:                       # per output channel
        sh = (1, -1) + (1,) * (acc.ndim - 2) if acc.ndim > 2 else (1, -1)
        mult = mult.reshape(sh)
        shift = shift.reshape(sh)
    # The C truncates the Q0.31 product to int32 before shifting; reproduce that, not a
    # wider intermediate that happens to agree most of the time.
    p = ((acc * mult + (1 << 30)) >> 31).astype(np.int32).astype(np.int64)
    # THREE BRANCHES, NOT TWO. output_shift is SIGNED: the generated kernel does
    #     if (shift > 0) v = (prod + (1 << (shift-1))) >> shift;
    #     else           v = prod << (-shift);
    # A simulator that only handles shift > 0 and passes `prod` through otherwise is
    # correct for every network whose scales happen to give a positive shift -- which is
    # every keyword spotter in this repo -- and silently wrong for the three dispatches in
    # MobileNetV1 that do not (`body.19` and `body.21` at shift 0, `body.25` at -1). It
    # cost 17 LSB at body.25 and 48 at the output, and the baked-golden gate in main() is
    # what caught it.
    rnd = np.where(shift > 0, np.int64(1) << np.maximum(shift - 1, 0), 0)
    p = np.where(shift > 0,
                 (p + rnd) >> np.maximum(shift, 0),
                 p << np.maximum(-shift, 0))
    return np.clip(p + off, amin, amax).astype(np.int8)


def _mult_shift(o, q, W):
    if "output_multiplier_per_oc_key" in q:
        return W[q["output_multiplier_per_oc_key"]], W[q["output_shift_per_oc_key"]]
    return q["output_multiplier"], q["output_shift"]


def conv2d(x, w, b, s, q, mult, shift, depthwise=False):
    """im2col + one matmul per dispatch.

    The obvious implementation -- a Python loop over (oh, ow) with an einsum inside --
    is correct and takes hours over 10,928 frames and a 27-dispatch MobileNet.  This
    materialises the patch tensor once with a strided view and hands the whole dispatch
    to BLAS.  The ARITHMETIC is unchanged and the baked-golden gate in main() is what
    proves it: int8 operands, an int32 reduction, then the CMSIS-NN requantise.
    """
    OC, OH, OW = s["OC"], s["OH"], s["OW"]
    KH, KW, SH, SW, PH, PW = s["KH"], s["KW"], s["SH"], s["SW"], s["PH"], s["PW"]
    N = x.shape[0]
    xp = np.pad(x.astype(np.int32), ((0, 0), (0, 0), (PH, PH), (PW, PW)))
    win = np.lib.stride_tricks.sliding_window_view(xp, (KH, KW), axis=(2, 3))
    win = win[:, :, ::SH, ::SW][:, :, :OH, :OW]          # N, C, OH, OW, KH, KW
    wi = w.astype(np.int32)
    if depthwise:
        out = np.einsum("nchwkl,ckl->nchw", win, wi[:, 0]).astype(np.int64)
    else:
        # N, OH, OW, IC*KH*KW  @  IC*KH*KW, OC
        p = np.ascontiguousarray(win.transpose(0, 2, 3, 1, 4, 5)).reshape(
            N * OH * OW, -1)
        out = (p @ wi.reshape(OC, -1).T).reshape(N, OH, OW, OC)
        out = out.transpose(0, 3, 1, 2).astype(np.int64)
    if b is not None:
        out = out + b.astype(np.int64)[None, :, None, None]
    return requant(out, mult, shift, q["activation_min"], q["activation_max"],
                   q.get("output_offset", 0))


def run_graph(gdir, x_i8, cache={}):
    key = str(gdir)
    if key not in cache:
        cache[key] = (json.load(open(gdir / "graph.json")),
                      dict(np.load(gdir / "weights.npz")))
    g, W = cache[key]
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
            ic = s["OC"] if dw else s["IC"]
            r = conv2d(a.reshape(-1, ic, s["IH"], s["IW"]), w, b, s, q, mult, shift,
                       depthwise=dw)
        elif op == "maxpool2d_s8":
            v = a.reshape(-1, s["C"], s["IH"], s["IW"])
            r = np.empty((v.shape[0], s["C"], s["OH"], s["OW"]), dtype=np.int8)
            for oh in range(s["OH"]):
                for ow in range(s["OW"]):
                    r[:, :, oh, ow] = v[:, :, oh * s["SH"]:oh * s["SH"] + s["KH"],
                                        ow * s["SW"]:ow * s["SW"] + s["KW"]].max((2, 3))
        elif op == "avgpool2d_s8":
            # READ OFF THE GENERATED C, not guessed. kernel_avgpool2d_s8 is pure integer
            # and changes no scale: it sums the in-bounds window, divides by KH*KW (or by
            # the in-bounds count when count_include_pad is 0), rounds HALF AWAY FROM ZERO
            # by adding div/2 to the magnitude, and clamps to the full int8 range -- not
            # to activation_min/max, which this op does not carry.
            #
            # An earlier version of this file modelled it as a dequantise-rescale-roundf,
            # which is what several other _s8 references do, and it disagreed with the
            # baked golden by 20 LSB. The gate in main() caught it and refused to print an
            # accuracy; that is what the gate is for.
            v = a.reshape(-1, s["C"], s["IH"], s["IW"]).astype(np.int32)
            acc = np.zeros((v.shape[0], s["C"], s["OH"], s["OW"]), dtype=np.int32)
            cnt = np.zeros((s["OH"], s["OW"]), dtype=np.int32)
            PH, PW = s.get("PH", 0), s.get("PW", 0)
            for oh in range(s["OH"]):
                for ow in range(s["OW"]):
                    ih0, iw0 = oh * s["SH"] - PH, ow * s["SW"] - PW
                    ih1 = min(ih0 + s["KH"], s["IH"]); ihs = max(ih0, 0)
                    iw1 = min(iw0 + s["KW"], s["IW"]); iws = max(iw0, 0)
                    acc[:, :, oh, ow] = v[:, :, ihs:ih1, iws:iw1].sum((2, 3))
                    cnt[oh, ow] = max((ih1 - ihs) * (iw1 - iws), 1)
            div = (s["KH"] * s["KW"] if s.get("count_include_pad", 1) else cnt)
            mag = (np.abs(acc) + np.asarray(div) // 2) // np.asarray(div)
            r = np.clip(np.sign(acc) * mag, -128, 127).astype(np.int8)
        elif op in ("linear_s8", "linear_s8_pc"):
            w = W[o["weight"]].astype(np.int32)
            b = W[o["bias"]].astype(np.int64) if o.get("bias") else 0
            acc = a.reshape(-1, s["K"]).astype(np.int32) @ w.T
            mult, shift = _mult_shift(o, q, W)
            r = requant(acc.astype(np.int64) + b, mult, shift,
                        q["activation_min"], q["activation_max"],
                        q.get("output_offset", 0))
        elif op in ("view", "relu_s8", "relu6_s8"):
            r = a if op == "view" else np.maximum(a, 0).astype(np.int8)
        else:
            raise SystemExit("int8_accuracy.py does not model op %r" % op)
        env[o["outputs"][0]] = r
    go = g["output"]
    outname = go["tensor"] if isinstance(go, dict) else go
    if isinstance(outname, list):
        outname = outname[0]
    return env[outname]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--archs", required=True)
    ap.add_argument("--feat", required=True)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--limit", type=int, default=0, help="debug: cap test frames")
    a = ap.parse_args()
    run = pathlib.Path(a.run)
    feat = pathlib.Path(a.feat)
    meta = json.load(open(feat / "meta.json"))
    yt_all = np.load(feat / "test_y.npy")
    res = {}
    for arch in a.archs.split():
        gdir = run / arch / "scalar" / "ir"
        gen = run / arch / "scalar" / "gen"
        if not (gdir / "graph.json").exists():
            continue
        shape = FEED_SHAPE[FEED[arch]]
        # -- the gate: reproduce the BAKED golden bit-exactly ------------------------
        gin = np.fromfile(gen / "test_input.bin", dtype=np.int8)
        gold = np.fromfile(gen / "test_golden.bin", dtype=np.int8)
        got = run_graph(gdir, gin.reshape((1,) + shape)).ravel()
        err = int(np.abs(got.astype(int) - gold.astype(int)).max())
        print("  %-10s simulator vs baked golden: max_abs_err = %d  %s"
              % (arch, err, "OK" if err == 0
                 else "MISMATCH -- accuracy below is NOT valid"), flush=True)
        if err != 0:
            res[arch] = {"simulator_matches_golden": False}
            continue
        # -- the sweep ---------------------------------------------------------------
        xt = np.load(feat / f"{FEED[arch]}_test_x.npy", mmap_mode="r")
        yt = yt_all
        if a.limit:
            xt, yt = xt[:a.limit], yt[:a.limit]
        pred = np.empty(len(xt), dtype=np.int64)
        for i in range(0, len(xt), a.batch):
            chunk = np.ascontiguousarray(xt[i:i + a.batch])
            out = run_graph(gdir, chunk).reshape(len(chunk), -1)
            pred[i:i + len(chunk)] = out.astype(np.int32).argmax(1)
            if (i // a.batch) % 8 == 0:
                print("    %d/%d" % (i, len(xt)), flush=True)
        acc = float((pred == yt).mean())
        per = {meta["labels"][c]: float((pred[yt == c] == c).mean())
               for c in range(len(meta["labels"])) if (yt == c).any()}
        res[arch] = {"simulator_matches_golden": True, "int8_test_acc": acc,
                     "n_test": int(len(xt)), "per_class_recall": per,
                     "feed": FEED[arch]}
        print("  %-10s int8 accuracy on %d held-out frames: %.2f%%   (%s)"
              % (arch, len(xt), acc * 100,
                 "  ".join("%s %.1f%%" % (k, 100 * v) for k, v in per.items())),
              flush=True)
    json.dump(res, open(run / "int8_accuracy.json", "w"), indent=2)


if __name__ == "__main__":
    main()
