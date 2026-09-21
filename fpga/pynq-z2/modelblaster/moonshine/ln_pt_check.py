#!/usr/bin/env python3
"""Can the LayerNorm lane serve per-tensor `layernorm_s8`, and what does it cost in bytes?

    fpga/pynq-z2/modelblaster/moonshine/ln_pt_check.py [--ir out/qatu_long/ir] [--json ...]

WHY.  The lane serves `layernorm_pc_s8`; the shipping candidate QATU emits per-tensor
`layernorm_s8`, and it is the ONLY op QATU cannot reach a lane for.  Closing that is a kernel,
not an extractor change, and its whole risk is arithmetic: the substitution replaces
`pext_int_rsqrt`'s mantissa/shift core with `_Q16_NORM_CORE`, which is what mbxr_ln.v computes.

WHAT THIS MEASURES, AND WHY max_abs_err CANNOT.  The board lab compares against a host golden
rebuilt FROM THE SAME KERNEL, so once a `layernorm_s8` lane kernel exists, a bit-exactness check
compares the new arithmetic against itself and passes at 0 while proving nothing.  That is the
trap.  So this runs BOTH REAL KERNELS -- the tree's own `pext_nl_layernorm_s8_pext_int_rsqrt.c`
and the lane's `_Q16_NORM_CORE`, reached through the committed derivation in
`kernels/roccmoon/roccmoon/mbxr_ln_derive.h` -- on the same input, at every site of a real graph,
and reports the distribution of their disagreement.  Neither core is reimplemented here.

It does NOT decide the question.  A per-element delta is a PREDICTOR for a WER measurement, not
a substitute: the check that decides is WER against the candidate's measured baseline, over a
named set and a stated number of utterances.
"""
import argparse, json, os, subprocess, sys, tempfile
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "..", ".."))
KERN = os.path.join(ROOT, "fpga", "pynq-z2", "modelblaster", "kernels")
SW = os.path.join(ROOT, "fpga", "pynq-z2", "sw")

HARNESS = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define MB_PEXT_HW 0
#include "pext_nl_layernorm_s8_pext_int_rsqrt.c"   /* core A: what the candidate runs today */
#include "roccmoon/mbxr_ln_derive.h"                  /* the derivation under test, verbatim */

/* core B: _Q16_NORM_CORE, the expression mbxr_ln.v implements */
static int64_t isq(unsigned __int128 v){unsigned __int128 r=0,b=(unsigned __int128)1<<126;
  while(b>v)b>>=2; while(b){if(v>=r+b){v-=r+b;r=(r>>1)+b;}else r>>=1;b>>=2;} return (int64_t)r;}
static void coreB(const int8_t*x,const int32_t*um,const int64_t*gm,const int64_t*bd,int8_t*y,
                  int M,int K,int64_t eq){
  for(int m=0;m<M;m++){const int8_t*xi=x+(size_t)m*K;int8_t*yo=y+(size_t)m*K;
    int64_t S=0;__int128 Q=0;
    for(int k=0;k<K;k++){int64_t u=(int64_t)xi[k]*um[k];S+=u;Q+=(__int128)u*u;}
    __int128 V=(__int128)K*Q-(__int128)S*S+(__int128)eq;
    int64_t R=isq(((unsigned __int128)1<<120)/(unsigned __int128)V);
    for(int k=0;k<K;k++){__int128 d=(__int128)K*((int64_t)xi[k]*um[k])-(__int128)S;
      int64_t t=(int64_t)((d*(__int128)R)>>44);
      int64_t v=(t*gm[k]+bd[k]*65536+((int64_t)1<<31))>>32;
      if(v<-128)v=-128; if(v>127)v=127; yo[k]=(int8_t)v;}}}

int main(int argc,char**argv){
  int M=atoi(argv[1]),K=atoi(argv[2]);
  float si=atof(argv[3]),so=atof(argv[4]),ep=atof(argv[5]);
  static float gm[4096],bt[4096]; static int32_t um[4096]; static int64_t g2[4096],b2[4096],eq;
  static int8_t x[1<<21],ya[1<<21],yb[1<<21];
  FILE*f=fopen(argv[6],"rb"); if(!f||fread(gm,4,K,f)!=(size_t)K||fread(bt,4,K,f)!=(size_t)K) return 2; fclose(f);
  f=fopen(argv[7],"rb"); if(!f||fread(x,1,(size_t)M*K,f)!=(size_t)M*K) return 2; fclose(f);
  kernel_layernorm_s8(x,gm,bt,ya,M,K,si,so,ep,-128,127);
  if(!mbxr_ln_derive_pt(gm,bt,K,si,so,ep,-128,127,um,g2,b2,&eq)){printf("{\"derived\":false}\n");return 0;}
  coreB(x,um,g2,b2,yb,M,K,eq);
  long n=(long)M*K,diff=0,d1=0,d2=0; int worst=0;
  for(long i=0;i<n;i++){int d=ya[i]-yb[i]; if(d<0)d=-d; if(d){diff++; if(d==1)d1++; else d2++;}
    if(d>worst)worst=d;}
  printf("{\"derived\":true,\"eps_q\":%lld,\"umul\":%d,\"n\":%ld,\"differ\":%ld,"
         "\"by_1\":%ld,\"by_2_or_more\":%ld,\"max_abs\":%d}\n",
         (long long)eq,um[0],n,diff,d1,d2,worst);
  return 0;}
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ir", default=os.path.join(ROOT, "out", "qatu_long", "ir"))
    ap.add_argument("--json", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                   "ln_pt_check.json"))
    ap.add_argument("--seed", type=int, default=12345)
    a = ap.parse_args()

    g = json.load(open(os.path.join(a.ir, "graph.json")))
    W = np.load(os.path.join(a.ir, "weights.npz"))
    ops = [o for o in g["ops"] if o["op"] == "layernorm_s8"]
    if not ops:
        sys.exit("%s has no layernorm_s8 ops -- this check is for a per-tensor candidate" % a.ir)

    tmp = tempfile.mkdtemp(prefix="ln_pt_")
    csrc = os.path.join(tmp, "h.c")
    open(csrc, "w").write(HARNESS)
    exe = os.path.join(tmp, "h")
    cc = subprocess.run(["gcc", "-O2", "-I", os.path.join(KERN, "pext_nl"),
                         "-I", os.path.join(KERN, "roccmoon"), "-I", SW,
                         "-o", exe, csrc, "-lm"], capture_output=True, text=True)
    if cc.returncode:
        sys.exit("harness did not build:\n" + cc.stderr[-2000:])

    rng = np.random.default_rng(a.seed)
    rows = []
    for o in ops:
        q, sh = o["quant"], o["shape"]
        M, K = sh["M"], sh["K"]
        gm = W[o["weight"]].astype(np.float32)
        bt = (W[o["bias"]].astype(np.float32) if o.get("bias") in W.files
              else np.zeros(K, np.float32))
        gp = os.path.join(tmp, "gb.bin"); open(gp, "wb").write(gm.tobytes() + bt.tobytes())
        # UNIFORM int8 is the STRESS case, not the typical one: it exercises the whole range,
        # where real activations are concentrated.  Named so nobody reads it as "on real data".
        x = rng.integers(-128, 128, size=M * K, dtype=np.int16).astype(np.int8)
        xp = os.path.join(tmp, "x.bin"); open(xp, "wb").write(x.tobytes())
        r = subprocess.run([exe, str(M), str(K), repr(q["scale_in"]), repr(q["scale_out"]),
                            repr(q["eps"]), gp, xp], capture_output=True, text=True)
        if r.returncode:
            sys.exit("harness failed on %s: %s" % (o["name"], r.stderr[-800:]))
        d = json.loads(r.stdout)
        d.update(name=o["name"], M=M, K=K, **{k: q[k] for k in ("scale_in", "scale_out", "eps")})
        rows.append(d)

    ok = all(r["derived"] for r in rows)
    worst = max((r.get("max_abs", 0) for r in rows), default=0)
    any2 = sum(r.get("by_2_or_more", 0) for r in rows)
    out = {"what": "per-tensor layernorm_s8 on the LayerNorm lane: does the derivation accept, "
                   "and how far do the two cores disagree",
           "ir": a.ir, "input": "uniform random int8 (the stress case, not real activations)",
           "seed": a.seed, "sites": len(rows),
           "all_sites_derived": ok, "max_abs_over_all_sites": worst,
           "elements_differing_by_2_or_more": any2,
           "decides_nothing": "the check that decides is WER against the candidate's measured "
                              "baseline; max_abs_err cannot see this substitution at all",
           "rows": rows}
    json.dump(out, open(a.json, "w"), indent=1)

    print("per-tensor layernorm_s8 -> LayerNorm lane, %d sites from %s" % (len(rows), a.ir))
    print("  %-42s %8s %9s %7s" % ("site", "differ", "of", "max_abs"))
    for r in rows:
        print("  %-42s %8d %9d %7d%s" % (r["name"], r.get("differ", -1), r.get("n", 0),
                                         r.get("max_abs", -1),
                                         "" if r["derived"] else "   DERIVE REFUSED"))
    print("  all sites derived: %s ; worst disagreement %d LSB ; elements off by >=2: %d"
          % (ok, worst, any2))
    print("  input was UNIFORM RANDOM int8 -- the stress case.  WER decides, not this.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
