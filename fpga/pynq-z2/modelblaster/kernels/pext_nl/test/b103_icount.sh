#!/usr/bin/env bash
# B103 -- rope_s8's and add_s8's instruction accounts with the guard band folded into the
# rounding constant, measured on spike with the board's own compiler and flags.  Host only:
# no board, no bitstream, no lock.
#
# THE CONTROL ARM IS THE SHIPPED ARM, not the file's defaults: out/b101_combined_0035_f40's
# kernel_cflags.txt carries -DMBP_B74=1 -DMBP_B87=1, so both control objects are built with
# both and B103's delta is measured against what actually ships.  b87_icount_main.c is
# reused unchanged, so the rows it labels `_b87` are THIS script's B103 arms -- the header
# below says so and the flag lines are printed so the labels cannot be read the other way.
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
CF=(-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections -falign-loops=4
    -I"$SW" -I"$SHIM" -I"$here" -DMB_PEXT_HW=1)
w="${B103_ICOUNT_OUT:-$(mktemp -d)}"; mkdir -p "$w"

KR="$KD/pext_nl_rope_s8_pext_int_rot.c"
KA="$KD/pext_nl_add_s8_pext_int_add.c"
KG="$KD/pext_nl_groupnorm_s8_pext_int_rsqrt.c"

SHIP=(-DMBP_B74=1 -DMBP_B87=1)          # the shipped encoder's own flags
ARM=("${SHIP[@]}" -DMBP_B103=1)

echo "control arm : ${SHIP[*]}"
echo "B103 arm    : ${ARM[*]}     (printed under the _b87 labels)"
echo

one () {  # one <obj> <src> <rename> <extra -D...>
  local o="$1" src="$2" ren="$3"; shift 3
  "${CROSS}gcc" "${CF[@]}" "-D${ren}" "$@" -c "$src" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="${ren#*=}" "$w/$o.o"
}
one rctl "$KR" kernel_rope_s8=rope_ctl       "${SHIP[@]}"
one rb87 "$KR" kernel_rope_s8=rope_b87       "${ARM[@]}"
one actl "$KA" kernel_add_s8=add_ctl         "${SHIP[@]}"
one ab87 "$KA" kernel_add_s8=add_b87         "${ARM[@]}"
# groupnorm is untouched by B103; both arms are built identically so the two rows must be
# EQUAL.  A difference there is a sign the flag leaked, not a saving.
one gctl "$KG" kernel_groupnorm_s8=gn_ctl    -DMBP_B87=1
one gb87 "$KG" kernel_groupnorm_s8=gn_b87    -DMBP_B87=1 -DMBP_B103=1

"${CROSS}gcc" "${CF[@]}" -c "$here/b87_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o \
  "$w"/rctl.o "$w"/rb87.o "$w"/actl.o "$w"/ab87.o "$w"/gctl.o "$w"/gb87.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b103.elf" -lgcc

for o in rctl rb87 actl ab87; do
  "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"
done

echo "--- inner loops, counted off the measured objects themselves ---"
python3 - "$w"/rctl.dis "$w"/rb87.dis "$w"/actl.dis "$w"/ab87.dis <<'PYEOF'
import re, sys
pat = re.compile(r'^\s*([0-9a-f]+):\s+[0-9a-f ]+\t\s*(\S+)\s*(.*)$')
for path in sys.argv[1:]:
    print("== %s" % path.split('/')[-1])
    sec = None
    rows = []
    for l in open(path):
        m3 = re.match(r'^Disassembly of section (\S+):', l)
        if m3:
            sec = m3.group(1)
        m = pat.match(l)
        if m:
            rows.append((sec, int(m.group(1), 16), m.group(2), m.group(3)))
    addr = {(s, a): i for i, (s, a, o, r) in enumerate(rows)}
    for i, (s, a, op, rest) in enumerate(rows):
        if op[0] not in 'bj':
            continue
        m2 = re.search(r'\b([0-9a-f]+)\s*<', rest)
        if not m2:
            continue
        ta = int(m2.group(1), 16)
        if ta < a and (s, ta) in addr:
            j = addr[(s, ta)]
            n = i - j + 1
            if n > 70:
                continue
            mix = {}
            for b in rows[j:i + 1]:
                mix[b[2]] = mix.get(b[2], 0) + 1
            tag = " ".join("%s=%d" % (k, mix[k]) for k in ("lb", "lbu", "ld", "sb", "mul", ".insn") if k in mix)
            print("   %-28s %x -> %x : %2d instr   [%s]" % (s.replace('.text.', ''), a, ta, n, tag))
PYEOF

echo
"$SPIKE" "$w/b103.elf" 2>&1 | tee "$w/b103_icount.txt" | grep -E "MB_B87"
echo "raw: $w/b103_icount.txt"
echo "workdir: $w"
