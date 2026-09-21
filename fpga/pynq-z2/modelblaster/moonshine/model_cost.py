#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A cost model of Moonshine Tiny ITSELF -- bytes fetched and MACs, per tensor group -- built
on the MEASURED per-dispatch traffic in engine_traffic.json, so that a change to the MODEL can
be priced without a board.

WHY THIS FILE EXISTS.  ROCC_DECOUPLED.md section 8 prices the hardware: what the engine, the port
and hart 0 cost for a fixed model.  MOONSHINE_MODEL.md asks the other question -- what would
change if the MODEL changed -- and that needs the cost attributed to tensor groups (stem,
encoder attention, encoder FFN, decoder self-attention, decoder cross-attention, decoder FFN,
lm_head) rather than to dispatch kinds.

WHAT IS MEASURED AND WHAT IS DERIVED.
  MEASURED   every per-dispatch byte count and cycle count.  They come from
             engine_traffic.json, which carries Lab B25 run 8 (one dispatch per shape, engine
             counters read on the board, 0x5A5A0010 md5 7475c1b2) and Lab B26 (the whole
             encoder's totals).  This file copies them; it does not re-measure them.
  PLANNED    the three stem convolutions, whose bytes come from mbxr_run's tile plan
             re-executed in engine_traffic.py and checked against B26's encoder totals.
  DERIVED    (a) MACs: arithmetic on the checkpoint's shapes (config.json @ 390624ed).
             (b) The group sums: the model's dispatch counts times the measured per-dispatch
                 numbers.
             (c) Every "what if" below: the same planner (engine_traffic.wimage_plan) run on a
                 changed shape, and the measured cycles scaled by the part of the dispatch the
                 change touches.  A changed shape is NOT a measurement and is labelled so.

THE ENGINE'S WEIGHT IMAGE, which is what makes bytes != parameters.  mbxr's planar image
(engine_traffic.wimage_plan) lays a linear of N outputs and K bytes of reduction out as
ceil(N/4) quads of (K/8 + 1) words -- the +1 word is the row's bias, with the requantise
multiplier and shift in its high half -- packed Q quads to a tile, each tile 4 planes of a
POWER-OF-TWO number of words, and fetched whole.  So
    tile_bytes = 4 * (8 << lgpw),  lgpw = max(3, bitlen(Q*(K/8+1) - 1)),  Q = min(1024//(K/8+1), quads)
and the fetched bytes exceed the int8 parameter bytes by the power-of-two rounding.  For
lm_head (N = 32768, K = 288) that is 9,961,472 fetched for 9,437,184 of weights, +5.6 %.  For
stem conv3 (K = 1728) it is +18 %.  Any model change that changes K or N re-runs this planner.

    python3 model_cost.py --json model_cost.json
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import engine_traffic as et  # noqa: E402

CLK = et.CLK                       # 34,482,759 Hz, FCLK0 as read back in B25/B26
WINDOW_S = 4.0
T_ENC = 165                        # encoder frames for a 4 s window
D, FF_ENC, FF_DEC, HEADS, HD = 288, 1152, 2304, 8, 36   # FF_DEC is the gated fc1 width
LAYERS = 6
VOCAB = 32768

# ---------------------------------------------------------------------------------------
# The measured per-dispatch record, keyed by shape name, straight out of engine_traffic.json.
# ---------------------------------------------------------------------------------------


def traffic() -> dict:
    with open(os.path.join(HERE, "engine_traffic.json")) as f:
        return json.load(f)


def per_dispatch(tj: dict) -> dict:
    """name -> {bytes_w, bytes_a, out_bytes, cyc_fill, steps, cyc_h0, source}"""
    out = {}
    for grp in ("encoder_dispatches", "decoder_dispatches"):
        for e in tj[grp]:
            m = e.get("measured_b25_run8")
            p = e["planned"]
            key = e["name"] if e["name"] not in out else e["name"]
            if key in out:
                continue
            if m:
                out[key] = dict(N=e["N"], K=e["K"], npix=e["npix"], bytes_w=m["bytes_w"],
                                bytes_a=m["bytes_a"], out_bytes=m["out_bytes"],
                                cyc_fill=m["cyc_fill"], steps=m["steps"],
                                cyc_h0=m["eng_h0_chunk64"], cyc_place=m["cyc_place_h1_chunk64"],
                                source="measured (B25 run 8)")
            else:
                out[key] = dict(N=e["N"], K=e["K"], npix=e["npix"], bytes_w=p["bytes_w"],
                                bytes_a=p["bytes_a"], out_bytes=p["out_bytes"],
                                cyc_fill=None, steps=None, cyc_h0=None, cyc_place=None,
                                source="planned (mbxr tile plan, checked against B26 totals)")
    return out


# ---------------------------------------------------------------------------------------
# Tensor groups.  (dispatch name, count, MACs per dispatch, what it is)
# ---------------------------------------------------------------------------------------

ENC_GROUPS = {
    "stem": [("stem_conv1", 1, 999 * 288 * 127), ("stem_conv2", 1, 331 * 576 * 2016),
             ("stem_conv3", 1, 165 * 288 * 1728)],
    "enc_attn_proj": [("enc_qkvo", 24, T_ENC * D * D)],
    "enc_ffn": [("enc_fc1", 6, T_ENC * FF_ENC * D), ("enc_fc2", 6, T_ENC * D * FF_ENC)],
}
# software on hart 0, no engine dispatch: the batched attention matmuls
ENC_SOFT = {"enc_attn_matmul": LAYERS * 2 * HEADS * T_ENC * T_ENC * HD}

DEC_GROUPS = {
    "dec_self_attn_proj": [("dec_qkvo", 24, D * D)],        # q,k,v,o x 6 layers
    "dec_cross_attn_proj": [("dec_qkvo", 12, D * D)],       # q,o x 6 layers (k,v once per utt)
    "dec_ffn": [("dec_fc1", 6, FF_DEC * D), ("dec_fc2", 6, D * FF_ENC)],
    "lm_head": [("dec_lmhead", 1, VOCAB * D)],
}
DEC_UTT_GROUPS = {"dec_cross_attn_kv": [("enc_qkvo", 12, T_ENC * D * D)]}


def group_sum(pd: dict, spec: list) -> dict:
    g = dict(dispatches=0, bytes_w=0, bytes_a=0, out_bytes=0, macs=0,
             cyc_fill=0, steps=0, cyc_h0=0, cyc_place=0, planned=False)
    for name, count, macs in spec:
        d = pd[name]
        g["dispatches"] += count
        g["bytes_w"] += count * d["bytes_w"]
        g["bytes_a"] += count * d["bytes_a"]
        g["out_bytes"] += count * d["out_bytes"]
        g["macs"] += count * macs
        if d["cyc_h0"] is None:
            g["planned"] = True
        else:
            g["cyc_fill"] += count * d["cyc_fill"]
            g["steps"] += count * d["steps"]
            g["cyc_h0"] += count * d["cyc_h0"]
            g["cyc_place"] += count * d["cyc_place"]
    if g["planned"]:
        for k in ("cyc_fill", "steps", "cyc_h0", "cyc_place"):
            g[k] = None
    return g


# ---------------------------------------------------------------------------------------
# lm_head levers: everything is the planner on a changed shape.
# ---------------------------------------------------------------------------------------


def lmhead_image(V: int, K: int = D) -> dict:
    """Bytes the engine fetches for an lm_head of V rows and K bytes of reduction, and the
    parameter bytes it actually uses.  DERIVED (planner on a changed shape)."""
    img = et.wimage_plan(V, K)
    return dict(V=V, K=K, tiles=img["tiles"], fetched_bytes=img["bytes"],
                param_bytes=V * K, overhead=img["bytes"] / max(V * K, 1))


def lmhead_cycles(fetched_bytes: int, macs: int, base: dict) -> dict:
    """Scale the measured lm_head dispatch to a changed lm_head.  DERIVED, not measured.

    The measured dispatch splits into fill (bytes-proportional), array steps
    (MAC-proportional), result placement (output-proportional) and a residue that is the
    per-dispatch fixed cost.  Each part is scaled by its own driver; the residue is kept."""
    b0, m0, o0 = base["bytes_w"] + base["bytes_a"], base["N"] * base["K"], base["out_bytes"]
    fill = base["cyc_fill"] * fetched_bytes / b0
    steps = base["steps"] * macs / m0
    out_b = macs / D                       # one int8 logit per row
    place = base["cyc_place"] * out_b / o0
    residue = base["cyc_h0"] - base["cyc_fill"] - base["cyc_place"]
    residue = max(residue, 0) * 1.0        # command issue + planning: per dispatch, kept whole
    # the array's steps overlap the fill inside the engine; cyc_h0 already reflects that, so
    # rebuild it the same way the measurement decomposes: fill + placement + the rest
    rest = base["cyc_h0"] - base["cyc_fill"] - base["cyc_place"]
    return dict(cyc_fill=fill, steps=steps, cyc_place=place, cyc_h0=fill + place + rest,
                label="derived: measured dispatch scaled by bytes / MACs / outputs")


def decoder_rtf(token_ms: float, cross_kv_ms: float, tokens: int = 15) -> float:
    """decode_compose.py's definition: the once-per-utterance cross-attention K,V GEMMs plus
    `tokens` tokens, over the 4 s window."""
    return (cross_kv_ms + tokens * token_ms) / (WINDOW_S * 1e3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", type=int, default=15,
                    help="tokens per 4 s utterance (section 8.9 composes 15)")
    ap.add_argument("--json", required=True)
    a = ap.parse_args()

    tj = traffic()
    pd = per_dispatch(tj)

    out = {
        "what": "A cost model of Moonshine Tiny itself: bytes fetched and MACs per tensor group, "
                "per 4 s encoder window and per decoded token, on the measured per-dispatch "
                "traffic of ROCC_DECOUPLED.md section 8 (engine_traffic.json).",
        "labels": {
            "measured": "board counters, Lab B25 run 8 / Lab B26, copied from engine_traffic.json",
            "planned": "mbxr's tile plan re-executed (the three stem convolutions), checked "
                       "against B26's encoder totals",
            "derived": "arithmetic here: MACs from the checkpoint's shapes; group sums; and "
                       "every changed-shape number, which is the same planner on a new shape",
        },
        "config": dict(hidden=D, ffn_enc=FF_ENC, ffn_dec_gated=FF_DEC, heads=HEADS, head_dim=HD,
                       layers_enc=LAYERS, layers_dec=LAYERS, vocab=VOCAB, window_s=WINDOW_S,
                       enc_frames=T_ENC, clk_hz=CLK,
                       tied_embeddings=True,
                       note="lm_head is TIED to model.decoder.embed_tokens (no separate tensor in "
                            "model.safetensors), so 9,437,184 of the checkpoint's 27,092,736 "
                            "parameters -- 34.8 % -- are the one tensor the decoder re-reads "
                            "whole for every token"),
        "per_dispatch_measured": pd,
        "encoder_window": {}, "decoder_token": {}, "decoder_utterance": {},
    }

    # ---- encoder window -----------------------------------------------------------------
    enc = out["encoder_window"]
    for g, spec in ENC_GROUPS.items():
        enc[g] = group_sum(pd, spec)
    for g, macs in ENC_SOFT.items():
        enc[g] = dict(dispatches=0, bytes_w=0, bytes_a=0, out_bytes=0, macs=macs,
                      cyc_fill=None, steps=None, cyc_h0=None, cyc_place=None,
                      note="hart-0 software (no weights): the batched attention matmuls")
    enc["TOTAL"] = dict(
        bytes_w=sum(v["bytes_w"] for v in enc.values()),
        bytes_a=sum(v["bytes_a"] for v in enc.values()),
        out_bytes=sum(v["out_bytes"] for v in enc.values()),
        macs=sum(v["macs"] for v in enc.values()))
    enc["TOTAL"]["filled_bytes"] = enc["TOTAL"]["bytes_w"] + enc["TOTAL"]["bytes_a"]
    enc["check_against_engine_traffic"] = {
        "filled_bytes_here": enc["TOTAL"]["filled_bytes"],
        "filled_bytes_engine_traffic": tj["encoder_per_utterance"]["filled_bytes"],
        "agree": enc["TOTAL"]["filled_bytes"] == tj["encoder_per_utterance"]["filled_bytes"]}

    # ---- decoder token ------------------------------------------------------------------
    dec = out["decoder_token"]
    for g, spec in DEC_GROUPS.items():
        dec[g] = group_sum(pd, spec)
    # hart-0 software attention inside a token: cross is fixed, self grows with the context
    dec["dec_cross_attn_matmul"] = dict(
        dispatches=0, bytes_w=0, bytes_a=0, out_bytes=0,
        macs=LAYERS * 2 * HEADS * T_ENC * HD,
        note="hart-0 software: q.Kc and p.Vc against the 165 cached encoder frames")
    dec["dec_self_attn_matmul_per_context_token"] = dict(
        macs=LAYERS * 2 * HEADS * HD,
        note="hart-0 software, MACs per token ALREADY in the context; at 15 tokens the whole "
             "self-attention matmul is under 0.03 M MACs, 0.15 % of a token")
    dec["TOTAL"] = dict(
        bytes_w=sum(v.get("bytes_w", 0) for k, v in dec.items() if k != "TOTAL"),
        bytes_a=sum(v.get("bytes_a", 0) for k, v in dec.items() if k != "TOTAL"),
        out_bytes=sum(v.get("out_bytes", 0) for k, v in dec.items() if k != "TOTAL"),
        macs=sum(v.get("macs", 0) for k, v in dec.items()
                 if k not in ("TOTAL", "dec_self_attn_matmul_per_context_token")),
        cyc_fill=sum(v.get("cyc_fill") or 0 for k, v in dec.items() if k != "TOTAL"),
        cyc_h0=sum(v.get("cyc_h0") or 0 for k, v in dec.items() if k != "TOTAL"),
        cyc_place=sum(v.get("cyc_place") or 0 for k, v in dec.items() if k != "TOTAL"))
    dec["TOTAL"]["filled_bytes"] = dec["TOTAL"]["bytes_w"] + dec["TOTAL"]["bytes_a"]
    dec["TOTAL"]["gemm_ms"] = dec["TOTAL"]["cyc_h0"] / CLK * 1e3
    dec["check_against_engine_traffic"] = {
        "filled_bytes_here": dec["TOTAL"]["filled_bytes"],
        "filled_bytes_engine_traffic": tj["decoder_per_token"]["filled_bytes"],
        "agree": dec["TOTAL"]["filled_bytes"] == tj["decoder_per_token"]["filled_bytes"],
        "gemm_ms_here": dec["TOTAL"]["gemm_ms"],
        "gemm_ms_rocc_decoupled_8_9": 159.5}

    for g, spec in DEC_UTT_GROUPS.items():
        out["decoder_utterance"][g] = group_sum(pd, spec)

    # ---- the token's time, from section 8.9, so a lever can be priced end to end ---------
    token = dict(
        source="ROCC_DECOUPLED.md section 8.9, engine with 64-byte placement, nl+ew",
        gemm_ms=159.5, residue_ms=183.8, token_ms=343.4,
        residue_breakdown_ms=dict(softmax=67, attn_matmul=37, layernorm=30, silu_est=27,
                                  gate_mul_est=14, add=9),
        gemm_split_ms=dict(fill=dec["TOTAL"]["cyc_fill"] / CLK * 1e3,
                           placement=dec["TOTAL"]["cyc_place"] / CLK * 1e3,
                           rest=(dec["TOTAL"]["cyc_h0"] - dec["TOTAL"]["cyc_fill"]
                                 - dec["TOTAL"]["cyc_place"]) / CLK * 1e3),
        lm_head_ms=dec["lm_head"]["cyc_h0"] / CLK * 1e3,
        lm_head_fill_ms=dec["lm_head"]["cyc_fill"] / CLK * 1e3,
        label="measured parts (B25 run 8) composed by decode_compose.py; SiLU and the gate "
              "multiply are estimates, as section 8.9 says")
    out["decoder_token_time"] = token

    cross_kv_ms = out["decoder_utterance"]["dec_cross_attn_kv"]["cyc_h0"] / CLK * 1e3
    token["cross_kv_once_ms"] = cross_kv_ms
    token["tokens_per_utterance"] = a.tokens
    token["decoder_rtf"] = decoder_rtf(token["token_ms"], cross_kv_ms, a.tokens)
    token["decoder_rtf_check_8_9"] = 1.39

    # ---- lm_head levers -----------------------------------------------------------------
    base = pd["dec_lmhead"]
    lev = {"base": lmhead_image(VOCAB)}
    lev["base"].update(macs=VOCAB * D, cyc_h0=base["cyc_h0"], ms=base["cyc_h0"] / CLK * 1e3,
                       source="measured")
    lev["tokens_per_utterance"] = a.tokens
    lev["prune_rows"] = []
    for V in (32768, 16384, 8192, 4096, 2048, 1024, 512, 256, 128):
        im = lmhead_image(V)
        cy = lmhead_cycles(im["fetched_bytes"] + base["bytes_a"], V * D, base)
        tok_ms = token["token_ms"] - token["lm_head_ms"] + cy["cyc_h0"] / CLK * 1e3
        lev["prune_rows"].append(dict(
            V=V, fetched_bytes=im["fetched_bytes"], tiles=im["tiles"],
            token_bytes=dec["TOTAL"]["filled_bytes"] - base["bytes_w"] + im["fetched_bytes"],
            lm_head_ms=cy["cyc_h0"] / CLK * 1e3, token_ms=tok_ms,
            decoder_rtf=decoder_rtf(tok_ms, cross_kv_ms, a.tokens)))
    # low-rank: h -> (288 x r) -> (r x V).  Two dispatches: N=r K=288, then N=V K=r.
    lev["low_rank"] = []
    for V in (32768, 4096, 1024):
        for r in (16, 32, 48, 64, 96, 128, 192, 288):
            a_img = et.wimage_plan(r, D)
            b_img = et.wimage_plan(V, max(8, (r + 7) // 8 * 8))
            fb = a_img["bytes"] + b_img["bytes"]
            macs = r * D + V * r
            cy = lmhead_cycles(fb + 2 * base["bytes_a"], macs, base)
            # two dispatches, so one extra per-dispatch residue
            rest = base["cyc_h0"] - base["cyc_fill"] - base["cyc_place"]
            cyc = cy["cyc_h0"] + rest
            tok_ms = token["token_ms"] - token["lm_head_ms"] + cyc / CLK * 1e3
            lev["low_rank"].append(dict(V=V, r=r, fetched_bytes=fb, macs=macs,
                                        lm_head_ms=cyc / CLK * 1e3, token_ms=tok_ms,
                                        decoder_rtf=decoder_rtf(tok_ms, cross_kv_ms, a.tokens)))
    # int4 / mixed precision: bytes only.  NEEDS RTL -- flagged, not designed here.
    lev["sub_byte"] = []
    for bits in (8, 6, 4, 3):
        for V in (32768, 4096):
            K4 = max(8, int(math.ceil(D * bits / 8 / 8) * 8))
            im = et.wimage_plan(V, K4)
            cy = lmhead_cycles(im["bytes"] + base["bytes_a"], V * D, base)
            tok_ms = token["token_ms"] - token["lm_head_ms"] + cy["cyc_h0"] / CLK * 1e3
            lev["sub_byte"].append(dict(bits=bits, V=V, K_bytes=K4, fetched_bytes=im["bytes"],
                                        lm_head_ms=cy["cyc_h0"] / CLK * 1e3, token_ms=tok_ms,
                                        decoder_rtf=decoder_rtf(tok_ms, cross_kv_ms, a.tokens),
                                        needs_rtl=bits != 8))
    out["lm_head_levers"] = lev

    # ---- structural levers on the decoder ------------------------------------------------
    struct = []
    for label, nl, ff, hd_heads in (("as built", 6, FF_DEC, 8), ("FFN 1152->768", 6, 1536, 8),
                                    ("FFN 1152->576", 6, 1152, 8), ("heads 8->6", 6, FF_DEC, 6),
                                    ("dec layers 6->4", 4, FF_DEC, 8),
                                    ("dec layers 6->3", 3, FF_DEC, 8),
                                    ("layers 6->4 + FFN 1152->768", 4, 1536, 8)):
        d_head = D * hd_heads // HEADS   # hidden kept; heads only change the attention matmul
        qkvo = et.wimage_plan(D, D)["bytes"]
        f1 = et.wimage_plan(ff, D)["bytes"]
        f2 = et.wimage_plan(D, ff // 2)["bytes"]
        bw = nl * (6 * qkvo + f1 + f2) + base["bytes_w"]
        macs = nl * (6 * D * D + ff * D + D * ff // 2) + VOCAB * D
        struct.append(dict(label=label, dec_layers=nl, ffn_gated=ff, heads=hd_heads,
                           bytes_w_per_token=bw, macs_per_token=macs,
                           bytes_vs_base=bw / dec["TOTAL"]["bytes_w"]))
    out["decoder_structure"] = struct

    # ---- the same levers under the hardware already in flight -----------------------------
    # amdahl_hart0.json's decoder table gives the token, part by part, at today / T1 / T2 / T3 /
    # T4.  Split each part into "scales with the number of decoded rows in the dispatch" (array
    # steps, result placement, every hart-0 per-element op) and "does not" (the weight fill and
    # the per-dispatch commands), so a beam width and an lm_head of V' rows can be priced in
    # every scenario.  DERIVED from those measured/estimated parts.
    am = json.load(open(os.path.join(HERE, "amdahl_hart0.json")))
    dam = am["decoder_amdahl"]
    SCEN = ("today", "T1", "T2", "T3", "T4")
    FIXED = ("engine GEMMs: fill (port)", "engine GEMMs: commands and hand-off")
    scen = {}
    for s in SCEN:
        parts = {r["part"]: r["ms_per_token"][s] for r in dam["rows"]}
        scen[s] = {"parts": parts, "token_ms": sum(parts.values()),
                   "fixed_ms": sum(v for k, v in parts.items() if k in FIXED),
                   "scaling_ms": sum(v for k, v in parts.items() if k not in FIXED)}
    # lm_head's share of each component, from the measured dispatch
    lm = pd["dec_lmhead"]
    n_disp = 49
    lm_share = {
        "fill_ms": lm["cyc_fill"] / CLK * 1e3,
        "steps_ms": lm["steps"] / CLK * 1e3,
        "place_ms_today": lm["cyc_place"] / CLK * 1e3,
        "commands_ms": scen["today"]["parts"]["engine GEMMs: commands and hand-off"] / n_disp,
        "place_factor_T1plus": (dam["rows"][1]["ms_per_token"]["T1"]
                                / dam["rows"][1]["ms_per_token"]["today"]),
    }
    beam_rows, prune_rows2 = [], []
    for s in SCEN:
        for B in (1, 2, 5):
            # weight fill and commands are per dispatch, not per beam; everything else scales
            tok = scen[s]["fixed_ms"] + B * scen[s]["scaling_ms"]
            beam_rows.append(dict(scenario=s, beam=B, token_ms=tok,
                                  decoder_rtf=decoder_rtf(tok, cross_kv_ms, a.tokens),
                                  note="the beams share the weight image: one dispatch of npix = "
                                       "beam, so the fill is fetched once"))
        for V in (32768, 16384, 11000, 8451, 6144, 4096, 2436, 2048, 1024, 0):
            fb = lmhead_image(V)["fetched_bytes"] if V else 0
            place = lm_share["place_ms_today"] * (1.0 if s == "today" else lm_share["place_factor_T1plus"])
            lm_ms = (lm_share["fill_ms"] * fb / lm["bytes_w"]
                     + lm_share["steps_ms"] * V / VOCAB
                     + place * V / VOCAB
                     + (lm_share["commands_ms"] if V else 0.0))
            lm_ms0 = (lm_share["fill_ms"] + lm_share["steps_ms"] + place + lm_share["commands_ms"])
            tok = scen[s]["token_ms"] - lm_ms0 + lm_ms
            prune_rows2.append(dict(scenario=s, V=V, lm_head_ms=lm_ms, token_ms=tok,
                                    token_bytes=dec["TOTAL"]["filled_bytes"] - lm["bytes_w"] + fb,
                                    decoder_rtf=decoder_rtf(tok, cross_kv_ms, a.tokens),
                                    lm_head_share_of_token=lm_ms0 / scen[s]["token_ms"]))
    out["under_hardware_in_flight"] = {
        "source": "amdahl_hart0.json decoder_amdahl (measured parts today; every T1..T4 second "
                  "is that file's estimate), split into beam/row-scaling and fixed parts here",
        "scenario_token_ms": {s: scen[s]["token_ms"] for s in SCEN},
        "scenario_fixed_ms": {s: scen[s]["fixed_ms"] for s in SCEN},
        "lm_head_component_ms": lm_share,
        "beam": beam_rows, "lm_head_prune": prune_rows2}

    # ---- the B28 measured token: the same split, from the newer board record -----------------
    # Lab B28 (0x5A5A0028, md5 32d10e5d) re-measured every decoder dispatch with the T1 software
    # levers in the image and composed the token at 11 tokens.  It SUPERSEDES the 339.7 ms
    # "today" row above, which is the pre-T1 software.  amdahl_hart0.json ESTIMATED the T1 token
    # at 273.26 ms; B28 measures 276.32, a 1.1 % miss, which is the check on that column.
    b28p = os.path.join(HERE, "board", "b28_decode_compose.json")
    if os.path.exists(b28p):
        b28 = json.load(open(b28p))
        ps = b28["per_shape"]
        fill_ms = sum(ps[k]["fill_ms"] * (ps[k]["count_per_token"] or 0)
                      for k in ("dec_qkvo", "dec_fc1", "dec_fc2", "dec_lmhead"))
        gemm_ms = b28["gemm_per_token_ms"]["engine_place64"]
        res_ms = b28["residue_per_token_ms"]["B26/nl+ew"]
        # placement at 64-byte, from the same record's per-shape cycles
        place_cyc = {"dec_qkvo": 4719 * 36, "dec_fc1": 40976 * 6, "dec_fc2": 8763 * 6,
                     "dec_lmhead": 556320}
        place_ms = sum(place_cyc.values()) / CLK * 1e3
        steps_ms = dec["TOTAL"]["steps"] / CLK * 1e3 if dec["TOTAL"].get("steps") else             sum(pd[k]["steps"] * c for k, c in (("dec_qkvo", 36), ("dec_fc1", 6),
                                                ("dec_fc2", 6), ("dec_lmhead", 1))) / CLK * 1e3
        cmds_ms = gemm_ms - fill_ms - place_ms - steps_ms
        lm = pd["dec_lmhead"]
        lm_b28 = {"fill_ms": ps["dec_lmhead"]["fill_ms"],
                  "steps_ms": lm["steps"] / CLK * 1e3,
                  "place_ms": place_cyc["dec_lmhead"] / CLK * 1e3,
                  "commands_ms": cmds_ms / 49.0}
        cross_kv_b28 = b28["gemm_once_ms"]["engine_place64"]
        b28rows = {"fill": fill_ms, "placement": place_ms, "steps": steps_ms,
                   "commands": cmds_ms, "residue": res_ms}
        b28_tok = sum(b28rows.values())
        # the hardware in flight, applied to B28's OWN measured residue split rather than to
        # amdahl's pre-T1 one: each lane replaces its kind with amdahl's estimate for that lane
        rk = b28["residue_by_kind_ms"]["B26/nl+ew"]
        lane = {"T2": {"matmul": 0.542, "softmax": 0.482, "neg": 0.100},
                "T3": {"matmul": 0.542, "softmax": 0.482, "neg": 0.100, "layernorm": 0.335},
                "T4": {"matmul": 0.542, "softmax": 0.482, "neg": 0.100, "layernorm": 0.335,
                       "silu": 0.200, "mul": 0.200, "add": 0.150}}
        b28_scen = {"measured": res_ms}
        for sc, repl in lane.items():
            b28_scen[sc] = sum(repl.get(k, v) for k, v in rk.items())
        b28_place = {"measured": place_ms,
                     "T1_incremental": place_ms * (dam["rows"][1]["ms_per_token"]["T1"]
                                                   / dam["rows"][1]["ms_per_token"]["today"])}
        prune_b28, beam_b28 = [], []
        for V in (32768, 16384, 11000, 8451, 6144, 4096, 2436, 0):
            f = lmhead_image(V)["fetched_bytes"] / lm["bytes_w"] if V else 0.0
            fill_v = fill_ms - lm_b28["fill_ms"] * (1 - f)
            steps_v = steps_ms - lm_b28["steps_ms"] * (1 - V / VOCAB)
            place_v = place_ms - lm_b28["place_ms"] * (1 - V / VOCAB)
            cmds_v = cmds_ms - (0.0 if V else lm_b28["commands_ms"])
            fixed = fill_v + cmds_v
            scaling = steps_v + place_v + res_ms
            for B in (1, 2, 5):
                tok = fixed + B * scaling
                row = dict(V=V, beam=B, token_ms=tok, fixed_ms=fixed, scaling_ms=scaling,
                           token_bytes=dec["TOTAL"]["filled_bytes"] - lm["bytes_w"]
                           + lmhead_image(V)["fetched_bytes"] if V else
                           dec["TOTAL"]["filled_bytes"] - lm["bytes_w"],
                           decoder_rtf=(cross_kv_b28 + a.tokens * tok) / (WINDOW_S * 1e3))
                (prune_b28 if B == 1 else beam_b28).append(row)
                if B != 1 and V in (32768, 16384, 11000):
                    prune_b28.append(row)
        out["b28_measured"] = {
            "source": "modelblaster/moonshine/board/b28_decode_compose.json, Lab B28, "
                      "0x5A5A0028 md5 32d10e5d, T1 software levers in the image, 11 tokens",
            "supersedes": "the 339.7 ms 'today' token above, which is the pre-T1 software",
            "token_ms_measured_composition": b28["token_ms"]["B26/nl+ew"]["engine_place64"],
            "token_ms_rebuilt_here": b28_tok,
            "amdahl_T1_estimate_ms": scen["T1"]["token_ms"],
            "amdahl_T1_miss": scen["T1"]["token_ms"] / b28_tok - 1.0,
            "split_ms": b28rows, "lm_head_ms": lm_b28,
            "lm_head_share_of_token": sum(lm_b28.values()) / b28_tok,
            "cross_kv_once_ms": cross_kv_b28,
            "decoder_rtf": (cross_kv_b28 + a.tokens * b28_tok) / (WINDOW_S * 1e3),
            "rows": prune_b28,
            "residue_ms_under_lanes": b28_scen,
            "placement_ms": b28_place,
            "token_ms_under_lanes": {
                sc: fill_ms + b28_place["T1_incremental"] + steps_ms + cmds_ms + r
                for sc, r in b28_scen.items()},
            "decoder_rtf_under_lanes": {
                sc: (cross_kv_b28 + a.tokens * (fill_ms + b28_place["T1_incremental"]
                                                + steps_ms + cmds_ms + r)) / (WINDOW_S * 1e3)
                for sc, r in b28_scen.items()},
            "stacks": [
                dict(scenario=sc, V=V, beam=B,
                     token_ms=(fill_ms - lm_b28["fill_ms"]
                               * (1 - (lmhead_image(V)["fetched_bytes"] / lm["bytes_w"] if V else 0.0))
                               + cmds_ms)
                     + B * ((steps_ms - lm_b28["steps_ms"] * (1 - V / VOCAB))
                            + (b28_place["T1_incremental"]
                               - lm_b28["place_ms"] * b28_place["T1_incremental"] / place_ms
                               * (1 - V / VOCAB)) + r),
                     decoder_rtf=(cross_kv_b28 + a.tokens * (
                         (fill_ms - lm_b28["fill_ms"]
                          * (1 - (lmhead_image(V)["fetched_bytes"] / lm["bytes_w"] if V else 0.0))
                          + cmds_ms)
                         + B * ((steps_ms - lm_b28["steps_ms"] * (1 - V / VOCAB))
                                + (b28_place["T1_incremental"]
                                   - lm_b28["place_ms"] * b28_place["T1_incremental"] / place_ms
                                   * (1 - V / VOCAB)) + r))) / (WINDOW_S * 1e3))
                for sc, r in b28_scen.items() for V in (32768, 16384, 11000) for B in (1, 2)],
            "lanes_note": "the lane substitutions are amdahl_hart0.json's ESTIMATES applied to "
                          "B28's MEASURED residue split; the placement column also takes the T1 "
                          "incremental-placement factor, which B28's 64-byte runs do not have",
            "note": "the residue still contains SiLU and the gate multiply as estimates, and the "
                    "decoder is still COMPOSED from per-dispatch measurements -- it has not run"}

    # ---- stacks: the prune and the beam together, which is where they stop being independent --
    stacks = []
    for s in SCEN:
        parts = scen[s]["parts"]
        lm_place = lm_share["place_ms_today"] * (1.0 if s == "today"
                                                 else lm_share["place_factor_T1plus"])
        for V in (32768, 16384, 11000, 4096):
            f = lmhead_image(V)["fetched_bytes"] / lm["bytes_w"] if V else 0.0
            fill = parts["engine GEMMs: fill (port)"] - lm_share["fill_ms"] * (1 - f)
            steps = parts["engine GEMMs: array steps"] - lm_share["steps_ms"] * (1 - V / VOCAB)
            place = (parts["engine GEMMs: result placement (hart 1)"]
                     - lm_place * (1 - V / VOCAB))
            cmds = parts["engine GEMMs: commands and hand-off"]
            residue = sum(v for k, v in parts.items() if k not in FIXED
                          and not k.startswith("engine GEMMs"))
            fixed = fill + cmds
            scaling = steps + place + residue
            for B in (1, 2, 5):
                tok = fixed + B * scaling
                stacks.append(dict(scenario=s, V=V, beam=B, token_ms=tok,
                                   fixed_ms=fixed, scaling_ms=scaling,
                                   decoder_rtf=decoder_rtf(tok, cross_kv_ms, a.tokens)))
    out["under_hardware_in_flight"]["stacks"] = stacks
    out["under_hardware_in_flight"]["stacks_note"] = (
        "the vocabulary prune takes bytes out of the FIXED half of a token (the weight fill, "
        "which the beams share) and the beam multiplies only the SCALING half, so the two levers "
        "work on opposite halves and stacking them is cheaper than either implies alone")

    # ---- structural levers, both sides, on the planner and the measured component split ------
    # Each candidate is priced the way model_base.py prices base: exact bytes and MACs from
    # engine_traffic's planner on the changed shape, and time by scaling each MEASURED component
    # of the encoder (amdahl_hart0.json rows) and of a token (decoder_amdahl rows) by the element
    # count that drives it.  DERIVED.
    T = T_ENC
    p1 = (64000 - 127) // 64 + 1
    p2 = (p1 - 7) // 3 + 1

    def roll(spec):
        tot = dict(bytes_w=0, bytes_a=0, out_bytes=0, macs=0, dispatches=0)
        for N, K, npix, astride, count in spec:
            pl = et.run_plan(et.wimage_plan(N, K), npix, astride)
            tot["bytes_w"] += count * pl["bytes_w"]
            tot["bytes_a"] += count * pl["bytes_a"]
            tot["out_bytes"] += count * pl["out_bytes"]
            tot["macs"] += count * npix * N * K
            tot["dispatches"] += count
        return tot

    def enc_spec(ff, L=LAYERS, d=D, heads=HEADS):
        # pruning heads keeps the hidden width d and shrinks the attention inner width to
        # heads x head_dim: q, k, v emit ha outputs and o_proj reduces over ha
        ha = heads * HD
        return [(d, 128, p1, 8, 1), (2 * d, d * 7, p2, d * 7 // 8, 1),
                (d, 2 * d * 3, T, 2 * d * 3 // 8, 1),
                (ha, d, T, d // 8, 3 * L), (d, ha, T, ha // 8, L),
                (ff, d, T, d // 8, L), (d, ff, T, ff // 8, L)]

    def dec_spec(ff, L=LAYERS, d=D, V=VOCAB, heads=HEADS):
        ha = heads * HD
        return [(ha, d, 1, d // 8, 3 * L), (d, ha, 1, ha // 8, L),     # self q,k,v then o
                (ha, d, 1, d // 8, L), (d, ha, 1, ha // 8, L),         # cross q then o
                (2 * ff, d, 1, d // 8, L), (d, ff, 1, ff // 8, L), (V, d, 1, d // 8, 1)]

    erows = {r["part"]: (r["software_seconds_after"] if r.get("software_seconds_after")
                         is not None else r["seconds_today"]) for r in am["rows"]}
    erows["NCHW<->NHWC staging (stem)"] = 0.0
    enc0, dec0 = roll(enc_spec(FF_ENC)), roll(dec_spec(FF_ENC))
    assert enc0["bytes_w"] == 8519680, enc0["bytes_w"]
    assert dec0["bytes_w"] == 19988480, dec0["bytes_w"]
    enc_s0 = sum(erows.values())
    K_ENC = 4.134 / (enc_s0 / 4.0)

    def price_struct(label, ff, ndl, heads, V=VOCAB, nel=LAYERS):
        eb = roll(enc_spec(ff, nel, heads=heads))
        db = roll(dec_spec(ff, ndl, V=V, heads=heads))
        hr, lr_e, lr_d = heads / HEADS, nel / LAYERS, ndl / LAYERS
        edrv = {"softmax": lr_e * hr, "attention scores q.k (matmul_b)": lr_e * hr,
                "attention weighted sum p.v (matmul_b)": lr_e * hr, "LayerNorm": lr_e,
                "permute (24 attention + 1 stem)": lr_e, "rotary (q, k)": lr_e * hr,
                "NCHW<->NHWC staging (stem)": 1.0, "GELU LUT (stem 2 + MLP 6)": ff / FF_ENC,
                "GroupNorm (stem)": 1.0, "residual adds": lr_e, "tanh LUT (stem)": 1.0,
                "engine dispatches: linears (hart-0 wall)": eb["macs"] / enc0["macs"],
                "engine dispatches: stem convs (hart-0 wall, no staging)": 1.0}
        es = sum(erows[k] * edrv[k] for k in edrv)
        ddrv = {"engine GEMMs: fill (port)": db["bytes_w"] / dec0["bytes_w"],
                "engine GEMMs: array steps": db["macs"] / dec0["macs"],
                "engine GEMMs: result placement (hart 1)": db["out_bytes"] / dec0["out_bytes"],
                "engine GEMMs: commands and hand-off": db["dispatches"] / dec0["dispatches"],
                "softmax (6 self, 6 cross)": lr_d * hr, "attention matmuls": lr_d * hr,
                "LayerNorm": lr_d, "rotary": lr_d * hr, "SiLU": lr_d * ff / FF_ENC,
                "gate multiply": lr_d * ff / FF_ENC, "residual adds": lr_d}
        tms = {s: sum(v[s] * ddrv[k] for k, v in
                      {r["part"]: r["ms_per_token"] for r in dam["rows"]}.items())
               for s in SCEN}
        return dict(label=label, ffn=ff, dec_layers=ndl, enc_layers=nel, heads=heads, vocab=V,
                    enc_bytes_w=eb["bytes_w"], enc_macs=eb["macs"],
                    token_bytes_w=db["bytes_w"], token_macs=db["macs"],
                    token_bytes_vs_base=db["bytes_w"] / dec0["bytes_w"],
                    params=27092736 - (VOCAB - V) * D
                    - (FF_ENC - ff) * D * 2 * (LAYERS - 0) - (FF_ENC - ff) * D * 3 * 0,
                    encoder_rtf=es / 4.0 * K_ENC,
                    encoder_rtf_T4=am["scenarios"][4]["rtf"] * (es / enc_s0),
                    token_ms=tms,
                    decoder_rtf={s: decoder_rtf(tms[s], cross_kv_ms, a.tokens) for s in SCEN})

    out["structural_levers"] = [
        price_struct("as built", FF_ENC, LAYERS, HEADS),
        price_struct("FFN 1152 -> 768", 768, LAYERS, HEADS),
        price_struct("FFN 1152 -> 576", 576, LAYERS, HEADS),
        price_struct("heads 8 -> 6", FF_ENC, LAYERS, 6),
        price_struct("decoder layers 6 -> 4", FF_ENC, 4, HEADS),
        price_struct("decoder layers 6 -> 3", FF_ENC, 3, HEADS),
        price_struct("lm_head rows -> 11,000", FF_ENC, LAYERS, HEADS, V=11000),
        price_struct("lm_head 11,000 + FFN 768", 768, LAYERS, HEADS, V=11000),
        price_struct("lm_head 11,000 + FFN 768 + dec layers 4", 768, 4, HEADS, V=11000),
    ]


    with open(a.json, "w") as f:
        json.dump(out, f, indent=1)
    print(f"wrote {a.json}")
    e, d = out["encoder_window"], out["decoder_token"]
    print(f"encoder window: {e['TOTAL']['filled_bytes']/1e6:.2f} MB filled, "
          f"{e['TOTAL']['macs']/1e6:.1f} M MACs (check {e['check_against_engine_traffic']['agree']})")
    print(f"decoder token : {d['TOTAL']['filled_bytes']/1e6:.2f} MB filled, "
          f"{d['TOTAL']['macs']/1e6:.1f} M MACs (check {d['check_against_engine_traffic']['agree']}), "
          f"GEMM {d['TOTAL']['gemm_ms']:.1f} ms")
    print(f"lm_head       : {d['lm_head']['bytes_w']/1e6:.2f} MB, "
          f"{100*d['lm_head']['bytes_w']/d['TOTAL']['bytes_w']:.1f} % of the token's weight bytes, "
          f"{token['lm_head_ms']:.1f} ms of {token['token_ms']} ms")
    print(f"decoder RTF   : {token['decoder_rtf']:.3f} at {a.tokens} tokens "
          f"(section 8.9 composes 1.39); cross K,V once {cross_kv_ms:.1f} ms")


if __name__ == "__main__":
    main()
