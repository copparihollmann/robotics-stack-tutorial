#!/usr/bin/env bash
# B66's pre-board gate for pext_nl_softmax_s8_pext_int_memo2.c -- host only, no board, no
# simulator.  Builds the ONE kernel source four ways into one binary and compares them
# BYTE FOR BYTE:
#   a  -DMBP_SMX_B66=1                       lazy ex[] below MBP_SMX_MINN
#   b  (default, MBP_SMX_B66=0)              the SHIPPING kernel -- and what still ships
#   c  -DMBP_SMX_MINN=1000000000            lazy always: the coverage arm
# A lazily filled ex[d] is the same expression evaluated on first use, so this is not a
# tolerance and a single differing byte fails.
#
# A SECOND CHANGE WAS PROPOSED HERE AND WITHDRAWN: skipping the per-row d0 bisection at small
# K.  Arm c, run with -DMBP_SMX_MAXK_NOBISECT=100000, refused it -- and the mismatch was a
# PRE-EXISTING soundness bug in the shipping kernel, not in the change.  See the withdrawal
# note in the kernel.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="$here/../pext_nl_softmax_s8_pext_int_memo2.c"
INC="-I$here/../../../../sw"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
build () {   # build <object> <symbol suffix> <cc> <extra cflags...>
  local o="$1"; shift
  local x="$1"; shift
  local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_softmax_s8="smx_$x" -Dsmx2_out="so_$x" -Dsmx2_ex="sx_$x" \
      -Dmb_smx2_stats="st_$x" -Dmb_smx2_stats_t="stt_$x" \
      "$@" -c "$K" -o "$w/$o.o"
  # int_nonlin.c's non-static globals would collide across the three objects; keep one
  # global per object and localise the rest, which is exact where
  # --allow-multiple-definition would silently pick one copy.
  objcopy --keep-global-symbol="smx_$x" "$w/$o.o"
}
build a a "gcc -O2" -DMBP_SMX_B66=1
# arm d is the kernel AS IT STOOD BEFORE B66 touched it, extracted from git into
# b66_smx_prechange.c.inc.  B66 split the fused `ex[k] = ...; stamp[k] = 0;` prologue into
# two loops, which let the compiler widen the stamp zeroing and made the SHIPPED path 0.03
# to 2.85 % cheaper.  That is a change to code that ships with the feature OFF, so it needs
# its own control -- a restructuring nobody asked for is still a restructuring.
buildpre () {
  local o="$1"; shift; local cc="$1"; shift
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_softmax_s8=smx_d -Dsmx2_out=so_d -Dmb_smx2_stats=st_d \
      -Dmb_smx2_stats_t=stt_d "$@" -x c -c "$here/b66_smx_prechange.c.inc" -o "$w/$o.o"
  objcopy --keep-global-symbol=smx_d "$w/$o.o"
}
buildpre d "gcc -O2"
build b b "gcc -O2" -DMBP_SMX_B66=0
build c c "gcc -O2" -DMBP_SMX_B66=1 -DMBP_SMX_MINN=1000000000
gcc -O2 -Wall $INC "$here/b66_smx_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o "$w"/d.o -lm -o "$w/gate"
"$w/gate"

echo
echo "--- the same four arms under ASan + UBSan, exact-sized allocations ---"
SAN="gcc -O1 -g -fsanitize=address,undefined"
build as a "$SAN" -DMBP_SMX_B66=1
buildpre ds "$SAN"
build bs b "$SAN" -DMBP_SMX_B66=0
build cs c "$SAN" -DMBP_SMX_B66=1 -DMBP_SMX_MINN=1000000000
$SAN -Wall $INC "$here/b66_smx_gate.c" "$w"/as.o "$w"/bs.o "$w"/cs.o "$w"/ds.o -lm -o "$w/gate_san"
"$w/gate_san"
