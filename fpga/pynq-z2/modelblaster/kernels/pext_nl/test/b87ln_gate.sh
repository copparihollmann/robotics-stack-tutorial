#!/usr/bin/env bash
# B87LN's pre-board gate.  Host only: no board, no bitstream, no lock.  Four checks.
#   1 VALUE IDENTITY over the decoder's own 456-dispatch sequence plus shape/scale cases
#   2 THE KEY -- three cardinality cases, because a cache's own failure mode is a FALSE HIT
#   3 POISON -- the cached read, which must be rejected; and the hit count, because a
#     byte-perfect route that never fires is worth nothing
#   4 INERTNESS -- with MBP_B87LN unset the kernel must be opcode-identical
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
K="$here/../pext_nl_layernorm_s8_pext_int_rsqrt.c"
INC="-I$root/fpga/pynq-z2/sw -I$here"
w="${B87LN_GATE_OUT:-$(mktemp -d)}"; mkdir -p "$w"
rc=0

build () {  # build <obj> <sym> <cc...> -- <extra -D...>
  local o="$1" sym="$2"; shift 2
  local cc=""; while [ "$1" != "--" ]; do cc="$cc $1"; shift; done; shift
  # shellcheck disable=SC2086
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 -DMBP_B76=1 \
      -Dkernel_layernorm_s8="$sym" -Dnlk_f2mss="f2_$sym" -Dnlk_msmul="ms_$sym" \
      "$@" -c "$K" -o "$w/$o.o"
  objcopy --keep-global-symbol="$sym" \
          --keep-global-symbol=ln_cache_hits --keep-global-symbol=ln_cache_misses "$w/$o.o"
}
arms () {
  local cc=""; while [ "$1" != "--" ]; do cc="$cc $1"; shift; done; shift
  build lnship  ln_ship  $cc -- "$@"
  build lncache ln_cache $cc -- -DMBP_B87LN=1 "$@"
}

echo "=== 1+2  value identity and the key ==="
arms gcc -O2 --
gcc -O2 -Wall $INC "$here/b87ln_gate.c" "$w"/lnship.o "$w"/lncache.o -lm -o "$w/gate"
"$w/gate" || rc=1

echo
echo "=== 3  poison (must be rejected) ==="
arms gcc -O2 -- -DMBP_B87LN_POISON=8
gcc -O2 -Wall $INC "$here/b87ln_gate.c" "$w"/lnship.o "$w"/lncache.o -lm -o "$w/gate_p8"
if "$w/gate_p8" >"$w/p8.txt" 2>&1; then
  echo "  poison 8: NOT REJECTED  <<< GATE IS BLIND TO THE CACHED READ"; rc=1
else
  echo "  poison 8: rejected      ($(grep -o 'mismatches=[0-9]*' "$w/p8.txt" | tail -1))"
fi
# a cache with ONE slot must still be correct, and must hit zero times at a reuse
# distance of twelve -- which is the measurement that says why SITES must be 12.
arms gcc -O2 -- -DMBP_B87LN_SITES=1
gcc -O2 -Wall $INC "$here/b87ln_gate.c" "$w"/lnship.o "$w"/lncache.o -lm -o "$w/gate_s1"
"$w/gate_s1" >"$w/s1.txt" 2>&1 || true
echo "  SITES=1 (reuse distance 12): $(grep -o 'hits=[0-9]* misses=[0-9]*' "$w/s1.txt" | head -1)  -- correctness $(grep -o 'mismatches=[0-9]*' "$w/s1.txt" | tail -1)"

echo
echo "=== 2c  ASan + UBSan ==="
SAN="gcc -O1 -g -fsanitize=address,undefined"
arms $SAN --
$SAN -Wall $INC "$here/b87ln_gate.c" "$w"/lnship.o "$w"/lncache.o -lm -o "$w/gate_san"
"$w/gate_san" 2>&1 | tail -3 || rc=1

echo
INERT_REF="${B87LN_INERT_REF:-HEAD}"
echo "=== 4  inertness (MBP_B87LN unset vs $INERT_REF) ==="
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
command -v "${CROSS}gcc" >/dev/null 2>&1 || \
  CROSS="$root/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-"
CF="-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -ffunction-sections -fdata-sections -falign-loops=4
    -I$root/fpga/pynq-z2/sw -I$root/fpga/pynq-z2/modelblaster/check/shim
    -DMB_PEXT_HW=1 -DMBP_B76=1"
rel="fpga/pynq-z2/modelblaster/kernels/pext_nl/pext_nl_layernorm_s8_pext_int_rsqrt.c"
if git -C "$root" show "$INERT_REF:$rel" > "$w/ref.c" 2>/dev/null; then
  # shellcheck disable=SC2086
  "${CROSS}gcc" $CF -c "$w/ref.c" -o "$w/ref.o"
  # shellcheck disable=SC2086
  "${CROSS}gcc" $CF -c "$K" -o "$w/now.o"
  for n in ref now; do
    "${CROSS}objdump" -d "$w/$n.o" | tail -n +3 | sed 's/^ *[0-9a-f]*://' \
      | sed 's/\t[0-9a-f ]*\t/\t/' > "$w/$n.dis"
  done
  if diff -q "$w/ref.dis" "$w/now.dis" >/dev/null; then
    echo "  PASS - opcode-identical, $(grep -cE $'\t' "$w/ref.dis") instructions in each"
  else
    echo "  FAIL - MBP_B87LN is NOT inert when unset:"; diff "$w/ref.dis" "$w/now.dis" | head -20; rc=1
  fi
else
  echo "  (not in $INERT_REF; skipped)"
fi
echo; echo "workdir: $w"
[ $rc = 0 ] && echo "MB_B87LN_GATE OVERALL PASS" || echo "MB_B87LN_GATE OVERALL FAIL"
exit $rc
