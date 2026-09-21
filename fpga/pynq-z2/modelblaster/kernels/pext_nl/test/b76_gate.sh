#!/usr/bin/env bash
# B76's pre-board gate for ALL FOUR of the decoder's hart-0 elementwise kernels -- host
# only, no board, no simulator, no lock.
#
# Every one of the four changes is value-preserving by construction, so the comparison has
# no tolerance and a single differing output byte fails:
#
#   permute4_s8   an alignment proved once per call, a loop interchange, and two loop
#                 invariants hoisted.  A permute has no arithmetic: the bytes must land
#                 where they landed.
#   mul_s8        the 128-bit table builder split into two 64-bit halves and turned into a
#                 recurrence, and the table's mirror symmetry used.  tb[] is IDENTICAL,
#                 verified entry by entry against fx32_apply for all 144 shipped triples
#                 before this gate was written, and the OUTPUT is compared here over the
#                 full 65,536-pair operand domain at every one of them.
#   layernorm_s8  nl_scale's __int128 removed where the operand cannot need it, with
#                 nl_scale ITSELF as the fallback, plus the (-128, 127) output tail.
#   softmax_s8    the row loop duplicated behind a constant `lazy` (B66's own prescription),
#                 the table build's __int128 removed, and a per-element statistics counter
#                 accumulated per row instead.
#
# THE POISONED ARMS ARE THE POINT.  Without them a route that never fires passes the
# byte-for-byte comparison perfectly -- which is how B66's first guard tested the wrong
# branch while passing all 6,462 comparisons.  Ten poisons, one per new route, each visible
# in the OUTPUT and not in an intermediate: B74's first attempt perturbed a multiplier by
# one unit, watched a `>> F` at F ~ 44 absorb it, and reported four live routes as dead.
# The mul_s8 poisons therefore SCALE an entry by 1 + 2^-8 rather than adding to it.
#
# The gate REQUIRES a-vs-b to pass for all four and EVERY poisoned arm to FAIL.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KP="$here/../../../kernels_t1/pext_nl/pext_nl_permute4_s8_pext_block.c"
KM="$here/../pext_nl_mul_s8_pext_int_mul.c"
KL="$here/../pext_nl_layernorm_s8_pext_int_rsqrt.c"
KS="$here/../pext_nl_softmax_s8_pext_int_memo2.c"
INC="-I$here/../../../../sw"
w="${B76_GATE_OUT:-$(mktemp -d)}"; mkdir -p "$w"
fails=0

# Each arm is one object with ONE global symbol.  int_nonlin.c's non-static globals would
# otherwise collide across arms in the same binary; objcopy localising all but the entry
# point is exact where --allow-multiple-definition silently picks one copy.
bp () {  # permute4: <obj> <suffix> <cc> <extra...>
  local o="$1"; shift; local x="$1"; shift; local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_permute4_s8="perm_$x" -Dpblk_nest="pn_$x" -Dpblk_copy="pc_$x" \
      -Dpblk_runs="pr_$x" -Dpblk_runs_w="prw_$x" -Dpblk_tblock="pt_$x" \
      -Dpblk_stride="ps_$x" -Dpblk_align="pa_$x" -Dpblk_mode="pm_$x" \
      "$@" -c "$KP" -o "$w/$o.o"
  objcopy --keep-global-symbol="perm_$x" "$w/$o.o"
}
bm () {  # mul_s8
  local o="$1"; shift; local x="$1"; shift; local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_mul_s8="mul_$x" -Dpint_mul_exact="pme_$x" \
      "$@" -c "$KM" -o "$w/$o.o"
  objcopy --keep-global-symbol="mul_$x" "$w/$o.o"
}
bl () {  # layernorm_s8
  local o="$1"; shift; local x="$1"; shift; local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_layernorm_s8="ln_$x" -Dnlk_f2mss="nf_$x" -Dnlk_msmul="nm_$x" \
      -Dln_scale="lsc_$x" -Dln_q8_full="lq_$x" \
      "$@" -c "$KL" -o "$w/$o.o"
  objcopy --keep-global-symbol="ln_$x" "$w/$o.o"
}
bs () {  # softmax_s8
  local o="$1"; shift; local x="$1"; shift; local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_softmax_s8="smx_$x" -Dsmx2_out="so_$x" -Dsmx2_ex="sx_$x" \
      -Dsmx2_rows="sr_$x" -Dsmx_scale="ssc_$x" \
      -Dmb_smx2_stats="st_$x" -Dmb_smx2_stats_t="stt_$x" \
      "$@" -c "$KS" -o "$w/$o.o"
  objcopy --keep-global-symbol="smx_$x" "$w/$o.o"
}

run () {  # run <name> <expect pass|fail> <binary>
  local name="$1" expect="$2" bin="$3" rc=0
  echo "--- $name (expect $expect) ---"
  "$bin" || rc=$?
  if [ "$expect" = pass ] && [ "$rc" != 0 ]; then
    echo "!!! $name FAILED and should have passed"; fails=$((fails+1))
  fi
  if [ "$expect" = fail ] && [ "$rc" = 0 ]; then
    echo "!!! $name PASSED and should have FAILED -- the new route is DEAD, not correct"
    fails=$((fails+1))
  fi
  echo
}

for CC in "gcc -O2" "gcc -O1 -g -fsanitize=address,undefined"; do
  tag="O2"; SAN=0; [ "$CC" != "gcc -O2" ] && { tag="SAN"; SAN=1; }

  # ---- permute4_s8 -------------------------------------------------------------
  bp "pa_$tag" a "$CC" -DMBP_B76=1
  bp "pb_$tag" b "$CC"
  $CC -Wall $INC "$here/b76_perm_gate.c" "$w/pa_$tag.o" "$w/pb_$tag.o" -o "$w/perm_$tag"
  run "permute4_s8 $tag  treatment vs ship" pass "$w/perm_$tag"
  for lvl in 1 2 3 4 5; do
    bp "pp${lvl}_$tag" a "$CC" -DMBP_B76=1 -DMBP_B76_POISON=$lvl
    $CC -Wall $INC "$here/b76_perm_gate.c" "$w/pp${lvl}_$tag.o" "$w/pb_$tag.o" \
        -o "$w/permp${lvl}_$tag"
    run "permute4_s8 $tag  POISON $lvl" fail "$w/permp${lvl}_$tag"
  done

  # ---- mul_s8 ------------------------------------------------------------------
  bm "ma_$tag" a "$CC" -DMBP_B76=1
  bm "mb_$tag" b "$CC"
  $CC -Wall $INC "$here/b76_mul_gate.c" "$w/ma_$tag.o" "$w/mb_$tag.o" -lm -o "$w/mul_$tag"
  run "mul_s8 $tag  treatment vs ship" pass "$w/mul_$tag"
  for lvl in 1 2 3; do
    bm "mp${lvl}_$tag" a "$CC" -DMBP_B76=1 -DMBP_B76_POISON=$lvl
    $CC -Wall $INC "$here/b76_mul_gate.c" "$w/mp${lvl}_$tag.o" "$w/mb_$tag.o" -lm \
        -o "$w/mulp${lvl}_$tag"
    run "mul_s8 $tag  POISON $lvl" fail "$w/mulp${lvl}_$tag"
  done

  # ---- layernorm_s8: B66's own gate, re-pointed at B76's two arms ---------------
  bl "la_$tag" a "$CC" -DMBP_B76=1
  bl "lb_$tag" b "$CC"
  $CC -Wall $INC "$here/b66_ln_gate.c" "$w/la_$tag.o" "$w/lb_$tag.o" -lm -o "$w/ln_$tag"
  run "layernorm_s8 $tag  treatment vs ship" pass "$w/ln_$tag"
  for lvl in 6 7; do
    bl "lp${lvl}_$tag" a "$CC" -DMBP_B76=1 -DMBP_B76_POISON=$lvl
    $CC -Wall $INC "$here/b66_ln_gate.c" "$w/lp${lvl}_$tag.o" "$w/lb_$tag.o" -lm \
        -o "$w/lnp${lvl}_$tag"
    run "layernorm_s8 $tag  POISON $lvl" fail "$w/lnp${lvl}_$tag"
  done

  # ---- softmax_s8: B66's own gate.  Arm c is the COVERAGE arm and it is what makes
  #      the split lazy loop reachable at the encoder's shape, where the guard would
  #      otherwise always choose eager -- B66's own lesson about dead paths. ---------
  bs "sa_$tag" a "$CC" -DMBP_B76=1
  bs "sb_$tag" b "$CC"
  bs "sc_$tag" c "$CC" -DMBP_B76=1 -DMBP_B76_SMX_MINN=1000000000
  bs "sd_$tag" d "$CC" -DMBP_B76=1 -DMBP_B76_SMX_MINN=0
  $CC -Wall $INC "$here/b66_smx_gate.c" "$w/sa_$tag.o" "$w/sb_$tag.o" "$w/sc_$tag.o" \
      "$w/sd_$tag.o" -lm -o "$w/smx_$tag"
  run "softmax_s8 $tag  treatment/all-lazy/all-eager vs ship" pass "$w/smx_$tag"
  for lvl in 8 9 10; do
    bs "sp${lvl}_$tag" a "$CC" -DMBP_B76=1 -DMBP_B76_POISON=$lvl
    bs "sq${lvl}_$tag" c "$CC" -DMBP_B76=1 -DMBP_B76_SMX_MINN=1000000000 \
       -DMBP_B76_POISON=$lvl
    bs "sr${lvl}_$tag" d "$CC" -DMBP_B76=1 -DMBP_B76_SMX_MINN=0 -DMBP_B76_POISON=$lvl
    $CC -Wall $INC "$here/b66_smx_gate.c" "$w/sp${lvl}_$tag.o" "$w/sb_$tag.o" \
        "$w/sq${lvl}_$tag.o" "$w/sr${lvl}_$tag.o" -lm -o "$w/smxp${lvl}_$tag"
    run "softmax_s8 $tag  POISON $lvl" fail "$w/smxp${lvl}_$tag"
  done
  [ "$SAN" = 1 ] && break || true
done

if [ "$fails" = 0 ]; then
  echo "B76 GATE PASSED: all four treatments byte-identical to the shipping kernels over"
  echo "every shape and scale the decoder dispatches, and all ten new routes proved live by"
  echo "a poisoned arm that the same gate rejects."
else
  echo "B76 GATE FAILED: $fails checks did not do what they must"
fi
echo "workdir: $w"
exit "$fails"
