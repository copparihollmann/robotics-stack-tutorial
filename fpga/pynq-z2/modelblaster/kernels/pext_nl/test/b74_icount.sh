#!/usr/bin/env bash
# B74 -- rope_s8's and add_s8's instruction accounts, their splits and their FLOORS,
# measured on spike with the board's own compiler and flags.  Host only: no board, no
# bitstream, no lock.  See b74_icount_main.c for what is counted and why.
#
# The board's own kernel_cflags, copied from out/b72_enc_stage_on/run.json:
#   -DMB_PEXT_HW=1 -falign-loops=4  (plus MBXR_RT_* which no pext_nl kernel reads)
# MB_PEXT_HW=1 means the REAL custom-0 encodings, which this spike implements
# (patches/0006-spike-mbp-pext-insns), so mb_pext_clip8 costs one instruction here
# exactly as it does on the board.
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
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections -falign-loops=4
    -I"$SW" -I"$SHIM" -I"$here" -DMB_PEXT_HW=1)
w="${B74_ICOUNT_OUT:-$(mktemp -d)}"; mkdir -p "$w"

KR="$KD/pext_nl_rope_s8_pext_int_rot.c"
KA="$KD/pext_nl_add_s8_pext_int_add.c"

kr () {  # kr <obj> <symbol> <extra -D...>
  local o="$1"; shift; local sym="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_rope_s8="$sym" "$@" -c "$KR" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$sym" "$w/$o.o"
}
ka () {
  local o="$1"; shift; local sym="$1"; shift
  "${CROSS}gcc" "${CF[@]}" -Dkernel_add_s8="$sym" "$@" -c "$KA" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="$sym" "$w/$o.o"
}
kr rship rope_ship
kr rpre  rope_pre  -DMBP_ROPE_NO_FAST=1
kr rb74  rope_b74  -DMBP_B74=1
ka aship add_ship
ka apre  add_pre   -DMBP_ADD_NO_FAST=1
ka ab74  add_b74   -DMBP_B74=1

"${CROSS}gcc" "${CF[@]}" -c "$here/b74_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o \
  "$w"/rship.o "$w"/rpre.o "$w"/rb74.o "$w"/aship.o "$w"/apre.o "$w"/ab74.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b74.elf" -lgcc

# The disassembly half: the very objects measured above, not a different build.
"${CROSS}objdump" -d "$w/rship.o" > "$w/rship.dis"
"${CROSS}objdump" -d "$w/aship.o" > "$w/aship.dis"
"${CROSS}objdump" -d "$w/rb74.o" > "$w/rb74.dis"
"${CROSS}objdump" -d "$w/ab74.o" > "$w/ab74.dis"

echo "--- inner loops, counted off the measured objects themselves ---"
python3 - "$w/rship.dis" "$w/aship.dis" "$w/rb74.dis" "$w/ab74.dis" <<'PYEOF'
import re, sys
pat = re.compile(r'^\s*([0-9a-f]+):\s+[0-9a-f ]+\t\s*(\S+)\s*(.*)$')
for path in sys.argv[1:]:
    rows = []
    for l in open(path):
        m = pat.match(l)
        if m:
            rows.append((int(m.group(1), 16), m.group(2), m.group(3)))
    addr = {a: i for i, (a, o, r) in enumerate(rows)}
    print("== %s" % path.split('/')[-1])
    for i, (a, op, rest) in enumerate(rows):
        if op[0] not in 'bj':
            continue
        t = re.search(r'^([0-9a-f]+)\s', rest.split(',')[-1].strip())
        m2 = re.search(r'\b([0-9a-f]+)\s*<', rest)
        if not m2:
            continue
        ta = int(m2.group(1), 16)
        if ta < a and ta in addr:
            n = i - addr[ta] + 1
            if n <= 60:
                print("   backedge %x -> %x : %2d instructions in the body   [%s %s]"
                      % (a, ta, n, op, rest.split('<')[0].strip()))
PYEOF

echo
"$SPIKE" "$w/b74.elf" 2>&1 | tee "$w/b74_icount.txt" | grep -E "MB_B74"
echo "raw: $w/b74_icount.txt"
echo "workdir: $w"
