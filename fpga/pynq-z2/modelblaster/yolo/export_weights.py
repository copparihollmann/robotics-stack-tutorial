"""Lab B106 -- turn the stock ultralytics yolov8n.pt into a PLAIN state_dict.

WHY THE CONVERSION EXISTS AT ALL.  `modelblaster/models/yolov8_nano.py` loads pretrained
weights through `from ultralytics import YOLO`, and ultralytics is not installed in the
zephyr conda env that carries torch 2.6.0 -- the env every other lab's extract_graph runs
in.  Installing it there would downgrade that env's numpy from 2.0.0 to 1.26.4 (ultralytics
8.3.0 pins <2), and numpy 1.26 SILENTLY WRAPS the int32 overflow that numpy 2.0 raises on
in extract_graph._requantize_int.  A quantiser that wraps instead of raising produces
plausible int8 bytes from a broken requantise, which is precisely the failure mode this
lab cannot afford.

So ultralytics lives in a throwaway venv, is used for exactly one thing -- unpickling the
checkpoint -- and what crosses the boundary is a dict of tensors with OUR key names, which
needs no ultralytics to load.

Run with the venv's python.  Writes <out>.pt (torch state_dict) and <out>.sha256.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import sys

ZCS = pathlib.Path(__file__).resolve().parents[4] / "zephyr-chipyard-sw"
sys.path.insert(0, str(ZCS))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pt", required=True, help="the stock ultralytics yolov8n.pt")
    ap.add_argument("--out", required=True, help="output .pt (plain state_dict)")
    ap.add_argument("--nc", type=int, default=80)
    a = ap.parse_args()

    os.environ["MODELBLASTER_YOLOV8N_PRETRAINED"] = "0"
    os.environ.setdefault("MODELBLASTER_YOLOV8N_INPUT", "160")
    import torch
    from modelblaster.models import yolov8_nano as y

    m = y.YOLOv8Nano(nc=a.nc)
    # The RANDOM baseline, captured before the load, is what makes the "did it actually
    # arrive" check capable of failing.  A key-count check alone passes on a checkpoint
    # that wrote every tensor with the value it already had.
    import copy
    torch.manual_seed(12345)
    ref = y.YOLOv8Nano(nc=a.nc)
    before = {k: v.detach().clone() for k, v in m.state_dict().items()}
    n = y._load_ultralytics_weights(m, a.pt)

    after = m.state_dict()
    if n != len(after):
        missing = len(after) - n
        raise SystemExit(
            f"loaded {n} tensors but the model has {len(after)} -- {missing} tensor(s) "
            f"keep their random initialisation, so this checkpoint is PARTIALLY "
            f"pretrained and the export would not say so.")

    # Every CONV WEIGHT must have moved.  BN bias/mean are legitimately zero in both the
    # checkpoint and the init, and num_batches_tracked is a counter, so they are excluded
    # rather than waved at -- the convs are where a silent partial load would hide.
    unmoved = [k for k, v in after.items()
               if k.endswith("conv.weight") or re.fullmatch(r"detect\.cv[23]_\d_2\.weight", k)
               if torch.equal(v, before[k])]
    if unmoved:
        raise SystemExit(f"{len(unmoved)} conv weight tensor(s) unchanged by the load, "
                         f"first: {unmoved[:3]} -- the key map missed them.")
    nconv = sum(1 for k in after
                if k.endswith("conv.weight") or re.fullmatch(r"detect\.cv[23]_\d_2\.weight", k))
    print(f"all {nconv} conv weight tensors changed by the load")

    sd = {k: v.detach().cpu().clone() for k, v in m.state_dict().items()}
    torch.save(sd, a.out)
    h = hashlib.sha256(pathlib.Path(a.out).read_bytes()).hexdigest()
    pathlib.Path(a.out + ".sha256").write_text(h + "\n")
    print(f"wrote {a.out}: {len(sd)} tensors, {n} from {a.pt}")
    print(f"sha256 {h}")


if __name__ == "__main__":
    main()
