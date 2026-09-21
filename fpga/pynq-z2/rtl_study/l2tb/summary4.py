#!/usr/bin/env python3
# SIMULATION ONLY (a model). A: skip clean Releases; B: 128-bit system bus. Tables from out4/.
import re, os, sys
HERE=os.path.dirname(os.path.abspath(__file__)); O=os.path.join(HERE,'out4')
sys.path.insert(0, HERE)
SIL_DRAM = {1:2.1587,2:4.3167,3:6.2510,4:5.9591,6:6.1249,8:6.1249}
def runs(name):
    txt=open(os.path.join(O,name+'.txt')).read(); out={}
    for blk in re.split(r'(?=RESULT )',txt)[1:]:
        lines=blk.splitlines(); kv=dict(x.split('=',1) for x in lines[0].split()[1:])
        d={'R':kv,'LAT':{},'BURST':None,'ATTR':{},'PHASE':{}}
        for l in lines[1:]:
            if l.startswith('LAT '):
                f=dict(x.split('=',1) for x in l.split()[1:] if '=' in x); d['LAT'][f['who']]=f
            elif l.startswith('BURST '):
                d['BURST']=re.findall(r'n=(\d+) delayed=(\d+) mean_wait=([\d.]+) max_wait=(\d+)',l)
            m=re.match(r'ATTR out=\d+ window_cycles=\d+ blocks_delivered=[\d.]+ cycles_per_block=([\d.]+)',l)
            if m: d['ATTR']['cycles/block (window)']=float(m.group(1))
            m=re.match(r'ATTR\s{3}(.+?)\s+(\d+)\s+([\d.]+) /block',l)
            if m: d['ATTR'][m.group(1).strip()]=float(m.group(3))
            m=re.match(r'ATTR  MSHRs valid histogram \(fraction of cycles\):(.*)  mean ([\d.]+)',l)
            if m: d['ATTR']['MSHRs valid (mean)']=float(m.group(2)); d['ATTR']['_hist']=m.group(1)
            m=re.match(r'PHASE   (.+?)\s+([\d.]+)\s+\(seen',l)
            if m: d['PHASE'][m.group(1).strip()]=float(m.group(2))
        out[int(kv['out'])]=d
    return out
B=lambda d: float(d['R']['B/cycle']); C=lambda d: int(d['R']['cycles'])/int(d['R']['reqs'])
def cell(d): return f"{B(d):.4f} ({C(d):.3f})"
def chk(rs): return all(d['R']['cksum_ok']=='1' and d['R'].get('put_data_ok','1')=='1' and d['R'].get('readback_ok','1')=='1' for d in rs.values())

print("=== SIMULATION ONLY (a model). S=0, PARALLEL, G=0, M=8, TLMonitors on. 'skip' = MSHR.sv variant that sends no outer")
print("    Release for a clean victim; 'cork' = generated ReleaseAck-first RTL (L2CorkConfig); 'rackfirst' on Wide = the same")
print("    edit applied by hand to the Wide config's TLCacheCork.sv. B/cycle (cycles/Get). ===")
V=[('lever1','lever-1 RTL'),('cork','cork (RA-first)'),('skip','skip-clean only'),('cork_skip','cork + skip-clean')]
print("\n[A1] L2 hits (4 KiB x 1025)")
for b,t in V: print(f"  {t:20} "+"  ".join(f"{o}:{cell(d)}" for o,d in runs(b+'_hits').items())+f"   checks {chk(runs(b+'_hits'))}")
for L in ['10.65','12.35','15']:
    print(f"\n[A2] DRAM, 65,536 Gets, L={L}")
    print(f"  {'out':>3} | "+" | ".join(f"{t:>18}" for b,t in V)+(" | silicon" if L=='10.65' else ""))
    R={b:runs(f"{b}_dram_L{L}") for b,_ in V}
    for o in range(1,9):
        print(f"  {o:>3} | "+" | ".join(f"{cell(R[b][o]):>18}" for b,_ in V)+(f" | {SIL_DRAM[o]:.4f}" if L=='10.65' and o in SIL_DRAM else ""))
    print("  checks: "+", ".join(f"{b} {chk(R[b])}" for b,_ in V))

keys=['cycles/block (window)','outer D fire GrantData beats','outer D fire ReleaseAck','outer C fire (Release)','outer D idle',
      'outer D valid && !ready','mem D valid && !ready (cork/L2 backpressure)','mem D idle: nothing outstanding at memory',
      'mem D idle: outstanding, inside latency L','cork ReleaseAck queued, lost to data','outer C valid && !ready (cork RA queue full)',
      'SinkD deq fire','SinkD deq blocked: grant hazard (SourceD)','SinkD deq blocked: BankedStore (sinkC/sourceC)',
      'inner D valid && !ready','SourceD busy (any stage)','SourceD SRAM read blocked','inner A valid && !ready',
      'cycles an MSHR was scheduled','MSHR-cycles ready but lost arbitration','... sourceA busy','... sourceC busy','... sourceD busy',
      '... sourceE busy','... directory write not ready','Directory write queued behind a read',
      'release_unsched','acquire_unsched','await_first_grant','exec/grantack_unsched','grant_streaming','await_releaseack',
      'writeback_unsched','MSHRs valid (mean)']
for o in (4,8):
    print(f"\n[A3] Per-block budget, DRAM L=10.65, {o} in flight (rows marked * are MSHR-cycles per block)")
    A={b:runs(f"{b}_dram_L10.65")[o]['ATTR'] for b,_ in V}
    print(f"  {'':50} "+" ".join(f"{b:>10}" for b,_ in V))
    for k in keys:
        star='*' if k.startswith('...') or k in ('MSHR-cycles ready but lost arbitration','release_unsched','acquire_unsched','await_first_grant','exec/grantack_unsched','grant_streaming','await_releaseack','writeback_unsched') else ' '
        print(f"  {star}{k[:49]:49} "+" ".join(f"{A[b].get(k,0):>10.3f}" for b,_ in V))
    for b,_ in V: print(f"    MSHRs valid histogram {b}:{A[b]['_hist']}")

print("\n[A4] Dirty-victim path (evictions become ReleaseData -> PutFullData through the cork's A path). L=10.65.")
print("     Get latency = A fire to 8th D beat; GD = GrantData burst wait at the cork; checks = probe/client checksum, Put data legal at memory, W read-back")
cases=[('dramw1_put8','probe DRAM 1 + 8B Puts','probe_get'),('dramw4_put8','probe DRAM 4 + 8B Puts','probe_get'),
       ('dramw8_put8','probe DRAM 8 + 8B Puts','probe_get'),('dramw8_put64','probe DRAM 8 + 64B Puts','probe_get'),
       ('alt8_clean','alt W/fresh 8, clean','client_get'),('alt8_dirty','alt W/fresh 8, W dirty','client_get')]
print(f"  {'pattern':26} {'RTL':10} {'B/cycle':>8} | {'Get mean':>8} {'p99.9':>5} {'max':>5} {'>2xmed':>6} | {'Put max':>7} | {'mem Puts':>8} {'Releases/blk':>12} {'RAs/blk':>7} | {'GD max w':>8} | checks")
for f,t,who in cases:
    for b,_ in V:
        d=list(runs(f"{b}_{f}").values())[0]; L=d['LAT'][who]
        pk=[k for k in d['LAT'] if k in ('writer_put','client_put')]
        pm=d['LAT'][pk[0]]['max'] if pk else '-'
        g=d['BURST'][0] if d['BURST'] else ('-','-','-','-')
        ok=d['R']['cksum_ok']+d['R'].get('put_data_ok','1')+d['R'].get('readback_ok','1')
        print(f"  {t:26} {b:10} {B(d):>8.4f} | {float(L['mean']):>8.3f} {L['p99.9']:>5} {L['max']:>5} {L['over_2x_median']:>6} | {pm:>7} | {d['R']['mem_puts']:>8} {d['ATTR'].get('outer C fire (Release)',0):>12.3f} {d['ATTR'].get('outer D fire ReleaseAck',0):>7.3f} | {g[3]:>8} | {ok}")

print("\n[A5] 1-in-flight DRAM (core-like), L=10.65: cycles/Get and event timeline")
P={b:list(runs(f"{b}_phases_L10.65").values())[0] for b in ['lever1','skip','cork_skip']}
print(f"  cycles/Get: "+"  ".join(f"{b} {C(d):.3f}" for b,d in P.items()))
for k in P['lever1']['PHASE']:
    print(f"  {k[:44]:44} "+" ".join(f"{P[b]['PHASE'].get(k,float('nan')):>9.3f}" for b in P))

W=[('wide','Wide alone'),('wide_rackfirst','Wide + rackfirst'),('wide_skip','Wide + skip only'),('wide_rackfirst_skip','Wide + rackfirst + skip')]
print("\n[B1] 128-bit system bus: L2 hits (bytes counted as 8 x 64-bit words)")
for b,t in W: print(f"  {t:24} "+"  ".join(f"{o}:{cell(d)}" for o,d in runs(b+'_hits').items())+f"   checks {chk(runs(b+'_hits'))}")
print("\n[B2] 128-bit system bus: DRAM, L=10.65")
R={b:runs(f"{b}_dram_L10.65") for b,_ in W}
print(f"  {'out':>3} | "+" | ".join(f"{t:>23}" for b,t in W)+" | lever-1 64-bit | silicon lever-1")
L1=runs('lever1_dram_L10.65')
for o in range(1,9):
    print(f"  {o:>3} | "+" | ".join(f"{cell(R[b][o]):>23}" for b,_ in W)+f" | {cell(L1[o]):>14} | "+(f"{SIL_DRAM[o]:.4f}" if o in SIL_DRAM else ""))
print("  checks: "+", ".join(f"{b} {chk(R[b])}" for b,_ in W))
for o in (4,8):
    print(f"\n[B3] Wide per-block budget, DRAM L=10.65, {o} in flight")
    A={b:R[b][o]['ATTR'] for b,_ in W}
    print(f"  {'':50} "+" ".join(f"{b:>20}" for b,_ in W))
    for k in keys + ['inner D AccessAckData beats']:
        print(f"  {k[:50]:50} "+" ".join(f"{A[b].get(k,0):>20.3f}" for b,_ in W))
