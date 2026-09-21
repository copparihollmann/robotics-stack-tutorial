#!/usr/bin/env python3
# SIMULATION ONLY. Follow-up tables from out2/*.txt, next to lever-1 RTL and the silicon rows (bitstream 737d2f57).
import re, os
HERE=os.path.dirname(os.path.abspath(__file__)); O=os.path.join(HERE,'out2')
SIL_DRAM = {1:(1942993,2.1587),2:(971637,4.3167),3:(670983,6.2510),4:(703844,5.9591),6:(684791,6.1249),8:(684801,6.1249)}
SIL_HITS = {1:(918416,4.5713),2:(524806,7.9999),3:(524806,7.9999),4:(524806,7.9999),6:(524806,7.9999),8:(524806,7.9999)}
def load(name):
    r={}; attr={}; ph={}
    txt=open(os.path.join(O,name+'.txt')).read()
    for blk in re.split(r'(?=RESULT )',txt)[1:]:
        kv=dict(x.split('=',1) for x in blk.splitlines()[0].split()[1:]); o=int(kv['out']); r[o]=kv
        rows={}
        for line in blk.splitlines():
            m=re.match(r'ATTR out=\d+ window_cycles=\d+ blocks_delivered=[\d.]+ cycles_per_block=([\d.]+)',line)
            if m: rows['cycles/block (window)']=float(m.group(1))
            m=re.match(r'ATTR\s{3}(.+?)\s+(\d+)\s+([\d.]+) /block',line)
            if m: rows[m.group(1).strip()]=float(m.group(3))
            m=re.match(r'ATTR  MSHRs valid histogram \(fraction of cycles\):(.*)  mean ([\d.]+)',line)
            if m: rows['MSHRs valid (mean)']=float(m.group(2)); rows['_hist']=m.group(1).strip()
            m=re.match(r'PHASE   (.+?)\s+([\d.]+)\s+\(seen',line)
            if m: ph[m.group(1).strip()]=float(m.group(2))
        attr[o]=rows
    return r,attr,ph
def bpc(kv): return float(kv['B/cycle'])
def cpg(kv): return int(kv['cycles'])/int(kv['reqs'])

print("=== SIMULATION. Calibration S=0, PARALLEL, L=10.65, G=0, M=8. Silicon = lever-1 bitstream 737d2f57. ===")
print("\n[1a] L2 hits (4 KiB x 1025), B/cycle (cycles/Get)")
H={c:load(c+'_hits')[0] for c in ['lever1','mshr12','cap256']}
print(f"{'out':>4} | {'silicon':>16} | {'lever-1 RTL':>16} | {'12-MSHR RTL':>16} | {'256 KB RTL':>16} | cksum")
for o in sorted(H['lever1']):
    cells=[f"{bpc(H[c][o]):.4f} ({cpg(H[c][o]):.3f})" for c in ['lever1','mshr12','cap256']]
    sc,sb=SIL_HITS[o]
    print(f"{o:>4} | {sb:.4f} ({sc/65600:.3f}) | "+" | ".join(f"{x:>16}" for x in cells)+" | "+''.join(H[c][o]['cksum_ok'] for c in H))

R={}; A={}
for c in ['lever1','mshr12','cap256']:
    R[c],A[c],_=load(c+'_dram_L10.65')
print("\n[1b] DRAM, 65,536 64-byte Gets, every miss evicts. B/cycle (cycles/Get); peak in flight; cksum")
print(f"{'out':>4} | {'silicon':>17} | {'lever-1 RTL':>17} | {'12-MSHR RTL':>17} | {'256 KB RTL':>17} | peaks | cksum")
for o in sorted(R['lever1']):
    s = f"{SIL_DRAM[o][1]:.4f} ({SIL_DRAM[o][0]/65536:.3f})" if o in SIL_DRAM else "not measured"
    cells=[f"{bpc(R[c][o]):.4f} ({cpg(R[c][o]):.3f})" for c in R]
    print(f"{o:>4} | {s:>17} | "+" | ".join(f"{x:>17}" for x in cells)+" | "+'/'.join(R[c][o]['peak'] for c in R)+" | "+''.join(R[c][o]['cksum_ok'] for c in R))

keys=['cycles/block (window)','outer D fire GrantData beats','outer D fire ReleaseAck','outer D idle',
      'mem D idle: nothing outstanding at memory','mem D idle: outstanding, inside latency L',
      'cork ReleaseAck queued, lost to data','outer C valid && !ready (cork RA queue full)',
      'SinkD deq blocked: grant hazard (SourceD)','inner A valid && !ready',
      'MSHR-cycles ready but lost arbitration','... sourceC busy','... sourceD busy','... directory write not ready',
      'Directory write queued behind a read',
      'no_meta(dir lookup)','release_unsched','acquire_unsched','await_first_grant','exec/grantack_unsched',
      'grant_streaming','await_releaseack','writeback_unsched','MSHRs valid (mean)']
for o in (4,8):
    print(f"\n[1c] Per-block budget at {o} in flight (window 10%..90% of requests; per 64-byte block unless noted)")
    print(f"{'':52} {'lever-1':>9} {'12-MSHR':>9} {'256 KB':>9}")
    for k in keys:
        lab = k + (' [MSHR-cycles]' if k in ('no_meta(dir lookup)','release_unsched','acquire_unsched','await_first_grant','exec/grantack_unsched','grant_streaming','await_releaseack','writeback_unsched','MSHR-cycles ready but lost arbitration','... sourceC busy','... sourceD busy','... directory write not ready') else '')
        print(f"{lab[:52]:52} "+" ".join(f"{A[c][o].get(k,0):>9.3f}" for c in A))
    for c in A: print(f"  MSHRs-valid histogram {c}: {A[c][o]['_hist']}")

print("\n[2] 128 KiB working set (2048 blocks), fresh region, 1 untimed pass + 33 timed passes (67,584 Gets)")
print(f"{'out':>4} | {'lever-1 RTL B/cyc (cyc/Get)':>28} {'misses':>7} {'miss%':>6} | {'256 KB RTL B/cyc (cyc/Get)':>28} {'misses':>7} {'miss%':>6} | cksum")
W={c:load(c+'_ws128k_L10.65')[0] for c in ['lever1','cap256']}
for o in sorted(W['lever1']):
    cells=[]
    for c in W:
        kv=W[c][o]; m=int(kv['mem_gets']); n=int(kv['reqs'])
        cells.append(f"{bpc(kv):.4f} ({cpg(kv):.3f})".rjust(28)+f" {m:>7} {100*m/n:>6.2f}")
    print(f"{o:>4} | "+" | ".join(cells)+" | "+''.join(W[c][o]['cksum_ok'] for c in W))

print("\n[3] Memory-latency sensitivity, PARALLEL, DRAM. 1-in-flight cycles/Get, then B/cycle at 2,3,4,6,8")
for var in ['lever1','rackfirst']:
    print(f"  {('lever-1 RTL' if var=='lever1' else 'RTL WHAT-IF: cork ReleaseAck-first (NOT silicon RTL)')}")
    print(f"  {'L':>6} {'cyc/Get@1':>10} {'B/cyc@1':>8} | {'@2':>7} {'@3':>7} {'@4':>7} {'@6':>7} {'@8':>7} | cksum")
    for L in ['10.65','11.5','12.35','13.3','15','21.3']:
        r=load(f'lsweep_{var}_L{L}')[0]
        print(f"  {L:>6} {cpg(r[1]):>10.3f} {bpc(r[1]):>8.4f} | "+" ".join(f"{bpc(r[o]):>7.4f}" for o in (2,3,4,6,8))+" | "+''.join(r[o]['cksum_ok'] for o in sorted(r)))
    print(f"  {'sil.':>6} {29.648:>10.3f} {2.1587:>8.4f} | "+" ".join(f"{SIL_DRAM[o][1]:>7.4f}" for o in (2,3,4,6,8)))

print("\n[4] Per-Get event timeline at 1 in flight (mean cycle offset from the probe's A fire)")
P={}
for n in ['phases_lever1_L0','phases_lever1_L10.65','phases_lever1_L11','phases_mshr12_L10.65','phases_cap256_L10.65']:
    r,_,ph=load(n); P[n]=(r,ph)
names=list(P['phases_lever1_L10.65'][1].keys())
print(f"{'event':44} "+" ".join(f"{n.replace('phases_',''):>14}" for n in P))
for k in names:
    print(f"{k[:44]:44} "+" ".join(f"{P[n][1].get(k,float('nan')):>14.3f}" for n in P))
print(f"{'cycles/Get (whole run)':44} "+" ".join(f"{cpg(P[n][0][1]):>14.3f}" for n in P))
