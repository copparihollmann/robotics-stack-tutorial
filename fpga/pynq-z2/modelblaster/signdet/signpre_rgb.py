"""Lab B144 colour front end: HM01B0 Bayer frame -> 64x64x3 RGB, integer-exact.

THE DEPLOY CONTRACT.  Everything the detector is trained on goes through this function, and
the board-side C (sign_pre_rgb64) must reproduce it byte for byte.  Kept in Python here so
the training set, the host harness and the C can all be checked against one definition.

WHY NOT DEMOSAIC.  sign_pre.c's grey path averages RAW Bayer bytes over an EVEN box, because
any even box holds equal numbers of R, G and B and so needs no CFA phase.  A colour front end
cannot dodge the phase that way -- it must commit.  But it does not need a demosaic either:
for each 5x5 output block we accumulate each CFA colour into its OWN accumulator and divide by
its OWN count.  That is an unbiased per-channel mean over the 4..9 samples of that colour in
the block, it needs no interpolation, and it is what kills the speckle:

  measured on snap_015, the bilinear demosaic of cam_view.py leaves a red-excess signal of
  ~15/255 on the sign under speckle whose peak amplitude is 171 -- the noise is 10x the
  signal.  Averaging 4..9 same-colour samples per block removes the speckle by construction,
  because the speckle IS the interpolation error and we never interpolate.

THE PHASE IS BGGR, and it is not a guess: under BGGR the frame's illuminant reads warm
(R~=G>B, which is the fluorescent light you can see in the picture) and the props read red.
Under RGGB the same frame reads cyan and the STOP sign reads blue.

GEOMETRY.  324x324 with a 326-byte stride and 2 pad bytes per line.  We take rows/cols 2..321
-- a 320x320 crop, offset 2, EVEN, so the CFA phase is still BGGR -- and tile it with 5x5
blocks to 64x64.  The 2-pixel border we drop is vignetted anyway.  THIS IS NOT THE CENTRE CROP
THE LAB RULED OUT: it discards 2 pixels, not the 62% of the frame a sign-sized crop would.
The 180 rotation is applied to the 64x64x3 RGB, AFTER the mosaic is read, so it can never
disturb the phase.
"""
import numpy as np

STRIDE, W, H, PAD = 326, 324, 324, 2
CROP, OUT, BOX = 320, 64, 5
OFF = (W - CROP) // 2          # 2, even -> CFA phase preserved
WB_TARGET = 110                # gray-world target mean per channel


def read_raw(path):
    a = np.fromfile(path, dtype=np.uint8)
    if a.size != STRIDE * H:
        raise ValueError("%s: %d bytes, expected %d" % (path, a.size, STRIDE * H))
    return a.reshape(H, STRIDE)[:, PAD:PAD + W]


def bayer_to_rgb64(bayer324, rot180=True):
    """320x320 BGGR mosaic -> 64x64x3 uint8 by per-channel counted 5x5 box mean.

    THE BOX IS ODD (5) AND THAT MATTERS.  The CFA phase of a pixel is the parity of its
    ABSOLUTE row/col, and with an odd box the phase of a block's first pixel alternates with
    the block index.  A mask fixed in block-local coordinates therefore averages R and B
    together on half the blocks and returns a grey image -- measured, on the bench frames it
    collapsed the sign to R82.6 G83.2 B83.4.  So the masks below are built over the WHOLE
    crop from absolute coordinates, and each block divides by the count it actually has
    (R and B are 4, 6 or 9 per block; G is 8, 12 or 13).  The crop offset is even, so
    in-crop parity is frame parity.
    """
    b = bayer324[OFF:OFF + CROP, OFF:OFF + CROP].astype(np.uint32)
    yy, xx = np.meshgrid(np.arange(CROP), np.arange(CROP), indexing="ij")
    sel = {"R": (yy % 2 == 1) & (xx % 2 == 1),
           "B": (yy % 2 == 0) & (xx % 2 == 0),
           "G": (yy % 2) != (xx % 2)}
    planes = {}
    for name, m in sel.items():
        s = (b * m).reshape(OUT, BOX, OUT, BOX).sum(axis=(1, 3))
        c = m.astype(np.uint32).reshape(OUT, BOX, OUT, BOX).sum(axis=(1, 3))
        planes[name] = ((2 * s + c) // (2 * c)).astype(np.uint8)   # round-half-up
    rgb = np.dstack([planes["R"], planes["G"], planes["B"]])
    return np.rot90(rgb, 2).copy() if rot180 else rgb


def gray_world(rgb64):
    """Per-channel gain to a common mean. Integer, and it is what removes the illuminant."""
    out = np.empty_like(rgb64)
    for c in range(3):
        ch = rgb64[:, :, c].astype(np.uint32)
        m = int(ch.mean())
        if m < 1:
            m = 1
        out[:, :, c] = np.minimum((ch * WB_TARGET + m // 2) // m, 255).astype(np.uint8)
    return out


def preprocess(path_or_bayer, wb=True):
    b = read_raw(path_or_bayer) if isinstance(path_or_bayer, str) else path_or_bayer
    rgb = bayer_to_rgb64(b)
    return gray_world(rgb) if wb else rgb


def mosaic_bggr(rgb324):
    """Inverse of the read: an RGB scene -> the single-byte-per-pixel BGGR frame a sensor
    would deliver. Used to put training images through the same optics as the board."""
    h, w = rgb324.shape[:2]
    yy, xx = np.meshgrid(np.arange(h), np.arange(w), indexing="ij")
    out = np.where((yy % 2 == 1) & (xx % 2 == 1), rgb324[:, :, 0],
          np.where((yy % 2 == 0) & (xx % 2 == 0), rgb324[:, :, 2], rgb324[:, :, 1]))
    return out.astype(np.uint8)
