"""THE GATE: SignDetLite against the 8 real HM01B0 captures, with B144's own labels.

Eight images is a tiny test set and this script is written not to overclaim from it: it prints
EVERY image, its true class, the predicted class, the peak cell, whether that cell lands inside
the hand-labelled box, and the confidence.  It also reports what the model does on the parts of
those frames that are NOT the sign -- the clutter-firing number, which matters as much as the
hits, because the model being replaced scored 100.0% confident and wrong on all eight.
"""
from __future__ import annotations
import argparse, glob, json, os, sys
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _paths                                # noqa: E402
import signpre_rgb as sp
from model import SignDetLite, GRID

NAMES = ["background", "stop", "yield"]
CELL324 = sp.CROP / GRID          # 40 px of the 324 frame per grid cell
OFF = sp.OFF


def cell_box_324(gx, gy):
    return (OFF + gx * CELL324, OFF + gy * CELL324, OFF + (gx + 1) * CELL324, OFF + (gy + 1) * CELL324)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--snaps", default=_paths.out("cam_snap/snaps"))
    ap.add_argument("--gt", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                 "bench_groundtruth.json"))
    ap.add_argument("--thr", type=float, default=0.5)
    ap.add_argument("--out", default=None)
    ap.add_argument("--viz", default=None)
    a = ap.parse_args()
    gt = json.load(open(a.gt))["images"]
    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()

    rows, viz = [], []
    for f in sorted(glob.glob(os.path.join(a.snaps, "*.raw"))):
        n = os.path.basename(f).replace(".raw", "")
        x = sp.preprocess(f)
        with torch.no_grad():
            P = torch.softmax(m.features(torch.from_numpy(x.astype(np.float32) / 255.0)
                                         .permute(2, 0, 1)[None]), dim=1)[0].numpy()
        obj = P[1:].max(axis=0)
        gy, gx = np.unravel_index(obj.argmax(), obj.shape)
        conf = float(obj[gy, gx])
        pred = int(P[1:, gy, gx].argmax()) + 1 if conf > a.thr else 0
        bx = cell_box_324(gx, gy)
        pcx, pcy = (bx[0] + bx[2]) / 2, (bx[1] + bx[3]) / 2
        b = gt[n]["box"]
        inside = bool(b[0] <= pcx <= b[2] and b[1] <= pcy <= b[3])
        # CLUTTER = cells that do not touch the sign AT ALL.  An earlier version of this
        # asked whether the cell CENTRE was inside the box, which is wrong for a big sign: a
        # cell is 40 px of the 324 frame and snap_022's triangle spans 117, so cells that are
        # mostly ON the sign were being counted as clutter and one read 0.952.  Zero overlap
        # with the hand-labelled box is the honest test.
        out_mask = np.ones((GRID, GRID), bool)
        for yy in range(GRID):
            for xx in range(GRID):
                cb = cell_box_324(xx, yy)
                if not (cb[2] <= b[0] or cb[0] >= b[2] or cb[3] <= b[1] or cb[1] >= b[3]):
                    out_mask[yy, xx] = False
        clutter = float(obj[out_mask].max())
        rows.append(dict(image=n, truth=gt[n]["label"], pred=NAMES[pred], conf=round(conf, 3),
                         peak_cell=[int(gx), int(gy)], peak_in_box=inside,
                         max_clutter_conf=round(clutter, 3),
                         correct=bool(NAMES[pred] == gt[n]["label"] and inside)))
        viz.append((n, x, P, (gx, gy), b, gt[n]["label"], NAMES[pred], conf))

    w = max(len(r["image"]) for r in rows)
    print("%-*s %-7s %-11s %6s  %-9s %-8s %s" %
          (w, "image", "truth", "predicted", "conf", "peak cell", "in box", "max clutter conf"))
    for r in rows:
        print("%-*s %-7s %-11s %6.3f  %-9s %-8s %.3f%s" %
              (w, r["image"], r["truth"], r["pred"], r["conf"], str(r["peak_cell"]),
               r["peak_in_box"], r["max_clutter_conf"], "" if r["correct"] else "   <-- MISS"))
    ok = sum(r["correct"] for r in rows)
    cls_ok = sum(r["pred"] == r["truth"] for r in rows)
    print("\n%d/%d correct (class AND peak inside the hand-labelled box)" % (ok, len(rows)))
    print("%d/%d correct class regardless of localisation" % (cls_ok, len(rows)))
    print("max confidence on clutter across all 8 frames: %.3f"
          % max(r["max_clutter_conf"] for r in rows))
    if a.out:
        json.dump(rows, open(a.out, "w"), indent=1)
        print("wrote", a.out)
    if a.viz:
        from PIL import Image, ImageDraw
        W = Image.new("RGB", (272 * 4, 292 * 2), (16, 16, 16))
        for i, (n, x, P, (gx, gy), b, tr, pr, cf) in enumerate(viz):
            t = Image.fromarray(x).resize((256, 256), Image.NEAREST).convert("RGB")
            d = ImageDraw.Draw(t, "RGBA")
            obj = P[1:].max(axis=0)
            for yy in range(GRID):
                for xx in range(GRID):
                    v = float(obj[yy, xx])
                    if v > 0.15:
                        d.rectangle([xx * 32, yy * 32, xx * 32 + 31, yy * 32 + 31],
                                    fill=(255, 40, 40, int(120 * v)))
            d.rectangle([int(v * 256 / 324) for v in b], outline=(0, 255, 0), width=2)
            d.rectangle([gx * 32, gy * 32, gx * 32 + 31, gy * 32 + 31], outline=(255, 255, 0), width=3)
            W.paste(t, (272 * (i % 4) + 8, 292 * (i // 4) + 26))
            ImageDraw.Draw(W).text((272 * (i % 4) + 10, 292 * (i // 4) + 8),
                                   "%s  T=%s P=%s %.2f" % (n[5:8], tr, pr, cf),
                                   fill=(0, 255, 0) if tr == pr else (255, 90, 90))
        W.save(a.viz); print("wrote", a.viz)


if __name__ == "__main__":
    main()
