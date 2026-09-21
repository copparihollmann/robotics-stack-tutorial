#!/usr/bin/env bash
# B84's pre-board gate for the interchanged phase-pad build in pmmb_m1_rows
# (pext_nl_matmul_b_s8_pext_dot8_exact.c) -- host only, no board, no simulator.
#
# Same shape as b68_matmul_b_unroll_gate.sh, and deliberately the same gate program
# (b59_matmul_b_m1_gate.c), because that program's third block walks EVERY K from 1..80
# at both transposes and EVERY alignment of B's base -- which is exactly the phase set
# 8/gcd(K,8) this change reorders.  The arms are:
#
#   a  B84 default (MBP_B84 unset)                  seven pmmb_m1_padp passes -- WHAT SHIPS
#   b  -DMBP_B84=1                                  one interchanged pass
#   c  -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1  the general nest, the reference
#
# BYTE FOR BYTE, no tolerance.  Destination p receives pmmb_m1_padp's own expression,
# (q0[t] << 8p) | (q0[t-1] >> (64 - 8p)), from the same source words -- nothing is
# reassociated and nothing is rebuilt from a shifted copy -- so a single differing byte
# would mean the reasoning is wrong.
#
# AND THE POISONS MUST FAIL.  B74's lesson (L346 (10)): a poison that is not visible in
# the OUTPUT proves nothing.  MBP_B84_POISON=1 builds phase 7 from the wrong bits of the
# carry word and =2 builds it one byte short; each must be REJECTED by this gate, or the
# gate is not exercising the interchanged builder at all.
#
# Run b68_matmul_b_unroll_gate.sh too: the two changes are independent and both ship
# guarded, and arm B of B84's board pair carries neither.
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
san () {     # san <suffix> <extra cflags...>
  local o="$1"; shift
  gcc -O1 -g -fsanitize=address,undefined $INC -DMB_PEXT_HW=0 \
      -Dkernel_matmul_b_s8="mmb_$o" -Dpmmb_rows_a="pra_$o" -Dpmmb_rows_b="prb_$o" \
      "$@" -c "$K" -o "$w/$o.o"
}

echo "=== 1. the two board arms and the reference nest, -O2 ==="
build a
build b -DMBP_B84=1
build c -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1
gcc -O2 -Wall $INC "$here/b59_matmul_b_m1_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o -o "$w/gate"
"$w/gate"

echo "=== 2. the same three under ASan+UBSan ==="
rm -f "$w"/{a,b,c}.o
san a
san b -DMBP_B84=1
san c -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1
gcc -O1 -g -fsanitize=address,undefined $INC "$here/b59_matmul_b_m1_gate.c" \
    "$w"/a.o "$w"/b.o "$w"/c.o -o "$w/gate_san"
"$w/gate_san"
gcc -O1 -g -fsanitize=address,undefined $INC "$here/b59_matmul_b_m1_bounds.c" \
    "$w"/a.o "$w"/c.o -o "$w/bounds"
"$w/bounds"

echo "=== 3. the coverage arm: each poison must be REJECTED ==="
rc=0
for P in 1 2; do
  rm -f "$w"/{a,b,c}.o
  build a
  build b -DMBP_B84=1 -DMBP_B84_POISON=$P
  build c -DMBP_MMB_NO_M1=1 -DMBP_MMB_NO_SPECIALIZE=1
  gcc -O2 -Wall $INC "$here/b59_matmul_b_m1_gate.c" "$w"/a.o "$w"/b.o "$w"/c.o \
      -o "$w/gate_p$P"
  if out="$("$w/gate_p$P" 2>&1)"; then
    echo "POISON $P WAS NOT CAUGHT -- the gate does not exercise pmmb_m1_padall8"
    echo "$out" | tail -3
    rc=1
  else
    n=$(printf '%s\n' "$out" | sed -n 's/.*failing=\([0-9]*\).*/\1/p' | tail -1)
    echo "poison $P rejected: failing=$n shapes"
  fi
done
[ "$rc" = 0 ] || { echo "B84_GATE verdict=FAIL (a poison survived)"; exit 1; }
echo "B84_GATE verdict=PASS"
