#!/usr/bin/env bash
# B66's pre-board gate for pext_nl_add_s8_pext_int_add.c -- host only, no board, no
# simulator.  Builds the ONE kernel source three ways into one binary and compares them
# BYTE FOR BYTE:
#   a  shipped default             (B66: no table below MBP_ADD_MINN)
#   b  -DMBP_ADD_MINN=0            (B63 as landed: always build -- the SHIPPING kernel)
#   c  -DMBP_ADD_MINN=1000000000   (no table at any n the regime admits: the coverage arm)
# The no-build route computes the same value the table entry would have held, so there is
# no tolerance.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="$here/../pext_nl_add_s8_pext_int_add.c"
INC="-I$here/../../../../sw"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
build () {   # build <object> <symbol suffix> <cc> <extra cflags...>
  local o="$1"; shift
  local x="$1"; shift
  local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_add_s8="add_$x" -Dpint_add_exact="pae_$x" -Dpint_add_table="pat_$x" \
      -Dpint_add_t1="pt1_$x" \
      "$@" -c "$K" -o "$w/$o.o"
}
build a a "gcc -O2"
build b b "gcc -O2" -DMBP_ADD_MINN=0
build c c "gcc -O2" -DMBP_ADD_MINN=1000000000
gcc -O2 -Wall $INC "$here/b66_add_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o -lm -o "$w/gate"
"$w/gate"

echo
echo "--- the same three arms under ASan + UBSan, exact-sized allocations ---"
SAN="gcc -O1 -g -fsanitize=address,undefined"
build as a "$SAN"
build bs b "$SAN" -DMBP_ADD_MINN=0
build cs c "$SAN" -DMBP_ADD_MINN=1000000000
$SAN -Wall $INC "$here/b66_add_gate.c" "$w"/as.o "$w"/bs.o "$w"/cs.o -lm -o "$w/gate_san"
"$w/gate_san"
