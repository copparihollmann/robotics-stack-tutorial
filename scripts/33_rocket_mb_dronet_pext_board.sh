#!/usr/bin/env bash
# Lab B13 -- DroNet int8 on the P-ext silicon: the integer batchnorm/add kernels of
# fpga/pynq-z2/docs/DRONET_INTEGER.md together with the MBP kernels of PEXT_KERNELS.md,
# proved BIT-EXACT on hardware and timed.
#
#   modelblaster codegen x2 (scalar + pext, same IR)
#   -> EXHAUSTIVE integer-kernel proof on the host
#   -> west build (chipyard_pynqz1_pext) -> ELF gates -> soft-float call audit
#   -> load pynqz1_rocket_pext.bit -> run the MBP image
#   -> compare the OUTPUT TENSOR element by element against the SCALAR codegen's golden
#
# WHY THIS IS A SEPARATE SCRIPT FROM 30, AND NOT A --model FLAG ON IT.
#
#   30 is the LeNet validation and its result is a pinned baseline.  DroNet differs from
#   LeNet in three ways that each need their own gate, and bolting them onto 30 would put
#   new failure modes in front of a green check that is currently meaningful:
#
#   1. LeNet's graph is conv/pool/linear only.  DroNet adds batchnorm2d_s8 and add_s8,
#      whose ModelBlaster reference expressions DEQUANTIZE TO FLOAT -- 649 and 734
#      instructions per element of libgcc soft-float on this WithoutFPU core
#      (PEXT_SPEC.md section 1.5).  They are replaced here by integer fixed-point curated
#      kernels whose general accuracy class is numeric_drift, NOT bit_exact.  Using them
#      honestly requires a per-model proof, which is stage 3 and which has no analogue in
#      30 because LeNet has neither op.
#
#   2. `kernels_integer_only`, the flag 24 and 30 compute and pin to true, IS STRUCTURALLY
#      UNREACHABLE FOR DRONET and pinning it would be a lie.  That check greps the
#      generated kernels.c source for /float|double|roundf|.../ -- and
#      kernel_batchnorm2d_s8's SIGNATURE is
#         (const int8_t *input, const float *scale, const float *bias, ...)
#      so the word `float` is in kernels.c no matter what the kernel body does.  The
#      grep cannot distinguish a float parameter list from a float inner loop.  Stage 6
#      therefore measures the thing the grep was a proxy for -- how much soft-float the
#      image actually CALLS -- and reports that instead.  See DRONET_INTEGER.md section 5.
#
#   3. The scalar DroNet baseline is ~346 M instructions, about 11 s per iteration on this
#      34.4828 MHz part against LeNet's 8.7 M.  Running it is opt-in (--scalar) rather
#      than default, and the bit-exactness claim does not depend on it: the golden is
#      BAKED from the scalar codegen tree, whose IR is asserted byte-identical to the
#      pext tree's, which is the same chain 30 uses.
#
# WHAT IT DOES NOT TOUCH.  expected/modelblaster_lenet_int8*.json, out/rocket_mb_lenet_*,
# scripts/24_*, scripts/30_*, samples/modelblaster_hart_latency/ and
# fpga/pynq-z2/modelblaster/kernels/pext/ are the validated LeNet baseline.  The DroNet
# curated kernels live in a SIBLING directory, kernels_dronet/pext/, which symlinks the
# three LeNet kernels rather than copying or editing them -- so there is exactly one copy
# of each and this lab cannot perturb that one.
#
# Produces, under out/<name>/:
#   model/scalar/{ir,gen}, model/pext/{ir,gen}   the two codegen trees
#   integer_check.txt   the exhaustive batchnorm/add proof, in full
#   pext/  zephyr.{elf,bin,dis}, console.txt, console.stamps, isa.txt, build.log
#   softfloat.txt       which soft-float helpers the image calls, and from where
#   boot.log, bitexact.txt, run.json
#
# Usage:
#   scripts/with_board.sh ./scripts/33_rocket_mb_dronet_pext_board.sh
#   ./scripts/33_rocket_mb_dronet_pext_board.sh --build-only        # no board, no lock
#   scripts/with_board.sh ./scripts/33_rocket_mb_dronet_pext_board.sh --scalar
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODEL="dronet"
QUANT="int8"
ITERS=3
NAME=""
BOARD="chipyard_pynqz1_pext"
SAMPLE_PEXT="$IISWC_ROOT/samples/modelblaster_pext"
SAMPLE_SCALAR="$IISWC_ROOT/samples/modelblaster_hart_latency"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_pext_z1/pynqz1_rocket_pext.bit"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels_dronet"
LOAD_BIT=1
DO_BOARD=1
DO_SCALAR=0
SECONDS_READ=180
WANT_MTIME_HZ=34483
# The curated conv kernel's repacked-weight block, as a BUILD FLAG -- the kernel declares
# it `#ifndef MB_PEXT_CONV_WBYTES / #define ... 8192`, so this overrides without touching
# the frozen file in kernels/pext/.
#
# 8192 is the shipped default and is right for LeNet, whose largest repacked row set is
# 2,432 B.  DroNet is a different shape: conv_modules.8 has K = 1152, so an 8 KB block
# holds 7 of its 128 output channels and the kernel re-gathers that layer's reduction
# vector 19 times.  Raising it trades gather instructions for cache misses, and the two do
# NOT cancel the way the instruction count suggests -- MEASURED ON THE BOARD, all three
# bit-exact:
#
#        WBYTES   instructions(spike)   cycles(board)      ms     CPI
#          8192            18,576,059      23,040,281   668.2    1.240
#         16384            15,734,994      20,981,796   608.5    1.334
#         65536            14,108,729      19,936,133   578.1    1.413
#
# Instructions fall 24.1%, cycles only 13.5%: CPI rises 14% because a 64 KB block no
# longer fits the 16 KB L1D and starts leaning on a 64 KB L2 it shares with the
# activations.  Spike's flat memory model shows the first column and cannot show the
# third, which is why this default was chosen on silicon and not on the simulator.
# 65536 is still the best of the three by wall clock, by 1.156x, so it is the default here.
CONV_WBYTES=65536

while [ $# -gt 0 ]; do
  case "$1" in
    --model)        MODEL="${2:?}";  shift 2 ;;
    --quant)        QUANT="${2:?}";  shift 2 ;;
    --iters)        ITERS="${2:?}";  shift 2 ;;
    --name)         NAME="${2:?}";   shift 2 ;;
    --board)        BOARD="${2:?}";  shift 2 ;;
    --bit)          BIT="${2:?}";    shift 2 ;;
    --seconds)      SECONDS_READ="${2:?}"; shift 2 ;;
    --conv-wbytes)  CONV_WBYTES="${2:?}";  shift 2 ;;
    --scalar)       DO_SCALAR=1;     shift ;;
    --no-bitstream) LOAD_BIT=0;      shift ;;
    --build-only)   DO_BOARD=0;      shift ;;
    -h|--help)
      sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$NAME" ] || NAME="rocket_mb_${MODEL}_${QUANT}_pext_board"
RUN="$IISWC_OUT/$NAME"
MB="$ZCS/modelblaster"
PATCH="$IISWC_ROOT/patches/0009-modelblaster-pext-backend.patch"
CHECK="$IISWC_ROOT/fpga/pynq-z2/modelblaster/check"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")

rm -rf "$RUN"; mkdir -p "$RUN"

# ---------------------------------------------------------------------------
step "1/8  apply the pext backend patch to the modelblaster submodule (idempotent)"
# NOTE: 0009 is UNCHANGED for DroNet.  The integer batchnorm/add kernels needed no new
# AlgorithmCandidate because `direct` is already a universal-affinity candidate for both
# ops, and a curated file at <curated-dir>/<target>/<target>_<op>_direct.c is probed for
# it by path.  That is the whole reason this lab carries no second patch.
need_file "$PATCH"
if git -C "$MB" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  info "already applied"
elif git -C "$MB" apply --check "$PATCH" >/dev/null 2>&1; then
  run git -C "$MB" apply "$PATCH"; info "applied"
else
  die "patches/0009 neither applies nor is applied to $MB -- the submodule is dirty"
fi
( cd "$ZCS" && PYTHONPATH="$ZCS" python -c "
from modelblaster.pipeline import backends
b = backends.get('pext')
assert b is not None and b.atol_override == 0.0, b
print('    backend pext present, atol_override =', b.atol_override)
" ) || die "the pext backend did not register"

# ---------------------------------------------------------------------------
step "2/8  modelblaster codegen -- scalar and pext, from the same IR"
codegen () {                     # $1 = scalar|pext
  local t="$1" ir="$RUN/model/$1/ir" gen="$RUN/model/$1/gen"
  mkdir -p "$ir" "$gen"
  local extra=()
  [ "$t" = "pext" ] && extra=(--global-curated-dir "$KERNELS")
  ( cd "$ZCS" && PYTHONPATH="$ZCS" CPATH="$IISWC_ROOT/fpga/pynq-z2/sw:${CPATH:-}" \
    python -m modelblaster.pipeline.extract_graph \
      --model "$MODEL" --out-dir "$ir" --quant "$QUANT" \
      --num-calibration 1 --fusion-target "$t" \
    && PYTHONPATH="$ZCS" python -m modelblaster.pipeline.generate_skeleton \
      --ir "$ir/graph.json" --weights "$ir/weights.npz" --io "$ir/io.npz" \
      --out-dir "$gen" --backend "$t" \
    && PYTHONPATH="$ZCS" CPATH="$IISWC_ROOT/fpga/pynq-z2/sw:${CPATH:-}" \
       python -m modelblaster.pipeline.generate_kernels \
      --ir "$ir/graph.json" --out-dir "$gen" --backend reference --target "$t" \
      --quant "$QUANT" --io "$ir/io.npz" --repo-root "$MB" \
      --build-dir "$RUN/model/$1/kverify" --harness-dir "$MB/harness" \
      --cache-dir "$RUN/model/$1/cache" --algorithms all "${extra[@]}" \
  ) >> "$RUN/codegen.log" 2>&1 || { tail -40 "$RUN/codegen.log"; die "$t codegen failed"; }
  info "$t: $gen"
}
codegen scalar
codegen pext
SGEN="$RUN/model/scalar/gen"; PGEN="$RUN/model/pext/gen"

# The comparison below is only meaningful if the two trees quantised identically.
cmp -s "$RUN/model/scalar/ir/graph.json" "$RUN/model/pext/ir/graph.json" \
  || die "the scalar and pext IR differ -- the comparison would be of two quantisations"
cmp -s "$SGEN/test_golden.bin" "$PGEN/test_golden.bin" || die "goldens differ"
cmp -s "$SGEN/test_input.bin"  "$PGEN/test_input.bin"  || die "inputs differ"
info "IR, input and golden byte-identical between the two trees"

# Which ops actually resolved to a curated MBP kernel, and which did not. DroNet cannot
# be all-curated (relu_s8 and sigmoid_s8 have no pext kernel and barely matter -- 0.1% of
# the frame between them), so this REPORTS rather than dies, and names the fallbacks.
CURATED=$(python3 - "$PGEN/kernel_picks.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))["picks"]
cur = sorted(k for k, v in p.items() if v["source"] == "curated")
ref = sorted(k for k, v in p.items() if v["source"] != "curated")
print("curated: " + ",".join(cur))
print("reference: " + (",".join(ref) or "(none)"))
PY
)
printf '    %s\n' "$CURATED"
echo "$CURATED" | grep -q "curated:.*batchnorm2d_s8" \
  || die "batchnorm2d_s8 did NOT resolve to the integer curated kernel -- it would run
       the float reference at ~649 instructions per element and this lab would measure
       nothing but soft-float"
echo "$CURATED" | grep -q "curated:.*add_s8" || die "add_s8 did not resolve to curated"
echo "$CURATED" | grep -q "curated:.*conv2d_s8" || die "conv2d_s8 did not resolve to curated"

# ---------------------------------------------------------------------------
step "3/8  EXHAUSTIVE proof: the integer batchnorm/add kernels vs the float reference"
# This is the gate that replaces "bit_exact by declaration" for these two kernels. Both
# are pointwise int8 maps, so their whole input domain is finite and small, and this
# enumerates ALL of it -- not a sample. See check_dronet_integer.c for why that is the
# only honest way to ship a numeric_drift kernel against a max_abs_err = 0 bar.
( cd "$CHECK" && ZCS="$ZCS" python3 check_dronet_integer.py \
    --ir "$RUN/model/pext/ir" --kernels-dir "$KERNELS/pext" \
    --build-dir "$RUN/integer_check" --json "$RUN/integer_check.json" ) \
  > "$RUN/integer_check.txt" 2>&1 || { cat "$RUN/integer_check.txt"
    die "the integer batchnorm/add kernels are NOT bit-exact on this graph's parameters.
       They are numeric_drift in general (PEXT_SPEC.md section 1.5), so this is a real
       possibility and not a bug in the check: if the model was recalibrated, the
       parameters moved. Do NOT widen a tolerance -- either keep the float reference for
       the affected op or re-derive the fixed-point form."; }
sed -n '1,20p' "$RUN/integer_check.txt" | sed 's/^/    /'
grep -q '^RESULT: PASS' "$RUN/integer_check.txt" || die "integer kernel proof did not PASS"

# ---------------------------------------------------------------------------
step "4/8  west build -- the MBP image"
MB_KERNEL_CFLAGS=$(cd "$ZCS" && PYTHONPATH="$ZCS" python -c "
from modelblaster.pipeline import backends
print(' '.join(backends.get('pext').resolved_kernel_cflags('$MB')))")
[ -n "$CONV_WBYTES" ] && MB_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS -DMB_PEXT_CONV_WBYTES=$CONV_WBYTES"
info "kernel cflags: $MB_KERNEL_CFLAGS"

build_one () {                   # $1 = pext|scalar
  local w="$1" d="$RUN/$1" sample cf=()
  mkdir -p "$d"
  if [ "$w" = "pext" ]; then sample="$SAMPLE_PEXT"; cf=(-DMODELBLASTER_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS")
  else sample="$SAMPLE_SCALAR"; fi
  local gen; [ "$w" = "pext" ] && gen="$PGEN" || gen="$SGEN"
  run west build -p always -b "$BOARD" "$sample" -d "$d/build" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$gen" -DMB_ITERS="$ITERS" "${cf[@]}" \
      > "$d/build.log" 2>&1 || { tail -30 "$d/build.log"; die "$w build failed"; }
  cp "$d/build/zephyr/zephyr.elf" "$d/zephyr.elf"
  cp "$d/build/zephyr/zephyr.bin" "$d/zephyr.bin"
  "$OBJDUMP" -d "$d/zephyr.elf" > "$d/zephyr.dis"
}
OBJDUMP="$ZEPHYR_SDK_INSTALL_DIR/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-objdump"
READELF="$ZEPHYR_SDK_INSTALL_DIR/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-readelf"
[ -x "$OBJDUMP" ] || OBJDUMP=$(command -v riscv64-zephyr-elf-objdump)
[ -x "$READELF" ] || READELF=$(command -v riscv64-zephyr-elf-readelf)
build_one pext
[ "$DO_SCALAR" -eq 1 ] && build_one scalar

# ---------------------------------------------------------------------------
step "5/8  ELF gates"
gate () {                        # $1 = pext|scalar, $2 = 0|nonzero MBP encodings wanted
  local w="$1" want="$2" d="$RUN/$1"
  local cfg="$d/build/zephyr/.config"
  local hz ncpu
  hz=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$cfg" | cut -d= -f2)
  [ "$hz" = "$WANT_MTIME_HZ" ] || die "$w: CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$hz, want $WANT_MTIME_HZ
       (this constant also sets the UART baud divisor -- wrong here is a garbled console)"
  ncpu=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$cfg" | cut -d= -f2)
  [ "${ncpu:-0}" -ge 2 ] || die "$w: CONFIG_MP_MAX_NUM_CPUS=$ncpu"
  grep -q '^CONFIG_SMP=y' "$cfg" || die "$w: not an SMP build"
  grep -q '^CONFIG_FPU=y' "$cfg" && die "$w: CONFIG_FPU=y on a WithoutFPU core"
  if [ "$w" = "pext" ]; then
    grep -q '^CONFIG_MB_PEXT=y' "$cfg" || die "pext: CONFIG_MB_PEXT is not y"
    grep -q '^CONFIG_SCHED_CPU_MASK=y' "$cfg" || die "pext: CONFIG_SCHED_CPU_MASK is not y
       -- without it k_thread_cpu_pin does not exist and MBP cannot be kept off hart 1"
  fi
  { "$READELF" -h "$d/zephyr.elf" | grep -E 'Flags'
    "$READELF" -A "$d/zephyr.elf" | grep Tag_RISCV_arch ; } > "$d/isa.txt"
  grep -q 'soft-float ABI' "$d/isa.txt" || die "$w: not a soft-float ABI build"
  local arch; arch=$(grep Tag_RISCV_arch "$d/isa.txt" | sed 's/.*"\(.*\)".*/\1/')
  case "$arch" in *_f[0-9]*|*_d[0-9]*|*_v[0-9]*)
      die "$w: ELF advertises f/d/v: $arch -- this core has none of them" ;;
  esac
  local fp; fp=$(grep -cE '^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]+(f(add|sub|mul|div|sqrt|mv|cvt|ld|sd|lw|sw|sgnj|min|max|eq|lt|le|class|madd|msub|nmadd|nmsub)|c\.f(ld|sd|lw|sw)|v(set|le|se|add|mul|mac))' "$d/zephyr.dis" || true)
  [ "${fp:-0}" -eq 0 ] || die "$w: $fp float/vector instructions in the image"
  python3 - "$d/zephyr.dis" "$want" "$w" <<'PY' || die "$w: MBP encoding gate failed"
import re, sys
names = ["dot8", "max8", "qmul", "clip8"]
counts = [0, 0, 0, 0]; other = 0
for word in re.findall(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", open(sys.argv[1]).read(), re.M):
    v = int(word, 16)
    if (v & 0x7f) != 0x0b: continue
    if (v >> 25) != 0 or ((v >> 12) & 7) > 3: other += 1; continue
    counts[(v >> 12) & 7] += 1
total = sum(counts)
print(f"    {sys.argv[3]:<6} custom-0 encodings: " +
      ", ".join(f"{n}={c}" for n, c in zip(names, counts)) + f"   total {total}")
if other: print(f"    WARNING: {other} custom-0 words that are NOT MBP")
sys.exit(0 if (total == 0 if sys.argv[2] == "0" else total > 0) else 1)
PY
  info "$w: bin $(fsize "$d/zephyr.bin")   elf $(fsize "$d/zephyr.elf")   mtime ${hz} Hz"
}
gate pext nonzero
[ "$DO_SCALAR" -eq 1 ] && gate scalar 0

# ---------------------------------------------------------------------------
step "6/8  soft-float audit -- what the image actually CALLS"
# THIS REPLACES kernels_integer_only FOR DRONET, and section 2 of this file's header says
# why the grep it replaces cannot work here. A libgcc soft-float call is an ordinary
# integer instruction sequence, so it survives every ELF gate above; the only way to see
# it is to look for the calls.
python3 - "$RUN/pext/zephyr.dis" <<'SFPY' | tee "$RUN/softfloat.txt"
import re, sys, collections
# objdump renders a call as either
#     jal  ra,80000854 <__mulsf3>
# or  jalr 530(ra) # 80000854 <__mulsf3>
# and renders an ordinary branch INSIDE the helper as <__mulsf3+0x10c>. Only the
# no-offset form is a call, so requiring the symbol to end the line at '>' excludes
# the helper's own control flow -- which is what made the first version of this audit
# report a confident, wrong zero while the image called __mulsf3 31 times.
CALL = re.compile(r"\b(jal|jalr|j|call|tail)\b.*<([A-Za-z_][A-Za-z0-9_]*)>\s*$")
HELPER = re.compile(r"^(__(add|sub|mul|div|neg|eq|ne|lt|le|gt|ge|fix|float|extend|trunc)"
                    r"[a-z0-9]*(sf|df)[a-z0-9]*\d?|roundf|expf|lrintf|sqrtf|logf|powf)$")
cur = None
per = collections.defaultdict(collections.Counter)
for line in open(sys.argv[1]):
    m = re.match(r"^[0-9a-f]+ <([^>]+)>:", line)
    if m:
        cur = m.group(1); continue
    m = CALL.search(line.rstrip())
    if m and HELPER.match(m.group(2)) and cur and not HELPER.match(cur):
        per[cur][m.group(2)] += 1
kern = {f: c for f, c in per.items() if f.startswith("kernel_")}
print("soft-float CALL SITES inside the generated kernels (static):")
if not kern:
    print("  none -- every kernel_* function is integer-only")
for f in sorted(kern):
    print("  %-40s %s" % (f, ", ".join("%sx%d" % (h, n) for h, n in sorted(kern[f].items()))))
print()
print("  Where they sit is the whole point. In the integer batchnorm they are the")
print("  per-CHANNEL fold of the affine into Q(S); in the integer add, the per-DISPATCH")
print("  fold of the two scale ratios. Neither is in an element loop, which is what took")
print("  batchnorm from 470 to 21.6 and add from 559 to 22.1 instructions per element.")
print("  sigmoid_s8 keeps the float reference and is 1,953 instructions for its one")
print("  element. See DRONET_INTEGER.md section 5.")
other = sorted((f, c) for f, c in per.items() if not f.startswith("kernel_"))
tot = sum(sum(c.values()) for _, c in other)
print("\nelsewhere in the image (Zephyr, libc, startup): %d call sites in %d functions"
      % (tot, len(other)))
SFPY

# ---------------------------------------------------------------------------
if [ "$DO_BOARD" -eq 0 ]; then
  step "BUILD ONLY -- image at $RUN/pext/zephyr.bin"; exit 0
fi

step "7/8  load the P-ext PL, then run the MBP image on hart 0"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_pext.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
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
  grep -q 'MAGIC = 0x5A5A0003' "$RUN/boot.log" && { cat "$RUN/boot.log"
    die "the plain DUAL-CORE bitstream is loaded (MAGIC 0x5A5A0003) -- no MBP on either hart"; }
  grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log" && { cat "$RUN/boot.log"
    die "the SINGLE-core bitstream is loaded (MAGIC 0x5A5A0002)"; }
  grep -q 'MAGIC = 0x5A5A0001' "$RUN/boot.log" && { cat "$RUN/boot.log"
    die "the DRAM self-test bitstream is loaded (MAGIC 0x5A5A0001)"; }
  return 0
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_pext.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_pext.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0004' "$RUN/boot.log" || { wrong_pl; cat "$RUN/boot.log"
  die "P-ext bitstream not reachable over GP0"; }
grep -E 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true

boot_and_read () {               # $1 = pext|scalar, $2 = terminating line
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
    echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_pext.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
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
boot_and_read pext 'RESULT:'
printf '%s\n' "----------------------------------------------------------------"
grep -vE '^MB_PEXT_OP ' "$RUN/pext/console.txt"
printf '%s\n' "----------------------------------------------------------------"
if [ "$DO_SCALAR" -eq 1 ]; then
  info "running the SCALAR image on the same bitstream (this is ~11 s per iteration)"
  boot_and_read scalar 'RESULT:'
fi

# ---------------------------------------------------------------------------
step "8/8  bit-exactness, cycles, manifest"
python3 - "$RUN" "$SGEN/test_golden.bin" "$PGEN/kernel_picks.json" \
         "$RUN/integer_check.json" "$MODEL" "$QUANT" "$ITERS" "$DO_SCALAR" \
  <<'PY' | tee "$RUN/bitexact.txt"
import json, os, re, sys
run, golden_p, picks_p, intchk_p, model, quant, iters, do_scalar = sys.argv[1:9]
con = open(os.path.join(run, "pext", "console.txt"), errors="replace").read()
golden = list(open(golden_p, "rb").read())
golden = [g - 256 if g > 127 else g for g in golden]

m = re.search(r"^MB_PEXT_OUT((?:\s+-?\d+)+)\s*$", con, re.M)
if not m:
    print("no MB_PEXT_OUT line on the console"); sys.exit(1)
out = [int(x) for x in m.group(1).split()]
n = min(len(out), len(golden))
delta = [out[i] - golden[i] for i in range(n)]
maxerr = max((abs(d) for d in delta), default=0)
print(f"output tensor, {len(out)} element(s), against the SCALAR codegen's baked golden")
print(f"  mbp    {out}")
print(f"  golden {golden}")
print(f"  delta  {delta}")
print(f"  max_abs_err = {maxerr}  {'(BIT-EXACT)' if maxerr == 0 else '*** NOT BIT-EXACT ***'}")

def g1(pat, text=con, cast=float):
    mm = re.search(pat, text, re.M)
    return cast(mm.group(1)) if mm else None

res = {
    "booted": True, "model": model, "quant": quant,
    "iterations_per_hart": int(iters),
    "mb_pext_hw": g1(r"MB_PEXT_BUILD .*\bhw=(\d+)", cast=int),
    "output_len": len(out),
    "max_abs_err_vs_scalar_golden": maxerr,
    "guest_reported_max_abs_err": g1(r"MB_PEXT_RUN .*\bmax_abs_err=(\d+)", cast=int),
    "pext_ran_on_hart": g1(r"MB_PEXT_RUN .*\bmhartid=(\d+)", cast=int),
    "negative_test_trapped": bool(re.search(r"MB_PEXT_NEG .*\btrapped=1", con)),
    "negative_test_mcause": g1(r"MB_PEXT_NEG .*\bmcause=(\d+)", cast=int),
    "result_pass": bool(re.search(r"^RESULT:\s*PASS", con, re.M)),
}
med = g1(r"MB_PEXT_RUN .*\bmedian=(\d+)", cast=int)
res["pext_hart0_median_cycles"] = med
picks = json.load(open(picks_p))["picks"]
res["kernel_sources"] = {k: v["source"] for k, v in sorted(picks.items())}
res["curated_ops"] = sorted(k for k, v in picks.items() if v["source"] == "curated")
res["reference_ops"] = sorted(k for k, v in picks.items() if v["source"] != "curated")
res["integer_kernels_exhaustively_bit_exact"] = \
    json.load(open(intchk_p))["result"] == "PASS"
res["graph_ops"] = sorted({v for v in
    (json.load(open(os.path.join(run, "model", "pext", "ir", "graph.json")))["ops"])
    and {o["op"] for o in json.load(open(os.path.join(run, "model", "pext", "ir",
                                                      "graph.json")))["ops"]}})
res["ir_identical_scalar_vs_pext"] = True
res["golden_identical_scalar_vs_pext"] = True

ops = []
for mm in re.finditer(r"^MB_PEXT_OP id=(\d+) name=(\S+) op=(\S+) shape=(\S+) cycles=(\d+)",
                      con, re.M):
    ops.append({"id": int(mm.group(1)), "name": mm.group(2), "op": mm.group(3),
                "shape": mm.group(4), "cycles": int(mm.group(5))})
res["dispatches_profiled"] = len(ops)
if med:
    HZ = 34482759.0
    res["pext_hart0_median_ms"] = round(med / HZ * 1000.0, 3)
    res["pext_hart0_fps"] = round(HZ / med, 3)
if ops:
    by = {}
    for o in ops: by[o["op"]] = by.get(o["op"], 0) + o["cycles"]
    tot = sum(by.values()) or 1
    print("\nper-op cycles on hart 0 (one inference):")
    for k, v in sorted(by.items(), key=lambda x: -x[1]):
        print(f"  {k:16s} {v:12,d}  {100*v/tot:5.1f}%")
    res["cycles_by_op"] = by

if do_scalar == "1":
    sp = os.path.join(run, "scalar", "console.txt")
    if os.path.exists(sp):
        sc = open(sp, errors="replace").read()
        sm = re.search(r"MB_HART cpu=0 .*\bmedian=(\d+)", sc)
        if sm:
            res["scalar_hart0_median_cycles_same_bitstream"] = int(sm.group(1))
            if med:
                res["cycle_speedup_same_bitstream"] = round(int(sm.group(1)) / med, 3)

json.dump({"results": res, "per_dispatch": ops},
          open(os.path.join(run, "run.json"), "w"), indent=2)
print("\nwrote " + os.path.join(run, "run.json"))
if maxerr != 0:
    print("\nBIT-EXACTNESS FAILED ON HARDWARE"); sys.exit(1)
PY
grep -q 'max_abs_err = 0' "$RUN/bitexact.txt" \
  || die "BIT-EXACTNESS FAILED ON HARDWARE -- see $RUN/bitexact.txt"

EXPECT="$IISWC_ROOT/expected/modelblaster_${MODEL}_${QUANT}_pext.json"
if [ -f "$EXPECT" ]; then
  python3 - "$RUN/run.json" "$EXPECT" <<'PY' || die "golden check failed"
import json, sys
got = json.load(open(sys.argv[1]))["results"]
exp = json.load(open(sys.argv[2]))
bad = []
for k, want in exp.items():
    if k.startswith("_"): continue
    have = got.get(k)
    if isinstance(want, dict) and ("min" in want or "max" in want):
        ok = have is not None and ("min" not in want or have >= want["min"]) \
             and ("max" not in want or have <= want["max"])
    else:
        ok = have == want
    print(f"  {'ok  ' if ok else 'FAIL'} {k}: got {have!r} want {want!r}")
    if not ok: bad.append(k)
sys.exit(1 if bad else 0)
PY
  info "golden check passed against $(basename "$EXPECT")"
else
  warn "no golden file at $EXPECT -- nothing checked against"
fi
step "DONE -- $RUN"
