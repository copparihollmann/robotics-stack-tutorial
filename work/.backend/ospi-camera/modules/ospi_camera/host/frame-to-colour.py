#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Demosaic a raw HM01B0 capture into a colour PNG.

    python3 host/frame-to-colour.py frame.raw [width] [scale]

Options:
    --crop y0,y1,x0,x1   take a region before demosaicing
    --order RGGB|BGGR|GRBG|GBRG   force the phase assignment
    --binned             one output pixel per 2x2 tile (quarter resolution)
    --bilinear           plain bilinear demosaic instead of gradient-corrected
    --denoise            suppress colour speckles without smoothing luminance
    --no-wb              leave the channels raw
    --linear             skip the sRGB transfer curve
    --black N            black level in DN (default: measured from the frame)
    --sat S              saturation multiplier after demosaic (default 1.0)
    --ccm S              colour matrix strength, 0 = off, 1 = full (default 0.7)
    --rotate180          rotate the rendered RGB image for an inverted sensor
    --as-captured        demosaic only; no brightness, colour or transfer correction

Companion to frame-to-png.py, which renders the same buffer as greyscale and
decides whether a mosaic is present at all. This one assumes the answer is yes
and renders it, so the two are deliberately separate: nothing here should be
read as evidence FOR a mosaic.

CAPTURE THIS WITH BLACK LEVEL CORRECTION OFF (the default since the clamp was
found). With BLC on, every pixel at or below the sensor's dark reference leaves
as exactly BLC_TARGET x digital gain, so the picture arrives as one flat value
and no demosaic can recover it.

PHASE ASSIGNMENT. Which 2x2 phase carries red is a property of the FRAME, not of
the part: the first row read out depends on where the capture core armed, so the
lattice comes back row-swapped between captures and a hardcoded RGGB would swap
red with green about half the time.

So the greens are found by geometry rather than by brightness. A Bayer pattern
puts its two green pixels on a diagonal and they measure the same channel, so of
the two possible diagonals the green one is whichever pair agrees more closely.
That holds under any illuminant, which brightness does not: on the first colour
frame off this bench the red and green phase means were 145.1 and 146.8, and
ranking by brightness picked green as red.

Red and blue are then the other diagonal, and they are told apart by brightness
-- blue below red. That one IS an assumption about the light; it holds under
daylight and under every warm indoor source, and --order overrides it.

THE PIPELINE, in the order the steps have to happen:

  1. black level     subtracted before anything scales the data, because every
                     ratio below it -- white balance and the demosaic's own
                     gradients -- is a ratio of signal ABOVE black, and a
                     pedestal left in place flattens all of them toward 1.
  2. white balance   applied to the MOSAIC, not to the demosaiced image. The
                     interpolation mixes neighbouring channels, so balancing
                     afterwards is balancing a blend and leaves colour fringes
                     along every edge.
  3. demosaic        full resolution. Averaging each 2x2 tile into one pixel
                     (--binned, which is all this tool used to do) throws away
                     three quarters of the pixels and every edge with them.
  4. chroma denoise  optional 3x3 colour-only median, gated by luminance so it
                     does not mix across strong brightness edges. Enabled by
                     the notebook; does not smooth luminance or change the raw.
  5. colour matrix   the sensor's three filters overlap, so a red object puts
                     real signal into the blue pixels. White balance cannot
                     undo that -- it is a per-channel gain, and the gain that
                     makes a neutral surface neutral (blue x2.0 here) also
                     doubles the blue that leaked onto the red sign. A matrix
                     subtracts the cross-channel leak instead. Its rows sum to
                     1, so neutrals are left exactly where white balance put
                     them and only saturated colours move.
  6. highlight roll  a channel that clipped in the raw reads lower than it
                     really was, so a blown highlight comes out tinted -- cyan
                     where red clipped first. Blend to white with the overflow.
  7. sRGB curve      the sensor is linear and displays are not. Skipping this
                     is what makes a correct render look muddy and contrasty,
                     and it is a bigger effect on how "natural" the result
                     looks than anything else here.

WHITE BALANCE is grey-world, on by default, and computed from UNSATURATED
pixels only: with 17% of this frame clipped at 255, including those pixels drags
every channel mean toward the same ceiling and washes the correction out.
Without any correction the picture comes out strongly yellow-green, because
under warm indoor light this sensor's blue phase sits at roughly half of green
and nothing in the pipeline corrects for it. That imbalance is also what made
the blue phase look for a long time like a one-phase capture defect -- it is
constant across a neutral scene, exactly as a broken phase would be. --no-wb
leaves the channels raw, which is what any further colour measurement should
use.

THE COLOUR MATRIX IS GENERIC, NOT CALIBRATED for this part -- there is no
spectral measurement of these filters in this repository, and producing one
needs a target and a known illuminant. It is the usual shape for a small CMOS
sensor and it is applied because the alternative is worse: uncorrected, this
camera renders a stop sign as #E0A09A, a pale salmon, against a true value near
#B01116. Judge it by eye, and use --ccm 0 for any measurement, which leaves the
channels as white balance left them.

Strength defaults to 0.7 rather than 1.0 because the matrix multiplies the
dominant channel by 1.6, and on a brightly lit saturated object that clips:
at full strength the stop sign's red channel reaches 251 and the highlight
roll-off then blends it toward white, so the sign comes out PINKER than at 0.7
despite the stronger correction. 0.7 is the most correction this scene takes
before the red runs out of headroom.

DEMOSAIC is gradient-corrected linear interpolation (Malvar, He and Cutler
2004). Plain bilinear interpolates each channel over its own sparse lattice and
ignores the other two, which blurs edges and puts a zipper on every one of
them; the gradient correction uses the densely-sampled green to steer red and
blue, for very little arithmetic. --bilinear selects the plain version, which
is useful mainly for seeing what the correction is doing.
"""
import struct
import sys
import zlib
from statistics import median

SAT_DN = 250          # at or above this a raw sample is treated as clipped

# Generic small-sensor colour correction. Rows sum to 1.0 so a neutral stays
# neutral and only saturated colours are moved. See the note in the docstring:
# this is not a calibrated matrix for this part.
CCM = ((1.60, -0.40, -0.20),
       (-0.30, 1.60, -0.30),
       (-0.10, -0.60, 1.70))
KEYS = [(0, 0), (0, 1), (1, 0), (1, 1)]


def read_rows(path, width):
    data = open(path, "rb").read()
    rows = [data[i * width:(i + 1) * width] for i in range(len(data) // width)]
    # The two 0x00 dummy pixels that open each line are dropped. Two is even,
    # so the 2x2 phase lattice survives the crop; an odd crop would rotate the
    # column parity and swap red with green.
    return [list(r[2:]) for r in rows]


def phase_means(img):
    acc = {k: [0, 0] for k in KEYS}
    for y, row in enumerate(img):
        for x, v in enumerate(row):
            a = acc[(y & 1, x & 1)]
            a[0] += v
            a[1] += 1
    return {k: (s / n if n else 0.0) for k, (s, n) in acc.items()}


def assign_phases(means, order, log=print):
    """Return (red, green_a, green_b, blue) as 2x2 parities."""
    if order is not None:
        if sorted(order) != ["B", "G", "G", "R"]:
            sys.exit(f"--order {order}: expected two G and one each of R and B")
        greens = [k for k, c in zip(KEYS, order) if c == "G"]
        return (KEYS[order.index("R")], greens[0], greens[1],
                KEYS[order.index("B")])

    def disagreement(p, q):
        return abs(means[p] - means[q]) / max(means[p], means[q], 1e-9)

    main, anti = ((0, 0), (1, 1)), ((0, 1), (1, 0))
    greens = main if disagreement(*main) < disagreement(*anti) else anti
    rest = [k for k in KEYS if k not in greens]
    blue, red = sorted(rest, key=lambda k: means[k])
    log(f"  greens are the {'main' if greens == main else 'anti'}-diagonal "
        f"(they agree to {100 * disagreement(*greens):.1f}%; the other diagonal "
        f"differs by {100 * disagreement(*rest):.1f}%)")
    return red, greens[0], greens[1], blue


def estimate_black(img, red, blue):
    """Black level, as the 0.5th percentile of the frame.

    With BLC off there is no pedestal to remove in principle, but the ADC still
    sits a little above zero and the demosaic's gradients are ratios above
    black. Measured rather than assumed, because it moves with analog gain.
    This is a scene-based estimate, not a sensor calibration: scenes without
    dark areas can overestimate black. --black overrides it for measurements.
    A wholly clipped frame has no usable black reference; leave its level alone.
    """
    flat = sorted(v for row in img for v in row)
    estimate = float(flat[len(flat) // 200])
    return estimate if estimate < SAT_DN else 0.0


def white_balance_gains(img, red, green_a, green_b, blue, black):
    """Per-channel gains from unsaturated pixels, normalised to green."""
    tot = {k: [0.0, 0] for k in KEYS}
    for y, row in enumerate(img):
        p = y & 1
        for x, v in enumerate(row):
            if v >= SAT_DN:
                continue
            a = tot[(p, x & 1)]
            a[0] += max(0.0, v - black)
            a[1] += 1
    mean = {k: (s / n if n else 0.0) for k, (s, n) in tot.items()}
    g = (mean[green_a] + mean[green_b]) / 2.0
    if g <= 0:
        return {k: 1.0 for k in KEYS}, mean
    gains = {green_a: 1.0, green_b: 1.0,
             red: g / mean[red] if mean[red] > 0 else 1.0,
             blue: g / mean[blue] if mean[blue] > 0 else 1.0}
    return gains, mean


def plane(img, black, gains, sat_mask):
    """Black-subtracted, white-balanced mosaic as floats, plus a clip mask."""
    out = []
    for y, row in enumerate(img):
        p = y & 1
        line = []
        for x, v in enumerate(row):
            if v >= SAT_DN:
                sat_mask[y][x] = True
            line.append(max(0.0, v - black) * gains[(p, x & 1)])
        out.append(line)
    return out


def _at(m, y, x, H, W):
    """Mirrored edge access, so the 5x5 kernels need no special-casing."""
    def reflect(i, size):
        if size == 1:
            return 0
        i %= 2 * (size - 1)
        return min(i, 2 * (size - 1) - i)
    return m[reflect(y, H)][reflect(x, W)]


def demosaic(m, red, green_a, green_b, blue, gradient=True):
    """Malvar-He-Cutler (or bilinear) interpolation of a Bayer mosaic.

    The kernels are the published ones, scaled by 1/8. Rather than four hard
    cases they are written as a bilinear estimate plus the correction from the
    channel sampled at this pixel. At green sites the correction uses nine green
    samples, including the four diagonals, not just an axial second difference.
    See Figure 2: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/Demosaicing_ICASSP04.pdf
    """
    H, W = len(m), len(m[0])
    greens = {green_a, green_b}
    out = [[None] * W for _ in range(H)]

    for y in range(H):
        for x in range(W):
            k = (y & 1, x & 1)
            c = m[y][x]

            n_l = _at(m, y, x - 1, H, W)
            n_r = _at(m, y, x + 1, H, W)
            n_u = _at(m, y - 1, x, H, W)
            n_d = _at(m, y + 1, x, H, W)
            d_ul = _at(m, y - 1, x - 1, H, W)
            d_ur = _at(m, y - 1, x + 1, H, W)
            d_dl = _at(m, y + 1, x - 1, H, W)
            d_dr = _at(m, y + 1, x + 1, H, W)
            f_l = _at(m, y, x - 2, H, W)
            f_r = _at(m, y, x + 2, H, W)
            f_u = _at(m, y - 2, x, H, W)
            f_d = _at(m, y + 2, x, H, W)

            # Laplacians of the channel sampled AT this pixel, along each axis.
            lap_h = c - (f_l + f_r) / 2.0
            lap_v = c - (f_u + f_d) / 2.0
            lap = (lap_h + lap_v) / 2.0

            if k in greens:
                g = c
                # The two non-green channels: one lies left/right, the other
                # up/down, and which is which follows from the row parity.
                horiz = (n_l + n_r) / 2.0
                vert = (n_u + n_d) / 2.0
                if gradient:
                    diagonals = d_ul + d_ur + d_dl + d_dr
                    horiz += (5*c - (f_l + f_r + diagonals)
                              + 0.5*(f_u + f_d)) / 8.0
                    vert += (5*c - (f_u + f_d + diagonals)
                             + 0.5*(f_l + f_r)) / 8.0
                if (y & 1) == red[0]:
                    r, b = horiz, vert
                else:
                    r, b = vert, horiz
            else:
                # Green is the densely sampled channel: four orthogonal
                # neighbours, steered by the Laplacian of this pixel's own
                # channel.
                g = (n_l + n_r + n_u + n_d) / 4.0
                if gradient:
                    g += 0.5 * lap
                other = (d_ul + d_ur + d_dl + d_dr) / 4.0
                if gradient:
                    other += 0.75 * lap
                if k == red:
                    r, b = c, other
                else:
                    r, b = other, c

            out[y][x] = (r, g, b)
    return out


def chroma_denoise(rgb):
    """Median-filter chroma in similar-luminance neighbours; retain luminance.

    Operates in linear DN before the CCM and sRGB amplify low-level colour noise.
    A 3x3 window and an 8-DN luminance gate limit colour bleed at edges. This is
    display processing, not hot-pixel repair or evidence of a capture defect.
    """
    h, w = len(rgb), len(rgb[0])
    luma = [[0.299*r + 0.587*g + 0.114*b for r, g, b in row] for row in rgb]
    out = []
    for y in range(h):
        row = []
        for x in range(w):
            lum = luma[y][x]
            neighbours = [(rgb[j][i], luma[j][i])
                          for j in range(max(0, y-1), min(h, y+2))
                          for i in range(max(0, x-1), min(w, x+2))
                          if abs(luma[j][i] - lum) <= 8.0]
            r = lum + median(pixel[0] - v for pixel, v in neighbours)
            b = lum + median(pixel[2] - v for pixel, v in neighbours)
            g = (lum - 0.299*r - 0.114*b) / 0.587
            row.append((r, g, b))
        out.append(row)
    return out


SRGB_LUT = None


def srgb(v):
    """Linear 0..1 to sRGB 0..255."""
    if v <= 0.0031308:
        s = 12.92 * v
    else:
        s = 1.055 * (v ** (1.0 / 2.4)) - 0.055
    return max(0, min(255, int(s * 255.0 + 0.5)))


def encode(rgb, sat_mask, white, gamma=True, sat=1.0, ccm=1.0):
    """Normalise, roll off highlights, optionally saturate, then encode."""
    H, W = len(rgb), len(rgb[0])
    out = [[None] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            r, g, b = (v / white for v in rgb[y][x])
            r = max(0.0, r)
            g = max(0.0, g)
            b = max(0.0, b)

            if ccm != 0.0:
                # Blended with the identity so the strength is continuous, and
                # applied to LINEAR data -- a matrix on gamma-encoded values
                # shifts hue as well as saturation.
                m = [[(1.0 - ccm) * (i == j) + ccm * CCM[i][j]
                      for j in range(3)] for i in range(3)]
                r, g, b = (max(0.0, m[i][0] * r + m[i][1] * g + m[i][2] * b)
                           for i in range(3))

            # A raw sample that clipped reads lower than the light that hit it,
            # so a blown highlight comes out tinted rather than white -- cyan
            # where red clipped first. Blend to white in proportion to how far
            # past full scale the brightest channel is.
            m = max(r, g, b)
            if m > 1.0:
                f = min(1.0, m - 1.0)
                r += (1.0 - r) * f
                g += (1.0 - g) * f
                b += (1.0 - b) * f

            if sat != 1.0:
                # Around luma, so brightness is untouched.
                luma = 0.299 * r + 0.587 * g + 0.114 * b
                r = luma + (r - luma) * sat
                g = luma + (g - luma) * sat
                b = luma + (b - luma) * sat

            if gamma:
                out[y][x] = (srgb(min(1.0, r)), srgb(min(1.0, g)),
                             srgb(min(1.0, b)))
            else:
                out[y][x] = tuple(max(0, min(255, int(v * 255 + 0.5)))
                                  for v in (r, g, b))
    return out


def png(path, pix, scale):
    height = len(pix) * scale
    width = len(pix[0]) * scale
    raw = bytearray()
    for y in range(height):
        src = pix[y // scale]
        raw.append(0)
        for x in range(width):
            raw += bytes(src[x // scale])

    def chunk(tag, payload):
        body = tag + payload
        return (struct.pack(">I", len(payload)) + body +
                struct.pack(">I", zlib.crc32(body) & 0xffffffff))

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)


def main(argv):
    argv = list(argv)

    def flag(name):
        if name in argv:
            argv.remove(name)
            return True
        return False

    def opt(name, cast=str, default=None):
        if name in argv:
            i = argv.index(name)
            v = cast(argv[i + 1])
            del argv[i:i + 2]
            return v
        return default

    crop = opt("--crop", lambda s: [int(v) for v in s.split(",")])
    order = opt("--order", lambda s: s.upper())
    black_arg = opt("--black", float)
    sat = opt("--sat", float, 1.0)
    ccm = opt("--ccm", float, 0.7)
    binned = flag("--binned")
    rotate180 = flag("--rotate180")
    bilinear = flag("--bilinear")
    denoise = flag("--denoise")
    wb = not flag("--no-wb")
    gamma = not flag("--linear")
    as_captured = flag("--as-captured")
    if as_captured:
        black_arg, wb, gamma, sat, ccm = 0.0, False, False, 1.0, 0.0
        denoise = False

    path = argv[1] if len(argv) > 1 else "frame.raw"
    width = int(argv[2]) if len(argv) > 2 else 326
    scale = int(argv[3]) if len(argv) > 3 else 1

    img = read_rows(path, width)
    if len(img) < 2:
        sys.exit(f"{path}: too few rows at width {width}")
    if crop is not None:
        y0, y1, x0, x1 = crop
        # Even bounds only: an odd offset rotates the phase lattice.
        y0 -= y0 & 1
        x0 -= x0 & 1
        img = [r[x0:x1] for r in img[y0:y1]]
        print(f"  cropped to rows {y0}..{y1}, cols {x0}..{x1}")

    print(f"{path}: {len(img[0])}x{len(img)}")
    means = phase_means(img)
    red, green_a, green_b, blue = assign_phases(means, order)
    label = {red: "red", blue: "blue", green_a: "green", green_b: "green"}
    for k in KEYS:
        print(f"  phase r{k[0]}c{k[1]} mean {means[k]:7.2f}  -> {label[k]}")

    # Guards --order, which can name any two phases as green. Auto-assignment
    # picks a diagonal by construction, so this cannot fire there.
    if green_a[0] == green_b[0] or green_a[1] == green_b[1]:
        print("  WARNING: the two greens are adjacent, not diagonal -- "
              "this frame does not have Bayer geometry")

    black = black_arg if black_arg is not None else estimate_black(img, red, blue)
    if not 0 <= black < SAT_DN:
        sys.exit(f"black level must be between 0 and {SAT_DN - 1} DN")
    clipped = sum(1 for row in img for v in row if v >= SAT_DN)
    print(f"  black level {black:.1f} DN"
          f"{'' if black_arg is None else ' [--black]'}; "
          f"{100.0 * clipped / (len(img) * len(img[0])):.1f}% of samples clipped")

    if wb:
        gains, mean = white_balance_gains(img, red, green_a, green_b, blue, black)
        print("  white balance (grey-world, unsaturated pixels only): "
              f"R x{gains[red]:.2f}  G x1.00  B x{gains[blue]:.2f}")
    else:
        gains = {k: 1.0 for k in KEYS}

    sat_mask = [[False] * len(img[0]) for _ in img]
    m = plane(img, black, gains, sat_mask)

    if binned:
        out = []
        for ty in range(len(m) // 2):
            row = []
            for tx in range(len(m[0]) // 2):
                y, x = 2 * ty, 2 * tx
                def at(k):
                    return m[y + k[0]][x + k[1]]
                row.append((at(red), (at(green_a) + at(green_b)) / 2.0,
                            at(blue)))
            out.append(row)
        print(f"  binned 2x2 -> {len(out[0])}x{len(out)}")
    else:
        out = demosaic(m, red, green_a, green_b, blue, gradient=not bilinear)
        print("  demosaic: "
              f"{'bilinear' if bilinear else 'gradient-corrected (Malvar-He-Cutler)'}"
              f" -> {len(out[0])}x{len(out)} full resolution")

    if denoise:
        out = chroma_denoise(out)
        print("  denoise: 3x3 edge-gated chroma median, luminance retained")

    # White point: the raw clip level in GREEN, whose gain is 1.0 by
    # construction. Scaling by the largest gain instead would mean green and
    # red could never reach full scale -- green would top out at 1/1.5 -- which
    # compresses the whole picture and desaturates it. Letting the boosted
    # channels run past 1.0 is the point: that overflow is exactly what the
    # highlight roll-off consumes.
    white = SAT_DN - black
    if as_captured:
        pix = [[tuple(max(0, min(255, int(v + 0.5))) for v in pixel)
                for pixel in row] for row in out]
    else:
        pix = encode(out, sat_mask, white, gamma=gamma, sat=sat, ccm=ccm)
    if rotate180:
        pix = [row[::-1] for row in pix[::-1]]
    print(f"  colour matrix: "
          + (f"generic, strength {ccm:.2f}" if ccm else "off [--ccm 0]"))
    print(f"  transfer: {'sRGB' if gamma else 'linear [--linear]'}"
          + (f", saturation x{sat:.2f}" if sat != 1.0 else ""))

    dst = path.rsplit(".", 1)[0] + "-colour.png"
    png(dst, pix, scale)
    print(f"  wrote {dst}  ({len(pix[0]) * scale}x{len(pix) * scale})")


if __name__ == "__main__":
    main(sys.argv)
