#!/usr/bin/env python3
# SIMULATION ONLY. Compare out/*.txt sweeps with the silicon rows (fpga/pynq-z2/bwlab/results.csv, bitstream 737d2f57).
import re, os
HERE=os.path.dirname(os.path.abspath(__file__))
SIL_HITS = {1:(918416,4.5713),2:(524806,7.9999),3:(524806,7.9999),4:(524806,7.9999),6:(524806,7.9999),8:(524806,7.9999)}
SIL_DRAM = {1:(1942993,2.1587),2:(971637,4.3167),3:(670983,6.2510),4:(703844,5.9591),6:(684791,6.1249),8:(684801,6.1249)}
def load(name):
    r={}
    for line in open(os.path.join(HERE,'out',name)):
        if not line.startswith('RESULT'): continue
        kv=dict(x.split('=',1) for x in line.split()[1:])
        r[int(kv['out'])]=kv
    return r
def table(title, name, sil, n):
    r=load(name)
    print(f"\n{title}   [{name}]")
    print(f"{'out':>4} {'sim cycles':>11} {'sim B/cyc':>10} {'cyc/Get':>8} {'peak':>5} {'cksum':>6} | {'silicon cyc':>11} {'sil B/cyc':>10} {'cyc/Get':>8} | {'dB/cyc %':>8}")
    for o in sorted(r):
        kv=r[o]; sc,sb=sil[o]
        b=float(kv['B/cycle']); c=int(kv['cycles'])
        print(f"{o:>4} {c:>11} {b:>10.4f} {c/n:>8.3f} {kv['peak']:>5} {kv['cksum_ok']:>6} | {sc:>11} {sb:>10.4f} {sc/n:>8.3f} | {100*(b-sb)/sb:>+8.2f}")
table("L2 hits, S=0", "hits_S0.txt", SIL_HITS, 65600)
table("DRAM, PARALLEL memory, L=10.65 (calibrated)", "dram_parallel_L10.65.txt", SIL_DRAM, 65536)
table("DRAM, SERIAL memory, L=10.65 (calibrated)", "dram_serial_L10.65.txt", SIL_DRAM, 65536)
table("DRAM, FIFO memory (strict order, latency from accept), L=10.65", "dram_fifo_L10.65.txt", SIL_DRAM, 65536)
table("DRAM, ideal memory PARALLEL L=0", "dram_parallel_L0.txt", SIL_DRAM, 65536)
table("DRAM, ideal memory SERIAL L=0", "dram_serial_L0.txt", SIL_DRAM, 65536)
for f,t in [("dram_parallel_L10.txt","PARALLEL L=10"),("dram_parallel_L11.txt","PARALLEL L=11"),("dram_parallel_L5.txt","PARALLEL L=5"),
            ("dram_parallel_L21.3.txt","PARALLEL L=21.3"),("dram_parallel_L10.65_G1.txt","PARALLEL L=10.65 G=1"),
            ("dram_parallel_L0_G1.txt","PARALLEL L=0 G=1"),("dram_parallel_L10.65_M2.txt","PARALLEL L=10.65 M=2"),
            ("dram_parallel_L10.65_M4.txt","PARALLEL L=10.65 M=4"),
            ("rackfirst_dram_parallel_L10.65.txt","RTL WHAT-IF cork ReleaseAck-first, PARALLEL L=10.65"),
            ("rackfirst_dram_parallel_L0.txt","RTL WHAT-IF cork ReleaseAck-first, PARALLEL L=0"),
            ("rackfirst_dram_serial_L10.65.txt","RTL WHAT-IF cork ReleaseAck-first, SERIAL L=10.65")]:
    table("DRAM, "+t, f, SIL_DRAM, 65536)
