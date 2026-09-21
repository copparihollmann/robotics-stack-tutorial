#!/usr/bin/env python3
"""Moonshine Tiny's decoder, composed from dispatches measured on the board -- and said to be so.

WHAT IS MEASURED AND WHAT IS NOT.  Lab B25 (scripts/51_rocket_roccmoon.sh) times every GEMM
SHAPE a decoder step contains, on bitstream 0x5A5A0010, both ways: the curated MBP kernel on
hart 0, and the engine driven from hart 1 with the hand-off included.  A token is a fixed
multiset of those dispatches, so the GEMM part of a token is a SUM OF MEASURED DISPATCHES.
That is a composition, not a decoder run: it assumes a dispatch costs the same inside a
decoder as alone, which it does for the engine (every dispatch fetches its own weights) and
for the core up to cache state between neighbouring dispatches.

The non-GEMM residue of a token (layer norm, softmax, attention matmuls, rotary, residual
adds, SiLU) is priced two ways and both are printed:

  s7     reprice_port.py's unit costs, as ROCC_DECOUPLED.md section 7 used them;
  B26    the same op list with every unit cost that Lab B26 MEASURED on Moonshine's own
         encoder substituted (--calib <lab B26 run.json>): integer softmax, layer norm,
         add, the batched attention matmul, and the float reference add.  SiLU has no
         kernel in either measurement; with --calib its float cost is the measured float
         tanh reference (the same expf shape) and its integer cost stays the GELU-LUT model.
         Those two stay flagged as estimates.

WHAT A FASTER PORT WOULD DO (--ports) is a projection from measured parts: each shape's fill
cycles are its measured fill beats divided by the other port's MEASURED bandwidth
(MEMORY_BANDWIDTH.md s6.11 and s8.5), and everything else in the dispatch is kept as
measured.  A bypass lane's rate needs the fill engine and the scratchpad's write port on the
memory clock, which is not built; the number is labelled a projection.

    python3 fpga/pynq-z2/modelblaster/moonshine/decode_compose.py <B25 run.json> \\
        [--tokens 15] [--calib <B26 run.json>] [--out decode.json]
"""
import argparse, copy, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reprice_port as rp   # noqa: E402

CLK = rp.CLK
LD = rp.LD

# per token: for each decoder layer q,k,v,o (self) + q,o (cross) are 288->288; fc1 288->2304;
# fc2 1152->288.  Then the tied projection 288->32768.  Cross K,V are once per utterance.
PER_TOKEN = {"dec_qkvo": 6 * LD, "dec_fc1": LD, "dec_fc2": LD, "dec_lmhead": 1}
PER_UTTERANCE = {"enc_qkvo": 2 * LD}          # cross-attention K and V over 165 frames

# Other fill paths, B per CORE cycle, measured on the bandwidth instrument (not on the engine).
PORTS = [
    # The engine's OWN port, measured inside the engine by Lab B25's cap sweep -- not the
    # instrument's.  The cap is a runtime field (MBXR_CAP), so this row costs no build at all.
    ("the engine's own fill at cap 4, measured on 0x5A5A0028 (runtime field, no build)", 7.342,
     "ROCC_DECOUPLED.md 8.15.10, Lab B25 port sweep on 0x5A5A0028"),
    ("SBUS, skip clean Release 0x5A5A001A (L2 path, the INSTRUMENT's rate, which the engine "
     "reaches only above cap 4)", 8.00, "MEMORY_BANDWIDTH.md 6.11, measured"),
    # THE SINGLE-CLOCK W LANE: the same private read-only port on S_AXI_HP2, but at FCLK0 with no
    # asynchronous crossing.  Its ceiling is the bus, not the PS: one 64-bit beat per core cycle is
    # 8.00 B/cycle = 275.8 MB/s, and s8.5's closed form says 3 outstanding Gets already reach it at
    # this clock (64*3/(12 + 202.5 ns in core cycles = 6.98) = 10.1, capped at 8).  No build.
    ("ONE private lane at FCLK0, no crossing (275.8 MB/s ceiling)", 8.00,
     "derived: 64-bit port x 34.4828 MHz; MEMORY_BANDWIDTH.md 8.5's closed form saturates at 3 Gets"),
    ("TWO private lanes at FCLK0, no crossing (551.7 MB/s)", 16.00,
     "derived: two 64-bit ports x 34.4828 MHz, as 8.5 measured two lanes scaling exactly"),
    ("MBUS bypass, 1 lane at FCLK1 100 MHz (800 MB/s)", 800.0e6 / CLK, "MEMORY_BANDWIDTH.md 8.5, measured"),
    ("MBUS bypass, 2 lanes HP0+HP1 (1,600 MB/s)", 1600.0e6 / CLK, "MEMORY_BANDWIDTH.md 8.5, measured"),
]


# Which B26 model each calibrated cost is read from, best first.  A Lab B26 run holds several
# encoder images; the integer unit costs come from the best software one that RAN in that session
# (the later ones carry softmax memo2, the NHWC GroupNorm and the block permute), and the float
# reference costs come from the pext_nl baseline.  Whichever is used is named in the output.
CALIB_INT = ("enc_ew_smx2_nhwc_perm_bigconv", "enc_ew_smx2_nhwc_perm", "enc_ew_smx2_bigconv",
             "enc_ew_bigconv", "enc_ew")
CALIB_FLOAT = ("enc_nl",)


def _pick(models, names, what):
    for n in names:
        m = models.get(n)
        # Lab B26 records `ran`; Lab B30's q16 profile does not -- per_kind is the real test.
        if m and m.get("per_kind") and (m.get("ran") is not False):
            return n, m["per_kind"]
    raise SystemExit("this run has none of the %s models %s" % (what, list(names)))


def calibrate(path, int_model=None, float_model=None):
    """Unit costs Lab B26 measured on Moonshine's encoder, keyed as reprice_port.COST."""
    run = json.load(open(path))
    m = run["models"]
    ew_name, ew = _pick(m, (int_model,) if int_model else CALIB_INT, "integer")
    # A q16 candidate's run has ONE model and no float-reference twin.  Then the float-reference
    # costs stay reprice_port's, each marked CARRIED in its provenance -- they price SiLU and the
    # gate multiply, which no build measures anyway.
    try:
        nl_name, nl = _pick(m, (float_model,) if float_model else CALIB_FLOAT, "float-reference")
    except SystemExit:
        nl_name, nl = None, None
    calibrate.models = (ew_name, nl_name or "(none: float costs carried)")
    src = "Lab B26 %s, md5 %s, %s/%s" % (os.path.basename(os.path.dirname(os.path.abspath(path))),
                                         run.get("bitstream_md5", "?")[:8], ew_name, nl_name)
    cost = copy.deepcopy(rp.COST)
    # A q16 candidate names its kinds differently (layernorm_pc_s8, add_pc_s8, groupnorm_s16) and
    # has no float-reference twin; take whichever of each pair the run actually measured, and say
    # which in the provenance string that goes into every cost.
    def pick(*names):
        for n in names:
            if n in ew:
                return ew[n], n
        return None, None
    ln, ln_n = pick("layernorm_s8", "layernorm_pc_s8")
    ad, ad_n = pick("add_s8", "add_pc_s8")
    gn, gn_n = pick("groupnorm_s8", "groupnorm_s16")
    calibrate.kinds = {"layernorm": ln_n, "add": ad_n, "groupnorm": gn_n,
                       "softmax": "softmax_s8", "matmul": "matmul_b_s8"}
    calibrate.rope_c_el = ew["rope_s8"]["cycles_per_element"] if "rope_s8" in ew else None
    # which measured kind each cost key was read from, so the size and kernel can travel with it
    calibrate.kind_of = {"softmax_int": "softmax_s8", "layernorm_int": ln_n, "add_int": ad_n,
                         "matmul_c_mac": "matmul_b_s8", "groupnorm_int": gn_n,
                         "rope_int": "rope_s8", "matmul_rq_int": "matmul_b_s8"}
    subs = {
        "softmax_int": (ew["softmax_s8"]["cycles_per_element"], True,
                        "softmax_s8 %s" % ew["softmax_s8"].get("kernel", "?")),
        "layernorm_int": (ln["cycles_per_element"], True, "%s %s" % (ln_n, ln.get("kernel", "?"))),
        "add_int": (ad["cycles_per_element"], True, "%s %s" % (ad_n, ad.get("kernel", "?"))),
        "add_float": ((nl["add_s8"]["cycles_per_element"], True, "add_s8 reference")
                      if nl and "add_s8" in nl else (rp.COST["add_float"]["v"], False,
                      "CARRIED: no float-reference model in this run")),
        # the batched attention matmul, requantise included: all of it per MAC
        "matmul_c_mac": (ew["matmul_b_s8"]["cycles_per_mac"], True, "matmul_b_s8 pext_dot8_exact, requant included"),
        "matmul_rq_int": (0.0, True, "inside matmul_c_mac (measured whole)"),
        "groupnorm_int": (gn["cycles_per_element"], True, "%s %s" % (gn_n, gn.get("kernel", "?"))),
        # the fused RoPE dispatch, measured -- see reprice_port.COST["rope_int"]
        "rope_int": ((ew["rope_s8"]["cycles_per_element"], True,
                      "rope_s8 %s" % ew["rope_s8"].get("kernel", "?")) if "rope_s8" in ew else None),
        "rope_float": ((nl["rope_s8"]["cycles_per_element"], True, "rope_s8 reference")
                       if nl and "rope_s8" in nl else None),
        "groupnorm_float": (nl and nl["groupnorm_s8"]["cycles_per_element"], True, "groupnorm_s8 reference"),
        "tanh_float": (nl and nl["tanh_s8"]["cycles_per_element"], True, "tanh_s8 reference"),
        "silu_float": ((nl["tanh_s8"]["cycles_per_element"], False,
                        "ESTIMATE: no silu_s8; the measured float tanh reference, same expf shape")
                       if nl and "tanh_s8" in nl else (rp.COST["silu_float"]["v"], False,
                       "ESTIMATE, CARRIED: no float-reference model in this run")),
    }
    for k, val in list(subs.items()):
        if val is None or (isinstance(val, tuple) and val[0] is None):
            continue                      # this run has no measurement for it; keep reprice_port's
        v, meas, what = val
        # THE SIZE TRAVELS WITH THE NUMBER (ROCC_DECOUPLED.md 8.15.17).  It was already in the
        # record -- elements / dispatches -- and nothing read it.
        rec = ew.get(calibrate.kind_of.get(k)) or {}
        n = (rec["elements"] // rec["dispatches"]) if rec.get("dispatches") else None
        cost[k] = rp.U(v, meas, "%s: %s" % (src, what), n=n, kernel=rec.get("kernel"))
    return cost


# Lab B31's ladder, keyed as reprice_port.COST.  Each entry is the operator's measured rungs;
# the composition uses their RATIO against the top rung, applied to Lab B26's measured rate.
B31_KEY = {"layernorm_s8": ("layernorm_int",), "add_pc_s8": ("add_int",),
           "rope_s8": ("rope_int",), "mul_s8": ("mul_int",)}


def apply_b31(cost, path):
    """Attach Lab B31's measured size ladders to the costs they belong to."""
    run = json.load(open(path))
    lad, named = {}, {}
    for r in run.get("residue_ops", []):
        lad.setdefault(r["op"], []).append((r["n"], r["cycles_per_element"]))
    for r in run.get("gelu", []):
        lad.setdefault("gelu_s8", []).append((r["n"], r["cycles_per_element"]))
    for r in run.get("softmax_memo2", []):
        lad.setdefault("softmax_s8", []).append((r["n"], r["cycles_per_element"]))
    ok = {k: v.get("reproduces") for k, v in run.get("residue_op_control", {}).items()}
    for op, keys in list(B31_KEY.items()) + [("softmax_s8", ("softmax_int",))]:
        if op not in lad:
            continue
        if ok.get(op) is False:
            apply_b31.refused.append(op)      # its control missed: the ladder may not be used
            continue
        for k in keys:
            if k in cost:
                u = dict(cost[k])
                u["ladder"] = lad[op]
                u["src"] = u["src"] + "; sized by Lab B31 (%s)" % os.path.basename(path)
                cost[k] = u
                named[k] = op
    apply_b31.applied = named
    return cost


apply_b31.refused = []
apply_b31.applied = {}


def residue(cost, sw, tokens):
    saved = rp.COST
    rp.COST = cost
    rp.EXTRAPOLATIONS = {}
    try:
        T, _ = rp.encoder(4.0)
        tok_ops = rp.decoder_token(T, max(1, (tokens + 1) // 2))
        c = 0.0
        est = False
        by = {}
        for o in tok_ops:
            if o["kind"] == "linear":
                continue
            cy, e = rp.core_cycles(o, sw)
            c += cy
            est = est or e
            by[o["kind"]] = by.get(o["kind"], 0.0) + cy
        return c, est, by
    finally:
        residue.extrapolations = rp.EXTRAPOLATIONS
        rp.COST = saved



# ======================================================================================
# The known-answer control for the composition ITSELF (--self-check).
# ======================================================================================
# Every other tier of this programme has one: Lab B25's identity dispatch is checked against
# ref_linear.c on the host before any board time, Lab B31's rates are gated against Lab B26's,
# Lab B20 checks GELU over its whole input domain.  The decoder composition -- the source of the
# 134.2 ms/token budget this goal is written against -- was checked against nothing, because a
# decoder cannot be run: ModelBlaster cannot generate one.
#
# But the encoder CAN be composed by the identical method, and it HAS been measured.  So:
# compose the encoder exactly as the decoder is composed -- Lab B25's measured GEMM dispatches
# times the counts the topology implies, plus the non-GEMM residue priced per element -- and
# compare against Lab B26's measured encoder, a number the composition never consumes.
#
# THREE CHECKS, AND ONLY TWO OF THEM ARE INDEPENDENT.  Said plainly, because it decides what a
# pass is worth:
#   A. POPULATIONS (independent).  How many elements of each kind the topology says the encoder
#      touches, against how many ModelBlaster actually dispatched.  This is the counting the
#      decoder residue rests on, and it is the same code path.  A miscount here is invisible in
#      the decoder, where there is no measurement to disagree with.  Must be EXACT.
#   B. THE GEMM (independent, and the strong one).  Lab B25 measured enc_qkvo/enc_fc1/enc_fc2 as
#      standalone dispatches with random data; Lab B26 measured linear_s8 inside a real encoder.
#      Two labs, two harnesses, the same work.  The GEMM is the decoder composition's dominant
#      term, so if these disagree the decoder number is wrong by that much.  Band: +-25 %.
#   C. THE TOTAL (partly circular, reported for completeness).  Any cost that --calib read OUT of
#      this same run is being compared against itself; those rows test the population and nothing
#      else, and they are marked so.  The stem is reported separately because its convolutions
#      are priced from a different network entirely (SPEECH_ON_ROCKET.md's digit_ctc_t) and the
#      decoder has no convolution at all.
ENC_PER_UTTERANCE = {"enc_qkvo": 4 * rp.LE, "enc_fc1": rp.LE, "enc_fc2": rp.LE}

# reprice_port's op kinds -> the kind names ModelBlaster's profile uses.  RoPE is the one that
# needs the op NAME rather than its kind: reprice prices it as four elementwise passes over the
# rotary dims, ModelBlaster runs ONE fused dispatch over the whole of D.
MB_KIND = {"linear": ("linear_s8",), "conv": ("conv2d_s8",), "matmul": ("matmul_b_s8",),
           "softmax": ("softmax_s8",), "layernorm": ("layernorm_s8", "layernorm_pc_s8"),
           "gelu": ("gelu_s8",), "tanh": ("tanh_s8",),
           "groupnorm": ("groupnorm_s8", "groupnorm_s16"),
           "add": ("add_s8", "add_pc_s8"), "rope": ("rope_s8",)}
# Which COST key prices each kind, so "did --calib read this out of the run I am checking against?"
# is answered by the table rather than by memory.
KIND_COST = {"softmax_s8": "softmax_int", "layernorm_s8": "layernorm_int",
             "layernorm_pc_s8": "layernorm_int", "add_s8": "add_int", "add_pc_s8": "add_int",
             "matmul_b_s8": "matmul_c_mac", "groupnorm_s8": "groupnorm_int",
             "groupnorm_s16": "groupnorm_int", "tanh_s8": "tanh_float",
             "conv2d_s8": "conv_w_c_mac", "gelu_s8": None, "rope_s8": "rope_int",
             "linear_s8": None}
STEM = ("conv1", "conv1.tanh", "groupnorm", "conv2", "conv2.gelu", "conv3", "conv3.gelu")


def _mb_kind(o, have):
    names = ("rope_s8",) if ".rope." in o["name"] else MB_KIND.get(o["kind"], ())
    for n in names:
        if n in have:
            return n
    return names[0] if names else o["kind"]


def self_check(shapes, cost, sw, calib_path, model_name=None, out=None):
    """Compose the ENCODER by the decoder's own method and check it against Lab B26."""
    run = json.load(open(calib_path))
    name, per_kind = _pick(run["models"], (model_name,) if model_name else CALIB_INT, "encoder")
    model = run["models"][name]
    # Which Lab B25 column to compare against is decided by the kernel the run ACTUALLY used for
    # its linears, not by a `target` field a q16 profile does not carry: comparing B25's hart-0
    # dispatches against an engine run reads as a 6.2x "failure" that is only a category error.
    on_engine = (model.get("target") == "roccmoon"
                 or per_kind.get("linear_s8", {}).get("kernel") == "roccmoon_engine")
    variant = "eng_h0_cycles" if on_engine else "core_cycles"
    missing = [k for k in ENC_PER_UTTERANCE if k not in shapes]
    if missing:
        sys.exit("the Lab B25 run lacks encoder shapes %s" % missing)

    saved = rp.COST
    rp.COST = cost
    try:
        T, ops = rp.encoder(run.get("window_s", 4.0))
        comp = {}
        for o in ops:
            k = _mb_kind(o, per_kind)
            d = comp.setdefault(k, {"ops": 0, "els": 0, "cycles": 0.0, "stem": 0.0, "est": False})
            d["ops"] += 1
            d["els"] += o["els"]
            if o["kind"] == "linear":
                continue                      # measured below, not priced
            cy, est = rp.core_cycles(o, sw)
            d["cycles"] += cy
            d["est"] = d["est"] or est
            if o["name"] in STEM:
                d["stem"] += cy
    finally:
        rp.COST = saved

    # LIKE FOR LIKE, AND ON THE ENGINE PATH THAT TAKES AN INTERVAL RATHER THAN A POINT.
    # mbxr_rt builds each weight image LAZILY, inside the first dispatch that needs it
    # (mbxr_rt_image(), sw/roccmoon/mbxr_rt.h), so Lab B26's per-kind linear_s8 total is
    # dispatch + images, and the record reports image_cycles only for the whole model, never per
    # kind.  It cannot be split exactly.  It CAN be bounded, and the bound is tight enough to be
    # a gate: every image is built inside either a linear or a conv dispatch, so the conv images
    # can absorb at most the whole of conv2d_s8's measured time, and the rest must be linear's.
    #   L_image in [image_cycles - conv_measured, image_cycles]
    #   L_dispatch = linear_measured - L_image, in [lin - img, lin - max(0, img - conv)]
    # Lab B25's composed dispatch has to land in that interval, within the same +-25 % band.
    # Lab B25's own img_build_cycles is NOT added: it times mbxr_wimage_build on a contiguous
    # weight matrix, while the runtime also stages every row through a callback first.  How much
    # more that costs is exactly what the interval says, and it is reported below.
    gemm = sum(shapes[k][variant] * n for k, n in ENC_PER_UTTERANCE.items())
    img = sum(shapes[k].get("img_build_cycles", 0) * n for k, n in ENC_PER_UTTERANCE.items())
    comp["linear_s8"]["cycles"] = gemm + (img if on_engine else 0)

    # IS THIS THE REFERENCE TOPOLOGY?  reprice_port counts the graph of modeling_moonshine.py.  A
    # candidate quantisation is a DIFFERENT graph -- q16 candidate R splits the stem into 24 conv
    # dispatches, carries s16 intermediates and folds tanh into a lut16 -- and comparing populations
    # against it is a category error, not a failure.  The discriminator is stated before it is used:
    # if kinds reprice_port cannot produce at all carry more than 2 % of the measured cycles, this
    # is not the reference topology and only the GEMM check applies.
    known = set(n for v in list(MB_KIND.values()) + [("rope_s8",)] for n in v)
    tot_meas_cyc = float(sum(v["cycles"] for v in per_kind.values())) or 1.0
    alien = {k: v["cycles"] / tot_meas_cyc for k, v in per_kind.items() if k not in known}
    alien_share = sum(alien.values())
    reference_graph = alien_share <= 0.02

    rows, pop_bad, unmodelled = [], [], []
    for k in sorted(set(list(comp) + list(per_kind))):
        c, m = comp.get(k), per_kind.get(k)
        if not m:
            pop_bad.append("%s: composed %d el, ModelBlaster never dispatches it" % (k, c["els"]))
            continue
        if not c:
            unmodelled.append(k)
            rows.append({"kind": k, "composed_els": 0, "measured_els": m["elements"],
                         "els_ratio": 0.0, "composed_ms": 0.0,
                         "measured_ms": m["cycles"] / CLK * 1e3, "ms_ratio": 0.0,
                         "independent": True, "note": "NOT MODELLED by reprice_port"})
            continue
        ratio = c["els"] / float(m["elements"])
        key = KIND_COST.get(k)
        indep = (k == "linear_s8") or key is None or "Lab B26" not in cost.get(key, {}).get("src", "")
        if abs(ratio - 1.0) > 1e-9:
            pop_bad.append("%s: composed %d el, measured %d (%.3fx)" % (k, c["els"], m["elements"], ratio))
        rows.append({"kind": k, "composed_ops": c["ops"], "measured_dispatches": m["dispatches"],
                     "composed_els": c["els"], "measured_els": m["elements"], "els_ratio": ratio,
                     "composed_ms": c["cycles"] / CLK * 1e3, "measured_ms": m["cycles"] / CLK * 1e3,
                     "ms_ratio": c["cycles"] / max(1.0, float(m["cycles"])),
                     "independent": bool(indep),
                     "note": "measured (Lab B25 dispatches)" if k == "linear_s8"
                             else ("priced" if indep else "CIRCULAR: this cost was read from this run")})

    tot_c = sum(r["composed_ms"] for r in rows)
    tot_m = sum(r["measured_ms"] for r in rows)
    stem_c = sum(v["stem"] for v in comp.values()) / CLK * 1e3
    # THE STACK IS THE PART A DECODER SHARES.  The stem's convolutions are priced from another
    # network entirely and on the engine path they are not even priced on the right unit, so the
    # whole-encoder ratio says little about a decoder.  conv/tanh/groupnorm are stem-only kinds;
    # GELU straddles, and is uniform per element, so its stem share splits exactly by elements.
    stem_m = sum(r["measured_ms"] for r in rows if r["kind"] in ("conv2d_s8", "tanh_s8",
                                                                "groupnorm_s8", "groupnorm_s16"))
    g = [r for r in rows if r["kind"] == "gelu_s8"]
    if g and comp.get("gelu_s8", {}).get("els"):
        stem_els = sum(o["els"] for o in ops if o["kind"] == "gelu" and o["name"] in STEM)
        stem_m += g[0]["measured_ms"] * stem_els / comp["gelu_s8"]["els"]
    lin_meas = float(per_kind["linear_s8"]["cycles"])
    if on_engine:
        img_meas = float(model.get("image_cycles_once") or 0.0)
        conv_meas = float(per_kind.get("conv2d_s8", {}).get("cycles", 0.0))
        lo = max(0.0, lin_meas - img_meas)
        hi = lin_meas - max(0.0, img_meas - conv_meas)
        gemm_ratio = gemm / max(1.0, min(max(gemm, lo), hi))   # 1.0 when inside the interval
        band = {"interval_lo_ms": lo / CLK * 1e3, "interval_hi_ms": hi / CLK * 1e3,
                "composed_dispatch_ms": gemm / CLK * 1e3,
                "runtime_image_build_ms": (lin_meas - hi) / CLK * 1e3,
                "b25_image_build_ms": img / CLK * 1e3}
    else:
        gemm_ratio = comp["linear_s8"]["cycles"] / lin_meas
        band = None
    verdict_img = {"dispatch_ms": gemm / CLK * 1e3, "image_build_ms": img / CLK * 1e3}
    verdict = {"populations_exact": not pop_bad, "population_defects": pop_bad,
               "reference_graph": bool(reference_graph), "unmodelled_share": alien_share,
               "unmodelled_kinds": {k: round(v, 4) for k, v in sorted(alien.items(), key=lambda x: -x[1])},
               "gemm_ratio": gemm_ratio, "gemm_within_25pct": abs(gemm_ratio - 1.0) <= 0.25,
               "gemm_on_engine": bool(on_engine), "gemm_dispatch_ms": gemm / CLK * 1e3,
               "gemm_image_build_ms": img / CLK * 1e3, "gemm_interval": band,
               "total_ratio": tot_c / max(1e-9, tot_m),
               "stack_composed_ms": tot_c - stem_c, "stack_measured_ms": tot_m - stem_m,
               "stack_ratio": (tot_c - stem_c) / max(1e-9, tot_m - stem_m),
               "model": name, "variant": variant, "sw": sw,
               "measured_total_ms": model["dispatch_cycles_total"] / CLK * 1e3,
               "measured_rtf": model.get("rtf_steady", model.get("rtf_4s")), "rows": rows}

    print("\nSELF-CHECK: the encoder composed by the decoder's own method, against Lab B26")
    print("  model %s (%s, %s), GEMM from Lab B25's %s, residue priced with sw=%s"
          % (name, model.get("target"), "engine" if variant.startswith("eng") else "hart 0",
             variant, sw))
    print("  %-16s %7s %7s %9s %10s %10s %7s  %s"
          % ("kind", "ops", "disp", "els ratio", "composed", "measured", "ratio", "what it tests"))
    for r in sorted(rows, key=lambda r: -r["measured_ms"]):
        print("  %-16s %7s %7s %9.3f %9.1fms %9.1fms %7s  %s"
              % (r["kind"], r.get("composed_ops", "-"), r.get("measured_dispatches", "-"),
                 r["els_ratio"], r["composed_ms"], r["measured_ms"],
                 ("%.2fx" % r["ms_ratio"]) if r.get("ms_ratio") else "-", r["note"]))
    if reference_graph:
        print("  A. POPULATIONS: %s" % ("EXACT on every kind" if not pop_bad else "MISMATCH"))
        for b in pop_bad:
            print("       - %s" % b)
        if alien:
            print("       (omitted, %.2f %% of the measured cycles: %s)"
                  % (100 * alien_share, ", ".join("%s %.2f %%" % (k, 100 * v) for k, v in
                                                  sorted(alien.items(), key=lambda x: -x[1]))))
    else:
        print("  A. POPULATIONS: NOT APPLICABLE -- %s is not the reference topology: %.1f %% of its "
              "cycles are in kinds reprice_port cannot produce (%s).  Only the GEMM check applies."
              % (name, 100 * alien_share, ", ".join(sorted(alien))))
        for b in pop_bad:
            print("       (for the record) %s" % b)
    ok = "PASS (within 25 %)" if verdict["gemm_within_25pct"] else "FAIL"
    if band:
        print("  B. GEMM (independent): Lab B25's dispatches compose to %.1f ms; the record permits "
              "%.1f-%.1f ms of in-encoder dispatch (linear_s8 %.1f ms less its share of the %.1f ms "
              "of lazily built images) -- %.3fx, %s"
              % (band["composed_dispatch_ms"], band["interval_lo_ms"], band["interval_hi_ms"],
                 lin_meas / CLK * 1e3, (model.get("image_cycles_once") or 0) / CLK * 1e3,
                 gemm_ratio, ok))
        print("       and so the runtime's own image build costs AT LEAST %.1f ms against Lab B25's "
              "%.1f ms for the same 36 matrices (%.2fx): the row-staging callback, paid once per "
              "model load" % (band["runtime_image_build_ms"], band["b25_image_build_ms"],
                              band["runtime_image_build_ms"] / max(1e-9, band["b25_image_build_ms"])))
    else:
        print("  B. GEMM (independent): composed %.1f ms vs measured %.1f ms = %.3fx -- %s"
              % (comp["linear_s8"]["cycles"] / CLK * 1e3, lin_meas / CLK * 1e3, gemm_ratio, ok))
    print("  C. TOTAL: composed %.1f ms vs measured %.1f ms = %.3fx"
          % (tot_c, verdict["measured_total_ms"], tot_c / max(1e-9, verdict["measured_total_ms"])))
    print("     of which THE TRANSFORMER STACK, the part a decoder shares: composed %.1f ms vs "
          "measured %.1f ms = %.3fx  (stem: %.1f vs %.1f)"
          % (tot_c - stem_c, tot_m - stem_m, (tot_c - stem_c) / max(1e-9, tot_m - stem_m),
             stem_c, stem_m))
    if on_engine:
        print("     (on the engine path the measured side carries the one-time weight-image build "
              "and the composed side does not, so this ratio reads low by construction; check B is "
              "the gate here)")
    if out is not None:
        out["self_check"] = verdict
    return verdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("tokens_pos", nargs="?", type=int)
    ap.add_argument("out_pos", nargs="?")
    ap.add_argument("--tokens", type=int, default=None)
    ap.add_argument("--calib")
    ap.add_argument("--b31", help="Lab B31 ladder run.json: size the residue costs with its "
                    "measured rungs instead of carrying an encoder-sized rate")
    ap.add_argument("--calib-int-model", help="B26 model for the integer unit costs (default: the best that ran)")
    ap.add_argument("--calib-float-model", help="B26 model for the float reference costs (default: enc_nl)")
    ap.add_argument("--out")
    ap.add_argument("--self-check", action="store_true",
                    help="compose the ENCODER by this same method and check it against Lab B26's "
                         "measured encoder -- a number the composition never consumes")
    ap.add_argument("--self-check-model", help="which Lab B26 model to check against (default: the "
                    "one the integer costs are calibrated from)")
    a = ap.parse_args()
    if a.self_check and not a.calib:
        sys.exit("--self-check needs --calib <Lab B26 run.json>: that run IS the known answer")
    tokens = a.tokens or a.tokens_pos or 15
    out_path = a.out or a.out_pos

    run = json.load(open(a.run))
    shapes = {s["name"]: s for s in run["shapes"]}
    chunk = {s["name"]: s for s in run.get("shapes_place_chunk", [])}
    missing = [k for k in list(PER_TOKEN) + list(PER_UTTERANCE) if k not in shapes]
    if missing:
        sys.exit("run.json lacks shapes %s" % missing)

    def total(fn, table):
        return sum(fn(k) * n for k, n in table.items())

    variants = {
        "core": lambda k: shapes[k]["core_cycles"],
        "engine": lambda k: shapes[k]["eng_h0_cycles"],
    }
    if all(k in chunk for k in list(PER_TOKEN) + list(PER_UTTERANCE)):
        variants["engine_place64"] = lambda k: chunk[k]["eng_h0_cycles"]

    def fill_at(k, F, base):
        """the dispatch with its measured fill cycles replaced by fill beats x 8 / F"""
        s = shapes[k]
        return base(k) - s["cyc_fill"] + 8.0 * s["fill_beats"] / F

    costs = {"s7": rp.COST}
    if a.calib:
        costs["B26"] = calibrate(a.calib, a.calib_int_model, a.calib_float_model)
        if a.b31:
            costs["B26+B31"] = apply_b31(copy.deepcopy(costs["B26"]), a.b31)
            del costs["B26"]
            print("  sized from Lab B31 %s: %s%s"
                  % (os.path.basename(a.b31),
                     ", ".join("%s<-%s" % (k, v) for k, v in sorted(apply_b31.applied.items())),
                     ("; REFUSED (control missed): " + ", ".join(apply_b31.refused))
                     if apply_b31.refused else ""))
        print("  calibrated from %s: integer costs %s, float reference costs %s"
              % (os.path.basename(os.path.dirname(os.path.abspath(a.calib))), *calibrate.models))

    out = {"bitstream_md5": run.get("bitstream_md5"), "tokens": tokens, "utterance_s": 4.0,
           "calib": ({"run": os.path.abspath(a.calib), "integer_model": calibrate.models[0],
                      "float_model": calibrate.models[1],
                      "bitstream_md5": json.load(open(a.calib)).get("bitstream_md5")} if a.calib else None),
           "composition": "sum of measured dispatches per token + priced non-GEMM residue",
           "gemm_per_token_ms": {}, "gemm_once_ms": {}, "residue_per_token_ms": {},
           "residue_contains_estimates": {}, "residue_by_kind_ms": {}, "token_ms": {},
           "size_extrapolated": {},
           "decoder_rtf": {}, "ports_projection": [],
           "per_shape": {k: {"count_per_token": PER_TOKEN.get(k), "count_per_utterance": PER_UTTERANCE.get(k),
                             **{v + "_ms": fn(k) / CLK * 1e3 for v, fn in variants.items()},
                             "fill_ms": shapes[k]["cyc_fill"] / CLK * 1e3,
                             "fill_b_per_cycle": 8.0 * shapes[k]["fill_beats"] / max(1, shapes[k]["cyc_fill"])}
                         for k in list(PER_TOKEN) + list(PER_UTTERANCE)}}

    if a.self_check:
        v = self_check(shapes, costs.get("B26", rp.COST), "nl+ew", a.calib, a.self_check_model, out)
        if (v["reference_graph"] and not v["populations_exact"]) or not v["gemm_within_25pct"]:
            if out_path:
                json.dump(out, open(out_path, "w"), indent=1)
                print("wrote", out_path)
            sys.exit("SELF-CHECK FAILED: the method that produces the decoder number does not "
                     "reproduce the encoder it was never shown.  Nothing composed below is "
                     "trustworthy until this is understood.")
        print("  SELF-CHECK PASSED -- the composition reproduces a measurement it never consumed.\n")

    print("Moonshine Tiny decoder, composed from Lab B25's measured dispatches (md5 %s), %d tokens, 4 s"
          % ((run.get("bitstream_md5") or "?")[:8], tokens))
    hdr = "  %-12s %6s" % ("shape", "x/tok") + "".join(" %15s" % (v + " ms") for v in variants)
    print(hdr)
    for k, n in PER_TOKEN.items():
        print("  %-12s %6d" % (k, n) + "".join(" %15.2f" % (fn(k) / CLK * 1e3) for fn in variants.values()))
    g_tok = {v: total(fn, PER_TOKEN) for v, fn in variants.items()}
    g_once = {v: total(fn, PER_UTTERANCE) for v, fn in variants.items()}
    for v in variants:
        out["gemm_per_token_ms"][v] = g_tok[v] / CLK * 1e3
        out["gemm_once_ms"][v] = g_once[v] / CLK * 1e3
    print("  GEMMs per token (measured sum): " + "   ".join("%s %.1f ms" % (v, g_tok[v] / CLK * 1e3) for v in variants))
    print("  cross-attention K,V once per utterance: " + "   ".join("%s %.1f ms" % (v, g_once[v] / CLK * 1e3) for v in variants))

    for cname, cost in costs.items():
        for sw in ("nl", "nl+ew"):
            key = "%s/%s" % (cname, sw)
            r, est, by = residue(cost, sw, tokens)
            out["residue_per_token_ms"][key] = r / CLK * 1e3
            out["residue_contains_estimates"][key] = est
            out["residue_by_kind_ms"][key] = {k: v / CLK * 1e3 for k, v in sorted(by.items(), key=lambda x: -x[1])}
            out["token_ms"][key] = {}
            out["decoder_rtf"][key] = {}
            line = []
            for v in variants:
                t_ms = (g_tok[v] + r) / CLK * 1e3
                rtf = ((g_once[v] + tokens * (g_tok[v] + r)) / CLK) / 4.0
                out["token_ms"][key][v] = t_ms
                out["decoder_rtf"][key][v] = rtf
                line.append("%s %.1f ms/tok, RTF %.2f" % (v, t_ms, rtf))
            print("  residue [%s%s] %.1f ms/token -> %s" % (key, ", contains estimates" if est else "",
                                                           r / CLK * 1e3, ";  ".join(line)))
            # SIZE PROVENANCE.  A cost measured on an encoder dispatch and spent on a decoder's is
            # not the same number; two of these have now been re-measured and moved +71 % and
            # -59 % (ROCC_DECOUPLED.md 8.15.16).  Say it on every composition, not in prose.
            ex = getattr(residue, "extrapolations", {})
            out["size_extrapolated"][key] = {k: {**v, "used_n": sorted(v["used_n"])}
                                             for k, v in ex.items()}
            if ex:
                print("    SIZE PROVENANCE -- %d cost%s used more than 10x from the dispatch size "
                      "measured:" % (len(ex), "" if len(ex) == 1 else "s"))
                for k, v in sorted(ex.items(), key=lambda x: -abs(math.log(x[1]["worst_ratio"]))):
                    print("      %-14s measured at n=%s (%s), used at n=%s  ->  %.0fx"
                          % (k, "{:,}".format(v["measured_n"]), v["kernel"] or "?",
                             ", ".join("{:,}".format(x) for x in sorted(v["used_n"])),
                             max(v["worst_ratio"], 1.0 / v["worst_ratio"])))

    # ---- projection: the same dispatches with a faster fill path --------------------------
    base_name = "engine_place64" if "engine_place64" in variants else "engine"
    base = variants[base_name]
    r_best = next((out["residue_per_token_ms"][k] for k in ("B26+B31/nl+ew", "B26/nl+ew")
                   if k in out["residue_per_token_ms"]), out["residue_per_token_ms"]["s7/nl+ew"])
    print("  PROJECTION from measured parts (%s; fill re-timed at another measured bandwidth; "
          "residue %s):" % (base_name, next((k for k in ("B26+B31/nl+ew", "B26/nl+ew")
                                              if k in out["residue_per_token_ms"]), "s7/nl+ew")))
    meas_fill = sum(shapes[k]["cyc_fill"] * n for k, n in PER_TOKEN.items())
    tok_meas = total(base, PER_TOKEN)
    print("    %-58s fill %6.1f ms  GEMM %6.1f ms/tok  token %6.1f ms" %
          ("as measured (SBUS, lever 1, 3 outstanding)", meas_fill / CLK * 1e3, tok_meas / CLK * 1e3,
           tok_meas / CLK * 1e3 + r_best))
    for name, F, src in PORTS:
        tok = sum(fill_at(k, F, base) * n for k, n in PER_TOKEN.items())
        once = sum(fill_at(k, F, base) * n for k, n in PER_UTTERANCE.items())
        fill = sum(8.0 * shapes[k]["fill_beats"] / F * n for k, n in PER_TOKEN.items())
        t_ms = tok / CLK * 1e3 + r_best
        rtf = (once / CLK + tokens * t_ms / 1e3) / 4.0
        out["ports_projection"].append({"port": name, "b_per_core_cycle": F, "source": src,
                                        "fill_ms_per_token": fill / CLK * 1e3,
                                        "gemm_ms_per_token": tok / CLK * 1e3,
                                        "token_ms": t_ms, "decoder_rtf": rtf, "label": "projection"})
        print("    %-58s fill %6.1f ms  GEMM %6.1f ms/tok  token %6.1f ms  RTF %.2f" %
              (name + " [%.2f B/c]" % F, fill / CLK * 1e3, tok / CLK * 1e3, t_ms, rtf))
    if out_path:
        json.dump(out, open(out_path, "w"), indent=1)
        print("wrote", out_path)


if __name__ == "__main__":
    main()
