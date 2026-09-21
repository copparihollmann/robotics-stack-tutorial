#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Where Moonshine's int8 encoder breaks: per-tensor statistics, SQNR and sensitivity.

Step 1 of the fidelity work (ROCC_DECOUPLED.md section 8.12).  A FLOAT SIMULATION (fq.py) of
the grids ModelBlaster's int8 IR puts on every tensor, run on the multi-speaker LibriSpeech
sets of librispeech_sets.py.  It answers three questions, each with a number per tensor:

  1. How badly does a per-tensor int8 grid fit this tensor?  Range statistics over
     calibration (max, p99.9, p99.99, per-channel max: median, top, how many channels sit
     8x or more above the median) and the tensor's own SQNR on its MB grid.
  2. How much does quantising ONLY this tensor hurt the encoder output?  (isolated)
  3. How much does leaving ONLY this tensor float repair the fully quantised encoder?
     (leave-one-out, from W8A8)

A "tensor" here is a FAMILY: a producer and the view/permute/reshape chain that carries
its values unchanged (MB gives them the same scale, so they cannot be restored apart).
The families then roll up into GROUPS (the residual stream, post-LayerNorm activations,
attention probabilities, ...), and the groups are scored by WER with HF's float decoder.

Every WER here is an ESTIMATE of a kernel set with those grids.  Measured WER comes from the
generated int8 C (host_fidelity.py).

    PYTHONPATH=zephyr-chipyard-sw:$MOONSHINE_DIR/pylib python3 quant_diag.py --json quant_diag.json
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import os
import re
import sys
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import moonshine_enc as me  # noqa: E402

PASS = ("view", "permute", "reshape")


def families(gm) -> dict:
    """producer name -> [producer, pass-through descendants...]"""
    fam, root = {}, {}
    for n in gm.graph.nodes:
        if n.op == "output":
            continue
        if n.op == "call_method" and n.target in PASS:
            r = root[n.args[0].name]
            root[n.name] = r
            fam[r].append(n.name)
        else:
            root[n.name] = n.name
            fam[n.name] = [n.name]
            if fq.is_sdpa(n):
                fam[n.name] += []            # its internals are their own families below
    for n in gm.graph.nodes:
        if fq.is_sdpa(n):
            fam[f"{n.name}__scores"] = [f"{n.name}__scores"]
            fam[f"{n.name}__probs"] = [f"{n.name}__probs"]
    return fam


def layer_of(gm, name: str):
    m = re.match(r"layers_(\d+)_", name)
    if m:
        return int(m.group(1))
    return None


def groups(gm, fam: dict) -> dict:
    """family -> group label, by what the family IS in a pre-LN transformer."""
    g = {}
    adds = [n.name for n in gm.graph.nodes if n.op == "call_function" and n.target.__name__ == "add"]
    sdpas = [n.name for n in gm.graph.nodes if fq.is_sdpa(n)]
    for f in fam:
        if f == "x":
            g[f] = "input"
        elif f.startswith("stem_"):
            g[f] = "stem." + f[len("stem_"):]
        elif f in adds:
            g[f] = "residual.after_attn" if adds.index(f) % 2 == 0 else "residual.after_mlp"
        elif f.endswith("input_layernorm"):
            g[f] = "ln.pre_attn (q/k/v input)"
        elif f.endswith("post_attention_layernorm"):
            g[f] = "ln.pre_mlp (fc1 input)"
        elif f.endswith(("q_proj", "k_proj")):
            g[f] = "attn.q/k proj out"
        elif f.endswith("v_proj"):
            g[f] = "attn.v proj out"
        elif f.endswith(("rope_q", "rope_k")):
            g[f] = "attn.q/k after rope"
        elif f.endswith("__scores"):
            g[f] = "attn.scores"
        elif f.endswith("__probs"):
            g[f] = "attn.probs"
        elif f in sdpas:
            g[f] = "attn.out (o_proj input)"
        elif f.endswith("o_proj"):
            g[f] = "attn.o_proj out"
        elif f.endswith("mlp_fc1"):
            g[f] = "mlp.fc1 out"
        elif f.endswith("mlp_act"):
            g[f] = "mlp.gelu out (fc2 input)"
        elif f.endswith("mlp_fc2"):
            g[f] = "mlp.fc2 out"
        elif f == "layer_norm":
            g[f] = "ln.final"
        else:
            g[f] = "other"
    return g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--ncal", type=int, default=64)
    ap.add_argument("--nsweep", type=int, default=64, help="dev-clean utterances for the per-tensor sweeps")
    ap.add_argument("--ntune", type=int, default=0, help="dev-clean utterances for group WER (0 = all)")
    ap.add_argument("--neval", type=int, default=0, help="test-clean utterances for the headline WER (0 = all)")
    ap.add_argument("--max-new-tokens", type=int, default=40)
    a = ap.parse_args()
    t0 = time.time()
    dev = fq.device()
    torch.set_grad_enabled(False)

    m = me.build_encoder().to(dev)
    gm = fq.trace(m).to(dev)
    gfed = fq.gelu_fed(gm)
    fam = families(gm)
    grp = groups(gm, fam)
    ws = fq.WeightState(m)

    # ---- calibration ---------------------------------------------------------------------
    cc, cidx = ls.cal_set(a.ncal)
    st = fq.Stats(dev)
    for i in cidx:
        fq.FQInterp(gm, {}, stats=st).run(me.input_tensor(cc.wav(i)).to(dev))
    rng = fq.mb_ranges(st, gfed)
    print(f"[diag] calibrated {len(cidx)} windows, {len(st.t)} tensors ({time.time() - t0:.0f} s)", flush=True)

    def a8(names=None):
        names = st.t.keys() if names is None else names
        return {k: ("pt", 8, rng[k]) for k in names}

    W8 = {k: ("pt", 8) for k in ws.mods}
    A8 = a8()

    # ---- sweep set and float reference ---------------------------------------------------
    tc, tidx_all = ls.tune_set()
    sweep = ls.even(tidx_all, a.nsweep)
    xs = [me.input_tensor(tc.wav(i)).to(dev) for i in sweep]
    ws.restore()
    ref = [fq.FQInterp(gm, {}).run(x) for x in xs]

    def run(cfg, wcfg, inputs=xs, capture=None):
        ws.apply(wcfg)
        outs = []
        for x in inputs:
            cap = {} if capture is not None else None
            outs.append(fq.FQInterp(gm, cfg, capture=cap).run(x))
            if capture is not None:
                capture.append(cap)
        ws.restore()
        return outs

    def score(cfg, wcfg):
        o = run(cfg, wcfg)
        return {"sqnr_db": fq.sqnr_db(ref, o), "cosine": fq.cosine(ref, o)}

    base = {"float": {"sqnr_db": float("inf"), "cosine": 1.0}, "W8": score({}, W8), "A8": score(A8, {}),
            "W8A8": score(A8, W8)}
    print("[diag] baselines", json.dumps(base), flush=True)

    # ---- per-tensor statistics and self-SQNR on the MB grid ------------------------------
    caps = []
    run({}, {}, inputs=xs[:16], capture=caps)
    tensors = {}
    for f, members in fam.items():
        k = members[0]
        if k not in st.t:
            continue
        s = st.t[k]
        pc = s["pc"]
        med = float(pc.median())
        top = float(pc.max())
        # self SQNR of the tensor on its own MB grid, over 16 sweep utterances (float model)
        num = den = 0.0
        for cap in caps:
            x = cap[k].double()
            q = fq.fq_tensor(cap[k], ("pt", 8, rng[k])).double()
            num += float((x ** 2).sum())
            den += float(((x - q) ** 2).sum())
        order = torch.argsort(pc, descending=True)[:8].tolist()
        tensors[f] = {
            "group": grp[f], "layer": layer_of(gm, f), "members": members, "shape": s["shape"],
            "channel_dim": s["cdim"], "mb_range": rng[k], "max_abs": s["max_abs"],
            "rms": math.sqrt(s["sq"] / max(s["n"], 1)),
            "p99.9": s["hist"].pct(99.9), "p99.99": s["hist"].pct(99.99),
            "pc_max_median": med, "pc_max_top": top, "pc_top_over_median": top / max(med, 1e-12),
            "pc_channels_over_8x_median": int((pc > 8 * med).sum()),
            "pc_top_channels": order, "pc_top_values": [float(pc[j]) for j in order],
            "self_sqnr_db": 10 * math.log10(num / max(den, 1e-30)),
        }
    print(f"[diag] statistics for {len(tensors)} families ({time.time() - t0:.0f} s)", flush=True)

    # ---- sensitivity: isolated and leave-one-out, per family -----------------------------
    for f, d in tensors.items():
        members = [k for k in fam[f] if k in st.t]
        d["iso_A8"] = score(a8(members), {})
        loo = dict(A8)
        for k in members:
            loo.pop(k, None)
        d["loo_W8A8"] = score(loo, W8)
    print(f"[diag] activation sweeps done ({time.time() - t0:.0f} s)", flush=True)
    weights = {}
    for k in ws.mods:
        loo = dict(W8)
        loo.pop(k)
        weights[k] = {"iso_W8": score({}, {k: ("pt", 8)}), "loo_W8A8": score(A8, loo),
                      "per_row_max_top_over_median": None}
        w = ws.fw[k]
        rows = w.abs().reshape(w.shape[0], -1).amax(dim=1)
        weights[k]["per_row_max_top_over_median"] = float(rows.max() / rows.median())
        weights[k]["max_abs"] = float(w.abs().max())
    print(f"[diag] weight sweeps done ({time.time() - t0:.0f} s)", flush=True)

    # ---- groups: per-group SQNR on the sweep set, WER on the full tune set -----------------
    gnames = sorted(set(d["group"] for d in tensors.values()))

    def members_of(label):
        return [k for f, d in tensors.items() if d["group"] == label for k in fam[f] if k in st.t]

    group_rows = {}
    for gl in gnames:
        mem = members_of(gl)
        loo = {k: v for k, v in A8.items() if k not in mem}
        group_rows[gl] = {"families": sum(1 for d in tensors.values() if d["group"] == gl),
                          "iso_A8": score(a8(mem), {}), "loo_W8A8": score(loo, W8)}
    print(f"[diag] group sweeps done ({time.time() - t0:.0f} s)", flush=True)

    dec = fq.Decoder(dev, a.max_new_tokens)
    tune_idx = tidx_all if not a.ntune else ls.even(tidx_all, a.ntune)
    ec, eidx_all = ls.eval_set()
    eval_idx = eidx_all if not a.neval else ls.even(eidx_all, a.neval)

    def enc_outputs(corpus, idx, cfg, wcfg):
        ws.apply(wcfg)
        outs = [fq.FQInterp(gm, cfg).run(me.input_tensor(corpus.wav(i)).to(dev)) for i in idx]
        ws.restore()
        return outs

    cache = {}

    def transcribe(label, corpus, idx, cfg, wcfg):
        key = (label, corpus.name, len(idx))
        if key not in cache:
            cache[key] = dec(enc_outputs(corpus, idx, cfg, wcfg))
        return cache[key]

    def wer_row(label, corpus, idx, cfg, wcfg):
        hyp = transcribe(label, corpus, idx, cfg, wcfg)
        fl = transcribe("float", corpus, idx, {}, {})
        refs = [corpus.texts[i] for i in idx]
        return {"vs_reference": fq.wer(refs, hyp), "vs_float": fq.wer(fl, hyp)}

    headline = {}
    for label, cfg, wcfg in (("float", {}, {}), ("W8", {}, W8), ("A8", A8, {}), ("W8A8", A8, W8)):
        headline[label] = {"tune": wer_row(label, tc, tune_idx, cfg, wcfg),
                           "eval": wer_row(label, ec, eval_idx, cfg, wcfg)}
        print(f"[diag] WER {label}: tune {headline[label]['tune']['vs_reference']['wer']:.4f} "
              f"(vs float {headline[label]['tune']['vs_float']['wer']:.4f}), eval "
              f"{headline[label]['eval']['vs_reference']['wer']:.4f} ({time.time() - t0:.0f} s)", flush=True)
    for gl in gnames:
        mem = members_of(gl)
        loo = {k: v for k, v in A8.items() if k not in mem}
        group_rows[gl]["loo_W8A8_wer_tune"] = wer_row("loo:" + gl, tc, tune_idx, loo, W8)
        print(f"[diag] WER W8A8 with {gl} float: {group_rows[gl]['loo_W8A8_wer_tune']['vs_float']['wer']:.4f} "
              f"vs float ({time.time() - t0:.0f} s)", flush=True)

    out = {
        "what": "Step 1 of the int8 fidelity work: where the per-tensor int8 grids ModelBlaster puts on "
                "Moonshine Tiny's encoder lose the signal. FLOAT SIMULATION (fq.py) -- ESTIMATES, not the "
                "int8 C pipeline. SQNR/cosine are of the encoder output against float; WER uses HF's float "
                "decoder, greedy.",
        "checkpoint": f"{me.CKPT_REPO}@{me.CKPT_REV}",
        "sets": {"calibration": {"corpus": "dev-clean >4 s, centre-cropped", "windows": len(cidx),
                                 "speakers": len({cc.speakers[i] for i in cidx})},
                 "sweep": {"corpus": "dev-clean <=4 s", "utterances": len(sweep)},
                 "tune": {"corpus": "dev-clean <=4 s", "utterances": len(tune_idx),
                          "speakers": len({tc.speakers[i] for i in tune_idx})},
                 "eval": {"corpus": "test-clean <=4 s", "utterances": len(eval_idx),
                          "speakers": len({ec.speakers[i] for i in eval_idx})}},
        "grids": "activations per-tensor int8, MB ranges (GELU-aware); attention scores calibrated, probs 1/127; "
                 "weights per-tensor int8 max-abs",
        "max_new_tokens": a.max_new_tokens,
        "baselines_sweep": base, "headline_wer": headline,
        "groups": group_rows, "tensors": tensors, "weights": weights,
        "seconds": time.time() - t0,
    }
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json} ({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
