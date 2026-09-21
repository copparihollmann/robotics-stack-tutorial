#!/usr/bin/env python3
"""Synthesise an HM01B0 frame from a corpus image, and call the board's own front end.

Two things live here so that the featuriser, the replay-frame generator and the
bit-exactness check cannot drift apart:

  `scene324(rgb96)`        a 324 x 324 x 3 scene, the sensor's field of view.
  `mono_frame(scene)`      what a MONOCHROME HM01B0 reads out: 324x324, one byte/pixel.
  `bayer_frame(scene)`     what a COLOUR HM01B0 reads out: 324x324 RGGB mosaic, also one
                           byte per pixel.  The colour is in the filter array; it does
                           not cost bytes on the wire.
  `FrameFE`                ctypes bindings to fpga/pynq-z2/sw/frame_fe.c, compiled for
                           the host.

WHY THE FEATURES ARE COMPUTED BY THE C AND NOT BY NUMPY.  The usual way a vision model
goes wrong on a device is that training used one resize/normalise and the device does
another, and nothing in the pipeline compares them.  Compiling the device's own front end
for the host and calling it through ctypes removes the possibility rather than managing
it -- the same thing fpga/pynq-z2/sw/tools/featurise.py does with audio_fe.c, and for the
same reason.

WHAT THE SYNTHESIS IS AND IS NOT.  The corpus is 96x96, so a 324x324 frame has to be
constructed: the image is replicated 3x into the centre 288x288 and the 18-pixel border
is edge-extended.  The crop origin is 18, a multiple of 3, so every 3x3 box the front end
averages lands inside one replicated block and the monochrome path reconstructs the
corpus pixel exactly.  What this DOES exercise, faithfully and at full size, is the cost
and the arithmetic of the front end: the crop, the box filter, the de-interleave and the
demosaic all run on 324x324 real data.  What it does NOT exercise is sensor noise, lens
blur, rolling-shutter skew or demosaic error on genuinely high-frequency content, because
a 3x-replicated image has none above the corpus Nyquist.  Frames from an attached camera
would; these are replay frames and the write-up says so.
"""
from __future__ import annotations

import ctypes
import os
import pathlib
import subprocess
import tempfile

import numpy as np

SW = pathlib.Path(__file__).resolve().parents[1]          # fpga/pynq-z2/sw
FRAME_W = FRAME_H = 324
CROP0 = 18
SIDE = 96


def scene324(rgb96: np.ndarray) -> np.ndarray:
    """96x96x3 uint8 -> 324x324x3 uint8.  Nearest 3x into the centre, edges extended."""
    blk = np.repeat(np.repeat(rgb96, 3, axis=0), 3, axis=1)        # 288x288x3
    return np.pad(blk, ((CROP0, CROP0), (CROP0, CROP0), (0, 0)), mode="edge")


def mono_frame(scene: np.ndarray) -> np.ndarray:
    """BT.601 integer luma -- the same expression a demosaicing ISP would use, and the
    one the featuriser's documentation quotes."""
    r, g, b = (scene[..., i].astype(np.uint32) for i in range(3))
    return (((77 * r + 150 * g + 29 * b + 128) >> 8).astype(np.uint8))


def bayer_frame(scene: np.ndarray) -> np.ndarray:
    """RGGB mosaic: R at (even, even), G at (even, odd) and (odd, even), B at (odd, odd).

    Phase is defined on the FULL 324x324 frame, not on the crop, because that is where a
    sensor defines it.  CROP0 = 18 is even, so the crop inherits the same phase.
    """
    m = np.empty((FRAME_H, FRAME_W), dtype=np.uint8)
    m[0::2, 0::2] = scene[0::2, 0::2, 0]
    m[0::2, 1::2] = scene[0::2, 1::2, 1]
    m[1::2, 0::2] = scene[1::2, 0::2, 1]
    m[1::2, 1::2] = scene[1::2, 1::2, 2]
    return m


class FrameFE:
    """fpga/pynq-z2/sw/frame_fe.c, compiled for the host and called through ctypes."""

    def __init__(self, pext: bool = False, cflags=()):
        self._tmp = tempfile.mkdtemp(prefix="frame_fe_")
        so = os.path.join(self._tmp, "frame_fe.so")
        cmd = ["cc", "-O2", "-fPIC", "-shared", "-I", str(SW),
               str(SW / "frame_fe.c"), "-o", so]
        if pext:
            cmd[1:1] = ["-DFRAME_FE_PEXT=1", "-DMB_PEXT_HW=0"]
        cmd[1:1] = list(cflags)
        subprocess.run(cmd, check=True)
        self.lib = ctypes.CDLL(so)
        for f in ("frame_fe_mono96", "frame_fe_rgb96", "frame_fe_bayer4_48"):
            getattr(self.lib, f).restype = None
            getattr(self.lib, f).argtypes = [ctypes.POINTER(ctypes.c_uint8),
                                             ctypes.POINTER(ctypes.c_int8)]
        self.lib.frame_fe_selftest.restype = ctypes.c_int
        self.lib.frame_fe_uses_pext.restype = ctypes.c_int
        if self.lib.frame_fe_selftest() != 0:
            raise RuntimeError("frame_fe_selftest failed on the host")

    def _call(self, fn, frame: np.ndarray, shape):
        frame = np.ascontiguousarray(frame, dtype=np.uint8)
        out = np.empty(int(np.prod(shape)), dtype=np.int8)
        fn(frame.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
           out.ctypes.data_as(ctypes.POINTER(ctypes.c_int8)))
        return out.reshape(shape)

    def mono96(self, frame):
        return self._call(self.lib.frame_fe_mono96, frame, (1, SIDE, SIDE))

    def rgb96(self, frame):
        return self._call(self.lib.frame_fe_rgb96, frame, (3, SIDE, SIDE))

    def bayer4_48(self, frame):
        return self._call(self.lib.frame_fe_bayer4_48, frame, (4, SIDE // 2, SIDE // 2))


def features(fe: FrameFE, rgb96: np.ndarray):
    """The three int8 tensors, all from the device's own C, for one corpus image."""
    sc = scene324(rgb96)
    mf = mono_frame(sc)
    bf = bayer_frame(sc)
    return fe.mono96(mf), fe.rgb96(bf), fe.bayer4_48(bf), mf, bf
