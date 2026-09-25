#!/usr/bin/env python3
"""A DETERMINISTIC RANDOM-WEIGHT SignDetLite, so the demo runs from a clone.

WHY THIS FILE EXISTS.  SignDetLite's trained weights come from GTSDB scenes (make_data.py),
and GTSDB's licence could not be established: its canonical site does not resolve and the
mirrors carry no licence text.  So the trained checkpoint, and every artefact that embeds it
-- signdet_b144.pt, the lowered gen tree's weights.c/model.c, any golden computed from them
-- are NOT published, in this repository or anywhere else.  See docs/SIGNDET_WEIGHTS.md.

What is published instead is the thing that makes the lab runnable: an initialiser that
produces a checkpoint with the SAME ARCHITECTURE, the SAME TENSOR SHAPES and -- deliberately
-- the SAME INTERFACE QUANTISATION SCALES as the real model.  Everything downstream of the
weights therefore works unchanged: extract_graph lowers it, the same curated kernels are
picked, generate_kernels emits the same C, the guest links it, both harts trace, and Lab
B156's scheduling result is exactly the one the real model produces.

WHAT IT CANNOT DO IS DETECT.  A random network has no detection ability, so the replay gate
(8 baked frames vs the host's answers) cannot pass and MUST NOT be reported as if it could.
scripts/90 reads the manifest this file writes and reports that gate as NOT APPLICABLE.

------------------------------------------------------------------------------------------
DETERMINISM, AND WHY IT IS NUMPY AND NOT TORCH
------------------------------------------------------------------------------------------
torch.manual_seed reproduces within one build of PyTorch; it is not a stability guarantee
across versions, and a "deterministic" default that changes under the operator is worse than
an honest random one.  Every number here comes from numpy's PCG64 bit generator, whose
stream NEP 19 pins for the life of the `default_rng` API, and is then copied into the torch
state dict.  Two clones on two machines with different torch builds therefore get identical
TENSOR VALUES.  The manifest records the SHA-256 of the .pt file, which pins the artefact on
one machine but is a weaker claim than that -- torch's serialisation format is its own and
can move under us.  The portable fingerprint is the `ir_md5` scripts/84 writes into the gen
tree's manifest: identical values lowered by the same pipeline give the same graph.

    THE SEED IS 144, after Lab B144, and it is the only one this repository ever uses.
    --seed takes another if you want a second arm; the manifest records which was used.

------------------------------------------------------------------------------------------
THE TWO SCALES THAT ARE NOT FREE
------------------------------------------------------------------------------------------
extract_graph's PTQ sets every scale from the calibration set's observed max|x| over 127.
Two of those scales are part of the GUEST's contract and not private to the graph:

    input   1/127   sign_pre.c quantises with -DSIGN_IN_SCALE_RECIP=127
    output  1/127   main.c turns the softmax byte into a percentage with
                    -DSD_OUT_SCALE_PPB=7874016  (= 1e9/127)

The input one is free: the calibration frames are uint8 divided by 255, so a set containing
at least one 255 has max exactly 1.0.  The output one is not: softmax over three classes
only reaches 1.0 when one logit dominates, and a freshly initialised head produces logits
near zero, which would put the output scale somewhere near 0.4/127 and make every percentage
the board prints wrong by a factor nobody would notice.

So the head is GAINED: its weight and bias are multiplied by the smallest power of two that
makes float32 softmax saturate to exactly 1.0 somewhere on the calibration set.  That is a
property of this random model only; the real model saturates on its own.  The gain, and the
resulting max, are in the manifest, and scripts/84 gates both scales after lowering -- if
either misses, it says so rather than shipping a silently wrong percentage.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import SignDetLite, OUTPX             # noqa: E402

SEED = 144
NCALIB = 64


def random_state_dict(seed: int = SEED) -> "dict[str, torch.Tensor]":
    """SignDetLite's parameters, drawn from PCG64 on torch's own Conv2d init family.

    torch.nn.Conv2d's reset_parameters draws both the weight and the bias from
    U(-1/sqrt(fan_in), +1/sqrt(fan_in)) (kaiming_uniform_ with a=sqrt(5) reduces to exactly
    that bound).  Reproducing the family rather than inventing one keeps the activation
    magnitudes -- and therefore the per-tensor scales the PTQ observes -- in the same range
    a real freshly-initialised SignDetLite would have.
    """
    rng = np.random.default_rng(seed)
    m = SignDetLite()
    sd = {}
    for name, p in m.state_dict().items():
        shape = tuple(p.shape)
        if name.endswith(".weight"):
            fan_in = int(np.prod(shape[1:]))
        elif name.endswith(".bias"):
            # the bias shares its layer's fan_in; recover it from the matching weight
            fan_in = int(np.prod(tuple(m.state_dict()[name[:-4] + "weight"].shape)[1:]))
        else:
            raise SystemExit("unexpected parameter %r in SignDetLite" % name)
        bound = 1.0 / np.sqrt(fan_in)
        v = rng.uniform(-bound, bound, size=shape)
        sd[name] = torch.from_numpy(v.astype(np.float32))
    return sd


def random_calibration(seed: int = SEED, n: int = NCALIB) -> np.ndarray:
    """(n, 64, 64, 3) uint8 frames, in the shape signpre_rgb.py's front end emits.

    NOT white noise.  A conv stack fed uniform noise sees almost no spatial structure and
    every activation range collapses towards the same small number, which is not what the
    PTQ would observe on camera frames.  These are sums of a few low-frequency sinusoids
    per channel plus a little grain -- smooth blobs with edges, which is enough structure
    for the observed ranges to look like an image's.

    Each frame is stretched to fill [0, 255] exactly, so the set's max|x/255| is 1.0 and the
    input scale lands on 1/127 -- the same value the real model's calibration produces.
    """
    rng = np.random.default_rng(seed + 1)
    yy, xx = np.mgrid[0:OUTPX, 0:OUTPX].astype(np.float64) / OUTPX
    frames = np.empty((n, OUTPX, OUTPX, 3), dtype=np.uint8)
    for i in range(n):
        img = np.zeros((OUTPX, OUTPX, 3))
        for _ in range(5):                       # a few low-frequency components
            fx, fy = rng.uniform(0.5, 6.0, size=2)
            ph = rng.uniform(0, 2 * np.pi, size=3)
            amp = rng.uniform(0.3, 1.0, size=3)
            for c in range(3):
                img[:, :, c] += amp[c] * np.sin(2 * np.pi * (fx * xx + fy * yy) + ph[c])
        img += rng.normal(0.0, 0.08, size=img.shape)
        lo, hi = img.min(), img.max()
        frames[i] = np.round((img - lo) / max(hi - lo, 1e-9) * 255.0).astype(np.uint8)
    return frames


def _softmax_max(model: SignDetLite, X: np.ndarray) -> float:
    """The largest softmax probability the model produces anywhere on X, in float32.

    ONE FRAME AT A TIME.  SignDetLite.forward reshapes to (GRID*GRID, ncls), which is only
    valid for N=1 -- that is the shape the guest runs, and running the calibration through
    the same path is the point.
    """
    best = 0.0
    with torch.no_grad():
        for i in range(len(X)):
            t = torch.from_numpy(X[i:i + 1].astype(np.float32) / 255.0)
            y = model(t.permute(0, 3, 1, 2).contiguous())
            best = max(best, float(y.max().item()))
    return best


def gain_head(sd: "dict[str, torch.Tensor]", X: np.ndarray,
              max_doublings: int = 24) -> "tuple[dict, int, float]":
    """Scale the head until float32 softmax saturates at exactly 1.0 on X.

    Returns (state_dict, gain, softmax_max).  The gain is a power of two so the search is
    deterministic and the result is exactly representable; it is reported, not hidden.
    """
    m = SignDetLite()
    gain = 1
    for _ in range(max_doublings + 1):
        trial = dict(sd)
        trial["head.weight"] = sd["head.weight"] * float(gain)
        trial["head.bias"] = sd["head.bias"] * float(gain)
        m.load_state_dict(trial)
        m.eval()
        smax = _softmax_max(m, X)
        if smax >= 1.0:
            return trial, gain, smax
        gain *= 2
    raise SystemExit("the head did not saturate the softmax after %d doublings -- refusing "
                     "to write a checkpoint whose output scale would not be 1/127"
                     % max_doublings)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True,
                    help="directory to write signdet_random.pt, calib_X.npy and the manifest")
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--ncalib", type=int, default=NCALIB)
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    sd = random_state_dict(a.seed)
    X = random_calibration(a.seed, a.ncalib)
    sd, gain, smax = gain_head(sd, X)

    ckpt = os.path.join(a.out, "signdet_random.pt")
    calib = os.path.join(a.out, "calib_X.npy")
    torch.save(sd, ckpt)
    np.save(calib, X)

    sha = hashlib.sha256(open(ckpt, "rb").read()).hexdigest()
    man = {
        "weights_mode": "random",
        "provenance": "deterministic random initialiser, signdet/random_weights.py",
        "seed": a.seed,
        "rng": "numpy PCG64 (np.random.default_rng)",
        "init": "U(-1/sqrt(fan_in), +1/sqrt(fan_in)) per tensor, torch Conv2d's own family",
        "head_gain": gain,
        "calibration": {"n": int(len(X)), "shape": list(X.shape[1:]),
                        "min": int(X.min()), "max": int(X.max())},
        "softmax_max_on_calibration": smax,
        "checkpoint_sha256": sha,
        "parameters": int(sum(int(np.prod(tuple(v.shape))) for v in sd.values())),
        "detection_ability": "none -- the replay gate cannot pass and must be reported "
                             "NOT APPLICABLE, not FAIL",
    }
    with open(os.path.join(a.out, "random_weights.json"), "w") as fh:
        json.dump(man, fh, indent=2)

    print("    seed          %d  (numpy PCG64)" % a.seed)
    print("    checkpoint    %s" % ckpt)
    print("    sha256        %s" % sha)
    print("    parameters    %d" % man["parameters"])
    print("    head gain     x%d  -> max softmax on the calibration set = %.9f"
          % (gain, smax))
    print("    calibration   %d frames %s uint8, min %d max %d"
          % (len(X), "x".join(str(d) for d in X.shape[1:]), X.min(), X.max()))
    print("    THESE WEIGHTS CANNOT DETECT ANYTHING.  They exist so the pipeline runs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
