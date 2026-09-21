#!/usr/bin/env bash
# B66 -- the three crossovers, measured on spike with the board's own compiler and flags.
# Host only: no board, no bitstream, no lock.  See b66_icount_main.c for what is counted
# and for why an instruction crossover is a conservative bound on a cycle crossover.
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
    -I"$SW" -I"$SHIM" -DMB_PEXT_HW=0)
w="${B66_ICOUNT_OUT:-$(mktemp -d)}"; mkdir -p "$w"

k () {  # k <obj> <exported symbol> <source> <extra -D...>
  local o="$1"; shift; local sym="$1"; shift; local src="$1"; shift
  "${CROSS}gcc" "${CF[@]}" "$@" -c "$src" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$sym" "$w/$o.o"
}
G="$KD/pext_nl_groupnorm_s8_pext_int_rsqrt.c"
L="$KD/pext_nl_layernorm_s8_pext_int_rsqrt.c"
A="$KD/pext_nl_add_s8_pext_int_add.c"
k gnlut gn_lut "$G" -Dkernel_groupnorm_s8=gn_lut -Dpgn_f2mss=pf1 -Dpgn_msmul=pm1 -DMBP_GN_MINHW=1
k gnel  gn_el  "$G" -Dkernel_groupnorm_s8=gn_el  -Dpgn_f2mss=pf2 -Dpgn_msmul=pm2 -DMBP_GN_MINHW=2000000000
k lnh   ln_h   "$L" -Dkernel_layernorm_s8=ln_h   -Dnlk_f2mss=nf1 -Dnlk_msmul=nm1 -DMBP_LN_MINM=1
k lnf   ln_f   "$L" -Dkernel_layernorm_s8=ln_f   -Dnlk_f2mss=nf2 -Dnlk_msmul=nm2 -DMBP_LN_MINM=1000000
k lnshp ln_ship "$L" -Dkernel_layernorm_s8=ln_ship -Dnlk_f2mss=nf3 -Dnlk_msmul=nm3 -DMBP_LN_B66=0
k adtab add_tab "$A" -Dkernel_add_s8=add_tab -Dpint_add_exact=pae1 -Dpint_add_table=pat1 -Dpint_add_t1=pt1 -DMBP_ADD_MINN=0
k adnob add_nob "$A" -Dkernel_add_s8=add_nob -Dpint_add_exact=pae2 -Dpint_add_table=pat2 -Dpint_add_t1=pt2 -DMBP_ADD_MINN=1000000000
S="$KD/pext_nl_softmax_s8_pext_int_memo2.c"
M="$KD/pext_nl_mul_s8_pext_int_mul.c"
k smx smx "$S" -Dkernel_softmax_s8=smx -Dsmx2_out=smxo -Dsmx2_ex=smxe -Dmb_smx2_stats=smxstats -Dmb_smx2_stats_t=smxt
k smxs smx_ship "$S" -Dkernel_softmax_s8=smx_ship -Dsmx2_out=smxo4 -Dsmx2_ex=smxe4 -Dmb_smx2_stats=smxstats4 -Dmb_smx2_stats_t=smxt4 -DMBP_SMX_B66=0
k smxe smx_eager "$S" -Dkernel_softmax_s8=smx_eager -Dsmx2_out=smxo2 -Dsmx2_ex=smxe2 -Dmb_smx2_stats=smxstats2 -Dmb_smx2_stats_t=smxt2 -DMBP_SMX_B66=1 -DMBP_SMX_MINN=0
k smxl smx_lazy "$S" -Dkernel_softmax_s8=smx_lazy -Dsmx2_out=smxo3 -Dsmx2_ex=smxe3 -Dmb_smx2_stats=smxstats3 -Dmb_smx2_stats_t=smxt3 -DMBP_SMX_B66=1 -DMBP_SMX_MINN=1000000000
k mul mul_ "$M" -Dkernel_mul_s8=mul_ -Dpint_mul_exact=pme1
k adshp add_ship "$A" -Dkernel_add_s8=add_ship -Dpint_add_exact=pae3 -Dpint_add_table=pat3 -Dpint_add_t1=pt3 -DMBP_ADD_NO_FAST=1

"${CROSS}gcc" "${CF[@]}" -c "$here/b66_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o "$w"/gnlut.o "$w"/gnel.o \
  "$w"/lnh.o "$w"/lnf.o "$w"/lnshp.o "$w"/adtab.o "$w"/adnob.o "$w"/adshp.o "$w"/smx.o "$w"/smxs.o "$w"/smxe.o "$w"/smxl.o "$w"/mul.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b66.elf" -lgcc
"$SPIKE" "$w/b66.elf" 2>&1 | tee "$w/b66_icount.txt" | grep -E "MB_B66"
echo "raw: $w/b66_icount.txt"
