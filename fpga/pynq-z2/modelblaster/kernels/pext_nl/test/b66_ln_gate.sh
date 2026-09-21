#!/usr/bin/env bash
# B66's pre-board gate for pext_nl_layernorm_s8_pext_int_rsqrt.c -- host only, no board,
# no simulator.  Builds the ONE kernel source two ways into one binary and compares them
# BYTE FOR BYTE:
#   a  shipped default   (B66: the hoist guard tests M as well as K; int64 product)
#   b  -DMBP_LN_B66=0     (the SHIPPING kernel: guard on K alone; __int128 product)
# Both halves of the change are pure restructurings -- at M = 1 the arms take DIFFERENT
# paths through the kernel and must still agree byte for byte -- so there is no tolerance.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="$here/../pext_nl_layernorm_s8_pext_int_rsqrt.c"
INC="-I$here/../../../../sw"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
build () {   # build <object> <symbol suffix> <cc> <extra cflags...>
  local o="$1"; shift
  local x="$1"; shift
  local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_layernorm_s8="ln_$x" -Dnlk_f2mss="nf_$x" -Dnlk_msmul="nm_$x" \
      "$@" -c "$K" -o "$w/$o.o"
  # int_nonlin.c defines non-static globals (int_rsqrt_q31 and friends) and all three
  # arms include it, so the three objects would collide at link.  Keep ONE global symbol
  # per object -- the renamed kernel entry point -- and localise the rest.  This is
  # exact rather than --allow-multiple-definition, which would silently pick one copy.
  objcopy --keep-global-symbol="ln_$x" "$w/$o.o"
}
build a a "gcc -O2"
build b b "gcc -O2" -DMBP_LN_B66=0
gcc -O2 -Wall $INC "$here/b66_ln_gate.c" "$w"/a.o "$w"/b.o -lm -o "$w/gate"
"$w/gate"

echo
echo "--- the same three arms under ASan + UBSan, exact-sized allocations ---"
SAN="gcc -O1 -g -fsanitize=address,undefined"
build as a "$SAN"
build bs b "$SAN" -DMBP_LN_B66=0
$SAN -Wall $INC "$here/b66_ln_gate.c" "$w"/as.o "$w"/bs.o -lm -o "$w/gate_san"
"$w/gate_san"
