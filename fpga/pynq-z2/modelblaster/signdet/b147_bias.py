"""B147: is the int8 objectness shift a property of the DATA or of WHERE ON THE CURVE it sits?

Recalibrating every activation scale on bench-like frames did not move the +0.082 bias, so
range coverage is not the mechanism.  The remaining candidate is that the error is a function
of the OUTPUT, not of the input distribution: the procedural negatives sit at objectness ~0.05
and the bench negatives at ~0.41, and a quantised 3-way softmax has its largest absolute
probability error near 0.5 and almost none near 0.

So pool every frame this lab has scored -- bench, procedural indoor, GTSDB road -- bin them by
FLOAT peak objectness, and print the mean int8-float shift per bin.  If the curves lie on top
of each other the shift is not distribution-dependent at all.
"""
from __future__ import annotations
import argparse, json, os, sys
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "moonshine"))
import _paths                                # noqa: E402
import make_data as md                     # noqa: E402
from model import SignDetLite, GRID        # noqa: E402
import hostrun                             # noqa: E402
from b147_negatives import peak_obj, float_probs, int8_probs   # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", default=_paths.out("signdet/gen"))
    ap.add_argument("--ir", default=_paths.out("signdet/ir"))
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--gtsdb", default=_paths.work("b144/data/FullIJCNN2013"))
    ap.add_argument("--probs", default=_paths.work("b147/run/probs.npz"))
    ap.add_argument("--workdir", default=_paths.work("b147/hostc"))
    ap.add_argument("--out", default=_paths.work("b147/run"))
    ap.add_argument("--n", type=int, default=1500)
    a = ap.parse_args()

    g = json.load(open(os.path.join(a.ir, "graph.json")))
    oq = g["tensors"][g["output"]["tensor"]]["quant"]
    osc, ozp = float(oq["scale"]), int(oq["zero_point"])
    exe = hostrun.build(a.gen, a.workdir)
    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()

    z = np.load(a.probs)
    Xb = z["X8"]; bf, bc = peak_obj(z["P_f"]), peak_obj(z["P_c"])

    rng = np.random.default_rng(99)
    Xi = np.stack([md.camera_sim(md.indoor_bg(rng), rng) for _ in range(a.n)])
    inf_, inc = peak_obj(float_probs(m, Xi)), peak_obj(int8_probs(exe, Xi, a.workdir, osc, ozp))

    gt = md.load_gtsdb(a.gtsdb)
    pool = [n for n in sorted(os.listdir(a.gtsdb)) if n.endswith(".ppm") and int(n[:5]) >= 600]
    from PIL import Image
    Xr, cache, tries = [], {}, 0
    while len(Xr) < a.n and tries < a.n * 200:
        tries += 1
        nm = pool[rng.integers(len(pool))]
        if nm not in cache:
            if len(cache) > 200:
                cache.pop(next(iter(cache)))
            cache[nm] = np.asarray(Image.open(os.path.join(a.gtsdb, nm)).convert("RGB"))
        r = md.gtsdb_crop(cache[nm], gt.get(nm, []), rng, rng.choice(["neg", "pos", "hard"]))
        if r is None:
            continue
        Xr.append(md.camera_sim(r[0], rng))
    Xr = np.stack(Xr)
    rf, rc = peak_obj(float_probs(m, Xr)), peak_obj(int8_probs(exe, Xr, a.workdir, osc, ozp))

    edges = [0.0, 0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.001]
    L = []
    def p(s=""):
        print(s); L.append(s)
    p("B147  int8 - float peak objectness, binned by FLOAT peak objectness")
    p("if the shift were caused by the bench distribution the three columns would differ")
    p()
    p("%-14s %26s %26s %26s" % ("float peak bin", "bench frames (n=78)",
                                "procedural indoor (n=%d)" % len(inf_), "GTSDB mixed (n=%d)" % len(rf)))
    for lo, hi in zip(edges[:-1], edges[1:]):
        cells = []
        for f, c in ((bf, bc), (inf_, inc), (rf, rc)):
            s = (f >= lo) & (f < hi)
            cells.append("n=%4d  %+7.4f" % (s.sum(), (c[s] - f[s]).mean()) if s.sum() else "n=   0        -")
        p("%.2f .. %.2f   %26s %26s %26s" % (lo, hi, *cells))
    p()
    allf = np.concatenate([bf, inf_, rf]); allc = np.concatenate([bc, inc, rc])
    s = (allf > 0.3) & (allf < 0.7)
    p("pooled, float peak in 0.3..0.7 (the decision band): n=%d  mean shift %+.4f  median %+.4f"
      % (s.sum(), (allc[s] - allf[s]).mean(), np.median(allc[s] - allf[s])))
    s0 = allf < 0.10
    p("pooled, float peak < 0.10                         : n=%d  mean shift %+.4f"
      % (s0.sum(), (allc[s0] - allf[s0]).mean()))
    p()
    p("what fraction of each set sits in the 0.3..0.7 decision band, in FLOAT")
    for nm, f in (("bench, all 78", bf), ("procedural indoor", inf_), ("GTSDB mixed", rf)):
        p("  %-20s %.3f" % (nm, ((f > 0.3) & (f < 0.7)).mean()))
    open(os.path.join(a.out, "bias.txt"), "w").write("\n".join(L) + "\n")
    print("\nwrote %s/bias.txt" % a.out)


if __name__ == "__main__":
    main()
