#!/usr/bin/env python3
"""Train one Visual Wake Words network on the tensors the board is actually fed.

    python3 train_vww.py --feat /path/to/feat_vww --arch cnn --out weights/

The features come from fpga/pynq-z2/sw/tools/featurise_vww.py and are int8 exactly as the
device produces them -- `clamp(pixel - 128, -127, 127)` and nothing else -- so there is no
preprocessing mismatch between training and the Zephyr image, by construction.

Batch norm is folded before the weights are written, so the exported graph is
conv / relu / pool / linear only.  ModelBlaster does the int8 PTQ from there.

AUGMENTATION IS THE LIGHTING MODEL.  A conference room is directional, uneven and
changes when somebody walks past a window, and the sensor has no auto-exposure loop in
this pipeline.  So training applies a random affine gain and offset in the int8 domain --
which is exactly a contrast and brightness change on the raw pixel, because the int8 map
is a fixed subtract -- along with a horizontal flip and a small translation.  A model
trained without it is a model that works under the lighting of the COCO photographer.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time

import numpy as np
import torch
from torch import nn

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from vision_models import ARCHS, FEED, FEED_SHAPE, count_macs, fold_bn   # noqa: E402


def calib_index(n: int, ncal: int):
    """Which held-out frames become ModelBlaster's calibration set.

    EVENLY SPACED, NOT THE FIRST N, and that is a bug fix rather than a preference.

    The featuriser writes each split class by class, so `xte[:64]` is sixty-four
    NON-PERSON frames and nothing else. Calibrating an int8 network on one class of a
    two-class problem sets every activation range from data the other class never
    produces, and the result is a model that answers "no person" to almost everything: it
    measured 56.75 % on the 10,928-frame held-out set against 82.37 % in fp32, with
    person recall at 9.6 %. The generated C was *correct* throughout -- the numpy
    simulator reproduced its baked golden with max_abs_err = 0 -- and the graph, the
    kernels and the cycle counts were all fine. Only the calibration input was wrong,
    which is the kind of failure that produces a believable number rather than an error.

    A stride sample over a class-ordered array interleaves the classes by construction and
    stays deterministic, which a shuffle with a seed also does but less obviously.
    """
    if ncal >= n:
        return np.arange(n)
    return np.linspace(0, n - 1, ncal).round().astype(int)


def write_calib(out: pathlib.Path, arch: str, xte, yte, ncal: int):
    """Real held-out frames for ModelBlaster's calibration and the board's smoke test.

    Real frames, not noise: activation ranges from random input would be wrong in both
    directions -- too wide where a box-averaged natural image never goes, too narrow
    where a high-contrast edge does.

    `ncal` is what the labs pass as --num-calibration. A frame is 9,216 bytes (27,648 for
    the colour feed) and these files are tracked, so it is kept small on purpose.
    """
    idx = calib_index(len(xte), ncal)
    cx = xte[idx].numpy().astype(np.int8)
    cy = yte[idx].numpy()
    np.save(out / f"{arch}_calib_x.npy", cx)
    np.save(out / f"{arch}_calib_y.npy", cy)
    print(f"[calib] {arch}: {len(idx)} frames, class balance {np.bincount(cy, minlength=2)}")
    return len(idx), [int(v) for v in np.bincount(cy, minlength=2)]


def load(feat: pathlib.Path, feed: str, split: str):
    x = np.load(feat / f"{feed}_{split}_x.npy")
    y = np.load(feat / f"{split}_y.npy")
    return torch.from_numpy(x), torch.from_numpy(y)


def augment(xb: torch.Tensor, gen: torch.Generator, shift: int = 6):
    """xb is int8-valued float on the device.  Returns the augmented batch.

    gain/offset:  v' = clamp(g*v + o, -127, 127), g in [0.6, 1.4], o in [-20, 20].
                  On the raw pixel that is p' = g*(p-128) + o + 128: a contrast and
                  brightness change, which is what a room's lighting does.
    flip:         horizontal only.  A person is not usually upside down and the sensor
                  is not usually rolled.
    translate:    up to +/-`shift` pixels each way, zero-filled (mid-grey after the
                  int8 map, which is what an out-of-frame region looks like).
    """
    n = xb.shape[0]
    dev = xb.device
    g = (0.6 + 0.8 * torch.rand(n, 1, 1, 1, generator=gen, device=dev))
    o = (torch.randint(-20, 21, (n, 1, 1, 1), generator=gen, device=dev)).float()
    xb = torch.clamp(torch.round(xb * g + o), -127, 127)
    flip = torch.rand(n, generator=gen, device=dev) < 0.5
    xb[flip] = torch.flip(xb[flip], dims=[3])
    if shift:
        dx = int(torch.randint(-shift, shift + 1, (1,), generator=gen, device=dev).item())
        dy = int(torch.randint(-shift, shift + 1, (1,), generator=gen, device=dev).item())
        if dx or dy:
            xb = torch.roll(xb, shifts=(dy, dx), dims=(2, 3))
            if dy > 0:
                xb[:, :, :dy, :] = 0
            elif dy < 0:
                xb[:, :, dy:, :] = 0
            if dx > 0:
                xb[:, :, :, :dx] = 0
            elif dx < 0:
                xb[:, :, :, dx:] = 0
    return xb


@torch.no_grad()
def evaluate(model, x, y, dev, bs=1024):
    model.eval()
    correct = 0
    for i in range(0, len(x), bs):
        p = model(x[i:i + bs].to(dev).float()).argmax(1).cpu()
        correct += (p == y[i:i + bs]).sum().item()
    return correct / len(x)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feat", required=True)
    ap.add_argument("--arch", default="cnn", choices=sorted(ARCHS))
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--bs", type=int, default=256)
    ap.add_argument("--lr", type=float, default=4e-3)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-augment", action="store_true")
    ap.add_argument("--ncal", type=int, default=64,
                    help="held-out frames written for ModelBlaster calibration")
    ap.add_argument("--refresh-calib", action="store_true",
                    help="do not train: rewrite only the calibration frames for an\n                          architecture whose weights are already on disk")
    a = ap.parse_args()

    torch.manual_seed(a.seed)
    feat = pathlib.Path(a.feat)
    meta = json.load(open(feat / "meta.json"))
    feed = FEED[a.arch]
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    xtr, ytr = load(feat, feed, "train")
    xva, yva = load(feat, feed, "val")
    xte, yte = load(feat, feed, "test")
    assert tuple(xtr.shape[1:]) == FEED_SHAPE[feed], (xtr.shape, FEED_SHAPE[feed])
    print(f"[train] {a.arch} ({feed}) on {dev}: {len(xtr)} train / {len(xva)} val / "
          f"{len(xte)} test, input {tuple(xtr.shape[1:])}, {len(meta['labels'])} classes")

    if a.refresh_calib:
        out = pathlib.Path(a.out)
        n, bal = write_calib(out, a.arch, xte, yte, a.ncal)
        mp = out / f"{a.arch}_meta.json"
        if mp.exists():
            m = json.load(open(mp))
            m["n_calib"] = n
            m["calib_class_balance"] = bal
            m["calib_selection"] = "evenly spaced over the held-out split"
            json.dump(m, open(mp, "w"), indent=2)
        print("[train] --refresh-calib: rewrote the calibration frames only")
        return

    model = ARCHS[a.arch](nclass=len(meta["labels"])).to(dev)
    macs = count_macs(model.cpu(), (1,) + FEED_SHAPE[feed]); model.to(dev)
    nparam = sum(p.numel() for p in model.parameters())
    print(f"[train] {macs:,} MACs/inference, {nparam:,} parameters "
          f"(declared {ARCHS[a.arch].MACS:,})")
    assert macs == ARCHS[a.arch].MACS, "MACS constant is stale"

    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-4)
    steps = a.epochs * ((len(xtr) + a.bs - 1) // a.bs)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=steps)
    lossf = nn.CrossEntropyLoss(label_smoothing=0.05)
    cpu_rng = torch.Generator().manual_seed(a.seed)
    dev_rng = torch.Generator(device=dev).manual_seed(a.seed)
    best, best_state = 0.0, None
    t0 = time.time()
    for ep in range(a.epochs):
        model.train()
        perm = torch.randperm(len(xtr), generator=cpu_rng)
        tot = 0.0
        for i in range(0, len(xtr), a.bs):
            idx = perm[i:i + a.bs]
            xb = xtr[idx].to(dev, non_blocking=True).float()
            if not a.no_augment:
                xb = augment(xb, dev_rng)
            yb = ytr[idx].to(dev, non_blocking=True)
            opt.zero_grad(set_to_none=True)
            loss = lossf(model(xb), yb)
            loss.backward()
            opt.step(); sched.step()
            tot += loss.item() * len(idx)
        va = evaluate(model, xva, yva, dev)
        if va > best:
            best, best_state = va, {k: v.detach().clone() for k, v in model.state_dict().items()}
        print(f"  ep {ep + 1:3d}/{a.epochs}  loss {tot / len(xtr):.4f}  val {va * 100:.2f}%"
              f"{'  *' if va == best else ''}  [{time.time() - t0:.0f}s]", flush=True)
    model.load_state_dict(best_state)
    te = evaluate(model, xte, yte, dev)
    print(f"[train] best val {best * 100:.2f}%   TEST {te * 100:.2f}%   "
          f"({time.time() - t0:.0f} s)")

    model = model.cpu().eval()
    te_before = evaluate(model, xte, yte, "cpu")
    fold_bn(model)
    te_after = evaluate(model, xte, yte, "cpu")
    print(f"[train] batchnorm folded: test {te_before * 100:.2f}% -> {te_after * 100:.2f}% "
          f"(delta {100 * (te_after - te_before):+.3f} pp)")
    assert abs(te_after - te_before) < 2e-3, "BN folding changed the model"

    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    # Save as npz, not .pt: mb_shim loads it with numpy and torch.load of a pickle is a
    # trust boundary this repo does not need.
    np.savez(out / f"{a.arch}_folded.npz",
             **{k: v.numpy() for k, v in model.state_dict().items()})
    write_calib(out, a.arch, xte, yte, a.ncal)
    json.dump({"arch": a.arch, "feed": feed, "in_shape": list(FEED_SHAPE[feed]),
               "macs": macs, "params": nparam,
               "val_acc": best, "test_acc_fp32": te_after,
               "test_acc_before_bn_fold": te_before,
               "n_test": len(xte), "labels": meta["labels"],
               "corpus": meta["corpus"], "int8_map": meta["int8_map"],
               "epochs": a.epochs, "seed": a.seed, "n_calib": a.ncal,
               "calib_selection": "evenly spaced over the held-out split",
               "augment": not a.no_augment},
              open(out / f"{a.arch}_meta.json", "w"), indent=2)
    print("[train] wrote", out / f"{a.arch}_folded.npz")


if __name__ == "__main__":
    main()
