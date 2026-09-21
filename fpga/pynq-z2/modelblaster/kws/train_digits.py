#!/usr/bin/env python3
"""Train the connected-digit CTC transcriber, and score it with edit distance.

    python3 train_digits.py --feat /path/to/feat_digits --out weights/

Accuracy here is **word error rate** -- insertions + deletions + substitutions over
reference length, from a greedy CTC decode -- not a classification rate. That is the
point: the model emits a variable-length digit string and can get the length wrong,
which a twelve-way classifier cannot.
"""
from __future__ import annotations

import argparse, json, pathlib, sys, time
import numpy as np
import torch
from torch import nn

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from kws_models import ARCHS, count_macs, fold_bn   # noqa: E402

BLANK = 10


def load(feat: pathlib.Path, split: str, transpose: bool = False):
    x = np.load(feat / f"{split}_x.npy").astype(np.float32)
    if transpose:
        # [N, 1, T, C] -> [N, 1, C, T]: time on the WIDTH axis, so the curated MBP conv
        # kernel's NCHW gather walks contiguous runs of length KW instead of single
        # bytes. Same arithmetic, 4x fewer cycles -- see kws_models.DigitCTCT.
        x = np.ascontiguousarray(x.transpose(0, 1, 3, 2))
    y = np.load(feat / f"{split}_y.npy")
    l = np.load(feat / f"{split}_l.npy")
    return torch.from_numpy(x), torch.from_numpy(y.astype(np.int64)), torch.from_numpy(l.astype(np.int64))


def greedy_decode(logits):
    """[T, C] logits -> digit list. Exactly what the C on the device does.

    argmax, collapse runs, drop blanks. No softmax: argmax is invariant under it.
    """
    best = logits.argmax(-1)
    out, prev = [], -1
    for b in best.tolist():
        if b != prev and b != BLANK:
            out.append(b)
        prev = b
    return out


def edit(a, b):
    """Levenshtein, for WER."""
    if not a:
        return len(b)
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


@torch.no_grad()
def score(model, x, y, l, dev, bs=512):
    """Returns (WER, exact-utterance accuracy)."""
    model.eval()
    err = tot = exact = 0
    for i in range(0, len(x), bs):
        lg = model(x[i:i + bs].to(dev))           # [N, C, T, 1]
        lg = lg.reshape(lg.shape[0], lg.shape[1], -1).permute(0, 2, 1).cpu()  # [N, T, C]
        for k in range(lg.shape[0]):
            ref = y[i + k][:l[i + k]].tolist()
            hyp = greedy_decode(lg[k])
            e = edit(ref, hyp)
            err += e; tot += len(ref); exact += (e == 0)
    return err / max(tot, 1), exact / len(x)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feat", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--arch", default="digit_ctc")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--bs", type=int, default=128)
    ap.add_argument("--lr", type=float, default=3e-3)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    torch.manual_seed(a.seed)
    feat = pathlib.Path(a.feat)
    meta = json.load(open(feat / "meta.json"))
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    tr = getattr(ARCHS[a.arch], "TRANSPOSED", False)
    xtr, ytr, ltr = load(feat, "train", tr)
    xva, yva, lva = load(feat, "val", tr)
    xte, yte, lte = load(feat, "test", tr)
    if tr:
        print("[digits] input transposed to [N, 1, ncoef, frames]")
    print(f"[digits] {len(xtr)} train / {len(xva)} val / {len(xte)} test, "
          f"input {tuple(xtr.shape[1:])}, {meta['nclass']} classes (blank={meta['blank']})")

    model = ARCHS[a.arch](nclass=meta["nclass"]).to(dev)
    macs = count_macs(model.cpu(), (1,) + tuple(xtr.shape[1:])); model.to(dev)
    print(f"[digits] {macs:,} MACs/utterance ({macs / 4.01 / 1e6:.3f} MMAC per second of "
          f"audio), {sum(p.numel() for p in model.parameters()):,} parameters")
    assert macs == ARCHS[a.arch].MACS

    ctc = nn.CTCLoss(blank=BLANK, zero_infinity=True)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-4)
    steps = a.epochs * ((len(xtr) + a.bs - 1) // a.bs)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=steps)
    rng = torch.Generator().manual_seed(a.seed)
    best, best_state = 9e9, None
    t0 = time.time()
    for ep in range(a.epochs):
        model.train()
        perm = torch.randperm(len(xtr), generator=rng)
        tot = 0.0
        for i in range(0, len(xtr), a.bs):
            idx = perm[i:i + a.bs]
            xb = xtr[idx].to(dev)
            lg = model(xb)
            lg = lg.reshape(lg.shape[0], lg.shape[1], -1).permute(2, 0, 1)  # [T,N,C]
            lp = torch.log_softmax(lg, dim=-1)
            T, N, _ = lp.shape
            tl = torch.full((N,), T, dtype=torch.long)
            yl = ltr[idx]
            tgt = torch.cat([ytr[idx][k][:yl[k]] for k in range(N)]).to(dev)
            loss = ctc(lp, tgt, tl, yl)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            opt.step(); sched.step()
            tot += loss.item() * N
        if (ep + 1) % 5 == 0 or ep == a.epochs - 1:
            wer, exact = score(model, xva, yva, lva, dev)
            flag = ""
            if wer < best:
                best, best_state = wer, {k: v.detach().clone()
                                         for k, v in model.state_dict().items()}
                flag = "  *"
            print(f"  ep {ep + 1:3d}/{a.epochs}  loss {tot / len(xtr):.4f}  "
                  f"val WER {wer * 100:.2f}%  exact {exact * 100:.1f}%{flag}", flush=True)
        else:
            print(f"  ep {ep + 1:3d}/{a.epochs}  loss {tot / len(xtr):.4f}", flush=True)
    model.load_state_dict(best_state)
    wer, exact = score(model, xte, yte, lte, dev)
    print(f"[digits] best val WER {best * 100:.2f}%   TEST WER {wer * 100:.2f}%   "
          f"exact-utterance {exact * 100:.2f}%   ({time.time() - t0:.0f} s)")

    model = model.cpu().eval()
    w0, _ = score(model, xte, yte, lte, "cpu")
    fold_bn(model)
    w1, e1 = score(model, xte, yte, lte, "cpu")
    print(f"[digits] batchnorm folded: test WER {w0 * 100:.2f}% -> {w1 * 100:.2f}%")
    assert abs(w1 - w0) < 5e-3, "BN folding changed the model"

    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    torch.save(model.state_dict(), out / f"{a.arch}_folded.pt")
    np.savez_compressed(out / f"{a.arch}_folded.npz",
                        **{k: v.numpy() for k, v in model.state_dict().items()})
    np.save(out / f"{a.arch}_calib_x.npy", xte[:256].numpy().astype(np.int8))
    np.save(out / f"{a.arch}_calib_y.npy", yte[:256].numpy())
    np.save(out / f"{a.arch}_calib_l.npy", lte[:256].numpy())
    json.dump({"arch": a.arch, "macs": macs,
               "params": sum(p.numel() for p in model.parameters()),
               "test_wer_fp32": w1, "test_exact_fp32": e1, "val_wer": best,
               "labels": meta["digits"], "blank": meta["blank"],
               "nclass": meta["nclass"], "frames": meta["frames"],
               "ncoef": meta["ncoef"], "out_frames": 50,
               "transposed": bool(getattr(ARCHS[a.arch], "TRANSPOSED", False)),
               "geometry": meta["geometry"], "clip_samples": meta["clip_samples"],
               "off_q8": meta["off_q8"], "shift": meta["shift"],
               "epochs": a.epochs, "seed": a.seed,
               "test_acc_fp32": 1.0 - w1},
              open(out / f"{a.arch}_meta.json", "w"), indent=2)
    print("[digits] wrote", out / f"{a.arch}_folded.npz")


if __name__ == "__main__":
    main()
