#!/usr/bin/env python3
"""MODEL ONLY.  An L2 with N outer channels, striped by block address (MEMORY_BANDWIDTH.md s6.12).

Inputs: results/ALL_RESULTS8.txt -- one stripe, simulated on the generated RTL of three L2s
(run_nouter.sh): 001A (64-bit, 7 MSHRs), 0018 (128/128, 7) and 0019 (128/128, 12), each with
one outer channel whose memory bus is on FCLK1 = 100 behind an async crossing (one outer beat
per L2 cycle, first-beat latency L in L2 cycles), and results/ATTR8.txt, the per-block
attribution at saturation.

Two designs are priced:

  SHARED  one L2 core -- one scheduler (one MSHR per cycle), one Directory, one SourceD --
          with N outer channels.  Bounded by the per-block work the core serialises, read
          from ATTR8: 3 scheduled MSHR-cycles and 3 Directory operations per 64-byte block at
          saturation, so at most 64/3 B per L2 cycle however many outer channels feed it.
  STRIPED N complete L2s (scheduler, Directory, BankedStore, cork, outer channel each).  Stripe c
          owns the blocks whose address bits [6 + log2 N - 1 : 6] equal c -- the partition
          WithNMemoryChannels already uses -- and an sbus xbar routes every request, TL-C
          included, by address.  Every block has exactly one owner, so coherence stays
          automatic.  The stripes share no L2 state, so N stripes carry exactly N times one
          stripe; what they share is outside the L2 and is applied as a cap:
            - the requester's own link at the system-bus clock (W/8 B per cycle), and
            - the PS: 1,599.9 MB/s on two HP ports of one controller port, 2,009 MB/s on four
              (s8.5, s8.9, measured through the bypass).

  ./nouter_model.py [results/ALL_RESULTS8.txt]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
F0 = 34.4828                       # L2 and system-bus clock, MHz
PS_MBS = {1: 800.0, 2: 1599.9, 4: 2009.0}   # measured PS ceilings, MB/s (s8.5, s8.9)
STRIPES = {                        # name -> (label, outer/inner width bits, MSHRs, L used)
    "skip64":   ("64-bit, 7 MSHRs (001A RTL)", 64, 7, "12.35"),
    "ws128m7":  ("128/128, 7 MSHRs (0018 RTL)", 128, 7, "12.7"),
    "ws128m12": ("128/128, 12 MSHRs (0019 RTL)", 128, 12, "12.7"),
}
# Measured post-route costs (reports/post_route_util_hier.rpt of the named builds), LUT / FF:
COST = {
    #            L2 + cork          fast memory channel (async source + MemoryBus)   base build
    "skip64":   ((5573 + 163, 2522 + 35), (212 + 444, 959 + 1059), ("bwfast + 001A", 36455 + 11, 23064)),
    "ws128m7":  ((5614 + 24, 2854 + 32), (508 + 768, 1543 + 1802), ("0018", 40291, 27231)),
    "ws128m12": ((8764 + 136, 3737 + 32), (508 + 768, 1543 + 1802), ("0019", 42794, 28274)),
}
XBAR_PER_STRIPE = {64: 300, 128: 500}   # ESTIMATE: one more sbus xbar output (952 / 1,454 LUT for 2)
DEVICE_LUT, DEVICE_FF = 53200, 106400


def load(path):
    data = {}
    for line in open(path):
        m = re.match(r"(\S+)_L([\d.]+) RESULT kind=dram .* out=(\d+) .* B/cycle=([\d.]+) .* cksum_ok=(\d)", line)
        if m:
            name, L, out, bpc, ok = m.group(1), m.group(2), int(m.group(3)), float(m.group(4)), m.group(5)
            if ok != "1":
                sys.exit("checksum failure in %s" % line)
            data.setdefault((name, L), {})[out] = bpc
    return data


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results", "ALL_RESULTS8.txt")
    d = load(path)

    print("=== MODEL ONLY.  One stripe, simulated (generated RTL), memory bus on FCLK1 = 100:")
    print("    B per L2 cycle by in flight; MB/s = B/cycle x %.4f" % F0)
    for name, (label, w, m, _) in STRIPES.items():
        for L in sorted({k[1] for k in d if k[0] == name}, key=float):
            row = d[(name, L)]
            print("  %-30s L=%-5s %s" % (label, L, "  ".join("%d:%.2f" % (o, row[o]) for o in sorted(row))))

    print("\n=== SHARED core with N outer channels: the per-block work it serialises (ATTR8, 0019 RTL at 8 in flight)")
    print("  3 scheduled MSHR-cycles + 3 Directory ops (1 read, 2 writes) per block, one grant per cycle")
    shared = 64.0 / 3
    print("  ceiling = 64 B / 3 cycles = %.2f B per L2 cycle = %.0f MB/s, for any N and any inner width" % (shared, shared * F0))
    print("  (SourceD binds first below it: 8 B/cycle at a 64-bit inner edge, 16 at 128-bit)")

    print("\n=== STRIPED: N stripes, one lane (requester) per stripe, lane link = stripe width")
    print("  %-30s %2s %10s %9s %9s %8s %s" % ("stripe", "N", "in flight", "B/cycle", "MB/s", "% of PS", "binds"))
    best = {}
    for name, (label, w, m, L) in STRIPES.items():
        row = d[(name, L)]
        link = w / 8.0
        for n in (1, 2, 4):
            o_sat = min(o for o in row if row[o] >= max(row.values()) - 0.02)
            per = min(max(row.values()), link)
            tot = n * per
            ps = PS_MBS[n] / F0
            binds = "stripe (%s)" % ("SourceD / link" if abs(per - link) < 0.05 else "MSHRs x latency, Directory")
            if tot > ps:
                tot, binds = ps, "PS (%.0f MB/s measured)" % PS_MBS[n]
            best[(name, n)] = tot
            print("  %-30s %2d %10s %9.2f %9.0f %7.0f%% %s" % (label, n, "%d x %d" % (n, o_sat), tot, tot * F0,
                                                               100 * tot * F0 / PS_MBS[4], binds))

    print("\n=== STRIPED, one requester on one link (the link binds): W/8 B per L2 cycle")
    for w in (64, 128, 256):
        print("  %3d-bit requester: %5.2f B/cycle = %4.0f MB/s, whatever N" % (w, w / 8.0, w / 8.0 * F0))

    print("\n=== Cost ESTIMATE: base build + (N-1) x (L2 + cork + fast memory channel + one xbar output)")
    print("  %-30s %2s %8s %6s %8s %6s" % ("stripe", "N", "LUT", "% dev", "FF", "% dev"))
    for name, (label, w, m, L) in STRIPES.items():
        (l2l, l2f), (chl, chf), (bname, blut, bff) = COST[name]
        for n in (1, 2, 4):
            lut = blut + (n - 1) * (l2l + chl + XBAR_PER_STRIPE[w])
            ff = bff + (n - 1) * (l2f + chf + 50)
            print("  %-30s %2d %8d %5.0f%% %8d %5.0f%%  %s" % (label, n, lut, 100.0 * lut / DEVICE_LUT, ff, 100.0 * ff / DEVICE_FF,
                                                           "does not fit" if lut > DEVICE_LUT else ""))
    # 4-MSHR stripes: the smallest InclusiveCache (2 + max(2, ceil(memCycles/blockBeats))), 2 Get-capable MSHRs
    l2_4 = 5573 - 3 * 698          # 000B: +3,492 LUT for +5 MSHRs = 698 LUT/MSHR
    row = d[("skip64", "12.35")]
    per4 = row[2]
    lut4 = 36455 + 11 - 3 * 698 + 3 * (l2_4 + 163 + 656 + 300)
    print("\n=== ESTIMATE, 4 x 64-bit stripes of 4 MSHRs (2 Get-capable): per stripe ~ the 7-MSHR stripe at 2 in flight")
    print("  %.2f x 4 = %.2f B/cycle = %.0f MB/s; ~%d LUT (%.0f%%)" % (per4, 4 * per4, 4 * per4 * F0, lut4, 100.0 * lut4 / DEVICE_LUT))


if __name__ == "__main__":
    main()
