#!/usr/bin/env python3
"""Re-price SPEECH_ON_ROCKET.md section 6's STT rows from MEASURED per-element costs.

Section 6 divides a published MAC count by the measured 22.4 MMAC/s and says in as many
words that the result is a lower bound on the work rather than an estimate of the time,
because the operators a transformer needs are 28 of ModelBlaster's 43 float-tainted
kernels.  Lab B19 measured what those cost per element on this silicon.  This turns the
caveat into a number.

Everything here is an EXTRAPOLATION -- a measured unit cost multiplied by a counted
element population -- and it is labelled as one.  The unit costs are measured; the
element counts come from the published architecture; nobody has run Whisper on this board
and this script does not pretend otherwise.
"""
from __future__ import annotations

import argparse, json, os, re, sys

CLK = 34482759
MBP_MMAC = 22.4e6        # section 1.2, measured


def measured_costs(run):
    """cycles per output element, per op, from Lab B19's manifests."""
    cost = {}
    for m in ("norm_block", "attn_block", "ffn_block"):
        gp, cp = f"{run}/{m}/ir/graph.json", f"{run}/{m}/console.txt"
        if not (os.path.exists(gp) and os.path.exists(cp)):
            continue
        g = json.load(open(gp))
        prof = {}
        for l in open(cp):
            if l.startswith("MB_PEXT_OP "):
                d = dict(re.findall(r'(\w+)=(\S+)', l))
                prof[d["name"]] = int(d["cycles"])
        for o in g["ops"]:
            if o["name"] not in prof:
                continue
            s = o.get("shape", {})
            if "n" in s:
                els = s["n"]
            elif "N" in s and "M" in s:
                els = s["M"] * s["N"]
            elif "M" in s and "K" in s:
                els = s["M"] * s["K"]
            else:
                continue
            c = prof[o["name"]] / els
            # keep the LARGEST shape seen for each op: the small ones carry more
            # per-dispatch setup and would flatter the extrapolation
            prev = cost.get(o["op"])
            if prev is None or els > prev[1]:
                cost[o["op"]] = (c, els)
    return {k: v[0] for k, v in cost.items()}


# Published configurations. seq is per 30 s window for Whisper, per second otherwise.
MODELS = {
    "Whisper tiny (encoder)":  dict(d=384, ff=1536, heads=6, layers=4, seq=1500,
                                    window_s=30.0, macs_per_s=740e6),
    "Whisper base (encoder)":  dict(d=512, ff=2048, heads=8, layers=6, seq=1500,
                                    window_s=30.0, macs_per_s=1730e6),
    "Conformer-CTC-S":         dict(d=176, ff=704, heads=4, layers=16, seq=100,
                                    window_s=1.0, macs_per_s=620e6),
    "Squeezeformer-XS":        dict(d=144, ff=576, heads=4, layers=16, seq=100,
                                    window_s=1.0, macs_per_s=263e6),
}


def price(cfg, cost, softmax_c=None, ln_c=None, gelu_c=None):
    d, ff, h, L, T = cfg["d"], cfg["ff"], cfg["heads"], cfg["layers"], cfg["seq"]
    sc = softmax_c if softmax_c is not None else cost["softmax_s8"]
    lc = ln_c if ln_c is not None else cost["layernorm_s8"]
    gc = gelu_c if gelu_c is not None else cost.get("gelu_s8", cost["layernorm_s8"])
    ln_els = 2 * T * d * L                 # pre-attention and pre-FFN
    sm_els = h * T * T * L                 # one row per query per head
    gl_els = T * ff * L                    # the FFN activation
    cyc = ln_els * lc + sm_els * sc + gl_els * gc
    return {"ln_elements": ln_els, "softmax_elements": sm_els, "act_elements": gl_els,
            "nonlinear_cycles": cyc,
            "nonlinear_rtf": cyc / CLK / cfg["window_s"],
            "mac_rtf": cfg["macs_per_s"] / MBP_MMAC}



# ======================================================================================
# SECTION 2 -- encoder/decoder models, priced with an explicit DECODE LOOP and an
# explicit MEMORY model.
#
# WHY THIS EXISTS.  SPEECH_ON_ROCKET.md section 6's "weight-stream RTF" column divides a
# model's parameter bytes by the measured 53.6 MB/s and assumes ONE WEIGHT PASS PER
# SECOND OF AUDIO.  That is right for a CTC encoder, which sees every frame once, and it
# is wrong by more than an order of magnitude for an autoregressive encoder-decoder:
# every decoder weight is re-read once per OUTPUT TOKEN, and with a 64 KB L2 against
# tens of megabytes of int8 parameters nothing stays resident between tokens.
#
# So this section prices three things separately and reports all three:
#
#   ENCODER   run once per utterance.  High arithmetic intensity: the weights are read
#             once and used at every one of T frames.
#   DECODE    run once per output token.  Arithmetic intensity ~1 MAC/byte, because it
#             is a matrix-VECTOR product: every weight byte is used exactly once.  This
#             is ROCC_STUDY.md 7.5's fully-connected case, which it measured at AI ~ 1
#             and called fill-bound "by an order of magnitude, in both networks".
#   NONLINEAR the float-tainted operators, at Lab B19's and Lab B20's measured
#             per-element costs.
#
# Every unit cost below is MEASURED ON THIS BOARD.  Every population is COUNTED from the
# published architecture (for Moonshine, from the checkpoint's own tensor shapes --
# 27,092,736 parameters, which is the 27.1 M section 6 quotes).  The product is an
# EXTRAPOLATION and is labelled as one everywhere it is printed.  Nobody has run
# Moonshine or QuartzNet on this board.
# ======================================================================================

# ---- measured unit costs -------------------------------------------------------------
# Cycles per MAC for the curated MBP kernels, from SPEECH_ON_ROCKET.md 11.1 (linear_s8,
# measured on hart 0 of the routed part).  Section 6's "RTF (MACs only)" column instead
# divides by 22.4 MMAC/s, which is the same statement at 1.54 cycles/MAC; the difference
# is the shape mix and it is under 15%.
CYC_MAC_LINEAR = 1.34
# Convolution, contiguous reduction axis (KW >= 3 with time on the width axis).  Lab B21
# measured digit_ctc_t at 1.24 and Lab B17 kws_cnn at 1.30 cycles/MAC.
CYC_MAC_CONV = 1.24
# Convolution whose gather run is ONE BYTE -- KW == 1 in NCHW, which is what a 1x1
# pointwise convolution is and what a (k,1) temporal kernel is.  Lab B21 measured
# digit_ctc_wide at 20.92 cycles/MAC for exactly this shape, 16.93x the transposed
# version of the SAME network.  SPEECH_ON_ROCKET.md 11.4.
CYC_MAC_GATHER1 = 20.92
# Depthwise convolution: MBP.DOT8 reduces along the input-channel axis and a depthwise
# convolution does not have one.  Lab B17 measured kws_dscnn's depthwise dispatches at
# 0.031 MAC/cycle against the dense kernels' 0.878.  SPEECH_ON_ROCKET.md 5.
CYC_MAC_DEPTHWISE = 1.0 / 0.031
# matmul_s8 -- activation x activation, the shape attention needs.  Lab B19 measured 476
# cycles per OUTPUT element at K = 32; the reduction is ~1.5 cycles/MAC and the rest is
# one roundf((float)acc * total) per output element on a core with no FPU.  Split so the
# per-element float term can be priced away separately, because it is the same Q0.31
# requantise every conv kernel already does in integer.
CYC_MATMUL_REQUANT_FLOAT = 476.0 - 32 * 1.5
CYC_MATMUL_REQUANT_INT = 10.0          # ESTIMATE: the conv kernels' hoisted QMUL+CLIP8

# DRAM, one hart, streaming read: MEMORY_HIERARCHY.md section 2, measured.
DRAM_BPS = 53.6e6
L2_BYTES = 64 * 1024


def _ln(K):
    """layernorm_s8 cycles per element, float and integer, at width K (Lab B19/B20)."""
    return 1158.0, 73.0


class Op:
    """One dispatch's worth of work, in the units this machine charges for."""

    def __init__(self, macs=0, kind="linear", wbytes=0, cyc_mac=None, dw=False,
                 softmax_els=0, ln_els=0, gelu_els=0, matmul_els=0):
        self.macs = macs
        self.kind = kind
        # A DEPTHWISE convolution cannot use the engine at all, and saying so explicitly
        # is the point: MBP.DOT8 and the MAC array both reduce along the input-channel
        # axis, and a depthwise convolution does not have one (SPEECH_ON_ROCKET.md 5).
        # Sending it to the array would be the same mistake as pricing it by its MACs.
        self.dw = dw
        self.cyc_mac = cyc_mac
        self.wbytes = wbytes
        self.softmax_els = softmax_els
        self.ln_els = ln_els
        self.gelu_els = gelu_els
        self.matmul_els = matmul_els

    def nonlin(self, c):
        return (self.softmax_els * c["softmax"]
                + self.ln_els * c["layernorm"]
                + self.gelu_els * c["gelu"]
                + self.matmul_els * c["matmul_rq"])

    def cycles(self, c):
        m = self.cyc_mac if self.cyc_mac is not None else {
            "linear": CYC_MAC_LINEAR, "conv": CYC_MAC_CONV,
            "gather1": CYC_MAC_GATHER1, "depthwise": CYC_MAC_DEPTHWISE}[self.kind]
        return self.macs * m + self.nonlin(c)

    def engine_cycles(self, c, F, width=32.0):
        """With the mbxd engine doing the GEMMs and the core doing everything else.

        The engine is fed only where the tile's arithmetic intensity clears width/F, so
        the arithmetic term is max(MACs/width, bytes/F) and NOT MACs/width.  That is the
        whole point of the exercise: an array the port cannot fill runs at the port's
        rate, and for a matrix-VECTOR layer -- which is every step of an autoregressive
        decoder -- the port's rate is what you get however wide the array is.
        """
        if self.wbytes == 0 or self.dw:
            return self.cycles(c)
        return max(self.macs / width, self.wbytes / F) + self.nonlin(c)


def _conv1d_out(n, k, s):
    return (n - k) // s + 1


def moonshine(cfg, utt_s, tokens):
    """Encoder and per-token decoder work for a Moonshine checkpoint.

    Shapes are the checkpoint's own (fetched once from the safetensors header and
    transcribed here, so this script needs no network): a preprocessor of three 1-D
    convolutions over RAW AUDIO, an encoder stack, a decoder stack with self-attention,
    cross-attention and a gated (SwiGLU) MLP, and a TIED embedding used as the output
    projection.  The tie is the load-bearing detail: it makes the vocabulary matrix a
    d x 32768 matrix-vector product that is re-read from DRAM once per output token.
    """
    d, ff, H, Le, Ld, V = (cfg["d"], cfg["ff"], cfg["heads"],
                           cfg["enc_layers"], cfg["dec_layers"], cfg["vocab"])
    n = int(utt_s * 16000)
    t1 = _conv1d_out(n, 127, 64)
    t2 = _conv1d_out(t1, 7, 3)
    T = _conv1d_out(t2, 3, 2)

    enc, dec_per_tok, once = [], [], []

    # --- preprocessor.  Reduction axis is (in_channels x kernel); in NCHW-with-time-on-W
    # that run is KW bytes long for conv1 (IC = 1) and IC-strided for conv2/conv3, so
    # conv1 is the contiguous case and the other two are the 1x1-like gather case
    # whenever they are written channel-major.  Priced at the contiguous rate here and
    # the cost of getting that wrong is reported separately.
    enc.append(Op(macs=cfg["c1"] * t1 * 127, kind="conv",
                  wbytes=cfg["c1"] * 127))
    enc.append(Op(macs=cfg["c2"] * t2 * cfg["c1"] * 7, kind="conv",
                  wbytes=cfg["c2"] * cfg["c1"] * 7))
    enc.append(Op(macs=d * T * cfg["c2"] * 3, kind="conv",
                  wbytes=d * cfg["c2"] * 3))

    # --- encoder stack
    for _ in range(Le):
        enc.append(Op(macs=4 * T * d * d, wbytes=4 * d * d, ln_els=2 * T))
        enc.append(Op(macs=2 * T * T * d, matmul_els=H * T * T + T * d,
                      softmax_els=H * T * T))
        enc.append(Op(macs=2 * T * d * ff, wbytes=2 * d * ff, gelu_els=T * ff))

    # --- cross-attention K and V over the encoder output: once per utterance, cached
    for _ in range(Ld):
        once.append(Op(macs=2 * T * d * d, wbytes=2 * d * d))

    # --- decoder, per output token.  seq is the mean cache depth over the utterance.
    seq = max(1.0, (tokens + 1) / 2.0)
    for _ in range(Ld):
        # self-attention: q,k,v,o for ONE position, then attend over the cache
        dec_per_tok.append(Op(macs=4 * d * d, wbytes=4 * d * d, ln_els=d))
        dec_per_tok.append(Op(macs=2 * seq * d, matmul_els=H * seq + d,
                              softmax_els=H * seq))
        # cross-attention: q and o only; K,V are cached above
        dec_per_tok.append(Op(macs=2 * d * d, wbytes=2 * d * d, ln_els=d))
        dec_per_tok.append(Op(macs=2 * T * d, matmul_els=H * T + d,
                              softmax_els=H * T))
        # gated MLP: fc1 is d -> 2*ff, SiLU on one half, fc2 is ff -> d.  SiLU is the
        # same pointwise-int8-map shape as GELU, so it is priced at GELU's cost.
        dec_per_tok.append(Op(macs=d * 2 * ff + ff * d, wbytes=d * 2 * ff + ff * d,
                              gelu_els=ff, ln_els=d))
    # --- the tied output projection.  ONE token out of 32,768 is wanted and all of them
    # must be computed, and the whole embedding matrix is read to do it.
    dec_per_tok.append(Op(macs=d * V, wbytes=d * V))
    return T, enc, once, dec_per_tok


MOONSHINE = {
    "Moonshine Tiny": dict(d=288, ff=1152, heads=8, enc_layers=6, dec_layers=6,
                           vocab=32768, c1=288, c2=576, params=27_092_736,
                           # the WER SPEECH_ON_ROCKET.md section 6 already carries; the
                           # parameter count is the checkpoint's own tensor shapes summed,
                           # and it lands on the 27.1 M that section quotes.
                           wer="4.52 / 11.71"),
    "Moonshine Base": dict(d=416, ff=1664, heads=8, enc_layers=8, dec_layers=8,
                           vocab=32768, c1=416, c2=832, params=61_513_920,
                           wer="not checked here"),
}


def quartznet(dw_cyc, pw_cyc, sec=1.0):
    """QuartzNet-15x5: 1-D time-channel separable convolutions, CTC, no attention.

    Blocks from the paper's Table 1: C1 (K=33, C=256, stride 2), then B1..B15 in five
    groups of three -- (256, K=33), (256, K=39), (512, K=51), (512, K=63), (512, K=75)
    -- each block five sub-blocks, then C2 (K=87, C=512), C3 (1x1, C=1024) and C4
    (1x1, C=29).  Input is 64 MFCC at 100 frames/s; C1's stride 2 makes the body run at
    50 frames/s.

    THE LAYOUT CONFLICT.  Every sub-block is a DEPTHWISE convolution of width K followed
    by a POINTWISE 1x1, and the two want opposite memory layouts on this machine:

      time-major   (NCHW, time on W): the depthwise reduction is K CONTIGUOUS bytes --
                   the good case -- and the pointwise reduction is C bytes strided by T,
                   which is the ONE-BYTE gather Lab B21 measured at 20.92 cycles/MAC.
      channel-major(NHWC): the pointwise reduction is C contiguous bytes -- the good
                   case -- and the depthwise one is K bytes strided by C, the same
                   one-byte gather.

    There is no layout that makes both contiguous.  Which one loses is arithmetic on the
    MAC split, and that is what this computes.
    """
    T0 = int(100 * sec)
    T = T0 // 2
    body = ([(256, 33)] * 3 + [(256, 39)] * 3 + [(512, 51)] * 3
            + [(512, 63)] * 3 + [(512, 75)] * 3)
    ops = []

    def sep(cin, cout, k, t):
        ops.append(Op(macs=cin * k * t, cyc_mac=dw_cyc, dw=True, wbytes=cin * k))
        ops.append(Op(macs=cin * cout * t, cyc_mac=pw_cyc, wbytes=cin * cout))

    sep(64, 256, 33, T)
    cprev = 256
    for c, k in body:
        for r in range(5):
            sep(cprev, c, k, T)
            cprev = c
    sep(512, 512, 87, T)
    ops.append(Op(macs=512 * 1024 * T, cyc_mac=pw_cyc, wbytes=512 * 1024))
    ops.append(Op(macs=1024 * 29 * T, cyc_mac=pw_cyc, wbytes=1024 * 29))
    return ops


def _sum(ops, c):
    return (sum(o.cycles(c) for o in ops), sum(o.macs for o in ops),
            sum(o.wbytes for o in ops))


def _sum_eng(ops, c, F, width=32.0):
    return sum(o.engine_cycles(c, F, width) for o in ops)


def section2(cost, isoft, ilayer, igelu, imatmul_rq=None, utt_s=4.0, tokens=15):
    fl = {"softmax": cost["softmax_s8"], "layernorm": cost["layernorm_s8"],
          "gelu": cost.get("gelu_s8", 3093.0),
          "matmul_rq": CYC_MATMUL_REQUANT_FLOAT}
    it = {"softmax": isoft, "layernorm": ilayer, "gelu": igelu,
          "matmul_rq": (imatmul_rq if imatmul_rq is not None
                        else CYC_MATMUL_REQUANT_INT)}

    print("\n" + "=" * 94)
    print("SECTION 2 -- autoregressive decode, priced per token, and the memory it moves")
    print("=" * 94)
    print("   utterance %.1f s, %d output tokens.  EXTRAPOLATION: measured unit costs"
          % (utt_s, tokens))
    print("   (this board) x counted populations (the published/checkpoint shapes).")
    print("   Nobody has run these models on this board.\n")

    for name, cfg in MOONSHINE.items():
        T, enc, once, per_tok = moonshine(cfg, utt_s, tokens)
        rows = []
        for label, c in (("float kernels", fl), ("integer kernels", it)):
            ce, me, be = _sum(enc, c)
            co, mo, bo = _sum(once, c)
            ct, mt, bt = _sum(per_tok, c)
            tot_cyc = ce + co + ct * tokens
            tot_mac = me + mo + mt * tokens
            # Weight traffic.  The L2 is 64 KB; the smallest thing here that could be
            # resident is one decoder layer's weights, and it is not.  So every byte is
            # counted once per use, which is once per token for the decoder.
            tot_b = be + bo + bt * tokens
            rows.append((label, tot_cyc, tot_mac, tot_b, ct, mt, bt))
        print("-- %s   d=%d  %d+%d layers  vocab %d  %s params  WER %s"
              % (name, cfg["d"], cfg["enc_layers"], cfg["dec_layers"], cfg["vocab"],
                 "{:,}".format(cfg["params"]), cfg["wer"]))
        print("   encoder frames for %.1f s of audio: %d  (%.1f frames/s)"
              % (utt_s, T, T / utt_s))
        for label, cyc, mac, b, ct, mt, bt in rows:
            print("   %-16s  %10.2f s compute   RTF %7.1f   %s MAC   %s weight B"
                  % (label, cyc / CLK, cyc / CLK / utt_s,
                     "{:>13,}".format(int(mac)), "{:>12,}".format(int(b))))
        # ---- and with the decoupled engine doing the GEMMs.  F is the port rate the
        # fill engine delivers; tb_mbxd_bw.sv simulates the RTL against the MEASURED
        # miss latency and reports 5.10 B/cycle at four transactions in flight and 7.89
        # at eight, against the 1.34 a hart achieves.
        for F, lab in ((1.34, "the core's own port rate (measured)"),
                       (5.10, "mbxd, 4 outstanding (simulated)"),
                       (7.89, "mbxd, 8 outstanding (simulated)")):
            ce = _sum_eng(enc, it, F)
            co = _sum_eng(once, it, F)
            cte = _sum_eng(per_tok, it, F)
            tot = ce + co + cte * tokens
            print("   + engine @ %-34s RTF %7.1f   (decode %6.1f ms/token)"
                  % (lab, tot / CLK / utt_s, cte / CLK * 1e3))
        lbl, cyc, mac, b, ct, mt, bt = rows[-1]
        mem_s = b / DRAM_BPS
        print("   weight traffic %.1f MB -> %.2f s at the measured 53.6 MB/s"
              "  (weight-stream RTF %.2f)" % (b / 1e6, mem_s, mem_s / utt_s))
        print("   SECTION 6 SAID %.2f: it divides %s parameter bytes by 53.6 MB/s and"
              % (cfg["params"] / DRAM_BPS, "{:,}".format(cfg["params"])))
        print("   assumes ONE pass per second of audio.  The decoder is re-read per")
        print("   token, so the real figure is %.1fx that." % (mem_s / utt_s
              / (cfg["params"] / DRAM_BPS / utt_s)))
        print("   PER OUTPUT TOKEN: %s MAC, %s weight B, AI = %.2f MAC/byte"
              % ("{:,}".format(int(mt)), "{:,}".format(int(bt)), mt / bt))
        print("      compute %8.1f ms at the measured MBP rate" % (ct / CLK * 1e3))
        print("      memory  %8.1f ms at the measured 53.6 MB/s" % (bt / DRAM_BPS * 1e3))
        for F in (1.34, 4.0, 6.0, 8.0):
            # the engine is compute-bound only where AI >= 32/F (ROCC_STUDY.md 7.5)
            print("      at a %.2f B/cycle port: memory %7.1f ms, 32 MAC/cycle array "
                  "%7.1f ms  -> %s"
                  % (F, bt / F / CLK * 1e3, mt / 32.0 / CLK * 1e3,
                     "MEMORY bound" if bt / F > mt / 32.0 else "compute bound"))
        print("   the tied %d x %d output projection alone is %s MAC and %s weight B"
              " per token: %.1f%% of the token's weight traffic, for one useful logit"
              % (cfg["d"], cfg["vocab"], "{:,}".format(cfg["d"] * cfg["vocab"]),
                 "{:,}".format(cfg["d"] * cfg["vocab"]),
                 100.0 * cfg["d"] * cfg["vocab"] / bt))
        print()

    print("-- QuartzNet-15x5   18.9 M params, CTC, greedy decode needs NO softmax")
    print("   (argmax is invariant under a monotone transform, so none of the 28")
    print("   float-tainted kernels is reachable from this graph)")
    ops0 = quartznet(CYC_MAC_DEPTHWISE, CYC_MAC_GATHER1)
    dwm = sum(o.macs for o in ops0 if o.dw)
    tot = sum(o.macs for o in ops0)
    print("   %s MAC/s;  depthwise %.1f%% of them, pointwise %.1f%%"
          % ("{:,}".format(int(tot)), 100.0 * dwm / tot, 100.0 * (tot - dwm) / tot))
    print("   %-58s %8s %8s %8s" % ("layout / kernels", "dw c/MAC", "pw c/MAC", "RTF"))
    cases = [
        ("NCHW, time on W -- as the toolchain stands today", CYC_MAC_DEPTHWISE,
         CYC_MAC_GATHER1),
        ("NCHW, time on W, + a curated depthwise kernel (TODO 4)", CYC_MAC_CONV,
         CYC_MAC_GATHER1),
        ("NHWC (TODO 5), depthwise still on the reference kernel", CYC_MAC_DEPTHWISE,
         CYC_MAC_LINEAR),
        ("NHWC + a curated depthwise kernel (gathered taps)", CYC_MAC_GATHER1,
         CYC_MAC_LINEAR),
    ]
    for name, dwc, pwc in cases:
        ops = quartznet(dwc, pwc)
        cyc, _, _ = _sum(ops, it)
        print("   %-58s %8.1f %8.2f %8.1f" % (name, dwc, pwc, cyc / CLK))
    print("   the split is the answer: pointwise is %.1f%% of the MACs, so the layout"
          % (100.0 * (tot - dwm) / tot))
    print("   that makes POINTWISE contiguous wins, and the depthwise cost is residue.")
    ops = quartznet(CYC_MAC_GATHER1, CYC_MAC_LINEAR)
    for F in (1.34, 5.10, 7.89):
        ce = _sum_eng(ops, it, F)
        print("   best layout + the engine @ %.2f B/cycle (depthwise stays on the core):"
              "  RTF %6.2f" % (F, ce / CLK))
    print("   weight-stream: 18.9 MB once per second of audio -> RTF %.2f"
          % (18.9e6 / DRAM_BPS))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="out/rocket_xformer_cost")
    ap.add_argument("--int-nonlin", default="out/rocket_int_nonlin/run.json",
                    help="Lab B20's manifest, for the integer-kernel column")
    ap.add_argument("--utt-s", type=float, default=4.0,
                    help="utterance length for the decode-loop model (seconds)")
    ap.add_argument("--tokens", type=int, default=15,
                    help="output tokens emitted for that utterance")
    a = ap.parse_args()
    cost = measured_costs(a.run)
    if not cost:
        sys.exit("no Lab B19 results under %s" % a.run)
    print("-- measured cost per output element (Lab B19, hart 0)")
    for k in sorted(cost, key=lambda k: -cost[k]):
        print("   %-22s %8.0f cycles/element" % (k, cost[k]))

    # the integer replacements, if Lab B20 has run
    isoft = ilayer = igelu = None
    gelu_note = ""
    if os.path.exists(a.int_nonlin):
        b20 = json.load(open(a.int_nonlin))
        for r in b20.get("rows", []):
            if r["op"] == "softmax" and (isoft is None or r["K"] >= 256):
                isoft = r["int_cyc_per_elem"]
            if r["op"] == "layernorm" and (ilayer is None or r["K"] >= 256):
                ilayer = r["int_cyc_per_elem"]
        # GELU: take the LARGEST n measured.  The whole point of the memo/table kernel
        # is that the transcendental amortises, so quoting a small-n figure would
        # understate a real FFN activation by an order of magnitude and quoting it
        # without n would be dishonest.
        g = [r for r in b20.get("rows", []) if r["op"] == "gelu"]
        if g:
            big = max(g, key=lambda r: r["K"])
            igelu = big["int_cyc_per_elem"]
            gelu_note = " (measured at n = %d)" % big["K"]
        print("\n-- measured cost with the INTEGER kernels (Lab B20)")
        print("   softmax   %8s cycles/element" % isoft)
        print("   layernorm %8s cycles/element" % ilayer)
        if igelu:
            print("   gelu      %8s cycles/element%s" % (igelu, gelu_note))

    print("\n-- EXTRAPOLATION: measured unit costs x counted elements. Nobody has run")
    print("   any of these on this board; the unit costs are measured and the element")
    print("   populations come from the published configurations.\n")
    print("   %-24s %10s %12s %12s %12s %10s" %
          ("model", "RTF(MACs)", "RTF(+float)", "RTF(+int)", "RTF(+int+gelu)",
           "float share"))
    print("   " + "-" * 88)
    for name, cfg in MODELS.items():
        f = price(cfg, cost)
        tot_f = f["mac_rtf"] + f["nonlinear_rtf"]
        row = "   %-24s %10.1f %12.0f" % (name, f["mac_rtf"], tot_f)
        if isoft:
            i = price(cfg, cost, softmax_c=isoft, ln_c=ilayer,
                      gelu_c=cost.get("gelu_s8"))
            tot_i = f["mac_rtf"] + i["nonlinear_rtf"]
            row += " %12.1f" % tot_i
            # and with an integer GELU too.  NOT measured -- int_nonlin.c does not
            # have one.  It is the same 33-entry-LUT-plus-interpolation shape as the
            # exponential it already has (GELU is x*Phi(x) and Phi is an erf), so
            # softmax's measured 171 cycles/element is the right order; this column is
            # an ESTIMATE and is labelled as one wherever it is quoted.
            j = price(cfg, cost, softmax_c=isoft, ln_c=ilayer,
                      gelu_c=(igelu if igelu is not None else isoft))
            tot_j = f["mac_rtf"] + j["nonlinear_rtf"]
            row += " %12.1f" % tot_j
        else:
            row += " %12s %12s" % ("-", "-")
        row += " %10.1f%%" % (100 * f["nonlinear_rtf"] / tot_f)
        print(row)
    print("\n   RTF(MACs) is section 6's column: published MACs / 22.4 MMAC/s.")
    print("   RTF(+float) adds the non-matmul operators at Lab B19's measured cost.")
    if isoft:
        print("   RTF(+int) is the same with int_nonlin.c's measured softmax and layer")
        if igelu is not None:
            print("   norm instead.  RTF(+int+gelu) uses the MEASURED integer GELU at")
            print("   %d cycles/element%s -- int_nonlin.c now has one, so that column"
                  % (igelu, gelu_note))
            print("   is no longer an estimate.")
        else:
            print("   norm instead.  RTF(+int+gelu) additionally ESTIMATES an integer")
            print("   GELU at softmax's measured cycles/element; it has not been")
            print("   written and that column is not a measurement.")
    if isoft and igelu:
        section2(cost, isoft, ilayer, igelu,
                 utt_s=a.utt_s, tokens=a.tokens)


if __name__ == "__main__":
    main()
