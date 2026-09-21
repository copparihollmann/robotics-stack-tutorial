#!/usr/bin/env python3
"""Turn the MLPerf Tiny Visual Wake Words corpus into the three int8 tensors the board is
actually fed -- through the board's own front end -- and split it reproducibly.

    python3 featurise_vww.py --root /path/to/vw_coco2014_96 --out /path/to/feat_vww

`vw_coco2014_96` is MLCommons' prepared Visual Wake Words set: 109,619 COCO-2014 images
cropped and resized to 96x96 RGB, filed under person/ and non_person/ by whether any COCO
`person` instance covers at least 0.5 % of the frame.  It is the corpus the MLPerf Tiny
reference trains on, which is the whole reason for using it: the accuracy numbers mean
something outside this repo.

EVERY FEATURE HERE IS PRODUCED BY fpga/pynq-z2/sw/frame_fe.c, compiled for the host and
called through ctypes (see frame_sim.py).  The usual way a vision model fails on a device
is a preprocessing mismatch -- one resize in training, another on the target, and nothing
comparing them.  That cannot happen here by construction rather than by care, which is
the same property fpga/pynq-z2/sw/tools/featurise.py gives the audio path.

THREE FEEDS, ONE SCENE.  The camera can be specified monochrome or colour, and the choice
changes the tensor the first convolution sees.  All three are produced from the same
synthesised 324x324 field of view, so the comparison is controlled:

  mono    1 x 96 x 96   a MONOCHROME sensor's 324x324 luma frame, centre 288 cropped and
                        3x3 box-averaged.  One byte per pixel on the wire.
  rgb     3 x 96 x 96   a COLOUR sensor's 324x324 RGGB mosaic, bilinearly DEMOSAICED and
                        then cropped and box-averaged.  Still one byte per pixel on the
                        wire -- the three planes are made on the core, not read off the
                        sensor.
  bayer4  4 x 48 x 48   the same mosaic with NO demosaic: four sub-lattices, each box-
                        averaged on its own.  One byte per pixel, four input channels,
                        half the linear resolution.

THE INT8 MAP IS FIXED AND HAS NO PARAMETERS.  `v = clamp(avg - 128, -127, 127)`, inside
frame_fe.c.  Every per-image normalisation people reach for -- mean/std, histogram
equalisation, per-frame autoscale -- needs either a float or a second pass over the frame
before the first convolution can start, and this core has no FPU.

THE SPLIT IS BY FILENAME HASH, not by shuffle.  Same idea as Google's `which_set()` in
the Speech Commands recipe: a file lands in the same split whatever order the directory
is walked in and whatever else is added to the corpus, so a model trained today and a
sweep run next month are scored on the same held-out images.  Each COCO image appears
exactly once in the corpus (checked: zero filenames in common between the two class
directories), so a per-file split is also a per-image split and nothing leaks.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import multiprocessing as mp
import pathlib
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import frame_sim  # noqa: E402

SIDE = 96
LABELS = ["non_person", "person"]
FEEDS = ("mono", "rgb", "bayer4")
SHAPES = {"mono": (1, 96, 96), "rgb": (3, 96, 96), "bayer4": (4, 48, 48)}

_FE = None


def _init():
    global _FE
    _FE = frame_sim.FrameFE()


def _one(args):
    root, cls, name = args
    im = Image.open(pathlib.Path(root) / cls / name)
    if im.mode != "RGB":
        im = im.convert("RGB")
    if im.size != (SIDE, SIDE):
        im = im.resize((SIDE, SIDE), Image.BILINEAR)
    px = np.asarray(im, dtype=np.uint8)
    mono, rgb, bay, _, _ = frame_sim.features(_FE, px)
    return mono, rgb, bay


def which_set(name: str, val_pct: float, test_pct: float) -> str:
    """Deterministic train/val/test assignment from the filename alone."""
    h = int(hashlib.sha1(name.encode()).hexdigest()[:16], 16)
    pct = (h % (1 << 27)) * 100.0 / (1 << 27)
    if pct < val_pct:
        return "val"
    if pct < val_pct + test_pct:
        return "test"
    return "train"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="vw_coco2014_96 directory")
    ap.add_argument("--out", required=True)
    ap.add_argument("--val-pct", type=float, default=10.0)
    ap.add_argument("--test-pct", type=float, default=10.0)
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--limit", type=int, default=0, help="debug: cap images per class")
    a = ap.parse_args()

    root = pathlib.Path(a.root)
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    files = []
    for lab, cls in enumerate(LABELS):
        d = root / cls
        if not d.is_dir():
            sys.exit(f"no such class directory: {d}")
        names = sorted(p.name for p in d.iterdir() if p.suffix.lower() == ".jpg")
        if a.limit:
            names = names[:a.limit]
        files += [(cls, n, lab) for n in names]
    print(f"[featurise] {len(files)} images under {root}")

    buckets = {s: [] for s in ("train", "val", "test")}
    for cls, n, lab in files:
        buckets[which_set(n, a.val_pct, a.test_pct)].append((cls, n, lab))

    counts = {}
    with mp.Pool(a.jobs, initializer=_init) as pool:
        for split, rows in buckets.items():
            n = len(rows)
            arr = {f: np.empty((n,) + SHAPES[f], np.int8) for f in FEEDS}
            y = np.empty(n, np.int64)
            work = [(str(root), cls, name) for cls, name, _ in rows]
            for i, (mono, rgb, bay) in enumerate(pool.imap(_one, work, chunksize=64)):
                arr["mono"][i] = mono
                arr["rgb"][i] = rgb
                arr["bayer4"][i] = bay
                y[i] = rows[i][2]
                if (i + 1) % 20000 == 0:
                    print(f"  {split} {i + 1}/{n}", flush=True)
            for feed in FEEDS:
                np.save(out / f"{feed}_{split}_x.npy", arr[feed])
            np.save(out / f"{split}_y.npy", y)
            counts[split] = {"n": n, "person": int(y.sum()),
                             "non_person": int(n - y.sum())}
            print(f"[featurise] {split}: {counts[split]}", flush=True)

    json.dump({"corpus": "vw_coco2014_96", "side": SIDE, "labels": LABELS,
               "feeds": {f: list(SHAPES[f]) for f in FEEDS},
               "front_end": "fpga/pynq-z2/sw/frame_fe.c via ctypes",
               "frame": "324x324 synthesised by frame_sim.scene324 (3x nearest, edges "
                        "extended); crop 288 centred, 3x3 box average",
               "int8_map": "clamp(box_average - 128, -127, 127)",
               "luma": "BT.601 integer: (77R + 150G + 29B + 128) >> 8",
               "bayer": "RGGB mosaic; rgb feed is bilinear demosaic, bayer4 feed is the "
                        "four sub-lattices with no demosaic",
               "split": "sha1(filename) percentile",
               "val_pct": a.val_pct, "test_pct": a.test_pct, "counts": counts},
              open(out / "meta.json", "w"), indent=2)
    print("[featurise] wrote", out / "meta.json")


if __name__ == "__main__":
    main()
