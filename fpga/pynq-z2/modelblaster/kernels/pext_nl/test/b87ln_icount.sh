#!/usr/bin/env bash
# B87's decoder follow-on -- layernorm_s8's instruction account at the DECODER's M = 1,
# measured on spike with the board's own compiler and THE DECODER'S OWN FLAGS.  Host only.
#
# The control arm is the shipped decoder arm: -DMBP_B76=1, which B66's published numbers
# predate.  See b87ln_icount_main.c for why that matters.
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
SW="$root/fpga/pynq-z2/sw"
SHIM="$root/fpga/pynq-z2/modelblaster/check/shim"
IC="$root/fpga/pynq-z2/modelblaster/check/icount"
K="$KD/pext_nl_layernorm_s8_pext_int_rsqrt.c"
# the decoder's own kernel_cflags (out/b83_dec_f41667/dec_q16/kernel_cflags.txt), minus the
# MBXR_RT_* knobs no pext_nl kernel reads
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections -falign-loops=4
    -I"$SW" -I"$SHIM" -I"$here" -DMB_PEXT_HW=1 -DMBP_B76=1)
w="${B87LN_OUT:-$(mktemp -d)}"; mkdir -p "$w"

one () {  # one <obj> <sym> <extra -D...>
  local o="$1" sym="$2"; shift 2
  "${CROSS}gcc" "${CF[@]}" "-Dkernel_layernorm_s8=$sym" \
      -Dnlk_f2mss="f2_$sym" -Dnlk_msmul="ms_$sym" "$@" -c "$K" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$sym" \
      --keep-global-symbol=ln_cache_hits --keep-global-symbol=ln_cache_misses "$w/$o.o"
}
one lnship  ln_ship                       # MBP_LN_MINM = 2 : the shipped decoder path
one lnhoist ln_hoist -DMBP_LN_MINM=1      # the hoist forced on at M = 1
one lncache ln_cache -DMBP_B87LN=1        # the cross-dispatch cache

"${CROSS}gcc" "${CF[@]}" -c "$here/b87ln_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o "$w"/lnship.o "$w"/lnhoist.o "$w"/lncache.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b87ln.elf" -lgcc

for o in lnship lnhoist lncache; do "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"; done
echo "--- inner loops, off the measured objects themselves ---"
python3 - "$w"/lnship.dis "$w"/lnhoist.dis <<'PYEOF'
import re, sys
pat = re.compile(r'^\s*([0-9a-f]+):\s+[0-9a-f ]+\t\s*(\S+)\s*(.*)$')
for path in sys.argv[1:]:
    print("== %s" % path.split('/')[-1]); sec=None; rows=[]
    for l in open(path):
        m3 = re.match(r'^Disassembly of section (\S+):', l)
        if m3: sec = m3.group(1)
        m = pat.match(l)
        if m: rows.append((sec, int(m.group(1),16), m.group(2), m.group(3)))
    addr = {(s,a): i for i,(s,a,o,r) in enumerate(rows)}
    for i,(s,a,op,rest) in enumerate(rows):
        if op[0] not in 'bj': continue
        m2 = re.search(r'\b([0-9a-f]+)\s*<', rest)
        if not m2: continue
        ta = int(m2.group(1),16)
        if ta < a and (s,ta) in addr:
            j = addr[(s,ta)]; n = i-j+1
            if n > 110: continue
            mix = {}
            for b in rows[j:i+1]: mix[b[2]] = mix.get(b[2],0)+1
            tag = " ".join("%s=%d"%(k,mix[k]) for k in ("lb","lbu","lw","ld","sb","sw","mul","mulh",".insn") if k in mix)
            print("   %-24s %x -> %x : %3d instr  [%s]" % (s.replace('.text.',''), a, ta, n, tag))
PYEOF
echo
"$SPIKE" "$w/b87ln.elf" 2>&1 | tee "$w/b87ln_icount.txt" | grep -E "MB_B87LN"
echo "workdir: $w"
