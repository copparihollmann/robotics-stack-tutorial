#!/usr/bin/env bash
# B86 -- permute4_s8 at the ENCODER's three shapes: the instruction account, the per-MODE
# split, and a byte-for-byte equivalence gate.  Host only: no board, no bitstream, no lock.
#
# The encoder's own kernel_cflags, copied from out/b81_enc_f40/run.json:
#   -DMB_PEXT_HW=1 -DMBXR_RT_LUT=1 -falign-loops=4 -DMBXR_RT_DRAIN_STRIDED=1
#   -DMBXR_RT_STAGE_BLOCK=1 -DMBP_B74=1 -DMBXR_RT_CAP=4 -DMBXR_RT_PLACE_EARLY=1
# of which only -DMB_PEXT_HW=1 and -falign-loops=4 reach a pext_nl kernel (the MBXR_RT_*
# are runtime/engine defines and MBP_B74 gates add_s8/rope_s8, not permute4_s8) -- the same
# two b76_icount.sh used, so the two labs' instruction counts are directly comparable.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
# shellcheck disable=SC1091
source "$root/env.sh" >/dev/null 2>&1 || true
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
command -v "${CROSS}gcc" >/dev/null 2>&1 || \
  CROSS="$root/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-"
SPIKE="${TACIT_SPIKE:-$root/third_party/riscv-isa-sim/build/spike}"
KT1="$root/fpga/pynq-z2/modelblaster/kernels_t1/pext_nl"
SW="$root/fpga/pynq-z2/sw"
IC="$root/fpga/pynq-z2/modelblaster/check/icount"
SHIM="$root/fpga/pynq-z2/modelblaster/check/shim"
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections -falign-loops=4
    -I"$SW" -I"$SHIM" -I"$here" -DMB_PEXT_HW=1)
w="${B86_ICOUNT_OUT:-$(mktemp -d)}"; mkdir -p "$w"

KP="$KT1/pext_nl_permute4_s8_pext_block.c"

kp () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_permute4_s8="$s" -Dpblk_nest="pn_$o" \
      -Dpblk_copy="pc_$o" -Dpblk_runs="pr_$o" -Dpblk_runs_w="prw_$o" \
      -Dpblk_tblock="pt_$o" -Dpblk_stride="ps_$o" -Dpblk_align="pa_$o" \
      -Dpblk_mode="pm_$o" "$@" -c "$KP" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$s" "$w/$o.o"; }

kp pship perm_ship
kp pb76  perm_b76  -DMBP_B76=1

"${CROSS}gcc" "${CF[@]}" -c "$here/b86_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o "$w"/pship.o "$w"/pb76.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b86.elf" -lgcc

for o in pship pb76; do "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"; done

echo "--- spike, retired instructions at the encoder's shapes ---"
"$SPIKE" "$w/b86.elf" 2>&1 | tee "$w/b86_icount.txt" | grep -E "MB_B86" || true

echo
echo "--- the account, against the encoder's own board cycles (out/b81_enc_f40) ---"
python3 - "$w/b86_icount.txt" <<'PYEOF'
import re, sys
# board cycles / elements per shape index, from out/b81_enc_f40/enc_q16/console.txt
board = {0: (711984, 47520, 1), 1: (5641758, 855360, 18), 2: (1737634, 285120, 6)}
name  = {0: "TBLOCK 1x od=(1,1,165,288)", 1: "RUNS   18x od=(1,8,165,36)",
         2: "RUNS    6x od=(1,165,8,36)"}
rows = {}
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"MB_B86 op=permute4_s8 arm=(\w+) shape=(\d+) elems=(\d+) ndisp=(\d+) instret=(\d+)", l)
    if m:
        rows[(m.group(1), int(m.group(2)))] = (int(m.group(3)), int(m.group(4)), int(m.group(5)))
if not rows:
    print("no MB_B86 rows parsed"); sys.exit(1)
print("%-28s %10s %10s %8s %12s %8s %7s" %
      ("shape", "instr/disp", "  b76", " ratio", "board cyc", "cyc/el", "CPI"))
tot_s = tot_b = tot_c = 0
for t in sorted(board):
    els, nd, i_s = rows[("ship", t)]
    _, _, i_b = rows[("b76", t)]
    cyc, tel, ndisp = board[t]
    S, B = i_s * ndisp, i_b * ndisp
    tot_s += S; tot_b += B; tot_c += cyc
    print("%-28s %10d %10d %8.4f %12d %8.3f %7.3f" %
          (name[t], i_s, i_b, i_b / i_s, cyc, cyc / tel, cyc / S))
print("-" * 92)
print("%-28s %10d %10d %8.4f %12d" % ("TOTAL (25 dispatches)", tot_s, tot_b, tot_b / tot_s, tot_c))
print()
print("CPI-neutral projection: %d cyc  (saving %d, %.2f %%)" %
      (tot_c * tot_b / tot_s, tot_c - tot_c * tot_b / tot_s, 100 * (tot_b / tot_s - 1)))
PYEOF
echo
echo "raw: $w/b86_icount.txt"
echo "workdir: $w"
