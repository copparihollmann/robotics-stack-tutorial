#!/usr/bin/env python3
"""Per-tensor against per-channel int8, for every architecture, on the whole held-out set.

    python3 quant_sweep.py --feat /path/to/feat_vww --out <dir> [--archs "cnn mbnet ..."]

This is a HOST-ONLY measurement and it needs no board: quantisation granularity changes
what the network computes, not how fast it computes it.  The cycle cost of the choice is
Lab B22's job; this is the accuracy half, and it is run separately because it is the half
that decides whether the task is worth putting on the board at all.

WHY IT EXISTS.  `SPEECH_ON_ROCKET.md` section 3.4 measured per-channel at +3.62 points on
a dense keyword spotter and recorded that it could not be bought, because `--per-channel`
renames the ops to conv2d_s8_pc / linear_s8_pc and the curated MBP kernels were registered
for the un-suffixed names only.  Both halves of that have moved: patches/0060 registered
curated `_pc` kernels, and on this vision task the gap is not 3.62 points.

Every number is produced by re-executing ModelBlaster's own int8 graph in numpy, with the
simulator first required to reproduce the codegen's baked golden bit-exactly on the baked
input -- the same gate int8_accuracy.py applies, for the same reason.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
ROOT = pathlib.Path(__import__("os").environ.get("IISWC_ROOT", HERE.parents[3]))
ZCS = ROOT / "zephyr-chipyard-sw"
sys.path.insert(0, str(HERE))
from int8_accuracy import run_graph          # noqa: E402
from vision_models import FEED, FEED_SHAPE   # noqa: E402


def codegen(arch, mode, out):
    ir, gen = out / "ir", out / "gen"
    ir.mkdir(parents=True, exist_ok=True)
    gen.mkdir(parents=True, exist_ok=True)
    pc = ["--per-channel"] if mode == "per_channel" else []
    for cmd in (
        ["-m", "modelblaster.pipeline.extract_graph", "--model", f"vww_{arch}",
         "--out-dir", str(ir), "--quant", "int8", "--num-calibration", "64",
         "--fusion-target", "scalar", *pc],
        ["-m", "modelblaster.pipeline.generate_skeleton", "--ir", str(ir / "graph.json"),
         "--weights", str(ir / "weights.npz"), "--io", str(ir / "io.npz"),
         "--out-dir", str(gen), "--backend", "scalar"],
    ):
        r = subprocess.run([sys.executable, *cmd], cwd=ZCS,
                           capture_output=True, text=True)
        if r.returncode:
            print(r.stdout[-2000:], r.stderr[-2000:])
            raise SystemExit(f"{arch}/{mode}: {cmd[1]} failed")
    return ir, gen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feat", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--archs", default="cnn mbnet cnn_tiny cnn_rgb cnn_bayer")
    ap.add_argument("--batch", type=int, default=128)
    a = ap.parse_args()
    feat = pathlib.Path(a.feat)
    out = pathlib.Path(a.out)
    yt = np.load(feat / "test_y.npy")
    res = {}

    for arch in a.archs.split():
        shape = FEED_SHAPE[FEED[arch]]
        xt = np.load(feat / f"{FEED[arch]}_test_x.npy", mmap_mode="r")
        meta = json.load(open(HERE / "weights" / f"{arch}_meta.json"))
        res[arch] = {"feed": FEED[arch], "macs": meta["macs"],
                     "params": meta["params"], "fp32": meta["test_acc_fp32"]}
        for mode in ("per_tensor", "per_channel"):
            ir, gen = codegen(arch, mode, out / arch / mode)
            gin = np.fromfile(gen / "test_input.bin", dtype=np.int8)
            gold = np.fromfile(gen / "test_golden.bin", dtype=np.int8)
            got = run_graph(ir, gin.reshape((1,) + shape)).ravel()
            err = int(np.abs(got.astype(int) - gold.astype(int)).max())
            if err:
                print(f"  {arch}/{mode}: simulator vs baked golden max_abs_err={err} "
                      f"-- NOT VALID", flush=True)
                res[arch][mode] = {"golden_ok": False, "max_abs_err": err}
                continue
            pred = np.empty(len(xt), np.int64)
            for i in range(0, len(xt), a.batch):
                ch = np.ascontiguousarray(xt[i:i + a.batch])
                pred[i:i + len(ch)] = run_graph(ir, ch).reshape(len(ch), -1) \
                                        .astype(np.int32).argmax(1)
            acc = float((pred == yt).mean())
            rec = float((pred[yt == 1] == 1).mean())
            spe = float((pred[yt == 0] == 0).mean())
            res[arch][mode] = {"golden_ok": True, "acc": acc,
                               "person_recall": rec, "non_person_recall": spe}
            print(f"  {arch:<10} {mode:<12} {100*acc:6.2f}%   "
                  f"person {100*rec:5.1f}%  non_person {100*spe:5.1f}%", flush=True)

    out.mkdir(parents=True, exist_ok=True)
    json.dump({"n_test": int(len(yt)), "per_arch": res},
              open(out / "quant_sweep.json", "w"), indent=2)

    print("\n%-10s %-8s %10s %10s %12s %12s %10s" %
          ("arch", "feed", "MACs", "fp32", "per-tensor", "per-channel", "delta"))
    print("-" * 80)
    for arch in a.archs.split():
        d = res[arch]
        pt = d.get("per_tensor", {}).get("acc")
        pc = d.get("per_channel", {}).get("acc")
        print("%-10s %-8s %10d %9.2f%% %11s %12s %9s" %
              (arch, d["feed"], d["macs"], 100 * d["fp32"],
               ("%.2f%%" % (100 * pt)) if pt else "-",
               ("%.2f%%" % (100 * pc)) if pc else "-",
               ("%+.2f" % (100 * (pc - pt))) if (pt and pc) else "-"))


if __name__ == "__main__":
    main()
