#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The accuracy gate for ONE rung of the variable-length IR ladder (MOONSHINE_MODEL.md section 2.4).

WHY THIS EXISTS.  `host_fidelity.py` and `q16_fidelity.py` take the window length from
`moonshine_enc` module constants -- `me.N_SAMPLES` for the input and `me.T * me.D` for the output
-- so they work on the 4.0 s build and raise on any other (a reshape of 1,133,568 into
(24, 47,520)).  That is a hole in the ladder's gate chain: a rung can be built and timed but not
accuracy-checked, and section 4.2 ranks the ladder FIRST.  This file closes it without touching
either of those files, by taking the window from the RUNG'S OWN IR instead of from a constant:

    graph.json  input.tensor  -> shape [1, 1, 1, n_samples]   the rung's window
                output.tensors[0] -> shape [1, T, D]          the rung's frame count

so one script gates every rung, and a rung that changes shape cannot silently be gated against the
wrong one.  Everything else is q16_fidelity's method: ModelBlaster's generated C built for the
host, run on the window the device would see, dequantised with the IR's output scale, decoded by
HF's float decoder, greedy, and scored with fq.py's normalisation and paired bootstrap.

**Which utterances a rung is scored on.** The ones it SERVES: those whose audio fits its window
whole, so the LibriSpeech transcript is the reference for the whole window.  A 2.5 s rung is
therefore scored on a different (smaller) subset than a 4.0 s one, and the script prints the
subset with every number, because a WER on 300 utterances is not comparable with one on 772.

    PYTHONPATH=$ZCS:$MOONSHINE_DIR/pylib python3 model_rung_gate.py --set dev \\
        --rung 2.5s:out/rungs/2500/ir:out/rungs/2500/gen_nl \\
        --rung 4.0s:out/q16/F3PR/ir:out/q16/F3PR/gen_nl \\
        --workdir out/runggate --json model_rung_gate_dev.json
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
import fq  # noqa: E402
import hostrun  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import model_vocab as mv  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402


def rung_shape(ir: dict) -> tuple:
    """(n_samples, T, D) from the IR itself -- the whole point of this file."""
    n = int(ir["tensors"][ir["input"]["tensor"]]["shape"][-1])
    out = ir["tensors"][ir["output"]["tensors"][0]]["shape"]
    return n, int(out[-2]), int(out[-1])


def window(w: np.ndarray, n: int) -> np.ndarray:
    """the rung's window: zero-pad at the end if the clip is shorter, centre-crop if longer"""
    w = np.asarray(w, dtype=np.float32)
    if len(w) <= n:
        return np.pad(w, (0, n - len(w)))
    o = (len(w) - n) // 2
    return w[o:o + n]


@torch.no_grad()
def decode_hs(model, tok, hs: list, dev, T: int, D: int, batch=32, max_new=40):
    from transformers.modeling_outputs import BaseModelOutput
    out = []
    for i in range(0, len(hs), batch):
        h = torch.cat([x.reshape(1, T, D) for x in hs[i:i + batch]], 0).to(dev)
        ids = model.generate(encoder_outputs=BaseModelOutput(last_hidden_state=h),
                             max_new_tokens=max_new, do_sample=False, num_beams=1)
        out += [tok.decode(r, skip_special_tokens=True) for r in ids]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", choices=("dev", "test"), required=True)
    ap.add_argument("--rung", action="append", required=True, help="label:IR_DIR:GEN_DIR")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 4))
    ap.add_argument("--device", default=None, choices=("cpu", "cuda"))
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = torch.device(a.device) if a.device else fq.device()
    model, tok = mv.load_hf(dev)
    corpus = ls.Corpus("dev_clean" if a.set == "dev" else "test_clean")

    out = {"what": __doc__.split("\n")[0], "set": corpus.name, "device": str(dev), "rungs": {}}
    for spec in a.rung:
        label, ir_dir, gen = spec.split(":")
        ir_dir, gen = os.path.abspath(ir_dir), os.path.abspath(gen)
        ir = json.load(open(os.path.join(ir_dir, "graph.json")))
        n, T, D = rung_shape(ir)
        # the rung serves the utterances that fit its window whole
        idx = [i for i in range(len(corpus.ids)) if corpus.lens[i] <= n]
        refs = [corpus.texts[i] for i in idx]
        x = np.stack([window(corpus.wav(i), n) for i in idx]).astype(np.float32)

        meta = ir["tensors"][ir["input"]["tensor"]]
        s_in = meta["quant"]["scale"]
        if meta["dtype"] == "i16":
            xq = np.clip(np.rint(x.astype(np.float64) / s_in), -32768, 32767).astype(np.int16)
        else:
            xq = torch.round(torch.from_numpy(x) / s_in).clamp(-127, 127).to(torch.int8).numpy()
        s_out = ir["tensors"][ir["output"]["tensors"][0]]["quant"]["scale"]
        wd = os.path.abspath(os.path.join(a.workdir, label))
        exe = hostrun.build(gen, wd)
        yq = q16f.run_parallel(exe, xq, T * D, os.path.join(wd, "batch"), a.jobs)
        hs = [torch.from_numpy(y.astype(np.float32) * np.float32(s_out)) for y in yq]
        txt = decode_hs(model, tok, hs, dev, T, D)
        e_c, nw = q16f.utt_errors(refs, txt)

        # the float control AT THE SAME WINDOW -- the comparison that isolates the arithmetic
        fl = [model.model.encoder(torch.from_numpy(xi[None, :]).to(dev)).last_hidden_state
              .reshape(-1).cpu() for xi in x]
        fl_txt = decode_hs(model, tok, fl, dev, T, D)
        e_f, _ = q16f.utt_errors(refs, fl_txt)

        rec = {"ir": ir_dir, "gen": gen,
               "window_samples": n, "window_s": n / me.SR, "frames": T, "hidden": D,
               "input_dtype": meta["dtype"], "input_scale": s_in, "output_scale": s_out,
               "utterances_served": len(idx),
               "speakers": len({corpus.speakers[i] for i in idx}), "words": int(nw.sum()),
               "fraction_of_set": len(idx) / len(corpus.ids),
               "wer_c_vs_reference": float(e_c.sum() / nw.sum()),
               "wer_float_same_window_vs_reference": float(e_f.sum() / nw.sum()),
               "c_minus_float_same_window": q16f.paired_bootstrap(e_c, e_f, nw),
               "wer_c_vs_float_transcripts": fq.wer(fl_txt, txt),
               "sqnr_db": fq.sqnr_db(fl, hs), "host_seconds": round(time.time() - t0, 1)}
        out["rungs"][label] = rec
        print(f"[rung {label}] window {rec['window_s']:.2f} s, T = {T}: serves {len(idx)} of "
              f"{len(corpus.ids)} utterances ({rec['fraction_of_set']*100:.0f} %), {int(nw.sum())} words; "
              f"C {rec['wer_c_vs_reference']*100:.2f} %, float at the same window "
              f"{rec['wer_float_same_window_vs_reference']*100:.2f} %, gap "
              f"{rec['c_minus_float_same_window']['delta_wer']*100:+.2f} "
              f"[{rec['c_minus_float_same_window']['ci95'][0]*100:+.2f}, "
              f"{rec['c_minus_float_same_window']['ci95'][1]*100:+.2f}], SQNR {rec['sqnr_db']:.1f} dB",
              flush=True)

    out["elapsed_s"] = time.time() - t0
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({out['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
