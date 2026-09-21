#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Why the int8 encoder does not transcribe: activation-quantisation study, in FLOAT.

host_fidelity.py measures that ModelBlaster's int8 Moonshine encoder produces transcripts
unrelated to the float model's.  This script asks whether that is a defect in the lowering
or a property of per-tensor int8 activations, by FAKE-QUANTISING activations inside the
float model (every FX node output rounded to its grid and clamped; weights left float) and
measuring the encoder output's cosine against float on the eval utterances.

    policy                   what the activation grid is
    per_tensor_int8_maxabs   ModelBlaster's stock rule: max|x| over calibration / 127
    per_tensor_int8_gelu     the same with MB_INT8_GELU_AWARE_RANGES=1's rule
    per_tensor_int8_pNN      clipped at the NN-th percentile of |x| (a common PTQ fix)
    per_channel_int8         one max-abs scale per channel (dim 1 of the stem, last dim after)
    per_tensor_int12/int16   wider codes, max-abs

These are ESTIMATES of what a kernel set with that activation grid would reach -- fake
quantisation in float, not an integer pipeline -- and they are labelled so in the JSON.
The integer pipeline itself is measured by host_fidelity.py.

    python3 quant_study.py --json quant_study.json
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import moonshine_enc as me  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--ncal", type=int, default=16)
    ap.add_argument("--decode", action="store_true",
                    help="also decode each policy's encoder output with HF's float decoder "
                         "(needs transformers 4.48.0: PYTHONPATH=$MOONSHINE_DIR/pylib)")
    a = ap.parse_args()
    from modelblaster.pipeline.extract_graph import _mb_symbolic_trace, _CaptureTensors

    m = me.build_encoder()
    gm = _mb_symbolic_trace(m)
    gelu_users = {n.name for n in gm.graph.nodes
                  if n.op not in ("output", "placeholder") and n.users and all(
                      u.op == "call_module" and isinstance(gm.get_submodule(u.target), torch.nn.GELU)
                      for u in n.users)}
    sp = me.load_speech()
    split = me.speech_split(sp)
    cal = me.calibration_inputs(a.ncal)
    ev = [me.input_tensor(sp["wav"][i]) for i in split["eval"]]

    maxabs, pos, neg, pc, tops, counts = {}, {}, {}, {}, collections.defaultdict(list), collections.Counter()
    for x in cal:
        c = _CaptureTensors(gm)
        with torch.no_grad():
            c.run(x)
        for k, t in c.tensors.items():
            if t.dtype != torch.float32:
                continue
            ab = t.abs()
            maxabs[k] = max(maxabs.get(k, 0.0), float(ab.max()))
            pos[k] = max(pos.get(k, 0.0), float(t.clamp(min=0).max()))
            neg[k] = max(neg.get(k, 0.0), float((-t).clamp(min=0).max()))
            ch = ab.amax(dim=(0, 2, 3)) if t.dim() == 4 else ab.reshape(-1, t.shape[-1]).amax(dim=0)
            pc[k] = torch.maximum(pc[k], ch) if k in pc else ch
            flat = ab.reshape(-1).numpy()
            tops[k].append(np.sort(flat)[-max(1, flat.size // 100):])
            counts[k] += flat.size

    def pct(k, p):
        top = np.sort(np.concatenate(tops[k]))[::-1]
        idx = int(np.floor((1 - p / 100.0) * counts[k]))
        return float(top[min(idx, len(top) - 1)])

    class FQ(torch.fx.Interpreter):
        def __init__(self, g, scale_of, qmax):
            super().__init__(g)
            self.scale_of, self.qmax = scale_of, qmax

        def run_node(self, n):
            r = super().run_node(n)
            if isinstance(r, torch.Tensor) and r.dtype == torch.float32 and n.name in maxabs:
                s = self.scale_of(n.name, r)
                r = torch.clamp(torch.round(r / s), -self.qmax - 1, self.qmax) * s
            return r

    with torch.no_grad():
        ref = [m(x).reshape(-1) for x in ev]

    decode = None
    if a.decode:
        from transformers import MoonshineForConditionalGeneration, PreTrainedTokenizerFast
        from transformers.modeling_outputs import BaseModelOutput
        import host_fidelity as hfid
        hf = MoonshineForConditionalGeneration.from_pretrained(str(me.moonshine_dir())).eval()
        tok = PreTrainedTokenizerFast(tokenizer_file=os.path.join(str(me.moonshine_dir()), "tokenizer.json"))

        def decode(h):
            with torch.no_grad():
                ids = hf.generate(encoder_outputs=BaseModelOutput(last_hidden_state=h.reshape(1, me.T, me.D)),
                                  max_new_tokens=26, do_sample=False, num_beams=1)
            return hfid.norm_text(tok.decode(ids[0], skip_special_tokens=True))
        ref_txt = [decode(f) for f in ref]

    def score(scale_of, qmax):
        cs, pairs = [], []
        with torch.no_grad():
            for i, (x, f) in enumerate(zip(ev, ref)):
                q = FQ(gm, scale_of, qmax).run(x).reshape(-1)
                cs.append(float(f @ q / (f.norm() * q.norm())))
                if decode is not None:
                    pairs.append((ref_txt[i], decode(q)))
        r = {"mean_cosine": float(np.mean(cs)), "min_cosine": float(np.min(cs))}
        if decode is not None:
            r["wer_vs_float_transcripts"] = hfid.wer(pairs)
        return r

    def pt(bits, rng):
        qmax = 2 ** (bits - 1) - 1
        return (lambda k, r: max(rng(k), 1e-8) / qmax), qmax

    def pchan(bits):
        qmax = 2 ** (bits - 1) - 1

        def f(k, r):
            s = pc[k].clamp(min=1e-8) / qmax
            return s.view(1, -1, 1, 1) if r.dim() == 4 else s
        return f, qmax

    policies = {
        "per_tensor_int8_maxabs": pt(8, lambda k: maxabs[k]),
        "per_tensor_int8_gelu": pt(8, lambda k: max(pos[k], min(neg[k], 8.0)) if k in gelu_users else maxabs[k]),
        "per_tensor_int8_p99.99": pt(8, lambda k: pct(k, 99.99)),
        "per_tensor_int8_p99.9": pt(8, lambda k: pct(k, 99.9)),
        "per_tensor_int8_p99": pt(8, lambda k: pct(k, 99.0)),
        "per_channel_int8": pchan(8),
        "per_channel_int10": pchan(10),
        "per_tensor_int12": pt(12, lambda k: maxabs[k]),
        "per_tensor_int16": pt(16, lambda k: maxabs[k]),
    }
    out = {"what": "fake-quantised ACTIVATIONS inside the float encoder (weights float); cosine "
                   "of the encoder output against float over the 16 whole-transcript eval "
                   "utterances and, with --decode, the WER of HF's float decoder (greedy, 26 "
                   "tokens) on that output against its transcript of the float output. "
                   "ESTIMATES for kernel sets with these activation grids, not measurements of "
                   "an integer pipeline; one speaker, a small-sample check.",
           "calibration_windows": a.ncal, "eval_utterances": len(ev), "policies": {}}
    for name, (fn, qmax) in policies.items():
        out["policies"][name] = score(fn, qmax)
        print(f"  {name:26s} mean cos {out['policies'][name]['mean_cosine']:.4f}  "
              f"min {out['policies'][name]['min_cosine']:.4f}  "
              f"WER vs float {out['policies'][name].get('wer_vs_float_transcripts', float('nan')):.3f}")
    stats = {}
    for k in ("stem_conv1", "stem_tanh", "stem_groupnorm", "stem_conv2", "stem_gelu2", "stem_conv3",
              "stem_gelu3", "add_11", "layer_norm"):
        if k in maxabs:
            stats[k] = {"max_abs": maxabs[k], "p99": pct(k, 99.0), "p99.9": pct(k, 99.9),
                        "per_channel_max_median": float(pc[k].median()),
                        "per_channel_max_top": float(pc[k].max())}
    out["activation_ranges_over_calibration"] = stats
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
