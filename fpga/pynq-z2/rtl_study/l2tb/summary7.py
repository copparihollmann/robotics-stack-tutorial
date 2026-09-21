#!/usr/bin/env python3
# SIMULATION ONLY (a model). WideSkip (7 MSHRs) vs WideSkipM12 (12 MSHRs); optional dirq2 what-if. Reads out7/.
import re, os, sys
HERE=os.path.dirname(os.path.abspath(__file__)); O=os.path.join(HERE,'out7')
def runs(name):
    p=os.path.join(O,name+'.txt')
    if not os.path.exists(p): return None
    txt=open(p).read(); out={}
    for blk in re.split(r'(?=RESULT )',txt)[1:]:
        lines=blk.splitlines(); kv={}
        for x in lines[0].split()[1:]:
            if '=' in x: k,v=x.split('=',1); kv[k]=v
        r={'R':kv,'ATTR':{},'LAT':{}}
        for l in lines[1:]:
            m=re.match(r'ATTR out=\d+ window_cycles=\d+ blocks_delivered=[\d.]+ cycles_per_block=([\d.]+)',l)
            if m: r['ATTR']['cycles/block (10-90% window)']=float(m.group(1))
            m=re.match(r'ATTR\s{3}(.+?)\s+(\d+)\s+([\d.]+) /block',l)
            if m: r['ATTR'][m.group(1).strip()]=float(m.group(3))
            m=re.match(r'ATTR  MSHRs valid histogram \(fraction of cycles\):(.*)  mean ([\d.]+)',l)
            if m: r['ATTR']['MSHRs valid (mean)']=float(m.group(2)); r['ATTR']['_hist']=' '.join(x for x in m.group(1).split() if not x.endswith(':0.000'))
            if l.startswith('LAT '):
                f=dict(x.split('=',1) for x in l.split()[1:] if '=' in x); r['LAT'][f['who']]=f
        out[int(kv['out'])]=r
    return out
B=lambda d: float(d['R']['B/cycle']); C=lambda d: int(d['R']['cycles'])/int(d['R']['reqs'])
cell=lambda d: f"{B(d):.4f} ({C(d):.3f})"
V=[b for b in ['wideskip','wideskipm12','wideskip_dirq2','wideskipm12_dirq2'] if runs(b+'_hits')]
LAB={'wideskip':'WideSkip 7 MSHR','wideskipm12':'WideSkipM12 12 MSHR','wideskip_dirq2':'WideSkip+dirq2 (WHAT-IF)','wideskipm12_dirq2':'M12+dirq2 (WHAT-IF)'}
print("=== SIMULATION ONLY (a model). 128-bit L2 on both sides, skip clean Release, data-first cork. S=0, PARALLEL, G=0, M=8.")
print("    P = memory supply period (one 128-bit outer beat every P cycles); L = extra first-beat latency. B/cycle = 8 x 64-bit words / cycles.")
print("    dirq2 = hand-edited Directory.sv whose write queue has 2 entries instead of 1: a WHAT-IF, not generated RTL. ===")
print("\n[1] L2 hits")
for b in V:
    h=runs(b+'_hits'); print(f"  {LAB[b]:26} "+"  ".join(f"{o}:{B(d):.4f}" for o,d in h.items())+f"   checksums {all(d['R']['cksum_ok']=='1' for d in h.values())}")
for P in (1,2):
    for L in ('10.65','12.0','0'):
        print(f"\n[2] DRAM P={P} L={L}: B/cycle (cycles/Get, whole run) | 10-90% window cycles/block")
        R={b:runs(f"{b}_dram_P{P}_L{L}") for b in V}
        R={b:r for b,r in R.items() if r}
        print(f"  {'out':>3} | "+" | ".join(f"{LAB[b]:>34}" for b in R))
        for o in range(1,9):
            print(f"  {o:>3} | "+" | ".join(f"{cell(R[b][o]):>24} {R[b][o]['ATTR']['cycles/block (10-90% window)']:>9.3f}" for b in R))
        print("  checks: "+", ".join(f"{b} cksum {all(d['R']['cksum_ok']=='1' for d in R[b].values())} peak==out {all(int(d['R']['peak'])==o for o,d in R[b].items())}" for b in R))
keys=['cycles/block (10-90% window)','outer D fire GrantData beats','outer D idle','outer D valid && !ready','mem D valid && !ready (cork/L2 backpressure)',
      'mem D idle: nothing outstanding at memory','mem D idle: outstanding, inside latency L','mem D idle: burst chosen, supply period P',
      'SinkD deq fire','SinkD deq blocked: grant hazard (SourceD)','inner D AccessAckData beats','inner D valid && !ready','SourceD busy (any stage)',
      'SourceD SRAM read blocked','inner A valid && !ready','SinkA req fire','Directory read','Directory write fire (enq)','Directory write enq blocked',
      'Directory write queued behind a read','cycles an MSHR was scheduled','cycles nothing scheduled','MSHR-cycles ready but lost arbitration',
      '... sourceA busy','... sourceD busy','... sourceE busy','... directory write not ready','no_meta(dir lookup)','release_unsched','acquire_unsched',
      'await_first_grant','exec/grantack_unsched','grant_streaming','writeback_unsched','MSHRs valid (mean)']
MC={'MSHR-cycles ready but lost arbitration','... sourceA busy','... sourceD busy','... sourceE busy','... directory write not ready','no_meta(dir lookup)','release_unsched','acquire_unsched','await_first_grant','exec/grantack_unsched','grant_streaming','writeback_unsched'}
sets=[(1,'10.65'),(1,'12.0'),(1,'0')]
for o in (5,8):
    for P,L in sets:
        R={b:runs(f"{b}_dram_P{P}_L{L}") for b in V}; R={b:r for b,r in R.items() if r}
        print(f"\n[3] Per-block budget, P={P} L={L}, {o} in flight (* = MSHR-cycles per block)")
        print(f"  {'':52} "+" ".join(f"{LAB[b][:22]:>22}" for b in R))
        for k in keys: print(f"  {'*' if k in MC else ' '}{k[:51]:51} "+" ".join(f"{R[b][o]['ATTR'].get(k,0):>22.3f}" for b in R))
        for b in R: print(f"    MSHRs valid histogram {LAB[b]}: {R[b][o]['ATTR'].get('_hist','')}")

print("\n[4] Probe Get latency (A fire to last D beat), P=1: max / p99.9 / count over 2x median, at 5..8 in flight")
for L in ('10.65','12.0','0'):
    print(f"  L={L}")
    for b in V:
        R=runs(f"{b}_dram_P1_L{L}")
        print(f"    {LAB[b]:26} "+"  ".join(f"{o}: {R[o]['LAT']['probe_get']['max']}/{R[o]['LAT']['probe_get']['p99.9']}/{R[o]['LAT']['probe_get']['over_2x_median']}" for o in (5,6,7,8)))
