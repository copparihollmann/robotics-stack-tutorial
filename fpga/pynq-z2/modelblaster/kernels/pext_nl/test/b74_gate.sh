#!/usr/bin/env bash
# B74's pre-board gate for BOTH kernels -- host only, no board, no simulator.
#
# The two changes are value-preserving by construction, so the comparison has no tolerance:
#   rope_s8  pint_rope_apply is fx32_apply restricted to m < 2^24 and k.q <= 2^40; the
#            pass-through loop and the pair loop's index are restructurings.
#   add_s8   the linear route computes v * (k.q << l), which IS pint_add_table's entry on
#            its left-shift arm, term for term.
#
# Arms, one source each, one define apart:
#   a  -DMBP_B74=1     the treatment
#   b  default          the shipping kernel
# and the coverage arm, which is the point of the exercise:
#   p1 -DMBP_B74_POISON=1  add_s8's linear marking loop
#   p2 -DMBP_B74_POISON=2  rope_s8's restricted apply
#   p3 -DMBP_B74_POISON=3  rope_s8's pass-through helper
#   p4 -DMBP_B74_POISON=4  rope_s8's recovered pair index (read only by the fall-back, so
#                          this one also proves the adversarial tables reach that path)
# The gate REQUIRES a-vs-b to pass and EVERY poisoned arm to FAIL.  Without the second, a
# route that never fires passes the first perfectly -- which is how B66's first guard
# tested the wrong branch while passing all 6,462 comparisons.  This gate has already
# earned that: its first poison (A += 1) left every output byte unchanged, because at
# F ~ 44 a unit change in the multiplier cannot survive the >> F.  A poison must be visible
# in the OUTPUT.
#
# Coverage is b63_{add,rope}_gate.c's, unchanged: every add_s8 scale triple that ships
# (444) over all 65,536 (a, b) pairs, n = 0..600 across the block boundary, the dispatch's
# own n, random and tie-heavy triples, out-of-domain scales, narrowed clamps; and for
# rope_s8 all 65,536 (a0, a1) at every table position, the model's own rotary tables plus
# adversarial ones chosen to drive entries into the slow path, every (T, H, D, R) the graph
# dispatches plus odd ones, and narrowed clamps.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KA="$here/../pext_nl_add_s8_pext_int_add.c"
KR="$here/../pext_nl_rope_s8_pext_int_rot.c"
INC="-I$here/../../../../sw"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
fails=0

ba () {  # ba <obj> <suffix> <cc> <extra...>
  local o="$1"; shift; local x="$1"; shift; local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_add_s8="add_$x" -Dpint_add_exact="pae_$x" -Dpint_add_table="pat_$x" \
      -Dpint_add_lin="pal_$x" -Dpint_add_lin_mark="palm_$x" -Dpint_add_c="pac_$x" \
      "$@" -c "$KA" -o "$w/$o.o"
}
br () {
  local o="$1"; shift; local x="$1"; shift; local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_rope_s8="rope_$x" -Dpint_rope_exact="pre_$x" \
      -Dpint_rope_pass_exact="prpe_$x" -Dpint_rope_pairs="prp_$x" \
      -Dpint_rope_clamp="prc_$x" -Dpint_abs64="pab_$x" -Drope_e="re_$x" \
      -Dpint_rope_apply="pra_$x" -Dpint_rope_pass="prps_$x" \
      -Dpint_rope_build="prb_$x" \
      "$@" -c "$KR" -o "$w/$o.o"
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
  tag="O2"; [ "$CC" != "gcc -O2" ] && tag="SAN"
  ba "a_$tag" a "$CC" -DMBP_B74=1
  ba "b_$tag" b "$CC"
  ba "p1_$tag" a "$CC" -DMBP_B74=1 -DMBP_B74_POISON=1
  # each poisoned arm reuses a's symbol names, so it is linked into its own binary.
  $CC -Wall $INC "$here/b63_add_gate.c" "$w/a_$tag.o" "$w/b_$tag.o" -lm -o "$w/add_$tag"
  $CC -Wall $INC "$here/b63_add_gate.c" "$w/p1_$tag.o" "$w/b_$tag.o" -lm -o "$w/addp1_$tag"
  run "add_s8 $tag  treatment vs ship" pass "$w/add_$tag"
  run "add_s8 $tag  POISON 1 (linear marking loop)" fail "$w/addp1_$tag"

  br "ra_$tag" a "$CC" -DMBP_B74=1
  br "rb_$tag" b "$CC"
  $CC -Wall $INC "$here/b63_rope_gate.c" "$w/ra_$tag.o" "$w/rb_$tag.o" -lm -o "$w/rope_$tag"
  run "rope_s8 $tag  treatment vs ship" pass "$w/rope_$tag"
  for lvl in 2 3 4; do
    br "rp${lvl}_$tag" a "$CC" -DMBP_B74=1 -DMBP_B74_POISON=$lvl
    $CC -Wall $INC "$here/b63_rope_gate.c" "$w/rp${lvl}_$tag.o" "$w/rb_$tag.o" -lm \
        -o "$w/ropep${lvl}_$tag"
    run "rope_s8 $tag  POISON $lvl" fail "$w/ropep${lvl}_$tag"
  done
done

if [ "$fails" = 0 ]; then
  echo "B74 GATE PASSED: both treatments byte-identical to the shipping kernels, and both"
  echo "new routes proved live by a poisoned arm that the same gate rejects."
else
  echo "B74 GATE FAILED: $fails checks did not do what they must"
fi
exit "$fails"
