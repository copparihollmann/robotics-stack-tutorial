#!/usr/bin/env bash
# B84 -- the instruction account for the decoder bundle (MBP_B74 on rope_s8 + add_s8, and
# MBP_B84's interchanged pad passes in matmul_b_s8), at the DECODER's own shapes, on spike,
# at the board's own flags.  Host only: no board, no lock.  See b84_icount_main.c.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
# shellcheck disable=SC1091
source "$root/env.sh" >/dev/null 2>&1 || true
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
command -v "${CROSS}gcc" >/dev/null 2>&1 || \
  CROSS="$root/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-"
SPIKE="${TACIT_SPIKE:-$root/third_party/riscv-isa-sim/build/spike}"
KD="$root/fpga/pynq-z2/modelblaster/kernels/pext_nl"
SW="$root/fpga/pynq-z2/sw"
IC="$root/fpga/pynq-z2/modelblaster/check/icount"
SHIM="$root/fpga/pynq-z2/modelblaster/check/shim"
# b80_dec_int6_b76's own kernel_cflags, minus the MBXR_* the engine runtime reads and no
# pext_nl kernel does.  MBP_B76=1 is IN, because it is what the control compiles.
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections -falign-loops=4
    -I"$SW" -I"$SHIM" -DMB_PEXT_HW=1 -DMBP_B76=1)
w="${B84_OUT:-$(mktemp -d)}"; mkdir -p "$w"

M="$KD/pext_nl_matmul_b_s8_pext_dot8_exact.c"
R="$KD/pext_nl_rope_s8_pext_int_rot.c"
Ad="$KD/pext_nl_add_s8_pext_int_add.c"

mb () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_matmul_b_s8="$s" -Dpmmb_rows_a="pra_$o" \
      -Dpmmb_rows_b="prb_$o" -Dpmmb_exact="pex_$o" -Dpmmb_nest_fast_clip8="pnf_$o" \
      -Dpmmb_m1_one="p1o_$o" -Dpmmb_m1_oob="p1b_$o" -Dpmmb_m1_pad0="pp0_$o" \
      -Dpmmb_m1_padp="ppp_$o" -Dpmmb_m1_padall8="pa8_$o" -Dpmmb_m1_rows="prw_$o" \
      -Dpmmb_m1_cols="pcl_$o" "$@" -c "$M" -o "$w/$o.o"
  "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"; }
kr () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_rope_s8="$s" "$@" -c "$R" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$s" "$w/$o.o"
  "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"; }
ka () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_add_s8="$s" "$@" -c "$Ad" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$s" "$w/$o.o"
  "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"; }

mb mship mmb_ship
mb mb84  mmb_b84  -DMBP_B84=1
kr rship rope_ship
kr rb74  rope_b74 -DMBP_B74=1
ka aship add_ship
ka ab74  add_b74  -DMBP_B74=1

"${CROSS}gcc" "${CF[@]}" -c "$here/b84_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o "$w"/mship.o "$w"/mb84.o \
  "$w"/rship.o "$w"/rb74.o "$w"/aship.o "$w"/ab74.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b84.elf" -lgcc
"$SPIKE" "$w/b84.elf" 2>&1 | tee "$w/b84_icount.txt" | grep -E "MB_B84"
echo "workdir: $w"
