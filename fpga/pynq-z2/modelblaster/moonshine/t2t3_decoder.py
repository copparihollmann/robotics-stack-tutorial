#!/usr/bin/env python3
"""What T2 (the attention unit) and T3 (the LayerNorm lane) are worth to the DECODER.

Reads a decode_compose.py --out record and prices, from measurements this programme owns:
  * what each block removes, by kind, sized by Lab B31's ladder;
  * the attention unit's OWN decoder cost -- 48 head-images of 16 KB planar K/V re-filled per
    token, because the 80 KB scratchpad holds five of them -- at every measured/projected port;
  * a resident-K/V variant, which does not fit;
  * the per-dispatch software wrapper, measured by Lab B25 as eng_h0_cycles - eng_cycles.

  python3 t2t3_decoder.py board/b31_decode_compose_sized.json
"""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
d = json.load(open(sys.argv[1] if len(sys.argv) > 1
                   else os.path.join(HERE, "board", "b31_decode_compose_sized.json")))
CLK=34482759.0; TOK=12; WIN=4.0
r=d['residue_by_kind_ms']['B26+B31/nl+ew']
res=sum(r.values())
# the attention unit's OWN decoder cost, priced from the fill rates this programme measured.
# 48 head-images (8 heads x 6 layers), one 16 KB planar K/V image each (ATTENTION_UNIT.md 1.7),
# re-filled every token because 80 KB of scratchpad holds 5 of the 48.
IMG=16*1024; NIMG=8*6; FILLB=IMG*NIMG
ARRAY=474.0*1*NIMG/CLK*1e3           # 474 cycles per query row, L_q = 1
def unit(F):  return FILLB/F/CLK*1e3 + ARRAY
ports=[("as measured (SBUS, 3 outstanding)", None, d['ports_projection'][0]['gemm_ms_per_token']*0+158.7, 7.342)]
for p in d['ports_projection']:
    ports.append((p['port'], p['b_per_core_cycle'], p['gemm_ms_per_token'], p['b_per_core_cycle']))
print("residue %.1f ms/token (matmul %.2f, softmax %.2f, layernorm %.2f, rope %.2f)"
      % (res, r['matmul'], r['softmax'], r['layernorm'], r['rope']))
print("T2 removes matmul + softmax = %.2f ms  (NOT rope: section 1.6 keeps rotary in software)"
      % (r['matmul']+r['softmax']))
print()
# T3's own cost, priced below: best = one dispatch per token with resident affine parameters,
# worst = one dispatch per layernorm with them re-filled.  It was ZERO in the first version of
# this table, which is the omission the attention workstream found in T2 one row up.
D_=288; LN_N=3*6; LN_LAT=550.0; LN_CPE=1.000; PARAM_B=2*4*D_
W=4924.0/CLK*1e3
def t3cost(F, nd, resident):
    lane=(nd*LN_LAT+LN_N*D_*LN_CPE)/CLK*1e3
    fillb=LN_N*PARAM_B/(TOK if resident else 1)+LN_N*D_
    return lane+fillb/F/CLK*1e3+nd*W
hdr="%-44s %6s %6s %6s %13s %6s"%("port","GEMM","base","T2","T2+T3 (cost)","unit")
print(hdr); print("-"*len(hdr))
def rtf(tok): return (d['gemm_once_ms']['engine_place64']+TOK*tok)/1e3/WIN
for name,_,gemm,F in ports:
    u=unit(F)
    base=gemm+res
    t2=gemm+res-r['matmul']-r['softmax']+u
    t23b=t2-r['layernorm']+t3cost(F,1,True)
    t23w=t2-r['layernorm']+t3cost(F,18,False)
    print("%-44s %6.1f %6.3f %6.3f %6.3f-%-6.3f %6.2f"
          % (name[:44],gemm,rtf(base),rtf(t2),rtf(t23b),rtf(t23w),u))
print()
print("unit decoder cost = %d KB of K/V re-filled per token + %.2f ms of array (474 c/head x 48)"
      % (FILLB//1024, ARRAY))
for F,lab in ((7.342,"engine cap 4"),(23.20,"MBUS 1 lane"),(46.40,"MBUS 2 lanes")):
    print("   at %5.2f B/cycle (%-12s): fill %6.3f ms, fill:array = %.1f:1"
          % (F,lab,FILLB/F/CLK*1e3,(FILLB/F/CLK*1e3)/ARRAY))

# ---- the software wrapper, which neither lane document prices ------------------------------
# Lab B25 measures it directly: eng_h0_cycles - eng_cycles is what hart 0 pays around a dispatch
# beyond the engine's own busy time, and it is FLAT in dispatch size -- 4,701 cycles around a
# 48 k-cycle dec_qkvo, 4,956 around a 5.4 M-cycle enc_fc1.
print()
print("per-dispatch hart-0 wrapper, MEASURED (Lab B25, eng_h0 - eng): 4,701-5,190 cycles, flat")
print("   %-34s %8s %8s" % ("granularity", "ms/token", "vs the gain"))
for lab, nd, gain in (("attention: one dispatch per head", 48, 51.23),
                      ("attention: one per layer (8 heads)", 6, 51.23),
                      ("attention: one per token", 1, 51.23),
                      ("LayerNorm lane: one per layernorm", 18, 9.65),
                      ("LayerNorm lane: one per layer", 6, 9.65)):
    print("   %-34s %8.2f %7.1f %%" % (lab, nd * W, 100 * nd * W / gain))
print()
print("array time per token is %.2f ms (474 cycles x 48 heads at L_q = 1): one wrapper per head"
      % ARRAY)
print("   would be %.1fx the array it wraps." % (W / (474.0 / CLK * 1e3)))

# ---- T3's OWN cost, which the table above credited at zero -----------------------------------
# The identical omission just corrected in T2.  The LayerNorm lane reads through the same
# scratchpad, drains through the same mbxr_st, and one path owns both at a time
# (LAYERNORM_LANE.md 6.3), so its time is added, not overlapped.  Its own simulated numbers:
# 1.000 cycles/element for LayerNorm at K >= 250, plus 550 cycles of latency PER DISPATCH
# ("13 dispatches x 165 rows x 288 cycles + 13 x 550 of latency", LAYERNORM_LANE.md 7).
LN_PER_TOKEN = LN_N
print()
print("T3's OWN decoder cost -- the row the table above prices at zero")
print("  the lane: %d elements/token at %.3f c/el, plus 550 cycles per DISPATCH" %
      (LN_PER_TOKEN * D_, LN_CPE))
print("  its parameters: %d x %d B = %d KB/token if re-filled -- and that FITS the 80 KB"
      % (LN_PER_TOKEN, PARAM_B, LN_PER_TOKEN * PARAM_B // 1024))
print("  scratchpad, which is the structural difference from T2's 768 KB.")
print()
print("  %-34s %7s %7s %7s %7s %8s" % ("granularity / residency", "lane", "fill", "wrap", "cost",
                                       "net of 9.65"))
for lab, nd, resident in (("one dispatch per layernorm (18)", 18, False),
                          ("one per layer (6)", 6, False),
                          ("one per layer, params resident", 6, True),
                          ("one per token (1), params resident", 1, True)):
    lane = (nd * LN_LAT + LN_PER_TOKEN * D_ * LN_CPE) / CLK * 1e3
    fillb = LN_PER_TOKEN * PARAM_B / (TOK if resident else 1) + LN_PER_TOKEN * D_
    fill = fillb / 7.342 / CLK * 1e3
    wrap = nd * W
    cost = lane + fill + wrap
    print("  %-34s %7.3f %7.3f %7.3f %7.3f %8.2f" % (lab, lane, fill, wrap, cost, 9.645 - cost))
print()
print("  so T3 nets 6.4-9.1 ms/token, not 9.65, and the spread is ALL interface: wrapper")
print("  granularity and whether the affine parameters stay resident.")
print()
print("  SENSITIVITY THAT DWARFS IT: T3's gain is 9.65 ms against layernorm_pc_s8 (reference C,")
print("  60.78 c/el) and 20.51 ms against the curated pext_int_rsqrt (136.48) -- 2.1x, decided")
print("  by which kernel a decoder's software baseline would use.  Lab B31 refused its own")
print("  ladder for layernorm, so this stays open.")
