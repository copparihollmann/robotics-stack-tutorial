#!/usr/bin/env bash
# B67's pre-board gate for pext_nl_cat2_c1_s8_pext_memo_lut.c -- host only, no board, no
# simulator.  Builds the ONE kernel source three ways into one binary and compares them
# BYTE FOR BYTE:
#   ship  -DMBP_CAT2_B67=0                 the pre-B67 kernel: float builder + seen[]
#   new   (defaults)                       B67: integer builder, all 256, no marking
#   cov   -DMBP_CAT2_MINN=1000000000       the coverage arm: per-element route at EVERY
#                                          shape, including the ones the shipped guard
#                                          sends to the table and the model never reaches
# The B67 builder claims the reference's own answer, so there is no tolerance.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="$here/../pext_nl_cat2_c1_s8_pext_memo_lut.c"
INC="-I$here/../../../../sw -I$here"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
build () {   # build <object> <symbol suffix> <stats prefix> <cc> <extra cflags...>
  local o="$1"; shift
  local x="$1"; shift
  local p="$1"; shift
  local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 -DFX_STATS \
      -Dkernel_cat2_c1_s8="cat2_$x" \
      -Dpcat_slow_count="${p}_slow" -Dpcat_entry_count="${p}_entries" \
      -Dpcat_sat_count="${p}_sat" -Dpcat_slowside_count="${p}_slowside" \
      -Dpcat_tbl_sides="${p}_tbl_sides" -Dpcat_el_sides="${p}_el_sides" \
      "$@" -c "$K" -o "$w/$o.o"
}
build a new n "gcc -O2 -ffp-contract=off"
build b ship s "gcc -O2 -ffp-contract=off" -DMBP_CAT2_B67=0
build c cov c "gcc -O2 -ffp-contract=off" -DMBP_CAT2_MINN=1000000000
gcc -O2 -Wall $INC "$here/b67_cat2_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o -lm -o "$w/gate"
"$w/gate"

echo
echo "--- the same three arms under ASan + UBSan ---"
SAN="gcc -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -ffp-contract=off"
build as new n "$SAN"
build bs ship s "$SAN" -DMBP_CAT2_B67=0
build cs cov c "$SAN" -DMBP_CAT2_MINN=1000000000
$SAN -Wall $INC "$here/b67_cat2_gate.c" "$w"/as.o "$w"/bs.o "$w"/cs.o -lm -o "$w/gate_san"
"$w/gate_san"
