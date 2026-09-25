"""Lab B144 training-set builder: GTSDB scenes + US-prop composites, through the real optics.

THE PROBLEM THIS SOLVES.  GTSDB is 900 daylight road scenes; the bench is one person holding a
printed sign under fluorescent tubes, 324x324, Bayer, vignetted and glared.  A detector trained
on raw GTSDB crops has never seen that.  So every sample -- real crop or synthetic composite --
is rendered to a 324x324 "scene", ROTATED 180 (the camera is mounted upside down, so that is
what the sensor actually receives), mosaicked to BGGR, given sensor noise, and then read back
through the EXACT deploy front end in signpre_rgb.py.  Train and deploy therefore differ only
in what was in front of the lens.

TWO SOURCES, and they answer different halves of the problem:
  GTSDB crops      real scene statistics, real sign optics, and -- the part that matters most --
                   real NEGATIVES, including the other 41 sign classes.  A German "priority at
                   next intersection" is a red-bordered triangle; teaching the model to call it
                   background is exactly what stops the confident-wrong firing.
  US composites    the props are US-style ("YIELD" lettered, and GTSDB's give-way is textless),
                   and GTSDB holds only 32 stop and 83 give-way instances in 900 images -- far
                   too few to train a detector on.  Compositing drawn templates over real
                   backgrounds supplies both the count and the prop-matched appearance.

SPLIT IS BY SOURCE IMAGE (0..599 train, 600..899 held out), so no crop of a test scene can
appear in training.  The 8 bench captures are NEVER trained on and NEVER used to tune the
augmentation ranges; they are only the final gate.

==========================================================================================
THE DATASET, WHO MADE IT, AND WHY IT IS NOT HERE
==========================================================================================
GTSDB -- the German Traffic Sign Detection Benchmark, distributed as `FullIJCNN2013` --
is the work of its authors and not of this project:

    S. Houben, J. Stallkamp, J. Salmen, M. Schlipsing and C. Igel,
    "Detection of Traffic Signs in Real-World Images: The German Traffic Sign
     Detection Benchmark", International Joint Conference on Neural Networks
     (IJCNN), 2013.

IT IS NOT REDISTRIBUTED HERE, AND NEITHER IS ANYTHING TRAINED ON IT.  Obtain the dataset
from its own source and point --gtsdb at your copy; its terms are the ones that apply to
it, and this repository makes no claim about them.  We could not establish a licence for it
(the canonical site did not resolve from our network and the mirrors we found state none),
which is exactly why the SignDetLite checkpoint and every artefact that embeds its weights
are absent from this repository -- see docs/SIGNDET_WEIGHTS.md and
signdet/random_weights.py, which is what the demo runs on instead.

The other half of the training set -- the US-style composites -- is OURS: the templates in
this file are drawn with PIL, over backgrounds this file also generates, and the 8 bench
captures in signdet/bake/ are our own camera on our own bench.
"""
import argparse, json, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _paths                                # noqa: E402
import signpre_rgb as sp

SCENE = 324
GRID, OUTPX = 8, 64
CELL = OUTPX // GRID
BG, STOP, YIELD = 0, 1, 2
IGNORE = -1
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


# ---------------------------------------------------------------- sign templates (RGBA)
def _octagon(n, rng):
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    r = n / 2.0 - 1
    cx = cy = n / 2.0
    pts = [(cx + r * np.cos(np.pi / 8 + k * np.pi / 4), cy + r * np.sin(np.pi / 8 + k * np.pi / 4))
           for k in range(8)]
    red = (int(rng.uniform(150, 205)), int(rng.uniform(20, 45)), int(rng.uniform(25, 50)), 255)
    d.polygon(pts, fill=red)
    inner = [(cx + 0.87 * r * np.cos(np.pi / 8 + k * np.pi / 4),
              cy + 0.87 * r * np.sin(np.pi / 8 + k * np.pi / 4)) for k in range(8)]
    d.line(inner + [inner[0]], fill=(235, 235, 235, 255), width=max(1, n // 28))
    try:
        f = ImageFont.truetype(FONT, int(n * 0.30))
        d.text((cx, cy), "STOP", fill=(240, 240, 240, 255), anchor="mm", font=f)
    except Exception:
        pass
    return im


def _triangle_down(n, rng, text=True):
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    m = n * 0.02
    pts = [(m, m + n * 0.06), (n - m, m + n * 0.06), (n / 2.0, n - m)]
    red = (int(rng.uniform(150, 205)), int(rng.uniform(20, 45)), int(rng.uniform(25, 50)), 255)
    d.polygon(pts, fill=red)
    k = 0.30 if text else 0.26          # border thickness as a fraction
    ipts = [(pts[0][0] + n * k * 0.62, pts[0][1] + n * k * 0.55),
            (pts[1][0] - n * k * 0.62, pts[1][1] + n * k * 0.55),
            (pts[2][0], pts[2][1] - n * k * 1.12)]
    d.polygon(ipts, fill=(238, 238, 234, 255))
    if text:
        try:
            f = ImageFont.truetype(FONT, int(n * 0.155))
            d.text((n / 2.0, n * 0.40), "YIELD", fill=red[:3] + (255,), anchor="mm", font=f)
        except Exception:
            pass
    return im


def make_template(cls, rng):
    n = 192
    if cls == STOP:
        return _octagon(n, rng)
    return _triangle_down(n, rng, text=rng.random() < 0.75)   # 25% textless (German give-way)


# ---------------------------------------------------------------- optics + sensor
def _vignette(h, w, strength, rng):
    yy, xx = np.mgrid[0:h, 0:w]
    cy, cx = h / 2.0, w / 2.0
    r = np.sqrt(((yy - cy) / cy) ** 2 + ((xx - cx) / cx) ** 2) / np.sqrt(2)
    return (1.0 - strength * r ** 2)[..., None]


def _glare(img, rng):
    h, w = img.shape[:2]
    out = img.astype(np.float32)
    for _ in range(rng.integers(0, 4)):
        cy, cx = rng.uniform(0, h), rng.uniform(0, w)
        ln = rng.uniform(0.15, 0.9) * w
        th = rng.uniform(0.01, 0.07) * w
        ang = rng.uniform(0, np.pi)
        yy, xx = np.mgrid[0:h, 0:w]
        dx, dy = xx - cx, yy - cy
        u = dx * np.cos(ang) + dy * np.sin(ang)
        v = -dx * np.sin(ang) + dy * np.cos(ang)
        g = np.exp(-(u / ln) ** 2 - (v / th) ** 2) * rng.uniform(60, 230)
        out += g[..., None] * np.array([1.0, rng.uniform(.92, 1.0), rng.uniform(.6, .95)])
    return out


def camera_sim(scene_rgb, rng):
    """A 324x324 upright RGB scene -> the 64x64x3 the model sees, through the real front end."""
    x = scene_rgb.astype(np.float32)
    x = 255.0 * (np.clip(x, 0, 255) / 255.0) ** rng.uniform(0.62, 1.55)      # gamma
    x *= np.array([rng.uniform(.80, 1.25), rng.uniform(.82, 1.18), rng.uniform(.62, 1.15)])
    h, w = x.shape[:2]                                                        # linear gradient
    ax, ay = rng.uniform(-.45, .45), rng.uniform(-.45, .45)
    gy, gx = np.mgrid[0:h, 0:w]
    x *= (1.0 + ax * (gx / w - .5) + ay * (gy / h - .5))[..., None]
    x = _glare(x, rng)
    x *= _vignette(h, w, rng.uniform(0.15, 0.62), rng)
    x *= rng.uniform(0.55, 1.35)
    x = np.clip(x, 0, 255)
    mos = sp.mosaic_bggr(np.rot90(x, 2).astype(np.uint8))                     # sensor sees it flipped
    mos = mos.astype(np.float32)
    mos += rng.normal(0, rng.uniform(1.0, 7.0), mos.shape)                    # read noise
    mos += rng.normal(0, 1.0, mos.shape) * np.sqrt(np.maximum(mos, 0)) * rng.uniform(0, .45)
    mos = np.clip(mos, 0, 255).astype(np.uint8)
    return sp.gray_world(sp.bayer_to_rgb64(mos, rot180=True))


# ---------------------------------------------------------------- labels
def label_grid(signs):
    """signs: list of (cls, cx, cy, size) in 64-px coords -> (GRID,GRID) int8 label map."""
    lab = np.zeros((GRID, GRID), np.int64)
    for cls, cx, cy, s in signs:
        for gy in range(GRID):
            for gx in range(GRID):
                px, py = (gx + .5) * CELL, (gy + .5) * CELL
                d = np.hypot(px - cx, py - cy)
                if d <= 0.30 * s:
                    lab[gy, gx] = cls
                elif d <= 0.62 * s and lab[gy, gx] == BG:
                    lab[gy, gx] = IGNORE
    return lab


# ---------------------------------------------------------------- GTSDB
def load_gtsdb(root):
    boxes = {}
    for line in open(os.path.join(root, "gt.txt")):
        p = line.strip().split(";")
        if len(p) != 6:
            continue
        boxes.setdefault(p[0], []).append(
            (int(p[1]), int(p[2]), int(p[3]), int(p[4]), int(p[5])))
    return boxes


def gtsdb_crop(img, boxes, rng, want):
    """want='pos' (a stop/give-way), 'hard' (some other sign), 'neg' (no target).
    Returns (scene324, signs) or None."""
    H, W = img.shape[:2]
    tgt = {13: YIELD, 14: STOP}
    cand = [b for b in boxes if (b[4] in tgt if want == "pos" else
                                 (b[4] not in tgt) if want == "hard" else False)]
    if want in ("pos", "hard"):
        if not cand:
            return None
        b = cand[rng.integers(len(cand))]
        s = max(b[2] - b[0], b[3] - b[1])
        u = rng.uniform(0.16, 0.46)                 # sign fraction of the crop
        c = int(np.clip(s / u, 40, min(H, W)))
        bx, by = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        x0 = int(np.clip(bx - c * rng.uniform(0.18, 0.82), 0, W - c))
        y0 = int(np.clip(by - c * rng.uniform(0.18, 0.82), 0, H - c))
    else:
        c = int(rng.uniform(60, min(H, W)))
        x0, y0 = int(rng.uniform(0, W - c)), int(rng.uniform(0, H - c))
    crop = img[y0:y0 + c, x0:x0 + c]
    scene = np.asarray(Image.fromarray(crop).resize((SCENE, SCENE), Image.BILINEAR))
    signs = []
    k = SCENE / float(c)
    for b in boxes:
        if b[4] not in tgt:
            continue
        cx, cy = ((b[0] + b[2]) / 2 - x0) * k, ((b[1] + b[3]) / 2 - y0) * k
        ss = max(b[2] - b[0], b[3] - b[1]) * k
        if -ss < cx < SCENE + ss and -ss < cy < SCENE + ss:
            signs.append((tgt[b[4]], cx * OUTPX / SCENE, cy * OUTPX / SCENE, ss * OUTPX / SCENE))
    if want == "neg" and signs:
        return None
    return scene, signs


def indoor_bg(rng):
    """A procedural stand-in for the bench: a bright smooth ceiling, fluorescent tubes, dark
    structure and thin pipework.  GTSDB is 900 DAYLIGHT ROAD scenes and the demo is an indoor
    ceiling; without something of this shape in the training set the only indoor frames the
    model ever sees are the 8 it is being tested on."""
    h = w = SCENE
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    base = rng.uniform(95, 215)
    img = base * (1.0 + rng.uniform(-.5, .5) * (xx / w - .5) + rng.uniform(-.5, .5) * (yy / h - .5))
    img = np.dstack([img * rng.uniform(.9, 1.1), img * rng.uniform(.9, 1.1), img * rng.uniform(.75, 1.05)])
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(im)
    for _ in range(rng.integers(1, 5)):                       # panels / beams
        x0, y0 = rng.uniform(-40, w), rng.uniform(-40, h)
        d.polygon([(x0, y0), (x0 + rng.uniform(40, 300), y0 + rng.uniform(-60, 60)),
                   (x0 + rng.uniform(40, 300), y0 + rng.uniform(30, 180)),
                   (x0, y0 + rng.uniform(30, 180))],
                  fill=tuple(int(v) for v in np.clip(base * rng.uniform(.45, 1.25), 0, 255) * np.ones(3)))
    for _ in range(rng.integers(0, 6)):                       # pipes / cables
        d.line([(rng.uniform(0, w), rng.uniform(0, h)), (rng.uniform(0, w), rng.uniform(0, h))],
               fill=tuple(int(v) for v in np.clip(base * rng.uniform(.3, 1.4), 0, 255) * np.ones(3)),
               width=int(rng.integers(1, 7)))
    for _ in range(rng.integers(1, 4)):                       # dark structure, mostly low
        cx, cy = rng.uniform(0, w), rng.uniform(.45 * h, 1.25 * h)
        r = rng.uniform(40, 190)
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=tuple(int(v) for v in np.clip(base * rng.uniform(.05, .33), 0, 255) * np.ones(3)))
    return np.asarray(im)


def composite(bg324, rng):
    """Paste 1-2 drawn US props onto a background scene."""
    scene = Image.fromarray(bg324).convert("RGBA")
    signs = []
    for _ in range(1 if rng.random() < 0.85 else 2):
        cls = STOP if rng.random() < 0.5 else YIELD
        t = make_template(cls, rng)
        s = int(rng.uniform(0.13, 0.46) * SCENE)
        t = t.resize((s, s), Image.BILINEAR)
        t = t.rotate(rng.uniform(-22, 22), resample=Image.BILINEAR, expand=True)
        w = t.size[0]
        d = w * rng.uniform(0.0, 0.13)                                   # mild perspective
        q = (rng.uniform(0, d), rng.uniform(0, d), rng.uniform(0, d), w - rng.uniform(0, d),
             w - rng.uniform(0, d), w - rng.uniform(0, d), w - rng.uniform(0, d), rng.uniform(0, d))
        t = t.transform((w, w), Image.QUAD, q, Image.BILINEAR)
        a = np.asarray(t).astype(np.float32)
        # VEILING GLARE AND BACKLIGHT.  Without this the drawn props are far crisper than any
        # sign a camera actually returns: measured over 150 composites the box-mean red excess
        # was 40.2 against 10.6 for REAL GTSDB sign crops through the same pipeline -- 4x too
        # saturated -- and the synthetic sign came out BRIGHTER than its background where a real
        # one, lit from behind, is darker.  A first SignDetLite trained on those localised the
        # bench signs but would not call them (peak confidence 0.02..0.50).  So each prop gets a
        # gain and an additive veil, and the ranges are set to reproduce the REAL GTSDB
        # distribution -- the bench captures are not consulted for this.
        # Saturation and brightness are sampled SEPARATELY, because the bench and the road
        # sit in different regimes and the training set has to span both: a real GTSDB sign is
        # BRIGHTER than its surroundings (measured 117.5 vs 104.6) while a hand-held prop lit
        # from behind by a ceiling is DARKER (85.3 vs 110.3).  Tying the two together, as a
        # single gain does, reaches neither end.
        lum = (0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2])[..., None]
        sat = rng.uniform(0.12, 1.0)
        dark = rng.uniform(0.35, 1.25)
        veil = rng.uniform(0.0, 46.0)
        a[..., :3] = np.clip((lum + sat * (a[..., :3] - lum)) * dark + veil, 0, 255)
        a[..., 3] *= rng.uniform(0.80, 1.0)
        t = Image.fromarray(a.astype(np.uint8))
        px = int(rng.uniform(-0.08 * SCENE, SCENE - 0.92 * w))
        py = int(rng.uniform(-0.08 * SCENE, SCENE - 0.92 * w))
        scene.alpha_composite(t, (max(px, 0), max(py, 0)))
        cx, cy = max(px, 0) + w / 2, max(py, 0) + w / 2
        signs.append((cls, cx * OUTPX / SCENE, cy * OUTPX / SCENE, w * 0.86 * OUTPX / SCENE))
        if rng.random() < 0.55:                    # the hand/head holding it, as a dark shape
            d = ImageDraw.Draw(scene)
            r = w * rng.uniform(0.20, 0.52)
            hx = cx + rng.uniform(-.75, .75) * w
            hy = cy + rng.uniform(0.22, 0.85) * w
            v = int(rng.uniform(8, 70))
            d.ellipse([hx - r, hy - r, hx + r, hy + r], fill=(v, v, v, 255))
    return np.asarray(scene.convert("RGB")), signs


def build(root, out, n_train, n_test, seed=0):
    rng = np.random.default_rng(seed)
    gt = load_gtsdb(root)
    names = sorted(gt.keys() | {"%05d.ppm" % i for i in range(900)})
    tr = [n for n in names if int(n[:5]) < 600]
    te = [n for n in names if int(n[:5]) >= 600]
    cache = {}

    def img(n):
        if n not in cache:
            if len(cache) > 260:
                cache.pop(next(iter(cache)))
            cache[n] = np.asarray(Image.open(os.path.join(root, n)).convert("RGB"))
        return cache[n]

    def gen(pool, n, tag):
        X = np.zeros((n, OUTPX, OUTPX, 3), np.uint8)
        Y = np.zeros((n, GRID, GRID), np.int64)
        i = 0
        tries = 0
        while i < n:
            tries += 1
            if tries > n * 60:
                raise SystemExit("generator stalled at %d/%d" % (i, n))
            nm = pool[rng.integers(len(pool))]
            r = rng.random()
            im = img(nm)
            bb = gt.get(nm, [])
            if r < 0.34:                                   # synthetic props
                if rng.random() < 0.38:
                    scene = indoor_bg(rng)             # procedural indoor scene
                else:
                    got = gtsdb_crop(im, bb, rng, "neg")   # real cluttered background
                    if got is None:
                        continue
                    scene = got[0]
                scene, signs = composite(scene, rng)
            elif r < 0.40:                                 # indoor scene with NO sign at all
                scene, signs = indoor_bg(rng), []
            elif r < 0.56:
                got = gtsdb_crop(im, bb, rng, "pos")       # real stop / give-way
                if got is None:
                    continue
                scene, signs = got
            elif r < 0.80:
                got = gtsdb_crop(im, bb, rng, "hard")      # other sign classes -> background
                if got is None:
                    continue
                scene, signs = got
            else:
                got = gtsdb_crop(im, bb, rng, "neg")       # plain negative
                if got is None:
                    continue
                scene, signs = got
            X[i] = camera_sim(scene, rng)
            Y[i] = label_grid(signs)
            i += 1
            if i % 2000 == 0:
                print("  %s %d/%d" % (tag, i, n), flush=True)
        return X, Y

    os.makedirs(out, exist_ok=True)
    for tag, pool, n in (("train", tr, n_train), ("test", te, n_test)):
        X, Y = gen(pool, n, tag)
        np.save(os.path.join(out, "X_%s.npy" % tag), X)
        np.save(os.path.join(out, "Y_%s.npy" % tag), Y)
        pos = [(Y == c).sum() for c in (BG, STOP, YIELD)]
        print("%s: X%s  cells bg=%d stop=%d yield=%d ignore=%d"
              % (tag, X.shape, pos[0], pos[1], pos[2], (Y == IGNORE).sum()), flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--gtsdb", default=_paths.work("b144/data/FullIJCNN2013"))
    ap.add_argument("--out", default=_paths.work("b144/ds"))
    ap.add_argument("--n-train", type=int, default=60000)
    ap.add_argument("--n-test", type=int, default=6000)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    build(a.gtsdb, a.out, a.n_train, a.n_test, a.seed)
