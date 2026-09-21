#!/usr/bin/env bash
# B66's pre-board gate for pext_nl_groupnorm_s8_pext_int_rsqrt.c -- host only, no board,
# no simulator.  Builds the ONE kernel source three ways into one binary and compares them
# BYTE FOR BYTE:
#   a  shipped default              (guard at MBP_GN_MINHW)
#   b  -DMBP_GN_MINHW=2000000000    (per-element always: the shipping kernel)
#   c  -DMBP_GN_MINHW=1             (table always: the coverage arm)
# The table reproduces the kernel's map on its entire 256-value domain, so there is no
# tolerance -- a single differing byte fails.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="$here/../pext_nl_groupnorm_s8_pext_int_rsqrt.c"
INC="-I$here/../../../../sw"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
build () {   # build <object> <symbol suffix> <cc> <extra cflags...>
  local o="$1"; shift
  local x="$1"; shift
  local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_groupnorm_s8="gn_$x" -Dpgn_f2mss="pf_$x" -Dpgn_msmul="pm_$x" \
      "$@" -c "$K" -o "$w/$o.o"
  # int_nonlin.c defines non-static globals (int_rsqrt_q31 and friends) and all three
  # arms include it, so the three objects would collide at link.  Keep ONE global symbol
  # per object -- the renamed kernel entry point -- and localise the rest.  This is
  # exact rather than --allow-multiple-definition, which would silently pick one copy.
  objcopy --keep-global-symbol="gn_$x" "$w/$o.o"
}
build a a "gcc -O2"
build b b "gcc -O2" -DMBP_GN_MINHW=2000000000
build c c "gcc -O2" -DMBP_GN_MINHW=1
gcc -O2 -Wall $INC "$here/b66_gn_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o -lm -o "$w/gate"
"$w/gate"

echo
echo "--- the same three arms under ASan + UBSan, exact-sized allocations ---"
SAN="gcc -O1 -g -fsanitize=address,undefined"
build as a "$SAN"
build bs b "$SAN" -DMBP_GN_MINHW=2000000000
build cs c "$SAN" -DMBP_GN_MINHW=1
$SAN -Wall $INC "$here/b66_gn_gate.c" "$w"/as.o "$w"/bs.o "$w"/cs.o -lm -o "$w/gate_san"
"$w/gate_san"
