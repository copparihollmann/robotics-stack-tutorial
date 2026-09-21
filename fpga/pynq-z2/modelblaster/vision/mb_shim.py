"""The bridge from a ModelBlaster models/<id>.py to the definitions in this repo.

ModelBlaster resolves --model <id> by importing modelblaster.models.<id>, so the five
Visual Wake Words networks need a module inside the submodule.  Those modules are ~20
lines each and live in patches/0070-modelblaster-vww-models.patch; everything real -- the
architectures, the trained weights and the calibration frames -- stays HERE, because the
submodule is a read-only pinned input and a binary weight blob cannot live in a patch.

Same split as fpga/pynq-z2/modelblaster/kws/mb_shim.py, deliberately: two model families
reaching the pipeline the same way is one convention, and two conventions would be one
more thing to get wrong.
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
_VIS = _ROOT / "fpga" / "pynq-z2" / "modelblaster" / "vision"
if str(_VIS) not in sys.path:
    sys.path.insert(0, str(_VIS))

from vision_models import ARCHS, FEED, FEED_SHAPE, fold_bn  # noqa: E402


def load(arch: str):
    """The trained, batchnorm-folded model in eval mode."""
    meta = json.load(open(_VIS / "weights" / f"{arch}_meta.json"))
    m = ARCHS[arch](nclass=len(meta["labels"]))
    fold_bn(m)                          # make the module shapes match the folded state
    z = np.load(_VIS / "weights" / f"{arch}_folded.npz")
    m.load_state_dict({k: torch.from_numpy(z[k]) for k in z.files})
    m.eval()
    return m, meta


def calib(arch: str, n: int = 1):
    """n real held-out frames as int8-valued float tensors -- what the device feeds in.

    Real frames, not noise.  Activation ranges from random input would be wrong in both
    directions: too wide where a box-averaged natural image never goes, too narrow where
    a high-contrast edge does.

    NO transpose and NO scaling here.  The calibration array was written by train_vww.py
    straight out of the featuriser, which is frame_fe.c's own output, so it is already in
    the layout and the numeric range the device produces.  The audio side learned this
    the expensive way: a double transpose in the KWS shim produced a plausible wrong
    answer that built, ran and reported a believable cycle count
    (SPEECH_ON_ROCKET.md section 9 item 15).
    """
    x = np.load(_VIS / "weights" / f"{arch}_calib_x.npy")
    want = FEED_SHAPE[FEED[arch]]
    if tuple(x.shape[1:]) != want:
        raise ValueError(f"{arch}: calibration frames are {x.shape[1:]}, "
                         f"but the {FEED[arch]} feed is {want}")
    x = x.astype(np.float32)
    n = max(1, min(n, len(x)))
    return [torch.from_numpy(x[i:i + 1]) for i in range(n)]
