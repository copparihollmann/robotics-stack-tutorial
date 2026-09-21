#!/usr/bin/env bash
# B87 -- rope_s8's, add_s8's and groupnorm_s8's instruction accounts and their splits,
# measured on spike with the board's own compiler and flags.  Host only: no board, no
# bitstream, no lock.  See b87_icount_main.c for what is counted and why.
#
# THE CONTROL ARM IS THE HEADLINE ARM, not the file's defaults: the shipped encoder runs
# with -DMBP_B74=1 (out/b86_attn_on2/enc_q16/kernel_cflags.txt), so rope_ctl and add_ctl
# are built with it and B87's delta is measured against what actually ships.
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
w="${B87_ICOUNT_OUT:-$(mktemp -d)}"; mkdir -p "$w"

KR="$KD/pext_nl_rope_s8_pext_int_rot.c"
KA="$KD/pext_nl_add_s8_pext_int_add.c"
KG="$KD/pext_nl_groupnorm_s8_pext_int_rsqrt.c"

one () {  # one <obj> <src> <rename> <extra -D...>
  local o="$1" src="$2" ren="$3"; shift 3
  "${CROSS}gcc" "${CF[@]}" "-D${ren}" "$@" -c "$src" -o "$w/$o.o"
  "${CROSS}objcopy" --keep-global-symbol="${ren#*=}" "$w/$o.o"
}
one rctl "$KR" kernel_rope_s8=rope_ctl       -DMBP_B74=1
one rb87 "$KR" kernel_rope_s8=rope_b87       -DMBP_B74=1 -DMBP_B87=1
one actl "$KA" kernel_add_s8=add_ctl         -DMBP_B74=1
one ab87 "$KA" kernel_add_s8=add_b87         -DMBP_B74=1 -DMBP_B87=1
one gctl "$KG" kernel_groupnorm_s8=gn_ctl
one gb87 "$KG" kernel_groupnorm_s8=gn_b87    -DMBP_B87=1

"${CROSS}gcc" "${CF[@]}" -c "$here/b87_icount_main.c" -o "$w/main.o"
"${CROSS}gcc" "${CF[@]}" "$IC/crt.S" "$IC/htif.c" "$w"/main.o \
  "$w"/rctl.o "$w"/rb87.o "$w"/actl.o "$w"/ab87.o "$w"/gctl.o "$w"/gb87.o \
  -nostdlib -nostartfiles -Wl,--no-relax -Wl,--gc-sections -static \
  -T "$IC/link.ld" -o "$w/b87.elf" -lgcc

# The disassembly half: the very objects measured above, not a different build.
for o in rctl rb87 actl ab87 gctl gb87; do
  "${CROSS}objdump" -d "$w/$o.o" > "$w/$o.dis"
done

echo "--- inner loops, counted off the measured objects themselves ---"
python3 - "$w"/rctl.dis "$w"/rb87.dis "$w"/actl.dis "$w"/ab87.dis "$w"/gctl.dis "$w"/gb87.dis <<'PYEOF'
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
            body = rows[j:i + 1]
            mix = {}
            for b in body:
                mix[b[2]] = mix.get(b[2], 0) + 1
            tag = " ".join("%s=%d" % (k, mix[k]) for k in ("lb", "lbu", "ld", "sb", "mul", ".insn") if k in mix)
            print("   %-28s %x -> %x : %2d instr   [%s]" % (s.replace('.text.', ''), a, ta, n, tag))
PYEOF

echo
"$SPIKE" "$w/b87.elf" 2>&1 | tee "$w/b87_icount.txt" | grep -E "MB_B87"
echo "raw: $w/b87_icount.txt"
echo "workdir: $w"
