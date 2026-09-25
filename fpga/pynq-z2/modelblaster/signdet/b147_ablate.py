"""B147: WHERE the one-sided int8 bias enters -- input, weights, or activation rounding.

Recalibrating every activation scale on bench-like frames left the bias untouched, so it is
not range coverage.  This turns the three error sources on ONE AT A TIME in float, using the
graph's own quantisers (out/signdet/ir/graph.json scales and weights.npz's int8 weights), and
measures each one's effect on the logit margin ln(P_peakclass / P_bg) at the peak cell -- the
quantity the 0.50 decision is a threshold on.

Fidelity of the simulation is checked against the real generated C before anything is
attributed: if the all-on arm does not track the C, the attribution is worthless.
"""
from __future__ import annotations
import argparse, json, os, sys
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "moonshine"))
import _paths                                # noqa: E402
import make_data as md                   # noqa: E402
from model import SignDetLite, GRID      # noqa: E402
import hostrun                           # noqa: E402
from b147_negatives import peak_obj, float_probs, int8_probs   # noqa: E402
from b147_band import margin, LO, HI     # noqa: E402

LAYERS = ["conv1", "conv2", "conv3", "conv4", "conv5", "head"]
ACT_OF = {"conv1": "relu", "conv2": "relu_1", "conv3": "relu_2",
          "conv4": "relu_3", "conv5": "relu_4", "head": "head"}


def fq(t, s, lo, hi):
    return torch.clamp(torch.round(t / s), lo, hi) * s


@torch.no_grad()
def run(m, X, sc, wq, qin, qw, qact):
    """forward with any subset of {input, weight, activation} quantisers engaged."""
    x = torch.from_numpy(X.astype(np.float32) / 255.0).permute(0, 3, 1, 2)
    if qin:
        x = fq(x, sc["x"], 0, 127)
    for L in LAYERS:
        c = getattr(m, L)
        w = wq[L] if qw else c.weight.detach()
        x = torch.nn.functional.conv2d(x, w, c.bias.detach(), c.stride, c.padding)
        if L != "head":
            x = torch.relu(x)
        if qact:
            a = ACT_OF[L]
            x = fq(x, sc[a], -128 if L == "head" else 0, 127)
    return torch.softmax(x, dim=1).numpy()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ir", default=_paths.out("signdet/ir"))
    ap.add_argument("--gen", default=_paths.out("signdet/gen"))
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--gtsdb", default=_paths.work("b144/data/FullIJCNN2013"))
    ap.add_argument("--probs", default=_paths.work("b147/run/probs.npz"))
    ap.add_argument("--labels", default=_paths.work("b147/labels.json"))
    ap.add_argument("--workdir", default=_paths.work("b147/hostc"))
    ap.add_argument("--out", default=_paths.work("b147/run"))
    ap.add_argument("--want", type=int, default=300)
    a = ap.parse_args()

    g = json.load(open(os.path.join(a.ir, "graph.json")))
    sc = {t: float(g["tensors"][t]["quant"]["scale"]) for t in
          ["x", "relu", "relu_1", "relu_2", "relu_3", "relu_4", "head"]}
    W = np.load(os.path.join(a.ir, "weights.npz"))
    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()

    # the graph's own int8 weights, dequantised with the per-output-channel scale the
    # codegen implies; checked against a round-trip of the float weights before use.
    wq, chk = {}, []
    for L in LAYERS:
        Wf = getattr(m, L).weight.detach()
        s = Wf.abs().amax(dim=(1, 2, 3), keepdim=True) / 127.0
        q = torch.clamp(torch.round(Wf / s), -127, 127)
        stored = torch.from_numpy(W[L + ".weight_q"].astype(np.float32))
        chk.append((L, float((q - stored).abs().max()), float((q != stored).float().mean())))
        wq[L] = (q * s)

    z = np.load(a.probs)
    Xb = z["X8"]
    ob = peak_obj(z["P_f"])
    selb = (ob >= LO) & (ob <= HI)
    rng = np.random.default_rng(7)
    got = []
    while len(got) < a.want:
        X = np.stack([md.camera_sim(md.indoor_bg(rng), rng) for _ in range(1000)])
        o = peak_obj(float_probs(m, X))
        got.extend(list(X[(o >= LO) & (o <= HI)]))
    Xi = np.stack(got[:a.want])

    L_ = []
    def p(s=""):
        print(s); L_.append(s)
    p("B147  attributing the one-sided int8 bias")
    p()
    p("weight round-trip check (simulated per-channel int8 vs the IR's stored weight_q)")
    for nm, mx, fr in chk:
        p("  %-6s max |diff| %d level(s), %.3f %% of taps differ" % (nm, int(mx), 100 * fr))
    p()

    # fidelity of the simulation against the real generated C, on the bench frames
    exe = hostrun.build(a.gen, a.workdir)
    oq = g["tensors"][g["output"]["tensor"]]["quant"]
    Pc = int8_probs(exe, Xb, a.workdir, float(oq["scale"]), int(oq["zero_point"]))
    Psim = run(m, Xb, sc, wq, True, True, True)
    mc, _ = margin(Pc); ms, _ = margin(Psim); mf, _ = margin(z["P_f"])
    p("simulation fidelity on the 78 bench frames (logit margin at the peak cell):")
    p("  real C   - float : mean %+.4f" % (mc - mf).mean())
    p("  all-on   - float : mean %+.4f" % (ms - mf).mean())
    p("  all-on   - real C: mean %+.4f  sd %.4f  (the C's own requant rounding, not modelled)"
      % ((ms - mc).mean(), (ms - mc).std(ddof=1)))
    p()
    p("%-34s %18s %18s" % ("quantiser engaged", "bench band n=%d" % selb.sum(),
                           "indoor band n=%d" % len(Xi)))
    base = {"bench": mf[selb]}
    Pif = float_probs(m, Xi); mif, _ = margin(Pif)
    for nm, qin, qw, qact in (("input only", True, False, False),
                              ("weights only (per-channel)", False, True, False),
                              ("activation rounding only", False, False, True),
                              ("input + weights", True, True, False),
                              ("all three", True, True, True)):
        mb_, _ = margin(run(m, Xb[selb], sc, wq, qin, qw, qact))
        mi_, _ = margin(run(m, Xi, sc, wq, qin, qw, qact))
        p("%-34s %+18.4f %+18.4f" % (nm, (mb_ - base["bench"]).mean(), (mi_ - mif).mean()))
    p()
    p("(positive = the quantiser pushes the peak cell TOWARDS a sign, i.e. towards a false STOP)")
    open(os.path.join(a.out, "ablate.txt"), "w").write("\n".join(L_) + "\n")
    print("\nwrote %s/ablate.txt" % a.out)


if __name__ == "__main__":
    main()
