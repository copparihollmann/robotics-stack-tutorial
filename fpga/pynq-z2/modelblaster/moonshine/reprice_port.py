#!/usr/bin/env python3
"""Moonshine Tiny, re-priced against the MEASURED memory port -- ROCC_DECOUPLED.md section 7.

WHAT CHANGED.  ROCC_DECOUPLED.md section 5.2 projected Moonshine Tiny at RTF 3.7 with the
`d_eng4` engine, against a fill rate SIMULATED by tb_mbxd_bw.sv (5.10 B/cycle at four
outstanding, 7.89 at eight).  MEMORY_BANDWIDTH.md then built mbxd_dma.v into silicon and
MEASURED it: the DRAM path peaks at 6.25 B/cycle at three outstanding, dips at four, and
tripling the memory clock moved it by -1 %, which attributes the cap to the L2's miss
handling in the core's clock domain.  This script re-prices against that, and it reads the
port rates out of fpga/pynq-z2/bwlab/results.csv rather than quoting them.

WHAT IT PRICES, AND WHAT IS AN ESTIMATE.  Every population below is COUNTED from
transformers v4.48.0 `modeling_moonshine.py` and the checkpoint's own config
(UsefulSensors/moonshine-tiny @ 390624ed; 27,092,736 parameters, which the counts below
reproduce).  Every unit cost is either MEASURED on this board -- cited to the table it
comes from -- or an ESTIMATE, and estimates carry `est=True` into the JSON and an `(est)`
mark into every printed row.  The product is an EXTRAPOLATION.  Nobody has run Moonshine
on this board when this script is first committed; section 8 of the document is where that
changes, and when it does the measured per-dispatch cycles replace these rows.

THREE CORRECTIONS TO fpga/pynq-z2/modelblaster/kws/reprice_stt.py's Moonshine model, which
this script supersedes for Moonshine (reprice_stt.py is left as it was, because section 5.2
quotes it):

  1. Its encoder layer norm counts `2*T` elements per layer where it should count `2*T*d`
     (the decoder rows count `d` correctly).  Under-priced by 288x.
  2. It prices none of the elementwise work: the residual `add` (two per encoder layer,
     three per decoder layer), rotary position embedding (two multiplies, a negation and
     an add over 32 of each head's 36 dimensions, on q and k), the stem's `tanh` and
     `GroupNorm`, and the decoder MLP's SiLU gate multiply.  On a core with no FPU those
     are ModelBlaster's float reference kernels, measured at ~700 cycles per element.
  3. Its engine term is max(MACs/32, weight_bytes/F), i.e. it assumes a tile's weights
     and activations are already in the scratchpad.  They are not: an 80 KB scratchpad
     holds a fraction of a 332 KB FFN matrix, so the fill traffic is the tiling traffic,
     and that is computed here.

Usage:
    python3 fpga/pynq-z2/modelblaster/moonshine/reprice_port.py            # print
    python3 fpga/pynq-z2/modelblaster/moonshine/reprice_port.py --json out.json
"""
from __future__ import annotations

import argparse, csv, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
RESULTS = os.path.join(ROOT, "fpga", "pynq-z2", "bwlab", "results.csv")

CLK = 34482759.0            # Hz, the core clock every cycle count here is in

# ---- Moonshine Tiny, from config.json @ 390624ed ------------------------------------
D, FF, H, HD, V = 288, 1152, 8, 36, 32768
ROT = int(HD * 0.9)          # partial_rotary_factor 0.9 -> 32 of 36 dims per head
LE, LD = 6, 6


# ======================================================================================
# Unit costs.  (cycles, measured?, where)
# ======================================================================================
def U(v, measured, src, n=None, kernel=None, ladder=None):
    """A unit cost, WITH THE DISPATCH SIZE IT WAS MEASURED AT.

    ROCC_DECOUPLED.md 8.15.17: `src` is prose, and prose does not survive being carried into a
    composition.  Two facts have to travel with the number instead -- the size `n` (elements per
    dispatch) and the `kernel` -- because the same operator name covers costs that differ by 7.6x
    (GELU at n = 8,192 has been measured here at 24.22, 31 and 185 cycles/element under three
    kernels) and the same kernel differs by 2.5x between an encoder's dispatch size and a
    decoder's.  c(key, n_used) then flags any use more than 10x away from `n`."""
    return {"v": float(v), "est": not measured, "src": src, "n": n, "kernel": kernel,
            "ladder": ladder}


def ladder_ratio(ladder, n):
    """How this kernel's per-element cost at n compares with its cost at the size the unit cost
    was measured at.  A RATIO and not an absolute, deliberately: Lab B31's bench and Lab B26's
    encoder build the same kernels with different flags, and the ratio cancels that offset while
    the absolute does not.  Log-interpolated between measured rungs, clamped outside them."""
    pts = sorted((int(k), float(v)) for k, v in ladder)
    top = pts[-1][1]
    if n <= pts[0][0]:
        return pts[0][1] / top
    if n >= pts[-1][0]:
        return pts[-1][1] / top
    for (n0, c0), (n1, c1) in zip(pts, pts[1:]):
        if n <= n1:
            f = (math.log(n) - math.log(n0)) / (math.log(n1) - math.log(n0))
            return (c0 + f * (c1 - c0)) / top
    return 1.0


COST = {
    # --- MBP on hart 0, measured -------------------------------------------------------
    # ROCC_DECOUPLED.md 2.2, ffn_block: 47,134,182 + 44,285,838 cycles over two 33.5 M MAC
    # dispatches = 1.36 c/MAC.  Those weight matrices are 262 KB against a 64 KB L2 and are
    # swept once per input row, so this number ALREADY INCLUDES the core streaming weights
    # from DRAM at one byte per MAC: it is the right baseline for decode's AI ~ 1 too.
    "linear_c_mac": U(91420020 / (2 * 128 * 256 * 1024), True, "ROCC_DECOUPLED.md 2.2, ffn_block"),
    # SPEECH_ON_ROCKET.md 11.4: digit_ctc_t, (1,k) kernels, time on W, KW 5 -> 1.24 c/MAC.
    "conv_w_c_mac": U(1.24, True, "SPEECH_ON_ROCKET.md 11.4, digit_ctc_t"),
    # same network, time on H, KW = 1 -> 20.92 c/MAC: the layout lever, measured.
    "conv_h_c_mac": U(20.92, True, "SPEECH_ON_ROCKET.md 11.4, digit_ctc_wide"),
    # matmul_s8 reduction per MAC: Lab B19 476 cycles/element at K = 32 minus the 244-cycle
    # float tail leaves ~7 c/MAC at K = 32, dominated by per-element setup; at attention
    # K = 36 the reduction proper is DOT8-shaped, so take the linear kernel's rate.
    "matmul_c_mac": U(1.36, False, "ESTIMATE: DOT8-shaped reduction at the linear rate"),
    # --- integer kernels (pext_nl), measured -----------------------------------------------
    "softmax_int": U(168, True, "ROCC_DECOUPLED.md 1, Lab B20, K>=128", n=128, kernel="pext_int"),
    "layernorm_int": U(69, True, "Lab B20, K=512 (70 at K=256)", n=512, kernel="pext_int"),
    "matmul_rq_int": U(37, True, "ROCC_DECOUPLED.md 1.2"),
    "matmul_rq_float": U(244, True, "ROCC_DECOUPLED.md 1.2"),
    # --- float reference kernels, measured -------------------------------------------------
    "add_float": U(23142103 / 32768, True, "ROCC_DECOUPLED.md 2.2, ffn_block add_s8", n=32768,
                       kernel="float reference"),
    "mul_float": U((180234 + 180734 + 180631) / (3 * 256), True,
                      "ROCC_DECOUPLED.md 2.2, attn_block mul_s8", n=256, kernel="float reference"),
    "layernorm_float": U(1157, True, "Lab B20, K=512", n=512, kernel="float reference"),
    "softmax_float": U(5543, True, "Lab B20, K=512", n=512, kernel="float reference"),
    # --- NOT MEASURED ------------------------------------------------------------------------
    # tanh_s8 has no kernel in ModelBlaster at all.  A float tanhf per element is the same
    # expm1/expf shape as erff, so it is priced at the float GELU's uniform-input cost.
    "tanh_float": U(5323, False, "ESTIMATE: no tanh_s8 kernel exists; float gelu_s8's 5,323"),
    # GroupNorm(1, C) is a layer norm over C*T elements instead of C.
    "groupnorm_float": U(1157, False, "ESTIMATE: no groupnorm_s8 kernel; float layernorm's 1,157"),
    "groupnorm_int": U(69, False, "ESTIMATE: integer layernorm's 69"),
    "silu_float": U(5323, False, "ESTIMATE: sigmoid via expf, priced as float gelu"),
    # integer elementwise: nothing written.  37 is the measured integer requantise loop
    # (one QMUL-shaped multiply + round + clamp per element); add/mul need two of those.
    "add_int": U(2 * 37, False, "ESTIMATE: two integer requantise terms per element"),
    "mul_int": U(37, False, "ESTIMATE: one integer requantise per element"),
    "neg_int": U(10, False, "ESTIMATE: a byte negate and clamp"),
    # RoPE.  This programme used to price it as four elementwise passes over the 32 rotary dims
    # (mul, neg, mul, add).  ModelBlaster runs ONE fused `rope_s8` dispatch over the whole of D,
    # and decode_compose.py --self-check caught the difference: 1,774,080 elements composed
    # against 570,240 dispatched, a 3.111x over-count that cost 1.91x in cycles.  The defaults
    # below are what the four-pass model implied PER FUSED ELEMENT (153 integer cycles, or 2,464
    # float, over the 1.125 rotary elements that share one element of D), kept as estimates;
    # decode_compose.calibrate() replaces both with Lab B26's measured rope_s8.
    "rope_int": U(153 / 1.125, False, "ESTIMATE: the old four-pass model, per fused element"),
    "rope_float": U(2464 / 1.125, False, "ESTIMATE: the same, with the measured float mul/add"),
}


def gelu_int(n):
    """Integer GELU cycles/element at dispatch size n (Lab B20, measured; log-interpolated).
    The table build is paid per DISPATCH, so a 1,152-element decoder FFN activation pays
    ~7x per element what the 131,072-element measurement does."""
    pts = [(256, 294), (2048, 74), (8192, 31), (16384, 25), (131072, 20)]
    if n <= pts[0][0]:
        return pts[0][1] * pts[0][0] / n
    for (n0, c0), (n1, c1) in zip(pts, pts[1:]):
        if n <= n1:
            f = (math.log(n) - math.log(n0)) / (math.log(n1) - math.log(n0))
            return c0 + f * (c1 - c0)
    return 20.0


# ======================================================================================
# The measured port, read from the bandwidth log.
# ======================================================================================
def measured_port(path=RESULTS, magic="0x5A5A0007"):
    best = {}
    core = {}
    for r in csv.DictReader(open(path)):
        if r["source"] != "silicon" or r["soc_magic"] != magic:
            continue
        lvl, bpc = r["level"], float(r["bytes_per_cycle"])
        if r["notes"].startswith("core"):
            core[lvl] = bpc
        elif r["notes"].startswith("mbxd_dma"):
            k = (lvl, int(r["outstanding"]))
            best[k] = max(best.get(k, 0.0), bpc)
    dram = {o: v for (l, o), v in best.items() if l == "DRAM"}
    l2 = {o: v for (l, o), v in best.items() if l == "L2"}
    o_peak = max(dram, key=dram.get)
    return {"core_dram": core["DRAM"], "core_l2": core["L2"],
            "dram": dram, "l2": l2, "dram_peak": dram[o_peak], "dram_peak_out": o_peak,
            "l2_peak": max(l2.values()),
            "rt_dram_1": 64.0 / dram[1], "rt_l2_1": 64.0 / l2[1]}


def bypass_bounds(port):
    """What an MBUS attach (bypassing the L2) can deliver, DERIVED, with each assumption
    named.  Each row carries three numbers:

      lower  -- the MEASURED 6.25 B/cycle behind the L2.  A bypass cannot do worse than the
                same downstream path with the L2's work added to it, so this holds whatever
                MEMORY_BANDWIDTH.md section 6 finds.
      F      -- the ESTIMATE if section 3.5's attribution is right (the cap is L2 miss
                handling, in front of the port).  This is the value the tables use.
      upper  -- the ceiling of the link the client sits on.

    If section 6's falsification fires -- more MSHRs AND a faster L2 clock both leave the
    plateau where it is -- the cap is behind the L2 and every row collapses to `lower`."""
    rt_dram, rt_l2 = port["rt_dram_1"], port["rt_l2_1"]
    measured = port["dram_peak"]
    # The L2 serves a block-aligned miss WORMHOLE (MSHR.scala:489-490, w_grant := offset==0
    # || last): it does not store the block and then forward it.  So the DRAM round trip is
    # the L2's own request pipeline + its miss handling + the outer round trip.  The L2's
    # request pipeline is what the L2-HIT round trip measures minus its eight beats; an MBUS
    # client pays neither that nor the miss handling.  Hence an UPPER bound on the round
    # trip an MBUS client sees:
    hit_pipeline = rt_l2 - 8.0
    rt_bypass_max = rt_dram - hit_pipeline
    per_txn_min = 64.0 / rt_bypass_max
    link = 8.0                                   # 64-bit beat, one per cycle
    out = []
    need = math.ceil(link / per_txn_min)
    out.append(dict(label="MBUS attach, core clock, 1 HP port (lever 1 + item 13)",
                    F=min(link, need * per_txn_min), lower=measured, upper=link,
                    derivation=("round trip <= %.1f - (%.1f - 8) = %.1f cycles -> >= %.2f B/cycle "
                                "per transaction -> the 8.00 B/cycle link is reached at %d outstanding"
                                % (rt_dram, rt_l2, rt_bypass_max, per_txn_min, need)),
                    assumes="TLToAXI4, the AXI4->AXI3 shim and S_AXI_HP0 accept >= %d outstanding reads" % need))
    # + lever 2: the MBUS client, the fill FSM and the BRAM write port in a 100 MHz memory
    # domain; the BRAM is the clock-domain crossing.  Ceiling: one 64-bit beat per MEMORY
    # cycle.  Latency: if every one of the <= rt_bypass_max core cycles were physical time
    # (a PS DDR controller does not speed up with the PL clock), it is rt_bypass_max *
    # f_mem / f_core memory cycles -- the pessimistic end.
    fm = 100.0e6
    ratio = fm / CLK
    rt_mem = rt_bypass_max * ratio
    per_txn_mem = 64.0 / rt_mem
    est2 = min(8.0, 8 * per_txn_mem) * ratio        # eight outstanding
    out.append(dict(label="+ lever 2: fill path on a 100 MHz memory clock",
                    F=est2, lower=measured, upper=8.0 * ratio,
                    derivation=("8 B per memory cycle = %.1f B per core cycle; eight outstanding at a "
                                "worst-case %.0f-memory-cycle round trip gives %.1f"
                                % (8.0 * ratio, rt_mem, est2)),
                    assumes=("the fill FSM and the scratchpad's BRAM write port move to the memory "
                             "domain (an engine left in the core domain re-caps at 8.00); S_AXI_HP0 "
                             "accepts 8 outstanding reads; FCLK1 set AND READ BACK at 100 MHz "
                             "(lever 2's rows ran at an unset 142.857 MHz -- bwlab/errata.csv)")))
    out.append(dict(label="+ lever 3: two HP ports, one fill client on each",
                    F=2 * est2, lower=measured, upper=16.0 * ratio,
                    derivation="two independent 64-bit D channels at 100 MHz",
                    assumes=("two fill clients (one 64-bit client's D channel is the cap, so a "
                             "second port alone adds nothing); mbus xbar routes them in parallel; "
                             "the DDR3 controller (~2,100 MB/s, MEMORY_BANDWIDTH.md 0) is not reached")))
    return out, dict(hit_pipeline=hit_pipeline, rt_bypass_max=rt_bypass_max,
                     per_txn_min=per_txn_min, rt_mem_worst=rt_mem)


# ======================================================================================
# Populations, from modeling_moonshine.py v4.48.0.
# ======================================================================================
def conv_out(n, k, s):
    return (n - k) // s + 1


def op(kind, name, **kw):
    d = dict(kind=kind, name=name, macs=0, wb=0, els=0)
    d.update(kw)
    return d


def encoder(utt_s):
    n = int(utt_s * 16000)
    t1 = conv_out(n, 127, 64)
    t2 = conv_out(t1, 7, 3)
    T = conv_out(t2, 3, 2)
    L = []
    a = L.append
    # stem: conv1 (no bias) -> tanh -> GroupNorm(1, 288) -> conv2 -> GELU -> conv3 -> GELU
    a(op("conv", "conv1", M=t1, K=127, N=D, IC=1, KW=127, stride=64, macs=t1 * 127 * D, wb=127 * D, els=t1 * D))
    a(op("tanh", "conv1.tanh", els=t1 * D))
    a(op("groupnorm", "groupnorm", els=t1 * D))
    a(op("conv", "conv2", M=t2, K=D * 7, N=2 * D, IC=D, KW=7, stride=3, macs=t2 * D * 7 * 2 * D,
         wb=D * 7 * 2 * D + 4 * 2 * D, els=t2 * 2 * D))
    a(op("gelu", "conv2.gelu", els=t2 * 2 * D))
    a(op("conv", "conv3", M=T, K=2 * D * 3, N=D, IC=2 * D, KW=3, stride=2, macs=T * 2 * D * 3 * D,
         wb=2 * D * 3 * D + 4 * D, els=T * D))
    a(op("gelu", "conv3.gelu", els=T * D))
    for l in range(LE):
        a(op("layernorm", "e%d.ln1" % l, els=T * D))
        for p in "qkv":
            a(op("linear", "e%d.%s" % (l, p), M=T, K=D, N=D, macs=T * D * D, wb=D * D, els=T * D))
        for p in "qk":
            # ONE fused dispatch over the whole of D -- see the `rope` note in COST.  Lab B26
            # profiles 12 rope_s8 dispatches of T*D elements, and --self-check caught the 3.111x
            # over-count the four-pass model produced.
            a(op("rope", "e%d.rope.%s" % (l, p), els=T * D))
        a(op("matmul", "e%d.qk" % l, M=H * T, K=HD, N=T, macs=H * T * T * HD, els=H * T * T))
        a(op("softmax", "e%d.softmax" % l, els=H * T * T))
        a(op("matmul", "e%d.av" % l, M=H * T, K=T, N=HD, macs=H * T * T * HD, els=H * T * HD))
        a(op("linear", "e%d.o" % l, M=T, K=D, N=D, macs=T * D * D, wb=D * D, els=T * D))
        a(op("add", "e%d.res1" % l, els=T * D))
        a(op("layernorm", "e%d.ln2" % l, els=T * D))
        a(op("linear", "e%d.fc1" % l, M=T, K=D, N=FF, macs=T * D * FF, wb=D * FF + 4 * FF, els=T * FF))
        a(op("gelu", "e%d.gelu" % l, els=T * FF))
        a(op("linear", "e%d.fc2" % l, M=T, K=FF, N=D, macs=T * FF * D, wb=FF * D + 4 * D, els=T * D))
        a(op("add", "e%d.res2" % l, els=T * D))
    a(op("layernorm", "enc.norm", els=T * D))
    return T, L


def decoder_once(T):
    """Cross-attention K and V over the encoder output: once per utterance, then cached."""
    L = []
    for l in range(LD):
        for p in "kv":
            L.append(op("linear", "d%d.x%s" % (l, p), M=T, K=D, N=D, macs=T * D * D, wb=D * D, els=T * D))
    return L


def decoder_token(T, seq):
    """One output token.  seq = self-attention cache depth."""
    L = []
    a = L.append
    a(op("embed", "embed", wb=D, els=D))
    for l in range(LD):
        a(op("layernorm", "d%d.ln1" % l, els=D))
        for p in "qkv":
            a(op("linear", "d%d.%s" % (l, p), M=1, K=D, N=D, macs=D * D, wb=D * D, els=D))
        for p in "qk":
            a(op("rope", "d%d.rope.%s" % (l, p), els=D))     # one fused dispatch, one row
        a(op("matmul", "d%d.qk" % l, M=H, K=HD, N=seq, macs=H * seq * HD, els=H * seq))
        a(op("softmax", "d%d.softmax" % l, els=H * seq))
        a(op("matmul", "d%d.av" % l, M=H, K=seq, N=HD, macs=H * seq * HD, els=H * HD))
        a(op("linear", "d%d.o" % l, M=1, K=D, N=D, macs=D * D, wb=D * D, els=D))
        a(op("add", "d%d.res1" % l, els=D))
        a(op("layernorm", "d%d.ln2" % l, els=D))
        a(op("linear", "d%d.xq" % l, M=1, K=D, N=D, macs=D * D, wb=D * D, els=D))
        a(op("matmul", "d%d.xqk" % l, M=H, K=HD, N=T, macs=H * T * HD, els=H * T))
        a(op("softmax", "d%d.xsoftmax" % l, els=H * T))
        a(op("matmul", "d%d.xav" % l, M=H, K=T, N=HD, macs=H * T * HD, els=H * HD))
        a(op("linear", "d%d.xo" % l, M=1, K=D, N=D, macs=D * D, wb=D * D, els=D))
        a(op("add", "d%d.res2" % l, els=D))
        a(op("layernorm", "d%d.ln3" % l, els=D))
        a(op("linear", "d%d.fc1" % l, M=1, K=D, N=2 * FF, macs=D * 2 * FF, wb=D * 2 * FF + 4 * 2 * FF, els=2 * FF))
        a(op("silu", "d%d.silu" % l, els=FF))
        a(op("mul", "d%d.gate" % l, els=FF))
        a(op("linear", "d%d.fc2" % l, M=1, K=FF, N=D, macs=FF * D, wb=FF * D + 4 * D, els=D))
        a(op("add", "d%d.res3" % l, els=D))
    a(op("layernorm", "dec.norm", els=D))
    # The tied output projection: the embedding matrix read as a 288 x 32,768 linear.
    a(op("linear", "lm_head", M=1, K=D, N=V, macs=D * V, wb=D * V, els=V))
    return L


def param_count():
    """Recount the checkpoint from the same shapes, as a check on the populations."""
    p = 127 * D + (D * 7 * 2 * D + 2 * D) + (2 * D * 3 * D + D) + 2 * D     # stem + groupnorm
    enc_layer = 4 * D * D + (D * FF + FF) + (FF * D + D) + 2 * D
    dec_layer = 8 * D * D + (D * 2 * FF + 2 * FF) + (FF * D + D) + 3 * D
    return p + LE * enc_layer + D + V * D + LD * dec_layer + D


# ======================================================================================
# Pricing
# ======================================================================================
# Every use of a cost more than 10x from the size it was measured at, recorded rather than
# remembered.  decode_compose.py prints it and puts it in the JSON; reset it before a composition.
EXTRAPOLATIONS = {}


def c(key, n=None):
    u = COST[key]
    if n and u.get("ladder"):
        # measured AT this size (or interpolated between rungs that bracket it): no extrapolation
        return u["v"] * ladder_ratio(u["ladder"], n)
    if n and u.get("n"):
        r = float(n) / float(u["n"])
        if r < 0.1 or r > 10.0:
            d = EXTRAPOLATIONS.setdefault(key, {"measured_n": u["n"], "kernel": u.get("kernel"),
                                                "src": u["src"], "used_n": [], "worst_ratio": 1.0})
            if n not in d["used_n"]:
                d["used_n"].append(n)
            if abs(math.log(r)) > abs(math.log(d["worst_ratio"])):
                d["worst_ratio"] = r
    return u["v"]


def e(*keys):
    """Is any of these costs an estimate AS IT STANDS NOW?

    The flags below used to be written out per kind, which was right for the default table and
    WRONG once decode_compose.calibrate() had replaced a cost with a board measurement: a
    composition calibrated on Lab B30 reported 67 % of its residue as estimate when four of its
    blocks were measured.  Ask the table instead."""
    return any(COST[k]["est"] for k in keys)


def core_cycles(o, sw):
    """Cycles on hart 0.  sw selects the software baseline:
       'nl'    -- pext_nl as registered today: integer softmax/LN/GELU/matmul tail, float
                  add/mul (measured), tanh/GroupNorm/SiLU with no kernel (estimated)
       'nl+ew' -- plus integer elementwise and norm kernels that do not exist yet (ESTIMATE)
    Returns (cycles, uses_estimate)."""
    k = o["kind"]
    ew = sw == "nl+ew"
    if k == "linear":
        return o["macs"] * c("linear_c_mac"), False
    if k == "conv":
        return o["macs"] * c("conv_w_c_mac"), False
    if k == "matmul":
        rq = c("matmul_rq_int", o["els"])
        return o["macs"] * c("matmul_c_mac") + o["els"] * rq, e("matmul_c_mac", "matmul_rq_int")
    if k == "softmax":
        return o["els"] * c("softmax_int", o["els"]), e("softmax_int")
    if k == "layernorm":
        return o["els"] * c("layernorm_int", o["els"]), e("layernorm_int")
    if k == "gelu":
        return o["els"] * gelu_int(o["els"]), False
    if k == "add":
        return o["els"] * c("add_int" if ew else "add_float", o["els"]), e("add_int" if ew else "add_float")
    if k == "mul":
        return o["els"] * c("mul_int" if ew else "mul_float", o["els"]), e("mul_int" if ew else "mul_float")
    if k == "rope":
        return o["els"] * c("rope_int" if ew else "rope_float", o["els"]), e("rope_int" if ew else "rope_float")
    if k == "neg":
        return o["els"] * c("neg_int" if ew else "mul_float"), True   # no kernel measures a negate
    if k == "tanh":
        # a 256-value pointwise map, exactly like GELU: the memo table is the lever
        return o["els"] * (gelu_int(o["els"]) if ew else c("tanh_float", o["els"])), True
    if k == "groupnorm":
        return o["els"] * c("groupnorm_int" if ew else "groupnorm_float", o["els"]), \
               e("groupnorm_int" if ew else "groupnorm_float")
    if k == "silu":
        # ESTIMATE whatever the cost table says: SiLU priced as GELU is a model, not a measurement
        return o["els"] * (gelu_int(o["els"]) if ew else c("silu_float", o["els"])), True
    if k == "embed":
        return o["els"] * 1.0, True
    raise KeyError(k)


# ---- the engine ------------------------------------------------------------------------
class Engine:
    """d_eng4 with the scratchpad this document builds (section 7.5):

    NCH weight read ports and one activation port, GRP = 4 BRAM36 banks each, 512 64-bit
    words per bank: 16 KB per port, halved by double buffering to 8 KB per buffer.  Weights
    are PLANAR -- each weight port's banks hold only the rows its lane reads -- so a weight
    tile is NCH x 8 KB.  (As priced out of context, mbxd_spad fills a flat address into one
    bank group, which would force the weights to be replicated into all NCH groups and
    quarter that; see section 7.5.)
    """

    def __init__(self, nch=4, spad_kb_per_port=16, c_tile=300.0, c_dispatch=5000.0):
        self.nch = nch
        self.w = 8.0 * nch                       # MAC/cycle
        self.buf = spad_kb_per_port * 1024 // 2  # bytes per buffer per port
        self.c_tile = c_tile                     # hart-1 command overhead per tile (ESTIMATE)
        self.c_dispatch = c_dispatch             # hart-0 -> hart-1 handoff (ESTIMATE)

    def tiling(self, o):
        """(traffic_bytes, n_tiles).  Refill the smaller operand once per tile of the larger."""
        M, K, N = o["M"], o["K"], o["N"]
        kw = K + (-K) % 8
        stride = o.get("stride_bytes", kw)       # act bytes between successive rows/pixels
        act_bytes = (M - 1) * stride + kw
        w_bytes = N * kw
        a_rows = max(1, (self.buf - kw) // stride + 1)
        w_rows = max(1, self.nch * self.buf // kw // self.nch * self.nch)
        a_tiles = math.ceil(M / a_rows)
        w_tiles = math.ceil(N / w_rows)
        if a_tiles == 1 and w_tiles == 1:
            return act_bytes + w_bytes, 1
        weights_outer = w_tiles * act_bytes + w_bytes
        acts_outer = a_tiles * w_bytes + act_bytes
        return min(weights_outer, acts_outer), a_tiles * w_tiles

    def cycles(self, o, F, F_act=None):
        traffic, tiles = self.tiling(o)
        fill = traffic / F
        compute = o["macs"] / self.w
        drain = o["M"] * o["N"] / (F_act or F)
        # max(): double buffering lets the next tile fill while this one computes, which is
        # what makes the two overlap.  The sum is the no-overlap bound and is reported too.
        return (max(fill, compute) + drain + tiles * self.c_tile + self.c_dispatch,
                fill + compute + drain + tiles * self.c_tile + self.c_dispatch,
                dict(traffic=traffic, tiles=tiles, fill=fill, compute=compute,
                     ai=o["macs"] / traffic))


def engine_eligible(o, with_conv):
    return o["kind"] == "linear" or (with_conv and o["kind"] == "conv" and o["name"] != "conv1")


def price_phase(ops, sw, eng=None, F=None, with_conv=False):
    tot = tot_nooverlap = 0.0
    est = False
    rows = []
    for o in ops:
        if eng is not None and engine_eligible(o, with_conv):
            if o["kind"] == "conv":
                o = dict(o, stride_bytes=o["stride"] * o["IC"] + (-(o["stride"] * o["IC"])) % 8)
            cy, cy2, info = eng.cycles(o, F)
            est = True
            rows.append((o["name"], cy, info))
        else:
            cy, e = core_cycles(o, sw)
            cy2 = cy
            est = est or e
        tot += cy
        tot_nooverlap += cy2
    return tot, tot_nooverlap, est, rows


def by_kind(ops, sw):
    out = {}
    for o in ops:
        cy, e = core_cycles(o, sw)
        r = out.setdefault(o["kind"], dict(cycles=0.0, macs=0, els=0, wb=0, est=False))
        r["cycles"] += cy
        r["macs"] += o["macs"]
        r["els"] += o["els"]
        r["wb"] += o["wb"]
        r["est"] = r["est"] or e
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--utt-s", type=float, default=4.0)
    ap.add_argument("--tokens", type=int, default=15)
    ap.add_argument("--json", default=None)
    a = ap.parse_args()

    port = measured_port()
    bypass, bdeets = bypass_bounds(port)
    T, enc = encoder(a.utt_s)
    once = decoder_once(T)
    seq = max(1, (a.tokens + 1) // 2)
    tok = decoder_token(T, seq)
    out = {"model": "UsefulSensors/moonshine-tiny@390624ed", "utt_s": a.utt_s,
           "tokens": a.tokens, "encoder_frames": T, "params_recount": param_count(),
           "port": port, "bypass": bypass, "bypass_derivation": bdeets,
           "costs": COST, "clock_hz": CLK}

    P = lambda s: print(s)
    P("=" * 96)
    P("Moonshine Tiny against the MEASURED port   (ROCC_DECOUPLED.md section 7)")
    P("=" * 96)
    P("parameters recounted from these shapes: {:,} (checkpoint: 27,092,736)".format(param_count()))
    P("utterance %.1f s -> %d encoder frames; %d tokens, mean self-attention depth %d"
      % (a.utt_s, T, a.tokens, seq))

    P("\n-- the port, from fpga/pynq-z2/bwlab/results.csv (0x5A5A0007, silicon)")
    P("   core DRAM %.2f  L2 %.2f B/cycle;  mbxd_dma DRAM peak %.2f at %d outstanding, L2 %.2f"
      % (port["core_dram"], port["core_l2"], port["dram_peak"], port["dram_peak_out"], port["l2_peak"]))
    P("   round trip at one outstanding: DRAM %.1f cycles, L2 hit %.1f cycles"
      % (port["rt_dram_1"], port["rt_l2_1"]))

    P("\n-- item 13: the bypass, DERIVED (an estimate, bounded -- not a measurement)")
    for b in bypass:
        P("   %-58s F = %5.2f B/cycle if 3.5 holds (measured floor %.2f, ceiling %.1f)"
          % (b["label"], b["F"], b["lower"], b["upper"]))
        P("      %s" % b["derivation"])
        P("      assumes: %s" % b["assumes"])

    for label, ops, mult in (("ENCODER", enc, 1), ("DECODER, once per utterance", once, 1),
                             ("DECODER, per token", tok, a.tokens)):
        macs = sum(o["macs"] for o in ops)
        wb = sum(o["wb"] for o in ops)
        P("\n-- %s: %.1f M MAC, %.2f MB weights%s" % (label, macs / 1e6, wb / 1e6,
          ", AI %.2f MAC/byte" % (macs / wb) if label.endswith("token") else ""))
        for sw in ("nl", "nl+ew"):
            bk = by_kind(ops, sw)
            tot = sum(r["cycles"] for r in bk.values())
            P("   software baseline %-6s %9.1f ms %s" % (sw, tot / CLK * 1e3, "(contains estimates)"))
            for k, r in sorted(bk.items(), key=lambda kv: -kv[1]["cycles"]):
                P("      %-10s %6.1f %%  %9.1f ms  %s MAC  %s el%s"
                  % (k, 100 * r["cycles"] / tot, r["cycles"] / CLK * 1e3,
                     "{:>12,}".format(r["macs"]), "{:>10,}".format(r["els"]), "  (est)" if r["est"] else ""))
            out.setdefault("baseline", {}).setdefault(label, {})[sw] = {
                k: dict(v, ms=v["cycles"] / CLK * 1e3) for k, v in bk.items()}

    # ---- engine sizing: AI per encoder GEMM at the measured port -----------------------
    eng = Engine()
    P("\n-- sizing (section 7.5): encoder GEMM tiles with a 16 KB/port double-buffered scratchpad,"
      " planar weights, NCH = 4")
    P("   %-8s %6s %6s %6s %8s %7s %8s %8s %12s" % ("layer", "M", "K", "N", "traffic", "tiles", "AI",
                                                  "NCH<=", "fill/compute"))
    sizing = []
    F = port["dram_peak"]
    seen = set()
    for o in enc:
        if o["kind"] not in ("linear", "conv"):
            continue
        key = o["name"].split(".")[-1]
        if key in seen:
            continue
        seen.add(key)
        oo = dict(o, stride_bytes=o["stride"] * o["IC"] + (-(o["stride"] * o["IC"])) % 8) if o["kind"] == "conv" else o
        traffic, tiles = eng.tiling(oo)
        ai = o["macs"] / traffic
        nch = F * ai / 8.0
        sizing.append(dict(layer=key, M=o["M"], K=o["K"], N=o["N"], traffic=traffic, tiles=tiles,
                           ai=ai, nch_max=nch))
        P("   %-8s %6d %6d %6d %7.0fK %7d %8.1f %8.1f %12.2f"
          % (key, o["M"], o["K"], o["N"], traffic / 1024, tiles, ai, nch,
             (traffic / F) / (o["macs"] / eng.w)))
    decode_ai = sum(o["macs"] for o in tok) / sum(o["wb"] for o in tok)
    P("   decode step: AI %.2f -> NCH <= %.2f at F = %.2f" % (decode_ai, F * decode_ai / 8, F))
    out["sizing"] = dict(F=F, rows=sizing, decode_ai=decode_ai)

    # ---- the table the section is for ----------------------------------------------------
    P("\n-- ENCODER and DECODER, separately.  RTF = seconds of compute per second of audio.")
    Fs = [("core only (pext_nl)", None)]
    Fs += [("engine @ %.2f measured, behind the L2" % port["dram_peak"], port["dram_peak"])]
    Fs += [("engine @ %.2f bypass, core clock (est)" % bypass[0]["F"], bypass[0]["F"])]
    Fs += [("engine @ %.1f bypass + lever 2 (est)" % bypass[1]["F"], bypass[1]["F"])]
    Fs += [("engine @ %.1f bypass + levers 2,3 (est)" % bypass[2]["F"], bypass[2]["F"])]
    table = []
    P("   %-44s %-6s %9s %9s %11s %10s %9s %9s" % ("", "sw", "enc RTF", "enc+conv", "dec ms/tok",
                                                 "dec RTF", "all RTF", "all+conv"))
    for sw in ("nl", "nl+ew"):
        for lab, Fv in Fs:
            if Fv is None:
                ce = price_phase(enc, sw)[0]
                cec = ce
                co = price_phase(once, sw)[0]
                ct = price_phase(tok, sw)[0]
            else:
                ce = price_phase(enc, sw, eng, Fv)[0]
                cec = price_phase(enc, sw, eng, Fv, with_conv=True)[0]
                co = price_phase(once, sw, eng, Fv)[0]
                ct = price_phase(tok, sw, eng, Fv)[0]
            enc_rtf = ce / CLK / a.utt_s
            encc_rtf = cec / CLK / a.utt_s
            dec_s = (co + ct * a.tokens) / CLK
            row = dict(sw=sw, config=lab, F=Fv, enc_rtf=enc_rtf, enc_conv_rtf=encc_rtf,
                       dec_ms_per_token=ct / CLK * 1e3, dec_once_s=co / CLK,
                       dec_rtf=dec_s / a.utt_s, all_rtf=enc_rtf + dec_s / a.utt_s,
                       all_conv_rtf=encc_rtf + dec_s / a.utt_s)
            table.append(row)
            P("   %-44s %-6s %9.2f %9.2f %11.1f %10.2f %9.2f %9.2f"
              % (lab, sw, enc_rtf, encc_rtf, row["dec_ms_per_token"], row["dec_rtf"], row["all_rtf"],
                 row["all_conv_rtf"]))
    out["table"] = table

    # ---- decode: what binds, per token --------------------------------------------------
    P("\n-- DECODE, per token: the memory floor against everything else")
    tok_w = sum(o["wb"] for o in tok if o["kind"] == "linear")
    tok_mac = sum(o["macs"] for o in tok if o["kind"] == "linear")
    dec_rows = []
    for sw in ("nl", "nl+ew"):
        rest = sum(core_cycles(o, sw)[0] for o in tok if o["kind"] != "linear")
        for lab, Fv in Fs[1:]:
            mem = tok_w / Fv
            arr = tok_mac / eng.w
            dec_rows.append(dict(sw=sw, config=lab, F=Fv, memory_ms=mem / CLK * 1e3,
                                 array_ms=arr / CLK * 1e3, core_rest_ms=rest / CLK * 1e3,
                                 nch_fed=Fv * tok_mac / tok_w / 8.0))
            P("   %-6s %-44s memory %6.1f ms  32-MAC array %5.1f ms  core residue %7.1f ms  NCH fed %.1f"
              % (sw, lab, mem / CLK * 1e3, arr / CLK * 1e3, rest / CLK * 1e3, Fv * tok_mac / tok_w / 8))
    out["decode"] = dec_rows
    out["weight_traffic"] = dict(
        per_token_bytes=sum(o["wb"] for o in tok), once_bytes=sum(o["wb"] for o in once),
        encoder_bytes=sum(o["wb"] for o in enc),
        utterance_bytes=sum(o["wb"] for o in enc) + sum(o["wb"] for o in once)
        + a.tokens * sum(o["wb"] for o in tok))
    wt = out["weight_traffic"]
    P("\n-- weight traffic for the utterance: %.1f MB; at %.2f B/cycle (%.1f MB/s) that is %.2f s"
      % (wt["utterance_bytes"] / 1e6, port["dram_peak"], port["dram_peak"] * CLK / 1e6,
         wt["utterance_bytes"] / port["dram_peak"] / CLK))

    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=1, default=float)
        P("\nwrote %s" % a.json)


if __name__ == "__main__":
    main()
