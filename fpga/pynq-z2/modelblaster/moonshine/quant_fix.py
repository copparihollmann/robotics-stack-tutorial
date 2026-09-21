#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Step 2 of the int8 fidelity work: fixes that keep the engine's contract, scored in float
simulation on dev-clean ONLY.

The engine dispatches every convolution and linear with ONE requantise multiplier and shift
and one per-tensor weight grid.  Everything between those dispatches (tanh, GroupNorm, GELU,
add, LayerNorm, softmax) is a software kernel on hart 0 and may carry per-channel scales.  So a
fix may:

  rows    give an ENGINE op's output per-channel scales a_c by dividing its weight rows and
          bias by a_c before the per-tensor weight grid is taken.  The software consumer
          reads channel c with scale a_c times the tensor scale.  a_c = (r_c / max r)^beta,
          where r_c is the channel's range under the consumer-aware rule (GELU: the negative
          tail past -8 is deleted; tanh: past +-T saturates).
  mig     migrate a software producer's per-channel range into the next ENGINE op's weight
          columns (SmoothQuant): the producer emits x_c / m_c and the columns are multiplied
          by m_c, with m_c = r_c^alpha / w_c^(1-alpha).
  calib   choose each per-tensor range by max, a percentile, or MSE-optimal clipping.
  pc      a per-channel grid on a SOFTWARE-only tensor (both its producer and its consumers
          are software kernels).
  bits    more bits on a tensor.  An engine input or output with more than 8 bits takes that
          op off the engine, and the candidate says so, so its cycles can be priced.

rows, mig and pc need software kernels with per-channel scales (per-channel LUT GELU/tanh,
GroupNorm/LayerNorm/add with per-channel input or output scales).  No RTL changes.

Every number is an ESTIMATE (fq.py).  A fix counts once the generated int8 C transcribes.

    PYTHONPATH=zephyr-chipyard-sw:$MOONSHINE_DIR/pylib python3 quant_fix.py --json quant_fix.json
"""
from __future__ import annotations

import argparse
import copy
import json
import math
import os
import sys
import time

import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import moonshine_enc as me  # noqa: E402

TANH_NODES = {"stem_conv1"}          # tensors whose only consumer is tanh
PASS = ("view", "permute", "reshape")


def node_of(module: str) -> str:
    return module.replace(".", "_")


class Model:
    def __init__(self, dev, ncal: int):
        self.dev = dev
        self.m = me.build_encoder().to(dev)
        self.gm = fq.trace(self.m).to(dev)
        self.gfed = fq.gelu_fed(self.gm)
        self.ws = fq.WeightState(self.m)
        self.nodes = {n.name: n for n in self.gm.graph.nodes}
        cc, cidx = ls.cal_set(ncal)
        self.cal = [me.input_tensor(cc.wav(i)).to(dev) for i in cidx]
        self.s0 = self.stats({}, {}, {}, {})
        import quant_diag as qd
        self.fam = qd.families(self.gm)
        # pass-through members (view/permute/reshape) carry the root's int8 codes unchanged
        self.passthrough = {k for f, mem in self.fam.items() for k in mem[1:]}

    def producer(self, module: str) -> str:
        """the node whose output feeds this module (the family root)"""
        n = self.nodes[node_of(module)]
        p = n.args[0]
        if p.op == "call_method" and p.target in PASS:
            raise ValueError(f"{module}: its input passes through {p.target}; migration not supported there")
        return p.name

    def stats(self, pre_div, post_mul, wover, bover):
        self.ws.apply({}, wover, bover)
        st = fq.Stats(self.dev)
        for x in self.cal:
            fq.FQInterp(self.gm, {}, stats=st, pre_div=pre_div, post_mul=post_mul).run(x)
        self.ws.restore()
        return st


def channel_rule(s, name, gfed, T, unit=None):
    """per-channel range under the consumer-aware rule, in the tensor's own (possibly
    scaled) units; unit[c] converts a floor given in real units"""
    u = unit if unit is not None else torch.ones_like(s["pc"])
    if name in gfed:
        return torch.maximum(s["pc_pos"], torch.minimum(s["pc_neg"], fq.GELU_NEG_FLOOR / u))
    if name in TANH_NODES and T:
        return torch.minimum(s["pc"], T / u)
    return s["pc"]


def build(M: Model, knobs: dict):
    """-> (cfg, wcfg, weight overrides, bias overrides, pre_div, post_mul, notes)"""
    s0 = M.s0.t
    wover = {k: v.clone() for k, v in M.ws.fw.items()}
    bover = {k: (v.clone() if v is not None else None) for k, v in M.ws.fb.items()}
    pre_div, post_mul, unit = {}, {}, {}
    T = knobs.get("tanh_clip")

    # rows: engine outputs with per-channel scales
    for mod, beta in knobs.get("rows", {}).items():
        n = node_of(mod)
        r = channel_rule(s0[n], n, M.gfed, T).clamp(min=1e-6)
        a = (r / r.max()) ** beta
        a = a.clamp(min=1e-4)
        w = wover[mod]
        wover[mod] = w / a.view([-1] + [1] * (w.dim() - 1))
        if bover.get(mod) is not None:
            bover[mod] = bover[mod] / a
        post_mul[n] = (a, s0[n]["cdim"])
        unit[n] = a

    # mig: software producer -> engine op columns.  Consumers sharing a producer (q/k/v after
    # one LayerNorm) share one m, sized against the largest of their column maxima.
    by_prod = {}
    for mod, alpha in knobs.get("mig", {}).items():
        by_prod.setdefault(M.producer(mod), []).append((mod, alpha))
    for p, mods in by_prod.items():
        alpha = mods[0][1]
        r = channel_rule(s0[p], p, M.gfed, T).clamp(min=1e-6)
        wc = None
        for mod, _ in mods:
            w = wover[mod]
            c = w.abs().transpose(0, 1).reshape(w.shape[1], -1).amax(dim=1)
            wc = c if wc is None else torch.maximum(wc, c)
        wc = wc.clamp(min=1e-8)
        mfac = (r ** alpha) / (wc ** (1 - alpha))
        mfac = mfac / mfac.max()
        mfac = mfac.clamp(min=knobs.get("mig_floor", 1e-4))
        for mod, _ in mods:
            w = wover[mod]
            shape = [1, -1] + [1] * (w.dim() - 2)
            wover[mod] = w * mfac.view(shape)
        pre_div[p] = (mfac, s0[p]["cdim"])

    s1 = M.stats(pre_div, post_mul, wover, bover).t

    # ranges
    calib = knobs.get("calib", "max")
    cnodes = knobs.get("calib_nodes", {})
    cfg, notes = {}, []
    bits = knobs.get("bits", {})
    pcn = knobs.get("pc", {})
    for k, s in s1.items():
        if k in M.passthrough:
            continue
        b = bits.get(k, 8)
        if k.endswith("__probs"):
            cfg[k] = ("pt", b, 1.0)
            continue
        pol = cnodes.get(k, calib)
        rule = channel_rule(s, k, M.gfed, T, unit.get(k))
        if k in pcn:
            cfg[k] = ("pc", pcn[k], rule.clamp(min=1e-8), s["cdim"])
            continue
        rmax = float(rule.max())
        if pol == "max":
            r = rmax
        elif pol.startswith("p"):
            r = min(rmax, s["hist"].pct(float(pol[1:])))
        elif pol == "mse":
            r = min(rmax, s["hist"].mse_clip(b, rmax))
        else:
            raise ValueError(pol)
        cfg[k] = ("pt", b, r)
    for k, ratio in knobs.get("dual", {}).items():
        cfg[k] = ("dual", 8, cfg[k][2], ratio)
    for k, ratios in knobs.get("multi", {}).items():
        cfg[k] = ("multi", 8, cfg[k][2], tuple(ratios))
    if knobs.get("afloat"):
        cfg = {}
    for k in knobs.get("afloat_nodes", []):
        cfg.pop(k, None)
    wcfg = {k: ("pt", 8) for k in M.ws.mods}
    for k, b in knobs.get("wbits", {}).items():
        wcfg[k] = ("pt", b) if b else None
    for k in knobs.get("wfloat", []):
        wcfg[k] = None
    for k, G in knobs.get("wgroups", {}).items():
        wcfg[k] = ("rg", 8, G)
    for k in knobs.get("wpc", []):
        wcfg[k] = ("pc", 8)
    return cfg, wcfg, wover, bover, pre_div, post_mul, notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--ncal", type=int, default=64)
    ap.add_argument("--ntune", type=int, default=256)
    ap.add_argument("--only", default=None, help="|-separated candidate names")
    ap.add_argument("--eval", default=None, help="|-separated finalists to run ONCE on test-clean")
    ap.add_argument("--greedy-from", default=None,
                    help="a candidate name: rank the remaining families by leave-one-out SQNR from it, "
                         "then restore them to float one at a time and score WER")
    ap.add_argument("--greedy-steps", type=int, default=16)
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = fq.device()
    M = Model(dev, a.ncal)
    dec = fq.Decoder(dev, 40)

    tc, tall = ls.tune_set()
    tidx = ls.even(tall, a.ntune) if a.ntune else tall
    xs = [me.input_tensor(tc.wav(i)).to(dev) for i in tidx]
    fl = [fq.FQInterp(M.gm, {}).run(x) for x in xs]
    fl_txt = dec(fl)
    refs = [tc.texts[i] for i in tidx]
    float_ref = fq.wer(refs, fl_txt)["wer"]
    print(f"[fix] tune {len(tidx)} utterances, float WER vs reference {float_ref:.4f} ({time.time() - t0:.0f} s)", flush=True)

    STEM = ["stem.conv1", "stem.conv2", "stem.conv3"]
    STEMFIX = {"tanh_clip": 3.5, "rows": {m: 1.0 for m in STEM}, "mig": {"stem.conv2": 1.0, "stem.conv3": 1.0},
               "wgroups": {m: 4 for m in STEM}}
    cands = {}
    cands["W8A8 (as extracted)"] = {}
    for pol in ("p99.99", "p99.9", "mse"):
        cands[f"calib {pol} everywhere"] = {"calib": pol}
    cands["tanh-aware clip T=3.5"] = {"tanh_clip": 3.5}
    for beta in (0.5, 0.75, 1.0):
        cands[f"stem rows beta={beta}, T=3.5"] = {"tanh_clip": 3.5, "rows": {m: beta for m in STEM}}
    for alpha in (0.25, 0.5, 0.75):
        cands[f"stem rows beta=1 + mig(gn->conv2, gelu2->conv3) alpha={alpha}"] = {
            "tanh_clip": 3.5, "rows": {m: 1.0 for m in STEM},
            "mig": {"stem.conv2": alpha, "stem.conv3": alpha}}
    cands["stem int16 activations (conv1/2/3 off the engine)"] = {
        "bits": {k: 16 for k in ("stem_conv1", "stem_tanh", "stem_groupnorm", "stem_conv2", "stem_gelu2",
                                 "stem_conv3", "stem_gelu3")}}
    STEMW = {"wfloat": STEM}
    cands["DIAG: stem weights float, activations as extracted"] = dict(STEMW)
    cands["DIAG: stem rows beta=1, T=3.5, stem weights float"] = {"tanh_clip": 3.5, "rows": {m: 1.0 for m in STEM}, **STEMW}
    cands["DIAG: stem rows beta=1 + mig alpha=0.5, stem weights float"] = {
        "tanh_clip": 3.5, "rows": {m: 1.0 for m in STEM}, "mig": {"stem.conv2": 0.5, "stem.conv3": 0.5}, **STEMW}
    cands["DIAG: stem per-channel activations (pc on conv1/2/3 out, gn, gelu2), weights W8"] = {
        "tanh_clip": 3.5, "pc": {k: 8 for k in ("stem_conv1", "stem_groupnorm", "stem_conv2", "stem_gelu2", "stem_conv3", "stem_gelu3")}}
    PCSW = {k: 8 for k in ("stem_groupnorm", "stem_gelu2", "stem_gelu3")}
    cands["DIAG2: pc on conv1/2/3 outputs only, W8"] = {"tanh_clip": 3.5, "pc": {k: 8 for k in ("stem_conv1", "stem_conv2", "stem_conv3")}}
    cands["DIAG2: pc on gn/gelu2/gelu3 only, W8"] = {"tanh_clip": 3.5, "pc": dict(PCSW)}
    cands["DIAG2: rows beta=1 + pc gn/gelu2/gelu3, stem weights float"] = {"tanh_clip": 3.5, "rows": {m: 1.0 for m in STEM}, "pc": dict(PCSW), **STEMW}
    cands["DIAG2: rows beta=1 + mig alpha=1, stem weights float"] = {"tanh_clip": 3.5, "rows": {m: 1.0 for m in STEM}, "mig": {"stem.conv2": 1.0, "stem.conv3": 1.0}, **STEMW}
    cands["DIAG2: pc all stem, stem weights float"] = {"tanh_clip": 3.5, "pc": {k: 8 for k in ("stem_conv1", "stem_groupnorm", "stem_conv2", "stem_gelu2", "stem_conv3", "stem_gelu3")}, **STEMW}
    for beta in (0.25, 0.5, 0.75, 1.0):
        for alpha in (0.25, 0.5, 0.75, 1.0):
            cands[f"SWEEP: rows beta={beta} + mig alpha={alpha}, W8"] = {
                "tanh_clip": 3.5, "rows": {m: beta for m in STEM}, "mig": {"stem.conv2": alpha, "stem.conv3": alpha}}
    for G in (2, 4, 8, 16):
        for beta, alpha in ((1.0, 1.0), (0.75, 0.75), (0.5, 0.5)):
            cands[f"SWEEP: rows beta={beta} + mig alpha={alpha}, stem W8 in {G} row groups"] = {
                "tanh_clip": 3.5, "rows": {m: beta for m in STEM}, "mig": {"stem.conv2": alpha, "stem.conv3": alpha},
                "wgroups": {m: G for m in STEM}}
    cands["SWEEP: stem weights per-row (per-channel requant), rows=1 mig=1"] = {
        "tanh_clip": 3.5, "rows": {m: 1.0 for m in STEM}, "mig": {"stem.conv2": 1.0, "stem.conv3": 1.0},
        "wbits": {}, "wpc": STEM}
    cands["STEMFIX: rows=1 mig=1 T=3.5, stem W8 in 4 row groups"] = dict(STEMFIX)
    L = range(me.LAYERS)
    ADDS = ["add"] + [f"add_{i}" for i in range(1, 2 * me.LAYERS)]
    RESW = [f"layers.{i}.self_attn.o_proj" for i in L] + [f"layers.{i}.mlp.fc2" for i in L]

    def resid(G=4, beta=1.0, x=None, gelu3=True):
        k = copy.deepcopy(STEMFIX)
        k["pc"] = {a_: 8 for a_ in ADDS}
        if gelu3:
            k["pc"]["stem_gelu3"] = 8
        k["rows"].update({m: beta for m in RESW})
        if G:
            k["wgroups"].update({m: G for m in RESW})
        if x:
            k["calib_nodes"] = {"x": x}
        return k
    cands["RESID: stemfix + residual adds per-channel + o_proj/fc2 rows, 4 row groups"] = resid()
    cands["RESID: ... 1 row group (per-tensor W8)"] = resid(G=0)
    cands["RESID: ... 4 row groups, beta=0.5"] = resid(beta=0.5)
    cands["RESID: ... 4 row groups, input x p99.99"] = resid(x="p99.99")
    cands["RESID: ... 4 row groups, input x p99.9"] = resid(x="p99.9")
    cands["RESID: ... 4 row groups, input x mse"] = resid(x="mse")
    best = resid(x="p99.9")
    ALLW = list(M.ws.mods)
    LIN = [k for k in ALLW if not k.startswith("stem.")]
    k_ = copy.deepcopy(best); k_["wfloat"] = ALLW
    cands["WDIAG: best, all weights float"] = k_
    k_ = copy.deepcopy(best); k_["wfloat"] = LIN
    cands["WDIAG: best, transformer weights float"] = k_
    k_ = copy.deepcopy(best); k_["wpc"] = ALLW; k_["wgroups"] = {}
    cands["WDIAG: best, all weights per-row (per-channel requant)"] = k_
    for G in (2, 4, 8):
        k_ = copy.deepcopy(best); k_["wgroups"] = {m: G for m in ALLW}
        cands[f"WDIAG: best, all weights in {G} row groups"] = k_
    cands["WDIAG: activations float, weights W8 per-tensor (reference)"] = {"afloat": True}
    for pol in ("p99.99", "p99.9", "mse"):
        k_ = copy.deepcopy(best); k_["calib_nodes"].update({"stem_conv2": pol, "stem_gelu2": pol})
        cands[f"STEP3: best + stem conv2/gelu2 calib {pol}"] = k_
    for nodes, lab in ((["x", "stem_conv2", "stem_gelu2"], "x, conv2 out, gelu2 out"),
                       (["x", "stem_conv1", "stem_tanh", "stem_groupnorm", "stem_conv2", "stem_gelu2", "stem_conv3", "stem_gelu3"], "all stem")):
        k_ = copy.deepcopy(best); k_["bits"] = {n: 16 for n in nodes}
        cands[f"STEP3: best + int16 on {lab}"] = k_
        k_ = copy.deepcopy(best); k_["bits"] = {n: 16 for n in nodes}
        k_["rows"] = {m: v for m, v in k_["rows"].items() if not m.startswith("stem.")}
        k_["mig"] = {}; k_["wgroups"] = {m: v for m, v in k_["wgroups"].items() if not m.startswith("stem.")}
        cands[f"STEP3: best + int16 on {lab}, no stem migration, stem W8 per-tensor"] = k_
    def nostem(k_):
        k_["rows"] = {m: v for m, v in k_["rows"].items() if not m.startswith("stem.")}
        k_["mig"] = {m: v for m, v in k_["mig"].items() if not m.startswith("stem.")}
        k_["wgroups"] = {m: v for m, v in k_["wgroups"].items() if not m.startswith("stem.")}
        k_.pop("tanh_clip", None)
        return k_
    STEM_IN, STEM_OUT, STEM_SW = ["x", "stem_groupnorm", "stem_gelu2"], ["stem_conv1", "stem_conv2", "stem_conv3"], ["stem_tanh", "stem_gelu3"]
    for ratio in (8, 16, 32, 64, 128):
        k_ = nostem(copy.deepcopy(best))
        k_["bits"] = {n: 16 for n in STEM_IN + STEM_SW}
        k_["dual"] = {n: ratio for n in STEM_OUT}
        cands[f"SPLIT: stem inputs int16 (hi/lo dispatches), outputs dual-range x{ratio}, software int16"] = k_
    k_ = nostem(copy.deepcopy(best)); k_["bits"] = {n: 16 for n in STEM_IN + STEM_SW}
    cands["SPLIT: stem inputs int16, outputs int8 per-tensor, software int16"] = k_
    k_ = nostem(copy.deepcopy(best)); k_["bits"] = {n: 16 for n in STEM_OUT + STEM_SW}
    cands["SPLIT: stem outputs int16, inputs int8 per-tensor, software int16"] = k_
    STEM_ALL = STEM_IN + STEM_OUT + STEM_SW
    F1 = {"bits": {n: 16 for n in STEM_ALL}}
    cands["FACT F1: stem int16 (software convs), transformer as extracted"] = F1
    F2 = copy.deepcopy(F1); F2["pc"] = {a_: 8 for a_ in ADDS}
    cands["FACT F2: F1 + residual adds per-channel"] = F2
    F3 = copy.deepcopy(F2); F3["rows"] = {m: 1.0 for m in RESW}
    cands["FACT F3: F2 + o_proj/fc2 rows, per-tensor W8"] = F3
    F4 = copy.deepcopy(F3); F4["wgroups"] = {m: 4 for m in RESW}
    cands["FACT F4: F3 in 4 row groups"] = F4
    F5 = copy.deepcopy(F1); F5["pc"] = {"add_11": 8}; F5["rows"] = {"layers.5.mlp.fc2": 1.0}; F5["wgroups"] = {"layers.5.mlp.fc2": 4}
    cands["FACT F5: F1 + add_11 per-channel + layer-5 fc2 rows in 4 groups"] = F5
    S64 = nostem(copy.deepcopy(best)); S64["bits"] = {n: 16 for n in STEM_IN + STEM_SW}; S64["dual"] = {n: 64 for n in STEM_OUT}
    cands["FACT S1: split stem x64 + residual fixes (4 groups)"] = S64
    S2 = copy.deepcopy(S64); S2["rows"] = {}; S2["wgroups"] = {}
    cands["FACT S2: split stem x64 + residual adds per-channel only"] = S2
    S3 = copy.deepcopy(S2); S3["pc"] = {}
    cands["FACT S3: split stem x64, transformer as extracted"] = S3
    for rs in ((1, 16, 256), (1, 8, 64), (1, 32, 1024)):
        k_ = copy.deepcopy(S64); k_.pop("dual"); k_["multi"] = {n: rs for n in STEM_OUT}
        cands[f"FACT S4: split stem, outputs {len(rs)}-range {rs} + residual fixes (4 groups)"] = k_
    k_ = copy.deepcopy(S64); k_["mig"].update({f"layers.{i}.self_attn.{p}_proj": 0.25 for i in L for p in "qkv"})
    k_["mig"].update({f"layers.{i}.mlp.fc1": 0.25 for i in L}); k_["mig"].update({f"layers.{i}.mlp.fc2": 0.25 for i in L})
    cands["FACT S5: S1 + transformer mig alpha=0.25"] = k_
    S4 = copy.deepcopy(S64); S4.pop("dual"); S4["multi"] = {n: (1, 16, 256) for n in STEM_OUT}
    for lab, base_ in (("F3", F3), ("S4", S4)):
        k_ = copy.deepcopy(base_); k_["wgroups"] = {m: 4 for m in ALLW}
        cands[f"FACT W: {lab} + ALL weights in 4 row groups (dispatch splits)"] = k_
        k_ = copy.deepcopy(base_); k_["wgroups"] = {}; k_["wpc"] = ALLW
        cands[f"FACT W: {lab} + ALL weights per-row (RTL per-channel requant)"] = k_
    S4W = copy.deepcopy(S4); S4W["wgroups"] = {m: 4 for m in ALLW}
    cands["ABL S4W: the finalist"] = S4W
    k_ = copy.deepcopy(S4W); k_["rows"] = {}
    cands["ABL S4W - o_proj/fc2 rows"] = k_
    k_ = copy.deepcopy(S4W); k_["pc"] = {}
    cands["ABL S4W - residual adds per-channel"] = k_
    k_ = copy.deepcopy(S4W); k_["rows"] = {}; k_["pc"] = {}
    cands["ABL S4W - rows - adds per-channel"] = k_
    k_ = copy.deepcopy(S4W); k_["multi"] = {n: (1, 64) for n in STEM_OUT}
    cands["ABL S4W with 2-range stem outputs (1, 64)"] = k_
    k_ = copy.deepcopy(S4W); k_["wgroups"] = {m: 2 for m in ALLW}
    cands["ABL S4W with 2 row groups"] = k_
    k_ = copy.deepcopy(S4W); k_["wgroups"] = {m: 4 for m in ALLW if m.startswith("stem.")}
    cands["ABL S4W with row groups on the stem only"] = k_
    k_ = copy.deepcopy(S4W); k_["wgroups"] = {m: 4 for m in ALLW if not m.startswith("stem.")}
    cands["ABL S4W with row groups on the transformer only"] = k_
    k_ = copy.deepcopy(S4W); k_["bits"] = {n: 16 for n in STEM_SW + ["x"]}
    cands["ABL S4W with GN/GELU2 (conv2/conv3 inputs) int8, no hi/lo split"] = k_
    SS = copy.deepcopy(S4W); SS["rows"] = {}; SS["multi"] = {n: (1, 64) for n in STEM_OUT}
    SS["wgroups"] = {m: 4 for m in STEM}
    cands["FINAL S*1: split stem (1,64), stem weights 4 row groups, residual adds per-channel"] = SS
    k_ = copy.deepcopy(SS); k_["wgroups"] = {m: 2 for m in STEM}
    cands["FINAL S*2: S*1 with 2 stem row groups"] = k_
    k_ = copy.deepcopy(SS); k_["wgroups"] = {}
    cands["FINAL S*3: S*1 with per-tensor stem weights"] = k_
    k_ = copy.deepcopy(SS); k_["multi"] = {n: (1, 32) for n in STEM_OUT}
    cands["FINAL S*4: S*1 with (1,32)"] = k_
    k_ = copy.deepcopy(SS); k_["multi"] = {n: (1, 16) for n in STEM_OUT}
    cands["FINAL S*5: S*1 with (1,16)"] = k_
    for G in (0, 2, 4):
        for rs in ((1, 64), (1, 16, 256)):
            k_ = copy.deepcopy(SS); k_["rows"] = {m: 1.0 for m in RESW}
            k_["wgroups"] = {m: G for m in STEM} if G else {}
            k_["multi"] = {n: rs for n in STEM_OUT}
            cands[f"FINAL R: split stem {rs}, stem weights {G or 1} group(s), adds per-channel + o_proj/fc2 rows"] = k_
    # ---- co-design candidates: what a width-selectable engine (int16 x int8 MACs, per-channel
    # requant) makes cheap, and narrower int16 mixes.  pr = per-row weights (per-channel requant).
    def cd(label, bits_nodes=(), pc_adds=False, rows=False, pr=False, groups=None, all16=False, adds16=False):
        k_ = {}
        if all16:
            k_["bits"] = {n: 16 for n in M.s0.t if not n.endswith("__probs")}
        else:
            k_["bits"] = {n: 16 for n in bits_nodes}
        if adds16:
            k_["bits"].update({a_: 16 for a_ in ADDS})
        if pc_adds:
            k_["pc"] = {a_: 8 for a_ in ADDS}
        if rows:
            k_["rows"] = {m: 1.0 for m in RESW}
        if pr:
            k_["wpc"] = ALLW
        if groups:
            k_["wgroups"] = {m: groups for m in ALLW}
        cands["CD " + label] = k_
    cd("N1: int16 conv2-out + gelu2 only", ["stem_conv2", "stem_gelu2"])
    cd("N1PR: N1 + per-row weights", ["stem_conv2", "stem_gelu2"], pr=True)
    cd("N2: int16 x..gelu2 (conv1 in/out, conv2 in/out, conv3 in)", STEM_ALL[:0] + ["x", "stem_conv1", "stem_tanh", "stem_groupnorm", "stem_conv2", "stem_gelu2"])
    cd("F1PR: stem int16 + per-row weights", STEM_ALL, pr=True)
    cd("F2PR: stem int16 + adds per-channel + per-row", STEM_ALL, pc_adds=True, pr=True)
    cd("F3PR: stem int16 + adds per-channel + rows + per-row", STEM_ALL, pc_adds=True, rows=True, pr=True)
    cd("A16: stem int16 + residual adds int16 (per-tensor)", STEM_ALL, adds16=True)
    cd("A16PR: stem int16 + residual adds int16 + per-row", STEM_ALL, adds16=True, pr=True)
    cd("ALL16: every activation int16, W8 per-tensor", all16=True)
    cd("ALL16PR: every activation int16, per-row weights", all16=True, pr=True)
    QKV = {f"layers.{i}.self_attn.{p}_proj": None for i in L for p in "qkv"}
    FC1 = {f"layers.{i}.mlp.fc1": None for i in L}
    FC2 = {f"layers.{i}.mlp.fc2": None for i in L}
    for alpha in (0.25, 0.5, 0.75):
        k_ = copy.deepcopy(best)
        k_["mig"].update({m: alpha for m in list(QKV) + list(FC1) + list(FC2)})
        cands[f"STEP3: best + transformer mig (LN->qkv, LN->fc1, gelu->fc2) alpha={alpha}"] = k_
    STEMN = ["x", "stem_conv1", "stem_tanh", "stem_groupnorm", "stem_conv2", "stem_gelu2", "stem_conv3", "stem_gelu3"]
    for label, nodes in (("all stem activations float", STEMN), ("stem float except input x", STEMN[1:]),
                         ("only input x float", ["x"]), ("x + conv1 out float", ["x", "stem_conv1"]),
                         ("x, conv1, tanh, gn float", STEMN[:4]), ("conv2, gelu2, conv3, gelu3 float", STEMN[4:])):
        k_ = copy.deepcopy(best); k_["afloat_nodes"] = nodes
        cands[f"ADIAG: best, {label}"] = k_
    for b in (10, 12, 16):
        k_ = copy.deepcopy(best); k_["bits"] = {"x": b}
        cands[f"ADIAG: best, input x int{b}"] = k_
    cands["WDIAG: activations float, weights per-row"] = {"afloat": True, "wpc": ALLW}
    cands["WDIAG: activations float, weights in 4 row groups"] = {"afloat": True, "wgroups": {m: 4 for m in ALLW}}
    if a.only:
        keep = a.only.split("|")
        cands = {k: v for k, v in cands.items() if any(k == x or (x.endswith("*") and k.startswith(x[:-1])) for x in keep)}

    results = {}

    def evaluate(name, knobs, corpus, idx, inputs, float_out, float_txt):
        cfg, wcfg, wover, bover, pre_div, post_mul, notes = build(M, knobs)
        M.ws.apply(wcfg, wover, bover)
        outs = [fq.FQInterp(M.gm, cfg, pre_div=pre_div, post_mul=post_mul).run(x) for x in inputs]
        M.ws.restore()
        txt = dec(outs)
        r = {"knobs": knobs, "sqnr_db": fq.sqnr_db(float_out, outs), "cosine": fq.cosine(float_out, outs),
             "wer_vs_float": fq.wer(float_txt, txt), "wer_vs_reference": fq.wer([corpus.texts[i] for i in idx], txt),
             "notes": notes}
        return r, txt

    if a.greedy_from:
        import quant_diag as qd
        base_knobs = cands[a.greedy_from] if a.greedy_from in cands else json.loads(a.greedy_from)
        cfg, wcfg, wover, bover, pre_div, post_mul, _ = build(M, base_knobs)
        fam = qd.families(M.gm)
        sw = xs[:64]
        flsw = fl[:64]

        def sq(c):
            M.ws.apply(wcfg, wover, bover)
            o = [fq.FQInterp(M.gm, c, pre_div=pre_div, post_mul=post_mul).run(x) for x in sw]
            M.ws.restore()
            return fq.sqnr_db(flsw, o)

        base_sq = sq(cfg)
        rank = []
        for f, members in fam.items():
            c2 = {k: v for k, v in cfg.items() if k not in members}
            if len(c2) == len(cfg):
                continue
            rank.append((sq(c2) - base_sq, f))
        rank.sort(reverse=True)
        print(f"[greedy] base SQNR {base_sq:.2f} dB; top LOO gains: " +
              ", ".join(f"{f} +{g:.2f}" for g, f in rank[:12]), flush=True)
        steps = []
        c2 = dict(cfg)
        restored = []

        def wer_of(c):
            M.ws.apply(wcfg, wover, bover)
            o = [fq.FQInterp(M.gm, c, pre_div=pre_div, post_mul=post_mul).run(x) for x in xs]
            M.ws.restore()
            txt = dec(o)
            return fq.sqnr_db(fl, o), fq.wer(fl_txt, txt)["wer"], fq.wer(refs, txt)["wer"]

        s_, wf, wr = wer_of(c2)
        steps.append({"restored": [], "sqnr_db": s_, "wer_vs_float": wf, "wer_vs_reference": wr})
        print(f"[greedy] base: SQNR {s_:.2f}  WER vs float {wf:.4f}  vs ref {wr:.4f}", flush=True)
        for g, f in rank[:a.greedy_steps]:
            for k in fam[f]:
                c2.pop(k, None)
            restored.append(f)
            s_, wf, wr = wer_of(c2)
            steps.append({"restored": list(restored), "added": f, "loo_gain_db": g, "sqnr_db": s_,
                          "wer_vs_float": wf, "wer_vs_reference": wr})
            print(f"[greedy] +{f:40s} LOO +{g:5.2f} dB -> SQNR {s_:.2f}  WER vs float {wf:.4f}  vs ref {wr:.4f} "
                  f"({time.time() - t0:.0f} s)", flush=True)
        json.dump({"what": "greedy float restore from a fixed base; FLOAT SIMULATION (estimates), dev-clean",
                   "base": base_knobs, "tune_utterances": len(tidx), "float_wer_vs_reference": float_ref,
                   "loo_rank": [[f, g] for g, f in rank], "steps": steps},
                  open(a.json, "w"), indent=1, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
        print(f"wrote {a.json}")
        return

    if a.eval:
        ec, eidx = ls.eval_set()
        exs = [me.input_tensor(ec.wav(i)).to(dev) for i in eidx]
        efl = [fq.FQInterp(M.gm, {}).run(x) for x in exs]
        efl_txt = dec(efl)
        erefs = [ec.texts[i] for i in eidx]
        eout = {"what": "FINALISTS on test-clean <=4 s, run once each; FLOAT SIMULATION (estimates)",
                "eval": {"utterances": len(eidx), "speakers": len({ec.speakers[i] for i in eidx}),
                         "words": fq.wer(erefs, erefs)["words"]},
                "float": {"wer_vs_reference": fq.wer(erefs, efl_txt)}, "finalists": {}}
        base_names = ["W8A8 (as extracted)"]
        for name in base_names + a.eval.split("|"):
            r, txt = evaluate(name, cands[name], ec, eidx, exs, efl, efl_txt)
            ex = []
            for j, i in enumerate(eidx):
                if fq.norm_text(txt[j]) != fq.norm_text(efl_txt[j]):
                    ex.append({"id": ec.ids[i], "reference": ec.texts[i], "float": efl_txt[j], "int8": txt[j]})
            r["differs_from_float"] = len(ex)
            r["examples_differing"] = ex[:: max(1, len(ex) // 12)][:12]
            r["examples_agreeing"] = [{"id": ec.ids[i], "reference": ec.texts[i], "float": efl_txt[j], "int8": txt[j]}
                                      for j, i in enumerate(eidx)
                                      if fq.norm_text(txt[j]) == fq.norm_text(efl_txt[j])][:4]
            eout["finalists"][name] = r
            print(f"[eval] {name:70s} SQNR {r['sqnr_db']:6.2f}  WER vs float {r['wer_vs_float']['wer']:.4f}  "
                  f"vs ref {r['wer_vs_reference']['wer']:.4f}  (float {eout['float']['wer_vs_reference']['wer']:.4f})", flush=True)
        json.dump(eout, open(a.json, "w"), indent=1, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
        print(f"wrote {a.json}")
        return

    for name, knobs in cands.items():
        r, _ = evaluate(name, knobs, tc, tidx, xs, fl, fl_txt)
        results[name] = r
        print(f"[fix] {name:70s} SQNR {r['sqnr_db']:6.2f} dB  WER vs float {r['wer_vs_float']['wer']:.4f}  "
              f"vs ref {r['wer_vs_reference']['wer']:.4f}  ({time.time() - t0:.0f} s)", flush=True)

    out = {"what": "step 2 candidates, FLOAT SIMULATION (estimates), selected on dev-clean only",
           "tune": {"utterances": len(tidx), "speakers": len({tc.speakers[i] for i in tidx}),
                    "float_wer_vs_reference": float_ref},
           "calibration_windows": a.ncal, "candidates": results}
    json.dump(out, open(a.json, "w"), indent=1, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
    print(f"wrote {a.json} ({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
