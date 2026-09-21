#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Which tensors account for the int8 encoder's error: restore them to float, worst first.

quant_diag.py finds that no single group of tensors, left float, repairs the W8A8 encoder:
several break it independently.  This script names the SET.  Starting from W8A8 (the
ModelBlaster grids, fq.py), it restores tensor families to float in the order of their
ISOLATED harm (quant_diag.json: output SQNR with only that family quantised, lowest first).
After each step it records output SQNR on the sweep set and WER on dev-clean, both against
the float encoder's transcripts and against the references.  It stops when WER against
float is under --target.

FLOAT SIMULATION: the WERs are estimates of a kernel set with these grids.

    PYTHONPATH=zephyr-chipyard-sw:$MOONSHINE_DIR/pylib python3 quant_greedy.py \
        --diag quant_diag.json --json quant_greedy.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import moonshine_enc as me  # noqa: E402
import quant_diag as qd  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--diag", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--ncal", type=int, default=64)
    ap.add_argument("--ntune", type=int, default=256)
    ap.add_argument("--target", type=float, default=0.02, help="stop at this WER against float")
    ap.add_argument("--max-steps", type=int, default=40)
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = fq.device()
    diag = json.load(open(a.diag))

    m = me.build_encoder().to(dev)
    gm = fq.trace(m).to(dev)
    gfed = fq.gelu_fed(gm)
    fam = qd.families(gm)
    ws = fq.WeightState(m)
    cc, cidx = ls.cal_set(a.ncal)
    st = fq.Stats(dev)
    for i in cidx:
        fq.FQInterp(gm, {}, stats=st).run(me.input_tensor(cc.wav(i)).to(dev))
    rng = fq.mb_ranges(st, gfed)
    A8 = {k: ("pt", 8, rng[k]) for k in st.t}
    W8 = {k: ("pt", 8) for k in ws.mods}

    tc, tall = ls.tune_set()
    tidx = ls.even(tall, a.ntune)
    xs = [me.input_tensor(tc.wav(i)).to(dev) for i in tidx]
    dec = fq.Decoder(dev, 40)
    ws.restore()
    fl = [fq.FQInterp(gm, {}).run(x) for x in xs]
    fl_txt = dec(fl)
    refs = [tc.texts[i] for i in tidx]

    def evaluate(cfg, wcfg):
        ws.apply(wcfg)
        o = [fq.FQInterp(gm, cfg).run(x) for x in xs]
        ws.restore()
        txt = dec(o)
        return {"sqnr_db": fq.sqnr_db(fl, o), "cosine": fq.cosine(fl, o),
                "wer_vs_float": fq.wer(fl_txt, txt)["wer"], "wer_vs_reference": fq.wer(refs, txt)["wer"]}

    order = sorted(diag["tensors"].items(), key=lambda kv: kv[1]["iso_A8"]["sqnr_db"])
    steps = [{"restored": [], "added": None, **evaluate(A8, W8)}]
    print(f"[greedy] W8A8: {json.dumps(steps[0])}", flush=True)
    cfg = dict(A8)
    restored = []
    for f, d in order[:a.max_steps]:
        for k in fam.get(f, [f]):
            cfg.pop(k, None)
        restored.append(f)
        r = {"restored": list(restored), "added": f, "group": d["group"],
             "iso_sqnr_db": d["iso_A8"]["sqnr_db"], **evaluate(cfg, W8)}
        steps.append(r)
        print(f"[greedy] +{f:40s} ({d['group']}): SQNR {r['sqnr_db']:6.2f} dB  WER vs float {r['wer_vs_float']:.4f}  "
              f"vs ref {r['wer_vs_reference']:.4f}  ({time.time() - t0:.0f} s)", flush=True)
        if r["wer_vs_float"] <= a.target:
            break
    float_ref = fq.wer(refs, fl_txt)["wer"]
    out = {"what": "greedy float restore of W8A8 tensor families, worst isolated SQNR first; FLOAT SIMULATION (estimates)",
           "tune_utterances": len(tidx), "tune_speakers": len({tc.speakers[i] for i in tidx}),
           "calibration_windows": len(cidx), "float_wer_vs_reference": float_ref, "target_wer_vs_float": a.target,
           "steps": steps, "seconds": time.time() - t0}
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}; float WER vs reference {float_ref:.4f}")


if __name__ == "__main__":
    main()
