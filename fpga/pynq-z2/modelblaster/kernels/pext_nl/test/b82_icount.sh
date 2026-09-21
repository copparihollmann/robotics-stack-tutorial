#!/usr/bin/env bash
# B82 -- the instruction account for the "K a multiple of 8" route in matmul_b_s8, fitted
# against N and against K on spike at the board`s own flags.  Host only: no board, no lock.
# See b82_icount_main.c and B82_BAND.md section 0.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
source "$root/env.sh" >/dev/null 2>&1 || true
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
command -v "${CROSS}gcc" >/dev/null 2>&1 || \
  CROSS="$root/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-"
SPIKE="${TACIT_SPIKE:-$root/third_party/riscv-isa-sim/build/spike}"
KD="$root/fpga/pynq-z2/modelblaster/kernels/pext_nl"
SW="$root/fpga/pynq-z2/sw"
IC="$root/fpga/pynq-z2/modelblaster/check/icount"
SHIM="$root/fpga/pynq-z2/modelblaster/check/shim"
# the board's own kernel_cflags for b80_dec_int6_b76, minus the ones that mean nothing
# to a pext_nl kernel (MBXR_* are the engine runtime's)
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections -falign-loops=4
    -I"$SW" -I"$SHIM" -DMB_PEXT_HW=1 -DMBP_B76=1)
w="${B82_OUT:-$(mktemp -d)}"; mkdir -p "$w"
K="$KD/pext_nl_matmul_b_s8_pext_dot8_exact.c"

kb () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_matmul_b_s8="$s" -Dpmmb_rows_a="pra_$o" \
      -Dpmmb_rows_b="prb_$o" -Dpmmb_exact="pex_$o" -Dpmmb_nest_fast_clip8="pnf_$o" \
      -Dpmmb_m1_one="p1o_$o" -Dpmmb_m1_oob="p1b_$o" -Dpmmb_m1_pad0="pp0_$o" \
      -Dpmmb_m1_padp="ppp_$o" -Dpmmb_m1_rows="prw_$o" -Dpmmb_m1_cols="pcl_$o" \
      "$@" -c "$K" -o "$w/$o.o"
  "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"; }

kb ship mmb_ship
kb unr  mmb_unr  -DMBP_MMB_M1_UNROLL8=1

"${CROSS}gcc" "${CF[@]}" -c "$here/b82_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o "$w"/ship.o "$w"/unr.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b82.elf" -lgcc
"$SPIKE" "$w/b82.elf" 2>&1 | tee "$w/b82.txt" | grep -c "MB_B82" >/dev/null
echo "workdir: $w"
