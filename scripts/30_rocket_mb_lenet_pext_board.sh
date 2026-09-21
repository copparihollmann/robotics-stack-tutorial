#!/usr/bin/env bash
# Lab B10 -- the MBP LeNet kernels of PEXT_KERNELS.md, on the P-ext silicon of
# PEXT_BITSTREAM.md, proved BIT-EXACT against the scalar baseline and TIMED against it:
#
#   modelblaster codegen x2 (scalar + pext, same IR)
#   -> west build x2 (chipyard_pynqz1_pext)  -> ELF gates
#   -> load pynqz1_rocket_pext.bit ONCE  -> run the MBP image  -> run the scalar image
#   -> compare the OUTPUT TENSOR element by element  -> cycles, wall time, speedup
#
# WHAT WAS MISSING BEFORE THIS SCRIPT, and what each half supplies.
#
#   scripts/28_rocket_modelblaster_pext.sh proves the kernels bit-exact ON THE HOST, against
#   pext.h's software model, and counts spike instructions (6,247,648 -> 419,490, 14.89x).
#   It deliberately never touches the board, because when it was written no bitstream
#   carried the extension.  One does now.  So the two things that could not be checked there
#   are checked here, and only here:
#
#     BIT-EXACTNESS ON SILICON.  The host result says pext.h's MODEL of the four
#     instructions gives the same answer as the scalar reference.  It says nothing about
#     whether the ROUTED ALU implements that model.  samples/pext_hart_proof answers that
#     for the instructions in isolation (3,041 checks); this answers it for a whole network
#     of them, which is a different question: it exercises the operand distributions a real
#     graph produces, the alignment the real kernels use, and 4,694 QMUL roundings on real
#     accumulators rather than on a test vector.
#
#     CYCLES.  PEXT_KERNELS.md section 4 says, twice, that no cycle count exists and that an
#     estimate of one would be an estimate.  This produces the measurement.  The
#     instruction-count speedup is 14.89x; the CYCLE speedup is a different number because
#     the CPI of the two instruction mixes differs, and THAT DIFFERENCE IS THE RESULT, not
#     an error.
#
# THE CLOCK.  This bitstream runs at 34.4828 MHz, the 40 MHz dual-core one at 40.000.  Every
# cycle count here is therefore directly comparable with a 40 MHz one and every WALL TIME is
# not.  Both forms are computed and both are reported; see section 5 of the manifest and
# PEXT_VALIDATION.md.  The clean number is the cycle ratio measured on THIS bitstream against
# THE SCALAR IMAGE RUN ON THE SAME BITSTREAM MINUTES APART, which is why this script runs
# both rather than quoting expected/modelblaster_lenet_int8.json's 40 MHz numbers.
#
# WHAT IT DOES NOT TOUCH.  expected/modelblaster_lenet_int8.json, out/rocket_mb_lenet_int8/,
# samples/modelblaster_hart_latency/ and scripts/24_rocket_modelblaster.sh are the scalar
# baseline this lab is measured against, and the comparison is only worth something if they
# are untouched.  The scalar image built here is that sample, unmodified, from the same
# IR -- only the BOARD argument differs, and that is the point.
#
# Produces, under out/<name>/:
#   model/scalar/{ir,gen}, model/pext/{ir,gen}   the two codegen trees
#   pext/   zephyr.{elf,bin,dis}, console.txt, console.stamps, isa.txt, build.log
#   scalar/ zephyr.{elf,bin,dis}, console.txt, isa.txt, build.log
#   boot.log        the PS-side bring-up transcript for both runs, incl. the FCLK readback
#   bitexact.txt    the element-by-element output comparison, in full
#   run.json        manifest: the tensors, the cycles, the speedups, both normalisations
#
# Usage:
#   scripts/with_board.sh ./scripts/30_rocket_mb_lenet_pext_board.sh
#   scripts/with_board.sh ./scripts/30_rocket_mb_lenet_pext_board.sh --no-bitstream
#   ./scripts/30_rocket_mb_lenet_pext_board.sh --build-only        # no board, no lock
#   scripts/with_board.sh ./scripts/30_rocket_mb_lenet_pext_board.sh --no-scalar
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# bitstream_identify: md5 of the .bit this run loads (and refusal of known-defective builds),
# the same identity every bandwidth lab records.  run.json takes the MAGIC from boot.log.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

MODEL="lenet"
QUANT="int8"
ITERS=11
NAME=""
BOARD="chipyard_pynqz1_pext"
SAMPLE_PEXT="$IISWC_ROOT/samples/modelblaster_pext"
SAMPLE_SCALAR="$IISWC_ROOT/samples/modelblaster_hart_latency"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_pext_z1/pynqz1_rocket_pext.bit"
LOAD_BIT=1
DO_BOARD=1
DO_SCALAR=1
SECONDS_READ=60
# The clock this bitstream is TIMED at, x1000 = the mtime rate the board Kconfig carries.
WANT_MTIME_HZ=34483
# The loader and the MAGIC it must find.  The defaults are this lab's own bitstream; the
# L2-miss-path lab (scripts/45_rocket_bwl2lab.sh, MEMORY_BANDWIDTH.md section 6) points them
# at run_rocket_bwl2.py and 0x5A5A000B-D to measure what an asynchronous tile crossing costs
# the SAME network.  --mtime-hz is for a bitstream whose uncore -- and so mtime and the UART
# divisor -- runs on a clock other than 34.4828 MHz: it adds a Kconfig fragment to both
# images and the gate below checks the built value against it.
RUNNER=run_rocket_pext.py
WANT_MAGIC=0x5A5A0004
# The 40 MHz scalar baseline, for the cross-bitstream comparison. Read from the golden
# file rather than retyped, so the two cannot drift.
BASELINE_EXPECT="$IISWC_ROOT/expected/modelblaster_lenet_int8.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --model)  MODEL="${2:?}";  shift 2 ;;
    --quant)  QUANT="${2:?}";  shift 2 ;;
    --iters)  ITERS="${2:?}";  shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --bit)    BIT="${2:?}";    shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only)   DO_BOARD=0; shift ;;
    --no-scalar)    DO_SCALAR=0; shift ;;
    --runner)   RUNNER="${2:?}"; shift 2 ;;
    --magic)    WANT_MAGIC="${2:?}"; shift 2 ;;
    --mtime-hz) WANT_MTIME_HZ="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,57p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
NAME="${NAME:-rocket_mb_${MODEL}_${QUANT}_pext_board}"
if [ "$WANT_MTIME_HZ" != 34483 ]; then
  mkdir -p "$IISWC_OUT/$NAME.conf"
  printf 'CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=%s\n' "$WANT_MTIME_HZ" > "$IISWC_OUT/$NAME.conf/uncore_clock.conf"
  export EXTRA_CONF_FILE="$IISWC_OUT/$NAME.conf/uncore_clock.conf"
fi

MB="$ZCS/modelblaster"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
PEXT_H="$IISWC_ROOT/fpga/pynq-z2/sw/pext.h"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB"
[ -d "$SAMPLE_PEXT" ] || die "no such sample: $SAMPLE_PEXT"
[ -d "$SAMPLE_SCALAR" ] || die "no such sample: $SAMPLE_SCALAR"
need_file "$PEXT_H" "the frozen ISA contract"
[ -d "$KERNELS/pext" ] || die "no curated pext kernels at $KERNELS/pext"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
rm -rf "$RUN"
mkdir -p "$RUN/pext" "$RUN/scalar"

# ---------------------------------------------------------------------------
step "1/8  modelblaster backend patch  (patches/0009-modelblaster-pext-backend.patch)"
# Idempotent, same reverse-check-first shape as 28_rocket_modelblaster_pext.sh: the
# submodule is a pinned, read-only input and the two edits the pext target needs live in
# patches/. Re-running is free.
MBPATCH="$IISWC_ROOT/patches/0009-modelblaster-pext-backend.patch"
need_file "$MBPATCH"
if ( cd "$MB" && git apply --reverse --check "$MBPATCH" ) >/dev/null 2>&1; then
  info "already applied to $MB"
elif ( cd "$MB" && git apply --check "$MBPATCH" ) >/dev/null 2>&1; then
  run git -C "$MB" apply "$MBPATCH"
  info "applied to $MB"
elif ( cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
raise SystemExit(0 if 'pext' in backends.BACKENDS else 1)" ) >/dev/null 2>&1; then
  # The same test scripts/44_rocket_vision_replay.sh uses: patches/0060 rewrites hunks of
  # 0009, so on a tree carrying both, 0009 neither applies nor reverse-applies -- and the
  # thing it installs, the `pext` backend, is present.  That is a property of the tree,
  # not of the patch's line numbers.
  info "0009 neither applies nor reverse-applies, but the pipeline has the pext backend"
  info "  (expected when a later patch has rewritten the same hunks -- 0060 over 0009)"
else
  die "patches/0009-modelblaster-pext-backend.patch neither applies nor is applied to
       $MB, and the pipeline has no pext backend -- the submodule has moved off its pin,
       or those two files were hand-edited."
fi

# ---------------------------------------------------------------------------
step "2/8  modelblaster codegen, TWICE from the same model  (scalar and pext)"
# Both trees come from the same extract_graph invocation parameters and a FRESH cache, for
# the two reasons 24_rocket_modelblaster.sh gives: the submodule stays a read-only input,
# and no stale cache entry can be swapped in behind a signature that has since changed.
#
# The only differences between the two are --fusion-target / --backend / --target, and
# --global-curated-dir on the pext side. That is checked below rather than asserted: the
# IR must be byte-identical and the baked golden must be byte-identical, or the two images
# are not running the same network and the comparison means nothing.
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
codegen () {  # $1 = target (scalar|pext)
  local t="$1" ir="$RUN/model/$1/ir" gen="$RUN/model/$1/gen" extra=()
  mkdir -p "$ir" "$gen" "$RUN/model/$1/cache"
  if [ "$t" = pext ]; then extra=(--global-curated-dir "$KERNELS"); fi
  ( cd "$ZCS" && python -m modelblaster.pipeline.extract_graph \
      --model "$MODEL" --out-dir "$ir" --quant "$QUANT" \
      --num-calibration 1 --fusion-target "$t" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "extract_graph ($t) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_skeleton \
      --ir "$ir/graph.json" --weights "$ir/weights.npz" --io "$ir/io.npz" \
      --out-dir "$gen" --backend "$t" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "generate_skeleton ($t) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_kernels \
      --ir "$ir/graph.json" --out-dir "$gen" --backend reference --target "$t" \
      --quant "$QUANT" --io "$ir/io.npz" --repo-root "$MB" \
      --build-dir "$RUN/model/$1/kverify" --harness-dir "$MB/harness" \
      --cache-dir "$RUN/model/$1/cache" --algorithms all "${extra[@]}" ) \
    >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "generate_kernels ($t) failed"; }
  need_file "$gen/kernels.c" "codegen ($t) produced no kernels"
  need_file "$gen/test_golden.bin" "codegen ($t) produced no golden"
}
run codegen scalar
run codegen pext
SGEN="$RUN/model/scalar/gen"; PGEN="$RUN/model/pext/gen"

# THE TWO BUILDS MUST BE THE SAME NETWORK. Checked, not assumed.
cmp -s "$RUN/model/scalar/ir/graph.json" "$RUN/model/pext/ir/graph.json" \
  || die "the scalar and pext IR differ -- these are two different networks and no
       comparison between them means anything"
cmp -s "$SGEN/test_golden.bin" "$PGEN/test_golden.bin" \
  || die "the two baked int8 goldens differ -- see above"
cmp -s "$SGEN/test_input.bin" "$PGEN/test_input.bin" || die "the two test inputs differ"
info "IR byte-identical, test_input.bin and test_golden.bin byte-identical"
info "ops: $(python3 -c "import json;print(','.join(sorted({o['op'] for o in json.load(open('$RUN/model/pext/ir/graph.json'))['ops'] if o['op']!='view'})))")"

# EVERY OP MUST BE CURATED ON THE PEXT SIDE, AND EVERY OP MUST BE REFERENCE ON THE SCALAR
# SIDE. A pext build in which an op quietly fell back to the scalar reference compiles,
# boots and gives the right answer while reporting a number that is not a measurement of
# the extension -- backends.py's own comments record that failure mode twice.
python3 - "$PGEN/kernel_picks.json" curated <<'PY' || die "not every pext op resolved to a curated kernel"
import json, sys
picks = json.load(open(sys.argv[1]))["picks"]
want = sys.argv[2]
bad = {k: v for k, v in picks.items() if v.get("source") != want}
for k, v in sorted(picks.items()):
    print(f"    {'ok  ' if k not in bad else 'FAIL'}  pext   {k:<16} {v.get('source')}/{v.get('algorithm')}")
sys.exit(1 if bad else 0)
PY
python3 - "$SGEN/kernel_picks.json" reference <<'PY' || die "a scalar op did not come from reference_kernels.py"
import json, sys
picks = json.load(open(sys.argv[1]))["picks"]
want = sys.argv[2]
bad = {k: v for k, v in picks.items() if v.get("source") != want}
for k, v in sorted(picks.items()):
    print(f"    {'ok  ' if k not in bad else 'FAIL'}  scalar {k:<16} {v.get('source')}/{v.get('algorithm')}")
sys.exit(1 if bad else 0)
PY

# The float scan both other labs run, for the same reason: 22 of the 43 `_s8` reference
# KernelSpecs dequantize to float internally, which on this WithoutFPU core is libgcc
# soft-float -- integer instructions, so no ELF check can see them.
INTEGER_ONLY=1
for g in "$SGEN" "$PGEN"; do
  F=$(grep -nE '(^|[^_[:alnum:]])(float|double)([^_[:alnum:]]|$)|\b(expf|roundf|sqrtf|logf|tanhf|powf|fabsf)\b' \
        "$g/kernels.c" | grep -v '^[0-9]*:#include' || true)
  if [ -n "$F" ]; then
    INTEGER_ONLY=0
    warn "$g/kernels.c contains floating point -- libgcc soft-float on this core:"
    printf '%s\n' "$F" | head -6 | sed 's/^/       /' >&2
  fi
done
if [ "$INTEGER_ONLY" = 1 ]; then info "both kernel sets are integer-only"; fi

# ---------------------------------------------------------------------------
step "3/8  build both images for $BOARD"
# BOARD_ROOT points at this repo: the board lives here, not in the west-managed zephyr
# checkout, so `west update` cannot clobber it.
MB_KERNEL_CFLAGS=$(cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
print(' '.join(backends.get('pext').resolved_kernel_cflags('$MB')))")
info "kernels.c cflags from Backend('pext'): ${MB_KERNEL_CFLAGS:-<none>}"
run west build -p always -b "$BOARD" "$SAMPLE_PEXT" -d "$RUN/pext/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$PGEN" -DMB_ITERS="$ITERS" \
    -DMODELBLASTER_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS" \
  > "$RUN/pext/build.log" 2>&1 \
  || { tail -40 "$RUN/pext/build.log"; die "pext build failed -- see $RUN/pext/build.log"; }
if [ "$DO_SCALAR" -eq 1 ]; then
  run west build -p always -b "$BOARD" "$SAMPLE_SCALAR" -d "$RUN/scalar/build" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$SGEN" -DMB_ITERS="$ITERS" \
    > "$RUN/scalar/build.log" 2>&1 \
    || { tail -40 "$RUN/scalar/build.log"; die "scalar build failed -- see $RUN/scalar/build.log"; }
fi

READELF="$(command -v riscv64-zephyr-elf-readelf || true)"
OBJDUMP="$(command -v riscv64-zephyr-elf-objdump || true)"
[ -n "$READELF" ] || die "riscv64-zephyr-elf-readelf not on PATH -- source env.sh"
[ -n "$OBJDUMP" ] || die "riscv64-zephyr-elf-objdump not on PATH -- source env.sh"

# $1 = pext|scalar, $2 = how many MBP encodings this image must carry (exact: 0 or >0)
gate () {
  local w="$1" want_mbp="$2" d="$RUN/$1" cfg="$RUN/$1/build/zephyr/.config"
  need_file "$d/build/zephyr/zephyr.bin" "$w build produced no raw image"
  cp "$d/build/zephyr/zephyr.elf" "$d/build/zephyr/zephyr.bin" "$d/"

  # THE CLOCK, checked on the BUILT image. CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC sets the
  # SiFive UART's baud divisor as well as the tick rate, so a mismatch here shows up as a
  # GARBLED console rather than a silent one -- FPGA_END_TO_END.md 4.1.
  local hz; hz=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$cfg" | cut -d= -f2)
  [ "${hz:-0}" = "$WANT_MTIME_HZ" ] || die "$w: CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$hz,
       expected $WANT_MTIME_HZ -- wrong board? (--board $BOARD)"
  local ncpu; ncpu=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$cfg" | cut -d= -f2)
  [ "${ncpu:-1}" -ge 2 ] || die "$w: CONFIG_MP_MAX_NUM_CPUS=$ncpu"
  grep -q '^CONFIG_SMP=y' "$cfg" || die "$w: CONFIG_SMP is not enabled"
  if grep -q '^CONFIG_FPU=y' "$cfg"; then die "$w: CONFIG_FPU=y against a WithoutFPU core"; fi
  if [ "$w" = pext ]; then
    grep -q '^CONFIG_MB_PEXT=y' "$cfg" || die "pext: CONFIG_MB_PEXT is not set -- this
       image would run pext.h's software model and measure nothing about the extension"
    grep -q '^CONFIG_SCHED_CPU_MASK=y' "$cfg" || die "pext: CONFIG_SCHED_CPU_MASK is off --
       k_thread_cpu_pin() would not exist, and pinning is the heterogeneity mechanism"
  else
    if grep -q '^CONFIG_MB_PEXT=y' "$cfg"; then
      die "scalar: CONFIG_MB_PEXT leaked into the baseline image -- it would no longer
       be a baseline"
    fi
  fi

  {
    "$READELF" -h "$d/zephyr.elf" | grep -E 'Entry point|Flags'
    "$READELF" -A "$d/zephyr.elf" | grep Tag_RISCV_arch
  } > "$d/isa.txt"
  grep -q 'soft-float ABI' "$d/isa.txt" || { cat "$d/isa.txt"; die "$w: not a soft-float ABI build"; }
  local arch; arch=$(grep Tag_RISCV_arch "$d/isa.txt" | sed 's/.*"\(.*\)".*/\1/')
  case "$arch" in
    *_f[0-9]*|*_d[0-9]*|*_v[0-9]*) die "$w: ELF advertises f/d/v: $arch" ;;
  esac
  "$OBJDUMP" -d "$d/zephyr.elf" > "$d/zephyr.dis"
  local fp; fp=$(grep -cE '^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]+(f(add|sub|mul|div|sqrt|mv|cvt|ld|sd|lw|sw|sgnj|min|max|eq|lt|le|class|madd|msub|nmadd|nmsub)|c\.f(ld|sd|lw|sw)|v(set|le|se|add|mul|mac))' \
        "$d/zephyr.dis" || true)
  [ "${fp:-0}" -eq 0 ] || die "$w: $fp float/vector instructions in the image"
  echo "    0 float/vector instructions in the disassembly" >> "$d/isa.txt"

  # THE ONLY EVIDENCE THE IMAGE CARRIES THE EXTENSION. `.insn` leaves no trace in
  # Tag_RISCV_arch, on purpose -- that is what keeps the exact rv64imac multilib match --
  # so the encodings are decoded out of the disassembly by hand against PEXT_SPEC.md 3.0:
  # opcode 0x0b, funct7 0, funct3 0..3.
  #
  # The SCALAR image is checked for EXACTLY ZERO of them, which is the half that makes the
  # baseline a baseline: an image that had picked up an MBP kernel would not be one.
  python3 - "$d/zephyr.dis" "$want_mbp" "$w" <<'PY' | tee -a "$d/isa.txt" || die "$w: MBP encoding count is wrong"
import re, sys
names = ["MBP.DOT8", "MBP.MAX8", "MBP.QMUL", "MBP.CLIP8"]
counts = [0, 0, 0, 0]
other = 0
for word in re.findall(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", open(sys.argv[1]).read(), re.M):
    v = int(word, 16)
    if (v & 0x7f) != 0x0b:
        continue
    if (v >> 25) != 0 or ((v >> 12) & 7) > 3:
        other += 1
        continue
    counts[(v >> 12) & 7] += 1
total = sum(counts)
want = sys.argv[2]
print(f"    {sys.argv[3]:<6} custom-0 encodings: " +
      ", ".join(f"{n}={c}" for n, c in zip(names, counts)) + f"   total {total}")
if other:
    print(f"    WARNING: {other} custom-0 words that are NOT MBP (reserved funct7/funct3)")
if want == "0":
    sys.exit(0 if total == 0 else 1)
sys.exit(0 if total > 0 else 1)
PY
  info "$w: bin $(fsize "$d/zephyr.bin")   elf $(fsize "$d/zephyr.elf")   mtime ${hz} Hz   cpus $ncpu"
}
gate pext nonzero
if [ "$DO_SCALAR" -eq 1 ]; then gate scalar 0; fi

if [ "$DO_BOARD" -eq 0 ]; then
  step "BUILD ONLY -- images at $RUN/pext/zephyr.bin and $RUN/scalar/zephyr.bin"
  exit 0
fi

# ---------------------------------------------------------------------------
step "4/8  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"

# ---------------------------------------------------------------------------
step "5/8  load the P-ext PL and hold the SoC in reset"
if [ "$LOAD_BIT" -eq 1 ]; then
  # Present AND the file this repo ships: fpga/pynq-z2/bitstreams.csv holds the md5, and
  # $IISWC_BIT_DIR / /opt/iiswc/bit are searched when it is not in the checkout. The old
  # need_file here said "build it with build_*_z1.sh", which no attendee is going to do.
  BIT="$(bitstream_require "$BIT")"
  bitstream_identify "$BIT"
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD_ARGS="--bitstream $(basename "$BIT") --hold"
else
  bitstream_identify ""
  HOLD_ARGS="--no-load --hold"
fi
# Diagnose a MAGIC mismatch BEFORE retrying with a password, or the real cause ends up
# buried under a sudo fallback.
wrong_pl () {
  if grep -q 'MAGIC = 0x5A5A0003' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the plain DUAL-CORE bitstream is loaded (MAGIC 0x5A5A0003). It has no MBP unit on
       either hart, so the MBP kernels would take an illegal-instruction trap on hart 0 --
       which looks exactly like the heterogeneity claim failing. Re-run without
       --no-bitstream, or load $BIT."
  fi
  if grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log"; then
    cat "$RUN/boot.log"; die "the SINGLE-core bitstream is loaded (MAGIC 0x5A5A0002)."
  fi
  if grep -q 'MAGIC = 0x5A5A0001' "$RUN/boot.log"; then
    cat "$RUN/boot.log"; die "the DRAM self-test bitstream is loaded (MAGIC 0x5A5A0001)."
  fi
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u $RUNNER $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "P-ext bitstream not reachable over GP0"
}
grep -E 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true
info "P-ext PL loaded, SoC held in reset"

# $1 = pext|scalar, $2 = the guest's terminating line. The console reader starts BEFORE the
# core: the SiFive UART's TX FIFO is 8 bytes deep, so a late reader loses the banner.
# --stamps gives host-clock timing, which is the only measurement that assumes nothing
# about CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC (PEXT_BITSTREAM.md section 5).
boot_and_read () {
  local w="$1" done_line="$2" d="$RUN/$1"
  run scp -q "$d/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
  local lmd5 rmd5
  lmd5=$(md5sum "$d/zephyr.bin" | cut -d' ' -f1)
  rmd5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
  [ "$lmd5" = "$rmd5" ] || die "$w: zephyr.bin corrupted in transfer"
  info "$w: md5 verified $lmd5"
  "${SSH[@]}" "bash -lc '
    cd $PYNQ_DIR
    rm -f console.out console.stamps
    nohup python3 -u console.py --seconds $SECONDS_READ --stamps console.stamps > console.out 2>/dev/null &
    CPID=\$!
    sleep 1.5
    echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
    for i in \$(seq 1 $SECONDS_READ); do
      grep -q \"$done_line\" console.out 2>/dev/null && break
      sleep 1
    done
    kill \$CPID 2>/dev/null
    wait \$CPID 2>/dev/null
  '" >> "$RUN/boot.log" 2>&1 || true
  "${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$d/console.txt" 2>/dev/null || true
  "${SSH[@]}" "cat $PYNQ_DIR/console.stamps" > "$d/console.stamps" 2>/dev/null || true
  [ -s "$d/console.txt" ] || { grep -E 'STATUS|saw_mem' "$RUN/boot.log" | tail -6 || true
    die "$w: the SoC produced no console output -- see $RUN/boot.log"; }
  grep -q '\*\*\* Booting Zephyr OS' "$d/console.txt" \
    || { cat "$d/console.txt"; die "$w: the SoC did not boot -- see $RUN/boot.log"; }
}

# ---------------------------------------------------------------------------
step "6/8  run the MBP image on hart 0"
boot_and_read pext 'RESULT:'
printf '%s\n' "----------------------------------------------------------------"
grep -vE '^MB_PEXT_OP ' "$RUN/pext/console.txt"
printf '%s\n' "----------------------------------------------------------------"

# ---------------------------------------------------------------------------
if [ "$DO_SCALAR" -eq 1 ]; then
  step "7/8  run the SCALAR image on the same bitstream, same session"
  # samples/modelblaster_hart_latency, unmodified, from the same IR. Only the --board
  # differs from Lab B5. This is what makes the speedup a same-silicon, same-clock
  # measurement rather than a comparison across two bitstreams and two clocks.
  boot_and_read scalar 'RESULT:'
  printf '%s\n' "----------------------------------------------------------------"
  grep -vE '^MB_ITER ' "$RUN/scalar/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
else
  step "7/8  scalar run -- skipped by request (--no-scalar)"
fi

# ---------------------------------------------------------------------------
step "8/8  bit-exactness, cycles and the manifest"
python3 - "$RUN" "$SGEN" "$PGEN" "$RUN/model/pext/ir" "$MODEL" "$QUANT" "$BOARD" \
         "$ITERS" "$WANT_MTIME_HZ" "$BASELINE_EXPECT" "$INTEGER_ONLY" \
         "$BIT" "$LOAD_BIT" "$BIT_MD5" "$WANT_MAGIC" "$IISWC_ROOT" <<'PY' | tee "$RUN/bitexact.txt"
import hashlib, json, os, re, statistics, sys
run, sgen, pgen, ir, model, quant, board, iters, want_hz, baseline, integer_only = sys.argv[1:12]
bit_path, load_bit, bit_md5, want_magic, root = sys.argv[12:17]
iters = int(iters)
want_hz = int(want_hz)

def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest() if os.path.exists(p) else None

def read(p):
    return open(p).read() if os.path.exists(p) else ''

def kv(line):
    return dict(re.findall(r'(\w+)=([^\s]+)', line))

ptxt = read(os.path.join(run, 'pext', 'console.txt'))
stxt = read(os.path.join(run, 'scalar', 'console.txt'))
boot = read(os.path.join(run, 'boot.log'))

# --- the clock, from OUTSIDE the SoC ------------------------------------------------
# zynq_preflight reads SLCR FPGA0_CLK_CTRL and IO_PLL_CTRL on the PS. It is the authority:
# nothing the guest computes from mtime can contradict it without being circular.
m = re.search(r'FCLK0_HZ = (\d+)', boot)
fclk_hz = int(m.group(1)) if m else None
core_hz = fclk_hz or want_hz * 1000

# =====================================================================================
# 1. BIT-EXACTNESS. The OUTPUT TENSOR, element by element, not a checksum.
# =====================================================================================
golden = list(open(os.path.join(sgen, 'test_golden.bin'), 'rb').read())
golden = [g - 256 if g > 127 else g for g in golden]          # int8
pgolden = list(open(os.path.join(pgen, 'test_golden.bin'), 'rb').read())
pgolden = [g - 256 if g > 127 else g for g in pgolden]

# What the MBP kernels actually produced ON THE BOARD, printed element by element by
# samples/modelblaster_pext (MB_PEXT_OUT).
mline = next((l for l in ptxt.splitlines() if l.startswith('MB_PEXT_OUT')), None)
hw = [int(x) for x in mline.split()[1:]] if mline else []

deltas = [h - g for h, g in zip(hw, golden)] if len(hw) == len(golden) else None
max_abs_err = max((abs(d) for d in deltas), default=None) if deltas is not None else None

print("=== 1. the output tensor, element by element ===")
print(f"    scalar golden (model/scalar/gen/test_golden.bin) : {golden}")
print(f"    MBP on hardware  (MB_PEXT_OUT, hart 0)           : {hw}")
if deltas is None:
    print(f"    FAIL: got {len(hw)} elements, expected {len(golden)}")
else:
    print(f"    delta                                            : {deltas}")
    print(f"    max_abs_err = {max_abs_err}   ({'BIT-EXACT' if max_abs_err == 0 else 'MISMATCH'})")
print(f"    the two codegen goldens are identical            : {golden == pgolden}")

# The guest's own verdict, computed on the board against the baked golden in ITS image.
prun = kv(next((l for l in ptxt.splitlines() if l.startswith('MB_PEXT_RUN')), ''))
guest_err = int(prun.get('max_abs_err', -1))
print(f"    the guest's own max_abs_err (on the board)        : {guest_err}")

# The scalar side of the chain. samples/modelblaster_hart_latency does not print its
# tensor, so the equality "MBP output == scalar output" is established transitively:
# scalar_hw == golden (max_abs_err 0 on BOTH harts, and the two harts byte-identical to
# each other) and MBP_hw == golden element by element, above.
sver = kv(next((l for l in stxt.splitlines() if l.startswith('MB_VERIFY')), ''))
print("\n=== the chain, since the scalar sample prints no tensor ===")
print(f"    scalar hart0 vs golden : max_abs_err={sver.get('hart0_max_abs_err')}")
print(f"    scalar hart1 vs golden : max_abs_err={sver.get('hart1_max_abs_err')}")
print(f"    scalar hart0 == hart1  : {sver.get('outputs_identical')}")
print(f"    MBP hart0 vs golden    : max_abs_err={max_abs_err}  (element by element, above)")

# =====================================================================================
# 2. CYCLES
# =====================================================================================
def ms(c):
    return round(c * 1000.0 / core_hz, 3) if (core_hz and c) else None

pext_cyc = int(prun['median']) if 'median' in prun else None
pext_min = int(prun['min']) if 'min' in prun else None
pext_max = int(prun['max']) if 'max' in prun else None
pext_warm = int(prun['warm']) if 'warm' in prun else None

sharts = {}
for line in stxt.splitlines():
    if line.startswith('MB_HART ') and 'NEVER_RAN' not in line:
        d = kv(line)
        sharts[int(d['cpu'])] = {k: int(v) for k, v in d.items()}
siters = {}
for line in stxt.splitlines():
    if line.startswith('MB_ITER '):
        d = kv(line)
        siters.setdefault(int(d['cpu']), []).append(int(d['cycles']))
scal0 = sharts.get(0, {}).get('median')
scal1 = sharts.get(1, {}).get('median')

# The 40 MHz baseline, read out of the golden file rather than retyped.
base = json.load(open(baseline)).get('_measured', {})
base0 = base.get('hart0_big_median_cycles', [None])[-1]
base1 = base.get('hart1_little_median_cycles', [None])[-1]
BASE_HZ = 40_000_000

def spread_pct(v):
    if not v:
        return None
    med = statistics.median(v)
    return round((max(v) - min(v)) * 100.0 / med, 3) if med else None

def ratio(a, b):
    return round(a / b, 3) if (a and b) else None

print("\n=== 2. cycles, wall time and speedup ===")
print(f"    core clock, read from the PS SLCR : {core_hz} Hz ({core_hz/1e6:.4f} MHz)")
print()
print(f"    {'':<46}{'cycles':>12}  {'ms':>9}")
if scal0:
    print(f"    {'scalar LeNet, hart 0, THIS bitstream':<46}{scal0:>12,}  {ms(scal0):>9}")
if scal1:
    print(f"    {'scalar LeNet, hart 1, THIS bitstream':<46}{scal1:>12,}  {ms(scal1):>9}")
if pext_cyc:
    print(f"    {'MBP LeNet,    hart 0, THIS bitstream':<46}{pext_cyc:>12,}  {ms(pext_cyc):>9}")
print(f"    {'scalar LeNet, hart 0, 40 MHz baseline':<46}{base0:>12,}  "
      f"{round(base0*1000.0/BASE_HZ,3):>9}")

# THE CLEAN NUMBER: both runs on the same silicon at the same clock, minutes apart. A
# cycle ratio is clock-free by construction, so this needs no normalisation at all.
cyc_speedup_same = ratio(scal0, pext_cyc)
# Across bitstreams: the same quantity computed against the 40 MHz baseline's CYCLES.
# Also clock-free -- which is why it should agree with the line above.
cyc_speedup_base = ratio(base0, pext_cyc)
# WALL TIME, raw: 216.504 ms measured at 40 MHz against this run measured at 34.4828 MHz.
# This one DOES carry the clock difference, and is the number not to quote on its own.
wall_speedup_raw = ratio(base0 * 1000.0 / BASE_HZ, ms(pext_cyc))
# WALL TIME, normalised: what the MBP run would have taken had this bitstream closed at
# 40 MHz. Equal to the cycle ratio by construction; stated so the two forms can be
# compared directly rather than argued about.
pext_ms_at_40 = round(pext_cyc * 1000.0 / BASE_HZ, 3) if pext_cyc else None

print()
print(f"    cycle speedup, same bitstream, same clock     : {cyc_speedup_same}x")
print(f"    cycle speedup vs the 40 MHz scalar baseline   : {cyc_speedup_base}x")
print(f"    wall-clock speedup, RAW (34.48 vs 40 MHz)     : {wall_speedup_raw}x"
      f"   <- carries the clock difference, do not quote alone")
print(f"    MBP LeNet normalised to 40 MHz                : {pext_ms_at_40} ms"
      f"   (vs {round(base0*1000.0/BASE_HZ,3)} ms scalar)")
print(f"    instruction speedup (spike, PEXT_KERNELS.md)  : 14.89x")
if cyc_speedup_same:
    print(f"    CPI ratio implied (insn speedup / cycle speedup): "
          f"{round(14.89 / cyc_speedup_same, 3)}  -- the MBP mix costs this much more per "
          f"instruction")

# =====================================================================================
# 3. manifest
# =====================================================================================
pops = []
for line in ptxt.splitlines():
    if line.startswith('MB_PEXT_OP '):
        d = kv(line)
        pops.append({'id': int(d['id']), 'name': d['name'], 'op': d['op'],
                     'shape': d['shape'], 'cycles': int(d['cycles'])})
sops = {}
for line in stxt.splitlines():
    if line.startswith('MB_OP '):
        d = kv(line)
        sops.setdefault(int(d['cpu']), []).append(
            {'id': int(d['id']), 'name': d['name'], 'op': d['op'],
             'shape': d['shape'], 'cycles': int(d['cycles'])})

per_op = []
for p in pops:
    s = next((x for x in sops.get(0, []) if x['id'] == p['id']), None)
    per_op.append({'name': p['name'], 'op': p['op'], 'shape': p['shape'],
                   'scalar_cycles': s['cycles'] if s else None,
                   'pext_cycles': p['cycles'],
                   'speedup': ratio(s['cycles'], p['cycles']) if s else None})

neg = kv(next((l for l in ptxt.splitlines() if l.startswith('MB_PEXT_NEG cpu=')), ''))
pbuild = kv(next((l for l in ptxt.splitlines() if l.startswith('MB_PEXT_BUILD model=')), ''))
schecks = dict(re.findall(r'(\w+)=([01])\b',
               next((l for l in stxt.splitlines() if l.startswith('CHECKS')), '')))
sratio = kv(next((l for l in stxt.splitlines() if l.startswith('MB_RATIO ')), ''))
smdl = kv(next((l for l in stxt.splitlines() if l.startswith('MB_MODEL ')), ''))

graph_ops = sorted({o['op'] for o in json.load(open(os.path.join(ir, 'graph.json')))['ops']
                    if o.get('op') != 'view'})
ppicks = json.load(open(os.path.join(pgen, 'kernel_picks.json')))['picks']
spicks = json.load(open(os.path.join(sgen, 'kernel_picks.json')))['picks']

def mbp_counts(dis):
    names = ['dot8', 'max8', 'qmul', 'clip8']
    c = {n: 0 for n in names}
    for word in re.findall(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", read(dis), re.M):
        v = int(word, 16)
        if (v & 0x7f) == 0x0b and (v >> 25) == 0 and ((v >> 12) & 7) < 4:
            c[names[(v >> 12) & 7]] += 1
    return c

pmbp = mbp_counts(os.path.join(run, 'pext', 'zephyr.dis'))
smbp = mbp_counts(os.path.join(run, 'scalar', 'zephyr.dis'))

manifest = {
    'board': board,
    # Identity of the silicon actually measured.  Until 2026-09-17 these two fields were the
    # literals of Lab B10's own bitstream (the pext build, 0x5A5A0004) whatever --bit/--magic
    # said, so LeNet records from scripts/45 on 0x5A5A0007/000D/001A misnamed their bitstream
    # (bwlab/errata.csv).  Now: the path and md5 of the .bit this run loaded (bitstream_identify,
    # as the bandwidth labs record it), and the MAGIC read back over GP0 in boot.log.
    'bitstream': (os.path.relpath(bit_path, root) if load_bit == '1' else None),
    'bitstream_md5': bit_md5,
    'bitstream_loaded_per_boot_log': (re.search(r'loaded (\S+\.bit)', boot) or [None, None])[1],
    'magic': (re.search(r'MAGIC = (0x[0-9A-Fa-f]+) OK', boot) or [None, None])[1],
    'magic_expected': want_magic,
    'model': model,
    'quant': quant,
    'iters': iters,
    'isa_contract': 'fpga/pynq-z2/sw/pext.h',
    'pext_bin_md5': md5(os.path.join(run, 'pext', 'zephyr.bin')),
    'scalar_bin_md5': md5(os.path.join(run, 'scalar', 'zephyr.bin')),
    'kernel_sources': {
        'pext': {k: f"{v.get('source')}/{v.get('algorithm')}" for k, v in sorted(ppicks.items())},
        'scalar': {k: f"{v.get('source')}/{v.get('algorithm')}" for k, v in sorted(spicks.items())},
    },
    'static_mbp_instructions': {'pext': pmbp, 'scalar': smbp},
    'tensors': {
        'scalar_golden': golden,
        'pext_on_hardware': hw,
        'delta': deltas,
    },
    'measured': {
        'core_hz_from_ps_slcr': fclk_hz,
        'sys_clock_hw_cycles_per_sec': want_hz,
        'pext_hart0': {'median_cycles': pext_cyc, 'min_cycles': pext_min,
                       'max_cycles': pext_max, 'cold_cycles': pext_warm,
                       'median_ms': ms(pext_cyc),
                       'median_ms_normalised_to_40mhz': pext_ms_at_40},
        'scalar_hart0': {'median_cycles': scal0, 'median_ms': ms(scal0),
                         'spread_pct_of_median': spread_pct(siters.get(0, []))},
        'scalar_hart1': {'median_cycles': scal1, 'median_ms': ms(scal1),
                         'spread_pct_of_median': spread_pct(siters.get(1, []))},
        'baseline_40mhz_hart0_cycles': base0,
        'baseline_40mhz_hart1_cycles': base1,
        'baseline_40mhz_hart0_ms': round(base0 * 1000.0 / BASE_HZ, 3) if base0 else None,
        'cycle_speedup_same_bitstream': cyc_speedup_same,
        'cycle_speedup_vs_40mhz_baseline': cyc_speedup_base,
        'wall_speedup_raw_vs_40mhz_baseline': wall_speedup_raw,
        'instruction_speedup_spike': 14.89,
        'cpi_ratio_pext_over_scalar': round(14.89 / cyc_speedup_same, 3) if cyc_speedup_same else None,
        'per_op': per_op,
        'scalar_little_over_big_x100': int(sratio.get('little_over_big_x100', 0) or 0),
    },
    'pext_console_lines': ptxt.splitlines(),
    'scalar_console_lines': stxt.splitlines(),

    # --- checked against expected/modelblaster_lenet_int8_pext.json -------------------
    'results': {
        'booted': '*** Booting Zephyr OS' in ptxt,
        'model': pbuild.get('model'),
        'graph_ops': graph_ops,
        'ir_identical_scalar_vs_pext': True,   # cmp'd in stage 2, or the script died
        'golden_identical_scalar_vs_pext': golden == pgolden,
        'pext_kernels_all_curated': all(v.get('source') == 'curated' for v in ppicks.values()),
        'scalar_kernels_all_reference': all(v.get('source') == 'reference' for v in spicks.values()),
        'kernels_integer_only': integer_only == '1',
        'pext_image_carries_mbp': sum(pmbp.values()) > 0,
        'scalar_image_carries_no_mbp': sum(smbp.values()) == 0,
        'mb_pext_hw': int(pbuild.get('hw', -1)),
        'output_len': len(hw),
        # THE HEADLINE. The output tensor the routed MBP ALU produced on the board,
        # against the scalar reference's baked golden, element by element.
        'max_abs_err_vs_scalar_golden': max_abs_err,
        'guest_reported_max_abs_err': guest_err,
        'scalar_hart0_max_abs_err': int(sver.get('hart0_max_abs_err', -1)) if sver else None,
        'scalar_hart1_max_abs_err': int(sver.get('hart1_max_abs_err', -1)) if sver else None,
        'scalar_outputs_identical': (sver.get('outputs_identical') == '1') if sver else None,
        # the heterogeneity half, from the same run
        'pext_ran_on_hart': int(prun.get('mhartid', -1)),
        'negative_test_trapped': neg.get('trapped') == '1',
        'negative_test_mcause': int(neg.get('mcause', -1)) if neg else None,
        'negative_test_hart': int(neg.get('mhartid', -1)) if neg else None,
        'result_pass': 'RESULT: PASS' in ptxt,
        'scalar_result_pass': 'RESULT: PASS' in stxt,
        'dispatches_profiled': len([l for l in ptxt.splitlines() if l.startswith('MB_PEXT_OP ')]),
        'cycle_speedup_same_bitstream': cyc_speedup_same,
    },
    # --- the scalar half, in scripts/24_rocket_modelblaster.sh's own manifest shape, so
    # --- it can be checked against the UNMODIFIED expected/modelblaster_lenet_int8.json
    'results_scalar': {
        'booted': '*** Booting Zephyr OS' in stxt,
        'model': smdl.get('name'),
        'quant': smdl.get('quant'),
        'op_count': int(smdl.get('ops', 0) or 0),
        'graph_ops': graph_ops,
        'kernel_sources_all_reference': all(v.get('source') == 'reference' for v in spicks.values()),
        'kernels_integer_only': integer_only == '1',
        'harts_observed': sorted(d.get('mhartid') for d in sharts.values()),
        'iterations_per_hart': sorted({len(v) for v in siters.values()}),
        'hart0_max_abs_err': int(sver.get('hart0_max_abs_err', -1)) if sver else None,
        'hart1_max_abs_err': int(sver.get('hart1_max_abs_err', -1)) if sver else None,
        'outputs_identical': (sver.get('outputs_identical') == '1') if sver else None,
        'both_harts': schecks.get('both_harts') == '1',
        'distinct_harts': schecks.get('distinct_harts') == '1',
        'result_pass': 'RESULT: PASS' in stxt,
        'little_over_big_x100': int(sratio.get('little_over_big_x100', 0) or 0),
        'max_spread_pct_of_median': max(
            [x for x in (spread_pct(siters.get(0, [])), spread_pct(siters.get(1, [])))
             if x is not None] or [None]),
    },
}
json.dump(manifest, open(os.path.join(run, 'run.json'), 'w'), indent=2)
print(f"\n    manifest: {os.path.join(run, 'run.json')}")
print("\n=== 4. per-kernel, same bitstream ===")
print(f"    {'dispatch':<8} {'op':<14} {'shape':<26} {'scalar':>11} {'pext':>11}  speedup")
for r in per_op:
    sc = f"{r['scalar_cycles']:,}" if r['scalar_cycles'] else '-'
    print(f"    {r['name']:<8} {r['op']:<14} {r['shape']:<26} {sc:>11} "
          f"{r['pext_cycles']:>11,}  {r['speedup']}x")
PY

# The verdict, loud, before the golden check.
python3 - "$RUN/run.json" <<'PY' || die "BIT-EXACTNESS FAILED ON HARDWARE -- see $RUN/bitexact.txt"
import json, sys
r = json.load(open(sys.argv[1]))["results"]
e = r["max_abs_err_vs_scalar_golden"]
if e == 0:
    print("\n    \033[1;32mmax_abs_err = 0\033[0m  the MBP kernels reproduce the scalar "
          "output tensor exactly, on silicon")
    sys.exit(0)
print(f"\n    \033[1;31mmax_abs_err = {e}\033[0m  THE ROUTED ALU DISAGREES WITH THE SCALAR "
      "REFERENCE. This is a hardware finding, not a tolerance to loosen: "
      "fpga/pynq-z2/sw/pext.h is the frozen contract and the host run is bit-exact "
      "against it.")
sys.exit(1)
PY

EXPECT="$IISWC_ROOT/expected/modelblaster_${MODEL}_${QUANT}_pext.json"
if [ -f "$EXPECT" ]; then
  step "check  (vs $(basename "$EXPECT"))"
  python3 - "$RUN/run.json" "$EXPECT" results <<'PYCHECK' || die "golden check failed"
import json, sys
got = json.load(open(sys.argv[1]))[sys.argv[3]]
exp = json.load(open(sys.argv[2]))
bad = 0
for k, want in exp.items():
    if k.startswith("_"):
        continue
    have = got.get(k)
    if isinstance(want, dict) and ("min" in want or "max" in want):
        ok = have is not None and (("min" not in want) or have >= want["min"]) \
             and (("max" not in want) or have <= want["max"])
        shown = f"[{want.get('min','-inf')} .. {want.get('max','inf')}]"
    else:
        ok = have == want
        shown = repr(want)
    if not ok:
        bad += 1
    print(f"    {'ok  ' if ok else 'FAIL'}  {k:<34} expected {shown}   got {have!r}")
sys.exit(1 if bad else 0)
PYCHECK
fi

# THE REGRESSION THAT COSTS NOTHING AND SAYS THE MOST: the scalar baseline's OWN golden
# file, written for the 40 MHz dual-core bitstream, checked unchanged against the scalar
# image run here at 34.4828 MHz. Everything in it is either structural or a cycle RATIO,
# so it must pass -- and if it does not, the P-ext bitstream has changed something about
# the plain dual-core path.
if [ "$DO_SCALAR" -eq 1 ] && [ -f "$BASELINE_EXPECT" ]; then
  step "check  (the scalar baseline's own golden, unmodified, on this bitstream)"
  python3 - "$RUN/run.json" "$BASELINE_EXPECT" results_scalar <<'PYCHECK' || die "the scalar baseline no longer reproduces on this bitstream"
import json, sys
got = json.load(open(sys.argv[1]))[sys.argv[3]]
exp = json.load(open(sys.argv[2]))
bad = 0
for k, want in exp.items():
    if k.startswith("_"):
        continue
    have = got.get(k)
    if isinstance(want, dict) and ("min" in want or "max" in want):
        ok = have is not None and (("min" not in want) or have >= want["min"]) \
             and (("max" not in want) or have <= want["max"])
        shown = f"[{want.get('min','-inf')} .. {want.get('max','inf')}]"
    else:
        ok = have == want
        shown = repr(want)
    if not ok:
        bad += 1
    print(f"    {'ok  ' if ok else 'FAIL'}  {k:<34} expected {shown}   got {have!r}")
sys.exit(1 if bad else 0)
PYCHECK
fi

step "LENET IS BIT-EXACT ON THE P-EXT SILICON -- see $RUN/run.json and $RUN/bitexact.txt"
