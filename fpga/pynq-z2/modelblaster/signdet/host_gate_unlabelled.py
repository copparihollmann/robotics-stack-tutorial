"""B147: host_gate.py's float-vs-int8 comparison on frames that have NO ground-truth label.

host_gate.py scores the 8 hand-labelled bench captures against bench_groundtruth.json.  The
78 frames B146's live demo captured have no such file -- their filename suffix is the BOARD's
own int8 decision, not truth -- so this variant drops the --gt scoring and reports, per frame,
the numbers the false-positive question needs:

    peak objectness (1 - P(background), i.e. max over {stop,yield}), argmax class and peak cell
    for BOTH float torch and the generated int8 C,

and writes the full (N,3,8,8) probability tensors so a threshold can be swept afterwards.
The model loading and the C front end are host_gate's own, imported, so this is the same
pipeline and not a re-implementation of it.
"""
from __future__ import annotations
import argparse, glob, json, os, sys
import ctypes
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "moonshine"))
import _paths                                # noqa: E402
from host_gate import c_frontend, NAMES          # noqa: E402  -- the SAME front end
from model import SignDetLite, GRID              # noqa: E402
import hostrun                                   # noqa: E402


def peak(P):
    """(3,8,8) probabilities -> (objectness, class name, gx, gy) at the strongest cell."""
    obj = P[1:].max(axis=0)
    gy, gx = np.unravel_index(obj.argmax(), obj.shape)
    return float(obj[gy, gx]), NAMES[int(P[1:, gy, gx].argmax()) + 1], int(gx), int(gy)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", default=_paths.out("signdet/gen"))
    ap.add_argument("--ir", default=_paths.out("signdet/ir"))
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--lib", default=_paths.work("b144/libsign_pre_rgb.so"))
    ap.add_argument("--snaps", required=True)
    ap.add_argument("--workdir", default=_paths.work("b147/hostc"))
    ap.add_argument("--out", required=True, help="npz + json written here (a directory)")
    ap.add_argument("--thr", type=float, default=0.5)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    g = json.load(open(os.path.join(a.ir, "graph.json")))
    oq = g["tensors"][g["output"]["tensor"]]["quant"]
    oscale, ozp = float(oq["scale"]), int(oq["zero_point"])
    print("output quant: scale %.8g zero_point %d" % (oscale, ozp))

    print("building the generated C ...", flush=True)
    exe = hostrun.build(a.gen, a.workdir)
    lib = ctypes.CDLL(a.lib)
    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()

    files = sorted(glob.glob(os.path.join(a.snaps, "*.raw")))
    print("%d frames from %s" % (len(files), a.snaps))
    X8, Q = [], []
    for f in files:
        rgb, q = c_frontend(lib, f)
        X8.append(rgb); Q.append(q)
    Q = np.stack(Q)
    outs = hostrun.batch(exe, Q, GRID * GRID * 3, a.workdir)
    P_c = (outs.astype(np.float32) - ozp) * oscale
    P_c = P_c.reshape(len(files), GRID, GRID, 3).transpose(0, 3, 1, 2)
    with torch.no_grad():
        xt = torch.from_numpy(np.stack(X8).astype(np.float32) / 255.0).permute(0, 3, 1, 2)
        P_f = torch.softmax(m.features(xt), dim=1).numpy()

    rows = []
    print("\n%-22s %-9s %-7s %-5s %-9s %-7s %-5s %8s" %
          ("frame", "f32_obj", "f32_cls", "cell", "int8_obj", "int8_cls", "cell", "int8-f32"))
    for i, f in enumerate(files):
        n = os.path.basename(f)[:-4]
        of, cf, xf, yf = peak(P_f[i])
        oc, cc, xc, yc = peak(P_c[i])
        rows.append(dict(frame=n, board_suffix=n.rsplit("_", 1)[-1],
                         f32_obj=of, f32_cls=cf if of > a.thr else "background",
                         f32_cell=[xf, yf], f32_argmax_cls=cf,
                         int8_obj=oc, int8_cls=cc if oc > a.thr else "background",
                         int8_cell=[xc, yc], int8_argmax_cls=cc,
                         delta=oc - of, same_cell=(xf == xc and yf == yc)))
        print("%-22s %9.4f %-7s %d,%d   %9.4f %-7s %d,%d  %+8.4f" %
              (n, of, cf, xf, yf, oc, cc, xc, yc, oc - of))

    d = np.array([r["delta"] for r in rows])
    print("\nframes over %.2f : float %d/%d   int8 %d/%d" %
          (a.thr, sum(r["f32_obj"] > a.thr for r in rows), len(rows),
           sum(r["int8_obj"] > a.thr for r in rows), len(rows)))
    print("peak-objectness (int8 - float): mean %+.4f  median %+.4f  min %+.4f  max %+.4f" %
          (d.mean(), np.median(d), d.min(), d.max()))
    print("max |P_int8 - P_float| over all cells/classes/frames: %.4f" % np.abs(P_c - P_f).max())
    print("peak cell agrees on %d/%d" % (sum(r["same_cell"] for r in rows), len(rows)))

    np.savez_compressed(os.path.join(a.out, "probs.npz"), P_f=P_f, P_c=P_c,
                        files=np.array([os.path.basename(f) for f in files]),
                        X8=np.stack(X8))
    json.dump(rows, open(os.path.join(a.out, "perframe.json"), "w"), indent=1)
    print("wrote %s/{probs.npz,perframe.json}" % a.out)


if __name__ == "__main__":
    main()
