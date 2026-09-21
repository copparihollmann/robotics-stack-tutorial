#!/usr/bin/env python3
"""B76 -- the A/B, scored against the band that was committed before the board.

Usage:  b76_ab.py <off_run.json> <on_run.json> [baseline_run.json]

Reports, per op: absolute cycles both arms, the delta, cycles/element, and whether the
row is a TREATED one or an untouched one (crosstalk).  Then the aggregate: op-level
saving, steady saving, the implied C, the transfer, and each of B76_BAND.md's predictions
with HELD / MISSED HIGH / MISSED LOW.
"""
import json
import sys

TREATED = ("permute4_s8", "mul_s8", "layernorm_s8", "softmax_s8")
# The band, exactly as committed in B76_BAND.md before the board.
BAND = {
    "permute4_s8":   (4_902_791,  4_300_000,  5_900_000),
    "mul_s8":        (6_759_648,  6_200_000,  7_300_000),
    "layernorm_s8": (13_610_677, 11_700_000, 15_500_000),
    "softmax_s8":   (11_537_109, 11_100_000, 12_100_000),
}
P5 = (16_263_588, 12_300_000, 19_800_000)          # op-level saving, all four
P6 = (217_243_587, 213_500_000, 221_400_000)       # decoder steady
P7 = (1.57500, 1.5479, 1.6050)                     # rtf_steady
P8 = (1.72306, 1.7098, 1.7377)                     # RTF_e2e
C_B73 = 4_698_761
ENC_TERM = 0.955916                                # b74_enc_on, the encoder half
DEC_TERM_BASE = 0.80798
CROSSTALK_ROW = 0.003
CROSSTALK_AGG = 0.005


def load(p):
    return json.load(open(p))["models"]["dec_q16"]


def verdict(v, lo, hi):
    if v < lo:
        return "MISSED LOW"
    if v > hi:
        return "MISSED HIGH"
    return "HELD"


def main():
    off, on = load(sys.argv[1]), load(sys.argv[2])
    base = load(sys.argv[3]) if len(sys.argv) > 3 else None

    print("=" * 96)
    print("B76 A/B -- %s vs %s" % (sys.argv[1], sys.argv[2]))
    print("=" * 96)
    for k in ("soc_magic", "bitstream_md5", "kernel_cflags", "max_abs_err",
              "max_abs_err_meaning", "steady_cycles", "rtf_steady", "dispatches_profiled"):
        print("  %-22s off=%-46s on=%s" % (k, off.get(k), on.get(k)))
    print("  %-22s off=%-46s on=%s" % ("kernel digest",
          off["kernel_manifest"]["digest"], on["kernel_manifest"]["digest"]))

    print("\n--- F6: the engine must move the SAME BYTES in both arms ---")
    f6 = True
    for k in ("fill_beats", "cyc_tseq", "steps", "pairs", "bytes_act", "bytes_wgt",
              "loads_act", "loads_wgt", "calls_engine", "calls_fallback", "last_rc"):
        a, b = off["engine"][k], on["engine"][k]
        same = "same" if a == b else "*** DIFFERS ***"
        if a != b and k not in ("last_rc",):
            f6 = False
        print("  %-14s %16d %16d   %s" % (k, a, b, same))
    print("  F6: %s" % ("HELD -- the lever moves no byte the engine moves" if f6
                        else "FIRED -- this is not the A/B it claims to be"))

    print("\n--- per-op ---")
    print("  %-14s %12s %12s %12s %8s   %9s %9s" %
          ("op", "off", "on", "delta", "pct", "c/el off", "c/el on"))
    treated_save = 0
    unt_save = 0
    ct_rows = []
    for k in off["per_kind"]:
        a = off["per_kind"][k]["cycles"]
        b = on["per_kind"][k]["cycles"]
        ea = off["per_kind"][k]["elements"] or 1
        tag = "  <== treated" if k in TREATED else ""
        pct = 100.0 * (b - a) / a if a else 0.0
        print("  %-14s %12d %12d %12d %7.2f%%   %9.3f %9.3f%s" %
              (k, a, b, b - a, pct, a / ea, b / ea, tag))
        if k in TREATED:
            treated_save += a - b
        else:
            unt_save += a - b
            if a and abs(b - a) / a > CROSSTALK_ROW:
                ct_rows.append((k, a, b, pct))

    steady_off, steady_on = off["steady_cycles"], on["steady_cycles"]
    steady_save = steady_off - steady_on
    print("\n--- the aggregate ---")
    print("  op-level saving on the four treated rows   %14d" % treated_save)
    print("  net movement on the six untouched rows     %14d" % unt_save)
    print("  steady                     %14d -> %14d   %+d" %
          (steady_off, steady_on, steady_on - steady_off))
    print("  steady saving                              %14d" % steady_save)
    if treated_save:
        print("  transfer (steady saving / op saving)       %14.4f" %
              (steady_save / treated_save))
    print("  IMPLIED C = op saving - steady saving      %14d" % (treated_save - steady_save))
    print("     against B73 4,698,761 / B68-C 4,725,083 / B67 2,534,495")

    print("\n--- the band, as committed before the board ---")
    for k in TREATED:
        c, lo, hi = BAND[k]
        v = on["per_kind"][k]["cycles"]
        print("  %-14s predicted %12d  [%11d, %11d]  actual %12d   %s" %
              (k, c, lo, hi, v, verdict(v, lo, hi)))
    for name, (c, lo, hi), v in (
            ("P5 op saving", P5, treated_save),
            ("P6 steady", P6, steady_on)):
        print("  %-14s predicted %12d  [%11d, %11d]  actual %12d   %s" %
              (name, c, lo, hi, v, verdict(v, lo, hi)))
    r = on["rtf_steady"]
    print("  %-14s predicted %12.5f  [%11.4f, %11.4f]  actual %12.5f   %s" %
          ("P7 rtf_steady", P7[0], P7[1], P7[2], r, verdict(r, P7[1], P7[2])))
    dec_term = DEC_TERM_BASE * steady_on / (base["steady_cycles"] if base else steady_off)
    e2e = ENC_TERM + dec_term
    print("  %-14s predicted %12.5f  [%11.4f, %11.4f]  actual %12.5f   %s" %
          ("P8 RTF_e2e", P8[0], P8[1], P8[2], e2e, verdict(e2e, P8[1], P8[2])))
    print("     (decoder term %.5f, encoder term %.6f from b74_enc_on)" % (dec_term, ENC_TERM))

    print("\n--- F5: crosstalk, threshold 0.3 %% per untouched row / 0.5 %% of steady ---")
    if ct_rows:
        for k, a, b, pct in ct_rows:
            print("  %-14s %12d -> %12d   %+7.2f %%   OVER the 0.3 %% threshold" % (k, a, b, pct))
    else:
        print("  no untouched row moved more than 0.3 %")
    print("  aggregate on untouched rows %+d = %+.4f %% of steady   %s" %
          (unt_save, 100.0 * unt_save / steady_off,
           "over 0.5 %" if abs(unt_save) / steady_off > CROSSTALK_AGG else "under 0.5 %"))
    print("  lever NET of the untouched aggregate: steady saving %d - %d = %d" %
          (steady_save, unt_save, steady_save - unt_save))

    print("\n--- which side of C each op lands on, using the MEASURED saving ---")
    for k in TREATED:
        s = off["per_kind"][k]["cycles"] - on["per_kind"][k]["cycles"]
        print("  %-14s saving %12d   - C = %+12d   %s" %
              (k, s, s - C_B73, "positive alone" if s > C_B73 else "NEGATIVE alone"))
    print("  %-14s saving %12d   - C = %+12d" %
          ("all four", treated_save, treated_save - C_B73))

    if base:
        print("\n--- the control against b73_dec_ship (the pair-hygiene check) ---")
        print("  steady  b73 %14d   off-arm %14d   %+.4f %%" %
              (base["steady_cycles"], steady_off,
               100.0 * (steady_off - base["steady_cycles"]) / base["steady_cycles"]))
        for k in base["per_kind"]:
            a, b = base["per_kind"][k]["cycles"], off["per_kind"][k]["cycles"]
            print("    %-14s %12d -> %12d  %+7.3f %%" % (k, a, b, 100.0 * (b - a) / a))


if __name__ == "__main__":
    main()
