"""TASK 4's GATE: the LOWERED int8 C, on the 8 real captures and on held-out data.

An IR that code-generates is not a model that still works.  This runs ModelBlaster's generated
model.c/kernels.c/buffers.c -- compiled unmodified by moonshine/hostrun.py against pext.h's
software model of the MBP instructions (MB_PEXT_HW=0) -- on exactly the bytes the board's
front end would hand it, and compares, per frame:

    float torch  vs  int8 host C

so the accuracy cost of the int8 lowering is a measured number and not an assumption.  The
input is produced by the C front end (libsign_pre_rgb.so), which is itself checked byte-exact
against signpre_rgb.py, so the whole chain from DMA bytes to class is the board's.
"""
from __future__ import annotations
import argparse, ctypes, glob, json, os, sys
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "moonshine"))
import _paths                                # noqa: E402
import signpre_rgb as sp                      # noqa: E402
from model import SignDetLite, GRID           # noqa: E402
import hostrun                                # noqa: E402

NAMES = ["background", "stop", "yield"]


def c_frontend(lib, path):
    raw = open(path, "rb").read()
    buf = (ctypes.c_uint8 * len(raw)).from_buffer_copy(raw)
    rgb = (ctypes.c_uint8 * (64 * 64 * 3))()
    lib.sign_pre_rgb64(buf, rgb)
    lib.sign_pre_rgb_wb(rgb)
    q = (ctypes.c_int8 * (64 * 64 * 3))()
    lib.sign_pre_rgb_quant(rgb, q)
    return (np.frombuffer(bytes(rgb), np.uint8).reshape(64, 64, 3),
            np.frombuffer(bytes(bytearray(x & 0xff for x in q)), np.int8))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", default=_paths.out("signdet/gen"))
    ap.add_argument("--ir", default=_paths.out("signdet/ir"))
    ap.add_argument("--ckpt", default=_paths.work("b144/run/signdet_b144.pt"))
    ap.add_argument("--lib", default=_paths.work("b144/libsign_pre_rgb.so"))
    ap.add_argument("--snaps", default=_paths.out("cam_snap/snaps"))
    ap.add_argument("--gt", default=os.path.join(HERE, "bench_groundtruth.json"))
    ap.add_argument("--workdir", default=_paths.work("b144/hostc"))
    ap.add_argument("--heldout", default=_paths.work("b144/run/calib_X.npy"))
    ap.add_argument("--thr", type=float, default=0.5)
    a = ap.parse_args()

    g = json.load(open(os.path.join(a.ir, "graph.json")))
    oq = g["tensors"][g["output"]["tensor"]]["quant"]
    oscale, ozp = float(oq["scale"]), int(oq["zero_point"])
    print("output quant: scale %.8g zero_point %d" % (oscale, ozp))

    print("building the generated C ...", flush=True)
    exe = hostrun.build(a.gen, a.workdir)
    lib = ctypes.CDLL(a.lib)
    m = SignDetLite(); m.load_state_dict(torch.load(a.ckpt, map_location="cpu")); m.eval()
    gt = json.load(open(a.gt))["images"]

    files = sorted(glob.glob(os.path.join(a.snaps, "*.raw")))
    X8, Q = [], []
    for f in files:
        rgb, q = c_frontend(lib, f)
        X8.append(rgb); Q.append(q)
    Q = np.stack(Q)
    outs = hostrun.batch(exe, Q, GRID * GRID * 3, a.workdir)
    P_c = (outs.astype(np.float32) - ozp) * oscale            # (8, 64*3) NHWC probabilities
    P_c = P_c.reshape(len(files), GRID, GRID, 3).transpose(0, 3, 1, 2)

    with torch.no_grad():
        xt = torch.from_numpy(np.stack(X8).astype(np.float32) / 255.0).permute(0, 3, 1, 2)
        P_f = torch.softmax(m.features(xt), dim=1).numpy()

    print("\n%-20s %-7s %-11s %-11s %7s %7s  %s" %
          ("image", "truth", "C int8", "torch f32", "conf_C", "conf_f", "agree"))
    agree = ok = 0
    for i, f in enumerate(files):
        n = os.path.basename(f)[:-4]
        r = []
        for P in (P_c[i], P_f[i]):
            obj = P[1:].max(axis=0)
            gy, gx = np.unravel_index(obj.argmax(), obj.shape)
            c = float(obj[gy, gx])
            r.append((NAMES[int(P[1:, gy, gx].argmax()) + 1] if c > a.thr else "background", c, gx, gy))
        agree += (r[0][0] == r[1][0])
        b = gt[n]["box"]
        cx = sp.OFF + (r[0][2] + .5) * sp.CROP / GRID
        cy = sp.OFF + (r[0][3] + .5) * sp.CROP / GRID
        inb = b[0] <= cx <= b[2] and b[1] <= cy <= b[3]
        ok += (r[0][0] == gt[n]["label"] and inb)
        print("%-20s %-7s %-11s %-11s %7.3f %7.3f  %s" %
              (n, gt[n]["label"], r[0][0], r[1][0], r[0][1], r[1][1],
               "yes" if r[0][0] == r[1][0] else "NO"))
    print("\nint8 C agrees with float torch on %d/%d frames" % (agree, len(files)))
    print("int8 C correct (class AND localised) on %d/%d frames" % (ok, len(files)))
    print("max |P_c - P_f| over all cells/classes/frames: %.4f" % np.abs(P_c - P_f).max())

    if os.path.exists(a.heldout):
        Xh = np.load(a.heldout)
        qh = np.clip((2 * 127 * Xh.astype(np.uint32) + 255) // 510, 0, 127)
        qh = qh.astype(np.int8).transpose(0, 3, 1, 2).reshape(len(Xh), -1)
        oh = hostrun.batch(exe, qh, GRID * GRID * 3, a.workdir)
        Pch = ((oh.astype(np.float32) - ozp) * oscale).reshape(len(Xh), GRID, GRID, 3).transpose(0, 3, 1, 2)
        with torch.no_grad():
            Pfh = torch.softmax(m.features(torch.from_numpy(Xh.astype(np.float32) / 255.0)
                                           .permute(0, 3, 1, 2)), dim=1).numpy()
        ac = Pch[:, 1:].max(1).reshape(len(Xh), -1)
        af = Pfh[:, 1:].max(1).reshape(len(Xh), -1)
        print("\nheld-out n=%d: peak-cell agreement %.4f | argmax-class agreement %.4f | "
              "max |dP| %.4f" % (len(Xh), (ac.argmax(1) == af.argmax(1)).mean(),
                                 (Pch.argmax(1) == Pfh.argmax(1)).mean(), np.abs(Pch - Pfh).max()))


if __name__ == "__main__":
    main()
