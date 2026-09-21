#!/usr/bin/env python3
# SIMULATION ONLY (a model). WideSkip: L2 + cork 128-bit on both sides, skip clean Release. Reads out6/.
import re, os
HERE=os.path.dirname(os.path.abspath(__file__)); O=os.path.join(HERE,'out6')
def runs(name, d=O):
    txt=open(os.path.join(d,name+'.txt')).read(); out={}
    for blk in re.split(r'(?=RESULT )',txt)[1:]:
        lines=blk.splitlines(); kv={}
        for x in lines[0].split()[1:]:
            if '=' in x: k,v=x.split('=',1); kv[k]=v
        r={'R':kv,'ATTR':{},'PHASE':{},'LAT':{}}
        for l in lines[1:]:
            m=re.match(r'ATTR out=\d+ window_cycles=\d+ blocks_delivered=[\d.]+ cycles_per_block=([\d.]+)',l)
            if m: r['ATTR']['cycles/block']=float(m.group(1))
            m=re.match(r'ATTR\s{3}(.+?)\s+(\d+)\s+([\d.]+) /block',l)
            if m: r['ATTR'][m.group(1).strip()]=float(m.group(3))
            m=re.match(r'ATTR  MSHRs valid histogram \(fraction of cycles\):(.*)  mean ([\d.]+)',l)
            if m: r['ATTR']['MSHRs valid (mean)']=float(m.group(2)); r['ATTR']['_hist']=m.group(1).strip()
            m=re.match(r'PHASE   (.+?)\s+([\d.]+)\s+\(seen',l)
            if m: r['PHASE'][m.group(1).strip()]=float(m.group(2))
            if l.startswith('LAT '):
                f=dict(x.split('=',1) for x in l.split()[1:] if '=' in x); r['LAT'][f['who']]=f
        out[int(kv['out'])]=r
    return out
B=lambda d: float(d['R']['B/cycle']); C=lambda d: int(d['R']['cycles'])/int(d['R']['reqs'])
cell=lambda d: f"{B(d):.4f} ({C(d):.3f})"
print("=== SIMULATION ONLY (a model). WideSkipConfig: 128-bit sbus, L2 inner AND outer 128-bit, TLCacheCork 128-bit (data-first),")
print("    skip clean Release. S=0, PARALLEL, G=0, M=8. Bytes = 8 x 64-bit words. A 64-byte Get = 4 inner and 4 outer beats.")
print("    P = memory supply period: at most one 128-bit outer D beat every P cycles (P=2: width widget over 64-bit AXI on the")
print("    L2 clock, 8 B/cycle of supply; P=1: memory path >= 2x faster). L = extra first-beat latency (first beat >= accept+1+L). ===")
h=runs('ws_hits'); ok=all(d['R']['cksum_ok']=='1' for d in h.values())
print("\n[1] L2 hits: "+"  ".join(f"{o}:{cell(d)}" for o,d in h.items())+f"   checksums {ok}")
cfgs=[('P2_L10.65','P=2 L=10.65'),('P2_L12.35','P=2 L=12.35'),('P2_L0','P=2 L=0'),('P1_L10.65','P=1 L=10.65'),('P1_L12.35','P=1 L=12.35'),('P1_L0','P=1 L=0')]
R={c:runs('ws_dram_'+c) for c,_ in cfgs}
print("\n[2] DRAM, 65,536 Gets, every miss evicts. B/cycle (cycles/Get)")
print(f"  {'out':>3} | "+" | ".join(f"{t:>16}" for _,t in cfgs))
for o in range(1,9): print(f"  {o:>3} | "+" | ".join(f"{cell(R[c][o]):>16}" for c,_ in cfgs))
print("  checksums: "+", ".join(f"{t} {all(d['R']['cksum_ok']=='1' for d in R[c].values())}" for c,t in cfgs)+"; peak in flight == out in every run: "+str(all(int(d['R']['peak'])==o for c,_ in cfgs for o,d in R[c].items())))
keys=['cycles/block','outer D fire GrantData beats','outer D fire ReleaseAck','outer C fire (Release)','outer D idle','outer D valid && !ready',
      'mem D valid && !ready (cork/L2 backpressure)','mem D idle: nothing outstanding at memory','mem D idle: outstanding, inside latency L',
      'mem D idle: burst chosen, supply period P','SinkD deq fire','SinkD deq blocked: grant hazard (SourceD)','SinkD deq blocked: BankedStore (sinkC/sourceC)',
      'inner D AccessAckData beats','inner D valid && !ready','SourceD busy (any stage)','SourceD SRAM read blocked','inner A valid && !ready',
      'SinkA req fire','Directory read','Directory write fire (enq)','Directory write queued behind a read',
      'cycles an MSHR was scheduled','cycles nothing scheduled','MSHR-cycles ready but lost arbitration','... sourceA busy','... sourceC busy','... sourceD busy','... sourceE busy',
      '... directory write not ready','no_meta(dir lookup)','release_unsched','acquire_unsched','await_first_grant','exec/grantack_unsched','grant_streaming',
      'await_releaseack','writeback_unsched','MSHRs valid (mean)']
MC={'MSHR-cycles ready but lost arbitration','... sourceA busy','... sourceC busy','... sourceD busy','... sourceE busy','... directory write not ready','no_meta(dir lookup)','release_unsched','acquire_unsched','await_first_grant','exec/grantack_unsched','grant_streaming','await_releaseack','writeback_unsched'}
for o in (4,8):
    sel=[('P2_L10.65','P=2 L=10.65'),('P1_L10.65','P=1 L=10.65'),('P1_L12.35','P=1 L=12.35'),('P1_L0','P=1 L=0')]
    print(f"\n[3] Per-block budget at {o} in flight (* = MSHR-cycles per block; everything else cycles per 64-byte block)")
    print(f"  {'':52} "+" ".join(f"{t:>12}" for _,t in sel))
    for k in keys:
        print(f"  {'*' if k in MC else ' '}{k[:51]:51} "+" ".join(f"{R[c][o]['ATTR'].get(k,0):>12.3f}" for c,_ in sel))
    for c,t in sel: print(f"    MSHRs valid histogram {t}: {R[c][o]['ATTR'].get('_hist','')}")
print("\n[4] 1 in flight, L=10.65: per-Get timeline (mean cycle offset from the probe's A fire)")
P={c:list(runs('ws_phases_'+c).values())[0] for c in ['P2_L10.65','P1_L10.65']}
print("  cycles/Get: "+"  ".join(f"{c} {C(d):.3f}" for c,d in P.items()))
for k in P['P2_L10.65']['PHASE']: print(f"  {k[:44]:44} "+" ".join(f"{P[c]['PHASE'].get(k,float('nan')):>9.3f}" for c in P))
