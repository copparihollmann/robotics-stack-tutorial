#!/usr/bin/env bash
# B68's pre-board gate for the unrolled DOT8 word loop in pmmb_m1_rows
# (pext_nl_matmul_b_s8_pext_dot8_exact.c) -- host only, no board, no simulator.
#
# This gate compares EXACTLY THE TWO BOARD ARMS, plus the general nest as an
# independent third opinion, over the same 5,334 shapes B59's gate uses:
#
#   a  B68 default                                  the rolled loop -- WHAT SHIPS
#   b  -DMBP_MMB_M1_UNROLL8=1                       the 1/2/4 cascade + unroll-by-8
#   c  -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1  the general nest, the reference
#
# The unroll SHIPS OFF -- B68 measured it at -10.9 % on the op and +0.019 % on decoder
# steady, because 98.4 % of the saving went back to the engine (MATMUL_B_COST.md section
# 32.4).  It is gated anyway: it is still buildable, and a configuration that is not
# fill-bound would collect it.
#
# BYTE FOR BYTE, no tolerance.  The identity being checked is not associativity:
# the cascade head takes words 0..r-1 and the unrolled loop r..T-1, so `acc`
# receives the same int64 addends in the same order as the rolled loop.  If that
# is true the outputs cannot differ at all, and a difference of one LSB would
# mean the reasoning is wrong somewhere -- which is why there is no epsilon here.
#
# b59_matmul_b_m1_gate.sh still runs the ASan+UBSan bounds program; the unroll
# reads exactly the words the rolled loop read (t = 0..T-1) and adds no new
# addresses, so that gate's argument carries over unchanged -- run it too.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="$here/../pext_nl_matmul_b_s8_pext_dot8_exact.c"
INC="-I$here/../../../../sw"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
build () {   # build <suffix> <extra cflags...>
  local o="$1"; shift
  gcc -O2 -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 \
      -Dkernel_matmul_b_s8="mmb_$o" -Dpmmb_rows_a="pra_$o" -Dpmmb_rows_b="prb_$o" \
      "$@" -c "$K" -o "$w/$o.o"
}
build a
build b -DMBP_MMB_M1_UNROLL8=1
build c -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1
gcc -O2 -Wall $INC "$here/b59_matmul_b_m1_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o -o "$w/gate"
"$w/gate"

san () { gcc -O1 -g -fsanitize=address,undefined $INC -DMB_PEXT_HW=0 \
           -Dkernel_matmul_b_s8="mmb_$1" -Dpmmb_rows_a="pra_$1" -Dpmmb_rows_b="prb_$1" \
           "${@:2}" -c "$K" -o "$w/$1s.o"; }
san a
san b -DMBP_MMB_M1_UNROLL8=1
san c -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1
gcc -O1 -g -fsanitize=address,undefined $INC "$here/b59_matmul_b_m1_gate.c" \
    "$w"/as.o "$w"/bs.o "$w"/cs.o -o "$w/gate_san"
"$w/gate_san"
gcc -O1 -g -fsanitize=address,undefined $INC "$here/b59_matmul_b_m1_bounds.c" \
    "$w"/as.o "$w"/cs.o -o "$w/bounds"
"$w/bounds"
