#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Turn a raw HM01B0 capture into something a person can look at.

    cam_view.py --pgm out/rocket_cam/frame.pgm --out out/rocket_cam/view
    cam_view.py --raw frame.bin --width 324 --height 244 --out <dir>
    cam_view.py --selftest                      # no camera needed

***THE COLOUR PART IS A BAYER MOSAIC, NOT A PICTURE.***  scripts/66 writes `frame.pgm` straight
from the bytes the DMA landed in DDR, so on the colour HM01B0 each pixel is one colour channel
under a Bayer filter and the PGM looks like fine checkerboard texture.  Viewing it as grey is
correct and useful -- it is the sensor's actual output -- but it is not the photograph.

WHAT THIS EMITS
  mosaic.png    the raw bytes, greyscale, exactly as captured.  This is the evidence.
  rgb.png       bilinear demosaic to colour.  This is the picture.
  stats.json    min/max/mean/stdev AND the two structure metrics below.

***THE METRIC THAT SEPARATES AN IMAGE FROM NOISE, AND WHY A CHECKSUM CANNOT.***  scripts/66
already cross-checks the guest's checksum against the PS reading the same DDR -- that proves the
two agree on the bytes, not that the bytes are a scene.  All-zeros, all-0xFF, a stuck bus and
uniform noise all checksum fine.  Two cheap discriminators:

  bayer_ratio   mean |difference| between pixels 2 apart (same colour plane) divided by the same
                between pixels 1 apart (different planes).  A Bayer frame of a real scene has
                MORE correlation within a plane than across planes, so this sits BELOW 1.
                White noise has no such structure and sits AT 1.
  neighbour_r   Pearson correlation between a pixel and its same-plane neighbour.  A scene is
                strongly positive; noise is ~0; a stuck/constant buffer is undefined (zero
                variance) and is reported as such rather than as a number.

Neither is a substitute for CHANGING WHAT THE LENS SEES and watching the numbers move.  That is
the only test that cannot be passed by a convincing artefact, and it needs a person at the bench.
"""
import argparse, json, os, sys
import numpy as np


def read_pgm(path):
    with open(path, "rb") as f:
        raw = f.read()
    if not raw.startswith(b"P5"):
        sys.exit("%s is not a binary PGM (P5)" % path)
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(raw) and raw[i:i + 1].isspace():
            i += 1
        if raw[i:i + 1] == b"#":
            while i < len(raw) and raw[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(raw) and not raw[j:j + 1].isspace():
            j += 1
        fields.append(int(raw[i:j])); i = j
    i += 1
    w, h, maxv = fields
    if maxv > 255:
        sys.exit("16-bit PGM not handled")
    return np.frombuffer(raw[i:i + w * h], dtype=np.uint8).reshape(h, w).copy()


def structure(a):
    """The two discriminators. Returns dict; never raises on a constant frame."""
    x = a.astype(np.float64)
    out = {}
    if x.std() == 0.0:
        return {"constant": True, "bayer_ratio": None, "neighbour_r": None,
                "note": "every pixel identical -- no structure to measure"}
    out["constant"] = False
    d1 = np.abs(np.diff(x, axis=1)).mean()              # adjacent: crosses colour planes
    d2 = np.abs(x[:, 2:] - x[:, :-2]).mean()            # 2 apart: same colour plane
    out["mean_abs_diff_1"] = d1
    out["mean_abs_diff_2"] = d2
    out["bayer_ratio"] = (d2 / d1) if d1 else None
    p, q = x[:, :-2].ravel(), x[:, 2:].ravel()
    out["neighbour_r"] = float(np.corrcoef(p, q)[0, 1]) if p.std() and q.std() else None
    return out


def demosaic(a, pattern="BGGR"):
    """Bilinear demosaic. Small, dependency-free, and good enough to SEE the scene."""
    h, w = a.shape
    x = a.astype(np.float64)
    R = np.zeros((h, w)); G = np.zeros((h, w)); B = np.zeros((h, w))
    p = pattern.upper()
    # offsets of the R pixel within the 2x2 tile
    ro = {"RGGB": (0, 0), "BGGR": (1, 1), "GRBG": (0, 1), "GBRG": (1, 0)}[p]
    bo = (1 - ro[0], 1 - ro[1])
    R[ro[0]::2, ro[1]::2] = x[ro[0]::2, ro[1]::2]
    B[bo[0]::2, bo[1]::2] = x[bo[0]::2, bo[1]::2]
    G[ro[0]::2, bo[1]::2] = x[ro[0]::2, bo[1]::2]
    G[bo[0]::2, ro[1]::2] = x[bo[0]::2, ro[1]::2]

    def fill(P):
        M = (P > 0).astype(np.float64)
        acc = np.zeros_like(P); cnt = np.zeros_like(P)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                acc += np.roll(np.roll(P, dy, 0), dx, 1)
                cnt += np.roll(np.roll(M, dy, 0), dx, 1)
        out = np.where(M > 0, P, np.divide(acc, np.maximum(cnt, 1)))
        return out
    return np.clip(np.dstack([fill(R), fill(G), fill(B)]), 0, 255).astype(np.uint8)


def emit(a, outdir, pattern):
    from PIL import Image
    os.makedirs(outdir, exist_ok=True)
    Image.fromarray(a, "L").save(os.path.join(outdir, "mosaic.png"))
    rgb = demosaic(a, pattern)
    Image.fromarray(rgb, "RGB").save(os.path.join(outdir, "rgb.png"))
    st = {"width": int(a.shape[1]), "height": int(a.shape[0]),
          "min": int(a.min()), "max": int(a.max()),
          "mean": float(a.mean()), "stdev": float(a.std()),
          "bayer_pattern_assumed": pattern}
    st.update(structure(a))
    json.dump(st, open(os.path.join(outdir, "stats.json"), "w"), indent=1)
    print("wrote %s/{mosaic.png,rgb.png,stats.json}" % outdir)
    print("  %dx%d  min %d max %d mean %.2f stdev %.2f"
          % (st["width"], st["height"], st["min"], st["max"], st["mean"], st["stdev"]))
    if st.get("constant"):
        print("  ***CONSTANT FRAME -- every pixel identical.  This is not an image.***")
    else:
        print("  bayer_ratio %.3f (a scene is < 1; white noise is ~1)" % st["bayer_ratio"])
        print("  neighbour_r %.3f (a scene is strongly positive; noise ~0)" % st["neighbour_r"])
    return st


def selftest():
    """The metrics must SEPARATE a scene from noise, or they are decoration."""
    rng = np.random.default_rng(7)
    h, w = 244, 324
    yy, xx = np.mgrid[0:h, 0:w]
    scene = (110 + 90 * np.sin(xx / 23.0) * np.cos(yy / 31.0))
    bay = scene.copy()
    bay[0::2, 0::2] *= 1.25; bay[1::2, 1::2] *= 0.75          # a crude CFA gain split
    bay = np.clip(bay, 0, 255).astype(np.uint8)
    noise = rng.integers(0, 256, (h, w), dtype=np.uint8)
    flat = np.full((h, w), 37, dtype=np.uint8)
    s, n, f = structure(bay), structure(noise), structure(flat)
    print("scene : bayer_ratio %.3f  neighbour_r %+.3f" % (s["bayer_ratio"], s["neighbour_r"]))
    print("noise : bayer_ratio %.3f  neighbour_r %+.3f" % (n["bayer_ratio"], n["neighbour_r"]))
    print("flat  : constant=%s" % f["constant"])
    ok = (s["bayer_ratio"] < 0.9 and s["neighbour_r"] > 0.5
          and abs(n["bayer_ratio"] - 1.0) < 0.15 and abs(n["neighbour_r"]) < 0.15
          and f["constant"])
    print("SELFTEST", "PASS -- the metrics separate a scene from noise" if ok else "***FAIL***")
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--pgm"); ap.add_argument("--raw")
    ap.add_argument("--width", type=int, default=324); ap.add_argument("--height", type=int, default=244)
    ap.add_argument("--out", default="cam_view")
    ap.add_argument("--pattern", default="BGGR", choices=["RGGB", "BGGR", "GRBG", "GBRG"])
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest())
    if a.pgm:
        img = read_pgm(a.pgm)
    elif a.raw:
        img = np.fromfile(a.raw, dtype=np.uint8)[:a.width * a.height].reshape(a.height, a.width)
    else:
        sys.exit("need --pgm, --raw or --selftest")
    emit(img, a.out, a.pattern)
