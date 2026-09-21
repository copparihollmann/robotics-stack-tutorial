#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build the int8 unrolled decoder: calibrate, extract, codegen.

The decoder's inputs are not audio, so calibration has to be manufactured: for each calibration
window this runs the FLOAT ported decoder to get the token sequence the model would emit, and
feeds the resulting (h_0..h_{N-1}, kx, vx) as one calibration sample.  Teacher-forced on the
model's own float output, which is what the int8 model will be asked to reproduce.

    MB_INT8_CALIB_POLICY=p99.9 python3 model_dec_build.py --n-steps 24 --ncal 16 --out out/decint8
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import librispeech_sets as ls  # noqa: E402
import moonshine_dec as md  # noqa: E402
import moonshine_enc as me  # noqa: E402


@torch.no_grad()
def float_rollout(um, emb, enc_out, pro, start: int, eos: int, n_steps: int):
    """Greedy decode with the FLOAT unrolled model; returns its h inputs and its tokens.

    The unrolled graph takes every h as an input, so a rollout is: run the graph with the h's
    filled so far, read step k's logits, argmax, fill h_{k+1}.  Past EOS the h's are held at the
    EOS embedding -- the driver will early-exit there, and calibration should not see garbage.
    """
    kxvx = pro(enc_out)
    kx, vx = kxvx[:md.LAYERS], kxvx[md.LAYERS:]
    hs = [emb[start].view(1, 1, md.D)] + [emb[eos].view(1, 1, md.D) for _ in range(n_steps - 1)]
    toks = []
    for k in range(n_steps):
        lg = um(*hs, *kx, *vx)[k]
        t = int(lg.reshape(-1).argmax())
        toks.append(t)
        if t == eos:
            break
        if k + 1 < n_steps:
            hs[k + 1] = emb[t].view(1, 1, md.D)
    return hs, kx, vx, toks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-steps", type=int, default=24)
    ap.add_argument("--ncal", type=int, default=16)
    ap.add_argument("--out", required=True)
    ap.add_argument("--skip-extract", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    os.makedirs(a.out, exist_ok=True)
    import model_vocab as mv
    import modelblaster.pipeline.extract_graph as eg
    hf, tok = mv.load_hf("cpu")
    sd = hf.state_dict()
    emb = sd["model.decoder.embed_tokens.weight"]
    start, eos = hf.config.decoder_start_token_id, hf.config.eos_token_id

    um = md.load_unrolled(md.make_unrolled(a.n_steps), sd)
    pro = md.load_prologue(md.MbCrossPrologue().eval(), sd)

    c, idx = ls.cal_set(a.ncal)
    samples = []
    with torch.no_grad():
        for n, i in enumerate(idx):
            w = np.asarray(c.wav(i), dtype=np.float32)
            # cal_set is not restricted to <= 4 s, so crop as well as pad -- centre-crop, the
            # same rule model_rung_gate.window() uses, so calibration sees what evaluation sees.
            if len(w) > me.N_SAMPLES:
                o = (len(w) - me.N_SAMPLES) // 2
                w = w[o:o + me.N_SAMPLES]
            else:
                w = np.pad(w, (0, me.N_SAMPLES - len(w)))
            enc = hf.model.encoder(torch.from_numpy(w[None, :])).last_hidden_state
            hs, kx, vx, toks = float_rollout(um, emb, enc, pro, start, eos, a.n_steps)
            samples.append([*hs, *kx, *vx])
            print(f"  cal {n + 1}/{len(idx)}: {len(toks)} tokens  {tok.decode(toks, skip_special_tokens=True)[:58]!r}",
                  flush=True)
    print(f"calibration built: {len(samples)} samples, {len(samples[0])} tensors each "
          f"({time.time() - t0:.0f} s)", flush=True)
    if a.skip_extract:
        return
    ir_dir = os.path.join(a.out, "ir")
    os.makedirs(ir_dir, exist_ok=True)
    eg.extract_int8(um, samples[0], "moonshine_dec", ir_dir,
                    calibration_samples=samples, fusion_target="pext_nl")
    ir = json.load(open(os.path.join(ir_dir, "graph.json")))
    print(f"extracted: {len(ir.get('dispatches', []))} dispatches, "
          f"{len(ir['tensors'])} tensors ({time.time() - t0:.0f} s)")
    json.dump({"n_steps": a.n_steps, "ncal": len(samples),
               "calib_policy": os.environ.get("MB_INT8_CALIB_POLICY", "max"),
               "dispatches": len(ir.get("dispatches", []))},
              open(os.path.join(a.out, "build.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
