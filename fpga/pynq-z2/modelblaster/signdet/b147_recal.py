"""B147: does RECALIBRATING the per-tensor activation scales remove the int8 false alarms?

The int8 shift on the bench negatives is +0.082 median and one-sided, and no activation
saturates -- the bench frames use only ~0.3 of the int8 range every hidden layer was
calibrated for.  If that is the mechanism, a graph whose scales are set from deploy-like
frames should show the shift collapse.  Two arms were lowered by scripts/84_signdet_lower.sh:

    b147_mix    B144's 64 calibration frames interleaved with the 39 EVEN bench frames
    b147_bench  the 39 EVEN bench frames alone

and both are scored on the 39 ODD bench frames, which no arm was calibrated on.
"""
from __future__ import annotations
import argparse, json, os, sys
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "moonshine"))
import _paths                                # noqa: E402
import make_data as md                       # noqa: E402
from model import SignDetLite, GRID          # noqa: E402
import hostrun                               # noqa: E402
from b147_negatives import peak_obj, float_probs, int8_probs   # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arms", nargs="+", default=[
        "base=" + _paths.out("signdet"),
        "mix=" + _paths.out("b147_mix"),
        "bench=" + _paths.out("b147_bench")])
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--probs", default=_paths.work("b147/run/probs.npz"))
    ap.add_argument("--labels", default=_paths.work("b147/labels.json"))
    ap.add_argument("--split", default=_paths.work("b147/run/split.json"))
    ap.add_argument("--out", default=_paths.work("b147/run"))
    ap.add_argument("--n", type=int, default=600)
    ap.add_argument("--thr", type=float, default=0.5)
    a = ap.parse_args()

    z = np.load(a.probs)
    names = [str(x)[:-4] for x in z["files"]]
    lab = json.load(open(a.labels))["frames"]
    sp_ = json.load(open(a.split))
    odd = np.array([n in set(sp_["odd"]) for n in names])
    y = np.array([lab[n][0] for n in names])
    neg, pos = y == "none", y != "none"
    X8 = z["X8"]

    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()
    rng = np.random.default_rng(1234)
    Xi = np.stack([md.camera_sim(md.indoor_bg(rng), rng) for _ in range(a.n)])

    bf = peak_obj(z["P_f"]); inf = peak_obj(float_probs(m, Xi))
    L = []
    def p(s=""):
        print(s); L.append(s)
    p("B147  recalibration arms, scored on frames no arm was calibrated on")
    p("held-out half = the 39 ODD bench frames (%d no-sign, %d sign)"
      % ((neg & odd).sum(), (pos & odd).sum()))
    p()
    p("%-8s %10s %10s %10s %10s | %10s %10s" %
      ("arm", "FA odd-neg", "FA all-neg", "rec odd+", "rec all+", "FA indoor", "mean d vs f32"))
    p("%-8s %10.3f %10.3f %10s %10s | %10.3f %10s" %
      ("float", (bf[neg & odd] > a.thr).mean(), (bf[neg] > a.thr).mean(),
       "%d/%d" % ((bf[pos & odd] > a.thr).sum(), (pos & odd).sum()),
       "%d/%d" % ((bf[pos] > a.thr).sum(), pos.sum()), (inf > a.thr).mean(), "-"))
    rows = {}
    for spec in a.arms:
        nm, root = spec.split("=", 1)
        g = json.load(open(os.path.join(root, "ir", "graph.json")))
        oq = g["tensors"][g["output"]["tensor"]]["quant"]
        osc, ozp = float(oq["scale"]), int(oq["zero_point"])
        wd = os.path.join(a.out, "hostc_" + nm)
        exe = hostrun.build(os.path.join(root, "gen"), wd)
        bc = peak_obj(int8_probs(exe, X8, wd, osc, ozp))
        ic = peak_obj(int8_probs(exe, Xi, wd, osc, ozp))
        rows[nm] = bc
        p("%-8s %10.3f %10.3f %10s %10s | %10.3f %+10.4f" %
          ("int8 " + nm, (bc[neg & odd] > a.thr).mean(), (bc[neg] > a.thr).mean(),
           "%d/%d" % ((bc[pos & odd] > a.thr).sum(), (pos & odd).sum()),
           "%d/%d" % ((bc[pos] > a.thr).sum(), pos.sum()), (ic > a.thr).mean(),
           (bc[neg] - bf[neg]).mean()))
    p()
    p("peak objectness (int8 - float) on the 61 no-sign bench frames, by arm")
    for nm, bc in rows.items():
        d = bc[neg] - bf[neg]
        p("  %-6s mean %+.4f  median %+.4f  sd %.4f  |  positive on %2d/61  crossed 0.50 up %d"
          % (nm, d.mean(), np.median(d), d.std(ddof=1), (d > 0).sum(),
             int(((bf[neg] <= a.thr) & (bc[neg] > a.thr)).sum())))
    np.savez_compressed(os.path.join(a.out, "recal.npz"), bf=bf, inf=inf,
                        names=np.array(names), y=y, odd=odd, **{"bc_" + k: v for k, v in rows.items()})
    open(os.path.join(a.out, "recal.txt"), "w").write("\n".join(L) + "\n")
    print("\nwrote %s/{recal.txt,recal.npz}" % a.out)


if __name__ == "__main__":
    main()
