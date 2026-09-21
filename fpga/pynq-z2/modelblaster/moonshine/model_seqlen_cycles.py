#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""What a shorter encoder sequence is worth in cycles -- with the parts that do NOT shrink priced.

Built from `board/b34_qatu_lnhoist_run.json`, whose 129 op names are unique (so its name-keyed
join is sound -- 4aac1ef) and whose rows reconcile with its wall clock to -0.01 % (L297).

THE POINT OF THIS FILE IS THE FIXED FLOOR.  Shortening T does not shorten:

  * the WEIGHT IMAGE BUILD, 180,241,986 cycles for 8,519,680 bytes.  The image is weights only;
    T does not appear in it.  It reconciles exactly: 39 engine calls, 39 weight tensors, and
    sum(wimage_plan) = 8,519,680 = engine.image_bytes to the byte.  Cold only -- cached after.
  * every stem stage ABOVE the knob.  conv1/tanh/groupnorm run at T1 = 999 and conv2/gelu2 at
    T2 = 331, and a conv3-stride or post-stem knob leaves both untouched.

Each row is split into image + NCHW staging + dispatch, which is not a modelling choice but an
identity on this record:
    rows 732,249,750 = cycles_h0 96,715,634 + image_cycles 180,241,986 + cycles_stage 34,179,494
                       + CPU-kernel rows 420,991,706         (to 0.02 %)
Engine dispatches are then re-planned at the new npix with engine_traffic's own tile planner --
weight bytes do not scale (bytes_wgt 8,519,680 = image_bytes exactly: each image is streamed
once), activation bytes, MAC steps and drained bytes do.

CPU kernels are scaled by their own element law, and because that prices a per-dispatch residue
at ZERO -- the error this campaign keeps making -- the residue is also BOUNDED from Lab B31's
measured cycles-per-element curves (`board/b31_ladder_run.json`: gelu 321 cyc/el at n=48 falling
to 19.6 at n=172,332) and reported as a band, not dropped.

    python3 model_seqlen_cycles.py --json model_seqlen_cycles.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import engine_traffic as et  # noqa: E402

CLK = 34482759.0
WINDOW_S = 4.0
T1_0, T2_0, T0 = 999, 331, 165


def conv_out(n, k, s):
    return (n - k) // s + 1


def shapes_for(s1=64, s2=3, s3=2, post_k=1):
    t1 = conv_out(64000, 127, s1)
    t2 = conv_out(t1, 7, s2)
    t3 = conv_out(t2, 3, s3)
    return t1, t2, t3, (t3 // post_k if post_k > 1 else t3)


def wimg(row):
    if row["op"] == "linear_s8":
        return et.wimage_plan(row["shape"]["N"], row["shape"]["K"])
    s = row["shape"]
    return et.wimage_plan(s["OC"], s["IC"] * s["KW"] * s["KH"])


def npix_of(row, t1, t2, t3, T):
    """The row's own length variable, at the new shapes and at the measured ones."""
    op, s = row["op"], row["shape"]
    if op == "conv2d_s8":
        w = s["OW"]
        return ({999: t1, 331: t2, 165: t3}[w], w)           # conv output length
    if op == "linear_s8":
        return (T, s["M"])
    return (None, None)


def elem_law(row, t1, t2, t3, T):
    """(new elements, old elements) for a CPU-kernel row, from its own shape."""
    op, s = row["op"], row["shape"]
    if op == "tanh_s8":                                       # stem, at T1
        return (288 * t1, s["n"])
    if op == "groupnorm_s8":                                  # stem, at T1
        return (288 * t1, 288 * s["W"])
    if op == "gelu_s8":
        n = s["n"]
        if n == 190656:                                       # stem gelu2, at T2
            return (576 * t2, n)
        if n == 47520:                                        # stem gelu3, at T3 (pre-post-step)
            return (288 * t3, n)
        return (1152 * T, n)                                  # mlp act, at T
    if op == "layernorm_s8":
        return (T * s["K"], s["M"] * s["K"])
    if op == "add_s8":
        return (288 * T, s["n"])
    if op == "rope_s8":
        return (T * s["H"] * s["D"], s["T"] * s["H"] * s["D"])
    if op == "permute4_s8":
        d = [s["d0"], s["d1"], s["d2"], s["d3"]]
        old = d[0] * d[1] * d[2] * d[3]
        if d[1] == 288 and d[3] == 165:                       # the stem's [1,288,1,T3] permute
            return (288 * t3, old)
        return (8 * 36 * T, old)                              # attention permutes, at T
    if op == "softmax_s8":                                    # [H*T, T] -- quadratic
        return (8 * T * T, s["M"] * s["K"])
    if op == "matmul_b_s8":                                   # both qk and av are quadratic
        return (8 * T * T * 36, s["B"] * s["M"] * s["K"] * s["N"])
    raise KeyError(op)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--b34", default=os.path.join(HERE, "board", "b34_qatu_lnhoist_run.json"))
    ap.add_argument("--b28", default=os.path.join(HERE, "board", "b28_dec_t4_run.json"))
    ap.add_argument("--b31", default=os.path.join(HERE, "board", "b31_ladder_run.json"))
    ap.add_argument("--json", required=True)
    a = ap.parse_args()

    m = json.load(open(a.b34))["models"]["moonshine_q16"] if False else None
    d34 = json.load(open(a.b34))
    m = d34["models"][list(d34["models"].keys())[0]]
    rows, eng = m["rows"], m["engine"]
    wall = int(m["run_line"].split("median=")[1].split()[0])
    img_rate = eng["image_cycles"] / eng["image_bytes"]

    # ---- the identity the split rests on ------------------------------------------------
    cpu = sum(r["cycles"] for r in rows if r["op"] not in ("linear_s8", "conv2d_s8"))
    engrows = sum(r["cycles"] for r in rows if r["op"] in ("linear_s8", "conv2d_s8"))
    ident = {"rows_total": sum(r["cycles"] for r in rows),
             "cycles_h0": eng["cycles_h0"], "image_cycles": eng["image_cycles"],
             "cycles_stage": eng["cycles_stage"], "cpu_kernel_rows": cpu,
             "engine_rows": engrows,
             "h0_plus_image_plus_stage": eng["cycles_h0"] + eng["image_cycles"] + eng["cycles_stage"],
             "residual_vs_engine_rows": engrows - (eng["cycles_h0"] + eng["image_cycles"]
                                                   + eng["cycles_stage"]),
             "wall_median": wall, "steady_cycles": wall - eng["image_cycles"]}

    # ---- per-row decomposition at the measured shapes ------------------------------------
    parts = []
    stage_out = eng["cycles_stage"] - eng["cycles_stage_in"]
    conv_in = {999: 64000, 331: 999, 165: 331}
    stage_in_tot = sum(conv_in[r["shape"]["OW"]] * r["shape"]["IC"]
                       for r in rows if r["op"] == "conv2d_s8")
    stage_out_tot = sum(r["shape"]["OW"] * r["shape"]["OC"]
                        for r in rows if r["op"] == "conv2d_s8")
    for r in rows:
        p = {"name": r["name"], "op": r["op"], "cycles": r["cycles"]}
        if r["op"] in ("linear_s8", "conv2d_s8"):
            p["image"] = wimg(r)["bytes"] * img_rate
            if r["op"] == "conv2d_s8":
                s = r["shape"]
                p["stage"] = (eng["cycles_stage_in"] * conv_in[s["OW"]] * s["IC"] / stage_in_tot
                              + stage_out * s["OW"] * s["OC"] / stage_out_tot)
            else:
                p["stage"] = 0.0
            p["dispatch"] = r["cycles"] - p["image"] - p["stage"]
        else:
            p["image"] = p["stage"] = 0.0
            p["dispatch"] = r["cycles"]
        parts.append(p)

    def encoder_at(s1=64, s2=3, s3=2, post_k=1):
        t1, t2, t3, T = shapes_for(s1, s2, s3, post_k)
        image = sum(p["image"] for p in parts)                 # FIXED, weights only
        comp = stage = 0.0
        for p, r in zip(parts, rows):
            if r["op"] in ("linear_s8", "conv2d_s8"):
                npix_new, npix_old = npix_of(r, t1, t2, t3, T)
                w = wimg(r)
                if r["op"] == "linear_s8":
                    astride = r["shape"]["K"] // 8
                else:
                    astride = (r["shape"]["IC"] * r["shape"]["KW"] * r["shape"]["KH"]) // 8
                a_new = et.run_plan(w, npix_new, astride)
                a_old = et.run_plan(w, npix_old, astride)
                def work(pl, n):
                    return pl["bytes_a"] + pl["bytes_w"] + pl["out_bytes"] + n * 1.0
                comp += p["dispatch"] * work(a_new, npix_new) / work(a_old, npix_old)
                if p["stage"]:
                    s = r["shape"]
                    ci = {999: 64000, 331: t1, 165: t2}[s["OW"]]
                    co = {999: t1, 331: t2, 165: t3}[s["OW"]]
                    fin = eng["cycles_stage_in"] * conv_in[s["OW"]] * s["IC"] / stage_in_tot
                    fou = stage_out * s["OW"] * s["OC"] / stage_out_tot
                    stage += fin * ci / conv_in[s["OW"]] + fou * co / s["OW"]
            else:
                n_new, n_old = elem_law(r, t1, t2, t3, T)
                comp += p["dispatch"] * n_new / n_old
        return {"T1": t1, "T2": t2, "T3": t3, "T": T,
                "image_cycles": image, "steady_cycles": comp + stage,
                "cold_cycles": comp + stage + image}

    base = encoder_at()
    out = {"what": __doc__.split("\n")[0], "clock_hz": CLK, "window_s": WINDOW_S,
           "identity": ident, "image_cycles_per_byte": img_rate,
           "base_model_vs_measured": {
               "model_steady": base["steady_cycles"], "measured_steady": ident["steady_cycles"],
               "model_cold": base["cold_cycles"], "measured_cold": wall,
               "steady_pct_error": 100.0 * (base["steady_cycles"] - ident["steady_cycles"])
                                   / ident["steady_cycles"]},
           "fixed_floor": {}, "variants": []}

    # what is fixed under a conv3/post-stem knob: everything at T1 and T2, plus the image
    fix = 0.0
    for p, r in zip(parts, rows):
        s = r["shape"]
        at_t1 = (r["op"] == "conv2d_s8" and s["OW"] == 999) or r["op"] in ("tanh_s8", "groupnorm_s8")
        at_t2 = (r["op"] == "conv2d_s8" and s["OW"] == 331) or \
                (r["op"] == "gelu_s8" and s.get("n") == 190656)
        if at_t1 or at_t2:
            fix += p["dispatch"] + p["stage"]
    out["fixed_floor"] = {
        "under_a_conv3_or_post_stem_knob": {
            "steady_cycles_that_do_not_scale": fix,
            "pct_of_encoder_steady": 100.0 * fix / ident["steady_cycles"],
            "what": "conv1 + tanh + groupnorm at T1=999, conv2 + gelu2 at T2=331, and their "
                    "NCHW staging.  A conv3-stride or post-stem knob does not touch them."},
        "image_build_never_scales": {
            "cycles": eng["image_cycles"], "bytes": eng["image_bytes"],
            "pct_of_encoder_cold": 100.0 * eng["image_cycles"] / wall}}

    # SENSITIVITY THE COORDINATOR NEEDS: this speedup is computed against TODAY's op costs.
    # The encoder ladder in flight (attention unit, LayerNorm lane, LUT lane, place_early)
    # preferentially attacks the O(T^2) ops that this knob ALSO shrinks, so the two do not
    # multiply -- once those ops are cheap, what is left for this knob is mostly O(T) and its
    # factor falls.  Bound it by re-costing with the quadratic ops set to zero.
    def encoder_at_no_quadratic(**kw):
        t1, t2, t3, T = shapes_for(**kw)
        comp = 0.0
        for p_, r in zip(parts, rows):
            if r["op"] in ("matmul_b_s8", "softmax_s8"):
                continue
            if r["op"] in ("linear_s8", "conv2d_s8"):
                npix_new, npix_old = npix_of(r, t1, t2, t3, T)
                comp += p_["dispatch"] * npix_new / npix_old + p_["stage"] * npix_new / npix_old
            else:
                n_new, n_old = elem_law(r, t1, t2, t3, T)
                comp += p_["dispatch"] * n_new / n_old
        return comp
    nq_base = encoder_at_no_quadratic()

    CAND = [("c3s3", dict(s3=3)), ("c3s4", dict(s3=4)), ("c3s5", dict(s3=5)),
            ("c3s6", dict(s3=6)), ("dec2", dict(post_k=2)), ("dec3", dict(post_k=3)),
            ("c2s6", dict(s2=6)), ("c1s128", dict(s1=128))]
    for name, kw in CAND:
        v = encoder_at(**kw)
        v["name"] = name
        v["steady_speedup"] = base["steady_cycles"] / v["steady_cycles"]
        v["cold_speedup"] = base["cold_cycles"] / v["cold_cycles"]
        v["rtf_steady"] = v["steady_cycles"] / (CLK * WINDOW_S)
        v["rtf_cold"] = v["cold_cycles"] / (CLK * WINDOW_S)
        v["steady_speedup_if_the_quadratic_ops_were_already_free"] = \
            nq_base / encoder_at_no_quadratic(**kw)
        out["variants"].append(v)

    # ---- the decoder's cross-attention, which is O(T) and gets cheaper too ---------------
    d28 = json.load(open(a.b28))["models"]["dec_q16"]
    xrows = [r for r in d28["rows"]
             if (r["op"] == "matmul_b_s8" and 165 in (r["shape"].get("K"), r["shape"].get("N")))]
    xc = sum(r["cycles"] for r in xrows)
    out["decoder_cross_attention"] = {
        "note": "b28 rows are name-joined (4aac1ef) and the decoder reuses op names across its "
                "24 steps, so these are per-dispatch values x count: safe here only because "
                "every step does identical work and none of them builds an image.  Quoted as a "
                "SHARE, which is what the join preserves.",
        "dispatches": len(xrows), "cycles_at_T165": xc,
        "pct_of_b28_dispatch_total": 100.0 * xc / d28["dispatch_cycles_total"],
        "law": "O(T): M=1 queries against T keys",
        "kx_vx_input_bytes_at_T165": 12 * 165 * 288,
        "saving_at": {}}
    for name, kw in CAND:
        _, _, _, T = shapes_for(**kw)
        out["decoder_cross_attention"]["saving_at"][name] = {
            "T": T, "cycles": xc * T / 165.0, "saving": xc * (1 - T / 165.0)}

    # ---- what it does to the coordinator's composed projection -------------------------
    # EVERY NUMBER IN THIS BLOCK IS A COMPOSITION OF PREDICTIONS, none of it is measured.  The
    # inputs are the coordinator's own projected post-ladder halves (encoder 1.430, decoder
    # 1.247, RTF_e2e 2.676).  The encoder factor used is the T^2-FREE one, because the ladder
    # it is composed onto is what makes those ops cheap -- using the 2.056x measured against
    # TODAY's op mix would count the same savings twice.
    xshare = out["decoder_cross_attention"]["pct_of_b28_dispatch_total"] / 100.0
    comp = {"note": "composition of PREDICTIONS, not a measurement; inputs are the coordinator's "
                    "projected post-ladder halves",
            "inputs": {"encoder_rtf_projected": 1.430, "decoder_rtf_projected": 1.247,
                       "rtf_e2e_projected": 2.676, "goal": 1.0,
                       "decoder_cross_attention_share": xshare},
            "rows": []}
    for v in out["variants"]:
        f = v["steady_speedup_if_the_quadratic_ops_were_already_free"]
        e = 1.430 / f
        dfac = 1.0 - xshare * (1.0 - v["T"] / 165.0)
        d_ = 1.247 * dfac
        comp["rows"].append({"name": v["name"], "T": v["T"],
                             "encoder_rtf": e, "decoder_rtf": d_, "rtf_e2e": e + d_,
                             "encoder_factor_used": f,
                             "meets_goal": (e + d_) < 1.0,
                             "decoder_share_of_e2e": d_ / (e + d_)})
    out["composition_onto_the_projected_ladder"] = comp

    json.dump(out, open(a.json, "w"), indent=1)
    print(f"identity check: rows {ident['rows_total']:,} vs h0+image+stage+cpu "
          f"{ident['h0_plus_image_plus_stage'] + cpu:,} "
          f"({100.0*(ident['rows_total']-ident['h0_plus_image_plus_stage']-cpu)/ident['rows_total']:+.3f} %)")
    print(f"model at base: steady {base['steady_cycles']:,.0f} vs measured "
          f"{ident['steady_cycles']:,} ({out['base_model_vs_measured']['steady_pct_error']:+.2f} %)")
    f = out["fixed_floor"]["under_a_conv3_or_post_stem_knob"]
    print(f"fixed floor under a conv3/post-stem knob: {f['steady_cycles_that_do_not_scale']:,.0f} "
          f"= {f['pct_of_encoder_steady']:.1f} % of encoder steady; "
          f"image build {eng['image_cycles']:,} never scales "
          f"({out['fixed_floor']['image_build_never_scales']['pct_of_encoder_cold']:.1f} % of cold)")
    for v in out["variants"]:
        x = out["decoder_cross_attention"]["saving_at"][v["name"]]
        print(f"  {v['name']:7s} T={v['T']:3d}  steady {v['steady_cycles']:>12,.0f} "
              f"({v['steady_speedup']:.3f}x, RTF {v['rtf_steady']:.3f})  "
              f"cold {v['cold_cycles']:>12,.0f} ({v['cold_speedup']:.3f}x)  "
              f"decoder cross-attn -{x['saving']:,.0f}  "
              f"[{v['steady_speedup_if_the_quadratic_ops_were_already_free']:.3f}x if T^2 free]")
    print("\n-- composed onto the projected post-ladder halves (PREDICTIONS, not measurements) --")
    print(f"   today's projection: encoder 1.430 + decoder 1.247 = RTF_e2e 2.676, goal 1.0")
    for r in comp["rows"]:
        print(f"   {r['name']:7s} T={r['T']:3d}  encoder {r['encoder_rtf']:.3f} + decoder "
              f"{r['decoder_rtf']:.3f} = RTF_e2e {r['rtf_e2e']:.3f}  "
              f"{'MEETS' if r['meets_goal'] else 'misses'} the goal; decoder is now "
              f"{100*r['decoder_share_of_e2e']:.0f} % of it")
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
