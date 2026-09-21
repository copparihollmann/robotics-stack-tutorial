#!/usr/bin/env python3
"""SIMULATION ONLY.  Tabulate byptb sweeps: B/cycle by (cap, latency, set, in flight), plus the
1-in-flight round trip and the in-flight count at which a lane first reaches 99 % of its plateau."""
import re, sys
from collections import defaultdict
pts = defaultdict(dict)
for line in open(sys.argv[1] if len(sys.argv) > 1 else 'results/sweep1.txt'):
    m = re.search(r'lat=(\d+) cap=(\d+) set=(\S+) out=(\d+) cycles=(\d+) beats=(\d+) reqs=(\d+) bpc=([\d.]+) cyc_per_get=([\d.]+) peak=(\d+).*cksum=(\S+)', line)
    if not m: continue
    lat, cap, st, out = int(m.group(1)), int(m.group(2)), m.group(3), int(m.group(4))
    pts[(cap, lat, st)][out] = (float(m.group(8)), float(m.group(9)), int(m.group(10)), m.group(11))
outs = sorted({o for d in pts.values() for o in d})
bad = sum(1 for d in pts.values() for v in d.values() if v[3] != 'ok')
print("points %d, checksum mismatches %d" % (sum(len(d) for d in pts.values()), bad))
for cap in sorted({k[0] for k in pts}):
    print("\n== AXI read issue cap %d (as-run AFI: 8)" % cap)
    print("%-4s %-4s %8s " % ("lat", "set", "c/Get@1") + " ".join("%6d" % o for o in outs) + "   knee(99%)")
    for lat in sorted({k[1] for k in pts if k[0] == cap}):
        for st in ('L0', 'L01', 'SEQ'):
            d = pts.get((cap, lat, st))
            if not d: continue
            plateau = max(v[0] for v in d.values())
            knee = min((o for o, v in d.items() if v[0] >= 0.99 * plateau), default=None)
            print("%-4d %-4s %8.2f " % (lat, st, d[min(d)][1]) + " ".join("%6.2f" % d[o][0] if o in d else "     -" for o in outs) + "   %s" % knee)
