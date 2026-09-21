"""The bridge from a ModelBlaster models/<id>.py to the definitions in this repo.

ModelBlaster resolves --model <id> by importing modelblaster.models.<id>, so the three
keyword spotters need a module inside the submodule.  That module is three lines and
lives in patches/0020-modelblaster-kws-models.patch; everything real -- the
architectures, the trained weights and the calibration clips -- stays HERE, because the
submodule is a read-only pinned input and a binary weight blob cannot live in a patch.

The path is taken from $IISWC_ROOT, falling back to this file's own location, which is
the same shape models/_fused_loader.py uses upstream.
"""
from __future__ import annotations

import json
import os
import pathlib
import sys

import numpy as np
import torch

_HERE = pathlib.Path(__file__).resolve().parent
_ROOT = pathlib.Path(os.environ.get("IISWC_ROOT", _HERE.parents[3]))
_KWS = _ROOT / "fpga" / "pynq-z2" / "modelblaster" / "kws"
if str(_KWS) not in sys.path:
    sys.path.insert(0, str(_KWS))

from kws_models import ARCHS  # noqa: E402


def _w(arch):
    return _KWS / "weights" / f"{arch}_folded.npz"


def load(arch: str):
    """The trained, batchnorm-folded model in eval mode."""
    meta = json.load(open(_KWS / "weights" / f"{arch}_meta.json"))
    # nclass, not len(labels). For the CTC transcribers the label set is the ten digits
    # and the class count is eleven -- the extra one is the blank, which has no label
    # because it is never emitted. Deriving the head width from the label list builds a
    # ten-way model and fails to load an eleven-way checkpoint, which is the good
    # outcome; silently training one and deploying the other is not.
    m = ARCHS[arch](nclass=meta.get("nclass", len(meta["labels"])))
    from kws_models import fold_bn
    fold_bn(m)                         # make the module shapes match the folded state
    z = np.load(_w(arch))
    m.load_state_dict({k: torch.from_numpy(z[k]) for k in z.files})
    m.eval()
    return m, meta


def calib(arch: str, n: int = 1):
    """n real test clips as int8-valued float tensors -- what the device feeds in.

    Real clips, not noise.  Activation ranges from random input would be wrong in both
    directions: too wide where the front end never goes, too narrow where a loud
    keyword does.
    """
    # NO transpose here. train_digits.py saves the calibration clips AFTER applying
    # whatever layout its architecture wants, so this file is already in the model's
    # own layout. Transposing again turns [N,1,C,T] back into [N,1,T,C], which for
    # DigitCTCT still convolves -- the kernel is (10,5) over a 200x10 tensor instead of
    # a 10x200 one -- and produces an 11 x 191 x 3 output that no decoder can read. It
    # did exactly that once.
    x = np.load(_KWS / "weights" / f"{arch}_calib_x.npy").astype(np.float32)
    n = max(1, min(n, len(x)))
    return [torch.from_numpy(x[i:i + 1]) for i in range(n)]
