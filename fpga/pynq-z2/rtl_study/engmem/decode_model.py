#!/usr/bin/env python3
"""Where the Moonshine engine's time goes if its memory clients move (MEMORY_BANDWIDTH.md s9.9).

Inputs, all measured or composed by the Moonshine workstream, none fitted here:
  modelblaster/moonshine/engine_traffic.json (fe26d06): bytes per dispatch (W, A, out) and the per-kind
      cycle split of Lab B25 run 8 on 0x5A5A0010 (fill, steps, hart-1 wait, placement, hand-off);
  ROCC_DECOUPLED.md s8.9: decoder token = 183.8 ms hart-0 residue + the dispatches' hart-0 wall time;
  MEMORY_BANDWIDTH.md: fill-path rates measured on the instruments -- the L2 path (0007 / 001A) and memory-bus
      lanes (0016 / 0017) -- and the harts' DRAM cost of putting the memory bus on FCLK1 (1.369 -> 1.318).

The model: hart 1 waits on the engine for its fill (B25: hart1_wait = fill to within 2 %), and its placement
overlaps the array's steps, so a faster fill shortens a dispatch's hart-0 wall time by the fill it saves:
    wall' = wall - fill + fill',   fill' = W bytes / R_W + A bytes / R_A   (in core cycles)
"""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
TRAFFIC = os.path.join(HERE, '..', '..', 'modelblaster', 'moonshine', 'engine_traffic.json')
d = json.load(open(TRAFFIC))
F0 = d['clock_hz']
RESIDUE_MS = 183.8                      # ROCC_DECOUPLED.md s8.9, hart 0, nl+ew (SiLU/mul estimated there)
split = d['cycle_split_per_kind_b25']
disp = {x['name']: x for x in d['decoder_dispatches']}
per_token = [('dec_qkvo', 'dec_qkvo'), ('dec_fc1', 'dec_fc1'), ('dec_fc2', 'dec_fc2'), ('dec_lmhead', 'dec_lmhead')]

def mbps_to_bpc(mbps):
    return mbps * 1e6 / F0

# Fill-path rates, B per CORE cycle, each with where it was measured.
L2_0010 = None                          # as built: the engine's own measured rate per dispatch
PATHS = [
    ('as built: SBUS through the L2 (0x5A5A0010, ldepth 4)', L2_0010, L2_0010, 0.0),
    ('001A skip clean Release, ldepth 4 (instrument: 7.67 B/cycle at 4)', 7.67, 7.67, 0.0),
    ('001A skip clean Release, ldepth 6 (instrument: 8.00)', 8.00, 8.00, 0.0),
    ('(i) zero-RTL: W client on MBUS through an async crossing, engine on FCLK0 (64-bit client: 8.00 B/core cycle)', 8.00, 8.00, 0.037),
    ('(ii) split-DMA dual-clock W fill, 1 lane, FCLK1 100, ldepth 4 (instrument: 768 MB/s)', mbps_to_bpc(768.1), 8.00, 0.037),
    ('(ii) split-DMA dual-clock W fill, 1 lane, FCLK1 100, ldepth 8 (instrument: 800 MB/s)', mbps_to_bpc(799.96), 8.00, 0.037),
    ('(ii) 2 lanes into ONE spad write port at FCLK1 100 (the write port caps at 800 MB/s)', mbps_to_bpc(800.0), 8.00, 0.037),
    ('(ii) 2 lanes, HP0+HP2, two W write ports on disjoint banks (instrument: 1,600 MB/s)', mbps_to_bpc(1599.9), 8.00, 0.037),
]

def token(rw, ra, hart_penalty):
    rows, wall_total, fill_total, fill_new_total = [], 0.0, 0.0, 0.0
    for name, key in per_token:
        s = split[key]; m = disp[name]['measured_b25_run8']; n = disp[name]['count']
        fill = s['fill']
        if rw is None:
            fill_new = fill
        else:
            fill_new = m['bytes_w'] / rw + m['bytes_a'] / ra
        wall = s['hart0_wall'] - fill + fill_new
        wall_total += n * wall; fill_total += n * fill; fill_new_total += n * fill_new
        rows.append((name, n, fill, fill_new, wall))
    ms = lambda c: c / F0 * 1e3
    residue = RESIDUE_MS
    return ms(wall_total) + residue, ms(fill_new_total), rows, residue * hart_penalty

print("decoder token, 4 s utterance (15 tokens), engine nl+ew, 64-byte placement")
print("%-104s %9s %9s %s" % ("path", "fill ms", "token ms", "harts' DRAM-crossing bound"))
for name, rw, ra, pen in PATHS:
    t, f, rows, bound = token(rw, ra, pen)
    extra = ("+%.1f ms if the whole residue were DRAM-bound (it is not: L1/L2-resident tensors)" % bound) if pen else ""
    print("%-104s %9.1f %9.1f %s" % (name, f, t, extra))
enc = d['encoder_per_utterance']; b26 = d['cycle_split_encoder_b26']
print("\nencoder, per 4 s utterance (B26): fill %.1f ms = %.2f %% of the %.1f s hart-0 time spent in engine dispatches;"
      " the coordinator's relay puts it at 1.1 %% of the steady-state encoder" % (
    b26['cyc_fill'] / F0 * 1e3, 100.0 * b26['cyc_fill'] / b26['cycles_h0'], b26['cycles_h0'] / F0))
a_mb = enc['bytes_a'] / 1e6
print("  moving activations to a memory-clock lane: saves %.0f ms of fill (%.1f MB at 211 -> 800 MB/s)" % (
    a_mb / 211.0 * 1e3 - a_mb / 800.0 * 1e3, a_mb))
print("  ... and the flush contract costs %.0f ms (%d blocks x 14 cycles, s9.6 prediction, unmeasured)" % (
    enc['bytes_a'] / 64 * 14 / F0 * 1e3, enc['bytes_a'] // 64))
tok = d['decoder_per_token']
print("decoder per token: A %d B + out %d B -> %.2f ms at 276 MB/s, %.2f ms at 800" % (
    tok['bytes_a'], tok['out_bytes'], (tok['bytes_a'] + tok['out_bytes']) / 275.8e6 * 1e3, (tok['bytes_a'] + tok['out_bytes']) / 800e6 * 1e3))
