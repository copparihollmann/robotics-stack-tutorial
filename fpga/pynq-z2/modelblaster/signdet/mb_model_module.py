"""Lab B144 SignDetLite, for pipeline.extract_graph --model signdet_b144.

The class lives once, in the iiswc-tutorial tree next to the training and evaluation code
(fpga/pynq-z2/modelblaster/signdet/model.py); this module only adapts it to extract_graph's
contract so the lowered graph and the validated checkpoint can never drift apart.

WHICH WEIGHTS.  Both are loaded the same way and neither is guessed:

    B144_CKPT / B144_CALIB   point at a checkpoint and a calibration array.
                             scripts/84_signdet_lower.sh always sets them.

    real      the GTSDB-trained SignDetLite checkpoint.  It is NOT in this repository and
              never will be -- see docs/SIGNDET_WEIGHTS.md.  Supply your own, or use the
              lowered tree the tutorial image ships.
    random    random_weights.py's deterministic initialiser.  Same architecture, same
              tensor shapes, same interface quantisation scales; no detection ability.

CALIBRATION IS ON WHATEVER B144_CALIB HOLDS, not on torch.randn.  extract_graph's int8 PTQ
sets every activation scale from what it observes, so the calibration array decides the
scales.  For the real checkpoint it is the HELD-OUT split of the B144 set through the same
signpre_rgb front end the board runs; for the random one it is random_weights.py's synthetic
frames, which are built to land the input and output scales on the same 1/127 the real model
has (that is what keeps SIGN_IN_SCALE_RECIP and SD_OUT_SCALE_PPB valid in both modes).
"""
from __future__ import annotations
import os
import sys

import numpy as np
import torch

_SIGNDET = os.environ.get("B144_SIGNDET_DIR", os.path.dirname(os.path.abspath(__file__)))

if _SIGNDET not in sys.path:
    sys.path.insert(0, _SIGNDET)
import _paths                                    # noqa: E402
from model import SignDetLite                    # noqa: E402

_CKPT = os.environ.get("B144_CKPT", _paths.work("b144/run/signdet_b144.pt"))
_CALIB = os.environ.get("B144_CALIB", _paths.work("b144/run/calib_X.npy"))


def get_model(seed: int = 0) -> SignDetLite:
    m = SignDetLite()
    if os.path.exists(_CKPT):
        m.load_state_dict(torch.load(_CKPT, map_location="cpu"))
    else:
        raise SystemExit(
            "B144: no checkpoint at %s.\n"
            "       The GTSDB-trained weights are not shipped in this repository.\n"
            "       Run scripts/84_signdet_lower.sh, which builds a deterministic\n"
            "       RANDOM-weight checkpoint when no real one is present, or point\n"
            "       B144_CKPT at your own.  See docs/SIGNDET_WEIGHTS.md." % _CKPT)
    m.eval()
    return m


def _calib_array() -> "np.ndarray | None":
    if not os.path.exists(_CALIB):
        return None
    return np.load(_CALIB)                       # (N,64,64,3) uint8, the deploy front end's output


def get_sample_input(seed: int = 1) -> torch.Tensor:
    X = _calib_array()
    if X is None:
        g = torch.Generator().manual_seed(seed)
        return torch.randn(1, 3, 64, 64, generator=g)
    return torch.from_numpy(X[0].astype(np.float32) / 255.0).permute(2, 0, 1)[None].contiguous()


def get_calibration_samples(n: int):
    X = _calib_array()
    if X is None:
        raise SystemExit("B144: no calibration frames at %s" % _CALIB)
    n = min(int(n), len(X))
    for i in range(n):
        yield torch.from_numpy(X[i].astype(np.float32) / 255.0).permute(2, 0, 1)[None].contiguous()
