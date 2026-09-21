#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""DOES THE DECODER LOWER TO q16?  Host-only, no board.

WHY.  The q16 lowering produces `layernorm_pc_s8` -- the PRE-DERIVED form, whose affine table
arrives already quantised.  Lab B44/B41 measured the difference by subtraction: 438,437 against
183,579 cycles per dispatch on the same lane, same silicon, same shape, so the derivation is
**254,857 cycles = 885 per channel**.  On the DECODER, where layernorm_s8 is 456 dispatches of
M=1 (288 elements each), that derivation alone is 885 c/el against a measured control of 178.98
-- 4.9x slower -- and it cannot be cached because 451 of the 456 dispatches carry distinct
(scale_in, scale_out, eps) triples.  So the decoder does not want a cheaper derivation; it wants
the derivation GONE, which is what lowering does.

WHY IT WAS WORTH TESTING AT ALL.  The recorded q16 blocker is the ENCODER's stem groupnorm
("groupnorm lowering needs int16 in and out"), and everyone inherited it as *the* q16 blocker.
**The decoder has no stem and no groupnorm** -- its inventory is add/cat2/layernorm/linear/
matmul/mul/permute/rope/silu/softmax/view -- so the blocker's scope had never been tested.

TWO PIECES OF PLUMBING THIS HAD TO SOLVE, and they are the reusable part:
  * the decoder is NOT a registered ModelBlaster model -- there is no modelblaster.models.
    moonshine_dec -- so extract_q16's CLI cannot reach it.  model_dec_build.py passes the module
    object to extract_int8 directly, and extract_q16's FUNCTION takes the same shape, so it is
    called as a function here rather than through --model.
  * there is no decoder q16 PLAN.  This synthesises one from the decoder's own int8 calibration
    (out/decint8/ir), which asks exactly the question at issue -- the same quantisation
    decisions, lowered to the q16 integer form -- rather than introducing a new calibration
    whose effect could not be separated from the lowering.
"""

import json, os, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
# repo root: .../fpga/pynq-z2/modelblaster/moonshine -> up four
ROOT = os.environ.get("IISWC_ROOT") or os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, HERE)
import numpy as np, torch
import moonshine_dec as md
import model_vocab as mv
from modelblaster.pipeline import extract_q16 as xq

IR = json.load(open(os.path.join(ROOT, "out/decint8/ir/graph.json")))
# SYNTHESISE THE PLAN FROM THE DECODER'S OWN int8 CALIBRATION.  The plan chooses per-tensor vs
# per-channel and bit width; using the ranges already calibrated for this graph asks exactly the
# question at issue -- "the same quantisation decisions, lowered to the q16 integer form" --
# rather than introducing a new calibration whose effect could not be separated from the lowering.
T = IR["tensors"]
tensors = {}
for n, t in T.items():
    s = (t.get("quant") or {}).get("scale")
    if isinstance(s, (int, float)) and s > 0:
        _b = 15 if t.get("dtype") == "i16" else 7
        tensors[n] = {"kind": "pt", "bits": _b + 1, "range": float(s) * float((1 << _b) - 1)}
plan = {"what": "synthesised from out/decint8/ir ranges", "candidate": "DEC_from_int8",
        "tensors": tensors, "weights": {}, "rows": {}, "passthrough": []}
print("[probe] plan: %d tensors from the decoder's own int8 calibration" % len(tensors))

n_steps = int(os.environ.get("N_STEPS", "24"))
hf, tok = mv.load_hf("cpu")
sd = hf.state_dict()
um = md.load_unrolled(md.make_unrolled(n_steps), sd)
print("[probe] unrolled decoder built, %d steps" % n_steps)
# ONE calibration sample, built exactly as model_dec_build.py builds them: the unrolled graph
# takes every h as an input, so the sample is [*hs, *kx, *vx] from a FLOAT rollout.  One is
# enough for shape propagation; the plan carries the ranges, so no calibration SET is needed.
import librispeech_sets as ls, moonshine_enc as me
from model_dec_build import float_rollout
emb = sd["model.decoder.embed_tokens.weight"]
start, eos = hf.config.decoder_start_token_id, hf.config.eos_token_id
pro = md.load_prologue(md.MbCrossPrologue().eval(), sd)
c, idx = ls.cal_set(1)
w = np.asarray(c.wav(idx[0]), dtype=np.float32)
w = w[(len(w)-me.N_SAMPLES)//2:(len(w)-me.N_SAMPLES)//2+me.N_SAMPLES] if len(w) > me.N_SAMPLES \
    else np.pad(w, (0, me.N_SAMPLES - len(w)))
with torch.no_grad():
    enc = hf.model.encoder(torch.from_numpy(w[None, :])).last_hidden_state
    hs, kx, vx, toks = float_rollout(um, emb, enc, pro, start, eos, n_steps)
sample = [*hs, *kx, *vx]
print("[probe] one calibration sample built: %d tensors, %d tokens" % (len(sample), len(toks)))
out = os.path.join(ROOT, "out/dec_q16_probe")
os.makedirs(out, exist_ok=True)
try:
    xq.extract_q16(um, sample, "moonshine_dec", out, plan, "pext_nl")
except Exception as e:
    print("[probe] LOWERING STOPPED: %s: %s" % (type(e).__name__, e))
    sys.exit(3)
g = json.load(open(os.path.join(out, "graph.json")))
c = collections.Counter(o["op"] for o in g["ops"])
print("[probe] LOWERED.  op inventory:")
for k, v in sorted(c.items()):
    print("    %-20s %d" % (k, v))
