#!/usr/bin/env bash
# The host gate for the two LUT-lane kernels, and it runs BEFORE any board time.
#
#   ./scripts/72_lut_kernel_check.sh
#
# WHY A HOST GATE AT ALL.  Lab B37 measured the lane itself on silicon -- 0.1253 cycles/element,
# 187,904 bytes byte-compared, 0 differing -- so what is left to get wrong is the SOFTWARE
# around it: the table, and the tiling.  Both are provable without a board, and the two
# failures they would otherwise produce are a hang and a plausible wrong answer.
#
# WHAT IT PROVES
#   1. gelu_s8's table is the curated kernel's, over all 256 inputs x 16 scale pairs.  The lane
#      is a pure map, so agreement on the table is agreement on every possible stream -- a proof
#      over the whole domain rather than a sample.
#   2. tanh_s8's table is a TRANSCRIPTION (the curated tanh kernel exports no builder), so it is
#      checked against that kernel compiled under a rename -- the curated OUTPUT, never a golden
#      rebuilt from the transcription.  A golden regenerated from the new arithmetic compares a
#      kernel against itself and passes at 0 while proving nothing; three workstreams have now
#      named that trap and the attention unit measured its cost -- arm b41 landed INSIDE its
#      predicted band at rtf_steady 2.288 with max_abs_err 144.
#   3. every tile the plan will issue satisfies the rules the hardware requires and does not
#      enforce: destination 64-byte aligned, word count a multiple of 8, word0 + words inside
#      one 1,024-word buffer, and the drain's whole blocks covering the tile EXACTLY.  It is
#      checked through mbxr_lane_check() -- the same function the target calls -- so this is the
#      accept/reject decision itself and not a restatement of it.
#   4. on the model's own shapes, including the two whose naive last tile is 820 and 124 words:
#      neither a multiple of 8, and each of them the silent-tail hang.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
B="$IISWC_ROOT/fpga/pynq-z2"
OUT="${IISWC_OUT}/lut_kernel_check"
mkdir -p "$OUT"
step "1/3  build the host check"
run "${CC:-cc}" -O2 -Wall -Wextra -Wno-unused-parameter -Wno-stringop-overflow \
    -I "$B/sw" -I "$B/sw/roccmoon" -I "$B/modelblaster/kernels/roccmoon" \
    "$B/modelblaster/moonshine/check/gelu_lane_check.c" -o "$OUT/gelu_lane_check" -lm
step "2/3  run it"
"$OUT/gelu_lane_check" | tee "$OUT/report.txt"
grep -q "GELU_LANE_CHECK: PASS" "$OUT/report.txt" || die "the host gate did not pass"
info "report: $OUT/report.txt"

# ---- 3/3 ------------------------------------------------------------------------------------
# THE TARGET COMPILE OF THE GUARDED PATH.  Steps 1 and 2 compile the FALLBACK -- off Zephyr the
# lane arm is preprocessed away -- and every model image built so far has MBXR_RT_LUT off.  So
# without this step the lane path has never been compiled by the compiler that will run it, and
# a path that only ever builds under one set of defines is a path nobody has built.
#
# It borrows the model build's own command line from compile_commands.json rather than guessing
# one, so it uses the real target flags.  If no model build is around it says so and does not
# pretend to have checked.
step "3/3  compile the MBXR_RT_LUT=1 path for the target"
CC_JSON="$(ls -t "$IISWC_OUT"/*/enc_q16/build/compile_commands.json "$IISWC_OUT"/*/dec_q16/build/compile_commands.json 2>/dev/null | head -1 || true)"
if [ -z "$CC_JSON" ]; then
  warn "no model build found under $IISWC_OUT, so the TARGET compile of the lane path was NOT run"
  warn "  (build one with scripts/57 --build-only, then re-run this)"
  exit 0
fi
cat > "$OUT/lut_tu.c" <<'TU'
#include "roccmoon_gelu_s8_roccmoon_lut.c"
#include "roccmoon_tanh_s8_roccmoon_lut.c"
TU
python3 - "$CC_JSON" "$B" "$OUT" <<'PYP' || die "the MBXR_RT_LUT=1 path does not compile for the target"
import json, os, shlex, subprocess, sys
ccj, B, out = sys.argv[1], sys.argv[2], sys.argv[3]
cc = json.load(open(ccj))
e = [x for x in cc if x["file"].endswith("kernels.c")] or \
    [x for x in cc if x["file"].endswith("main.c")]
if not e:
    print("    no kernels.c entry in %s" % ccj); sys.exit(1)
c = e[0]
args, skip = [], False
for a in shlex.split(c["command"]):
    if skip: skip = False; continue
    if a in ("-o", "-MF", "-MT", "-c"): skip = True; continue
    args.append(a)
args += ["-DMBXR_RT_LUT=1",
         "-I" + os.path.join(B, "modelblaster/kernels/roccmoon"),
         "-I" + os.path.join(B, "sw"), "-I" + os.path.join(B, "sw/roccmoon"),
         "-c", os.path.join(out, "lut_tu.c"), "-o", os.path.join(out, "lut_tu.o")]
r = subprocess.run(args, cwd=c["directory"], capture_output=True, text=True)
if r.returncode:
    sys.stderr.write(r.stderr[-4000:]); sys.exit(1)
print("    compiled from %s" % os.path.relpath(ccj, os.path.dirname(os.path.dirname(B))))
# and the lane path must actually be IN the object: if the guard had compiled it away these
# symbols would be missing and the compile would still have "passed"
nm = None
for a in shlex.split(c["command"]):
    if a.endswith("-gcc"): nm = a[:-4] + "-nm"; break
if nm and os.path.exists(nm):
    syms = subprocess.run([nm, os.path.join(out, "lut_tu.o")], capture_output=True,
                          text=True).stdout
    need = ["kernel_gelu_s8", "kernel_tanh_s8", "mbxr_lut_map_op", "mbxr_rt_lut_post"]
    missing = [s for s in need if s not in syms]
    if missing:
        print("    THE GUARD COMPILED THE LANE PATH AWAY: missing %s" % ", ".join(missing))
        sys.exit(1)
    print("    lane path present: %s" % ", ".join(need))
PYP
info "the lane path compiles for riscv64-zephyr-elf and is present in the object"
