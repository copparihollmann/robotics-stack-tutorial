"""B147: WHICH layer's per-tensor activation scale the bench frames run outside.

The int8 shift on the bench negatives is +0.082 median and one-sided (58 of 61 positive),
while on the procedural indoor negatives B144 calibrated against it is +0.002 and two-sided.
A one-sided error is a calibration fault, not rounding noise, so this asks the direct
question: for each activation tensor, what fraction of values SATURATE against the
per-tensor scale out/signdet/ir/graph.json carries, on

    the calibration set | the procedural indoor negatives | the real no-sign bench frames

Weights are per-channel here (conv2d_s8_pc); every ACTIVATION is per-tensor, so an input
distribution the calibration set does not cover has nowhere to go but the clip.
"""
from __future__ import annotations
import argparse, json, os, sys
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _paths                                # noqa: E402
import make_data as md                       # noqa: E402
from model import SignDetLite                # noqa: E402

ORDER = ["x", "relu", "relu_1", "relu_2", "relu_3", "relu_4", "head"]


def acts(m, X):
    """float activations at exactly the tensors graph.json quantises."""
    with torch.no_grad():
        a = {}
        x = torch.from_numpy(X.astype(np.float32) / 255.0).permute(0, 3, 1, 2)
        a["x"] = x.numpy()
        x = torch.relu(m.conv1(x)); a["relu"] = x.numpy()
        x = torch.relu(m.conv2(x)); a["relu_1"] = x.numpy()
        x = torch.relu(m.conv3(x)); a["relu_2"] = x.numpy()
        x = torch.relu(m.conv4(x)); a["relu_3"] = x.numpy()
        x = torch.relu(m.conv5(x)); a["relu_4"] = x.numpy()
        a["head"] = m.head(x).numpy()
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ir", default=_paths.out("signdet/ir"))
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--calib", default=_paths.work("b144/run/calib_X.npy"))
    ap.add_argument("--probs", default=_paths.work("b147/run/probs.npz"))
    ap.add_argument("--labels", default=_paths.work("b147/labels.json"))
    ap.add_argument("--out", default=_paths.work("b147/run"))
    ap.add_argument("--n", type=int, default=400)
    a = ap.parse_args()

    g = json.load(open(os.path.join(a.ir, "graph.json")))
    sc = {t: float(g["tensors"][t]["quant"]["scale"]) for t in ORDER}
    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()

    Xc = np.load(a.calib)
    rng = np.random.default_rng(1234)
    Xi = np.stack([md.camera_sim(md.indoor_bg(rng), rng) for _ in range(a.n)])
    z = np.load(a.probs)
    names = [str(x)[:-4] for x in z["files"]]
    lab = json.load(open(a.labels))["frames"]
    Xb = z["X8"][[i for i, n in enumerate(names) if lab[n][0] == "none"]]

    sets = [("calibration set", Xc), ("procedural indoor_neg", Xi), ("bench, no sign", Xb)]
    L = []
    def p(s=""):
        print(s); L.append(s)
    p("B147  per-tensor activation scales vs the data that actually reaches them")
    p("calib n=%d  indoor n=%d  bench-neg n=%d" % (len(Xc), len(Xi), len(Xb)))
    p()
    p("%-8s %12s %10s %10s %10s   %s" % ("tensor", "scale", "clip@", "p99.9", "max", "SATURATED %  (calib | indoor | bench)"))
    A = [acts(m, X) for _, X in sets]
    for t in ORDER:
        s = sc[t]; lim = 127 * s
        row = []
        for k in range(3):
            v = np.abs(A[k][t])
            row.append(100.0 * (v > lim).mean())
        p("%-8s %12.6f %10.3f %10.3f %10.3f   %8.4f | %8.4f | %8.4f"
          % (t, s, lim, float(np.percentile(np.abs(A[2][t]), 99.9)), float(np.abs(A[2][t]).max()),
             row[0], row[1], row[2]))
    p()
    p("%-8s  max |a| by set: calib / indoor / bench-neg   (and bench max as a multiple of the clip)" % "tensor")
    for t in ORDER:
        mx = [float(np.abs(A[k][t]).max()) for k in range(3)]
        p("%-8s  %9.3f %9.3f %9.3f    bench max = %.2f x clip" % (t, mx[0], mx[1], mx[2], mx[2] / (127 * sc[t])))
    p()
    p("head logits, signed, on the bench negatives: the class channels that decide the STOP")
    for k, nm in enumerate(("background", "stop", "yield")):
        h = A[2]["head"][:, k]
        hc = A[0]["head"][:, k]
        p("  %-11s bench mean %+7.3f  p99 %+7.3f  max %+7.3f   |  calib mean %+7.3f p99 %+7.3f max %+7.3f"
          % (nm, h.mean(), np.percentile(h, 99), h.max(), hc.mean(), np.percentile(hc, 99), hc.max()))
    p("  head clip is +-%.3f; a logit beyond it is folded back onto the boundary" % (127 * sc["head"]))
    open(os.path.join(a.out, "ranges.txt"), "w").write("\n".join(L) + "\n")
    print("\nwrote %s/ranges.txt" % a.out)


if __name__ == "__main__":
    main()
