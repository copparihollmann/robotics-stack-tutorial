#!/usr/bin/env python3
# SIMULATION ONLY. Tabulate ATTR blocks of one out/*.txt file, per block, columns = in-flight cap.
import re, sys
txt=open(sys.argv[1]).read()
sel=sys.argv[2:]  # optional substrings to filter rows
runs={}; order=[]
for b in re.split(r'(?=RESULT )',txt)[1:]:
    o=int(re.search(r'out=(\d+)',b).group(1))
    rows={}
    m=re.search(r'B/cycle=([\d.]+)',b); rows['B/cycle (whole run)']=float(m.group(1))
    for line in b.splitlines():
        mm=re.match(r'ATTR out=\d+ window_cycles=\d+ blocks_delivered=[\d.]+ cycles_per_block=([\d.]+)',line)
        if mm: rows['cycles/block (window)']=float(mm.group(1))
        mm=re.match(r'ATTR\s{3}(.+?)\s+(\d+)\s+([\d.]+) /block',line)
        if mm: rows[mm.group(1).strip()]=float(mm.group(3))
        mm=re.match(r'ATTR  MSHRs valid histogram.*mean ([\d.]+)',line)
        if mm: rows['MSHRs valid (mean)']=float(mm.group(1))
    runs[o]=rows
    for k in rows:
        if k not in order: order.append(k)
cols=sorted(runs)
print('%-48s'%sys.argv[1].split('/')[-1] + ''.join('%9s'%('out=%d'%o) for o in cols))
for k in order:
    if sel and not any(s in k for s in sel): continue
    print('%-48s'%k[:48] + ''.join('%9.3f'%runs[o].get(k,0) for o in cols))
