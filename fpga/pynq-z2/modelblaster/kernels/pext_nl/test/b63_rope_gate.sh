#!/usr/bin/env bash
# B63's pre-board gate for pext_nl_rope_s8_pext_int_rot.c -- host only, no board.
#   a  B63 default             (packed per-i entry, slow[] folded into the tie test, CLIP8)
#   b  -DMBP_ROPE_NO_FAST=1    (the shipping kernel)
# A pure restructuring, so the comparison has no tolerance.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="$here/../pext_nl_rope_s8_pext_int_rot.c"
INC="-I$here/../../../../sw"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
build () {   # build <object> <symbol suffix> <cc> <extra cflags...>
  local o="$1"; shift
  local x="$1"; shift
  local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_rope_s8="rope_$x" -Dpint_rope_exact="pre_$x" \
      -Dpint_rope_pass_exact="prpe_$x" -Dpint_rope_pairs="prp_$x" \
      -Dpint_rope_clamp="prc_$x" -Dpint_abs64="pab_$x" -Drope_e="re_$x" \
      "$@" -c "$K" -o "$w/$o.o"
}
build a a "gcc -O2"
build b b "gcc -O2" -DMBP_ROPE_NO_FAST=1
gcc -O2 -Wall $INC "$here/b63_rope_gate.c" "$w"/a.o "$w"/b.o -lm -o "$w/gate"
"$w/gate"

echo
echo "--- the same two arms under ASan + UBSan ---"
SAN="gcc -O1 -g -fsanitize=address,undefined"
build as a "$SAN"
build bs b "$SAN" -DMBP_ROPE_NO_FAST=1
$SAN -Wall $INC "$here/b63_rope_gate.c" "$w"/as.o "$w"/bs.o -lm -o "$w/gate_san"
"$w/gate_san"
