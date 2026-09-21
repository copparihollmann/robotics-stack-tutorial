#!/usr/bin/env python3
# SIMULATION ONLY. From an L2TB_SCHDBG dump: per MSHR, cycles its plan was blocked, split by the missing resource.
import sys
from collections import Counter
rows=[l.split() for l in open(sys.argv[1]) if l.startswith('S ')]
k=Counter()
for r in rows:
    _,t,srd,dwr,drv,schv,req,sel,D,A,C,W,stat=r
    srd,dwr=int(srd),int(dwr); schv,req,sel,D,W=[int(x,16) for x in (schv,req,sel,D,W)]
    for i in range(5):
        if not (schv>>i&1): continue
        both = (D>>i&1) and (W>>i&1)
        if not both: continue
        if sel>>i&1: k[(i,'won')]+=1
        elif req>>i&1: k[(i,'ready_lost_rr')]+=1
        elif srd and not dwr: k[(i,'SourceD free, dir write NOT ready')]+=1
        elif dwr and not srd: k[(i,'dir write ready, SourceD busy')]+=1
        elif not dwr and not srd: k[(i,'both busy')]+=1
        else: k[(i,'other')]+=1
print(f"{len(rows)} cycles; MSHR plans needing SourceD AND a Directory write in the same schedule (Put hit -> dirty):")
for key in sorted(k): print("  mshr", key[0], key[1], k[key])
