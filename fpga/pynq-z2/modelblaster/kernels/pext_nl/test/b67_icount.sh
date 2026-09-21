#!/usr/bin/env bash
# B67 -- cat2_c1_s8's three-way split and the integer builder's crossover, measured on
# spike with the board's own compiler and flags.  Host only: no board, no bitstream, no
# lock.  See b67_icount_main.c for what is counted and why an instruction crossover is a
# conservative bound on a cycle crossover.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
# shellcheck disable=SC1091
source "$root/env.sh" >/dev/null 2>&1 || true
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
SPIKE="${TACIT_SPIKE:-$root/third_party/riscv-isa-sim/build/spike}"
KD="$here/.."
SW="$root/fpga/pynq-z2/sw"
IC="$root/fpga/pynq-z2/modelblaster/check/icount"
SHIM="$root/fpga/pynq-z2/modelblaster/check/shim"
# The board image's own flags (fpga/pynq-z2/docs/MODELBLASTER_ON_ROCKET.md).
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections
    -I"$SW" -I"$SHIM" -I"$here" -DMB_PEXT_HW=0)
w="${B67_ICOUNT_OUT:-$(mktemp -d)}"; mkdir -p "$w"

K="$KD/pext_nl_cat2_c1_s8_pext_memo_lut.c"
k () {  # k <obj> <exported symbol> <extra -D...>
  local o="$1"; shift; local sym="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_cat2_c1_s8="$sym" "$@" -c "$K" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$sym" "$w/$o.o"
}
k ship cat2_ship -DMBP_CAT2_B67=0
k new  cat2_new
k cov  cat2_cov  -DMBP_CAT2_MINN=1000000000
k tbl  cat2_tbl  -DMBP_CAT2_MINN=0

"${CROSS}gcc" "${CF[@]}" -c "$here/b67_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o \
  "$w"/ship.o "$w"/new.o "$w"/cov.o "$w"/tbl.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b67.elf" -lgcc

# The disassembly half of the split: the marking and gather inner loops, straight out of
# the object under measurement rather than out of a different build's zephyr.elf.
"${CROSS}objdump" -d "$w/ship.o" > "$w/ship.dis"
echo "disassembly of the shipped arm: $w/ship.dis"

"$SPIKE" "$w/b67.elf" 2>&1 | tee "$w/b67_icount.txt" | grep -E "MB_B67"
echo "raw: $w/b67_icount.txt"
