"""Lab B106 -- extract the YOLOv8n int8 IR in the zephyr conda env, with REAL weights.

`modelblaster.pipeline.extract_graph --model yolov8_nano` resolves the model by importing
`modelblaster.models.yolov8_nano` and calling its `get_model()`, and that function reaches
for ultralytics.  This driver pre-imports that module, replaces `get_model` with one that
loads the plain state_dict `export_weights.py` produced, and then calls extract_graph's own
`main()` -- so every pass, every calibration decision and every quantisation rule is the
shipped pipeline's, not a copy of it.

WHY NOT --weight-bits / a patch: nothing about the network changes here.  The ONLY thing
substituted is where the parameters come from, and the substitution is checked (below)
rather than trusted.

Run with the zephyr conda env's python (numpy 2.0.0, which RAISES on the int32 requantise
overflow that numpy 1.26 wraps silently).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import sys

ZCS = pathlib.Path(__file__).resolve().parents[4] / "zephyr-chipyard-sw"
if str(ZCS) not in sys.path:
    sys.path.insert(0, str(ZCS))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default="", help="plain state_dict .pt from export_weights.py; "
                                                "empty = leave the model at its random init")
    ap.add_argument("--sha256", default="", help="expected sha256 of --state")
    ap.add_argument("--input", default="160", help="MODELBLASTER_YOLOV8N_INPUT")
    ap.add_argument("--nc", type=int, default=80)
    ap.add_argument("--calib-dir", default="", help="directory of real RGB jpgs")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--num-calibration", type=int, default=8)
    ap.add_argument("--fusion-target", default="roccmoon")
    a = ap.parse_args()

    os.environ["MODELBLASTER_YOLOV8N_INPUT"] = a.input
    os.environ["MODELBLASTER_YOLOV8N_NC"] = str(a.nc)
    os.environ["MODELBLASTER_YOLOV8N_PRETRAINED"] = "0"   # we load them ourselves
    if a.calib_dir:
        os.environ["MODELBLASTER_YOLOV8N_CALIB_DIR"] = a.calib_dir
        jpgs = sorted(pathlib.Path(a.calib_dir).glob("*.jpg"))
        if not jpgs:
            raise SystemExit(f"--calib-dir {a.calib_dir} holds no *.jpg")
        os.environ["MODELBLASTER_YOLOV8N_CALIB_IMAGE"] = str(jpgs[0])

    import torch
    from modelblaster.models import yolov8_nano as y

    _plain = y.get_model
    provenance = "RANDOM INIT (no trained weights)"
    if a.state:
        blob = pathlib.Path(a.state).read_bytes()
        h = hashlib.sha256(blob).hexdigest()
        if a.sha256 and h != a.sha256:
            raise SystemExit(f"--state sha256 {h} != expected {a.sha256}")
        sd = torch.load(a.state, map_location="cpu", weights_only=True)

        def _pretrained(seed: int = 0):
            m = _plain(seed)
            before = {k: v.detach().clone() for k, v in m.state_dict().items()}
            # strict=True: a key that does not belong, or one that is missing, is a
            # different network and must stop the run rather than load 99 % of itself.
            m.load_state_dict(sd, strict=True)
            moved = sum(1 for k, v in m.state_dict().items()
                        if not torch.equal(v, before[k]))
            if moved == 0:
                raise SystemExit("the state_dict changed NOTHING -- it is the init.")
            print(f"[extract_yolo] loaded {len(sd)} tensors from {a.state} "
                  f"({moved} differ from init), sha256 {h[:16]}")
            m.eval()
            return m

        y.get_model = _pretrained
        provenance = f"ultralytics yolov8n.pt COCO-80 via {pathlib.Path(a.state).name}"

    print(f"[extract_yolo] weights: {provenance}")
    print(f"[extract_yolo] input {a.input}  nc {a.nc}  "
          f"calib {a.calib_dir or 'torch.randn'}  fusion-target {a.fusion_target}")

    from modelblaster.pipeline import extract_graph
    sys.argv = ["extract_graph",
                "--model", "yolov8_nano",
                "--out-dir", a.out_dir,
                "--quant", "int8",
                "--num-calibration", str(a.num_calibration),
                "--fusion-target", a.fusion_target]
    extract_graph.main()

    pathlib.Path(a.out_dir, "PROVENANCE.txt").write_text(
        f"weights: {provenance}\ninput: {a.input}\nnc: {a.nc}\n"
        f"calibration: {a.calib_dir or 'torch.randn'} x {a.num_calibration}\n"
        f"fusion-target: {a.fusion_target}\n")


if __name__ == "__main__":
    main()
