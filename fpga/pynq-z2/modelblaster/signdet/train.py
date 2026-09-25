"""Train SignDetLite on the B144 set. Float training; the int8 step is extract_graph's PTQ.

The input convention is fixed by the board: sign_pre_quant maps [0,255] -> [0,127], so the
float model is fed x/255 in [0,1] and the int8 input scale is 1/127 exactly as SignNetLite's.

THE SET THIS TRAINS ON IS HALF SOMEBODY ELSE'S.  make_data.py builds it from GTSDB -- the
German Traffic Sign Detection Benchmark of Houben, Stallkamp, Salmen, Schlipsing and Igel
(IJCNN 2013) -- plus composites this project draws itself.  GTSDB is not redistributed here;
obtain it from its own source.  See make_data.py's header for the citation and
docs/SIGNDET_WEIGHTS.md for why no checkpoint produced by this file is published.

YOU DO NOT NEED THIS FILE TO RUN THE DEMO.  scripts/84_signdet_lower.sh lowers a
deterministic random-weight model (random_weights.py, seed 144) when no checkpoint is
present, and everything but detection accuracy works from it.
"""
from __future__ import annotations
import argparse, glob, json, os, sys, time
import numpy as np
import torch
from torch import nn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _paths                                # noqa: E402
from model import SignDetLite, GRID, NCLS

BG, STOP, YIELD, IGNORE = 0, 1, 2, -1


def load(dsdir, tag):
    Xs, Ys = [], []
    for d in sorted(glob.glob(os.path.join(dsdir, "shard*"))):
        xp, yp = os.path.join(d, "X_%s.npy" % tag), os.path.join(d, "Y_%s.npy" % tag)
        if os.path.exists(xp):
            Xs.append(np.load(xp)); Ys.append(np.load(yp))
    if not Xs:
        raise SystemExit("no shards in %s" % dsdir)
    return np.concatenate(Xs), np.concatenate(Ys)


def augment(x, y, rng):
    """x uint8 (N,64,64,3), y (N,8,8). Horizontal flip only -- a vertical flip turns a
    point-down yield into a point-UP warning triangle, which is a different sign."""
    f = rng.random(len(x)) < 0.5
    x[f] = x[f][:, :, ::-1]
    y[f] = y[f][:, :, ::-1]
    g = (rng.uniform(0.75, 1.3, (len(x), 1, 1, 1)) * (1.0 + rng.uniform(-.06, .06, (len(x), 1, 1, 3))))
    b = rng.uniform(-22, 22, (len(x), 1, 1, 1))
    return np.clip(x.astype(np.float32) * g + b, 0, 255), y


@torch.no_grad()
def evaluate(m, X, Y, dev, thr=0.5, bs=1024):
    """Image-level detection metrics -- the only ones that mean anything for this demo."""
    m.eval()
    P = []
    for i in range(0, len(X), bs):
        xb = torch.from_numpy(X[i:i + bs].astype(np.float32) / 255.0).permute(0, 3, 1, 2).to(dev)
        P.append(torch.softmax(m.features(xb), dim=1).cpu().numpy())
    P = np.concatenate(P)                                   # (N,3,8,8)
    obj = P[:, STOP:].max(axis=1)                           # (N,8,8) best target prob
    peak = obj.reshape(len(P), -1).argmax(1)
    pk_y, pk_x = peak // GRID, peak % GRID
    score = obj.reshape(len(P), -1).max(1)
    cls = P[np.arange(len(P)), :, pk_y, pk_x][:, STOP:].argmax(1) + STOP
    has = (Y > 0).reshape(len(Y), -1).any(1)
    true = np.where(has, np.array([np.bincount(r[r > 0], minlength=3).argmax() if (r > 0).any() else 0
                                   for r in Y.reshape(len(Y), -1)]), 0)
    fired = score > thr
    out = {}
    pos = has
    if pos.sum():
        loc_ok = Y[np.arange(len(Y)), pk_y, pk_x] > 0
        out["pos_n"] = int(pos.sum())
        out["recall"] = float((fired & pos).mean() / max(pos.mean(), 1e-9))
        out["cls_acc"] = float(((cls == true) & fired & loc_ok)[pos].mean())
        out["loc_acc"] = float((loc_ok & fired)[pos].mean())
    neg = ~has
    if neg.sum():
        out["neg_n"] = int(neg.sum())
        out["false_alarm"] = float(fired[neg].mean())
    return out, P


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ds", default=_paths.work("b144/ds"))
    ap.add_argument("--out", default=_paths.work("b144/run"))
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--bs", type=int, default=256)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--pos-weight", type=float, default=6.0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    Xtr, Ytr = load(a.ds, "train"); Xte, Yte = load(a.ds, "test")
    print("train", Xtr.shape, "test", Xte.shape, flush=True)
    for nm, Y in (("train", Ytr), ("test", Yte)):
        print("  %s cells bg=%d stop=%d yield=%d ign=%d" %
              (nm, (Y == 0).sum(), (Y == 1).sum(), (Y == 2).sum(), (Y == IGNORE).sum()), flush=True)

    m = SignDetLite().to(dev)
    w = torch.tensor([1.0, a.pos_weight, a.pos_weight], device=dev)
    lossf = nn.CrossEntropyLoss(weight=w, ignore_index=IGNORE)
    opt = torch.optim.AdamW(m.parameters(), lr=a.lr, weight_decay=1e-4)
    steps = a.epochs * (len(Xtr) // a.bs)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=steps, pct_start=0.25)
    rng = np.random.default_rng(0)
    best, hist = -1.0, []
    t0 = time.time()
    for ep in range(a.epochs):
        m.train()
        idx = rng.permutation(len(Xtr))
        tot = n = 0
        for i in range(0, len(idx) - a.bs + 1, a.bs):
            j = idx[i:i + a.bs]
            xb, yb = augment(Xtr[j].copy(), Ytr[j].copy(), rng)
            xb = torch.from_numpy(xb / 255.0).permute(0, 3, 1, 2).float().to(dev)
            yb = torch.from_numpy(np.ascontiguousarray(yb)).long().to(dev)
            opt.zero_grad(set_to_none=True)
            l = lossf(m.features(xb), yb)
            l.backward(); opt.step(); sched.step()
            tot += float(l); n += 1
        ev, _ = evaluate(m, Xte, Yte, dev)
        sc = ev.get("cls_acc", 0) - ev.get("false_alarm", 1)
        hist.append({"epoch": ep, "loss": tot / max(n, 1), **ev})
        print("ep %2d loss %.4f  cls_acc %.4f loc %.4f recall %.4f  false_alarm %.4f  [%.0fs]" %
              (ep, tot / max(n, 1), ev.get("cls_acc", 0), ev.get("loc_acc", 0),
               ev.get("recall", 0), ev.get("false_alarm", 0), time.time() - t0), flush=True)
        if sc > best:
            best = sc
            torch.save(m.state_dict(), os.path.join(a.out, "signdet_b144.pt"))
    json.dump(hist, open(os.path.join(a.out, "history.json"), "w"), indent=1)
    m.load_state_dict(torch.load(os.path.join(a.out, "signdet_b144.pt")))
    sweep = {}
    for t in (0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9):
        ev, _ = evaluate(m, Xte, Yte, dev, thr=t)
        sweep["%.1f" % t] = ev
        print("thr %.1f -> %s" % (t, ev), flush=True)
    json.dump(sweep, open(os.path.join(a.out, "threshold_sweep.json"), "w"), indent=1)
    np.save(os.path.join(a.out, "calib_X.npy"), Xte[:256])
    print("saved", a.out, flush=True)


if __name__ == "__main__":
    main()
