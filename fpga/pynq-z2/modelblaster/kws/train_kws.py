#!/usr/bin/env python3
"""Train a keyword spotter on features produced by the board's own front end.

    python3 train_kws.py --feat /path/to/feat_kws --arch cnn --out weights/

The features come from fpga/pynq-z2/sw/tools/featurise.py, which compiles
fpga/pynq-z2/sw/audio_fe.c for the host and calls it -- so there is no front-end
mismatch between training and the Zephyr image, by construction rather than by care.

Batch norm is folded before the weights are written, so the exported graph is
conv / relu / pool / linear only.  Writes weights.pt (folded, eval) plus a fp32 accuracy
report; ModelBlaster does the int8 PTQ from there.
"""
from __future__ import annotations

import argparse, json, pathlib, sys, time
import numpy as np
import torch
from torch import nn

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from kws_models import ARCHS, count_macs, fold_bn   # noqa: E402


def load(feat: pathlib.Path, split: str):
    x = np.load(feat / f"{split}_x.npy")            # int8 [N,1,F,C]
    y = np.load(feat / f"{split}_y.npy")
    return torch.from_numpy(x.astype(np.float32)), torch.from_numpy(y)


def augment(x, rng, max_shift=3, nfmask=1, fmask=2, ntmask=1, tmask=6):
    """Feature-space augmentation: time shift plus SpecAugment masks.

    Shifting in the feature domain rather than the audio domain is deliberate -- the
    features are already built and rebuilding 36,769 clips per epoch through the C front
    end would dominate training.  The cost is that the shift is quantised to the 20 ms
    hop, which is the right granularity for a keyword spotter anyway.
    """
    n, _, F, C = x.shape
    out = x.clone()
    sh = torch.randint(-max_shift, max_shift + 1, (n,), generator=rng)
    for s in torch.unique(sh):
        m = sh == s
        if int(s):
            out[m] = torch.roll(out[m], int(s), dims=2)
    for _ in range(ntmask):
        t0 = torch.randint(0, max(1, F - tmask), (n,), generator=rng)
        w = torch.randint(0, tmask + 1, (n,), generator=rng)
        for i in range(n):
            out[i, :, t0[i]:t0[i] + w[i], :] = 0
    for _ in range(nfmask):
        f0 = torch.randint(0, max(1, C - fmask), (n,), generator=rng)
        w = torch.randint(0, fmask + 1, (n,), generator=rng)
        for i in range(n):
            out[i, :, :, f0[i]:f0[i] + w[i]] = 0
    return out


@torch.no_grad()
def evaluate(model, x, y, dev, bs=2048):
    model.eval()
    correct = 0
    for i in range(0, len(x), bs):
        p = model(x[i:i + bs].to(dev)).argmax(1).cpu()
        correct += (p == y[i:i + bs]).sum().item()
    return correct / len(x)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feat", required=True)
    ap.add_argument("--arch", default="cnn", choices=sorted(ARCHS))
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--bs", type=int, default=256)
    ap.add_argument("--lr", type=float, default=3e-3)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-augment", action="store_true")
    a = ap.parse_args()

    torch.manual_seed(a.seed)
    feat = pathlib.Path(a.feat)
    meta = json.load(open(feat / "meta.json"))
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    xtr, ytr = load(feat, "train")
    xva, yva = load(feat, "val")
    xte, yte = load(feat, "test")
    print(f"[train] {a.arch} on {dev}: {len(xtr)} train / {len(xva)} val / {len(xte)} test, "
          f"input {tuple(xtr.shape[1:])}, {len(meta['labels'])} classes")

    model = ARCHS[a.arch](nclass=len(meta["labels"])).to(dev)
    macs = count_macs(model.cpu()); model.to(dev)
    nparam = sum(p.numel() for p in model.parameters())
    print(f"[train] {macs:,} MACs/inference, {nparam:,} parameters "
          f"(declared {ARCHS[a.arch].MACS:,})")
    assert macs == ARCHS[a.arch].MACS, "MACS constant is stale"

    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-3)
    sched = torch.optim.lr_scheduler.OneCycleLR(
        opt, max_lr=a.lr, total_steps=a.epochs * ((len(xtr) + a.bs - 1) // a.bs))
    lossf = nn.CrossEntropyLoss(label_smoothing=0.1)
    rng = torch.Generator().manual_seed(a.seed)
    best, best_state = 0.0, None
    t0 = time.time()
    for ep in range(a.epochs):
        model.train()
        perm = torch.randperm(len(xtr), generator=rng)
        tot = 0.0
        for i in range(0, len(xtr), a.bs):
            idx = perm[i:i + a.bs]
            xb = xtr[idx]
            if not a.no_augment:
                xb = augment(xb, rng)
            xb, yb = xb.to(dev), ytr[idx].to(dev)
            opt.zero_grad(set_to_none=True)
            loss = lossf(model(xb), yb)
            loss.backward()
            opt.step(); sched.step()
            tot += loss.item() * len(idx)
        va = evaluate(model, xva, yva, dev)
        if va > best:
            best, best_state = va, {k: v.detach().clone() for k, v in model.state_dict().items()}
        print(f"  ep {ep + 1:3d}/{a.epochs}  loss {tot / len(xtr):.4f}  val {va * 100:.2f}%"
              f"{'  *' if va == best else ''}", flush=True)
    model.load_state_dict(best_state)
    te = evaluate(model, xte, yte, dev)
    print(f"[train] best val {best * 100:.2f}%   TEST {te * 100:.2f}%   "
          f"({time.time() - t0:.0f} s)")

    # Fold BN and re-check: folding must not move the answer.
    model = model.cpu().eval()
    te_before = evaluate(model, xte, yte, "cpu")
    fold_bn(model)
    te_after = evaluate(model, xte, yte, "cpu")
    print(f"[train] batchnorm folded: test {te_before * 100:.2f}% -> {te_after * 100:.2f}% "
          f"(delta {100 * (te_after - te_before):+.3f} pp)")
    assert abs(te_after - te_before) < 2e-3, "BN folding changed the model"

    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    torch.save(model.state_dict(), out / f"{a.arch}_folded.pt")
    # A handful of real test clips, for ModelBlaster's calibration and for the board's
    # own smoke test. int8-valued floats, exactly what the device feeds the model.
    np.save(out / f"{a.arch}_calib_x.npy", xte[:256].numpy().astype(np.int8))
    np.save(out / f"{a.arch}_calib_y.npy", yte[:256].numpy())
    json.dump({"arch": a.arch, "macs": macs, "params": nparam,
               "val_acc": best, "test_acc_fp32": te_after,
               "test_acc_before_bn_fold": te_before,
               "labels": meta["labels"], "nframes": meta["nframes"],
               "ncoef": meta["ncoef"], "feature": meta["feature"],
               "geometry": meta["geometry"], "off_q8": meta["off_q8"],
               "shift": meta["shift"], "epochs": a.epochs, "seed": a.seed},
              open(out / f"{a.arch}_meta.json", "w"), indent=2)
    print("[train] wrote", out / f"{a.arch}_folded.pt")


if __name__ == "__main__":
    main()
