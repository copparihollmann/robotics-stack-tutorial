#!/usr/bin/env bash
# Lab B12 -- TACIT over a REAL INFERENCE: one LeNet int8 forward pass through the curated
# MBP kernels, traced on the P-ext silicon, decoded, and checked against two independent
# ground truths that are not the decoder.
#
#   modelblaster codegen (pext)  ->  west build x2 (chipyard_pynqz1_pext, spike_riscv64)
#   -> spike --trace=l          -> decode -> DIFF THE PC SEQUENCE AGAINST tacit.debug
#   -> load pynqz1_rocket_pext.bit -> run -> drain /dev/mem -> decode --encoder rtl
#   -> every mbp.* re-disassembled from the ELF, dynamic counts against a CLOSED-FORM
#      derivation from the LeNet shapes, Perfetto slice nesting, hardware vs simulator
#
# WHAT WAS MISSING BEFORE THIS SCRIPT.  PEXT_VALIDATION.md section 6 states it exactly:
# "the traced MBP window is 96 instructions, not a traced inference".  Two traces existed:
#
#   out/pext_trace/                 a Spike trace of samples/pext_selftest -- 5,296 MBP
#                                   executions, but in a self-test, not a kernel.
#   out/rocket_tacit_pext_smp/      96 MBP executions on hardware, in a synthetic 24-round
#                                   loop written for the purpose.
#
# Neither touches fpga/pynq-z2/modelblaster/kernels/pext/, which is where MBP sits next to
# branches, at basic-block boundaries and interleaved with byte loads at high density.
# This traces THAT: 53,122 MBP executions inside one inference.
#
# THE FIVE CHECKS, AND WHY EACH IS NOT CIRCULAR.
#
#   1. SPIKE'S OWN GROUND TRUTH.  The same source, built for spike_riscv64 and run on the
#      patched simulator, which writes BOTH the encoded stream (tacit.out) and its own
#      per-instruction record of the traced window (tacit.debug).  The decoded PC sequence
#      must equal tacit.debug instruction for instruction.  Nothing about that comparison
#      goes through the decoder twice.
#
#   2. THE ELF.  Every address the hardware trace labels mbp.* is disassembled
#      independently out of the image and compared field for field -- funct3 against the
#      mnemonic, rd/rs1/rs2 against the printed registers.
#
#   3. `unknown` AT AN MBP SITE MUST BE ZERO, and the total `unknown` count in the trace is
#      reported with it. An `unknown` at an MBP address means patches/0007 silently did not
#      apply; an `unknown` anywhere else is a different bug and is worth seeing.
#
#   4. THE DYNAMIC COUNTS, DERIVED RATHER THAN OBSERVED.  Stage 9 computes how many times
#      each of the four instructions MUST execute in one inference, from the tensor shapes
#      in graph.json and the three curated kernels' structure -- DOT8 = OH*OW*OC*ceil8(K)/8
#      per convolution, MAX8 = C*OH*(VG*(KH-1) + OW/4) per 2x2 pool, one QMUL and one CLIP8
#      per output element, MAX8 per output element where the layer folds a ReLU.  The
#      linear kernel's count depends on the runtime alignment of the weight rows, so that
#      is read out of the ELF's symbol table rather than assumed.  The decoded counts must
#      equal the derivation exactly, on hardware AND on spike.
#
#   5. THE PICTURE.  The Perfetto slices must nest (begins == ends, no unclosed frame), the
#      curated kernel functions must be in them, and the seven dispatches must appear in
#      graph order.
#
# Produces, under out/<name>/:
#   model/{ir,gen}              the codegen tree this image was built from
#   fpga/   zephyr.{elf,bin,dis}, isa.txt, mbp_sites.json, console.txt, tacit.out,
#           trace.txt, trace.perfetto.json, decode.log
#   spike/  zephyr.elf, tacit.{out,debug,log}, trace.txt, trace.perfetto.json, decode.log
#   mbp_decode.txt              stages 8-10 in full
#   run.json                    manifest, checked against expected/tacit_mb_lenet_pext.json
#
# The board is shared. Run this under the lock:
#   scripts/with_board.sh ./scripts/32_rocket_tacit_mb_lenet_pext.sh
#   scripts/with_board.sh ./scripts/32_rocket_tacit_mb_lenet_pext.sh --no-bitstream
#   ./scripts/32_rocket_tacit_mb_lenet_pext.sh --build-only     # host + spike, no board
#
#   --no-spike     skip the simulator leg. The board half still runs and still checks the
#                  derivation, the ELF and the slices -- but checks 1 and 5b, which are the
#                  two that do not go through the decoder twice, are gone with it.
#   --no-expect    run everything, skip the comparison against expected/.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODEL="lenet"
QUANT="int8"
NAME=""
BOARD="chipyard_pynqz1_pext"
SPIKE_BOARD="spike_riscv64"
SAMPLE="$IISWC_ROOT/samples/tacit_mb_lenet_pext"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_pext_z1/pynqz1_rocket_pext.bit"
LOAD_BIT=1
DO_BOARD=1
DO_SPIKE=1
SECONDS_READ=60
EXPECT=""
NO_EXPECT=0
# Rocket's ExtMem base and where the FPGA top folds it into PS physical memory, from
# src/pynqz2_rocket_top.v: {4'd1, addr[27:0]}.
ROCKET_MEM_BASE=$((0x80000000))
PS_MEM_BASE=$((0x10000000))
TACIT_BUF=0x88000000
# The clock this bitstream is TIMED at, x1000 = the mtime rate the board Kconfig carries.
WANT_MTIME_HZ=34483
# The function the guest calls on both edges of the traced window.
MARKER=tacit_mb_marker

while [ $# -gt 0 ]; do
  case "$1" in
    --model)   MODEL="${2:?}";  shift 2 ;;
    --quant)   QUANT="${2:?}";  shift 2 ;;
    --name)    NAME="${2:?}";   shift 2 ;;
    --board)   BOARD="${2:?}";  shift 2 ;;
    --bit)     BIT="${2:?}";    shift 2 ;;
    --sample)  SAMPLE="${2:?}"; shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --expect)  EXPECT="${2:?}"; shift 2 ;;
    --no-expect)    NO_EXPECT=1; shift ;;
    --no-bitstream) LOAD_BIT=0;  shift ;;
    --build-only)   DO_BOARD=0;  shift ;;
    --no-spike)     DO_SPIKE=0;  shift ;;
    -h|--help) sed -n '2,69p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
NAME="${NAME:-rocket_tacit_mb_${MODEL}_${QUANT}_pext}"

MB="$ZCS/modelblaster"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
PEXT_H="$IISWC_ROOT/fpga/pynq-z2/sw/pext.h"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB"
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
need_file "$PEXT_H" "the frozen ISA contract"
[ -d "$KERNELS/pext" ] || die "no curated pext kernels at $KERNELS/pext"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"
need_exec "$TACIT_DECODER" "run scripts/05_build_tacit_tools.sh, or export TACIT_DECODER"
[ "$DO_SPIKE" -eq 0 ] || need_exec "$TACIT_SPIKE" "run scripts/05_build_tacit_tools.sh"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
rm -rf "$RUN"
mkdir -p "$RUN/fpga" "$RUN/spike"

OBJDUMP="$(command -v riscv64-zephyr-elf-objdump || true)"
READELF="$(command -v riscv64-zephyr-elf-readelf || true)"
[ -n "$OBJDUMP" ] && [ -n "$READELF" ] || die "riscv64-zephyr-elf binutils not on PATH -- source env.sh"
NM="$ZEPHYR_SDK_INSTALL_DIR/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-nm"
[ -x "$NM" ] || NM="$(command -v riscv64-zephyr-elf-nm || echo nm)"

# ---------------------------------------------------------------------------
step "1/11  modelblaster backend patch  (patches/0009-modelblaster-pext-backend.patch)"
# Idempotent, reverse-check-first, exactly as 28 and 30 do it: the submodule is a pinned,
# read-only input and the two edits the pext target needs live in patches/.
MBPATCH="$IISWC_ROOT/patches/0009-modelblaster-pext-backend.patch"
need_file "$MBPATCH"
if ( cd "$MB" && git apply --reverse --check "$MBPATCH" ) >/dev/null 2>&1; then
  info "already applied to $MB"
elif ( cd "$MB" && git apply --check "$MBPATCH" ) >/dev/null 2>&1; then
  run git -C "$MB" apply "$MBPATCH"
  info "applied"
else
  die "patches/0009 neither applies nor is applied at $MB -- the tree has diverged"
fi

# ---------------------------------------------------------------------------
step "2/11  modelblaster codegen  (pext target, fresh cache)"
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
IR="$RUN/model/ir"; GEN="$RUN/model/gen"
mkdir -p "$IR" "$GEN" "$RUN/model/cache"
( cd "$ZCS" && python -m modelblaster.pipeline.extract_graph \
    --model "$MODEL" --out-dir "$IR" --quant "$QUANT" \
    --num-calibration 1 --fusion-target pext ) > "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "extract_graph failed"; }
( cd "$ZCS" && python -m modelblaster.pipeline.generate_skeleton \
    --ir "$IR/graph.json" --weights "$IR/weights.npz" --io "$IR/io.npz" \
    --out-dir "$GEN" --backend pext ) >> "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "generate_skeleton failed"; }
( cd "$ZCS" && python -m modelblaster.pipeline.generate_kernels \
    --ir "$IR/graph.json" --out-dir "$GEN" --backend reference --target pext \
    --quant "$QUANT" --io "$IR/io.npz" --repo-root "$MB" \
    --build-dir "$RUN/model/kverify" --harness-dir "$MB/harness" \
    --cache-dir "$RUN/model/cache" --algorithms all \
    --global-curated-dir "$KERNELS" ) >> "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "generate_kernels failed"; }
need_file "$GEN/kernels.c" "codegen produced no kernels"
need_file "$GEN/test_golden.bin" "codegen produced no golden"

# EVERY OP MUST BE CURATED. A dispatch that quietly fell back to the scalar reference
# would still compute the right answer and would put no MBP in the traced window at all --
# which is the one thing this lab exists not to report.
python3 - "$GEN/kernel_picks.json" <<'PY' || die "not every op resolved to a curated kernel"
import json, sys
picks = json.load(open(sys.argv[1]))["picks"]
bad = {k: v for k, v in picks.items() if v.get("source") != "curated"}
for k, v in sorted(picks.items()):
    print(f"    {'ok  ' if k not in bad else 'FAIL'}  {k:<16} {v.get('source')}/{v.get('algorithm')}")
sys.exit(1 if bad else 0)
PY
info "ops: $(python3 -c "import json;print(','.join(sorted({o['op'] for o in json.load(open('$IR/graph.json'))['ops'] if o['op']!='view'})))")"

# ---------------------------------------------------------------------------
step "3/11  build the traced image, twice: the board and the simulator"
MB_KERNEL_CFLAGS=$(cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
print(' '.join(backends.get('pext').resolved_kernel_cflags('$MB')))")
info "kernels.c cflags from Backend('pext'): ${MB_KERNEL_CFLAGS:-<none>}"

build_one () {  # $1 = out subdir, $2 = board
  run west build -p always -b "$2" "$SAMPLE" -d "$RUN/$1/build" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$GEN" \
      -DMODELBLASTER_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS" \
    > "$RUN/$1/build.log" 2>&1 \
    || { tail -40 "$RUN/$1/build.log"; die "$1 build failed -- see $RUN/$1/build.log"; }
  cp "$RUN/$1/build/zephyr/zephyr.elf" "$RUN/$1/"
  [ -f "$RUN/$1/build/zephyr/zephyr.bin" ] && cp "$RUN/$1/build/zephyr/zephyr.bin" "$RUN/$1/"
  "$OBJDUMP" -d "$RUN/$1/zephyr.elf" > "$RUN/$1/zephyr.dis"
  "$NM" -S --defined-only "$RUN/$1/zephyr.elf" > "$RUN/$1/zephyr.nm"
}
build_one fpga "$BOARD"
if [ "$DO_SPIKE" -eq 1 ]; then build_one spike "$SPIKE_BOARD"; fi

# ---------------------------------------------------------------------------
step "4/11  ELF gates, and the static MBP ground truth"
CFG="$RUN/fpga/build/zephyr/.config"
HZ=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$CFG" | cut -d= -f2)
[ "${HZ:-0}" = "$WANT_MTIME_HZ" ] || die "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, expected
       $WANT_MTIME_HZ. That constant is the SiFive UART's baud divisor as well as the tick
       rate, so a mismatch shows up as a GARBLED console -- FPGA_END_TO_END.md 4.1."
NCPU=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$CFG" | cut -d= -f2)
[ "${NCPU:-1}" -ge 2 ] || die "CONFIG_MP_MAX_NUM_CPUS=$NCPU -- hart 1 would never come up
       and k_thread_cpu_pin(0) would be a no-op rather than a guarantee"
grep -q '^CONFIG_SMP=y' "$CFG" || die "CONFIG_SMP is not enabled in the board image"
grep -q '^CONFIG_MB_PEXT=y' "$CFG" || die "CONFIG_MB_PEXT is not set -- the kernels would
       compile against pext.h's software model and the traced window would contain no
       custom-0 encoding at all"
grep -q '^CONFIG_SCHED_CPU_MASK=y' "$CFG" || die "CONFIG_SCHED_CPU_MASK is off --
       k_thread_cpu_pin() would not exist and the inference could land on hart 1, where
       the first MBP instruction is illegal"
grep -q '^CONFIG_TACIT_MB_SINK_DMA=y' "$CFG" || die "CONFIG_TACIT_MB_SINK_DMA is off in
       the board image -- the encoder would be pointed at sink target 0, which this SoC
       does not instantiate, and every byte would be silently dropped"
if grep -q '^CONFIG_FPU=y' "$CFG"; then die "CONFIG_FPU=y against a WithoutFPU core"; fi

{
  "$READELF" -h "$RUN/fpga/zephyr.elf" | grep -E 'Entry point|Flags'
  "$READELF" -A "$RUN/fpga/zephyr.elf" | grep Tag_RISCV_arch
} > "$RUN/fpga/isa.txt"
grep -q 'soft-float ABI' "$RUN/fpga/isa.txt" || { cat "$RUN/fpga/isa.txt"; die "not a soft-float ABI build"; }
FP=$(grep -cE '^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]+(f(add|sub|mul|div|sqrt|mv|cvt|ld|sd|lw|sw|sgnj|min|max|eq|lt|le|class|madd|msub|nmadd|nmsub)|c\.f(ld|sd|lw|sw)|v(set|le|se|add|mul|mac))' \
      "$RUN/fpga/zephyr.dis" || true)
[ "${FP:-0}" -eq 0 ] || die "$FP float/vector instructions in the image"
echo "    0 float/vector instructions in the disassembly" >> "$RUN/fpga/isa.txt"

# THE GROUND TRUTH for stage 8, extracted before the board is touched: every MBP encoding
# in the image, by address, decoded by hand out of the disassembly against PEXT_SPEC.md
# 3.0. `.insn` leaves no trace in Tag_RISCV_arch -- on purpose, it is what keeps the exact
# rv64imac multilib match -- so the disassembly is the only place this exists.
sites_of () {  # $1 = fpga|spike
  python3 - "$RUN/$1/zephyr.dis" "$RUN/$1/mbp_sites.json" "$1" <<'PY'
import json, re, sys
names = ["dot8", "max8", "qmul", "clip8"]
sites, other = {}, 0
for m in re.finditer(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s", open(sys.argv[1]).read(), re.M):
    v = int(m.group(2), 16)
    if (v & 0x7f) != 0x0b:
        continue
    if (v >> 25) != 0 or ((v >> 12) & 7) > 3:
        other += 1
        continue
    sites["0x" + m.group(1).lstrip("0").rjust(1, "0")] = {
        "word": m.group(2), "op": names[(v >> 12) & 7],
        "rd": (v >> 7) & 31, "rs1": (v >> 15) & 31, "rs2": (v >> 20) & 31,
    }
json.dump({"sites": sites, "non_mbp_custom0": other}, open(sys.argv[2], "w"), indent=2)
by_op = {}
for s in sites.values():
    by_op[s["op"]] = by_op.get(s["op"], 0) + 1
print(f"    {sys.argv[3]:<5} {len(sites)} static MBP site(s): " +
      ", ".join(f"{k}={by_op.get(k,0)}" for k in names) +
      (f"   plus {other} custom-0 words that are NOT MBP" if other else ""))
sys.exit(0 if sites else 1)
PY
}
sites_of fpga || die "no MBP encodings in the board image -- it would trace nothing worth decoding"
if [ "$DO_SPIKE" -eq 1 ]; then sites_of spike || die "no MBP encodings in the spike image"; fi

# The marker has to survive -O2 under a name the decoder can resolve from the symbol
# table. gcc will happily emit tacit_mb_marker.constprop.0; catch that here rather than at
# the end of a board run.
MARKER_SYMS=$(awk -v m="$MARKER" '$4==m {print $1, $2}' "$RUN/fpga/zephyr.nm")
[ -n "$MARKER_SYMS" ] || die "no symbol '$MARKER' in the built ELF -- check noinline/noclone"
MARKER_ADDR=0x$(awk '{print $1}' <<<"$MARKER_SYMS")
info "marker: $MARKER at $MARKER_ADDR   bin $(fsize "$RUN/fpga/zephyr.bin")   elf $(fsize "$RUN/fpga/zephyr.elf")   mtime $HZ Hz   cpus $NCPU"

# ---------------------------------------------------------------------------
if [ "$DO_SPIKE" -eq 1 ]; then
step "5/11  spike --trace=l, and the decode diffed against spike's own tacit.debug"
# The L-encoder writes tacit.out / tacit.log / tacit.debug into the CWD, so run there.
# tacit.debug is written ONLY while the encoder is enabled, so it is a record of exactly
# the window the guest bracketed -- one inference and the two markers.
( cd "$RUN/spike" && run "$TACIT_SPIKE" --trace=l "$RUN/spike/zephyr.elf" ) \
  > "$RUN/spike/console.txt" 2>&1 \
  || { tail -20 "$RUN/spike/console.txt"; die "spike failed -- see $RUN/spike/console.txt"; }
tr -d '\r' < "$RUN/spike/console.txt" > "$RUN/spike/console.clean" && mv "$RUN/spike/console.clean" "$RUN/spike/console.txt"
need_file "$RUN/spike/tacit.out" "spike emitted no trace -- is this the patched TACIT spike?"
need_file "$RUN/spike/tacit.debug" "spike emitted no ground-truth log"
grep -q '^TACIT_MB_DONE ok=1' "$RUN/spike/console.txt" \
  || { tail -20 "$RUN/spike/console.txt"; die "the spike run did not complete"; }

( cd "$RUN/spike" && run "$TACIT_DECODER" \
    --binary "$RUN/spike/zephyr.elf" \
    --encoded-trace "$RUN/spike/tacit.out" \
    --to-txt --to-perfetto ) > "$RUN/spike/decode.log" 2>&1 \
  || { tail -20 "$RUN/spike/decode.log"; die "spike decode failed -- $RUN/spike/decode.log"; }
grep -q 'detected FSync packet, trace ending' "$RUN/spike/decode.log" \
  || warn "spike: decoder did not reach the trailing sync packet"
info "spike: $(sed -n 's/.*Decoded \([0-9]*\) packets.*/\1/p' "$RUN/spike/decode.log" | tail -1) packets, $(fsize "$RUN/spike/tacit.out") encoded, $(wc -l < "$RUN/spike/tacit.debug") instructions in tacit.debug"
fi

# ---------------------------------------------------------------------------
if [ "$DO_BOARD" -eq 0 ]; then
  step "BUILD ONLY -- board stages skipped"
  info "image: $RUN/fpga/zephyr.bin"
  [ "$DO_SPIKE" -eq 1 ] && info "spike trace: $RUN/spike/trace.perfetto.json"
  exit 0
fi

step "6/11  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/fpga/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_pext.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/fpga/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "7/11  load the P-ext PL and hold the SoC in reset"
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
wrong_pl () {
  if grep -q 'MAGIC = 0x5A5A0003' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the plain DUAL-CORE bitstream is loaded (MAGIC 0x5A5A0003). It has no MBP unit on
       either hart, so the first curated kernel would take an illegal-instruction trap
       INSIDE the traced window. Re-run without --no-bitstream, or load $BIT."
  fi
  if grep -q 'MAGIC = 0x5A5A000[12]' "$RUN/boot.log"; then
    cat "$RUN/boot.log"; die "the wrong bitstream is loaded -- see MAGIC above."
  fi
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_pext.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_pext.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0004' "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "P-ext bitstream not reachable over GP0"
}
grep -E 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true
# The clock, read from the PS SLCR rather than assumed -- every millisecond below is
# computed from it.
CORE_HZ=$(sed -n 's/^FCLK0_HZ = \([0-9][0-9]*\).*/\1/p' "$RUN/boot.log" | tail -1)
[ -n "$CORE_HZ" ] || CORE_HZ=$(( WANT_MTIME_HZ * 1000 ))
info "P-ext PL loaded, SoC held in reset   core clock $CORE_HZ Hz"

step "8/11  boot hart 0 and trace one inference"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_pext.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  for i in \$(seq 1 $SECONDS_READ); do
    grep -q TACIT_MB_DONE console.out 2>/dev/null && break
    sleep 1
  done
  kill \$CPID 2>/dev/null
  wait \$CPID 2>/dev/null
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/fpga/console.txt" 2>/dev/null || true

if [ -s "$RUN/fpga/console.txt" ]; then
  printf '%s\n' "----------------------------------------------------------------"
  cat "$RUN/fpga/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
else
  warn "no console output -- check $RUN/boot.log"
  die "the SoC produced no console output"
fi
grep -q '\*\*\* Booting Zephyr OS' "$RUN/fpga/console.txt" || die "the SoC did not boot; see $RUN/boot.log"
if grep -q '^TACIT_MB_FAIL' "$RUN/fpga/console.txt"; then
  die "guest reported: $(grep -m1 '^TACIT_MB_FAIL' "$RUN/fpga/console.txt")"
fi
grep -q '^TACIT_MB_DONE ok=1' "$RUN/fpga/console.txt" \
  || die "no clean TACIT_MB_DONE -- the run did not complete; see $RUN/fpga/console.txt"

TR_LINE=$(grep -m1 '^TACIT_MB_TRACE ' "$RUN/fpga/console.txt")
BYTES=$(sed -n 's/.* bytes=\([0-9]*\).*/\1/p' <<<"$TR_LINE")
BUFSZ=$(sed -n 's/.* buf_size=\([0-9]*\).*/\1/p' <<<"$TR_LINE")
ADDR=$(sed -n 's/.* addr=\(0x[0-9a-fA-F]*\).*/\1/p' <<<"$TR_LINE")
[ "${BYTES:-0}" -gt 0 ] 2>/dev/null || die "the sink wrote 0 bytes: $TR_LINE"
[ "$BYTES" -le "$BUFSZ" ] || die "the trace wrapped the buffer: $BYTES > $BUFSZ"
PHYS=$(( $((ADDR)) - ROCKET_MEM_BASE + PS_MEM_BASE ))
info "trace: $BYTES bytes at Rocket $ADDR = PS phys $(printf '0x%08X' $PHYS)   buffer $BUFSZ bytes ($(awk "BEGIN{printf \"%.2f\", 100.0*$BYTES/$BUFSZ}")% used)"

"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 -u read_mem.py \
   --phys $(printf '0x%X' $PHYS) --bytes $BYTES --out tacit.out" \
   > "$RUN/drain.log" 2>&1 || { cat "$RUN/drain.log"; die "could not read the trace buffer"; }
run scp -q "$PYNQ_HOST:$PYNQ_DIR/tacit.out" "$RUN/fpga/tacit.out"
GOT=$(stat -c%s "$RUN/fpga/tacit.out")
[ "$GOT" -eq "$BYTES" ] || die "short read: got $GOT bytes, guest reported $BYTES"

step "9/11  decode the hardware trace"
# --encoder rtl: the hardware encoder's sync and trap packets carry neither the privilege
# byte nor the context varint spike's trace_encoder_l emits. TACIT_ON_FPGA.md section 5.
( cd "$RUN/fpga" && run "$TACIT_DECODER" \
    --binary "$RUN/fpga/zephyr.elf" \
    --encoded-trace "$RUN/fpga/tacit.out" \
    --encoder rtl \
    --to-txt --to-perfetto ) > "$RUN/fpga/decode.log" 2>&1 \
  || { tail -20 "$RUN/fpga/decode.log"; die "decode failed -- $RUN/fpga/decode.log"; }
need_file "$RUN/fpga/trace.perfetto.json" "the decoder produced no perfetto trace"
grep -q 'detected FSync packet, trace ending' "$RUN/fpga/decode.log" \
  || warn "the decoder did not reach the trailing sync packet -- the stream may be truncated"
info "$(sed -n 's/.*Decoded \([0-9]*\) packets.*/\1/p' "$RUN/fpga/decode.log" | tail -1) packets, $(grep -cE '^0x[0-9a-f]+: ' "$RUN/fpga/trace.txt") instructions decoded"

# ---------------------------------------------------------------------------
step "10/11  the decode, against four things that are not the decoder"
set +e
python3 - "$RUN" "$IR/graph.json" "$MARKER" "$MARKER_ADDR" "$SAMPLE" "$BOARD" \
         "$IISWC_ROOT" "$ZCS" "$CORE_HZ" "$DO_SPIKE" <<'PY' | tee "$RUN/mbp_decode.txt"
import datetime, json, os, re, subprocess, sys

run, graph_path, marker, marker_addr, sample, board, root, zcs, core_hz, do_spike = sys.argv[1:11]
core_hz = int(core_hz)
do_spike = do_spike == "1"
ok = True


def rev(p):
    try:
        return subprocess.run(["git", "-C", p, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip() or None
    except Exception:
        return None


def verdict(good, text):
    global ok
    ok = ok and bool(good)
    print(f"    {'ok  ' if good else 'FAIL'}  {text}")
    return good


# ----------------------------------------------------------------- the derivation
# How many times each MBP instruction MUST execute in one inference, from the tensor
# shapes in graph.json and the three curated kernels in
# fpga/pynq-z2/modelblaster/kernels/pext/. Every number below is read off those two
# sources; nothing here looks at a trace.
def align8(x):
    return (x + 7) & ~7


def d_conv(shape, quant):
    """pext_conv2d_s8_pext_patch_dot8.c: one DOT8 per 8-byte group of the align8'd
    reduction vector, per output channel, per output pixel -- the output-channel blocking
    changes where the weights are read from, not how many DOT8s run. One QMUL and one
    CLIP8 per output element, plus a MAX8 where the layer folds a ReLU into the clamp
    (mb_pext_relu8 is MAX8 against x0)."""
    N, IC, IH = shape["N"], shape["IC"], shape["IH"]
    OC, OH, OW, KH, KW = shape["OC"], shape["OH"], shape["OW"], shape["KH"], shape["KW"]
    K = IC * KH * KW
    KP = align8(K)
    G = KP >> 3
    fast = (quant["input_offset"] == 0 and quant["filter_offset"] == 0 and K > 0
            and KP <= 2048 and KP <= 8192 and IC * KH <= 512 and OH > 0 and OW > 0)
    if not fast:
        return dict(dot8=0, max8=0, qmul=0, clip8=0, fast_path=False)
    elems = N * OC * OH * OW
    return dict(dot8=N * OH * OW * OC * G, max8=elems if quant["activation_min"] == 0 else 0,
                qmul=elems, clip8=elems, fast_path=True, K=K, KP=KP, groups=G)


def d_pool(shape, in_addr):
    """pext_maxpool2d_s8_pext_max8_rows.c: pass 1 is KH-1 MAX8s per 8-column group per
    output row; pass 2 adds OW/4 more when the window is the 2x2 the fast path pairs up.
    The fast path needs IW % 8 == 0 and an 8-aligned input plane, so the tensor's link
    address decides whether any of this runs at all."""
    N, C, IW = shape["N"], shape["C"], shape["IW"]
    OH, OW, KH, KW, SW = shape["OH"], shape["OW"], shape["KH"], shape["KW"], shape["SW"]
    fast = (shape["PH"] == 0 and shape["PW"] == 0 and shape["DH"] == 1
            and shape["DW"] == 1 and KH > 0 and KW > 0 and OH > 0 and OW > 0
            and IW > 0 and (IW & 7) == 0 and IW <= 4096
            and in_addr is not None and (in_addr & 7) == 0)
    if not fast:
        return dict(dot8=0, max8=0, qmul=0, clip8=0, fast_path=False)
    per_row = (IW >> 3) * (KH - 1) + ((OW >> 2) if (KW == 2 and SW == 2) else 0)
    return dict(dot8=0, max8=N * C * OH * per_row, qmul=0, clip8=0, fast_path=True)


def d_lin_edge(r, K, L, n, N):
    before, after = n * K, (N - n) * K + r
    j0 = (r - before) if r > before else 0
    j1 = after if after < L else L
    g0, g1 = (j0 + 7) >> 3, j1 >> 3
    return max(g1, g0) - g0


def d_linear(shape, quant, w_addr):
    """pext_linear_s8_pext_row_dot8.c: the weight rows are swept 8 bytes at a time from a
    pointer deliberately placed r bytes before row n, where r is that row's misalignment.
    So the DOT8 count depends on the LINK ADDRESS of the weight array, and the rows at
    either end of the tensor -- whose padded sweep would read outside it -- do fewer. That
    is why w_addr comes out of the ELF's symbol table."""
    M, K, N = shape["M"], shape["K"], shape["N"]
    fast = (quant["input_offset"] == 0 and quant["filter_offset"] == 0
            and K > 0 and N > 0 and K + 15 <= 2048 and w_addr is not None)
    if not fast:
        return dict(dot8=0, max8=0, qmul=0, clip8=0, fast_path=False)
    period = 8
    if (K & 1) == 0:
        period = 4
    if (K & 3) == 0:
        period = 2
    if (K & 7) == 0:
        period = 1
    dot8 = 0
    for _m in range(M):
        for t in range(min(period, N)):
            r = (w_addr + t * K) & 7
            L = align8(r + K)
            G = L >> 3
            nlo = (r + K - 1) // K
            nhi = N - (L - r + K - 1) // K
            n = t
            while n < N and n < nlo:
                dot8 += d_lin_edge(r, K, L, n, N)
                n += period
            while n + 3 * period <= nhi and n + 3 * period < N:
                dot8 += 4 * G
                n += 4 * period
            while n <= nhi and n < N:
                dot8 += G
                n += period
            while n < N:
                dot8 += d_lin_edge(r, K, L, n, N)
                n += period
    elems = M * N
    return dict(dot8=dot8, max8=elems if quant["activation_min"] == 0 else 0,
                qmul=elems, clip8=elems, fast_path=True, period=period)


def symbols(path):
    out = {}
    for line in open(path):
        f = line.split()
        if len(f) >= 3:
            out[f[-1]] = int(f[0], 16)
    return out


def derive(graph, syms):
    per_op = {}
    for op in graph["ops"]:
        kind = op["op"]
        if kind == "view":
            continue
        if kind == "conv2d_s8":
            d = d_conv(op["shape"], op["quant"])
        elif kind == "maxpool2d_s8":
            t = op["inputs"][0]
            a = next((v for k, v in syms.items()
                      if re.fullmatch(r"buf_.*_" + re.escape(t), k)), None)
            d = d_pool(op["shape"], a)
            d["input_addr"] = a
        elif kind == "linear_s8":
            w = re.escape(op["weight"].replace(".", "_"))
            a = next((v for k, v in syms.items()
                      if re.search(r"_" + w + r"(_|$)", k)), None)
            d = d_linear(op["shape"], op["quant"], a)
            d["weight_addr"] = a
        else:
            raise SystemExit("stage 10: unhandled op kind " + kind)
        d["op"] = kind
        per_op[op["name"]] = d
    total = {k: sum(v.get(k, 0) for v in per_op.values())
             for k in ("dot8", "max8", "qmul", "clip8")}
    total["total"] = sum(total.values())
    return per_op, total


# ----------------------------------------------------------------- trace readers
MBP_RE = re.compile(r'^(0x[0-9a-f]+): (mbp\.\w+)\s*(.*)$')
INSN_RE = re.compile(r'^(0x[0-9a-f]+): (\S+)')


def read_trace(path, site_addrs, marker_lo, marker_hi):
    counts, seen, unknown_at_site, unknown_total = {}, {}, 0, 0
    unknown_names = {}
    insns = 0
    pcs = []
    first_ts = last_ts = None
    first_mbp_ts = last_mbp_ts = None
    marker_hits = []
    ts = None
    for line in open(path):
        if line.startswith('[timestamp: '):
            ts = int(line[12:line.index(']')])
            if first_ts is None:
                first_ts = ts
            last_ts = ts
            continue
        if not line.startswith('0x'):
            continue
        insns += 1
        colon = line.index(':')
        pc = line[2:colon]
        pcs.append(pc)
        if marker_lo <= int(pc, 16) < marker_hi:
            marker_hits.append(ts)
        m = MBP_RE.match(line.rstrip('\n'))
        if m:
            op = m.group(2)[4:]
            counts[op] = counts.get(op, 0) + 1
            seen.setdefault(m.group(1), (op, m.group(3)))
            if first_mbp_ts is None:
                first_mbp_ts = ts
            last_mbp_ts = ts
            continue
        mi = INSN_RE.match(line.rstrip('\n'))
        if mi and mi.group(2) == 'unknown':
            unknown_total += 1
            unknown_names[mi.group(1)] = unknown_names.get(mi.group(1), 0) + 1
            if int(mi.group(1), 16) in site_addrs:
                unknown_at_site += 1
    return dict(counts=counts, seen=seen, unknown_at_site=unknown_at_site,
                unknown_total=unknown_total, unknown_addrs=unknown_names,
                instructions=insns, pcs=pcs, first_ts=first_ts, last_ts=last_ts,
                first_mbp_ts=first_mbp_ts, last_mbp_ts=last_mbp_ts,
                marker_executions=len(marker_hits))


def perfetto(path):
    txt = open(path).read()
    b = len(re.findall(r'"ph":"B"', txt))
    e = len(re.findall(r'"ph":"E"', txt))
    names = re.findall(r'"name":"([^"]+)","ph":"B"', txt)
    order, seen = [], set()
    for n in names:
        if n not in seen:
            seen.add(n)
            order.append(n)
    counts = {}
    for n in names:
        counts[n] = counts.get(n, 0) + 1
    # The generated model emits one dispatch_<model>_<id> per IR op, in execution order,
    # so the order these slices open in IS the graph's topological order as the hardware
    # actually walked it.
    dispatches = [n for n in names if re.fullmatch(r"dispatch_\w+_\d+", n)]
    return dict(begins=b, ends=e, unclosed=b - e, slice_counts=counts,
                first_slices=order[:8], distinct=len(counts),
                dispatch_order=dispatches)


def symbol_stream(run_dir):
    """Every decoded PC as (symbol, offset-into-symbol).

    Two images built for two different boards land their code at different addresses, so
    a raw PC diff between them is meaningless -- but a SYMBOL+OFFSET diff is not. The
    curated kernels are the same C compiled with the same flags in both, so if the
    hardware and the simulator really executed the same work, these two streams are the
    same sequence."""
    import bisect
    syms = []
    for line in open(os.path.join(run_dir, "zephyr.nm")):
        f = line.split()
        if len(f) >= 4 and f[2] in "tTwW":
            syms.append((int(f[0], 16), int(f[1], 16), f[3]))
    syms.sort()
    addrs = [x[0] for x in syms]
    out, gaps = [], 0
    for line in open(os.path.join(run_dir, "trace.txt")):
        if not line.startswith("0x"):
            continue
        pc = int(line[2:line.index(":")], 16)
        i = bisect.bisect_right(addrs, pc) - 1
        if i < 0:
            out.append(("<none>", pc))
            gaps += 1
            continue
        a, sz, n = syms[i]
        if sz and pc >= a + sz:
            out.append(("<gap>", pc - a))
            gaps += 1
        else:
            out.append((n, pc - a))
    return out, gaps


graph = json.load(open(graph_path))
m_lo = int(marker_addr, 16)
sym = symbols(os.path.join(run, "fpga", "zephyr.nm"))
m_hi = m_lo + next((int(l.split()[1], 16) for l in open(os.path.join(run, "fpga", "zephyr.nm"))
                    if l.split()[-1] == marker), 0x100)

console = open(os.path.join(run, "fpga", "console.txt")).read()
sites = json.load(open(os.path.join(run, "fpga", "mbp_sites.json")))["sites"]
site_addrs = {int(a, 16) for a in sites}

hw = read_trace(os.path.join(run, "fpga", "trace.txt"), site_addrs, m_lo, m_hi)
hw_pf = perfetto(os.path.join(run, "fpga", "trace.perfetto.json"))

fpga_per_op, fpga_expect = derive(graph, sym)

print("\n    -- 0. what one inference MUST execute, derived from the LeNet shapes --")
print(f"    {'dispatch':<9} {'op':<14} {'dot8':>7} {'max8':>6} {'qmul':>6} {'clip8':>6}   notes")
for name, d in fpga_per_op.items():
    note = ""
    if d["op"] == "conv2d_s8":
        note = f"K={d['K']} -> align8 {d['KP']}, {d['groups']} DOT8/px/oc"
    elif d["op"] == "linear_s8":
        note = f"weights @0x{d['weight_addr']:x} (r={d['weight_addr'] & 7}), period {d['period']}"
    elif d["op"] == "maxpool2d_s8":
        note = f"input @0x{d['input_addr']:x}, fast path {d['fast_path']}"
    print(f"    {name:<9} {d['op']:<14} {d['dot8']:>7} {d['max8']:>6} {d['qmul']:>6} "
          f"{d['clip8']:>6}   {note}")
print(f"    {'TOTAL':<9} {'':<14} {fpga_expect['dot8']:>7} {fpga_expect['max8']:>6} "
      f"{fpga_expect['qmul']:>6} {fpga_expect['clip8']:>6}   "
      f"{fpga_expect['total']} MBP instructions in one inference")
verdict(all(d["fast_path"] for d in fpga_per_op.values()),
        "every dispatch took its curated kernel's fast path (a refusal would run the "
        "bit-exact scalar fallback and execute no MBP at all)")

# --- 1. the names and the operands, field by field against the ELF -------------------
print("\n    -- 1. every address the decoder called mbp.*, re-decoded from the image --")
REG = re.compile(r'x(\d+)')
operands_ok = True
for addr, (op, operands) in sorted(hw["seen"].items(), key=lambda kv: int(kv[0], 16)):
    s = sites.get(addr)
    if s is None:
        print(f"    FAIL  {addr}: decoder says mbp.{op}, but that address carries no MBP "
              f"encoding in the image")
        operands_ok = False
        continue
    regs = [int(x) for x in REG.findall(operands)]
    # CLIP8 prints two operands: PEXT_SPEC.md 3.4 says rs2 is ignored and pext.h names x0.
    want = [s["rd"], s["rs1"]] + ([] if s["op"] == "clip8" else [s["rs2"]])
    good = (op == s["op"]) and (regs == want)
    operands_ok = operands_ok and good
    if not good:
        print(f"    FAIL  {addr}  word {s['word']}  decoder: mbp.{op} {operands}   "
              f"elf: {s['op']} rd=x{s['rd']} rs1=x{s['rs1']} rs2=x{s['rs2']}")
print(f"    {len(hw['seen'])} distinct MBP address(es) appeared in the trace, out of "
      f"{len(sites)} static site(s) in the image")
verdict(operands_ok, f"all {len(hw['seen'])} re-disassembled field for field "
                     f"(funct3 -> mnemonic, rd/rs1/rs2 -> printed registers)")

# --- 2. the dynamic counts, against the derivation ------------------------------------
print("\n    -- 2. dynamic executions, hardware, against the derivation above --")
counts_ok = True
for op in ("dot8", "max8", "qmul", "clip8"):
    got = hw["counts"].get(op, 0)
    good = got == fpga_expect[op]
    counts_ok = counts_ok and good
    print(f"    {'ok  ' if good else 'FAIL'}  mbp.{op:<5} decoded {got:>7}   "
          f"derived {fpga_expect[op]:>7}")
verdict(counts_ok, "the decoded MBP mix is exactly one inference's worth")

# --- 3. unknown ----------------------------------------------------------------------
print("\n    -- 3. what the decoder could not name --")
verdict(hw["unknown_at_site"] == 0,
        f"{hw['unknown_at_site']} instruction(s) decoded as `unknown` at an MBP address "
        f"(expected 0 -- a non-zero count means patches/0007 did not apply)")
print(f"    total `unknown` in the whole {hw['instructions']}-instruction trace: "
      f"{hw['unknown_total']}"
      + ("" if hw["unknown_total"] == 0 else
         "   at: " + ", ".join(f"{a} x{n}" for a, n in
                               sorted(hw["unknown_addrs"].items())[:8])))

# --- 4. the picture ------------------------------------------------------------------
print("\n    -- 4. the Perfetto slices --")
print(f"    {hw_pf['begins']} begin, {hw_pf['ends']} end, {hw_pf['distinct']} distinct "
      f"function(s)")
verdict(hw_pf["unclosed"] == 0,
        f"{hw_pf['unclosed']} unclosed slice(s) (expected 0: the window opens and closes "
        f"inside one function, so every frame entered inside it also returns inside it -- "
        f"Lab A's 5 are the HTIF exit path, which this trace does not contain)")
verdict(hw["marker_executions"] > 0 and hw_pf["slice_counts"].get(marker, 0) == 2,
        f"{marker} appears {hw_pf['slice_counts'].get(marker, 0)} time(s) "
        f"(expected 2: the window has a head and a tail)")
KERNEL_FNS = ("kernel_conv2d_s8", "kernel_linear_s8", "kernel_maxpool2d_s8")
present = {k: sum(c for n, c in hw_pf["slice_counts"].items() if n.startswith(k))
           for k in KERNEL_FNS}
for k, c in present.items():
    print(f"    {k:<22} {c:>4} slice(s)")
verdict(all(c > 0 for c in present.values()),
        "all three curated kernels are in the decoded trace")
want_dispatches = [f"dispatch_{graph['name']}_{op['dispatch_id']}"
                   for op in graph["ops"] if op.get("dispatch_id") is not None]
print("    dispatch slices, in the order they opened:")
print("      " + " ".join(hw_pf["dispatch_order"]))
verdict(hw_pf["dispatch_order"] == want_dispatches,
        f"all {len(want_dispatches)} dispatches appear exactly once, in graph order "
        f"({' -> '.join(op['name'] for op in graph['ops'] if op.get('dispatch_id') is not None)})")
print("    opens on: " + " ".join(hw_pf["first_slices"]))

# --- 5. spike: the decoded PC sequence against spike's own record ---------------------
spike = None
if do_spike:
    print("\n    -- 5. the same source on spike: decoded PCs vs spike's tacit.debug --")
    s_sites = json.load(open(os.path.join(run, "spike", "mbp_sites.json")))["sites"]
    s_site_addrs = {int(a, 16) for a in s_sites}
    s_sym = symbols(os.path.join(run, "spike", "zephyr.nm"))
    s_expect_per_op, s_expect = derive(graph, s_sym)
    sp = read_trace(os.path.join(run, "spike", "trace.txt"), s_site_addrs, 0, 0)
    sp_pf = perfetto(os.path.join(run, "spike", "trace.perfetto.json"))
    ground = []
    with open(os.path.join(run, "spike", "tacit.debug")) as f:
        for line in f:
            ground.append(line.split(',', 1)[0].strip())
    n = min(len(ground), len(sp["pcs"]))
    mism = [i for i in range(n) if ground[i] != sp["pcs"][i]]
    # The decoder emits ONE instruction past spike's last logged one: spike writes
    # tacit.debug on ingress and the encoder's trailing sync packet carries the address
    # after it. out/pext_trace has the same +1.
    print(f"    spike logged {len(ground)} instructions in tacit.debug; the decoder "
          f"produced {len(sp['pcs'])} from the encoded stream alone")
    verdict(len(mism) == 0 and 0 <= len(sp["pcs"]) - len(ground) <= 1,
            f"{len(mism)} mismatch(es) over {n} instructions, decoder is "
            f"{len(sp['pcs']) - len(ground)} instruction(s) long at the tail")
    s_counts_ok = all(sp["counts"].get(o, 0) == s_expect[o]
                      for o in ("dot8", "max8", "qmul", "clip8"))
    print("    spike MBP mix: " + ", ".join(f"{o}={sp['counts'].get(o, 0)}"
                                            for o in ("dot8", "max8", "qmul", "clip8")))
    verdict(s_counts_ok, "spike's MBP mix equals the derivation for its own ELF")
    verdict(sp["unknown_total"] == 0,
            f"{sp['unknown_total']} `unknown` in the spike trace")
    same_mix = all(sp["counts"].get(o, 0) == hw["counts"].get(o, 0)
                   for o in ("dot8", "max8", "qmul", "clip8"))
    verdict(same_mix, "hardware and simulator executed the same MBP mix, instruction "
                      "for instruction, from two different ELFs")

    # --- 5b. the same instruction stream, not just the same mix --------------------
    # Both legs are the same C at the same -O2 (boards/spike_riscv64.conf says why), so
    # the two decoded streams should be the SAME SEQUENCE once the caller's frame is
    # discounted: the FPGA image runs the inference from a pinned Zephyr thread and the
    # spike image runs it straight out of main(). Align on the first instruction of the
    # window marker and diff symbol+offset.
    print("\n    -- 5b. the same instruction sequence, symbol+offset, hardware vs spike --")
    hw_sym, hw_gaps = symbol_stream(os.path.join(run, "fpga"))
    sp_sym, sp_gaps = symbol_stream(os.path.join(run, "spike"))

    def first_marker(stream):
        for i, v in enumerate(stream):
            if v[0] == marker:
                return i
        return None

    hi, si = first_marker(hw_sym), first_marker(sp_sym)
    seq_ok = False
    seq = None
    if hi is None or si is None:
        print("    FAIL  the marker is not in both streams -- nothing to align on")
    else:
        a, b = hw_sym[hi:], sp_sym[si:]
        n2 = min(len(a), len(b))
        mm = [i for i in range(n2) if a[i] != b[i]]
        # The caller of the marker differs BY CONSTRUCTION and is the only thing allowed
        # to: read its name out of each stream rather than hardcoding it.
        hw_caller = hw_sym[hi - 1][0] if hi else None
        sp_caller = sp_sym[si - 1][0] if si else None
        pairs = sorted({(a[i][0], b[i][0]) for i in mm})
        # The two streams also end a couple of instructions apart, for the same reason:
        # after the closing marker returns, each one runs its own caller's epilogue up to
        # the store that stops the encoder. Those leftovers have to be in the caller's
        # frame too, or something other than the frame differs.
        tail = a[n2:] if len(a) > n2 else b[n2:]
        tail_ok = all(v[0] in (hw_caller, sp_caller) for v in tail)
        seq_ok = all(p == (hw_caller, sp_caller) for p in pairs) and tail_ok
        print(f"    aligned on {marker}; {n2} instructions compared "
              f"(hardware {len(a)}, spike {len(b)})")
        print(f"    {len(mm)} differ, in {len(pairs)} symbol pair(s): "
              + (", ".join(f"{x} vs {y}" for x, y in pairs) or "none"))
        print(f"    {len(tail)} instruction(s) past the shorter stream, all in the "
              f"caller's frame: {tail_ok}")
        print(f"    the caller of the traced window is `{hw_caller}` on hardware and "
              f"`{sp_caller}` on spike -- a pinned")
        print(f"    Zephyr thread against a direct call from main(), which is the one "
              f"frame that MUST differ.")
        verdict(seq_ok,
                f"every one of the {n2 - len(mm)} instructions outside that frame is "
                f"identical in symbol and offset -- the routed silicon and the simulator "
                f"ran the same code")
        seq = dict(compared=n2, differing=len(mm), identical=n2 - len(mm),
                   tail_only=len(tail), tail_in_caller_frame=tail_ok,
                   differing_symbol_pairs=[list(p) for p in pairs],
                   hw_caller=hw_caller, spike_caller=sp_caller,
                   hw_unresolved=hw_gaps, spike_unresolved=sp_gaps)

    spike = dict(instructions=sp["instructions"], ground_truth_instructions=len(ground),
                 pc_mismatches=len(mism), tail_overrun=len(sp["pcs"]) - len(ground),
                 counts=sp["counts"], unknown_total=sp["unknown_total"],
                 derived=s_expect, perfetto=sp_pf, sequence=seq,
                 bytes=os.path.getsize(os.path.join(run, "spike", "tacit.out")))

# ----------------------------------------------------------------- the manifest
def num(pat, default=None, text=None):
    m = re.search(pat, text if text is not None else console, re.M)
    return int(m.group(1)) if m else default


ops = []
for m in re.finditer(r'^TACIT_MB_OP id=(\d+) name=(\S+) op=(\S+) shape=(\S+) cycles=(\d+)',
                     console, re.M):
    ops.append(dict(id=int(m.group(1)), name=m.group(2), op=m.group(3),
                    shape=m.group(4), cycles=int(m.group(5))))
out_m = re.search(r'^TACIT_MB_OUT ((?:-?\d+ ?)+)$', console, re.M)
tensor = [int(x) for x in out_m.group(1).split()] if out_m else []
golden_path = os.path.join(run, "model", "gen", "test_golden.bin")
golden = list(open(golden_path, "rb").read()) if os.path.exists(golden_path) else []
golden = [g - 256 if g > 127 else g for g in golden]

traced_cycles = num(r'^TACIT_MB_RUN .* traced=(\d+)')
cold_cycles = num(r'^TACIT_MB_RUN .* cold=(\d+)')
warm_cycles = num(r'^TACIT_MB_RUN .* warm=(\d+)')
max_abs_err = num(r'^TACIT_MB_RUN .* max_abs_err=(\d+)')
bytes_out = num(r'^TACIT_MB_TRACE .* bytes=(\d+)')
buf_size = num(r'^TACIT_MB_TRACE .* buf_size=(\d+)')
flush_cycles = num(r'^TACIT_MB_TRACE .* flush_cycles=(\d+)')
hartid = num(r'^TACIT_MB_RUN cpu=\d+ hartid=(\d+)')

print("\n    -- 6. the inference itself, so a traced run is still a correct run --")
verdict(max_abs_err == 0,
        f"max_abs_err={max_abs_err} against the baked int8 golden")
verdict(tensor == golden,
        f"the traced inference's output tensor equals test_golden.bin element for element")
verdict(hartid == 0, f"it ran on hart {hartid} (MBP exists on hart 0 only)")
print(f"    the same inference, three times in this image:")
print(f"      cold, untraced   {cold_cycles:>8} cycles")
print(f"      warm, untraced   {warm_cycles:>8} cycles   <- the reference")
print(f"      warm, TRACED     {traced_cycles:>8} cycles   "
      f"({traced_cycles / core_hz * 1000.0:.3f} ms at {core_hz} Hz)")
sink_cost = None if (warm_cycles is None or traced_cycles is None) else traced_cycles - warm_cycles
if sink_cost is not None:
    print(f"    WHAT TRACING COST: {sink_cost:+} cycles, "
          f"{100.0 * sink_cost / warm_cycles:+.2f}% of the untraced inference.")
    print(f"    The encoder is a tap on retirement and cannot cost a cycle; TraceSinkDMA "
          f"is a master on")
    print(f"    the system bus, so its {bytes_out} bytes of Puts go through the same "
          f"inclusive L2 as the")
    print(f"    core's data. That is where this number comes from, and it is why it is "
          f"reported rather")
    print(f"    than assumed to be zero.")
print(f"    encoded: {bytes_out} bytes for {hw['instructions']} instructions = "
      f"{bytes_out * 8.0 / hw['instructions']:.2f} bits/instruction")
verdict(bytes_out <= buf_size,
        f"the trace used {bytes_out} of {buf_size} buffer bytes "
        f"({100.0 * bytes_out / buf_size:.3f}%) -- it did not wrap")
ts_span = (hw["last_ts"] - hw["first_ts"]) if hw["first_ts"] is not None else None
print(f"    encoder timestamps span {ts_span} cycles against the guest's "
      f"{traced_cycles} from rdcycle")
verdict(ts_span is not None and 0 < ts_span <= traced_cycles,
        f"the traced span is non-empty and inside the software bracket "
        f"(delta {None if ts_span is None else traced_cycles - ts_span} cycles)")

manifest = {
    "name": os.path.basename(run),
    "generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "sample": sample,
    "board": board,
    "source": "fpga",
    "bitstream": "fpga/pynq-z2/build_rocket_pext_z1/pynqz1_rocket_pext.bit",
    "magic": "0x5A5A0004",
    "core_hz": core_hz,
    "model": graph.get("name"),
    "isa_contract": "fpga/pynq-z2/sw/pext.h",
    "curated_kernels": "fpga/pynq-z2/modelblaster/kernels/pext",
    "pins": {
        "zephyr-chipyard-sw": rev(zcs),
        "tacit-decoder": rev(os.path.join(root, "third_party", "tacit-decoder")),
        "riscv-isa-sim": rev(os.path.join(root, "third_party", "riscv-isa-sim")),
    },
    "console_lines": console.splitlines(),
    "results": {
        "booted": "*** Booting Zephyr OS" in console,
        "run_ok": "TACIT_MB_DONE ok=1" in console,
        "traced_on_hart": hartid,
        "output_bitexact": max_abs_err == 0 and tensor == golden,
        "max_abs_err": max_abs_err,
        "all_dispatches_fast_path": all(d["fast_path"] for d in fpga_per_op.values()),
        "mbp_decoded_total": sum(hw["counts"].values()),
        "mbp_counts_match_derivation": counts_ok,
        "mbp_operands_match_elf": operands_ok,
        "mbp_unknown_at_site": hw["unknown_at_site"],
        "unknown_total": hw["unknown_total"],
        "perfetto_unclosed_slices": hw_pf["unclosed"],
        "marker_slices": hw_pf["slice_counts"].get(marker, 0),
        "all_curated_kernels_traced": all(c > 0 for c in present.values()),
        "dispatches_in_graph_order": hw_pf["dispatch_order"] == want_dispatches,
        "trace_wrapped_buffer": bytes_out > buf_size,
        "spike_pc_mismatches": None if spike is None else spike["pc_mismatches"],
        "spike_unknown_total": None if spike is None else spike["unknown_total"],
        "spike_matches_hardware_mix": None if spike is None else bool(
            all(spike["counts"].get(o, 0) == hw["counts"].get(o, 0)
                for o in ("dot8", "max8", "qmul", "clip8"))),
        "spike_matches_hardware_sequence": None if spike is None else bool(
            spike.get("sequence") and spike["sequence"]["tail_in_caller_frame"] and
            spike["sequence"]["differing_symbol_pairs"] ==
            [[spike["sequence"]["hw_caller"], spike["sequence"]["spike_caller"]]]),
        "all_checks_passed": ok,
    },
    "measured": {
        "traced_cycles": traced_cycles,
        "cold_cycles": cold_cycles,
        "warm_untraced_cycles": warm_cycles,
        "sink_cost_cycles": sink_cost,
        "sink_cost_pct": None if sink_cost is None else round(100.0 * sink_cost / warm_cycles, 3),
        "traced_ms": None if traced_cycles is None else traced_cycles / core_hz * 1000.0,
        "tacit_out_bytes": bytes_out,
        "buffer_bytes": buf_size,
        "l2_flush_cycles": flush_cycles,
        "instructions_decoded": hw["instructions"],
        "packets_decoded": int(re.search(r"Decoded (\d+) packets",
                                         open(os.path.join(run, "fpga", "decode.log")).read()).group(1)),
        "bits_per_instruction": None if not hw["instructions"] else
            round(bytes_out * 8.0 / hw["instructions"], 3),
        "encoder_timestamp_span": ts_span,
        "mbp_dynamic_counts": hw["counts"],
        "mbp_derived_counts": fpga_expect,
        "mbp_derived_per_dispatch": fpga_per_op,
        "mbp_static_sites": len(sites),
        "mbp_addresses_executed": len(hw["seen"]),
        "perfetto": hw_pf,
        "output_tensor": tensor,
        "golden_tensor": golden,
        "per_dispatch_cycles": ops,
        "spike": spike,
    },
}
json.dump(manifest, open(os.path.join(run, "run.json"), "w"), indent=2)
print()
sys.exit(0 if ok else 1)
PY
RC=${PIPESTATUS[0]}
set -e
[ "$RC" -eq 0 ] || die "the decoded trace does not match the image -- see $RUN/mbp_decode.txt"

python3 -c "
import json,sys
d=json.load(open('$RUN/run.json'))
m={k:v for k,v in d['measured'].items() if k not in ('mbp_derived_per_dispatch','spike')}
json.dump({'results':d['results'],'measured':m},sys.stdout,indent=2); print()
"

step "11/11  check"
[ "$NO_EXPECT" = 1 ] && { info "--no-expect: skipping the golden"; info "trace: $RUN/fpga/trace.perfetto.json"; exit 0; }
[ -n "$EXPECT" ] || EXPECT="$IISWC_ROOT/expected/$(basename "$SAMPLE").json"
if [ -f "$EXPECT" ]; then
  info "vs $(basename "$EXPECT")"
  if python3 - "$RUN/run.json" "$EXPECT" <<'PYCHECK'
import json, sys
d = json.load(open(sys.argv[1]))
got = dict(d["results"])
got.update({"measured." + k: v for k, v in d["measured"].items()})
exp = json.load(open(sys.argv[2]))
bad = 0
for k, want in exp.items():
    if k.startswith("_"):
        continue
    have = got.get(k)
    if isinstance(want, dict) and "within" in want:
        lo, hi = want["value"] * (1 - want["within"]), want["value"] * (1 + want["within"])
        ok = have is not None and lo <= have <= hi
        shown = f"{want['value']} +/-{want['within'] * 100:g}%"
    elif isinstance(want, dict) and "at_most" in want:
        ok = have is not None and have <= want["at_most"]
        shown = f"<= {want['at_most']}"
    else:
        ok = have == want
        shown = want
    if not ok:
        bad += 1
    print(f"    {'ok  ' if ok else 'FAIL'}  {k:<36} expected {shown!s:>16}   got {have!s:>12}")
sys.exit(1 if bad else 0)
PYCHECK
  then printf '    \033[1;32mPASS\033[0m  a whole LeNet inference traced through the curated MBP kernels, and every mbp.* in it checked against the image\n'
  else printf '    \033[1;31mFAIL\033[0m  output differs from expected/ -- see the table above\n'; exit 1
  fi
else
  info "no golden file at $EXPECT -- skipping check"
fi

step "Done"
info "open  $RUN/fpga/trace.perfetto.json  at https://ui.perfetto.dev"
[ "$DO_SPIKE" -eq 1 ] && info "  and  $RUN/spike/trace.perfetto.json  for the simulator's view of the same inference"
exit 0
