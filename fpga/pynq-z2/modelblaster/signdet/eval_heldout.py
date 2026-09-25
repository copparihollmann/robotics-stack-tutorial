"""Held-out numbers BY SOURCE, because one blended number would hide the thing that matters.

The B144 training set mixes real GTSDB sign crops with drawn US composites.  A single pooled
accuracy lets a model that only recognises its own synthetic props look good, so this splits
the held-out scenes (GTSDB images 600..899, never trained on) into:

  real_pos    a real GTSDB stop / give-way crop      -- what the model is worth on real signs
  synth_pos   a drawn US prop over a real background -- what it is worth on the demo props
  hard_neg    a crop around one of the OTHER 41 sign classes, which must read as background
  plain_neg   road scene, no target
  indoor_neg  procedural indoor scene, no target

The negatives carry the half of the claim the old classifier failed: it had no background
class and answered every frame at ~100%.
"""
from __future__ import annotations
import argparse, os, sys
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _paths                                # noqa: E402
import make_data as md
from model import SignDetLite, GRID
from PIL import Image


def gen(kind, pool, gt, root, rng, n, cache):
    X = np.zeros((n, 64, 64, 3), np.uint8); Y = np.zeros((n, GRID, GRID), np.int64)
    i = tries = 0
    while i < n:
        tries += 1
        if tries > n * 200:
            break
        nm = pool[rng.integers(len(pool))]
        if nm not in cache:
            if len(cache) > 200:
                cache.pop(next(iter(cache)))
            cache[nm] = np.asarray(Image.open(os.path.join(root, nm)).convert("RGB"))
        im, bb = cache[nm], gt.get(nm, [])
        if kind == "indoor_neg":
            scene, signs = md.indoor_bg(rng), []
        elif kind == "synth_pos":
            g = md.gtsdb_crop(im, bb, rng, "neg")
            if g is None:
                continue
            scene, signs = md.composite(g[0], rng)
        else:
            want = {"real_pos": "pos", "hard_neg": "hard", "plain_neg": "neg"}[kind]
            g = md.gtsdb_crop(im, bb, rng, want)
            if g is None:
                continue
            scene, signs = g
        X[i] = md.camera_sim(scene, rng); Y[i] = md.label_grid(signs); i += 1
    return X[:i], Y[:i]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--gtsdb", default=_paths.work("b144/data/FullIJCNN2013"))
    ap.add_argument("--n", type=int, default=1500)
    ap.add_argument("--thr", type=float, default=0.5)
    a = ap.parse_args()
    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()
    gt = md.load_gtsdb(a.gtsdb)
    pool = [n for n in sorted(os.listdir(a.gtsdb)) if n.endswith(".ppm") and int(n[:5]) >= 600]
    rng = np.random.default_rng(1234)
    cache = {}
    print("held-out scenes: GTSDB %05d..%05d (never trained on), thr=%.2f\n"
          % (600, 899, a.thr))
    print("%-11s %6s  %-42s" % ("source", "n", "result"))
    for kind in ("real_pos", "synth_pos", "hard_neg", "plain_neg", "indoor_neg"):
        X, Y = gen(kind, pool, gt, a.gtsdb, rng, a.n, cache)
        if len(X) == 0:
            print("%-11s %6d  (none generated)" % (kind, 0)); continue
        with torch.no_grad():
            P = []
            for i in range(0, len(X), 512):
                xb = torch.from_numpy(X[i:i + 512].astype(np.float32) / 255.0).permute(0, 3, 1, 2)
                P.append(torch.softmax(m.features(xb), dim=1).numpy())
            P = np.concatenate(P)
        obj = P[:, 1:].max(axis=1).reshape(len(P), -1)
        score, peak = obj.max(1), obj.argmax(1)
        py, px = peak // GRID, peak % GRID
        cls = P[np.arange(len(P)), :, py, px][:, 1:].argmax(1) + 1
        fired = score > a.thr
        if kind.endswith("pos"):
            loc = Y[np.arange(len(Y)), py, px] > 0
            true = np.array([np.bincount(r[r > 0], minlength=3).argmax() for r in Y.reshape(len(Y), -1)])
            det = fired & loc
            print("%-11s %6d  detected+localised %.3f | class correct %.3f | missed %.3f"
                  % (kind, len(X), det.mean(), (det & (cls == true)).mean(), (~fired).mean()))
        else:
            print("%-11s %6d  FALSE ALARM %.3f   (mean peak conf %.3f, p99 %.3f)"
                  % (kind, len(X), fired.mean(), score.mean(), np.percentile(score, 99)))


if __name__ == "__main__":
    main()
