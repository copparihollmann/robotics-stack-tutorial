#!/usr/bin/env bash
# B63's pre-board gate for pext_nl_add_s8_pext_int_add.c -- host only, no board, no simulator.
# Builds the ONE kernel source two ways into one binary and compares them BYTE FOR BYTE:
#   a  B63 default            (fast table builder + marked-fix-up element loop)
#   b  -DMBP_ADD_NO_FAST=1    (the shipping kernel)
# Both halves of the change are pure restructurings, so there is no tolerance.
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
      "$@" -c "$K" -o "$w/$o.o"
}
build a a "gcc -O2"
build b b "gcc -O2" -DMBP_ADD_NO_FAST=1
gcc -O2 -Wall $INC "$here/b63_add_gate.c" "$w"/a.o "$w"/b.o -lm -o "$w/gate"
"$w/gate"

echo
echo "--- the same two arms under ASan + UBSan, exact-sized allocations ---"
SAN="gcc -O1 -g -fsanitize=address,undefined"
build as a "$SAN"
build bs b "$SAN" -DMBP_ADD_NO_FAST=1
$SAN -Wall $INC "$here/b63_add_gate.c" "$w"/as.o "$w"/bs.o -lm -o "$w/gate_san"
"$w/gate_san"
