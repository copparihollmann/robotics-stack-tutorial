#!/usr/bin/env bash
# B76 -- the instruction accounts, the splits and the FLOORS for the decoder's four hart-0
# elementwise kernels, measured on spike with the board's own compiler and flags.  Host
# only: no board, no bitstream, no lock.  See b76_icount_main.c for what is counted.
#
# The board's own kernel_cflags, copied from out/b73_dec_ship/run.json:
#   -DMB_PEXT_HW=1 -DMBXR_LUT_LANE=0 -falign-loops=4 -DMBXR_RT_CAP=4 -DMBXR_RT_PLACE_EARLY=1
# of which only the first two matter to a pext_nl kernel; MB_PEXT_HW=1 means the REAL
# custom-0 encodings, which this spike implements (patches/0006-spike-mbp-pext-insns), so
# mb_pext_clip8 costs one instruction here exactly as it does on the board.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
# shellcheck disable=SC1091
source "$root/env.sh" >/dev/null 2>&1 || true
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
command -v "${CROSS}gcc" >/dev/null 2>&1 || \
  CROSS="$root/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-"
SPIKE="${TACIT_SPIKE:-$root/third_party/riscv-isa-sim/build/spike}"
KD="$here/.."
KT1="$root/fpga/pynq-z2/modelblaster/kernels_t1/pext_nl"
SW="$root/fpga/pynq-z2/sw"
IC="$root/fpga/pynq-z2/modelblaster/check/icount"
SHIM="$root/fpga/pynq-z2/modelblaster/check/shim"
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections -falign-loops=4
    -I"$SW" -I"$SHIM" -I"$here" -DMB_PEXT_HW=1)
w="${B76_ICOUNT_OUT:-$(mktemp -d)}"; mkdir -p "$w"

KP="$KT1/pext_nl_permute4_s8_pext_block.c"
KM="$KD/pext_nl_mul_s8_pext_int_mul.c"
KL="$KD/pext_nl_layernorm_s8_pext_int_rsqrt.c"
KS="$KD/pext_nl_softmax_s8_pext_int_memo2.c"

kp () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_permute4_s8="$s" -Dpblk_nest="pn_$o" \
      -Dpblk_copy="pc_$o" -Dpblk_runs="pr_$o" -Dpblk_runs_w="prw_$o" \
      -Dpblk_tblock="pt_$o" -Dpblk_stride="ps_$o" -Dpblk_align="pa_$o" \
      -Dpblk_mode="pm_$o" "$@" -c "$KP" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$s" "$w/$o.o"; }
km () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_mul_s8="$s" -Dpint_mul_exact="pme_$o" \
      "$@" -c "$KM" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$s" "$w/$o.o"; }
kl () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_layernorm_s8="$s" -Dnlk_f2mss="nf_$o" \
      -Dnlk_msmul="nm_$o" -Dln_scale="lsc_$o" -Dln_q8_full="lq_$o" \
      "$@" -c "$KL" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$s" "$w/$o.o"; }
ks () { local o="$1"; shift; local s="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_softmax_s8="$s" -Dsmx2_out="so_$o" \
      -Dsmx2_ex="sx_$o" -Dsmx2_rows="sr_$o" -Dsmx_scale="ssc_$o" \
      -Dmb_smx2_stats="st_$o" -Dmb_smx2_stats_t="stt_$o" "$@" -c "$KS" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$s" "$w/$o.o"; }

kp pship perm_ship
kp pb76  perm_b76  -DMBP_B76=1
km mship mul_ship
km mb76  mul_b76   -DMBP_B76=1
kl lship ln_ship
kl lb76  ln_b76    -DMBP_B76=1
ks sship smx_ship
ks sb76  smx_b76   -DMBP_B76=1
ks seag  smx_eager -DMBP_B76=1 -DMBP_B76_SMX_MINN=0
ks slaz  smx_lazy  -DMBP_B76=1 -DMBP_B76_SMX_MINN=1000000000

"${CROSS}gcc" "${CF[@]}" -c "$here/b76_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o \
  "$w"/pship.o "$w"/pb76.o "$w"/mship.o "$w"/mb76.o "$w"/lship.o "$w"/lb76.o \
  "$w"/sship.o "$w"/sb76.o "$w"/seag.o "$w"/slaz.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b76.elf" -lgcc

# The disassembly half: the very objects measured above, not a different build.
for o in pship pb76 mship mb76 lship lb76 sship sb76; do
  "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"
done

echo "--- inner loops, counted off the measured objects themselves ---"
python3 - "$w"/pship.dis "$w"/pb76.dis "$w"/mship.dis "$w"/mb76.dis \
           "$w"/lship.dis "$w"/lb76.dis <<'PYEOF'
import re, sys
pat = re.compile(r'^\s*([0-9a-f]+):\s+[0-9a-f ]+\t\s*(\S+)\s*(.*)$')
for path in sys.argv[1:]:
    rows = []
    for l in open(path):
        m = pat.match(l)
        if m:
            rows.append((int(m.group(1), 16), m.group(2), m.group(3)))
    addr = {a: i for i, (a, o, r) in enumerate(rows)}
    print("== %s   (%d instructions in the object)" % (path.split('/')[-1], len(rows)))
    for i, (a, op, rest) in enumerate(rows):
        if op[0] not in 'bj':
            continue
        m2 = re.search(r'\b([0-9a-f]+)\s*<', rest)
        if not m2:
            continue
        ta = int(m2.group(1), 16)
        if ta < a and ta in addr:
            n = i - addr[ta] + 1
            if n <= 40:
                print("   backedge %x -> %x : %2d instructions in the body   [%s %s]"
                      % (a, ta, n, op, rest.split('<')[0].strip()))
PYEOF

echo
"$SPIKE" "$w/b76.elf" 2>&1 | tee "$w/b76_icount.txt" | grep -E "MB_B76"
echo "raw: $w/b76_icount.txt"
echo "workdir: $w"
