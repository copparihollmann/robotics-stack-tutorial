#!/usr/bin/env bash
# Lab B5 -- take a PyTorch network through ModelBlaster's quantize + codegen pipeline,
# build it for the dual-core big.LITTLE Rocket, and measure its inference latency on
# EACH HART IN TURN (never both at once):
#
#   extract_graph (int8 PTQ)  ->  generate_skeleton  ->  generate_kernels
#   ->  west build (chipyard_pynqz1_smp)  ->  ELF ISA gate  ->  scp zephyr.bin
#   ->  PS writes DDR  ->  release reset  ->  pulse custom_boot  ->  /dev/ttyPS1
#
# Same shape as 22_rocket_smp_run.sh, which it deliberately does not modify. The
# differences are all consequences of running a real network rather than a proof:
#
#   * a codegen stage in front       modelblaster turns models/<name>.py into C
#   * an ELF ISA gate                this SoC is rv64imac -- WithoutFPU, no V, no
#                                    Gemmini -- so an image carrying f/d/v traps as
#                                    illegal on the board. That is caught here, on the
#                                    host, by reading the built ELF's own attributes.
#   * a latency golden check         structural facts and the big/LITTLE ratio, not
#                                    raw cycle counts (see expected/*.json for why)
#
# WHY SCALAR INTEGER IS THE ONLY OPTION. The generated DTS reports
# riscv,isa = "rv64imaczicsr_zifencei_zihpm_xrocket" for both harts: no F, no D, no V.
# Rocket's FPU measured 13,878 LUT and does not fit on an XC7Z020 next to everything
# else, so `WithoutFPU` is in the Chipyard config and propagates all the way here. Any
# fp32/fp16 path compiles to libgcc soft-float calls (__muldf3, __subdf3, ...) that
# would dominate the measurement. So: int8 PTQ weights/activations, int32 accumulate,
# the `scalar` ModelBlaster backend, and an integer-only Zephyr app.
#
# NOTE ON cores/*.json. ModelBlaster's stock scalar core descriptions advertise
# "isa": "rv64imafdc", which has F and D this SoC does not have. That string is
# DOCUMENTATION ONLY -- pipeline/core_registry.py stores it in Core.isa and nothing
# reads it; kernel selection keys off Backend.name/target_affinity and codegen flags
# come from Backend.kernel_cflags. A matching description is kept at
# fpga/pynq-z2/modelblaster/chipyard_pynqz1_rocket_biglittle.json for the registry-
# driven (XPU-RT) path; it is not on this script's critical path. See
# fpga/pynq-z2/docs/MODELBLASTER_ON_ROCKET.md.
#
# Produces, under out/<name>/:
#   model/ir/, model/gen/    the ModelBlaster IR and the generated C
#   zephyr.elf / zephyr.bin  the guest
#   console.txt              what the SoC printed
#   boot.log                 the PS-side bring-up transcript
#   isa.txt                  the ELF attribute gate's evidence
#   run.json                 manifest, including per-hart latency
#
# Usage:
#   scripts/with_board.sh ./scripts/24_rocket_modelblaster.sh
#   ./scripts/24_rocket_modelblaster.sh --build-only        # no board, no lock needed
#   scripts/with_board.sh ./scripts/24_rocket_modelblaster.sh --no-build
#   scripts/with_board.sh ./scripts/24_rocket_modelblaster.sh --model mlp_generic --iters 21
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODEL="lenet"
QUANT="int8"
TARGET="scalar"
ITERS=11
NAME=""
BOARD="chipyard_pynqz1_smp"
SAMPLE="$IISWC_ROOT/samples/modelblaster_hart_latency"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_smp_z1/pynqz1_rocket_smp.bit"
LOAD_BIT=1
DO_BUILD=1
DO_BOARD=1
SECONDS_READ=45
EXPECT_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model)  MODEL="${2:?}";  shift 2 ;;
    --quant)  QUANT="${2:?}";  shift 2 ;;
    --target) TARGET="${2:?}"; shift 2 ;;
    --iters)  ITERS="${2:?}";  shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --expected) EXPECT_NAME="${2:?}"; shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only)   DO_BOARD=0; shift ;;
    --no-build)     DO_BUILD=0; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
NAME="${NAME:-rocket_mb_${MODEL}_${QUANT}}"
EXPECT_NAME="${EXPECT_NAME:-modelblaster_${MODEL}_${QUANT}}"

MB="$ZCS/modelblaster"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB"
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
BUILD="$RUN/build"
IR="$RUN/model/ir"
GEN="$RUN/model/gen"

if [ "$DO_BUILD" -eq 1 ]; then
  rm -rf "$RUN"
fi
mkdir -p "$RUN"

if [ "$DO_BUILD" -eq 1 ]; then
  command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"
  mkdir -p "$IR" "$GEN" "$RUN/model/cache"

  step "1/6  modelblaster codegen  (model=$MODEL quant=$QUANT target=$TARGET)"
  # Run the three codegen stages directly rather than through
  # modelblaster/examples/<model>/run.sh. Two reasons, both load-bearing:
  #
  #  * run.sh writes its IR, generated C and kernel cache INSIDE the modelblaster
  #    submodule. Everything this lab produces belongs under out/, so the submodule
  #    stays a read-only input.
  #  * --cache-dir points at a FRESH directory under out/. The shipped per-model
  #    cache is keyed only by <target>_<op>_<algo> and is not re-checked against the
  #    current KernelSpec signature, so a cache entry written before an argument was
  #    added to an op still gets swapped in. lenet/int8/cache/scalar's
  #    maxpool2d_s8_direct predates PH/PW/DH/DW and produces a 10-argument definition
  #    against a 14-argument declaration -- a hard compile error, which is the good
  #    case, but only because C caught it. A fresh cache means every kernel here comes
  #    from reference_kernels.py, which is the pipeline's own trusted oracle.
  #
  # There is no curated kernel directory for the scalar target at all
  # (modelblaster/kernels/ has rvv*, gemmini*, ime -- no scalar/), and no
  # AlgorithmCandidate in reference_kernels.py carries target_affinity=("scalar",).
  # So on this backend "reference" is not a fallback from something better; it is the
  # only implementation that exists. The cwd-relative-include bug fixed by ae2c212 on
  # origin/feat/split-linear-along-m demotes CURATED kernels to the reference seed via
  # -I<repo_root>/kernels/rvv; the scalar backend carries no kernel_cflags and no
  # curated dir, so that fix cannot change anything here.
  export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
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
      --cache-dir "$RUN/model/cache" --algorithms all ) \
    >> "$RUN/codegen.log" 2>&1 || { tail -30 "$RUN/codegen.log"; die "generate_kernels failed"; }
  need_file "$GEN/kernels.c" "codegen produced no kernels"
  need_file "$GEN/test_golden.bin" "codegen produced no golden"
  info "ops: $(python3 -c "import json;print(','.join(sorted({o['op'] for o in json.load(open('$IR/graph.json'))['ops'] if o['op']!='view'})))")"
  info "kernel sources: $(python3 -c "import json;p=json.load(open('$GEN/kernel_picks.json'))['picks'];print(', '.join(f\"{k}={v['source']}\" for k,v in sorted(p.items())))")"

  # NOT EVERY int8 OP IS INTEGER, and the ELF gate in stage 3 cannot see this.
  #
  # 22 of the 43 `_s8` KernelSpecs in reference_kernels.py implement themselves by
  # dequantizing to float, doing the math in float and requantizing -- add_s8,
  # batchnorm2d_s8, matmul_s8, elu_s8, silu_s8, sigmoid_s8, gelu_s8, softmax_s8 and the
  # fused conv+bn variants among them. On a core with an FPU that is merely a precision
  # choice. Here it compiles to libgcc soft-float calls, which are ordinary integer
  # instructions: the disassembly stays free of FP opcodes, Tag_RISCV_arch stays clean,
  # the ELF gate passes, and the number that comes back is mostly __mulsf3.
  #
  # So the generated kernels are scanned here, at the only point where the distinction is
  # still visible. This WARNS rather than dies -- such a build is legitimate, it just is
  # not a measurement of integer inference -- and records the verdict in run.json, where
  # expected/*.json gates on it.
  FLOATY=$(grep -nE '(^|[^_[:alnum:]])(float|double)([^_[:alnum:]]|$)|\b(expf|roundf|sqrtf|logf|tanhf|powf|fabsf)\b' \
             "$GEN/kernels.c" | grep -v '^[0-9]*:#include' || true)
  if [ -n "$FLOATY" ]; then
    KERNELS_INTEGER_ONLY=0
    warn "the generated kernels contain floating point -- on this WithoutFPU core that is
       libgcc soft-float emulation, and it will dominate whatever latency this run
       reports. The offending lines:"
    printf '%s\n' "$FLOATY" | head -10 | sed 's/^/       /' >&2
  else
    KERNELS_INTEGER_ONLY=1
    info "kernels are integer-only (no float/double/expf in kernels.c)"
  fi
  echo "$KERNELS_INTEGER_ONLY" > "$RUN/kernels_integer_only"

  step "2/6  build  ($BOARD)"
  # BOARD_ROOT points at this repo: the board lives here, not in the west-managed
  # zephyr checkout, so `west update` cannot clobber it.
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$GEN" -DMB_ITERS="$ITERS" \
    > "$RUN/build.log" 2>&1 || { tail -40 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
  need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
  cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"

  NCPU=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$BUILD/zephyr/.config" | cut -d= -f2)
  [ "${NCPU:-1}" -ge 2 ] || die "CONFIG_MP_MAX_NUM_CPUS=$NCPU -- this image would run on one hart"
  grep -q '^CONFIG_SMP=y' "$BUILD/zephyr/.config" || die "CONFIG_SMP is not enabled in this image"
  # Not `grep ... && die`: that idiom reads as an assertion but its exit status is the
  # grep's, and under `set -e` the difference between the two forms is subtle enough to
  # be worth not relying on.
  if grep -q '^CONFIG_FPU=y' "$BUILD/zephyr/.config"; then
    die "CONFIG_FPU=y in the built .config, against a WithoutFPU core. An app prj.conf
       overrides the board defconfig, so CONFIG_FPU=n must be stated in the app."
  fi

  step "3/6  ELF ISA gate  (catch float on the host, not on the board)"
  # The board's failure mode for an FP instruction is an illegal-instruction trap with
  # no console context. The ELF says everything needed to rule it out before booting:
  # the ABI flag, the architecture attribute string, and -- the only one of the three
  # that cannot be satisfied by an ABI that merely PASSES floats in integer registers
  # -- a disassembly with no FP opcodes in it.
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
  # GCC writes Tag_RISCV_arch canonically -- every extension after the base arrives as
  # _<name><major>p<minor> -- so F, D and V appear as _f2p2 / _d2p2 / _v1p0 and cannot be
  # confused with the f inside _zifencei2p0.
  ARCH=$(grep Tag_RISCV_arch "$RUN/isa.txt" | sed 's/.*"\(.*\)".*/\1/')
  case "$ARCH" in
    *_f[0-9]*|*_d[0-9]*|*_v[0-9]*) die "ELF advertises f/d/v: $ARCH -- this core has none of them" ;;
  esac
  # The scan below is the check that is not redundant with the two above. A soft-float ABI
  # only says floats are PASSED in integer registers; it does not say the body contains no
  # FP opcodes, and an attribute string is metadata. The disassembly is the instructions.
  FPINSN=$("$OBJDUMP" -d "$RUN/zephyr.elf" \
    | grep -cE '^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]+(f(add|sub|mul|div|sqrt|mv|cvt|ld|sd|lw|sw|sgnj|min|max|eq|lt|le|class|madd|msub|nmadd|nmsub)|c\.f(ld|sd|lw|sw)|v(set|le|se|add|mul|mac))' || true)
  [ "${FPINSN:-0}" -eq 0 ] || die "$FPINSN float/vector instructions in the image"
  echo "    0 float/vector instructions in the disassembly" >> "$RUN/isa.txt"
  info "0 float/vector instructions in the disassembly"
  info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")   cpus: $NCPU   iters/hart: $ITERS"
else
  need_file "$RUN/zephyr.bin" "nothing built -- drop --no-build"
fi

if [ "$DO_BOARD" -eq 0 ]; then
  step "BUILD ONLY -- image at $RUN/zephyr.bin"
  exit 0
fi

step "4/6  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_smp.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "5/6  load the PL and hold the SoC in reset"
if [ "$LOAD_BIT" -eq 1 ]; then
  # Present AND the file this repo ships: fpga/pynq-z2/bitstreams.csv holds the md5, and
  # $IISWC_BIT_DIR / /opt/iiswc/bit are searched when it is not in the checkout. The old
  # need_file here said "build it with build_*_z1.sh", which no attendee is going to do.
  BIT="$(bitstream_require "$BIT")"
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD_ARGS="--bitstream $(basename "$BIT") --hold"
else
  HOLD_ARGS="--no-load --hold"
fi
# Diagnose a MAGIC mismatch BEFORE retrying with a password, or the real cause ends up
# buried under a sudo fallback.
wrong_pl () {
  if grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the SINGLE-core bitstream is loaded (MAGIC 0x5A5A0002). This image would run
       the network on one hart and report the other as never having run. Re-run without
       --no-bitstream, or load
       fpga/pynq-z2/build_rocket_smp_z1/pynqz1_rocket_smp.bit."
  fi
  if grep -q 'MAGIC = 0x5A5A0001' "$RUN/boot.log"; then
    cat "$RUN/boot.log"; die "the DRAM self-test bitstream is loaded (MAGIC 0x5A5A0001)."
  fi
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_smp.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_smp.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0003' "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "dual-core bitstream not reachable over GP0"
}
info "dual-core PL loaded, SoC held in reset"

step "6/6  run the network on each hart and capture the console"
# The console reader must be listening BEFORE the core starts: the SiFive UART's TX FIFO
# is only 8 bytes deep, so a late reader loses the banner.
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_smp.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true

step "result"
if [ -s "$RUN/console.txt" ]; then
  printf '%s\n' "----------------------------------------------------------------"
  grep -vE '^MB_ITER ' "$RUN/console.txt" || cat "$RUN/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
  info "(the $ITERS per-iteration MB_ITER lines per hart are elided above;"
  info " the full console is in $RUN/console.txt)"
else
  warn "no console output -- check $RUN/boot.log"
  grep -E 'STATUS|saw_mem' "$RUN/boot.log" | tail -6 || true
fi

python3 - "$RUN" "$MODEL" "$QUANT" "$TARGET" "$BOARD" "$ITERS" "$GEN" "$IR" <<'PY'
import hashlib, json, os, re, statistics, sys
run, model, quant, target, board, iters, gen, ir = sys.argv[1:9]
iters = int(iters)

def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest() if os.path.exists(p) else None

console = os.path.join(run, 'console.txt')
text = open(console).read() if os.path.exists(console) else ''
lines = text.splitlines()

def kv(line):
    return dict(re.findall(r'(\w+)=([^\s]+)', line))

harts = {}
for line in lines:
    if line.startswith('MB_HART ') and 'NEVER_RAN' not in line:
        d = kv(line)
        harts[int(d['cpu'])] = {k: int(v) for k, v in d.items()}

iters_seen = {}
for line in lines:
    if line.startswith('MB_ITER '):
        d = kv(line)
        iters_seen.setdefault(int(d['cpu']), []).append(int(d['cycles']))

ops = {}
for line in lines:
    if line.startswith('MB_OP '):
        d = kv(line)
        ops.setdefault(int(d['cpu']), []).append(
            {'id': int(d['id']), 'name': d['name'], 'op': d['op'],
             'shape': d['shape'], 'cycles': int(d['cycles'])})

ratio = next((kv(l) for l in lines if l.startswith('MB_RATIO ')), {})
verify = next((kv(l) for l in lines if l.startswith('MB_VERIFY ')), {})
clock = next((kv(l) for l in lines if l.startswith('MB_CLOCK ')), {})
mdl = next((kv(l) for l in lines if l.startswith('MB_MODEL ')), {})
checks = dict(re.findall(r'(\w+)=([01])\b',
                         next((l for l in lines if l.startswith('CHECKS')), '')))

# Spread is reported as a PERCENTAGE OF THE MEDIAN, not as raw cycles: the raw
# number scales with the model and with the core, the percentage does not, so it is
# the form a golden check can actually gate on.
def spread_pct(v):
    if not v:
        return None
    med = statistics.median(v)
    return round((max(v) - min(v)) * 100.0 / med, 3) if med else None

core_hz = int(clock.get('core_hz', 0) or 0)
def ms(c):
    return round(c * 1000.0 / core_hz, 3) if core_hz and c else None

per_hart = {}
for cpu, d in sorted(harts.items()):
    v = iters_seen.get(cpu, [])
    per_hart[str(cpu)] = {
        'mhartid': d.get('mhartid'),
        'median_cycles': d.get('median'),
        'min_cycles': d.get('min'),
        'max_cycles': d.get('max'),
        'mean_cycles': d.get('mean'),
        'cold_cycles': d.get('warm'),
        'median_ms': ms(d.get('median')),
        'mtime_ticks_last': d.get('mtime_ticks'),
        'iterations': len(v),
        'spread_pct_of_median': spread_pct(v),
        'max_abs_err': d.get('max_abs_err'),
        'per_op_cycles': ops.get(cpu, []),
    }

big = harts.get(0, {}).get('median')
little = harts.get(1, {}).get('median')
picks = {}
if os.path.exists(os.path.join(gen, 'kernel_picks.json')):
    picks = json.load(open(os.path.join(gen, 'kernel_picks.json'))).get('picks', {})
flagfile = os.path.join(run, 'kernels_integer_only')
integer_only = (open(flagfile).read().strip() == '1') if os.path.exists(flagfile) else None

graph_ops = []
if os.path.exists(os.path.join(ir, 'graph.json')):
    graph_ops = sorted({o['op'] for o in json.load(open(os.path.join(ir, 'graph.json')))['ops']
                        if o.get('op') != 'view'})

json.dump({
    'board': board,
    'sample': 'samples/modelblaster_hart_latency',
    'model': model,
    'quant': quant,
    'target': target,
    'bin_md5': md5(os.path.join(run, 'zephyr.bin')),
    'elf_md5': md5(os.path.join(run, 'zephyr.elf')),
    'isa': open(os.path.join(run, 'isa.txt')).read().strip().splitlines()
           if os.path.exists(os.path.join(run, 'isa.txt')) else [],
    'kernel_sources': {k: v.get('source') for k, v in sorted(picks.items())},
    'console_lines': lines,
    'measured': {
        'core_hz': core_hz,
        'mtime_hz': int(clock.get('mtime_hz', 0) or 0),
        'per_hart': per_hart,
        'little_over_big_x100': int(ratio.get('little_over_big_x100', 0) or 0),
    },
    # Checked against expected/<expect>.json.
    'results': {
        'booted': '*** Booting Zephyr OS' in text,
        'model': mdl.get('name'),
        'quant': mdl.get('quant'),
        'op_count': int(mdl.get('ops', 0) or 0),
        'graph_ops': graph_ops,
        'kernel_sources_all_reference': bool(picks) and all(
            v.get('source') == 'reference' for v in picks.values()),
        # False means the generated kernels dequantize to float somewhere, so the
        # latency below is partly libgcc soft-float emulation on this FPU-less core.
        # The ELF gate cannot catch this: soft-float calls are integer instructions.
        'kernels_integer_only': integer_only,
        'harts_observed': sorted(d.get('mhartid') for d in harts.values()),
        'iterations_per_hart': sorted({len(v) for v in iters_seen.values()}),
        'hart0_max_abs_err': int(verify.get('hart0_max_abs_err', -1)),
        'hart1_max_abs_err': int(verify.get('hart1_max_abs_err', -1)),
        'outputs_identical': verify.get('outputs_identical') == '1',
        'both_harts': checks.get('both_harts') == '1',
        'distinct_harts': checks.get('distinct_harts') == '1',
        'result_pass': 'RESULT: PASS' in text,
        'little_over_big_x100': int(ratio.get('little_over_big_x100', 0) or 0),
        'max_spread_pct_of_median': max(
            [h['spread_pct_of_median'] for h in per_hart.values()
             if h['spread_pct_of_median'] is not None] or [None]),
    },
}, open(os.path.join(run, 'run.json'), 'w'), indent=2)
print(f"    manifest: {os.path.join(run, 'run.json')}")
PY

grep -q '\*\*\* Booting Zephyr OS' "$RUN/console.txt" 2>/dev/null \
  || die "the SoC did not boot; see $RUN/boot.log"

EXPECT="$IISWC_ROOT/expected/${EXPECT_NAME}.json"
if [ -f "$EXPECT" ]; then
  step "check  (vs $(basename "$EXPECT"))"
  # Two kinds of expectation, because two kinds of fact are being checked. An exact
  # value covers anything structural (which harts ran, whether the output matched the
  # golden bit for bit, how many kernels the graph has). A {"min": , "max": } window
  # covers anything MEASURED -- the big/LITTLE ratio and the run-to-run spread. Pinning
  # a raw cycle count would turn a compiler bump or a one-line codegen change into a
  # red check that says nothing about whether the hardware still behaves.
  python3 - "$RUN/run.json" "$EXPECT" <<'PYCHECK' || die "golden check failed"
import json, sys
got = json.load(open(sys.argv[1]))["results"]
exp = json.load(open(sys.argv[2]))
bad = 0
for k, want in exp.items():
    if k.startswith("_"):
        continue
    have = got.get(k)
    if isinstance(want, dict) and ("min" in want or "max" in want):
        ok = have is not None and \
             (("min" not in want) or have >= want["min"]) and \
             (("max" not in want) or have <= want["max"])
        shown = f"[{want.get('min','-inf')} .. {want.get('max','inf')}]"
    else:
        ok = have == want
        shown = repr(want)
    if not ok:
        bad += 1
    print(f"    {'ok  ' if ok else 'FAIL'}  {k:<32} expected {shown}   got {have!r}")
sys.exit(1 if bad else 0)
PYCHECK
else
  warn "no golden at $EXPECT -- skipping the check"
fi

step "LATENCY MEASURED ON BOTH HARTS -- see $RUN/run.json"
