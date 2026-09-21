#!/usr/bin/env bash
# B73's pre-board gate for kernels/roccmoon/roccmoon_cat2_c1_s8_roccmoon_lut.c -- host only,
# no board, no simulator.  TWO CHECKS, and they answer different questions.
#
# (1) THE TRANSCRIPTION.  The lane kernel's table builder is a BYTE-FOR-BYTE COPY of B67's,
#     taken out of kernels/pext_nl/pext_nl_cat2_c1_s8_pext_memo_lut.c.  gelu_s8's lane kernel
#     can CALL its curated builder because int_gelu_s8_table is extern; cat2's pcat_build is
#     static, so a copy is the only route -- and a copy nobody diffs is a copy that drifts.
#     This re-extracts the block from `#ifndef MBP_CAT2_B67` through its matching `#endif` in
#     both files and refuses if they differ by one byte.
#
# (2) THE ARITHMETIC.  The same harness B67 used (b67_cat2_gate.c), with the LANE kernel as the
#     arm under test and the PRE-B67 curated kernel (-DMBP_CAT2_B67=0) as the golden -- the
#     reference expression, term for term.  The bar is BYTE IDENTITY over the model's own 274
#     (scale0, scale1, scale_out, amin, amax) tuples x all 256 input bytes through both inputs,
#     plus the adversarial phases the harness adds.  Arm `cov` forces the per-element route at
#     every shape, because on the model MBP_CAT2_MINN = 176 and the smallest side is 288, so
#     that route never runs and a gate without it would exercise nothing while passing.
#
# WHAT THIS GATE CANNOT SEE, stated so nobody reads more into it.  On the host,
# mbxr_lut_map_op's `#if defined(__ZEPHYR__)` is false, so every side takes the SCALAR
# fallback.  This gate proves the builder and the fallback gather; the LANE itself is proven on
# the board by max_abs_err 0 WITH lut_fallback = 0 and lut_els_lane at its expected value.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUR="$here/../pext_nl_cat2_c1_s8_pext_memo_lut.c"
LANE="$here/../../roccmoon/roccmoon_cat2_c1_s8_roccmoon_lut.c"
INC="-I$here/../../../../sw -I$here"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT

extract () {   # the builder block, verbatim
  python3 - "$1" <<'PY'
import sys
t = open(sys.argv[1]).read()
a = t.index("\n#ifndef MBP_CAT2_B67") + 1   # at a line start: the header comment names it too
b = t.index("#endif /* MBP_CAT2_B67 */") + len("#endif /* MBP_CAT2_B67 */")
sys.stdout.write(t[a:b])
PY
}
extract "$CUR"  > "$w/cur.block"
extract "$LANE" > "$w/lane.block"
if ! diff -u "$w/cur.block" "$w/lane.block" > "$w/block.diff"; then
  echo "B73 GATE REFUSES: the lane kernel's builder block is no longer the curated kernel's."
  head -40 "$w/block.diff"
  exit 1
fi
echo "transcription: the builder block is byte-identical in both files ($(wc -c < "$w/cur.block") bytes)"
echo

build () {   # build <object> <symbol suffix> <stats prefix> <source> <cc> <extra cflags...>
  local o="$1"; shift
  local x="$1"; shift
  local p="$1"; shift
  local src="$1"; shift
  local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 -DFX_STATS \
      -Dkernel_cat2_c1_s8="cat2_$x" -Dmbxr_lut_stats="mbxr_lut_stats_$x" \
      -Dpcat_slow_count="${p}_slow" -Dpcat_entry_count="${p}_entries" \
      -Dpcat_sat_count="${p}_sat" -Dpcat_slowside_count="${p}_slowside" \
      -Dpcat_tbl_sides="${p}_tbl_sides" -Dpcat_el_sides="${p}_el_sides" \
      "$@" -c "$src" -o "$w/$o.o"
}
run_arms () {   # run_arms <tag> <cc>
  local tag="$1"; shift
  local cc="$1"; shift
  build a new n "$LANE" "$cc"
  build b ship s "$CUR"  "$cc" -DMBP_CAT2_B67=0
  build c cov c "$LANE" "$cc" -DMBP_CAT2_MINN=1000000000
  $cc -Wall $INC "$here/b67_cat2_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o -lm -o "$w/gate_$tag"
  "$w/gate_$tag"
}
run_arms plain "gcc -O2 -ffp-contract=off"
echo
echo "--- the same three arms under ASan + UBSan ---"
run_arms san "gcc -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -ffp-contract=off"
