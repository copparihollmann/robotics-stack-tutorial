#!/usr/bin/env python3
# SIMULATION ONLY. Tables for the generated ReleaseAck-first cork follow-up (out3/).
import re, os
HERE=os.path.dirname(os.path.abspath(__file__)); O=os.path.join(HERE,'out3')
SIL_DRAM = {1:2.1587,2:4.3167,3:6.2510,4:5.9591,6:6.1249,8:6.1249}
def runs(name):
    txt=open(os.path.join(O,name+'.txt')).read()
    out=[]
    for blk in re.split(r'(?=RESULT )',txt)[1:]:
        lines=blk.splitlines()
        kv=dict(x.split('=',1) for x in lines[0].split()[1:])
        d={'R':kv,'LAT':{},'BURST':None,'WRITER':None,'ATTR':{},'PHASE':{}}
        for l in lines[1:]:
            if l.startswith('LAT '):
                f=dict(x.split('=',1) for x in l.split()[1:] if '=' in x); d['LAT'][f['who']]=f
            elif l.startswith('BURST '):
                m=re.findall(r'n=(\d+) delayed=(\d+) mean_wait=([\d.]+) max_wait=(\d+)',l); d['BURST']=m
            elif l.startswith('WRITER '):
                d['WRITER']=dict(x.split('=',1) for x in l.split()[1:])
            m=re.match(r'ATTR\s{3}(.+?)\s+(\d+)\s+([\d.]+) /block',l)
            if m: d['ATTR'][m.group(1).strip()]=float(m.group(3))
            m=re.match(r'ATTR  MSHRs valid histogram.*mean ([\d.]+)',l)
            if m: d['ATTR']['MSHRs valid (mean)']=float(m.group(1))
            m=re.match(r'PHASE   (.+?)\s+([\d.]+)\s+\(seen',l)
            if m: d['PHASE'][m.group(1).strip()]=float(m.group(2))
        out.append(d)
    return out
B=lambda d: float(d['R']['B/cycle'])
C=lambda d: int(d['R']['cycles'])/int(d['R']['reqs'])

print("=== SIMULATION ONLY. S=0, PARALLEL, L=10.65 (unless noted), G=0, M=8. TLMonitors on. ===")
print("\n[1] Generated ReleaseAck-first cork (L2CorkConfig) vs hand-edited rackfirst variant: B/cycle (cycles/Get)")
for f,title in [('hits','L2 hits'),('dram_L10.65','DRAM L=10.65'),('dram_L12.35','DRAM L=12.35'),('dram_L15','DRAM L=15'),('dram_L21.3','DRAM L=21.3')]:
    a=runs('cork_'+f); b=runs('rackfirst_'+f)
    same = open(os.path.join(O,'cork_'+f+'.txt')).read()==open(os.path.join(O,'rackfirst_'+f+'.txt')).read()
    print(f"  {title:14} files byte-identical: {same}")
    print("    out: "+"  ".join(f"{d['R']['out']}:{B(d):.4f}({C(d):.3f})" for d in a))
    if not same: print("    rackfirst: "+"  ".join(f"{d['R']['out']}:{B(d):.4f}" for d in b))
lev=runs('../out2/lever1_dram_L10.65') if False else None

def row(d, who):
    L=d['LAT'].get(who,{})
    g=d['BURST'][0] if d['BURST'] else ('0','0','0','0')
    return (B(d), C(d), L.get('mean','-'), L.get('median','-'), L.get('p99','-'), L.get('p99.9','-'), L.get('max','-'), L.get('over_2x_median','-'), g)
print("\n[2] Starvation-reversal checks: data-first (lever-1 RTL) vs ReleaseAck-first (generated cork RTL)")
print("    Get latency = cycles from the client's A fire to its 8th D beat. 'GrantData wait' = cycles a memory")
print("    AccessAckData burst sat valid && !ready at the cork (per burst).")
hdr=f"    {'pattern':34} {'RTL':6} {'B/cycle':>8} {'cyc/Get':>8} | {'lat mean':>8} {'med':>4} {'p99':>4} {'p99.9':>5} {'max':>4} {'>2xmed':>6} | {'GD bursts':>9} {'delayed':>7} {'mean w':>6} {'max w':>5} | extra"
print(hdr)
cases=[('dramw1_put8','probe DRAM 1 in flight + 8B Puts','probe_get'),
       ('dramw4_put8','probe DRAM 4 in flight + 8B Puts','probe_get'),
       ('dramw8_put8','probe DRAM 8 in flight + 8B Puts','probe_get'),
       ('dramw8_put64','probe DRAM 8 in flight + 64B Puts','probe_get'),
       ('dramw8_put8_L0','same, 8B Puts, ideal memory L=0','probe_get'),
       ('alt8_clean','alt W/fresh, 8 in flight, clean','client_get'),
       ('alt8_dirty','alt W/fresh, 8 in flight, W dirty','client_get'),
       ('alt4_dirty','alt W/fresh, 4 in flight, W dirty','client_get'),
       ('alt8_dirty_L0','alt dirty 8, ideal memory L=0','client_get')]
for f,title,who in cases:
    for rtl in ['lever1','cork']:
        d=runs(f"{rtl}_{f}")[0]
        b,c,mean,med,p99,p999,mx,over,g=row(d,who)
        extra=[]
        for k in ('writer_put','client_put'):
            if k in d['LAT']:
                w=d['LAT'][k]; wi=d['LAT'][k+'_from_L2_accept']
                extra.append(f"Put lat mean {w['mean']} p99.9 {w['p99.9']} max {w['max']} (inside L2 max {wi['max']}) n {w['n']}")
        gi=d['LAT'].get(who+'_from_L2_accept')
        if gi: extra.insert(0, f"Get inside-L2 max {gi['max']}")
        extra.append(f"mem Puts {d['R']['mem_puts']}")
        ok=d['R']['cksum_ok']+d['R'].get('put_data_ok','1')+d['R'].get('readback_ok','1')
        a=d['BURST'][1] if d['BURST'] else None
        if a: extra.append(f"AccessAck(ReleaseData) bursts {a[0]} delayed {a[1]} mean {a[2]} max {a[3]}")
        extra.append(f"checks {ok}")
        print(f"    {title:34} {rtl:6} {b:>8.4f} {c:>8.3f} | {float(mean):>8.3f} {med:>4} {p99:>4} {p999:>5} {mx:>4} {over:>6} | {g[0]:>9} {g[1]:>7} {float(g[2]):>6.3f} {g[3]:>5} | "+"; ".join(extra))
print("\n    selected attribution per block (lever-1 / cork)")
keys=['outer D fire ReleaseAck','cork ReleaseAck queued, lost to data','outer C valid && !ready (cork RA queue full)',
      'mem D valid && !ready (cork/L2 backpressure)','SinkD deq blocked: grant hazard (SourceD)','  ... of which the head is a ReleaseAck'.strip(),
      'outer D idle','release_unsched','await_releaseack','MSHRs valid (mean)']
for f,title,who in cases:
    a=runs(f"lever1_{f}")[0]['ATTR']; c=runs(f"cork_{f}")[0]['ATTR']
    print(f"    {title}: "+"; ".join(f"{k.replace('... ','')} {a.get(k,0):.3f}/{c.get(k,0):.3f}" for k in keys))

print("\n[3] Core-like single-outstanding DRAM miss stream (1 in flight), L=10.65")
a=runs('lever1_phases_L10.65')[0]; c=runs('cork_phases_L10.65')[0]
print(f"    cycles/Get: lever-1 {C(a):.3f} ({a['R']['cycles']} cycles)   cork {C(c):.3f} ({c['R']['cycles']} cycles)")
print(f"    {'event':44} {'lever-1':>9} {'cork':>9}")
for k in a['PHASE']:
    print(f"    {k[:44]:44} {a['PHASE'][k]:>9.3f} {c['PHASE'].get(k,float('nan')):>9.3f}")
