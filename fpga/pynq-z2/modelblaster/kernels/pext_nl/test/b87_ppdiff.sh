#!/usr/bin/env bash
# B87 -- B73's/B76's preprocessed-source diff, unchanged in method, pointed at either half.
# THIS IS THE THIRD PROVENANCE LAYER AND THE OTHER TWO CANNOT DO ITS JOB:
#   kernel_cflags   catches a -D lever, and is blind to file-presence selection
#   kernel_digest   catches WHICH kernel was selected, and is blind to a source change
#                   inside one -- b86_attn_ctl2 and b86_attn_on2 share the digest
#                   d7b0fc89a42c while differing by -DMBP_B86=1
#   THIS            preprocesses each arm's own generated kernels.c with that arm's own
#                   cflags and diffs the result, per kernel body
# B68 lost a whole build set because MBP_CAT2_MINN moved 256 -> 176 inside a kernel between
# its arms while soc_magic, bitstream_md5, roccmoon_md5 AND the manifest digest all agreed.
#
#   b87_ppdiff.sh <control run> <treatment run> [outdir]     HALF=enc_q16 (default) or dec_q16
set -euo pipefail
R=${IISWC_ROOT:?source env.sh first}
A="${1:?control run name}"; B="${2:?treatment run name}"
HALF="${HALF:-enc_q16}"
OUT="${3:-/tmp/b87_ppdiff}"
mkdir -p "$OUT"
CC=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$R/zephyr-chipyard-sw/tools-manual}" -name 'riscv64-zephyr-elf-gcc' 2>/dev/null | head -1)
[ -x "$CC" ] || { echo "no riscv gcc"; exit 2; }
pp () {  # pp <run> <dest>
  local run="$1" dest="$2"
  local cf; cf=$(cat "$R/out/$run/${HALF}/kernel_cflags.txt")
  # shellcheck disable=SC2086
  "$CC" -E -P -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany \
      -I"$R/fpga/pynq-z2/sw" -I"$R/out/$run/${HALF}/gen" \
      -I"$R/out/$run/kernels_board" $cf \
      "$R/out/$run/${HALF}/gen/kernels.c" 2>/dev/null \
    | sed '/^[[:space:]]*$/d' > "$dest"
}
pp "$A" "$OUT/$A.i"
pp "$B" "$OUT/$B.i"
echo "preprocessed: $A $(wc -l < "$OUT/$A.i") lines, $B $(wc -l < "$OUT/$B.i") lines"
# per kernel body, so "which bodies differ" is the answer and not "the files differ"
split_bodies () {   # split_bodies <file> <dir>
  python3 - "$1" "$2" <<'PY'
# ================================================================================================
# THE BODY LABELS THIS PRODUCES ARE NAVIGATION, NOT EVIDENCE.  CLEAR AN ARM ON THE FILE DIFF.
#
# This split is a copy of b76_ppdiff.sh's and carries the same defect (L355, L362): it scans for
# `void kernel_*(`, so EVERYTHING BETWEEN TWO KERNELS IS ATTRIBUTED TO THE ONE BEFORE IT.  A
# change inside a file-scope static helper, an inline function or a macro body is labelled with
# the PRECEDING kernel's name -- and most of this tree's levers live exactly there.
#
# THIS TOOL'S OWN OUTPUT FOR B87 WAS WRONG ON THREE OF ELEVEN KERNELS, re-checked against the two
# images' disassembly (mnemonic multiset, relocation excluded):
#
#     IDENTICAL kernel_add_s8_moonshine_enc      FALSE -- 698 -> 685 instructions.  add_s8 is one
#                                                of B87's THREE TREATED KERNELS, and B87's own
#                                                band records .text +416 bytes on it.
#     DIFFERS   kernel_gelu_s8_moonshine_enc     false -- code identical, relocation only
#     DIFFERS   kernel_permute4_s8_moonshine_enc false -- code identical, relocation only
#
# A false DIFFERS gets investigated and discarded.  A FALSE `IDENTICAL` TOLD B87 THAT ONE OF ITS
# THREE LEVERS WAS NOT IN THE IMAGE; only an independent .text-size check contradicted it.
# ================================================================================================
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
