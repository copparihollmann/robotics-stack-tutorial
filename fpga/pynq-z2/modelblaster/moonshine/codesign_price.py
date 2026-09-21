#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Moonshine's encoder with the int8 fidelity fixes: WER against RTF against engine hardware.

For each quantisation candidate of quant_fix.py (WER from the float simulation on dev-clean;
test-clean only for finalists run once), price the encoder's cycles for a 4 s window under
three engine assumptions:

  (a)   today's engine (0x5A5A0010): int8 x int8 MACs, one per-tensor requantise per dispatch.
        int16 work runs on hart 0 in software, or as SPLIT DISPATCHES (hi/lo input bytes,
        multi-range outputs, row groups), all of which keep the contract.
  (b1)  a width-selectable engine: int16 x int8 dispatches on the same 32 MAC DSPs (4 lanes x
        4 int16 elements per 64-bit word = 16 MAC/cycle), int8 unchanged at 32; a wider
        requantise; per-channel requant from the planar row header word (bias in the low
        32 bits, multiplier and shift in the high 32, which today are unused).
  (b2)  as (b1) with the int16 lanes doubled: int16 x int8 at 32 MAC/cycle.

EVERY COST IS BUILT FROM A MEASURED PART WHERE ONE EXISTS, AND SAYS SO:
  measured  Lab B26 (b26_roccmoon_run.json): software ops' cycles per kind in ew_eng, and
            MBP int8 cycles/MAC (ew_bigconv).
            Lab B25 run 8 (b25_run8_run.json): each encoder linear shape's engine dispatch,
            split into array steps, fill-busy cycles, result placement (64-byte runs) and the
            rest; and the stem kernel files (engine plus hart-0 staging).
  est       every multiplier on those parts that nothing has measured: int16 software kernels,
            per-channel adds, hi/lo decomposition, multi-range combination, bytes that double
            with width.  Each is named in COST with its derivation.

RTF = cycles / 34,482,759 / 4 s.  Steady state (the one-time weight-image build is excluded
and reported separately in ROCC_DECOUPLED.md s8.8).

    python3 codesign_price.py --json codesign_price.json
"""
from __future__ import annotations

import argparse
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CLK = 34482759.0
LE = 6
EL_T, D, FF = 165, 288, 1152

B26 = os.path.join(HERE, "board", "b26_roccmoon_run.json")
B25 = os.path.join(ROOT, "rtl_study", "roccmoon", "board", "b25_run8_run.json")


def U(v, measured, src):
    return {"v": float(v), "measured": measured, "src": src}


def load():
    b26 = json.load(open(B26))
    ew = b26["models"]["enc_ew_eng"]["per_kind"]
    big = b26["models"]["enc_ew_bigconv"]["per_kind"]
    b25 = json.load(open(B25))
    chunk = {s["name"]: s for s in b25["shapes_place_chunk"]}
    shapes = {s["name"]: dict(s, **{"h0_64": chunk[s["name"]]["eng_h0_cycles"],
                                    "place_64": chunk[s["name"]]["cyc_place"]}) for s in b25["shapes"]}
    kf = {k["name"]: k for k in b25["kernel_files"]}
    return ew, big, shapes, kf


def cost_table(ew, big):
    c = {}
    c["mbp_linear_c_mac"] = U(big["linear_s8"]["cycles_per_mac"], True, "B26 ew_bigconv linear_s8")
    c["mbp_conv_c_mac"] = U(big["conv2d_s8"]["cycles_per_mac"], True, "B26 ew_bigconv conv2d_s8")
    for k in ("softmax_s8", "matmul_b_s8", "layernorm_s8", "permute4_s8", "rope_s8", "gelu_s8",
              "groupnorm_s8", "add_s8", "tanh_s8"):
        c["sw8_" + k] = U(ew[k]["cycles"], True, f"B26 ew_eng {k}, whole encoder")
        c["sw8_" + k + "_el"] = U(ew[k]["cycles_per_element"], True, f"B26 ew_eng {k} cycles/element")
    # --- estimates ---------------------------------------------------------------------
    c["sw16_dot_c_mac"] = U(2 * big["conv2d_s8"]["cycles_per_mac"] + 0.3, False,
                            "ESTIMATE: int16 x int8 dot on MBP as two DOT8 passes (hi, lo-128) + a per-pixel combine")
    c["sw16_lut_el"] = U(2.0 * ew["gelu_s8"]["cycles_per_element"], False,
                         "ESTIMATE: 65,536-entry int16 LUT, 2x the measured int8 LUT for its cache misses")
    c["sw16_gn_el"] = U(1.2 * ew["groupnorm_s8"]["cycles_per_element"], False, "ESTIMATE: 1.2x int8 GroupNorm")
    c["sw16_ln_el"] = U(1.2 * ew["layernorm_s8"]["cycles_per_element"], False,
                        "ESTIMATE: 1.2x int8 LayerNorm (int16 or per-channel input dequant)")
    c["sw16_add_el"] = U(1.2 * ew["add_s8"]["cycles_per_element"], False, "ESTIMATE: 1.2x int8 add")
    c["swpc_add_el"] = U(1.3 * ew["add_s8"]["cycles_per_element"], False,
                         "ESTIMATE: 1.3x int8 add: a multiplier per channel instead of per tensor")
    c["sw16_softmax"] = U(1.3, False, "ESTIMATE: 1.3x int8 softmax for int16 scores")
    c["sw16_matmul_c_mac"] = U(4 * ew["matmul_b_s8"]["cycles_per_mac"], False,
                               "ESTIMATE: int16 x int16 on MBP as four DOT8 passes")
    c["sw16_rope"] = U(1.5, False, "ESTIMATE: 1.5x int8 rope")
    c["sw16_permute"] = U(1.5, False, "ESTIMATE: 1.5x int8 permute (bytes double)")
    c["hilo_split_el"] = U(10.0, False, "ESTIMATE: hart-0 pass splitting an int16 tensor into two int8 tensors, per element")
    c["multirange_el"] = U(8.0, False, "ESTIMATE: hart-0 combine per output element per extra range")
    c["stage16"] = U(2.0, False, "ESTIMATE: NCHW->NHWC staging of an int16 stem tensor, 2x the measured int8 staging")
    return c


def engine_linear(shp, macs_rate=32.0, in_w=1, out_w=1, G=1, n=1):
    """one encoder linear shape, n dispatches of it, from its measured B25 run-8 parts"""
    s = shp
    steps = s["macs"] / macs_rate
    fill = s["cyc_fill"] * (s["bytes_a"] * in_w + s["bytes_w"]) / max(1, s["bytes_a"] + s["bytes_w"])
    place = s["place_64"] * out_w
    rest = s["h0_64"] - s["steps"] - s["cyc_fill"] - s["place_64"]
    per = G * (fill + rest) + steps + place
    return n * per


def engine_conv(kf, conv, macs_rate=32.0, in_w=1, out_w=1, G=1, ranges=1, halves=1, stage_mult=1.0, place_mult=1.0):
    """a stem conv from its measured kernel-file line: hart-0 staging + engine.  The engine part
    minus array steps is split half fill, half placement (ESTIMATE: no fill counter on the
    kernel-file line)."""
    k = kf[conv]
    stage = k["stage_cycles_last"] * stage_mult
    eng = k["kernel_cycles"] - k["stage_cycles_last"]
    steps32 = k["macs"] / 32.0
    rest = max(0.0, eng - steps32)
    fill, place = 0.5 * rest * in_w, 0.5 * rest * out_w * place_mult
    D = G * ranges * halves
    return stage + D * fill + (k["macs"] / macs_rate) * ranges * halves + D * place / G


def price(desc, hw, C, ew, shapes, kf):
    """cycles for one candidate description under one hardware assumption; returns (cycles,
    parts, estimate_used, realizable)"""
    parts, est = {}, False
    nhwc = 0.0 if desc.get("nhwc") else 1.0
    pm = 0.0 if desc.get("drain_final_order") else 1.0
    stem16 = desc.get("stem") == "int16"
    all16 = desc.get("all16", False)
    wmode = desc.get("weights", "pt")          # pt | pr (per-row) | rg4
    adds = desc.get("adds", "int8")            # int8 | pc | int16
    impl_a = desc.get("stem_impl_a")           # sw16 | split:G:R
    G_tr = 4 if (wmode in ("pr", "rg4") and hw == "a") else 1
    if wmode == "pr" and hw == "a" and not desc.get("pr_as_groups_ok", True):
        return None
    # ---- transformer linears ----
    width = 2 if all16 else 1
    if hw == "a" and all16:
        # int16 linears cannot dispatch on today's engine: software on hart 0
        macs = sum(shapes[n]["macs"] * m for n, m in (("enc_qkvo", 24), ("enc_fc1", 6), ("enc_fc2", 6)))
        parts["linears"] = macs * C["sw16_dot_c_mac"]["v"]
        est = True
    else:
        rate = 32.0 if (not all16 or hw == "b2") else 16.0
        parts["linears"] = sum(engine_linear(shapes[n], rate, width, width, G_tr, m)
                               for n, m in (("enc_qkvo", 24), ("enc_fc1", 6), ("enc_fc2", 6)))
        est = est or all16 or G_tr > 1
    # ---- stem convs ----
    if not stem16 and not all16:
        parts["stem_convs"] = sum(engine_conv(kf, c, G=(4 if G_tr > 1 else 1), stage_mult=nhwc, place_mult=pm) for c in ("stem_conv1", "stem_conv2", "stem_conv3"))
        est = est or G_tr > 1
    elif hw == "a":
        if impl_a == "sw16" or impl_a is None:
            parts["stem_convs"] = sum(kf[c]["macs"] for c in ("stem_conv1", "stem_conv2", "stem_conv3")) * C["sw16_dot_c_mac"]["v"]
        else:
            _, G, R = impl_a.split(":")
            G, R = int(G), int(R)
            conv = sum(engine_conv(kf, c, G=G, ranges=R, halves=2, stage_mult=C["stage16"]["v"] * nhwc, place_mult=pm)
                       for c in ("stem_conv1", "stem_conv2", "stem_conv3"))
            in_el = 64000 + 288 * 999 + 576 * 331
            out_el = 288 * 999 + 576 * 331 + 288 * 165
            parts["stem_convs"] = conv + in_el * C["hilo_split_el"]["v"] + out_el * (R - 1) * C["multirange_el"]["v"]
        est = True
    else:
        rate = 32.0 if hw == "b2" else 16.0
        parts["stem_convs"] = sum(engine_conv(kf, c, macs_rate=rate, in_w=2, out_w=2, stage_mult=C["stage16"]["v"] * nhwc, place_mult=pm)
                                  for c in ("stem_conv1", "stem_conv2", "stem_conv3"))
        est = True
    # ---- software ops ----
    sw = {}
    stem_gelu_el = 576 * 331 + 288 * 165
    mlp_gelu_el = 6 * EL_T * FF
    if stem16 or all16:
        sw["tanh"] = 288 * 999 * C["sw16_lut_el"]["v"]
        sw["groupnorm"] = 288 * 999 * C["sw16_gn_el"]["v"]
        sw["gelu_stem"] = stem_gelu_el * C["sw16_lut_el"]["v"]
        est = True
    else:
        sw["tanh"] = C["sw8_tanh_s8"]["v"]
        sw["groupnorm"] = C["sw8_groupnorm_s8"]["v"]
        sw["gelu_stem"] = stem_gelu_el * C["sw8_gelu_s8_el"]["v"]
    sw["gelu_mlp"] = mlp_gelu_el * (C["sw16_lut_el"]["v"] if all16 else C["sw8_gelu_s8_el"]["v"])
    add_el = 12 * EL_T * D
    if all16 or adds == "int16":
        sw["add"] = add_el * C["sw16_add_el"]["v"]
        est = True
    elif adds == "pc":
        sw["add"] = add_el * C["swpc_add_el"]["v"]
        est = True
    else:
        sw["add"] = C["sw8_add_s8"]["v"]
    ln_changed = all16 or adds in ("pc", "int16") or stem16
    sw["layernorm"] = (13 * EL_T * D * C["sw16_ln_el"]["v"]) if ln_changed else C["sw8_layernorm_s8"]["v"]
    sw["softmax"] = C["sw8_softmax_s8"]["v"] * (C["sw16_softmax"]["v"] if all16 else 1.0)
    sw["matmul_b"] = (ew["matmul_b_s8"]["macs"] * C["sw16_matmul_c_mac"]["v"]) if all16 else C["sw8_matmul_b_s8"]["v"]
    sw["rope"] = C["sw8_rope_s8"]["v"] * (C["sw16_rope"]["v"] if all16 else 1.0)
    sw["permute"] = C["sw8_permute4_s8"]["v"] * (C["sw16_permute"]["v"] if (all16 or stem16) else 1.0)
    parts.update({"sw_" + k: v for k, v in sw.items()})
    total = sum(parts.values())
    return total, parts, est


CANDIDATES = [
    # name, quant_fix candidate for dev WER, description, test-clean WER key or None
    ("as extracted (W8A8)", "W8A8 (as extracted)", {"stem": "int8"}),
    ("F2: stem int16, residual adds per-channel", "FACT F2: F1 + residual adds per-channel",
     {"stem": "int16", "adds": "pc", "stem_impl_a": "sw16"}),
    ("F3: F2 + o_proj/fc2 rows", "FACT F3: F2 + o_proj/fc2 rows, per-tensor W8",
     {"stem": "int16", "adds": "pc", "stem_impl_a": "sw16"}),
    ("F3 + per-row weights (a: 4 row groups)", {"a": "FACT W: F3 + ALL weights in 4 row groups (dispatch splits)",
                                                "b": "CD F3PR: stem int16 + adds per-channel + rows + per-row"},
     {"stem": "int16", "adds": "pc", "weights": "pr", "stem_impl_a": "sw16"}),
    ("F2 + per-row weights", {"b": "CD F2PR: stem int16 + adds per-channel + per-row"},
     {"stem": "int16", "adds": "pc", "weights": "pr", "stem_impl_a": "sw16", "b_only": True}),
    ("A16: stem + residual adds int16, per-row weights", {"b": "CD A16PR: stem int16 + residual adds int16 + per-row"},
     {"stem": "int16", "adds": "int16", "weights": "pr", "b_only": True}),
    ("R: split stem (1,64), 2 stem row groups, adds pc + rows", {"a": "FINAL R: split stem (1, 64), stem weights 2 group(s), adds per-channel + o_proj/fc2 rows"},
     {"stem": "int16", "adds": "pc", "stem_impl_a": "split:2:2", "a_only": True}),
    ("R: split stem (1,16,256), 4 stem row groups, adds pc + rows", {"a": "FINAL R: split stem (1, 16, 256), stem weights 4 group(s), adds per-channel + o_proj/fc2 rows"},
     {"stem": "int16", "adds": "pc", "stem_impl_a": "split:4:3", "a_only": True}),
    ("ALL16: every activation int16, per-tensor weights", {"b": "CD ALL16: every activation int16, W8 per-tensor"},
     {"all16": True, "b_only": True}),
    ("ALL16 + per-row weights", {"b": "CD ALL16PR: every activation int16, per-row weights"},
     {"all16": True, "weights": "pr", "b_only": True}),
]

TEST = {"FINAL R: split stem (1, 64), stem weights 2 group(s), adds per-channel + o_proj/fc2 rows": None,
        "FINAL R: split stem (1, 16, 256), stem weights 4 group(s), adds per-channel + o_proj/fc2 rows": None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    ew, big, shapes, kf = load()
    C = cost_table(ew, big)
    wer = {}
    for f in ("quant_fix_factorial.json", "quant_fix_factorial3.json", "quant_fix_codesign_dev.json",
              "quant_fix_final_dev2.json"):
        d = json.load(open(os.path.join(HERE, f)))
        for k, v in d["candidates"].items():
            wer[k] = v["wer_vs_reference"]["wer"]
    tc = json.load(open(os.path.join(HERE, "quant_fix_eval_test_clean.json")))
    test = {k: v["wer_vs_reference"]["wer"] for k, v in tc["finalists"].items()}
    base, _, _ = price({"stem": "int8"}, "a", C, ew, shapes, kf)
    rows = []
    for name, qf, desc in CANDIDATES:
        for hw in ("a", "b1", "b2"):
            if desc.get("b_only") and hw == "a":
                continue
            if desc.get("a_only") and hw != "a":
                continue
            key = qf if isinstance(qf, str) else qf.get("a" if hw == "a" else "b")
            if key is None:
                continue
            cyc, parts, est = price(desc, hw, C, ew, shapes, kf)
            rows.append({"candidate": name, "hardware": hw, "wer_dev": wer.get(key), "wer_test": test.get(key),
                         "quant_fix_key": key, "cycles": cyc, "rtf": cyc / CLK / 4.0,
                         "vs_today_int8": cyc / base, "contains_estimates": est,
                         "parts_ms": {k: v / CLK * 1e3 for k, v in parts.items()}})
    out = {"what": "WER (float simulation, dev-clean; test-clean for finalists run once) against encoder RTF (4 s, "
                   "steady state) under three engine assumptions. Costs from measured parts (B26, B25 run 8) with named "
                   "estimates. See codesign_price.py.",
           "float_wer": {"dev": 0.0730, "test": 0.0752}, "bar": "int8 WER within 2 points absolute of float",
           "baseline_cycles_today_int8": base, "baseline_rtf": base / CLK / 4.0, "costs": C, "rows": rows}
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"baseline (as extracted, today's engine): RTF {base / CLK / 4.0:.2f}")
    print(f"{'candidate':62s} {'hw':3s} {'WER dev':>8s} {'test':>7s} {'RTF':>6s} {'x':>6s}")
    for r in rows:
        print(f"{r['candidate']:62s} {r['hardware']:3s} {100 * r['wer_dev']:7.2f}% "
              f"{(100 * r['wer_test']) if r['wer_test'] is not None else float('nan'):6.2f}% {r['rtf']:6.2f} {r['vs_today_int8']:6.2f}")
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
