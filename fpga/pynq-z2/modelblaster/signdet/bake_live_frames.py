#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""LAB B146's REPLAY GATE: bake the 8 real HM01B0 captures, and the HOST's answer for each,
into C the board links.

WHY THIS EXISTS.  samples/signdet_live can only be trusted to see a sign when somebody proves
that the board, given the SAME raw DMA bytes, reaches the SAME answer as the host did -- with
nobody at the bench and no optics involved.  That is what SL_REPLAY does for the grey demo;
this is its colour, localising equivalent, and it is a good deal stricter: it bakes not only
the host's DECISION (class, peak cell, confidence) but the host's WHOLE 192-byte output
tensor, so a board that reaches the right class by a different route is still caught.

WHAT "THE HOST" MEANS HERE.  ModelBlaster's generated model.c/kernels.c/buffers.c compiled by
moonshine/hostrun.py against pext.h's SOFTWARE MODEL of the MBP instructions (MB_PEXT_HW=0) --
the same arithmetic B144's host_gate.py validated 8/8 against float torch, and the same golden
B145 gated its board measurement on.  The front end is the BOARD's own sign_pre_rgb.c,
compiled here as a shared library and driven through ctypes, so nothing in the chain from DMA
bytes to int8 tensor is a Python re-implementation.

THE LABELS ARE NOT THE FILENAMES.  out/cam_snap/snaps/snap_026_PRIORITY.raw is a YIELD sign:
the name records the OLD GTSRB classifier's confidently wrong guess.  Ground truth comes from
signdet/bench_groundtruth.json, which B144 hand-labelled with boxes.
"""
from __future__ import annotations
import argparse, ctypes, glob, json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MBDIR = os.path.dirname(HERE)                       # fpga/pynq-z2/modelblaster
SW = os.path.join(os.path.dirname(MBDIR), "sw")     # fpga/pynq-z2/sw
sys.path.insert(0, os.path.join(MBDIR, "moonshine"))
import hostrun                                      # noqa: E402

NAMES = ["background", "stop", "yield"]
SHORT = ["NO SIGN", "STOP", "YIELD"]
GRID = 8
FRAME_BYTES = 326 * 324


def build_frontend(workdir):
    """The BOARD's sign_pre_rgb.c, compiled as a .so -- not archive/b144's prebuilt copy.
    If the front end has changed since B144 this bake must see the change, not hide it."""
    so = os.path.join(workdir, "libsign_pre_rgb.so")
    src = os.path.join(SW, "cam", "sign_pre_rgb.c")
    subprocess.run([os.environ.get("HOST_CC", "cc"), "-O2", "-fPIC", "-shared", "-w",
                    f"-I{os.path.join(SW, 'cam')}", src, "-o", so], check=True)
    return ctypes.CDLL(so), so


def front_end(lib, path):
    raw = open(path, "rb").read()
    if len(raw) != FRAME_BYTES:
        sys.exit("%s is %d bytes, not the %d the DMA delivers" % (path, len(raw), FRAME_BYTES))
    buf = (ctypes.c_uint8 * len(raw)).from_buffer_copy(raw)
    rgb = (ctypes.c_uint8 * (64 * 64 * 3))()
    lib.sign_pre_rgb64(buf, rgb)
    lib.sign_pre_rgb_wb(rgb)
    q = (ctypes.c_int8 * (64 * 64 * 3))()
    lib.sign_pre_rgb_quant(rgb, q)
    return raw, np.frombuffer(bytes(bytearray(x & 0xff for x in q)), np.int8)


def decode(q192, scale, zp, thr):
    """EXACTLY samples/signdet_live/src/main.c's decode, and exactly host_gate.py's.

    P is (8, 8, 3) after the permute+view: cell index = gy * 8 + gx, class 0 background.
    obj = max over the two sign classes; the peak cell is the first maximum in (gy, gx)
    order; the class at that cell is the first maximum over {stop, yield}; below the
    threshold the answer is BACKGROUND and not a guess."""
    P = (q192.astype(np.int32) - zp).reshape(GRID, GRID, 3)
    obj = P[:, :, 1:].max(axis=2)
    flat = int(obj.argmax())                       # first maximum, row-major (gy, gx)
    gy, gx = divmod(flat, GRID)
    qbest = int(obj[gy, gx])
    cls = 2 if P[gy, gx, 2] > P[gy, gx, 1] else 1  # tie -> stop, as argmax does
    p = qbest * scale
    return (cls if p > thr else 0), gx, gy, qbest, p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", default="out/signdet/gen")
    ap.add_argument("--ir", default="out/signdet/ir")
    ap.add_argument("--snaps", default="out/cam_snap/snaps")
    ap.add_argument("--gt", default=os.path.join(HERE, "bench_groundtruth.json"))
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--out", required=True, help="directory for signdet_frames.{c,h}")
    ap.add_argument("--thr", type=float, default=0.5)
    a = ap.parse_args()

    os.makedirs(a.workdir, exist_ok=True)
    os.makedirs(a.out, exist_ok=True)

    g = json.load(open(os.path.join(a.ir, "graph.json")))
    oq = g["tensors"][g["output"]["tensor"]]["quant"]
    scale, zp = float(oq["scale"]), int(oq["zero_point"])
    import hashlib
    ir_md5 = hashlib.md5(open(os.path.join(a.ir, "graph.json"), "rb").read()).hexdigest()

    lib, so = build_frontend(a.workdir)
    print("front end: %s" % so)
    exe = hostrun.build(a.gen, a.workdir)
    print("host-C model: %s" % exe)

    # THE GATE SET IS THE GROUND TRUTH FILE'S LIST, NOT WHATEVER IS IN THE DIRECTORY, and
    # that is not fastidiousness.  The first version of this script globbed *.raw, and
    # out/cam_snap/snaps grew from 8 captures to 90 DURING a B146 board session: two
    # scripts/85_cam_snap_pull.sh processes had been tailing the board console since 12:26
    # and pulled every frame of the live demo into it.  The replay gate silently became 14
    # frames, 6 of them unlabelled, and the run still said PASS.  A gate whose membership
    # can be changed by an unrelated process running in another terminal is not a gate.
    gt = json.load(open(a.gt))["images"]
    files = [os.path.join(a.snaps, stem + ".raw") for stem in sorted(gt)]
    missing = [f for f in files if not os.path.exists(f)]
    if missing:
        sys.exit("bench_groundtruth.json names %d captures that are not in %s: %s"
                 % (len(missing), a.snaps, ", ".join(os.path.basename(m) for m in missing)))
    extra = sorted(set(glob.glob(os.path.join(a.snaps, "*.raw"))) - set(files))
    print("gate set: %d captures named in %s" % (len(files), os.path.basename(a.gt)))
    if extra:
        print("IGNORED: %d other .raw file(s) in %s are not in the ground truth and take no "
              "part in this gate" % (len(extra), a.snaps))

    raws, Q = [], []
    for f in files:
        raw, q = front_end(lib, f)
        raws.append(raw)
        Q.append(q)
    O = hostrun.batch(exe, np.stack(Q), GRID * GRID * 3, a.workdir)

    rows = []
    print("\n%-22s %-8s %-8s %7s  %s" % ("image", "truth", "host", "conf", "peak cell"))
    n_correct = 0
    for i, f in enumerate(files):
        stem = os.path.basename(f)[:-4]
        cls, gx, gy, qb, p = decode(O[i], scale, zp, a.thr)
        truth = gt[stem]["label"]
        n_correct += (NAMES[cls] == truth)
        print("%-22s %-8s %-8s %7.3f  %d,%d" % (stem, truth, NAMES[cls], p, gx, gy))
        rows.append(dict(stem=stem, truth=truth, cls=cls, gx=gx, gy=gy, q=qb,
                         pct=int(round(p * 100)), note=gt[stem].get("note", ""),
                         out=[int(v) for v in O[i]]))
    print("\nhost: %d/%d match the hand label at threshold %.2f" % (n_correct, len(files), a.thr))

    ch = os.path.join(a.out, "signdet_frames.h")
    cc = os.path.join(a.out, "signdet_frames.c")
    with open(ch, "w") as f:
        f.write("""/* @generated by fpga/pynq-z2/modelblaster/signdet/bake_live_frames.py -- do not edit. */
/*
 * Lab B146's replay gate.  Each entry is one REAL HM01B0 capture -- 324 lines of a 326-byte
 * stride, exactly what the DMA delivers -- together with the answer the HOST-C build of this
 * same generated model gave for it, decoded at the threshold named below.
 *
 * `host_out` is the host's WHOLE 192-byte output tensor, so a board that agrees on the class
 * but not on the tensor is still caught.  `truth` is B144's hand label; the FILENAME is not a
 * label -- it records the old GTSRB classifier's wrong guess.
 */
#ifndef SIGNDET_FRAMES_H
#define SIGNDET_FRAMES_H
#include <stdint.h>
""")
        f.write("#define SDF_N           %d\n" % len(rows))
        f.write("#define SDF_FRAME_BYTES %d\n" % FRAME_BYTES)
        f.write("#define SDF_OUT_LEN     %d\n" % (GRID * GRID * 3))
        f.write("#define SDF_GRID        %d\n" % GRID)
        f.write("#define SDF_THR_PCT     %d\n" % int(round(a.thr * 100)))
        f.write('#define SDF_IR_MD5      "%s"\n' % ir_md5)
        f.write("""
struct signdet_frame {
	const uint8_t *bytes;      /* SDF_FRAME_BYTES of raw Bayer, as the DMA delivers it */
	const int8_t  *host_out;   /* SDF_OUT_LEN of the host-C model's output */
	const char    *name;       /* the capture's file stem */
	const char    *truth;      /* B144's hand label: background / stop / yield */
	int8_t         host_cls;   /* 0 background, 1 stop, 2 yield -- at SDF_THR_PCT */
	int8_t         host_gx, host_gy;
	int8_t         host_q;     /* the peak cell's quantised objectness */
	uint8_t        host_pct;
	const char    *note;
};
extern const struct signdet_frame signdet_frames[SDF_N];
#endif /* SIGNDET_FRAMES_H */
""")

    def carray(name, data, typ="uint8_t"):
        parts = ["static const %s %s[] = {\n" % (typ, name)]
        for i in range(0, len(data), 16):
            chunk = data[i:i + 16]
            parts.append("\t" + ",".join("%d" % (v if typ == "uint8_t" else v) for v in chunk) + ",\n")
        parts.append("};\n")
        return "".join(parts)

    with open(cc, "w") as f:
        f.write("/* @generated by signdet/bake_live_frames.py -- do not edit. */\n")
        f.write('#include "signdet_frames.h"\n\n')
        for i, r in enumerate(rows):
            f.write(carray("f%d" % i, raws[i]))
            f.write(carray("o%d" % i, r["out"], "int8_t"))
        f.write("\nconst struct signdet_frame signdet_frames[SDF_N] = {\n")
        for i, r in enumerate(rows):
            f.write('\t{ f%d, o%d, "%s", "%s", %d, %d, %d, %d, %d, "%s" },\n'
                    % (i, i, r["stem"], r["truth"], r["cls"], r["gx"], r["gy"],
                       r["q"], r["pct"], r["note"].replace('"', "'")))
        f.write("};\n")

    json.dump(dict(thr=a.thr, scale=scale, zero_point=zp, ir_md5=ir_md5,
                   frames=[{k: v for k, v in r.items() if k != "out"} for r in rows]),
              open(os.path.join(a.out, "signdet_frames.json"), "w"), indent=1)
    print("\nwrote %s (%.1f MB) and %s" % (cc, os.path.getsize(cc) / 1e6, ch))


if __name__ == "__main__":
    main()
