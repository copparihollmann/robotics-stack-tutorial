#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Do the vocabulary prune and beam search COMPOSE?  The one measurement MOONSHINE_MODEL.md §4.3
leaves as an assumption.

§4.3 stacks three numbers that were measured separately: an int8 candidate's WER in generated C
(R 8.31 %, F3PR 7.66 % on test-clean), the lm_head prune's cost measured on the FLOAT model
(+0.29 at 16,384 rows) and beam 2's gain, also on the float model (−0.76).  Adding them assumes
quantisation error and search error are independent, and they have no particular reason to be.

This measures the 2 x 2 directly, on the SAME int8 encoder the board would run:

    greedy / full vocabulary      greedy / pruned
    beam 2 / full vocabulary      beam 2 / pruned

and reports the INTERACTION,  (both - base) - (prune - base) - (beam - base), with a paired
bootstrap over utterances.  An interval covering 0 means §4.3's addition is sound; one that does
not means the ranking moves.  The same 2 x 2 is run on the float encoder so the int8 and float
interactions can be compared.

The encoder is ModelBlaster's generated C for the candidate (hostrun.build, the same binary
q16_fidelity.py scores), run on the CPU; only the decoder needs a GPU, and --device cpu keeps the
whole thing off a shared card.

    PYTHONPATH=$ZCS:$MOONSHINE_DIR/pylib python3 model_compose.py --set dev \\
        --candidate F3PR:out/q16/F3PR/ir:out/q16/F3PR/gen_nl --keep-rows 16384 \\
        --train-counts .../model_train_row_counts.npy --workdir out/compose --json model_compose_dev.json
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
import model_cost as mc  # noqa: E402
import model_vocab as mv  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402


@torch.no_grad()
def decode_hs(model, tok, hs: list, dev, keep_mask=None, num_beams=1, batch=32, max_new=40):
    """Decode a list of encoder hidden states, optionally with a kept-row mask and beam search."""
    from transformers.modeling_outputs import BaseModelOutput
    proc = None
    if keep_mask is not None:
        from transformers import LogitsProcessorList, LogitsProcessor
        km = torch.as_tensor(keep_mask, device=dev, dtype=torch.bool)

        class KeepOnly(LogitsProcessor):
            def __call__(self, input_ids, scores):
                return scores.masked_fill(~km, torch.finfo(scores.dtype).min)
        proc = LogitsProcessorList([KeepOnly()])
    out = []
    for i in range(0, len(hs), batch):
        h = torch.cat([x.reshape(1, me.T, me.D) for x in hs[i:i + batch]], 0).to(dev)
        ids = model.generate(encoder_outputs=BaseModelOutput(last_hidden_state=h),
                             max_new_tokens=max_new, do_sample=False, num_beams=num_beams,
                             logits_processor=proc)
        out += [tok.decode(r, skip_special_tokens=True) for r in ids]
    return out


def interaction(e_base, e_prune, e_beam, e_both, n, reps=2000, seed=11):
    """(both - base) - (prune - base) - (beam - base) = both - prune - beam + base, resampled
    over utterances with all four systems keeping the same resample."""
    rng = np.random.default_rng(seed)
    w = float(n.sum())
    d = (e_both.sum() - e_prune.sum() - e_beam.sum() + e_base.sum()) / w
    idx = rng.integers(0, len(n), size=(reps, len(n)))
    ds = ((e_both[idx].sum(1) - e_prune[idx].sum(1) - e_beam[idx].sum(1) + e_base[idx].sum(1))
          / n[idx].sum(1))
    return {"interaction_wer_points": 100.0 * d,
            "ci95": [100.0 * float(np.percentile(ds, 2.5)), 100.0 * float(np.percentile(ds, 97.5))],
            "resamples": reps, "unit": "utterance",
            "reading": "0 means the prune's cost and the beam's gain add; positive means the two "
                       "together are worse than the sum of their parts"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", choices=("dev", "test"), required=True)
    ap.add_argument("--candidate", action="append", default=[],
                    help="label:IR_DIR:GEN_DIR (omit for the float encoder only)")
    ap.add_argument("--keep-rows", type=int, default=16384)
    ap.add_argument("--train-counts", required=True)
    ap.add_argument("--beams", type=int, default=2)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 4))
    ap.add_argument("--device", default=None, choices=("cpu", "cuda"))
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = torch.device(a.device) if a.device else fq.device()
    model, tok = mv.load_hf(dev)

    corpus, idx = ls.tune_set() if a.set == "dev" else ls.eval_set()
    if a.n:
        idx = ls.even(idx, a.n)
    refs = [corpus.texts[i] for i in idx]
    x = np.stack([me.window(corpus.wav(i)) for i in idx]).astype(np.float32)

    cnt = np.load(a.train_counts)
    keep = np.zeros(model.config.vocab_size, dtype=bool)
    keep[np.argsort(-cnt, kind="stable")[:a.keep_rows]] = True
    keep[list(range(0, 259))] = True            # specials + the 256 <0xNN> byte rows

    out = {"what": __doc__.split("\n")[0],
           "set": {"name": f"{corpus.name} <= {me.WINDOW_S} s", "utterances": len(idx),
                   "speakers": len({corpus.speakers[i] for i in idx}),
                   "words": fq.wer(refs, refs)["words"]},
           "prune": {"rows_kept": int(keep.sum()), "requested": a.keep_rows,
                     "source": os.path.basename(a.train_counts),
                     "lm_head_bytes": mc.lmhead_image(int(keep.sum()))["fetched_bytes"]},
           "beams": a.beams, "device": str(dev), "encoders": {}}

    encoders = {}
    # the float encoder, the reference the prune and beam deltas were first measured on
    gm = fq.trace(me.build_encoder().to(dev)).to(dev)
    xt = [torch.from_numpy(xi).view(1, 1, 1, -1).to(dev) for xi in x]
    encoders["float"] = [fq.FQInterp(gm, {}).run(t).reshape(-1).cpu() for t in xt]
    print(f"[compose] float encoder done ({time.time()-t0:.0f} s)", flush=True)

    for spec in a.candidate:
        label, ir_dir, gen = spec.split(":")
        ir_dir, gen = os.path.abspath(ir_dir), os.path.abspath(gen)
        ir = json.load(open(os.path.join(ir_dir, "graph.json")))
        meta = ir["tensors"][ir["input"]["tensor"]]
        s_in = meta["quant"]["scale"]
        if meta["dtype"] == "i16":
            xq = np.clip(np.rint(x.astype(np.float64) / s_in), -32768, 32767).astype(np.int16)
        else:
            xq = torch.round(torch.from_numpy(x) / s_in).clamp(-127, 127).to(torch.int8).numpy()
        s_out = ir["tensors"][ir["output"]["tensors"][0]]["quant"]["scale"]
        wd = os.path.abspath(os.path.join(a.workdir, label))
        exe = hostrun.build(gen, wd)
        yq = q16f.run_parallel(exe, xq, me.T * me.D, os.path.join(wd, "batch"), a.jobs)
        encoders[label] = [torch.from_numpy(y.astype(np.float32) * np.float32(s_out)) for y in yq]
        print(f"[compose] {label} generated C done ({time.time()-t0:.0f} s)", flush=True)

    for name, hs in encoders.items():
        cells = {}
        errs = {}
        for cell, (km, nb) in (("base", (None, 1)), ("prune", (keep, 1)),
                               ("beam", (None, a.beams)), ("both", (keep, a.beams))):
            txt = decode_hs(model, tok, hs, dev, keep_mask=km, num_beams=nb)
            e, n = q16f.utt_errors(refs, txt)
            errs[cell] = e
            cells[cell] = {"wer": float(e.sum() / n.sum()), "errors": int(e.sum())}
            print(f"[compose] {name:6s} {cell:5s} WER {cells[cell]['wer']*100:.2f} % "
                  f"({time.time()-t0:.0f} s)", flush=True)
        nw = n
        rec = {"cells": cells,
               "delta_prune": q16f.paired_bootstrap(errs["prune"], errs["base"], nw),
               "delta_beam": q16f.paired_bootstrap(errs["beam"], errs["base"], nw),
               "delta_both": q16f.paired_bootstrap(errs["both"], errs["base"], nw),
               "sum_of_parts_wer": (cells["prune"]["wer"] + cells["beam"]["wer"]
                                    - cells["base"]["wer"]),
               "interaction": interaction(errs["base"], errs["prune"], errs["beam"], errs["both"], nw)}
        out["encoders"][name] = rec
        it = rec["interaction"]
        print(f"[compose] {name:6s} both {cells['both']['wer']*100:.2f} % against a sum of parts "
              f"{rec['sum_of_parts_wer']*100:.2f} % -> interaction "
              f"{it['interaction_wer_points']:+.2f} [{it['ci95'][0]:+.2f}, {it['ci95'][1]:+.2f}]",
              flush=True)

    out["elapsed_s"] = time.time() - t0
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({out['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
