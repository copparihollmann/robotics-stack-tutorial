#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""What the RoCC engine moves over the bus for Moonshine, per dispatch: bytes FILLED (weights
and activations, Gets) and bytes DRAINED (results, Puts), and where each dispatch's cycles go.

For the memory-bus data path (ROCC_DECOUPLED.md s8.16): the bus side needs the traffic, split
by client, for the encoder and for one decoder token.

SOURCES, and how each number is labelled in the output:
  MEASURED   Lab B25 run 8 (fpga/pynq-z2/rtl_study/roccmoon/board/b25_run8_run.json,
             0x5A5A0010, md5 7475c1b2): one dispatch per shape, engine counters and
             mbxr_stats read on the board -- bytes_a/bytes_w/fill_beats/out_bytes and
             cyc_fill/steps/cyc_busy/cyc_wait/cyc_place.  The encoder's linear shapes and the
             decoder's shapes are exactly these.
  MEASURED   Lab B26 (b26_nhwc_run.json): the whole encoder's mbxr_rt_stats totals
             (loads, bytes_act, bytes_wgt, fill_beats, cyc_fill, cycles_h0/h1, stage, image).
  PLANNED    the stem convolutions have no per-dispatch counters on the board.  Their loads
             and bytes come from mbxr_run's tile plan, re-executed here line for line
             (mbxr.c), and the plan is checked twice: against B25's measured per-shape
             loads/bytes for the linears, and against B26's encoder totals.
  COMPOSED   per-token and per-utterance sums of the above, by the dispatch counts of the
             model (encoder: 24 q/k/v/o, 6 fc1, 6 fc2, 3 stem convs; decoder per token: 36
             q/k/v/o (self q/k/v/o + cross q/o), 6 fc1, 6 fc2, 1 lm_head; per utterance: 12
             cross-attention k/v on the 165 encoder frames).

    python3 engine_traffic.py --json engine_traffic.json
"""
from __future__ import annotations

import argparse
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
B25 = os.path.join(ROOT, "fpga/pynq-z2/rtl_study/roccmoon/board/b25_run8_run.json")
B26 = os.path.join(HERE, "board", "b26_nhwc_run.json")
NCH, BUF_WORDS = 4, 1024
CLK = 34482759.0


def wimage_plan(N, K):
    G = K // 8
    quads = (N + NCH - 1) // NCH
    Q = min(BUF_WORDS // (G + 1), quads)
    lgpw = max(3, (Q * (G + 1) - 1).bit_length())
    tiles = (quads + Q - 1) // Q
    return dict(N=N, K=K, G=G, Q=Q, lgpw=lgpw, tiles=tiles, bytes=tiles * NCH * (8 << lgpw))


def run_plan(img, npix, astride, in_off=0):
    """mbxr_run's tile loop, counting what it issues.  in_off = in_pa mod 64."""
    G, N, K = img["G"], img["N"], img["K"]
    P = min((BUF_WORDS - 7 - G) // astride + 1, npix)
    tiles_a = (npix + P - 1) // P
    tiles_w = img["tiles"]
    quads = (N + NCH - 1) // NCH
    act_bytes = (npix - 1) * 8 * astride + K
    wgt_bytes = img["bytes"]
    w_outer = (tiles_w * act_bytes + wgt_bytes) <= (tiles_a * wgt_bytes + act_bytes)
    total = 0
    for t in range(tiles_w):
        qt = min(quads - t * img["Q"], img["Q"])
        for a in range(tiles_a):
            total += min(npix - a * P, P) * qt * NCH
    pad = (64 - total % 64) % 64
    st = dict(loads_a=0, loads_w=0, bytes_a=0, bytes_w=0, pairs=0)
    a_in, w_in = [-1, -1], [-1, -1]
    plane_bytes = 8 << img["lgpw"]

    def act_blocks(a):
        first = in_off + a * P * 8 * astride
        last = first + (P - 1) * 8 * astride + K
        src = first & ~63
        return (last - src + 63) // 64

    def load_act(a, b):
        a_in[b] = a
        st["loads_a"] += 1
        st["bytes_a"] += act_blocks(a) * 64

    def load_wgt(t, b):
        w_in[b] = t
        st["loads_w"] += 1
        st["bytes_w"] += NCH * plane_bytes

    def find(arr, x):
        return 0 if arr[0] == x else (1 if arr[1] == x else -1)

    outer_n, inner_n = (tiles_w, tiles_a) if w_outer else (tiles_a, tiles_w)
    cur_ab = cur_wb = -1
    for o in range(outer_n):
        for i in range(inner_n):
            a, t = (i, o) if w_outer else (o, i)
            ab, wb = find(a_in, a), find(w_in, t)
            if ab < 0:
                b = 1 if cur_ab == 0 else 0
                load_act(a, b)
                ab = b
            if wb < 0:
                b = 1 if cur_wb == 0 else 0
                load_wgt(t, b)
                wb = b
            st["pairs"] += 1
            cur_ab, cur_wb = ab, wb
            ni, no = i + 1, o
            if ni == inner_n:
                ni, no = 0, o + 1
            if no < outer_n:
                na, nt = (ni, no) if w_outer else (no, ni)
                if find(a_in, na) < 0:
                    load_act(na, 0 if cur_ab else 1)
                elif find(w_in, nt) < 0:
                    load_wgt(nt, 0 if cur_wb else 1)
    if pad:
        st["pairs"] += 1
    st.update(out_bytes=total + pad, tiles_a=tiles_a, tiles_w=tiles_w, P=P, w_outer=bool(w_outer),
              image_bytes=img["bytes"], results=total)
    return st


# (name, kind, N out, K bytes per window, npix, astride words, count, where)
ENC = [
    ("stem_conv1", "conv", 288, 128, 999, 8, 1, "enc"),      # IC 1 KW 127 (padded 128) SW 64
    ("stem_conv2", "conv", 576, 2016, 331, 108, 1, "enc"),   # IC 288 KW 7 SW 3
    ("stem_conv3", "conv", 288, 1728, 165, 144, 1, "enc"),   # IC 576 KW 3 SW 2
    ("enc_qkvo", "linear", 288, 288, 165, 36, 24, "enc"),
    ("enc_fc1", "linear", 1152, 288, 165, 36, 6, "enc"),
    ("enc_fc2", "linear", 288, 1152, 165, 144, 6, "enc"),
]
DEC = [
    ("dec_qkvo", "linear", 288, 288, 1, 36, 36, "token"),
    ("dec_fc1", "linear", 2304, 288, 1, 36, 6, "token"),
    ("dec_fc2", "linear", 288, 1152, 1, 144, 6, "token"),
    ("dec_lmhead", "linear", 32768, 288, 1, 36, 1, "token"),
    ("enc_qkvo", "linear", 288, 288, 165, 36, 12, "utterance"),   # cross-attention k, v
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    b25 = json.load(open(B25))
    meas = {s["name"]: s for s in b25["shapes"]}
    chunk = {s["name"]: s for s in b25.get("shapes_place_chunk", [])}
    b26 = json.load(open(B26))
    enc_tot = b26["models"]["enc_ew_eng_smx2"]["roccmoon_stats"]["total"]

    def row(name, kind, N, K, npix, astride, count, where):
        img = wimage_plan(N, K)
        plans = [run_plan(img, npix, astride, off) for off in range(0, 64, 8)]
        p0 = plans[0]
        r = {"name": name, "kind": kind, "count": count, "per": where, "N": N, "K": K, "npix": npix,
             "astride_words": astride,
             "planned": {k: p0[k] for k in ("loads_a", "loads_w", "bytes_a", "bytes_w", "pairs", "out_bytes",
                                            "tiles_a", "tiles_w", "P", "w_outer", "image_bytes")},
             "planned_bytes_a_range_over_input_offset": [min(p["bytes_a"] for p in plans),
                                                         max(p["bytes_a"] for p in plans)]}
        m = meas.get(name)
        if m and m["M"] == npix:
            c = chunk.get(name, {})
            r["measured_b25_run8"] = {
                "bytes_w": m["bytes_w"], "bytes_a": m["bytes_a"], "loads_w": m["loads_w"], "loads_a": m["loads_a"],
                "fill_beats": m["fill_beats"], "out_bytes": m["out_bytes"], "pairs": m["pairs"],
                "cyc_fill": m["cyc_fill"], "steps": m["steps"], "cyc_busy": m["cyc_busy"],
                "cyc_wait_h1": c.get("cyc_wait", m["cyc_wait"]), "cyc_place_h1_bytewise": m["cyc_place"],
                "cyc_place_h1_chunk64": c.get("cyc_place"), "eng_h1_chunk64": c.get("eng_cycles"),
                "eng_h0_chunk64": c.get("eng_h0_cycles"), "core_cycles_mbp": m["core_cycles"],
                "img_build_once": m["img_build_cycles"]}
            r["plan_matches_measured"] = all(p0[k] == m[j] for k, j in (("loads_a", "loads_a"), ("loads_w", "loads_w"),
                                                                        ("bytes_w", "bytes_w"), ("pairs", "pairs"),
                                                                        ("out_bytes", "out_bytes"))) and \
                r["planned_bytes_a_range_over_input_offset"][0] <= m["bytes_a"] <= r["planned_bytes_a_range_over_input_offset"][1]
        return r

    enc = [row(*e) for e in ENC]
    dec = [row(*d) for d in DEC]

    def src(r, k):
        mm = r.get("measured_b25_run8")
        if mm is not None and k in mm:
            return mm[k], "measured"
        return r["planned"][k], "planned"

    def total(rows, per):
        t = {"bytes_w": 0, "bytes_a": 0, "out_bytes": 0, "loads_w": 0, "loads_a": 0, "pairs": 0}
        labels = set()
        for r in rows:
            if r["per"] != per:
                continue
            for k in t:
                v, lab = src(r, k)
                t[k] += v * r["count"]
                labels.add(lab)
        t["filled_bytes"] = t["bytes_w"] + t["bytes_a"]
        t["label"] = "composed from " + " and ".join(sorted(labels))
        return t

    enc_total = total(enc, "enc")
    enc_check = {k: {"composed": enc_total[k], "b26_measured": enc_tot[j]}
                 for k, j in (("bytes_w", "bytes_wgt"), ("bytes_a", "bytes_act"), ("loads_w", "loads_wgt"),
                              ("loads_a", "loads_act"), ("pairs", "pairs"))}
    tok = total(dec, "token")
    utt = total(dec, "utterance")

    # where the cycles go, per dispatch kind (B25 run 8, measured, 64-byte placement)
    split = {}
    for r in enc + dec:
        mm = r.get("measured_b25_run8")
        if not mm or r["name"] in split:
            continue
        h1 = mm["eng_h1_chunk64"]
        split[r["name"]] = {
            "label": "measured, Lab B25 run 8, one dispatch",
            "engine_busy": mm["cyc_busy"], "fill": mm["cyc_fill"], "steps": mm["steps"],
            "drain_and_pipeline_beyond_steps_and_fill": mm["cyc_busy"] - max(mm["steps"], mm["cyc_fill"]),
            "hart1_total": h1, "hart1_wait": mm["cyc_wait_h1"], "hart1_place_chunk64": mm["cyc_place_h1_chunk64"],
            "hart1_other": h1 - mm["cyc_wait_h1"] - mm["cyc_place_h1_chunk64"] if h1 else None,
            "hart0_wall": mm["eng_h0_chunk64"], "handoff": mm["eng_h0_chunk64"] - h1 if h1 else None,
            "fill_bytes_per_cycle": round((mm["bytes_w"] + mm["bytes_a"]) / mm["cyc_fill"], 3),
            "results_bytes_per_dispatch": mm["out_bytes"],
        }
    b26_split = {"label": "measured, Lab B26 (0x5A5A0010, 2026-09-17 08:57), whole encoder, enc_ew_eng_smx2",
                 **{k: enc_tot[k] for k in ("cycles_h0", "cycles_h1", "cycles_stage", "image_cycles", "cyc_fill",
                                            "fill_beats", "polls", "loads_act", "loads_wgt", "bytes_act", "bytes_wgt",
                                            "pairs")},
                 "note": "B26 does not print cyc_wait/cyc_place/steps per image; the per-kind split is B25's"}
    out = {"what": __doc__.strip().splitlines()[0], "clock_hz": CLK, "sources": {"b25_run8": os.path.relpath(B25, ROOT),
                                                                            "b26": os.path.relpath(B26, ROOT)},
           "encoder_dispatches": enc, "decoder_dispatches": dec,
           "encoder_per_utterance": enc_total, "encoder_check_against_b26": enc_check,
           "decoder_per_token": tok, "decoder_per_utterance_cross_kv": utt,
           "cycle_split_per_kind_b25": split, "cycle_split_encoder_b26": b26_split}
    json.dump(out, open(a.json, "w"), indent=1)
    print("encoder, per 4 s utterance:", {k: enc_total[k] for k in ("bytes_w", "bytes_a", "filled_bytes", "out_bytes")})
    print("  check against B26:", enc_check)
    print("decoder, per token:", {k: tok[k] for k in ("bytes_w", "bytes_a", "filled_bytes", "out_bytes")})
    print("decoder, per utterance (cross k/v):", {k: utt[k] for k in ("bytes_w", "bytes_a", "filled_bytes", "out_bytes")})
    for r in enc + dec:
        print(f'  {r["name"]:11s} x{r["count"]:<3d}/{r["per"]:9s} planned {r["planned"]}  matches B25: {r.get("plan_matches_measured")}')
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
