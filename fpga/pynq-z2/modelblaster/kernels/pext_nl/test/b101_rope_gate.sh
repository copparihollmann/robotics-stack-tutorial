#!/usr/bin/env bash
# B101 -- rope_s8's head-granularity hook: bit-exactness against the PRE-CHANGE file, the
# yield count, and the instruction account.  Host only: no board, no bitstream, no lock.
#
# THE THREE ARMS ARE THREE BUILDS OF THE SAME SOURCE, linked into one program:
#   rope_pre   the file as it was before MBP_B101R existed (git show <base>:<path>)
#   rope_off   today's file at -DMBP_B101R=0   -- what every existing arm links
#   rope_on    today's file at -DMBP_B101R=1   -- with a LIVE hook installed
# and the gate requires pre == off AND pre == on, byte for byte, on every shape.
#
# WHAT WOULD MAKE IT FAIL, stated because a comparator that cannot is not evidence: the
# program flips ONE output byte after each comparison and re-runs it (NEGCTL), so a
# comparator that reports 0 differing on a corrupted buffer fails the gate too.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
# shellcheck disable=SC1091
source "$root/env.sh" >/dev/null 2>&1 || true
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
SPIKE="${TACIT_SPIKE:-$root/third_party/riscv-isa-sim/build/spike}"
KP="$here/.."; SW="$root/fpga/pynq-z2/sw"
IC="$root/fpga/pynq-z2/modelblaster/check/icount"; SHIM="$root/fpga/pynq-z2/modelblaster/check/shim"
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -ffunction-sections -fdata-sections -falign-loops=4
    -I"$SW" -I"$SHIM" -I"$KP" -DMB_PEXT_HW=1 -DMBP_B74=1 -DMBP_B87=1)
w="${B101_ROPE_OUT:-$(mktemp -d)}"; mkdir -p "$w"
PRE="${B101_ROPE_PRE:-}"
if [ -z "$PRE" ]; then
  PRE="$w/rope_pre.c"
  git -C "$root" show "${B101_ROPE_BASE:-af9b7f0}:fpga/pynq-z2/modelblaster/kernels/pext_nl/pext_nl_rope_s8_pext_int_rot.c" > "$PRE"
fi
"${CROSS}gcc" "${CF[@]}" -Dkernel_rope_s8=rope_pre -c "$PRE" -o "$w/pre.o"
"${CROSS}gcc" "${CF[@]}" -Dkernel_rope_s8=rope_off -DMBP_B101R=0 -c "$KP/pext_nl_rope_s8_pext_int_rot.c" -o "$w/off.o"
"${CROSS}gcc" "${CF[@]}" -Dkernel_rope_s8=rope_on  -DMBP_B101R=1 -c "$KP/pext_nl_rope_s8_pext_int_rot.c" -o "$w/on.o"
"${CROSS}gcc" "${CF[@]}" -c "$here/b101_rope_gate.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o "$w"/pre.o "$w"/off.o "$w"/on.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static -T "$IC/link.ld" -o "$w/gate.elf" -lgcc
out="$("$SPIKE" "$w/gate.elf" 2>&1)"; echo "$out"
bad=0
if echo "$out" | grep -q 'pre_vs_off_differing=[^0]'; then echo "FAIL: OFF arm differs from pre-change"; bad=1; fi
if echo "$out" | grep -q 'pre_vs_ON_differing=[^0]';  then echo "FAIL: ON arm differs from pre-change";  bad=1; fi
# The comparator must be able to SEE a difference, or "0 differing" proves nothing.
if echo "$out" | grep -q 'NEGCTL_one_byte_flipped_differing=0'; then echo "FAIL: comparator is blind"; bad=1; fi
if ! echo "$out" | grep -q 'NEGCTL_one_byte_flipped_differing=1'; then echo "FAIL: no NEGCTL line"; bad=1; fi
for s in ENC_T165_H8_D36_R32 DEC_T1_H8_D36_R32 ENC_clamped; do
  ln=$(echo "$out" | grep -m1 "^$s .*yields=" || true)
  [ -n "$ln" ] || { echo "FAIL: $s produced no yields line"; bad=1; continue; }
  y=${ln##*yields=}; y=${y%% *}
  e=${ln##*expected=}; e=${e%% *}
  if [ "$y" != "$e" ]; then echo "FAIL: $s yields $y != expected $e"; bad=1
  else echo "  $s: $y yields = T*H, head granularity confirmed"; fi
done
[ $bad -eq 0 ] && echo "B101_ROPE_GATE_OK" || { echo "B101_ROPE_GATE_FAILED"; exit 1; }
