#!/usr/bin/env python3
"""s8.9: is the four-lane cap a PS time-rate (MB/s constant across FCLK1) or per memory-bus cycle
(B/cycle constant)?  Tabulates every run of one bitstream by read-back FCLK1, per lane set, at
the highest in-flight count, with the per-lane balance from the BYPLANE notes.

    python3 cap_test.py bf600a3b"""
import csv, os, re, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'bwlab', 'results.csv')
pre = sys.argv[1]
rows = [r for r in csv.DictReader(open(R)) if r['bitstream_md5'].startswith(pre) and r['level'].startswith('BYP_')]
runs = sorted({(r['fclk_mem_mhz'], r['timestamp']) for r in rows}, key=lambda x: (float(x[0]), x[1]))
sets = sorted({r['level'] for r in rows}, key=lambda x: (len(x), x))
print("%-10s" % "set" + "".join("   FCLK1 %-8s %-8s" % (f, t[11:16]) for f, t in runs))
for st in sets:
    line = "%-10s" % st
    for f, t in runs:
        d = {int(r['outstanding']): r for r in rows if r['level'] == st and r['timestamp'] == t}
        if not d:
            line += " " * 30; continue
        top = d[max(d)]
        lanes = [int(b) * 8 / int(c) for c, b in re.findall(r'lane\d cycles=(\d+) beats=(\d+)', top['notes'])]
        bal = (max(lanes) - min(lanes)) / max(lanes) * 100 if len(lanes) > 1 else 0.0
        ck = all('cksum_ok' in x['notes'] for x in d.values())
        line += "  %7.3f B/c %7.1f MB/s %s%s" % (float(top['bytes_per_cycle']), float(top['mb_per_s']),
                                                "b%.1f%%" % bal if len(lanes) > 1 else "     ", "" if ck else " MISMATCH")
    print(line)
print("\n(top in-flight count per set; b = spread of per-lane B/cycle within the set)")
