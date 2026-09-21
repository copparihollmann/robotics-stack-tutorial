#!/usr/bin/env bash
# B76 (B73's, unchanged in method): the check a kernel manifest CANNOT do -- preprocess each arm's own generated kernels.c
# with that arm's own cflags and diff the results.  B68 lost a whole build set because
# MBP_CAT2_MINN moved 256 -> 176 inside a kernel between its arms while soc_magic,
# bitstream_md5, roccmoon_md5 AND the manifest digest all agreed.
set -euo pipefail
R=${IISWC_ROOT:?source env.sh first}
A="${1:?control run name}"; B="${2:?treatment run name}"
OUT="${3:-/tmp/b73_ppdiff}"
mkdir -p "$OUT"
CC=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$R/zephyr-chipyard-sw/tools-manual}" -name 'riscv64-zephyr-elf-gcc' 2>/dev/null | head -1)
[ -x "$CC" ] || { echo "no riscv gcc"; exit 2; }
pp () {  # pp <run> <dest>
  local run="$1" dest="$2"
  local cf; cf=$(cat "$R/out/$run/dec_q16/kernel_cflags.txt")
  # shellcheck disable=SC2086
  "$CC" -E -P -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany \
      -I"$R/fpga/pynq-z2/sw" -I"$R/out/$run/dec_q16/gen" \
      -I"$R/out/$run/kernels_board" $cf \
      "$R/out/$run/dec_q16/gen/kernels.c" 2>/dev/null \
    | sed '/^[[:space:]]*$/d' > "$dest"
}
pp "$A" "$OUT/$A.i"
pp "$B" "$OUT/$B.i"
echo "preprocessed: $A $(wc -l < "$OUT/$A.i") lines, $B $(wc -l < "$OUT/$B.i") lines"
# ================================================================================================
# THE BODY LABELS BELOW ARE NAVIGATION, NOT EVIDENCE.  READ THE FILE-LEVEL DIFF TO CLEAR AN ARM.
#
# This split scans for `void kernel_*(`, so EVERYTHING BETWEEN TWO KERNELS IS ATTRIBUTED TO THE
# ONE BEFORE IT.  A change inside a file-scope static helper, an inline function, a macro body or
# a file-scope declaration is therefore labelled with the PRECEDING kernel's name -- and most of
# this tree's levers live exactly there (pmmb_m1_rows, pmmb_m1_padall8, pint_rope_apply,
# pint_rope_build, pint_add_c, mbxr_lut_stats).
#
# B82 found this (L355) on pmmb_m1_rows.  B84 reproduced it three more times in one session and
# ONE WAS IN THE DANGEROUS DIRECTION (L362):
#
#     DIFFERS   kernel_linear_s8_moonshine_dec     FALSE -- pmmb_m1_padall8 precedes it
#     DIFFERS   kernel_permute4_s8_moonshine_dec   FALSE -- the rope helpers precede it
#     IDENTICAL kernel_matmul_b_s8_moonshine_dec   FALSE -- THE CHANGE IS INSIDE IT
#     DIFFERS   kernel_add_s8_moonshine_dec        FALSE -- mbxr_lut_stats precedes it
#
# A false DIFFERS gets investigated and discarded.  A FALSE `IDENTICAL` IS A CLEAN BILL OF HEALTH
# FOR AN ARM THAT CHANGED -- the same failure mode as the lost build set this script exists to
# prevent.  Clear an arm on the whole-file diff and its hunk count; use the labels only to find
# your way around it.
# ================================================================================================
# per kernel body, so "which bodies differ" is the answer and not "the files differ"
split_bodies () {   # split_bodies <file> <dir>
  python3 - "$1" "$2" <<'PY'
import os, re, sys
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
t = open(src).read()
marks = [(m.start(), m.group(1)) for m in re.finditer(r'\bvoid (kernel_[A-Za-z0-9_]+)\s*\(', t)]
marks.append((len(t), None))
for i in range(len(marks) - 1):
    a, name = marks[i]
    b = marks[i + 1][0]
    open(os.path.join(out, name + ".i"), "w").write(t[a:b])
print("%d kernel bodies" % (len(marks) - 1))
PY
}
split_bodies "$OUT/$A.i" "$OUT/${A}_bodies"
split_bodies "$OUT/$B.i" "$OUT/${B}_bodies"
same=0; diff=0; only=0
{
for f in "$OUT/${A}_bodies"/*.i; do
  n=$(basename "$f")
  if [ -f "$OUT/${B}_bodies/$n" ]; then
    if cmp -s "$f" "$OUT/${B}_bodies/$n"; then echo "IDENTICAL  ${n%.i}"; same=$((same+1))
    else echo "DIFFERS    ${n%.i}"; diff=$((diff+1)); fi
  else echo "ONLY IN $A  ${n%.i}"; only=$((only+1)); fi
done
for f in "$OUT/${B}_bodies"/*.i; do
  n=$(basename "$f")
  [ -f "$OUT/${A}_bodies/$n" ] || { echo "ONLY IN $B  ${n%.i}"; only=$((only+1)); }
done
echo "-- $same identical, $diff differing, $only one-sided --"
} | sort | tee "$OUT/bodies.txt"
diff -u "$OUT/$A.i" "$OUT/$B.i" > "$OUT/preprocessed_arm_diff.diff" || true
echo "full diff: $(wc -l < "$OUT/preprocessed_arm_diff.diff") lines -> $OUT/preprocessed_arm_diff.diff"
