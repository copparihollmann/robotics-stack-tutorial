#!/usr/bin/env python3
# SIMULATION ONLY (a model). Generated skip RTL (000F) checks, hazard table, pre-dirty pattern. Reads out5/.
import re, os, subprocess, glob
HERE=os.path.dirname(os.path.abspath(__file__)); O=os.path.join(HERE,'out5')
def runs(name):
    txt=open(os.path.join(O,name+'.txt')).read(); out={}
    for blk in re.split(r'(?=RESULT )',txt)[1:]:
        lines=blk.splitlines(); kv=dict(x.split('=',1) for x in lines[0].split()[1:])
        d={'R':kv,'LAT':{},'BURST':None,'ATTR':{},'PW':{},'WRITER':{}}
        for l in lines[1:]:
            if l.startswith('LAT '):
                f=dict(x.split('=',1) for x in l.split()[1:] if '=' in x); d['LAT'][f['who']]=f
            elif l.startswith('BURST '): d['BURST']=re.findall(r'n=(\d+) delayed=(\d+) mean_wait=([\d.]+) max_wait=(\d+)',l)
            elif l.startswith('PW '): d['PW']=dict(x.split('=',1) for x in l.split()[1:])
            elif l.startswith('WRITER '): d['WRITER']=dict(x.split('=',1) for x in l.split()[1:])
            m=re.match(r'ATTR\s{3}(.+?)\s+(\d+)\s+([\d.]+) /block',l)
            if m: d['ATTR'][m.group(1).strip()]=float(m.group(3))
            m=re.match(r'ATTR  MSHRs valid histogram.*mean ([\d.]+)',l)
            if m: d['ATTR']['MSHRs valid (mean)']=float(m.group(1))
            m=re.match(r'ATTR out=\d+ window_cycles=\d+ blocks_delivered=[\d.]+ cycles_per_block=([\d.]+)',l)
            if m: d['ATTR']['cycles/block']=float(m.group(1))
        out[int(kv['out'])]=d
    return out
B=lambda d: float(d['R']['B/cycle'])
print("=== SIMULATION ONLY (a model). S=0, PARALLEL, L=10.65 unless noted, G=0, M=8, TLMonitors on. ===")
print("    lever1 = BwConfig; 000E = generated ReleaseAck-first cork (L2CorkConfig);")
print("    000F = generated skip-clean-Release (L2SkipConfig); skipvar = hand-edited rtl_variants/skipclean/MSHR.sv on lever-1")
print("\n[1] 000F (generated) vs skipvar (hand-edited): identical command lines")
names=sorted(os.path.basename(p)[len('gskip_'):-4] for p in glob.glob(os.path.join(O,'gskip_*.txt')))
for n in names:
    a=open(os.path.join(O,'gskip_'+n+'.txt')).read(); b=open(os.path.join(O,'skipvar_'+n+'.txt')).read()
    r=runs('gskip_'+n)
    print(f"  {n:16} byte-identical: {a==b}   runs {len(r)}   "+"  ".join(f"{o}:{B(d):.4f}" for o,d in r.items()))
print("\n[2] Hazard table: Get / Put latency in cycles (A fire at the client to last D beat), count over 2x median")
cases=[('dramw8_put8','probe 8 in flight + 8B Put writer','probe_get','writer_put'),
       ('dramw8_put64','probe 8 in flight + 64B Put writer','probe_get','writer_put'),
       ('dramw4_put8','probe 4 in flight + 8B Put writer','probe_get','writer_put'),
       ('dramw4_put64','probe 4 in flight + 64B Put writer','probe_get','writer_put'),
       ('dramw1_put8','probe 1 in flight + 8B Put writer','probe_get','writer_put'),
       ('alt8_dirty','alt W/fresh 8 in flight, W dirty','client_get','client_put'),
       ('alt4_dirty','alt W/fresh 4 in flight, W dirty','client_get','client_put'),
       ('alt8_clean','alt W/fresh 8 in flight, clean','client_get',None)]
print(f"  {'pattern':36} {'RTL':6} {'B/cycle':>8} | {'Get max':>7} {'p99.9':>5} {'>2xmed':>6} | {'Put max':>7} {'p99.9':>5} {'>2xmed':>6} | {'GD max wait':>11} | checks")
for f,t,g,p in cases:
    for b,lab in [('lever1','lever1'),('cork','000E'),('gskip','000F')]:
        d=list(runs(f"{b}_{f}").values())[0]; G=d['LAT'][g]; P=d['LAT'].get(p) if p else None
        ok=d['R']['cksum_ok']+d['R'].get('put_data_ok', d['WRITER'].get('put_data_ok','1'))+d['R'].get('readback_ok','1')
        gd=d['BURST'][0][3] if d['BURST'] else '-'
        pstr=f"{P['max']:>7} {P['p99.9']:>5} {P['over_2x_median']:>6}" if P else f"{'-':>7} {'-':>5} {'-':>6}"
        print(f"  {t:36} {lab:6} {B(d):>8.4f} | {G['max']:>7} {G['p99.9']:>5} {G['over_2x_median']:>6} | {pstr} | {gd:>11} | {ok}")
print("\n[3] TL monitors (checkable): see out5/control_*.txt; production runs above never printed an assertion")
for f in sorted(glob.glob(os.path.join(O,'control_*.txt'))):
    txt=open(f).read()
    hits=sorted(set(re.findall(r'Assertion failed in (TOP\.[\w.]+): Assertion failed: [^(]*\(connected at [^)]*/(Configs\.scala:\d+:\d+)\)',txt)))
    print(f"  {os.path.basename(f)}: "+("; ".join(f"{i} [{c}]" for i,c in hits) if hits else "no assertion"))
print("\n[4] Dirty-victim-heavy: 4 MiB pre-dirtied with 64-byte PutFulls (client), then the probe reads it at 8 in flight while an")
print("    8-byte lag writer (32 blocks behind) keeps victims dirty; then an untimed read-back of the whole region.")
print(f"  {'RTL':8} {'B/cycle':>8} {'cyc/Get':>8} | {'pre-write evictions=ReleaseData':>31} | {'phase2 ReleaseData/probe Get':>28} | {'Get max':>7} {'p99.9':>5} | {'Put max':>7} {'p99.9':>5} | {'GD mean/max wait':>16} | read matches pre-write / read-back matches all writes / Put data legal")
for b,lab in [('lever1','lever1'),('cork','000E'),('gskip','000F'),('skipvar','skipvar')]:
    d=list(runs(f"{b}_pw8").values())[0]; PW=d['PW']; G=d['LAT']['probe_get']; P=d['LAT']['writer_put']; gd=d['BURST'][0]
    print(f"  {lab:8} {B(d):>8.4f} {int(d['R']['cycles'])/int(d['R']['reqs']):>8.3f} | {PW['prewrite_evictions_as_ReleaseData']+' of '+PW['prewrite_64B_puts']+' puts':>31} | {float(PW['phase2_ReleaseData_per_probe_Get']):>28.4f} | {G['max']:>7} {G['p99.9']:>5} | {P['max']:>7} {P['p99.9']:>5} | {float(gd[2]):>7.3f}/{gd[3]:>8} | {PW['phase2_read_matches_prewritten']} / {PW['phase3_readback_matches_all_writes']} / {d['WRITER']['put_data_ok']}")
keys=['cycles/block','outer D fire GrantData beats','outer D fire ReleaseAck','outer D idle','mem D valid && !ready (cork/L2 backpressure)',
      'SinkD deq blocked: grant hazard (SourceD)','  ... of which the head is a ReleaseAck'.strip(),'SourceD busy (any stage)','SinkA req fire',
      '... sourceD busy','... directory write not ready','await_releaseack','MSHRs valid (mean)']
print("  per-block attribution, phase 2 (lever1 / 000E / 000F):")
A={b:list(runs(f"{b}_pw8").values())[0]['ATTR'] for b in ['lever1','cork','gskip']}
for k in keys: print(f"    {k[:48]:48} "+" / ".join(f"{A[b].get(k,0):.3f}" for b in A))
