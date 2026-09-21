#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Does the int8 encoder still transcribe?  Host gate (c) -- a SMALL-SAMPLE check.

For each utterance of the fixed split (moonshine_enc.speech_split):

  float   the port's float32 encoder (bit-identical to transformers' MoonshineEncoder,
          moonshine_enc.py --check-hf) -> HF's float decoder, greedy
  int8    the GENERATED C of one ModelBlaster build, compiled for the host, on the int8
          input the device would see -> dequantised with the IR's output scale -> the
          same HF float decoder, greedy

and reports word error rates: int8 against float (does quantisation change the words?)
and both against the LibriSpeech reference on the utterances whose whole transcript fits
the 4 s window.  One speaker, 16 + 8 utterances: this is a smoke test of fidelity, NOT
an accuracy measurement, and every number it writes says so.

    PYTHONPATH=$MOONSHINE_DIR/pylib python3 host_fidelity.py \
        --variant ref:IR_DIR:GEN_DIR [--variant ew:IR_DIR:GEN_DIR ...] --json out.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hostrun  # noqa: E402
import moonshine_enc as me  # noqa: E402


def norm_text(s: str) -> list:
    s = s.upper()
    s = re.sub(r"[^A-Z' ]+", " ", s)
    return s.split()


def wer_counts(ref: list, hyp: list):
    """(edits, len(ref)) by word-level Levenshtein."""
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
            prev, d[j] = d[j], cur
    return d[len(hyp)], len(ref)


def wer(pairs) -> float:
    e = n = 0
    for r, h in pairs:
        a, b = wer_counts(r, h)
        e += a
        n += b
    return e / max(n, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", action="append", required=True,
                    help="label:IR_DIR:GEN_DIR -- GEN_DIR's kernels.c is the one built")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--max-new-tokens", type=int, default=int(me.WINDOW_S * 6.5))
    a = ap.parse_args()

    import transformers
    from transformers import MoonshineForConditionalGeneration, PreTrainedTokenizerFast
    from transformers.modeling_outputs import BaseModelOutput
    if transformers.__version__ != "4.48.0":
        raise SystemExit(f"transformers {transformers.__version__}: the port is checked "
                         f"against 4.48.0 (PYTHONPATH=$MOONSHINE_DIR/pylib)")
    mdir = str(me.moonshine_dir())
    hf = MoonshineForConditionalGeneration.from_pretrained(mdir).eval()
    tok = PreTrainedTokenizerFast(tokenizer_file=os.path.join(mdir, "tokenizer.json"))
    enc = me.build_encoder()

    sp = me.load_speech()
    split = me.speech_split(sp)
    utts = [("eval", i) for i in split["eval"]] + [("agreement", i) for i in split["agreement"]]
    x = np.stack([me.window(sp["wav"][i]) for _, i in utts]).astype(np.float32)

    def decode(h: np.ndarray) -> str:
        with torch.no_grad():
            ids = hf.generate(encoder_outputs=BaseModelOutput(
                last_hidden_state=torch.from_numpy(h.reshape(1, me.T, me.D).astype(np.float32))),
                max_new_tokens=a.max_new_tokens, do_sample=False, num_beams=1)
        return tok.decode(ids[0], skip_special_tokens=True).strip()

    rows = [{"id": sp["ids"][i], "set": s, "reference": sp["texts"][i],
             "seconds": round(len(sp["wav"][i]) / me.SR, 3)} for s, i in utts]
    for r, xi in zip(rows, x):
        with torch.no_grad():
            h = enc(torch.from_numpy(xi).view(1, 1, 1, -1)).numpy()
        r["float"] = decode(h)
        r["_float_h"] = h.reshape(-1)

    out = {"what": "host gate (c): int8 encoder (generated C, host) + HF float decoder vs "
                   "float encoder + HF float decoder, greedy",
           "caveat": "SMALL-SAMPLE CHECK: hf-internal-testing/librispeech_asr_dummy, ONE "
                     "speaker (1272), 16 whole-transcript utterances <= 4 s (zero-padded) "
                     "and 8 centre-cropped 4 s windows of longer ones; none of them was a "
                     "calibration clip. Not an accuracy measurement.",
           "checkpoint": f"{me.CKPT_REPO}@{me.CKPT_REV}",
           "speech": f"{me.SPEECH_REPO}@{me.SPEECH_REV}",
           "transformers": transformers.__version__,
           "max_new_tokens": a.max_new_tokens, "variants": {}}
    ev = [r for r in rows if r["set"] == "eval"]
    out["float_wer_vs_reference_eval"] = wer([(norm_text(r["reference"]), norm_text(r["float"]))
                                              for r in ev])

    for spec in a.variant:
        label, ir_dir, gen = spec.split(":")
        ir = json.load(open(os.path.join(ir_dir, "graph.json")))
        in_t = ir["input"]["tensor"]
        s_in = ir["tensors"][in_t]["quant"]["scale"]
        out_t = ir["output"]["tensors"][0]
        s_out = ir["tensors"][out_t]["quant"]["scale"]
        # extract_graph's own input quantiser: round(x / s), clamp to [-127, 127]
        xq = torch.round(torch.from_numpy(x) / s_in).clamp(-127, 127).to(torch.int8).numpy()
        wd = os.path.join(a.workdir, label)
        exe = hostrun.build(gen, wd)
        yq = hostrun.batch(exe, xq.reshape(len(rows), -1), me.T * me.D, wd)
        v = {"ir": ir_dir, "gen": gen, "input_scale": s_in, "output_scale": s_out, "rows": []}
        for r, yi in zip(rows, yq):
            h = yi.astype(np.float32) * s_out
            fh = r["_float_h"]
            txt = decode(h)
            v["rows"].append({"id": r["id"], "set": r["set"], "int8": txt,
                              "encoder_cosine": float(fh @ h / (np.linalg.norm(fh) * np.linalg.norm(h) + 1e-30))})
        both = list(zip(rows, v["rows"]))
        v["wer_int8_vs_float_all"] = wer([(norm_text(r["float"]), norm_text(q["int8"])) for r, q in both])
        v["wer_int8_vs_float_eval"] = wer([(norm_text(r["float"]), norm_text(q["int8"]))
                                           for r, q in both if r["set"] == "eval"])
        v["wer_int8_vs_float_agreement"] = wer([(norm_text(r["float"]), norm_text(q["int8"]))
                                                for r, q in both if r["set"] == "agreement"])
        v["wer_int8_vs_reference_eval"] = wer([(norm_text(r["reference"]), norm_text(q["int8"]))
                                               for r, q in both if r["set"] == "eval"])
        v["mean_encoder_cosine"] = float(np.mean([q["encoder_cosine"] for q in v["rows"]]))
        v["identical_transcripts"] = int(sum(norm_text(r["float"]) == norm_text(q["int8"])
                                             for r, q in both))
        out["variants"][label] = v
        print(f"[{label}] encoder cos {v['mean_encoder_cosine']:.4f}  "
              f"WER int8 vs float: all {v['wer_int8_vs_float_all']:.3f} "
              f"(eval {v['wer_int8_vs_float_eval']:.3f}, agreement {v['wer_int8_vs_float_agreement']:.3f});  "
              f"vs reference (eval) float {out['float_wer_vs_reference_eval']:.3f} "
              f"int8 {v['wer_int8_vs_reference_eval']:.3f};  identical {v['identical_transcripts']}/{len(rows)}")
    for r in rows:
        r.pop("_float_h")
    out["utterances"] = rows
    json.dump(out, open(a.json, "w"), indent=1)
    for i, r in enumerate(rows):
        print(f"  {r['id']} [{r['set']}]\n    ref   {r['reference']}\n    float {r['float']}")
        for label, v in out["variants"].items():
            print(f"    {label:5s} {v['rows'][i]['int8']}")


if __name__ == "__main__":
    main()
