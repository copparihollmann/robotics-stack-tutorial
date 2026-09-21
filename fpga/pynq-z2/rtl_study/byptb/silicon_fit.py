#!/usr/bin/env python3
"""Fit silicon BYP_ rows from results.csv against the byptb closed form min(8, 64N/(12+L)) per lane.

    python3 silicon_fit.py <md5-prefix> [...]

L is taken from the lane's own 1-in-flight row: L = cycles_per_Get - 12 (memory-bus cycles),
then reported in ns with the row's read-back FCLK1."""
import csv, os, re, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'bwlab', 'results.csv')
rows = list(csv.DictReader(open(R)))
for pre in sys.argv[1:]:
    rs = [r for r in rows if r['bitstream_md5'].startswith(pre) and r['level'].startswith('BYP_')]
    if not rs:
        print(pre, 'no BYP_ rows'); continue
    runs = sorted({(r['timestamp'], r['fclk_mem_mhz']) for r in rs})
    for ts, f1 in runs:
        rr = [r for r in rs if r['timestamp'] == ts]
        f1 = float(f1)
        print('== %s  %s  FCLK1 %.4f MHz  qos %s' % (pre, ts, f1, rr[0].get('ddrqos_hash', '')))
        by = {}
        for r in rr:
            by.setdefault(r['level'], {})[int(r['outstanding'])] = r
        for lvl in sorted(by, key=lambda x: (len(x), x)):
            d = by[lvl]
            nl = len(lvl) - len('BYP_L') if lvl != 'BYP_SEQ' else 1
            reqs1 = int(re.search(r'reqs=(\d+)', d[min(d)]['notes']).group(1))
            cpg = int(d[min(d)]['cycles']) * nl / reqs1 * min(d)
            L = cpg - 12
            ok = all('cksum_ok' in x['notes'] for x in d.values())
            cells = []
            for n in sorted(d):
                b = float(d[n]['bytes_per_cycle']); pred = nl * min(8.0, 64.0 * n / (12 + L))
                cells.append('@%d %.3f(%+.1f%%)' % (n, b, 100 * (b - pred) / pred))
            best = max(float(x['mb_per_s']) for x in d.values())
            print('  %-10s %-16s L=%5.2f cyc = %5.1f ns | %s | peak %.1f MB/s | %s' % (
                lvl, d[min(d)]['hp_port_set'], L, L * 1000 / f1, ' '.join(cells), best, 'cksum ok' if ok else 'MISMATCH'))
