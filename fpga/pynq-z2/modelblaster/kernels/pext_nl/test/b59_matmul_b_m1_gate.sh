#!/usr/bin/env bash
# B59's pre-board gate for the M=1 specialisation in
# pext_nl_matmul_b_s8_pext_dot8_exact.c -- host only, no board, no simulator.
#
# Compiles the ONE kernel source three ways into one binary and compares them BYTE FOR BYTE:
#   a  B59 default                                  (the M=1 paths)
#   b  -DMBP_MMB_NO_M1=1                            (the shipping kernel, B52's hoisted nest)
#   c  -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1  (the general nest, the reference)
# A tolerance would hide exactly the kind of mistake a specialisation makes, so there is none.
#
# Two programs, because they catch different things:
#   b59_matmul_b_m1_gate.c    correctness over 5,334 shapes, big allocations
#   b59_matmul_b_m1_bounds.c  EXACT-SIZED allocations under ASan+UBSan over 38,400 small
#                             shapes -- the aligned-window read must never leave the tensor.
#                             This is what caught the first version: at K < 8 several rows
#                             share one aligned word, so the out-of-tensor prefix is not one row.
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
build b -DMBP_MMB_NO_M1=1
build c -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1
gcc -O2 -Wall $INC "$here/b59_matmul_b_m1_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o -o "$w/gate"
"$w/gate"

san () { gcc -O1 -g -fsanitize=address,undefined $INC -DMB_PEXT_HW=0 \
           -Dkernel_matmul_b_s8="mmb_$1" -Dpmmb_rows_a="pra_$1" -Dpmmb_rows_b="prb_$1" \
           "${@:2}" -c "$K" -o "$w/$1s.o"; }
san a
san b -DMBP_MMB_NO_M1=1
san c -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1
gcc -O1 -g -fsanitize=address,undefined $INC "$here/b59_matmul_b_m1_gate.c" \
    "$w"/as.o "$w"/bs.o "$w"/cs.o -o "$w/gate_san"
"$w/gate_san"
gcc -O1 -g -fsanitize=address,undefined $INC "$here/b59_matmul_b_m1_bounds.c" \
    "$w"/as.o "$w"/cs.o -o "$w/bounds"
"$w/bounds"
