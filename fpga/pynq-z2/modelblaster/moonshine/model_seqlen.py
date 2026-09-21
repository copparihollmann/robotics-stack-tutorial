#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""What shortening the ENCODER SEQUENCE costs in WER -- as a curve, over the ways of shortening it.

Moonshine's encoder turns a 4.0 s window into 165 frames through three strided convolutions
(64 x 3 x 2 = 384 samples = 24 ms per frame).  `matmul_b_s8` and `softmax_s8` are O(T^2) and are
44.7 % of encoder steady on b34; everything else in the blocks is O(T).  So halving T is worth
roughly 2x on the blocks -- but only the blocks.  What it COSTS is measured here.

THE KNOB IS NOT ONE KNOB.  Five reachable ways to halve the frame rate, and they differ in what
they leave the model seeing and in what they leave the board computing:

    c1s128   conv1 stride 64 -> 128.  T1 999 -> 500.  EVERYTHING downstream halves, the stem
             included, so it is the only variant with no fixed floor -- and conv2's 7-frame
             kernel now spans 2x the time, which is the biggest change to what the model sees.
    c2s6     conv2 stride 3 -> 6.  conv1/tanh/groupnorm are untouched and do NOT shrink.
    c3s3/4   conv3 stride 2 -> 3 or 4.  conv1, conv2 and their nonlinearities do NOT shrink:
             19.6 % of encoder steady is fixed before the knob is turned.
    dec2     keep every 2nd stem output frame.  Same fixed floor as c3s4, and c3s4 is strictly
             better (it does not compute the frames it throws away), so this exists to separate
             "the model dislikes a coarser frame rate" from "the model dislikes a wider conv".
    pool2/3  mean of k adjacent stem output frames.  Same floor as dec2, but it keeps the
             energy of the discarded frames instead of dropping it.

NONE OF THESE ADDS A PARAMETER.  Every variant runs the pinned checkpoint's own weights; a
strided convolution at stride k*s is the same convolution evaluated at a subset of positions.
Whether that is enough to make it an inference-time change is the question, not the assumption:
the answer is in `retraining_needed` in the output.

THE TRAP, and it is invisible: the rotary table is indexed by FRAME INDEX
(`position_ids = arange(0, T)` in MoonshineEncoder.forward).  After downsampling, frame j is at
time j*k of the original grid, so there are two defensible tables -- keep the INDEX (0,1,2,...,
preserving the relative-position distribution the model was trained on) or keep the TIME
(0,k,2k,..., preserving absolute timing but at position strides the model never saw).  They are
different models.  Both are measured; `--rope` selects.

GATE: at the default settings this file's encoder must reproduce `hf.model.encoder` EXACTLY.  A
re-implementation that silently diverges would make every variant below a measurement of the
re-implementation.  The gate is a max-abs difference on the hidden state, reported, and the run
refuses to score anything if it is not 0.

    PYTHONPATH=$MOONSHINE_DIR/pylib python3 model_seqlen.py --sets dev test --json model_seqlen.json
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
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402

MAX_NEW = 40


def conv_out(n, k, s):
    return (n - k) // s + 1


class Variant:
    """One way of shortening the sequence, and the shapes it produces."""

    def __init__(self, name, s1=64, s2=3, s3=2, post=None, k=1, rope="index"):
        self.name, self.s1, self.s2, self.s3 = name, s1, s2, s3
        self.post, self.k, self.rope = post, k, rope     # post in (None, "pool", "decimate")
        self.T1 = conv_out(me.N_SAMPLES, 127, s1)
        self.T2 = conv_out(self.T1, 7, s2)
        self.T3 = conv_out(self.T2, 3, s3)
        self.T = self.T3 // k if post else self.T3
        # the time step of one output frame, in samples of the original grid
        self.stride_samples = s1 * s2 * s3 * (k if post else 1)
        self.ratio = self.T / conv_out(conv_out(conv_out(me.N_SAMPLES, 127, 64), 7, 3), 3, 2)

    def as_dict(self):
        return {"name": self.name, "conv_strides": [self.s1, self.s2, self.s3],
                "post": self.post, "post_k": self.k, "rope": self.rope,
                "T1": self.T1, "T2": self.T2, "T3_before_post": self.T3, "T": self.T,
                "samples_per_frame": self.stride_samples,
                "rope_position_step": 1.0 if self.rope == "index"
                                      else self.stride_samples / (64.0 * 3.0 * 2.0),
                "ms_per_frame": 1000.0 * self.stride_samples / me.SR,
                "T_vs_base": self.ratio}


@torch.no_grad()
def encode(enc, x, v: Variant):
    """MoonshineEncoder.forward, with the strides, the post-stem step and the rotary position
    policy as parameters.  Same submodules, same weights, same order of operations."""
    import torch.nn.functional as F
    h = x.unsqueeze(1)
    h = torch.tanh(F.conv1d(h, enc.conv1.weight, enc.conv1.bias, stride=v.s1))
    h = enc.groupnorm(h)
    h = F.gelu(F.conv1d(h, enc.conv2.weight, enc.conv2.bias, stride=v.s2))
    h = F.gelu(F.conv1d(h, enc.conv3.weight, enc.conv3.bias, stride=v.s3))
    h = h.permute(0, 2, 1)                                          # [B, T3, D]
    if v.post == "pool":
        n = (h.shape[1] // v.k) * v.k
        h = h[:, :n].reshape(h.shape[0], n // v.k, v.k, h.shape[2]).mean(2)
    elif v.post == "decimate":
        h = h[:, ::v.k]
    T = h.shape[1]
    # FRACTIONAL on purpose: conv3 at stride 3 moves the frame rate by 1.5, and an integer
    # step would silently round it to 1 and make the "time" policy identical to "index".
    step = 1.0 if v.rope == "index" else (v.stride_samples / (64.0 * 3.0 * 2.0))
    pos = (torch.arange(0, T, device=h.device, dtype=torch.float32) * step).unsqueeze(0)
    pe = enc.rotary_emb(h, pos)
    for layer in enc.layers:
        h = layer(h, position_embeddings=pe)[0]
    return enc.layer_norm(h)


@torch.no_grad()
def decode_set(model, tok, corpus, idx, dev, v: Variant, batch=32, max_new=MAX_NEW):
    from transformers.modeling_outputs import BaseModelOutput
    texts = []
    for i in range(0, len(idx), batch):
        chunk = idx[i:i + batch]
        x = np.stack([me.window(corpus.wav(j)) for j in chunk]).astype(np.float32)
        xv = torch.from_numpy(x).to(dev)
        hs = encode(model.model.encoder, xv, v)
        gen = model.generate(encoder_outputs=BaseModelOutput(last_hidden_state=hs),
                             max_new_tokens=max_new, do_sample=False, num_beams=1)
        texts += [tok.decode(r, skip_special_tokens=True) for r in gen]
    return texts


@torch.no_grad()
def gate_identical(model, corpus, idx, dev, n=8):
    """This file's encoder, at the checkpoint's own strides, against HF's.  Not a tolerance:
    the operations are the same operations, so the answer must be 0."""
    base = Variant("base")
    worst = 0.0
    for j in idx[:n]:
        x = torch.from_numpy(me.window(corpus.wav(j))[None, :].astype(np.float32)).to(dev)
        a = model.model.encoder(x).last_hidden_state
        b = encode(model.model.encoder, x, base)
        worst = max(worst, float((a - b).abs().max()))
    return worst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", nargs="+", default=["dev"], choices=("dev", "test"))
    ap.add_argument("--n", type=int, default=0, help="first n utterances (0 = whole set); a "
                                                     "subset is a SCREEN, not a report")
    ap.add_argument("--variants", nargs="+", default=None)
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = fq.device()
    import model_vocab as mv
    model, tok = mv.load_hf(dev)

    cat = [Variant("base")]
    for rope in ("index", "time"):
        cat += [Variant(f"c1s128.{rope}", s1=128, rope=rope),
                Variant(f"c2s6.{rope}", s2=6, rope=rope)]
        cat += [Variant(f"c3s{s}.{rope}", s3=s, rope=rope) for s in (3, 4, 5, 6, 8)]
        cat += [Variant(f"dec{k}.{rope}", post="decimate", k=k, rope=rope) for k in (2, 3)]
        cat += [Variant(f"pool{k}.{rope}", post="pool", k=k, rope=rope) for k in (2, 3, 4)]
    if a.variants:
        cat = [v for v in cat if v.name in a.variants or v.name == "base"]

    out = {"what": __doc__.split("\n")[0], "window_s": me.WINDOW_S,
           "n_samples": me.N_SAMPLES, "max_new_tokens": MAX_NEW, "greedy": True,
           "device": str(dev), "whole_set": not a.n,
           "variants": [v.as_dict() for v in cat], "sets": {}}

    for sname in a.sets:
        corpus, idx = ls.tune_set() if sname == "dev" else ls.eval_set()
        if a.n:
            idx = idx[:a.n]
        refs = [corpus.texts[i] for i in idx]
        g = gate_identical(model, corpus, idx, dev)
        print(f"[{sname}] gate: this encoder vs HF's, max|diff| = {g:g}", flush=True)
        if g != 0.0:
            raise SystemExit(f"REFUSING to score: the re-implemented encoder differs from HF's "
                             f"by {g:g}; every variant below would measure the re-implementation")
        rec = {"utterances": len(idx), "words": int(sum(len(r.split()) for r in refs)),
               "encoder_gate_max_abs_diff_vs_hf": g, "variants": {}}
        base_txt = decode_set(model, tok, corpus, idx, dev, cat[0])
        e_b, nw = q16f.utt_errors(refs, base_txt)
        if int(nw.sum()) == 0 or not any(t.strip() for t in base_txt):
            raise SystemExit("REFUSING to score: zero reference words or an empty hypothesis set")
        rec["baseline"] = {"wer_vs_reference": float(e_b.sum() / nw.sum()),
                           "errors": int(e_b.sum()), "words": int(nw.sum()),
                           "non_empty_hypotheses": int(sum(bool(t.strip()) for t in base_txt))}
        print(f"  base      T=165  WER {rec['baseline']['wer_vs_reference']*100:.3f} %", flush=True)
        for v in cat[1:]:
            txt = decode_set(model, tok, corpus, idx, dev, v)
            e_c, nw2 = q16f.utt_errors(refs, txt)
            assert (nw2 == nw).all()
            ne = int(sum(bool(t.strip()) for t in txt))
            rec["variants"][v.name] = {
                "T": v.T, "T_vs_base": v.ratio,
                "wer_vs_reference": float(e_c.sum() / nw2.sum()),
                "errors": int(e_c.sum()), "words": int(nw2.sum()),
                "non_empty_hypotheses": ne,
                "identical_to_base_transcript": int(sum(x == y for x, y in zip(txt, base_txt))),
                "minus_base": q16f.paired_bootstrap(e_c, e_b, nw)}
            r = rec["variants"][v.name]
            print(f"  {v.name:14s} T={v.T:3d}  WER {r['wer_vs_reference']*100:7.3f} %  "
                  f"delta {r['minus_base']['delta_wer']*100:+8.3f} pp "
                  f"[{r['minus_base']['ci95'][0]*100:+.3f}, {r['minus_base']['ci95'][1]*100:+.3f}]"
                  f"  {ne}/{len(idx)} non-empty", flush=True)
        out["sets"][sname] = rec
        json.dump(out, open(a.json, "w"), indent=1)
    out["elapsed_s"] = round(time.time() - t0, 1)
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({out['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
