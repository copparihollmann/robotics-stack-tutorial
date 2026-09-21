#!/usr/bin/env python3
"""The silicon prediction for 0x5A5A001C (bwwin), from the simulation of its generated RTL plus two
measured facts about the PS side, and nothing fitted to 001C itself.  MEMORY_BANDWIDTH.md s9.6.

  measured (s8.9-8.10, 0x5A5A0017 at FCLK1 = 100 / 90.9 / 76.9 MHz):
    C   = 2,008 MB/s     a time-rate cap on the PS side, shared by all four HP ports
    L   = 169 ns + 3.4 memory-bus cycles, AR to first R beat
  simulated (results/, this directory):
    per-Get round trips at 1 in flight, as a function of the memory latency in FCLK1 cycles
"""
import re, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
F0, F1, C = 1000.0 / 29.0, 100.0, 2008.0
T0, T1 = 1000.0 / F0, 1000.0 / F1
L = (169.0 + 3.4 * T1) / T1                     # PS latency in memory-bus cycles at F1

def rows(name):
    out = []
    for line in open(os.path.join(HERE, 'results', name)):
        if not line.startswith('WINTB'): continue
        d = dict(kv.split('=', 1) for kv in line.split() if '=' in kv)
        out.append(d)
    return out

# the latency law: cycles per Get at 1 in flight = a + b * L, from the L sweep (FCLK0 cycles)
pts = [(float(r['lat']), float(r['cyc_per_get'])) for r in rows('lsweep.txt') if r.get('out') == '1']
n = len(pts); sx = sum(x for x, _ in pts); sy = sum(y for _, y in pts)
sxx = sum(x * x for x, _ in pts); sxy = sum(x * y for x, y in pts)
b = (n * sxy - sx * sy) / (n * sxx - sx * sx); a = (sy - b * sx) / n
print("latency law (sim): cycles/Get @1 = %.3f + %.4f x L   (T1/T0 = %.4f)" % (a, b, T1 / T0))
print("PS latency at FCLK1 = %.1f MHz: L = %.2f cycles = %.1f ns" % (F1, L, L * T1))
win1 = a + b * L
sim20 = {(r['set'], r['out']): r for r in rows('sweep_win_lat20.txt') if 'set' in r}
ap20 = {r['out']: r for r in rows('sweep_ap_lat20.txt') if r.get('set') == 'AP_PROBE'}
tile = [r for r in rows('tile_src1_lat20.txt') if 'get_rt_avg' in r][0]
dL = b * (L - 20.0)                              # the sim ran at L = 20; shift every round trip
print("\nWIN lane, 128-bit at FCLK0: %.2f cycles per Get at 1 in flight (sim at L=20: %s)" % (win1, sim20[('WIN_L0', '1')]['cyc_per_get']))
cap_bpc = C / F0
print("PS cap in FCLK0 cycles: %.2f B/cycle" % cap_bpc)
print("\n%-10s %s" % ("set", "  ".join("@%-6s" % o for o in (1, 2, 3, 4, 5, 6, 8))))
for s, nl in (("WIN_L0", 1), ("WIN_L2", 1), ("WIN_L01", 2), ("WIN_L012", 3), ("WIN_L0123", 4), ("WIN_SEQ", 1)):
    vals = []
    for o in (1, 2, 3, 4, 5, 6, 8):
        per = min(16.0, 64.0 * o / win1)
        tot = min(nl * per, cap_bpc)
        vals.append("%7.2f" % tot)
    print("%-10s %s   -> %.1f MB/s at 8" % (s, " ".join(vals), float(vals[-1]) * F0))
ap1 = float(ap20['1']['cyc_per_get']) + dL
print("\nAP_PROBE (64-bit BwProbe through the aperture): %.2f cycles per Get at 1" % ap1)
print("  B/cycle @1..4: " + " ".join("%.2f" % min(8.0, 64.0 * o / ap1) for o in (1, 2, 3, 4)))
g = float(tile['get_rt_avg']) + dL; p = float(tile['put_rt_avg']) + dL
TILEBUF, PIPE = 2.0, 3.0
rd = g + TILEBUF + PIPE; wr = p + TILEBUF + PIPE
print("\ntile port round trip through the aperture (sim + PS latency): Get %.2f, Put %.2f FCLK0 cycles" % (g, p))
print("hart, per 8-byte load/store (+%.0f tile boundary TLBuffer, +%.0f DCache/pipeline): %.1f / %.1f cycles" % (TILEBUF, PIPE, rd, wr))
print("  mb_read  (32 loads + 2 per 256 B): %.3f B/cycle" % (256.0 / (32 * rd + 2)))
print("  mb_write (32 stores + 2 per 256 B): %.3f B/cycle" % (256.0 / (32 * wr + 2)))
