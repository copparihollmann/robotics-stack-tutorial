#!/usr/bin/env bash
# Lab B7 -- the same ModelBlaster network as Lab B5, on the same board, with the four
# MBP packed-integer instructions of fpga/pynq-z2/docs/PEXT_SPEC.md doing the arithmetic.
#
#   extract_graph (int8 PTQ)  ->  generate_skeleton  ->  generate_kernels --target pext
#   ->  bit-exactness against the scalar reference (host)
#   ->  dynamic instruction counts, scalar vs MBP (spike)
#   ->  west build (chipyard_pynqz1_smp, CONFIG_MB_PEXT=y)  ->  ELF gate
#
# THIS SCRIPT DOES NOT TOUCH THE BOARD, AND THAT IS NOT A LIMITATION OF THE SCRIPT.  No
# bitstream carries the extension yet: MBP.DOT8 on the shipped PL is an illegal
# instruction on both harts.  Everything below is therefore measured on the host and on
# spike, which is where PEXT_SPEC.md section 5's numbers came from in the first place,
# and the image it builds is ready for the bitstream when it lands -- at which point
# `scripts/with_board.sh` plus the board stage of 24_rocket_modelblaster.sh is the
# missing step, not a rewrite.
#
# WHAT IS MEASURED, AND WITH WHAT:
#
#   bit-exactness   fpga/pynq-z2/modelblaster/check/check_bitexact.py -- three checks,
#                   all with MB_PEXT_HW=0 so the kernels run pext.h's own software model
#                   of the four instructions (PEXT_SPEC.md 3.5 makes that model the
#                   normative definition).  ModelBlaster's host verify at atol=rtol=0;
#                   a stress sweep over quant parameters, clamps, zero points, alignments
#                   and shapes under ASan+UBSan; and the whole LeNet graph, reference
#                   kernels against MBP kernels, every intermediate tensor compared.
#
#   instructions    fpga/pynq-z2/modelblaster/check/count_instructions.py -- spike
#                   minstret, per dispatch, with the REAL encodings executing
#                   (patches/0006-spike-mbp-pext-insns.patch).  Not cycles: no bitstream
#                   exists to measure cycles on, and an estimate of one would be an
#                   estimate.
#
# WHAT IT DELIBERATELY DOES NOT DO.  It does not modify, rebuild or re-measure
# samples/modelblaster_hart_latency, scripts/24_rocket_modelblaster.sh or
# expected/modelblaster_lenet_int8.json.  Those are the scalar baseline this lab is
# measured against, and the comparison is only worth anything if they are untouched.
#
# Produces, under out/<name>/:
#   model/ir/, model/gen/    the ModelBlaster IR and the generated C (target=pext)
#   bitexact.txt             the three bit-exactness checks, in full
#   icount.json, icount.txt  per-dispatch instruction counts, scalar vs MBP
#   zephyr.elf / zephyr.bin  the guest, built with CONFIG_MB_PEXT=y
#   isa.txt                  the ELF attribute gate's evidence, plus the MBP encodings
#   run.json                 manifest
#
# Usage:
#   ./scripts/28_rocket_modelblaster_pext.sh                 # everything (no board)
#   ./scripts/28_rocket_modelblaster_pext.sh --no-zephyr     # checks + counts only
#   ./scripts/28_rocket_modelblaster_pext.sh --no-icount     # skip the spike stage
#   ./scripts/28_rocket_modelblaster_pext.sh --model mlp_generic
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODEL="lenet"
QUANT="int8"
TARGET="pext"
ITERS=11
NAME=""
BOARD="chipyard_pynqz1_smp"
SAMPLE="$IISWC_ROOT/samples/modelblaster_pext"
SCALAR_RUN=""
DO_ZEPHYR=1
DO_ICOUNT=1
DO_CHECK=1
STRESS_ITERS=600
while [ $# -gt 0 ]; do
  case "$1" in
    --model)  MODEL="${2:?}";  shift 2 ;;
    --quant)  QUANT="${2:?}";  shift 2 ;;
    --iters)  ITERS="${2:?}";  shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --scalar-run) SCALAR_RUN="${2:?}"; shift 2 ;;
    --stress-iters) STRESS_ITERS="${2:?}"; shift 2 ;;
    --no-zephyr) DO_ZEPHYR=0; shift ;;
    --no-icount) DO_ICOUNT=0; shift ;;
    --no-check)  DO_CHECK=0;  shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
NAME="${NAME:-rocket_mb_${MODEL}_${QUANT}_pext}"
SCALAR_RUN="${SCALAR_RUN:-$IISWC_OUT/rocket_mb_${MODEL}_${QUANT}}"

MB="$ZCS/modelblaster"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
CHECK="$IISWC_ROOT/fpga/pynq-z2/modelblaster/check"
PEXT_H="$IISWC_ROOT/fpga/pynq-z2/sw/pext.h"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB"
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
need_file "$PEXT_H" "the ISA contract"
[ -d "$KERNELS/pext" ] || die "no curated pext kernels at $KERNELS/pext"

RUN="$IISWC_OUT/$NAME"
BUILD="$RUN/build"
IR="$RUN/model/ir"
GEN="$RUN/model/gen"

rm -rf "$RUN"
mkdir -p "$IR" "$GEN" "$RUN/model/cache"

# ---------------------------------------------------------------------------
step "1/7  modelblaster backend patch  (patches/0009-modelblaster-pext-backend.patch)"
# THE SUBMODULE IS A PINNED, READ-ONLY INPUT, so the two edits ModelBlaster needs to know
# about this target live in patches/ -- the same arrangement patches/0005-zcs-* uses for
# zephyr-chipyard-sw and 0004-rocketchip-* uses for a shared Chipyard tree. They are a
# Backend named "pext" in pipeline/backends.py and three AlgorithmCandidates in
# pipeline/reference_kernels.py; the curated kernels themselves stay in THIS repo. The
# patch header says why each is at pipeline's own documented extension point rather than
# somewhere more invasive. Idempotent: a reverse-check first, so re-running is free.
MBPATCH="$IISWC_ROOT/patches/0009-modelblaster-pext-backend.patch"
need_file "$MBPATCH"
if ( cd "$MB" && git apply --reverse --check "$MBPATCH" ) >/dev/null 2>&1; then
  info "already applied to $MB"
elif ( cd "$MB" && git apply --check "$MBPATCH" ) >/dev/null 2>&1; then
  run git -C "$MB" apply "$MBPATCH"
  info "applied to $MB"
else
  die "patches/0009-modelblaster-pext-backend.patch neither applies nor is applied to
       $MB. The submodule has moved off its pin, or somebody edited those two files by
       hand. \`git -C $MB status\` and \`git -C $MB diff\` will say which."
fi
( cd "$ZCS" && PYTHONPATH="$ZCS" python -c "
from modelblaster.pipeline import backends
b = backends.get('pext')
print(f'    Backend(pext): cflags={b.kernel_cflags} verify={b.verify_method}')" )   || die "the pext backend is not importable even after the patch"

step "2/7  modelblaster codegen  (model=$MODEL quant=$QUANT target=$TARGET)"
# Same three stages, and the same two reasons, as 24_rocket_modelblaster.sh: run them
# directly rather than through examples/<model>/run.sh so the submodule stays a
# read-only input, and point --cache-dir at a FRESH directory so no stale cache entry
# can be swapped in behind a signature that has since changed.
#
# The differences from the scalar lab are exactly two:
#   --target pext                  selects pipeline/backends.py's PEXT backend, which is
#                                  what makes kernel selection look for pext kernels
#   --global-curated-dir <here>    points at THIS repo's curated kernels rather than the
#                                  submodule's modelblaster/kernels/, so the submodule
#                                  stays read-only for this too
#
# CPATH carries fpga/pynq-z2/sw so the host-ctypes verify inside generate_kernels can
# resolve `#include "pext.h"`. pext.h itself defaults MB_PEXT_HW to 0 off-target, so the
# host compiles the bit-identical software model rather than an encoding x86 cannot run.
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
( cd "$ZCS" && run python -m modelblaster.pipeline.extract_graph \
    --model "$MODEL" --out-dir "$IR" --quant "$QUANT" \
    --num-calibration 1 --fusion-target "$TARGET" ) \
  > "$RUN/codegen.log" 2>&1 || { tail -30 "$RUN/codegen.log"; die "extract_graph failed"; }
( cd "$ZCS" && run python -m modelblaster.pipeline.generate_skeleton \
    --ir "$IR/graph.json" --weights "$IR/weights.npz" --io "$IR/io.npz" \
    --out-dir "$GEN" --backend "$TARGET" ) \
  >> "$RUN/codegen.log" 2>&1 || { tail -30 "$RUN/codegen.log"; die "generate_skeleton failed"; }
( cd "$ZCS" && run python -m modelblaster.pipeline.generate_kernels \
    --ir "$IR/graph.json" --out-dir "$GEN" --backend reference --target "$TARGET" \
    --quant "$QUANT" --io "$IR/io.npz" --repo-root "$MB" \
    --build-dir "$RUN/model/kverify" --harness-dir "$MB/harness" \
    --cache-dir "$RUN/model/cache" --algorithms all \
    --global-curated-dir "$KERNELS" ) \
  >> "$RUN/codegen.log" 2>&1 || { tail -30 "$RUN/codegen.log"; die "generate_kernels failed"; }
need_file "$GEN/kernels.c" "codegen produced no kernels"
need_file "$GEN/test_golden.bin" "codegen produced no golden"

info "ops: $(python3 -c "import json;print(','.join(sorted({o['op'] for o in json.load(open('$IR/graph.json'))['ops'] if o['op']!='view'})))")"
info "kernel sources: $(python3 -c "import json;p=json.load(open('$GEN/kernel_picks.json'))['picks'];print(', '.join(f\"{k}={v['source']}/{v['algorithm']}\" for k,v in sorted(p.items())))")"

# EVERY OP MUST BE CURATED, NOT REFERENCE.  A pext build in which an op quietly fell back
# to the scalar reference still compiles, still boots, still produces the right answer --
# and reports a number that is not a measurement of the extension.  backends.py's own
# comments record this failure mode twice (rvv_x60's 195 ms vs 113 ms on DroNet, and the
# ime curated_aliases note); it is worth failing on rather than warning about.
python3 - "$GEN/kernel_picks.json" <<'PY' || die "not every op resolved to a curated pext kernel"
import json, sys
picks = json.load(open(sys.argv[1]))["picks"]
bad = {k: v for k, v in picks.items() if v.get("source") != "curated"}
for k, v in sorted(picks.items()):
    print(f"    {'ok  ' if k not in bad else 'FAIL'}  {k:<16} {v.get('source')}/{v.get('algorithm')}")
sys.exit(1 if bad else 0)
PY

# Same float scan as the scalar lab, for the same reason: 22 of the 43 `_s8` reference
# KernelSpecs dequantize to float internally, which on this WithoutFPU core is libgcc
# soft-float -- integer instructions, so no ELF check can see them.
FLOATY=$(grep -nE '(^|[^_[:alnum:]])(float|double)([^_[:alnum:]]|$)|\b(expf|roundf|sqrtf|logf|tanhf|powf|fabsf)\b' \
           "$GEN/kernels.c" | grep -v '^[0-9]*:#include' || true)
if [ -n "$FLOATY" ]; then
  KERNELS_INTEGER_ONLY=0
  warn "the generated kernels contain floating point -- on this WithoutFPU core that is
       libgcc soft-float emulation. The offending lines:"
  printf '%s\n' "$FLOATY" | head -10 | sed 's/^/       /' >&2
else
  KERNELS_INTEGER_ONLY=1
  info "kernels are integer-only (no float/double/expf in kernels.c)"
fi

# ---------------------------------------------------------------------------
if [ "$DO_CHECK" -eq 1 ]; then
  step "3/7  bit-exactness against the scalar reference  (host, MB_PEXT_HW=0)"
  if [ ! -d "$SCALAR_RUN/model/gen" ]; then
    warn "no scalar baseline at $SCALAR_RUN/model/gen -- the whole-model comparison
       needs one. Build it with:  ./scripts/24_rocket_modelblaster.sh --build-only"
    run python3 "$CHECK/check_bitexact.py" --skip-model \
        --iters "$STRESS_ITERS" --pext-gen-dir "$GEN" \
        --build-dir "$RUN/bitexact" 2>&1 | tee "$RUN/bitexact.txt"
  else
    run python3 "$CHECK/check_bitexact.py" \
        --iters "$STRESS_ITERS" --gen-dir "$SCALAR_RUN/model/gen" \
        --pext-gen-dir "$GEN" --build-dir "$RUN/bitexact" 2>&1 \
      | tee "$RUN/bitexact.txt"
  fi
  grep -q '^RESULT: PASS' "$RUN/bitexact.txt" || die "bit-exactness check failed -- see $RUN/bitexact.txt"
else
  step "3/7  bit-exactness -- skipped by request"
fi

# ---------------------------------------------------------------------------
if [ "$DO_ICOUNT" -eq 1 ] && [ -d "$SCALAR_RUN/model/gen" ] && [ -x "$TACIT_SPIKE" ]; then
  step "4/7  dynamic instruction counts  (spike minstret, real MBP encodings)"
  run python3 "$CHECK/count_instructions.py" \
      --gen-dir "$SCALAR_RUN/model/gen" --pext-gen-dir "$GEN" \
      --build-dir "$RUN/icount" --json "$RUN/icount.json" 2>&1 \
    | tee "$RUN/icount.txt"
  need_file "$RUN/icount.json" "the instruction-count stage produced no manifest"
elif [ "$DO_ICOUNT" -eq 0 ]; then
  step "4/7  instruction counts -- skipped by request"
else
  step "4/7  instruction counts -- SKIPPED"
  [ -x "$TACIT_SPIKE" ] || warn "no spike at $TACIT_SPIKE -- run scripts/05_build_tacit_tools.sh"
  [ -d "$SCALAR_RUN/model/gen" ] || warn "no scalar baseline at $SCALAR_RUN to compare against"
fi

# ---------------------------------------------------------------------------
if [ "$DO_ZEPHYR" -eq 1 ]; then
  step "5/7  build  ($BOARD, CONFIG_MB_PEXT=y)"
  # kernel_cflags come from the backend rather than from this script, so the two cannot
  # drift. They are applied to kernels.c only, exactly as modelblaster/harness does it.
  MB_KERNEL_CFLAGS=$(cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
print(' '.join(backends.get('pext').resolved_kernel_cflags('$MB')))")
  info "kernels.c cflags from Backend('pext'): ${MB_KERNEL_CFLAGS:-<none>}"
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$GEN" -DMB_ITERS="$ITERS" \
      -DMODELBLASTER_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS" \
    > "$RUN/build.log" 2>&1 || { tail -40 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
  need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
  cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"

  grep -q '^CONFIG_MB_PEXT=y' "$BUILD/zephyr/.config" \
    || die "CONFIG_MB_PEXT is not set in the built .config -- this image would run
       pext.h's software model and measure nothing about the extension"
  NCPU=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$BUILD/zephyr/.config" | cut -d= -f2)
  [ "${NCPU:-1}" -ge 2 ] || die "CONFIG_MP_MAX_NUM_CPUS=$NCPU -- the negative test needs two harts"
  grep -q '^CONFIG_SMP=y' "$BUILD/zephyr/.config" || die "CONFIG_SMP is not enabled"
  grep -q '^CONFIG_SCHED_CPU_MASK=y' "$BUILD/zephyr/.config" \
    || die "CONFIG_SCHED_CPU_MASK is not enabled -- k_thread_cpu_pin() would not exist,
       and pinning is the entire heterogeneity mechanism (PEXT_SPEC.md 7.3)"
  if grep -q '^CONFIG_FPU=y' "$BUILD/zephyr/.config"; then
    die "CONFIG_FPU=y in the built .config, against a WithoutFPU core."
  fi

  step "6/7  ELF gate  (no float, and the MBP encodings are actually there)"
  READELF="$(command -v riscv64-zephyr-elf-readelf || true)"
  OBJDUMP="$(command -v riscv64-zephyr-elf-objdump || true)"
  [ -n "$READELF" ] || die "riscv64-zephyr-elf-readelf not on PATH -- source env.sh"
  [ -n "$OBJDUMP" ] || die "riscv64-zephyr-elf-objdump not on PATH -- source env.sh"
  {
    "$READELF" -h "$RUN/zephyr.elf" | grep -E 'Entry point|Flags'
    "$READELF" -A "$RUN/zephyr.elf" | grep Tag_RISCV_arch
  } > "$RUN/isa.txt"
  sed 's/^/    /' "$RUN/isa.txt"
  grep -q 'soft-float ABI' "$RUN/isa.txt" || { cat "$RUN/isa.txt"; die "not a soft-float ABI build"; }
  ARCH=$(grep Tag_RISCV_arch "$RUN/isa.txt" | sed 's/.*"\(.*\)".*/\1/')
  case "$ARCH" in
    *_f[0-9]*|*_d[0-9]*|*_v[0-9]*) die "ELF advertises f/d/v: $ARCH -- this core has none of them" ;;
  esac
  FPINSN=$("$OBJDUMP" -d "$RUN/zephyr.elf" \
    | grep -cE '^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]+(f(add|sub|mul|div|sqrt|mv|cvt|ld|sd|lw|sw|sgnj|min|max|eq|lt|le|class|madd|msub|nmadd|nmsub)|c\.f(ld|sd|lw|sw)|v(set|le|se|add|mul|mac))' || true)
  [ "${FPINSN:-0}" -eq 0 ] || die "$FPINSN float/vector instructions in the image"
  echo "    0 float/vector instructions in the disassembly" >> "$RUN/isa.txt"

  # THE CHECK THAT IS NEW HERE, AND THE ONE THAT MATTERS.  Tag_RISCV_arch says nothing
  # about MBP -- the instructions are emitted with `.insn`, which leaves no trace in the
  # attributes and no extension in the ISA string, ON PURPOSE (it is what keeps the exact
  # multilib match). So the only evidence that this image actually carries the extension
  # is the encodings themselves, decoded out of the disassembly by hand against the table
  # in PEXT_SPEC.md 3.0: opcode 0x0b, funct7 0, funct3 0/1/2/3.
  "$OBJDUMP" -d "$RUN/zephyr.elf" > "$RUN/zephyr.dis"
  python3 - "$RUN/zephyr.dis" <<'PY' | tee -a "$RUN/isa.txt" || die "no MBP encodings in the image"
import re, sys
names = ["MBP.DOT8", "MBP.MAX8", "MBP.QMUL", "MBP.CLIP8"]
counts = [0, 0, 0, 0]
other = 0
for w in re.findall(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", open(sys.argv[1]).read(), re.M):
    v = int(w, 16)
    if (v & 0x7f) != 0x0b:
        continue
    if (v >> 25) != 0 or ((v >> 12) & 7) > 3:
        other += 1
        continue
    counts[(v >> 12) & 7] += 1
print("    custom-0 encodings in the image: " +
      ", ".join(f"{n}={c}" for n, c in zip(names, counts)))
if other:
    print(f"    WARNING: {other} custom-0 words that are NOT MBP (reserved funct7/funct3)")
sys.exit(0 if sum(counts) else 1)
PY
  info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")   cpus: $NCPU   iters: $ITERS"
else
  step "5/7  Zephyr build -- skipped by request"
  step "6/7  ELF gate -- skipped by request"
fi

# ---------------------------------------------------------------------------
step "7/7  manifest"
python3 - "$RUN" "$GEN" "$IR" "$MODEL" "$QUANT" "$TARGET" "$BOARD" "$KERNELS_INTEGER_ONLY" <<'PY'
import hashlib, json, os, re, sys
run, gen, ir, model, quant, target, board, integer_only = sys.argv[1:9]

def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest() if os.path.exists(p) else None

picks = {}
if os.path.exists(os.path.join(gen, 'kernel_picks.json')):
    picks = json.load(open(os.path.join(gen, 'kernel_picks.json'))).get('picks', {})
graph_ops = []
if os.path.exists(os.path.join(ir, 'graph.json')):
    graph_ops = sorted({o['op'] for o in json.load(open(os.path.join(ir, 'graph.json')))['ops']
                        if o.get('op') != 'view'})

icount = None
p = os.path.join(run, 'icount.json')
if os.path.exists(p):
    icount = json.load(open(p))

bitexact = os.path.join(run, 'bitexact.txt')
bitexact_pass = None
if os.path.exists(bitexact):
    bitexact_pass = 'RESULT: PASS' in open(bitexact).read()

mbp = {}
dis = os.path.join(run, 'zephyr.dis')
if os.path.exists(dis):
    names = ['dot8', 'max8', 'qmul', 'clip8']
    mbp = {n: 0 for n in names}
    for w in re.findall(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", open(dis).read(), re.M):
        v = int(w, 16)
        if (v & 0x7f) == 0x0b and (v >> 25) == 0 and ((v >> 12) & 7) < 4:
            mbp[names[(v >> 12) & 7]] += 1

out = {
    'board': board,
    'sample': 'samples/modelblaster_pext',
    'model': model,
    'quant': quant,
    'target': target,
    'isa_contract': 'fpga/pynq-z2/sw/pext.h',
    'curated_kernels': 'fpga/pynq-z2/modelblaster/kernels/pext',
    'bin_md5': md5(os.path.join(run, 'zephyr.bin')),
    'elf_md5': md5(os.path.join(run, 'zephyr.elf')),
    'kernel_sources': {k: f"{v.get('source')}/{v.get('algorithm')}" for k, v in sorted(picks.items())},
    'results': {
        'graph_ops': graph_ops,
        'all_ops_curated': bool(picks) and all(v.get('source') == 'curated' for v in picks.values()),
        'kernels_integer_only': integer_only == '1',
        'bit_exact_vs_scalar_reference': bitexact_pass,
        'static_mbp_instructions': mbp or None,
        'image_carries_mbp': (sum(mbp.values()) > 0) if mbp else None,
        'instructions_scalar': icount['total']['scalar'] if icount else None,
        'instructions_pext': icount['total']['pext'] if icount else None,
        'instruction_speedup_x100': int(round(icount['total']['speedup'] * 100)) if icount else None,
    },
}
if icount:
    out['per_dispatch_instructions'] = icount['per_dispatch']
    out['dynamic_mbp_mix'] = icount.get('dynamic_mbp_mix')
json.dump(out, open(os.path.join(run, 'run.json'), 'w'), indent=2)
print(f"    manifest: {os.path.join(run, 'run.json')}")
r = out['results']
if r['instruction_speedup_x100']:
    print(f"    LeNet int8: {r['instructions_scalar']:,} instructions on the scalar "
          f"reference kernels, {r['instructions_pext']:,} with MBP "
          f"-- {r['instruction_speedup_x100'] / 100:.2f}x, bit-exact")
PY

step "DONE -- checks and counts in $RUN (the board is deliberately not touched)"
