#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Would a quantisation search over the DECODER reach for per-channel weights (`wpc`)?

WHY THIS MATTERS.  `wpc` is the knob that makes a linear `linear_s8_pc`, and an `_pc` op is not
engine-capable: candidate R carries no `wpc` and runs on the engine, F3PR carries 39 and does not.
The decoder composition (ROCC_DECOUPLED.md s8.9) assumes the decoder's GEMMs run on the engine,
and that assumption is worth **8,489,362 cycles against 24,604,781 on hart 0 per token -- 2.90x,
467 ms** at 34.4828 MHz.  If the decoder needed `wpc`, the decoder table would not be slightly
wrong; it would describe a machine that cannot exist.

**But R's plan came from quant_fix.py searching the ENCODER only** -- every knob in it is named
after an encoder op, and there is no decoder graph to search (s7.8: the decoder is not
code-generable).  So the question has never been asked of the decoder.

**How this asks it without a decoder IR.**  `wpc` is reached for when per-TENSOR weight
quantisation is materially worse than per-CHANNEL for a given matrix.  That is a property of the
weights and can be measured on the real metric directly: fake-quantise the decoder's weights both
ways on the real model and decode.  No IR, no lowering, no ModelBlaster -- and it answers exactly
what a search would find, because a search reaches for `wpc` precisely when it buys WER.

Reported per configuration on the full 765-utterance dev-clean set, and per weight tensor the
row-max spread that drives the choice.

    PYTHONPATH=$MOONSHINE_DIR/pylib python3 model_decoder_wpc.py --json model_decoder_wpc.json
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
import librispeech_sets as ls  # noqa: E402
import model_vocab as mv  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402


def qt_per_tensor(w: torch.Tensor) -> torch.Tensor:
    s = w.abs().max().clamp(min=1e-12) / 127.0
    return torch.clamp(torch.round(w / s), -127, 127) * s


def qt_per_channel(w: torch.Tensor) -> torch.Tensor:
    s = (w.abs().reshape(w.shape[0], -1).amax(1).clamp(min=1e-12) / 127.0)
    s = s.view([-1] + [1] * (w.dim() - 1))
    return torch.clamp(torch.round(w / s), -127, 127) * s


def decoder_linears(model, include_lm_head: bool) -> dict:
    """Every weight the decoder's GEMMs read.  lm_head is TIED to embed_tokens, so quantising
    `proj_out` and quantising the embedding table are the same tensor -- it is handled separately
    because it is 32,768 rows and half the token's bytes."""
    out = {}
    for name, m in model.model.decoder.named_modules():
        if isinstance(m, torch.nn.Linear):
            out[f"decoder.{name}"] = m
    if include_lm_head:
        out["proj_out"] = model.proj_out
    return out


def spread(w: torch.Tensor) -> dict:
    """The statistic that decides per-tensor against per-channel: how far the row maxima spread.
    A per-tensor scale is set by the largest row, so every other row loses log2(rowmax_max/rowmax_i)
    bits.  A flat spread means per-tensor costs nothing."""
    r = w.detach().abs().reshape(w.shape[0], -1).amax(1).float()
    r = r.clamp(min=1e-12)
    return {"rows": int(r.numel()), "max_over_median": float(r.max() / r.median()),
            "max_over_p10": float(r.max() / torch.quantile(r, 0.10)),
            "bits_lost_median_row": float(torch.log2(r.max() / r.median()))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--device", default=None, choices=("cpu", "cuda"))
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = torch.device(a.device) if a.device else fq.device()
    model, tok = mv.load_hf(dev)

    corpus, allidx = ls.tune_set()
    idx = ls.even(allidx, a.n) if a.n else allidx
    refs = [corpus.texts[i] for i in idx]
    words = q16f.utt_errors(refs, refs)[1]

    out = {"what": __doc__.split("\n")[0],
           "set": {"name": f"dev-clean <= {me.WINDOW_S} s", "utterances": len(idx),
                   "words": int(words.sum())},
           "method": "the decoder's weights fake-quantised per-tensor against per-channel on the "
                     "real model; the ENCODER is left float throughout so the only thing moving "
                     "is the decoder's weight grid",
           "engine_stake": {"token_gemms_engine_cycles": 8489362,
                            "token_gemms_hart0_cycles": 24604781, "ratio": 2.90,
                            "ms_per_token_at_34.4828MHz": (24604781 - 8489362) / 34482759 * 1e3},
           "weights": {}, "configs": {}}

    # the spread statistic, per decoder weight
    lins = decoder_linears(model, include_lm_head=True)
    for n, m in lins.items():
        out["weights"][n] = spread(m.weight)
    grp = {}
    for n, s in out["weights"].items():
        fam = ("lm_head" if n == "proj_out" else
               "self_attn" if "self_attn" in n else
               "cross_attn" if "encoder_attn" in n else "mlp")
        grp.setdefault(fam, []).append(s["max_over_median"])
    out["spread_by_family_max_over_median"] = {
        k: {"n": len(v), "min": min(v), "median": float(np.median(v)), "max": max(v)}
        for k, v in grp.items()}

    orig = {n: m.weight.detach().clone() for n, m in lins.items()}

    def run(label, which, fn):
        for n, m in lins.items():
            if n in which:
                m.weight.data.copy_(fn(orig[n]))
        txt, _, _ = mv.decode_set(model, tok, corpus, idx, dev)
        for n, m in lins.items():
            m.weight.data.copy_(orig[n])
        e, nw = q16f.utt_errors(refs, txt)
        r = {"wer": float(e.sum() / nw.sum()), "errors": int(e.sum()),
             "tensors_quantised": len(which)}
        out["configs"][label] = r
        print(f"  {label:34s} {r['wer']*100:6.2f} %   ({time.time()-t0:.0f} s)", flush=True)
        return e, nw

    allw = set(lins)
    nolm = allw - {"proj_out"}
    e0, nw = run("float decoder (baseline)", set(), qt_per_tensor)
    for label, which in (("all decoder weights", allw), ("decoder without lm_head", nolm),
                         ("lm_head only", {"proj_out"})):
        ept, _ = run(f"per-TENSOR: {label}", which, qt_per_tensor)
        epc, _ = run(f"per-CHANNEL: {label}", which, qt_per_channel)
        out["configs"][f"pt_minus_pc: {label}"] = q16f.paired_bootstrap(ept, epc, nw)
        out["configs"][f"pt_minus_float: {label}"] = q16f.paired_bootstrap(ept, e0, nw)
        d = out["configs"][f"pt_minus_pc: {label}"]
        print(f"    -> per-tensor MINUS per-channel {d['delta_wer']*100:+.2f} points "
              f"[{d['ci95'][0]*100:+.2f}, {d['ci95'][1]*100:+.2f}]", flush=True)

    out["elapsed_s"] = time.time() - t0
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
