#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Amdahl table for hart 0: where Moonshine's encoder spends its 28.4 s on today's engine, what
would move each part (software first, hardware second), and what that does to RTF and to the
(a)-vs-(b) engine choice.

MEASURED: every "today" second comes from Lab B26's engine image on 0x5A5A0010
(b26_roccmoon_run.json, enc_ew_eng, one cold inference, steady state = total minus the one-time
weight-image build), dispatch by dispatch, and from Lab B25 run 8 (b25_run8_run.json) for the
engine dispatches' own split: array steps, fill, 64-byte result placement.

ESTIMATED, and marked est with a derivation: every software lever's new cycles/element, every
hardware unit's engine time and its LUT/DSP/BRAM.  The area estimates are scaled from blocks
that were routed in context (ROCC_DECOUPLED.md s8.4: mbxr_quant 1,333 LUT/16 DSP for four
32x32 requantisers; mbxr_mac 620 LUT/32 DSP; mbxd_spad 342 LUT/20 BRAM36; mbxd_dma 326 LUT;
drain 160 LUT; sequencer 96 LUT).  Budget left on 0x5A5A0010: 14,367 LUT, 130 DSP, 54.5 BRAM36,
WNS +0.458 ns.

    python3 amdahl_hart0.py --json amdahl_hart0.json
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import codesign_price as cp  # noqa: E402

CLK = cp.CLK
MEMO2_C_EL = 57271359 / 1306800.0     # softmax pext_int_memo2, measured (out/rocket_moonshine_enc_smx2)
# NHWC stem island, measured A/B/A/B in one session (board/b26_nhwc2_abab_run.json, 2026-09-17 09:10):
# enc_ew_eng_smx2 668.17/668.18 M steady -> enc_ew_eng_smx2_nhwc 638.45/638.43 M.  Net of the
# staging removed (-33.15 M) and the pixel-outer NHWC GroupNorm (106.3 against 89.4 cycles/element).
NHWC_NET_MEASURED = 29735061
# Curated permute pext_block, measured A/B/A/B aligned (board/b26_perm_abab_run.json, 2026-09-17 10:05):
# permute4_s8 39.80 -> 7.49 cycles/element, steady -38.81 M.
PERM_C_EL_MEASURED = 7.49
# Incremental placement, measured A/B/A/B on 0x5A5A0012 (board/b26_2a_ab_run.json, 2026-09-17 11:19):
# 595.43 M steady -> 570.19 M, -25.24 M, all of it in the engine dispatches (linears -20.41 M, stem
# convs -4.83 M).  The estimate was -27..-45 M: hart 1's wait fell by 35.4 M but placement itself
# cost 10.0 M more interleaved (42.4 -> 52.3 M), which the estimate did not model.
PLACE_EARLY_MEASURED = 25243209
# The share of placement cycles incremental placement actually removes, measured on the encoder:
# 25.24 M saved of 42.36 M placed.  Applied to the decoder's placement row, where it is derived,
# not measured: a decoder dispatch waits on fill far longer than it places, so the limit there is
# the same interleaving overhead rather than the available wait.
PLACE_EARLY_FRAC = 25243209 / 42359465.0
# Multiply pricing (the s8.14 audit): the big core is MulDivParams(mulUnroll = 8, mulEarlyOut = true).
# Extra cycles per M-extension instruction, DERIVED from board cycles and spike instruction counts of the
# same code: (cycles/instruction - 1.15) x instructions / M-instructions, for softmax (memo), LayerNorm,
# GroupNorm and rotary: 7.7, 6.5, 5.7, 8.4.  1.15 is the cycles/instruction of kernels without
# multiplies (add 1.09, matmul_b 1.20).  A pipelined multiplier (mulUnroll = xLen) leaves ~1.5
# (one interlock stall on a dependent instruction; estimate).
MUL_EXTRA_NOW = (5.7, 7.0, 8.4)
MUL_EXTRA_PIPED = 1.5
S = 1.0 / CLK                      # seconds per cycle
FILL_BPC = 6.06                    # B25 run 8, engine port at 3 outstanding (measured)
PLACE_CPB = 19.0                   # B25 run 8, LITTLE hart, 64-byte runs, encoder shapes (measured 15-25)


def sites():
    b26 = json.load(open(cp.B26))
    m = b26["models"]["enc_ew_eng"]
    agg = collections.OrderedDict()
    for x in m["rows"]:
        key = re.sub(r"layers\.\d+\.", "", x["name"])
        key = re.sub(r"scaled_dot_product_attention(_\d+)?", "sdpa", key)
        key = re.sub(r"^(permute|add)_\d+$", r"\1", key)
        a = agg.setdefault((x["op"], key), {"n": 0, "cycles": 0, "elements": 0, "macs": 0})
        a["n"] += 1
        a["cycles"] += x["cycles"]
        a["elements"] += x["elements"]
        a["macs"] += x["macs"]
    return b26, m, agg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    b26, m, agg = sites()
    ew, big, shapes, kf = cp.load()
    eng = m["mb_roccmoon"] if "mb_roccmoon" in m else None
    # engine dispatches, steady state, from B25 run 8 (64-byte placement)
    lin = {n: shapes[n] for n in ("enc_qkvo", "enc_fc1", "enc_fc2")}
    mult = {"enc_qkvo": 24, "enc_fc1": 6, "enc_fc2": 6}
    lin_total = sum(lin[n]["h0_64"] * mult[n] for n in lin)
    lin_steps = sum(lin[n]["steps"] * mult[n] for n in lin)
    lin_place = sum(lin[n]["place_64"] * mult[n] for n in lin)
    # AUDIT: draining in final order is not realisable for these dispatches -- every encoder linear
    # has several weight tiles (3, 11, 11), so its output leaves the drain in [tile, pixel] order.
    # What is realisable is placing each tile's bytes on hart 1 WHILE the engine computes the next:
    # the saving per dispatch is min(placement, engine busy) (B25 run 8, measured parts).
    lin_place_saving = sum(min(chunk_[n]["cyc_place"], chunk_[n]["cyc_busy"]) * mult[n]
                           for n in lin for chunk_ in [{x["name"]: x for x in json.load(open(cp.B25))["shapes_place_chunk"]}])
    stem_stage = sum(kf[c]["stage_cycles_last"] for c in ("stem_conv1", "stem_conv2", "stem_conv3"))
    stem_eng = sum(kf[c]["kernel_cycles"] - kf[c]["stage_cycles_last"] for c in ("stem_conv1", "stem_conv2", "stem_conv3"))
    stem_steps = sum(kf[c]["macs"] / 32.0 for c in ("stem_conv1", "stem_conv2", "stem_conv3"))

    def g(op, key):
        return agg[(op, key)]

    today = collections.OrderedDict()
    today["softmax"] = (g("softmax_s8", "sdpa.softmax")["cycles"], "measured", g("softmax_s8", "sdpa.softmax")["elements"])
    today["attention scores q.k (matmul_b)"] = (g("matmul_b_s8", "sdpa.qk")["cycles"], "measured", g("matmul_b_s8", "sdpa.qk")["macs"])
    today["attention weighted sum p.v (matmul_b)"] = (g("matmul_b_s8", "sdpa.av")["cycles"], "measured", g("matmul_b_s8", "sdpa.av")["macs"])
    today["LayerNorm"] = (sum(v["cycles"] for (op, k), v in agg.items() if op == "layernorm_s8"), "measured",
                          sum(v["elements"] for (op, k), v in agg.items() if op == "layernorm_s8"))
    today["permute (24 attention + 1 stem)"] = (g("permute4_s8", "permute")["cycles"], "measured", g("permute4_s8", "permute")["elements"])
    today["rotary (q, k)"] = (g("rope_s8", "self_attn.rope_q")["cycles"] + g("rope_s8", "self_attn.rope_k")["cycles"], "measured",
                              g("rope_s8", "self_attn.rope_q")["elements"] * 2)
    today["NCHW<->NHWC staging (stem)"] = (stem_stage, "measured (B25 run 8 kernel files)", None)
    today["GELU LUT (stem 2 + MLP 6)"] = (sum(v["cycles"] for (op, k), v in agg.items() if op == "gelu_s8"), "measured",
                                          sum(v["elements"] for (op, k), v in agg.items() if op == "gelu_s8"))
    today["GroupNorm (stem)"] = (g("groupnorm_s8", "stem.groupnorm")["cycles"], "measured", 287712)
    today["residual adds"] = (g("add_s8", "add")["cycles"], "measured", g("add_s8", "add")["elements"])
    today["tanh LUT (stem)"] = (g("tanh_s8", "stem.tanh")["cycles"], "measured", 287712)
    today["engine dispatches: linears (hart-0 wall)"] = (lin_total, "measured (B25 run 8, 64-byte placement)", None)
    today["engine dispatches: stem convs (hart-0 wall, no staging)"] = (stem_eng, "measured (B25 run 8)", None)
    total = sum(v[0] for v in today.values())

    rows = []

    def row(part, sw_lever, sw_new, sw_src, hw_unit, hw_new, hw_src, area, note=""):
        c, src, units = today[part]
        rows.append({"part": part, "seconds_today": c * S, "source": src, "share": c / total,
                     "software_lever": sw_lever, "software_seconds_after": None if sw_new is None else sw_new * S,
                     "software_estimate": sw_src,
                     "hardware_unit": hw_unit, "hardware_seconds_after": None if hw_new is None else hw_new * S,
                     "hardware_estimate": hw_src, "area_est": area, "note": note,
                     "rtf_if_software_lever_alone": None if sw_new is None else (total - c + sw_new) * S / 4.0,
                     "rtf_if_hardware_alone": None if hw_new is None else (total - c + hw_new) * S / 4.0})

    sm = today["softmax"]
    row("softmax",
        "softmax memo2 (patches/0106): the exponential memoised per dispatch, 32-bit-operand multiplies, and a "
        "per-row monotone zero cutoff with an output cache; bit-exact with the current kernel", sm[2] * MEMO2_C_EL,
        "MEASURED on the board (Lab B26, 0x5A5A0010): 43.8 cycles/element (pext_int_memo 101.7-103.6; the "
        "superseded s8.14 estimate was 30 for pext_int_memo, which priced a multiply at 1-2 cycles)",
        "softmax lane: exp table (256 x 32 b LUTRAM, loaded per dispatch), row sum, one sequential 64/32 divide per "
        "row, 32x32 normalise + rescale; rows streamed from the scores the MAC array just produced",
        sm[2] * 2.0 + 1320 * 6 * 64, "est 2 cycles/element (sum pass, normalise pass) + a 64-cycle divide per row",
        {"LUT": 1800, "DSP": 6, "BRAM36": 1, "derivation": "exp LUTRAM ~400 + divider ~200 + control ~600 + row buffer ~600; "
                                                              "6 DSP = one 32x32 normalise + one rescale, as mbxr_quant's 4 DSP per 32x32"},
        "What stops softmax in hardware: nothing but the division. The exponential is a 256-entry table because the "
        "input is int8; the per-row normalisation is one divide per 165 elements.")
    qk = today["attention scores q.k (matmul_b)"]
    row("attention scores q.k (matmul_b)", "none worth pricing: already DOT8 at 2.63 cycles/MAC", None, "",
        "the existing MAC array on q and k (both activations: SBUS client), scores kept in the engine for the softmax lane",
        qk[2] / 32.0, "est MACs/32 (the array's measured rate)",
        {"LUT": 1500, "DSP": 0, "BRAM36": 22,
         "derivation": "attention sequencer (query rows x key tiles, head loop) ~1,500 LUT against tseq's 96 for linears; "
                       "K and V for one layer held in the scratchpad: 2 x 165 x 288 B = 95 KB = ~22 BRAM36"})
    av = today["attention weighted sum p.v (matmul_b)"]
    row("attention weighted sum p.v (matmul_b)", "none", None, "",
        "MAC array, probabilities (int8) x V, streamed per query row after the softmax lane", av[2] / 32.0,
        "est MACs/32", {"LUT": 0, "DSP": 0, "BRAM36": 0, "derivation": "shares the attention sequencer and the array"})
    ln = today["LayerNorm"]
    row("LayerNorm", "none priced: per-row mean/variance and rsqrt are not table-able", None, "",
        "LayerNorm lane: sum and sum-of-squares accumulators, integer rsqrt (256-entry seed + one Newton step), "
        "normalise, gamma, rescale", ln[2] * 2.0 + 13 * 165 * 32,
        "est 2 cycles/element + 32 per row for the rsqrt",
        {"LUT": 900, "DSP": 6, "BRAM36": 0, "derivation": "two accumulators + rsqrt seed LUT + normalise/gamma/rescale "
                                                           "multipliers (6 DSP)"})
    pm = today["permute (24 attention + 1 stem)"]
    row("permute (24 attention + 1 stem)", "curated permute: block copies along the kept axis (the reference kernel "
        "walks every index)", pm[2] * PERM_C_EL_MEASURED,
        "measured 7.49 cycles/element (B26 aligned A/B/A/B, pext_block; the reference's cost was a per-element "
        "soft-float compare); today 39.9 (measured)",
        "vanishes inside the attention unit (heads are an index, not a copy)", 0.0, "", {"LUT": 0, "DSP": 0, "BRAM36": 0,
                                                                                        "derivation": "part of the attention sequencer"})
    rp = today["rotary (q, k)"]
    row("rotary (q, k)", "WITHDRAWN (audit): pext_int_rot already precomputes per-position constants; what is "
        "left is ~42 instructions/element with two 64-bit multiplies", None,
        "the s8.14 estimate of 35 cycles/element assumed a table the kernel already has",
        "rotary lane: per-position cos/sin table (Q15), two multiplies per element pair, between the q/k linears and "
        "the scores", rp[2] * 1.0, "est 1 cycle/element",
        {"LUT": 400, "DSP": 2, "BRAM36": 3, "derivation": "165 x 16 x 2 x 16 b table = 84 Kb = ~3 BRAM36; 2 DSP"})
    st = today["NCHW<->NHWC staging (stem)"]
    row("NCHW<->NHWC staging (stem)", "TODO.md item 5: NHWC tensors, so the stem's convs read and write the layout "
        "the engine uses (no gather, no transpose)", max(0.0, st[0] - NHWC_NET_MEASURED),
        "measured net -29.74 M (B26 A/B/A/B: staging gone, NHWC GroupNorm +4.9 M); applied to B25 run 8's staging",
        "none needed", None, "", {"LUT": 0, "DSP": 0, "BRAM36": 0, "derivation": "software only"})
    ge = today["GELU LUT (stem 2 + MLP 6)"]
    row("GELU LUT (stem 2 + MLP 6)", "none: already a memoised LUT (19.4 cycles/element measured)", None, "",
        "LUT lane: 256-entry table loaded per dispatch, streamed between fc1 and fc2 so fc1's output is never placed "
        "(fc1's 64-byte placement, 6 x 3.12 M cycles measured, is also removed by draining in final order)", ge[2] * 1.0,
        "est 1 cycle/element", {"LUT": 300, "DSP": 0, "BRAM36": 0,
                                                                 "derivation": "256 x 8 b LUTRAM + stream control"})
    gn = today["GroupNorm (stem)"]
    row("GroupNorm (stem)", "none", None, "", "shares the LayerNorm lane (one mean/variance over the whole tensor)",
        gn[2] * 2.0, "est 2 cycles/element", {"LUT": 200, "DSP": 0, "BRAM36": 0, "derivation": "on top of the LayerNorm lane"})
    ad = today["residual adds"]
    row("residual adds", "none", None, "", "add lane: two rescales and a saturate per element",
        ad[2] * 1.0, "est 1 cycle/element", {"LUT": 300, "DSP": 2, "BRAM36": 0, "derivation": "2 DSP rescales"})
    th = today["tanh LUT (stem)"]
    row("tanh LUT (stem)", "none", None, "", "the LUT lane", th[2] * 1.0, "est 1 cycle/element",
        {"LUT": 0, "DSP": 0, "BRAM36": 0, "derivation": "the LUT lane"})
    le = today["engine dispatches: linears (hart-0 wall)"]
    row("engine dispatches: linears (hart-0 wall)",
        "incremental placement: hart 1 places each tile's drained bytes while the engine computes the next "
        "(AUDIT: draining in final order is not realisable here -- multi-tile weights leave [tile, pixel] order)",
        le[0] - PLACE_EARLY_MEASURED, "measured -25.24 M (B26 A/B/A/B on 0x5A5A0012: wait -35.4 M, "
        "placement +10.0 M); the estimate was minus min(placement, engine busy), -29 M",
        "(the same software change)", le[0] - PLACE_EARLY_MEASURED, "measured",
        {"LUT": 0, "DSP": 0, "BRAM36": 0, "derivation": "driver only"})
    se = today["engine dispatches: stem convs (hart-0 wall, no staging)"]
    row("engine dispatches: stem convs (hart-0 wall, no staging)", "none priced", None, "",
        "none: the array's steps are most of it", None, "", {"LUT": 0, "DSP": 0, "BRAM36": 0, "derivation": ""})

    # ---- cumulative scenarios, from as-extracted -------------------------------------------
    by = {r["part"]: r for r in rows}

    def after(parts_sw, parts_hw):
        s = 0.0
        for r in rows:
            c = today[r["part"]][0] * S
            if r["part"] in parts_hw and r["hardware_seconds_after"] is not None:
                c = r["hardware_seconds_after"]
            elif r["part"] in parts_sw and r["software_seconds_after"] is not None:
                c = r["software_seconds_after"]
            s += c
        return s

    SW = ["softmax", "permute (24 attention + 1 stem)", "NCHW<->NHWC staging (stem)",
          "engine dispatches: linears (hart-0 wall)"]
    ATT = ["softmax", "attention scores q.k (matmul_b)", "attention weighted sum p.v (matmul_b)",
           "permute (24 attention + 1 stem)", "rotary (q, k)"]
    LN = ["LayerNorm"]
    REST = ["GELU LUT (stem 2 + MLP 6)", "GroupNorm (stem)", "residual adds", "tanh LUT (stem)"]

    def area(parts):
        tot = {"LUT": 0, "DSP": 0, "BRAM36": 0}
        seen = set()
        for p in parts:
            r = by[p]
            key = r["hardware_unit"]
            if key in seen:
                continue
            seen.add(key)
            for k in tot:
                tot[k] += r["area_est"][k]
        return tot

    scen = []
    for label, sw, hw in (("today (as measured)", [], []),
                          ("T1 software levers: softmax memo2 (measured), curated permute, NHWC, incremental placement", SW, []),
                          ("T2 = T1 + attention unit (scores, softmax lane, weighted sum, rotary)", SW, ATT),
                          ("T3 = T2 + LayerNorm lane", SW, ATT + LN),
                          ("T4 = T3 + LUT, GroupNorm and add lanes (a whole layer stays in the engine)", SW, ATT + LN + REST)):
        sec = after(sw, hw)
        ar = area([p for p in hw]) if hw else {"LUT": 0, "DSP": 0, "BRAM36": 0}
        if "engine dispatches: linears (hart-0 wall)" in sw:
            ar["LUT"] += 200 if hw else 0
        scen.append({"scenario": label, "seconds": sec, "rtf": sec / 4.0, "area_est": ar})

    # ---- the multiplier as a lever: M-extension instructions per kernel (spike, memo2 image) ----
    md = json.load(open(os.path.join(HERE, "muldiv_ew_eng_smx2.json")))
    kfun = {"softmax": "kernel_softmax_s8_moonshine_enc", "LayerNorm": "kernel_layernorm_s8_moonshine_enc",
            "attention scores q.k (matmul_b)": "kernel_matmul_b_s8_moonshine_enc",
            "rotary (q, k)": "kernel_rope_s8_moonshine_enc", "GroupNorm (stem)": "kernel_groupnorm_s8_moonshine_enc",
            "residual adds": "kernel_add_s8_moonshine_enc"}
    mcount = {part: sum(md["per_function"].get(fn, {}).values()) for part, fn in kfun.items()}
    mcount["LayerNorm"] += sum(md["per_function"].get("int_rsqrt_q31", {}).values())
    mul_rows = {part: {"m_instructions": n,
                       "stall_seconds_now": [n * e / CLK for e in MUL_EXTRA_NOW],
                       "saving_seconds_piped": [n * (e - MUL_EXTRA_PIPED) / CLK for e in MUL_EXTRA_NOW]}
                for part, n in mcount.items()}

    def mul_saving(parts_left):
        """seconds a pipelined multiplier saves on the software parts still on hart 0 (low, mid, high)"""
        return [sum(mul_rows[p]["saving_seconds_piped"][i] for p in parts_left if p in mul_rows) for i in range(3)]

    for sc_ in scen:
        gone = set()
        if sc_["scenario"].startswith(("T2", "T3", "T4")):
            gone |= set(ATT)
        if sc_["scenario"].startswith(("T3", "T4")):
            gone |= set(LN)
        if sc_["scenario"].startswith("T4"):
            gone |= set(REST)
        left = [p for p in mul_rows if p not in gone]
        sv = mul_saving(left)
        sc_["with_pipelined_multiplier"] = {"seconds": [sc_["seconds"] - x for x in sv],
                                            "rtf": [(sc_["seconds"] - x) / 4.0 for x in sv],
                                            "saving_seconds_low_mid_high": sv, "estimate": True}

    # ---- re-price the quantisation candidates under the scenarios -----------------------------
    C = cp.cost_table(ew, big)
    cands = [("as extracted (W8A8)", "a", {"stem": "int8"}),
             ("R split stem (1,64), 2 groups", "a", {"stem": "int16", "adds": "pc", "stem_impl_a": "split:2:2"}),
             ("F3 + per-row", "b1", {"stem": "int16", "adds": "pc", "weights": "pr"}),
             ("F3 + per-row", "b2", {"stem": "int16", "adds": "pc", "weights": "pr"})]
    wer = {"as extracted (W8A8)": (1.2049, 1.1157), "R split stem (1,64), 2 groups": (0.0831, 0.0818),
           "F3 + per-row": (0.0782, None)}
    re_rows = []
    for name, hw, desc in cands:
        for sc_label, nhwc, sw_scale in (("today", False, None), ("T1", True, "T1"), ("T2", True, "T2"),
                                         ("T3", True, "T3"), ("T4", True, "T4")):
            d = dict(desc, nhwc=nhwc, drain_final_order=nhwc)
            cyc, parts, est = cp.price(d, hw, C, ew, shapes, kf)
            # apply the scenario to the software parts and the engine placement
            p = dict(parts)
            f = {"sw_softmax": 1.0, "sw_permute": 1.0, "sw_rope": 1.0, "sw_matmul_b": 1.0, "sw_layernorm": 1.0,
                 "sw_gelu_mlp": 1.0, "sw_gelu_stem": 1.0, "sw_tanh": 1.0, "sw_groupnorm": 1.0, "sw_add": 1.0}
            if sc_label != "today":
                f["sw_softmax"] = by["softmax"]["software_seconds_after"] / (today["softmax"][0] * S)
                f["sw_permute"] = by["permute (24 attention + 1 stem)"]["software_seconds_after"] / (today["permute (24 attention + 1 stem)"][0] * S)
                f["sw_rope"] = 1.0          # the rotary lever was withdrawn by the audit
                p["linears"] = p["linears"] - PLACE_EARLY_MEASURED * (2 if (desc.get("all16")) else 1)
            if sc_label in ("T2", "T3", "T4"):
                for k in ("sw_softmax", "sw_permute", "sw_rope", "sw_matmul_b"):
                    f[k] = 0.0
                p["attention_unit"] = sum(by[x]["hardware_seconds_after"] for x in ATT) * CLK
            if sc_label in ("T3", "T4"):
                f["sw_layernorm"] = 0.0
                p["layernorm_unit"] = by["LayerNorm"]["hardware_seconds_after"] * CLK
            if sc_label == "T4":
                # int8 LUT/GN/add lanes; an int16 stem keeps its 65,536-entry tables in software
                for k in ("sw_gelu_mlp", "sw_add", "sw_groupnorm") + (() if desc.get("stem") == "int16" else ("sw_gelu_stem", "sw_tanh")):
                    f[k] = 0.0
                p["lut_gn_add_units"] = (1.14048e6 + 287712 * 2 + 570240) * 1.0
            for k, v in f.items():
                if k in p:
                    p[k] = p[k] * v
            cyc2 = sum(p.values())
            re_rows.append({"candidate": name, "engine": hw, "scenario": sc_label, "rtf": cyc2 / CLK / 4.0,
                            "stem_s": p["stem_convs"] / CLK, "linears_s": p["linears"] / CLK,
                            "wer_dev": wer[name][0], "wer_test": wer[name][1]})

    # ---- the decoder, per scenario, so the table can report end-to-end transcription RTF ----
    # Composed (ROCC_DECOUPLED.md 8.9): measured engine dispatches per token (B25 run 8, 64-byte
    # placement) + the non-GEMM residue priced with B26-calibrated unit costs.  15 tokens for a
    # typical 4 s utterance; cross-attention K,V once.  The decoder has not been quantised for
    # fidelity: its int8 WER is unmeasured, so this column prices cost only.
    dc = json.load(open(os.path.join(cp.ROOT, "rtl_study", "roccmoon", "board", "b25_run8_decode_compose.json")))
    b25 = json.load(open(cp.B25))
    chunk = {x["name"]: x for x in b25["shapes_place_chunk"]}
    per_tok = {"dec_qkvo": 36, "dec_fc1": 6, "dec_fc2": 6, "dec_lmhead": 1}
    place_tok_ms = sum(chunk[k]["cyc_place"] * n for k, n in per_tok.items()) / CLK * 1e3
    place_once_ms = chunk["enc_qkvo"]["cyc_place"] * 12 / CLK * 1e3
    res = dc["residue_by_kind_ms"]["B26/nl+ew"]
    memo = MEMO2_C_EL / 277.0          # measured memo2 over measured pext_int_row
    TOK = 15

    def decoder_rtf(scn):
        gemm = dc["gemm_per_token_ms"]["engine_place64"]
        once = dc["gemm_once_ms"]["engine_place64"]
        r = dict(res)
        if scn != "today":
            gemm -= place_tok_ms
            once -= place_once_ms
            r["softmax"] *= memo
        if scn in ("T2", "T3", "T4"):
            r["softmax"] = 0.0
            r["matmul"] = 0.0
        if scn in ("T3", "T4"):
            r["layernorm"] = 0.0
        if scn == "T4":
            r["silu"] = 0.0
            r["add"] = 0.0
        tok = gemm + sum(r.values())
        return (once + TOK * tok) / 1000.0 / 4.0, tok

    for sc_, key in zip(scen, ("today", "T1", "T2", "T3", "T4")):
        d_rtf, tok = decoder_rtf(key)
        sc_["decoder_rtf_composed"] = d_rtf
        sc_["decoder_token_ms"] = tok
        sc_["end_to_end_rtf"] = sc_["rtf"] + d_rtf
    for r_ in re_rows:
        d_rtf, _ = decoder_rtf(r_["scenario"])
        r_["decoder_rtf_composed"] = d_rtf
        r_["end_to_end_rtf"] = r_["rtf"] + d_rtf

    # ---- the decoder's own Amdahl rows, per token (15-token, 4 s utterance; seq 8 midpoint) ----
    # Populations from reprice_port.decoder_token; unit costs MEASURED on the board where a kernel ran
    # (B26 encoder kernels, B25 run 8 engine dispatches), ESTIMATED otherwise; the decoder itself is
    # composed, never run (ModelBlaster cannot generate it).
    T_ = 165
    dsm_el, dsm_disp = 8304, 12
    dln_el, dmm_mac, drope_el, dgate_el, dadd_el, dsilu_ms = 5472, 597888, 3456, 6912, 5184, dc["residue_by_kind_ms"]["B26/nl+ew"]["silu"]
    unit = {"softmax_row": 277.5, "softmax_memo2": MEMO2_C_EL, "ln": 186.6, "mm": 2.126, "rope": 66.0, "add": 37.7}
    chunk_tok = {k: chunk[k] for k in per_tok}
    fill_ms = sum(shapes_[k]["cyc_fill"] * n for k, n in per_tok.items() for shapes_ in [{x["name"]: x for x in b25["shapes"]}]) / CLK * 1e3
    steps_ms = sum(s_["steps"] * n for k, n in per_tok.items() for s_ in [{x["name"]: x for x in b25["shapes"]}[k]]) / CLK * 1e3
    gemm_ms = dc["gemm_per_token_ms"]["engine_place64"]
    rest_ms = gemm_ms - fill_ms - steps_ms - place_tok_ms
    ms = lambda cyc: cyc / CLK * 1e3
    dec_rows = [
        ("engine GEMMs: fill (port)", fill_ms, "measured (B25 run 8)", {"T1": fill_ms}),
        ("engine GEMMs: result placement (hart 1)", place_tok_ms, "measured",
         {"T1": place_tok_ms * (1.0 - PLACE_EARLY_FRAC)}),   # derived from the encoder's measured share
        ("engine GEMMs: array steps", steps_ms, "measured", {"T1": steps_ms}),
        ("engine GEMMs: commands and hand-off", rest_ms, "measured", {"T1": rest_ms}),
        ("softmax (6 self, 6 cross)", ms(dsm_el * unit["softmax_row"]), "measured unit (encoder)",
         {"T1": ms(dsm_el * unit["softmax_memo2"] + dsm_disp * 256 * 100), "T2": ms(dsm_el * 2)}),
        ("attention matmuls", ms(dmm_mac * unit["mm"]), "measured unit", {"T2": ms(dmm_mac / 32.0)}),
        ("LayerNorm", ms(dln_el * unit["ln"]), "measured unit", {"T3": ms(dln_el * 2 + 19 * 32)}),
        ("rotary", ms(drope_el * unit["rope"]), "measured unit", {"T2": ms(drope_el * 1)}),
        ("SiLU", dsilu_ms, "ESTIMATE (GELU-LUT model, no silu kernel)", {"T4": ms(6912 * 1)}),
        ("gate multiply", ms(dgate_el * unit["add"]), "ESTIMATE (int8 mul at the add unit)", {"T4": ms(dgate_el * 1)}),
        ("residual adds", ms(dadd_el * unit["add"]), "measured unit", {"T4": ms(dadd_el * 1)}),
    ]
    order = ["today", "T1", "T2", "T3", "T4"]
    dec_table = []
    for name, today_ms, src, after in dec_rows:
        vals, cur = {}, today_ms
        for sc in order:
            if sc in after:
                cur = after[sc]
            vals[sc] = cur
        dec_table.append({"part": name, "source": src, "ms_per_token": vals})
    # the pipelined multiplier on the decoder's software parts at T1: stall shares from the encoder's kernels
    stall_share = {"softmax (6 self, 6 cross)": mul_rows["softmax"]["stall_seconds_now"][1] / max(1e-9, by["softmax"]["software_seconds_after"]),
                   "attention matmuls": mul_rows["attention scores q.k (matmul_b)"]["stall_seconds_now"][1] / (today["attention scores q.k (matmul_b)"][0] * S + today["attention weighted sum p.v (matmul_b)"][0] * S),
                   "LayerNorm": mul_rows["LayerNorm"]["stall_seconds_now"][1] / (today["LayerNorm"][0] * S),
                   "rotary": mul_rows["rotary (q, k)"]["stall_seconds_now"][1] / (today["rotary (q, k)"][0] * S)}
    dec_tot = {sc: sum(r["ms_per_token"][sc] for r in dec_table) for sc in order}
    once_ms = {"today": dc["gemm_once_ms"]["engine_place64"]}
    for sc in order[1:]:
        once_ms[sc] = dc["gemm_once_ms"]["engine_place64"] - place_once_ms
    dec_rtf = {sc: (once_ms[sc] + TOK * dec_tot[sc]) / 1000.0 / 4.0 for sc in order}
    mul_save_t1 = sum(r["ms_per_token"]["T1"] * stall_share.get(r["part"], 0.0) * (1 - MUL_EXTRA_PIPED / MUL_EXTRA_NOW[1])
                      for r in dec_table)
    decoder_amdahl = {"rows": dec_table, "token_ms": dec_tot, "decoder_rtf": dec_rtf,
                      "pipelined_multiplier_saving_ms_per_token_at_T1_est": mul_save_t1,
                      "stall_shares_used": stall_share,
                      "note": "composed per token; softmax at T1 adds an ESTIMATED 256-entry table build per dispatch (~25.6 k cycles), "
                              "which matters for the decoder's small self-attention rows"}

    out = {"what": "Amdahl table for hart 0 on Moonshine's encoder (4 s window, 0x5A5A0010, steady state); today's "
                   "seconds measured (B26, B25 run 8); every lever's and unit's seconds and area are estimates",
           "total_seconds_today": total * S, "rtf_today": total * S / 4.0,
           "budget_free_on_0x5A5A0010": {"LUT": 53200 - 38833, "DSP": 220 - 90, "BRAM36": 140 - 85.5, "WNS_ns": 0.458},
           "rows": rows, "scenarios": scen, "repriced_candidates": re_rows,
           "decoder_amdahl": decoder_amdahl,
           "multiplier_lever": {"muldiv_counts": "muldiv_ew_eng_smx2.json", "extra_cycles_per_m_instruction_now": MUL_EXTRA_NOW,
                                "extra_cycles_piped_est": MUL_EXTRA_PIPED, "per_part": mul_rows,
                                "ooc": "rtl_study/muldiv/ooc_out/summary.tsv"}}
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"today: {total * S:.2f} s, RTF {total * S / 4:.2f}")
    print(f"{'part':56s} {'s':>6s} {'share':>6s} {'sw->s':>7s} {'RTF':>5s} {'hw->s':>7s} {'RTF':>5s}  area(est)")
    for r in sorted(rows, key=lambda r: -r["seconds_today"]):
        print(f"{r['part']:56s} {r['seconds_today']:6.2f} {100 * r['share']:5.1f}% "
              f"{r['software_seconds_after'] if r['software_seconds_after'] is not None else float('nan'):7.2f} "
              f"{r['rtf_if_software_lever_alone'] if r['rtf_if_software_lever_alone'] is not None else float('nan'):5.2f} "
              f"{r['hardware_seconds_after'] if r['hardware_seconds_after'] is not None else float('nan'):7.2f} "
              f"{r['rtf_if_hardware_alone'] if r['rtf_if_hardware_alone'] is not None else float('nan'):5.2f}  "
              f"{r['area_est']['LUT']} LUT {r['area_est']['DSP']} DSP {r['area_est']['BRAM36']} BRAM")
    for part, m in mul_rows.items():
        print(f"  mul lever {part:40s} M-instr {m['m_instructions']:>10,}  stall now {m['stall_seconds_now'][1]:5.2f} s  "
              f"saving {m['saving_seconds_piped'][0]:.2f}-{m['saving_seconds_piped'][2]:.2f} s")
    for sc in scen:
        wm = sc["with_pipelined_multiplier"]
        print(f"  {sc['scenario']:95s} {sc['seconds']:6.2f} s RTF {sc['rtf']:5.2f} (pipelined multiplier: {wm['rtf'][2]:.2f}-{wm['rtf'][0]:.2f})  decoder {sc['decoder_rtf_composed']:5.2f} "
              f"({sc['decoder_token_ms']:5.0f} ms/tok)  end-to-end {sc['end_to_end_rtf']:5.2f}  area est {sc['area_est']}")
    for r in re_rows:
        print(f"  {r['candidate']:34s} {r['engine']:3s} {r['scenario']:6s} RTF {r['rtf']:5.2f}  e2e {r['end_to_end_rtf']:5.2f}  "
              f"stem {r['stem_s']:5.2f} s  linears {r['linears_s']:5.2f} s")
    print("decoder, ms per token (composed):")
    for r in dec_table:
        print(f"  {r['part']:42s} " + "  ".join(f"{sc} {r['ms_per_token'][sc]:6.1f}" for sc in order) + f"   [{r['source']}]")
    print("  total                                      " + "  ".join(f"{sc} {dec_tot[sc]:6.1f}" for sc in order))
    print("  decoder RTF (15 tok, 4 s)                  " + "  ".join(f"{sc} {dec_rtf[sc]:6.2f}" for sc in order))
    print(f"  pipelined multiplier at T1: ~{mul_save_t1:.1f} ms/token saved (est)")
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
