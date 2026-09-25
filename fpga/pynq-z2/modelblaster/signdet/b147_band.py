"""B147: the same comparison, with the synthetic sets OVERSAMPLED into the decision band.

b147_bias.py showed the int8 shift is ~0 below float objectness 0.10 and material in
0.2..0.7, and that only 3.7 % of B144's procedural negatives ever reach that band against
50 % of the bench frames.  That confounds the two questions, so this keeps only synthetic
frames whose FLOAT peak lands in the band and compares like with like, in probability AND in
the logit margin  ln(P_peakclass / P_background)  at the peak cell, which is where a fixed
quantisation error would be constant instead of squashed by the softmax curve.
"""
from __future__ import annotations
import argparse, json, os, sys
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "moonshine"))
import _paths                                # noqa: E402
import make_data as md                    # noqa: E402
from model import SignDetLite, GRID       # noqa: E402
import hostrun                            # noqa: E402
from b147_negatives import peak_obj, float_probs, int8_probs  # noqa: E402

LO, HI = 0.20, 0.70


def margin(P):
    """(N,3,8,8) -> ln(P_peakclass / P_bg) at the peak cell, and the peak objectness."""
    obj = P[:, 1:].max(axis=1).reshape(len(P), -1)
    k = obj.argmax(1)
    gy, gx = k // GRID, k % GRID
    q = P[np.arange(len(P)), :, gy, gx]
    top = q[:, 1:].max(1)
    return np.log(np.maximum(top, 1e-6) / np.maximum(q[:, 0], 1e-6)), obj.max(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", default=_paths.out("signdet/gen"))
    ap.add_argument("--ir", default=_paths.out("signdet/ir"))
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--gtsdb", default=_paths.work("b144/data/FullIJCNN2013"))
    ap.add_argument("--probs", default=_paths.work("b147/run/probs.npz"))
    ap.add_argument("--workdir", default=_paths.work("b147/hostc"))
    ap.add_argument("--out", default=_paths.work("b147/run"))
    ap.add_argument("--want", type=int, default=300)
    ap.add_argument("--pool", type=int, default=14000)
    a = ap.parse_args()

    g = json.load(open(os.path.join(a.ir, "graph.json")))
    oq = g["tensors"][g["output"]["tensor"]]["quant"]
    osc, ozp = float(oq["scale"]), int(oq["zero_point"])
    exe = hostrun.build(a.gen, a.workdir)
    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()
    rng = np.random.default_rng(7)

    def band(X):
        P = float_probs(m, X)
        o = peak_obj(P)
        return np.where((o >= LO) & (o <= HI))[0]

    # indoor, oversampled
    keep = []
    while sum(len(k) for k, _ in keep) < a.want:
        X = np.stack([md.camera_sim(md.indoor_bg(rng), rng) for _ in range(1000)])
        i = band(X)
        keep.append((i, X))
        if sum(len(k) for k, _ in keep) * 1000 > a.pool:
            break
    Xi = np.concatenate([X[i] for i, X in keep])[:a.want]

    # GTSDB, oversampled (any crop kind -- the band is what matters, not the label)
    gt = md.load_gtsdb(a.gtsdb)
    pool = [n for n in sorted(os.listdir(a.gtsdb)) if n.endswith(".ppm") and int(n[:5]) >= 600]
    from PIL import Image
    cache, buf, got = {}, [], []
    while len(got) < a.want and len(buf) < a.pool:
        nm = pool[rng.integers(len(pool))]
        if nm not in cache:
            if len(cache) > 200:
                cache.pop(next(iter(cache)))
            cache[nm] = np.asarray(Image.open(os.path.join(a.gtsdb, nm)).convert("RGB"))
        r = md.gtsdb_crop(cache[nm], gt.get(nm, []), rng, rng.choice(["neg", "pos", "hard"]))
        if r is None:
            continue
        buf.append(md.camera_sim(r[0], rng))
        if len(buf) == 500:
            X = np.stack(buf); got.extend(list(X[band(X)])); buf = []
    Xr = np.stack(got[:a.want]) if got else np.zeros((0, 64, 64, 3), np.uint8)

    z = np.load(a.probs)
    Pbf, Pbc = z["P_f"], z["P_c"]
    ob = peak_obj(Pbf)
    sel = (ob >= LO) & (ob <= HI)

    L = []
    def p(s=""):
        print(s); L.append(s)
    p("B147  like-for-like in the decision band  float peak objectness %.2f..%.2f" % (LO, HI))
    p()
    p("%-26s %5s %14s %14s %16s %14s" %
      ("set", "n", "mean dP", "median dP", "mean d(margin)", "sd d(margin)"))
    sets = [("bench frames", Pbf[sel], Pbc[sel])]
    for nm, X in (("procedural indoor", Xi), ("GTSDB mixed crops", Xr)):
        if len(X) == 0:
            continue
        sets.append((nm, float_probs(m, X), int8_probs(exe, X, a.workdir, osc, ozp)))
    rows = {}
    for nm, Pf, Pc in sets:
        mf, of = margin(Pf); mc, oc = margin(Pc)
        dP, dm = oc - of, mc - mf
        rows[nm] = (dP, dm)
        p("%-26s %5d %14s %14s %16s %14.4f" %
          (nm, len(Pf), "%+.4f" % dP.mean(), "%+.4f" % np.median(dP),
           "%+.4f" % dm.mean(), dm.std(ddof=1)))
    p()
    p("the head's logit quantisation step is %.4f; a shift of one step in the margin is %.4f"
      % (float(g["tensors"]["head"]["quant"]["scale"]), float(g["tensors"]["head"]["quant"]["scale"])))
    p("(the margin is a DIFFERENCE of two head logits, so one step each way is up to 2 steps)")
    open(os.path.join(a.out, "band.txt"), "w").write("\n".join(L) + "\n")
    print("\nwrote %s/band.txt" % a.out)


if __name__ == "__main__":
    main()
