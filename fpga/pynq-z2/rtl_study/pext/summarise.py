#!/usr/bin/env python3
"""Merge PEXT_RESULT lines from one or more Vivado logs into a markdown table.

Usage: summarise.py <log> [<log> ...]
"""
import re, sys

ROW = re.compile(
    r"PEXT_RESULT (\S+) lut=(\d+) lutlogic=(\d+) lutmem=(\d+) ff=(\d+) dsp=(\d+) "
    r"slack=([-\d.]+) dpd=([\d.]+) logic=([\d.?]+) route=([\d.?]+) levels=(\d+)")

rows = {}
for path in sys.argv[1:]:
    for line in open(path, errors="ignore"):
        if line.lstrip().startswith("#"):
            continue
        m = ROW.search(line)
        if m:
            rows[m.group(1)] = m.groups()

# harness floor: 64 input FFs per used source operand + 64 output FFs, 0 LUT
ALU_LEVELS = int(rows["alu_only"][10]) if "alu_only" in rows else 7
ALU_LOGIC = float(rows["alu_only"][8]) if "alu_only" in rows else 1.616

hdr = ("| op | LUT | FF | DSP | levels | logic ns | route ns | routed ns | "
       "slack @25ns | net EX levels |")
print(hdr)
print("|---|---|---|---|---|---|---|---|---|---|")
for k, g in rows.items():
    (lab, lut, lutlogic, lutmem, ff, dsp, slack, dpd, logic, route, lev) = g
    net = max(1, int(lev) - (ALU_LEVELS - 1)) if lab not in ("alu_only", "null") else 0
    print(f"| {lab} | {lut} | {ff} | {dsp} | {lev} | {logic} | {route} | {dpd} | {slack} | +{net} |")
print()
print(f"# reference: RocketALU = {ALU_LOGIC} ns logic over {ALU_LEVELS} levels")
