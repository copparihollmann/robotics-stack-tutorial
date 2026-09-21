#!/usr/bin/env bash
# Lab B22 -- Visual Wake Words on this silicon, and the two architecture decisions that
# cost more than the model does.
#
#   scripts/with_board.sh ./scripts/42_rocket_vision_board.sh
#   scripts/with_board.sh ./scripts/42_rocket_vision_board.sh --archs "cnn mbnet"
#   ./scripts/42_rocket_vision_board.sh --build-only
#
# Five person/no-person classifiers on MLCommons' Visual Wake Words corpus
# (vw_coco2014_96, 109,619 COCO-2014 images), all taking a 96x96 tensor produced by
# fpga/pynq-z2/sw/frame_fe.c from a 324x324 HM01B0 frame, all trained on features that
# same C produced:
#
#   mbnet      the MLPerf Tiny reference shape -- MobileNetV1 alpha=0.25.  7,157,888 MACs.
#   cnn        the SAME MAC budget in DENSE convolutions.  7,154,048 MACs (-0.054 %).
#   cnn_tiny   a quarter of it.  1,843,328 MACs.
#   cnn_rgb    `cnn` with a THREE-channel first layer: a demosaiced colour frame.
#   cnn_bayer  `cnn` fed the RAW Bayer mosaic as four 48x48 planes, no demosaic.
#
# THE TWO QUESTIONS THIS LAB ANSWERS, both of them about the ISA and not the model.
#
#   1. Depthwise.  MBP.DOT8 retires eight int8 MACs in one cycle by reducing along the
#      INPUT-CHANNEL axis, and a depthwise convolution has no such axis.  The MLPerf
#      Tiny VWW reference is depthwise-separable throughout.  SPEECH_ON_ROCKET.md
#      section 5 measured 3.42x on the audio version of this pair; `mbnet` against `cnn`
#      is the vision version, at matched MACs on one piece of silicon.
#
#   2. Colour.  DOT8 consumes EIGHT int8 lanes per instruction, so a monochrome sensor
#      guarantees IC = 1 at the layer where all the pixels are -- seven lanes idle.  RGB
#      gives 3 and raw Bayer gives 4, and Bayer costs no extra bytes on the wire because
#      the colour is in the filter array.  `cnn` / `cnn_rgb` / `cnn_bayer` differ ONLY in
#      layer 1, so the cycle difference between them IS that layer.
#
# Each arch is code-generated TWICE from one extract_graph run -- scalar and pext -- and
# both images run on the same bitstream in the same board session, so every speedup here
# is a cycle ratio on one piece of silicon at one clock.
#
# Runs on the FULL-FEATURE bitstream (MAGIC 0x5A5A0006): the P-ext bitstream plus the PDM
# microphone and a stock GPIO.  Neither peripheral is touched here.  It is used because it
# is the one bitstream that carries every feature and is therefore the one on the bench --
# and because nothing in this lab needs the camera routed, which is the whole point of
# replaying frames from DRAM.
#
# Produces out/<name>/<arch>/{scalar,pext}/ and out/<name>/run.json.
# THE BITSTREAM THIS LAB IS VALIDATED AGAINST, set BEFORE lib/bitstream_id.sh is
# sourced -- that file defaults BIT_ACCEPTED with `${BIT_ACCEPTED:-...}` to the two
# microphone builds, so an assignment after the source is silently ignored and the run
# dies on a bitstream it was written for.  Same discipline as the speech labs: SOC_MAGIC
# names the CONFIGURATION and every build of the full-feature variant reports
# 0x5A5A0006, so the md5 of the file actually loaded is the only thing that identifies
# the silicon these numbers came off.  An environment override still wins.
: "${BIT_ACCEPTED:=4c8f7bf79e2f2464908eca8656abd691}"
export BIT_ACCEPTED

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

ARCHS="cnn mbnet cnn_tiny cnn_rgb cnn_bayer"
# The scalar baseline exists for cnn / mbnet / cnn_tiny, which is where the depthwise
# question lives. The colour pair is a pext-only comparison on purpose: IC at layer 1 is
# a statement about DOT8's lanes, and a scalar build has no lanes to waste.
SCALAR_ARCHS="cnn mbnet cnn_tiny"
QUANT="int8"
PER_CHANNEL=0
ITERS=11
# One scalar VWW inference is ~230 M cycles = 6.7 s. Eleven of those on each of five
# graphs does not fit in any reasonable console window and does not need to: Lab B5
# measured the spread across 11 iterations at 0.00 % of the median.
SCALAR_ITERS=3
NAME="rocket_vision"
BOARD="chipyard_pynqz1_micrgb"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_z1/pynqz1_rocket_micrgb.bit"
SAMPLE_PEXT="$IISWC_ROOT/samples/modelblaster_pext"
SAMPLE_SCALAR="$IISWC_ROOT/samples/modelblaster_hart_latency"
EXPECT="$IISWC_ROOT/expected/vision_board.json"
LOAD_BIT=1
DO_BOARD=1
DO_ACC=1
# Two read windows, because the two images differ by 30x in how long they take to say
# anything: an MBP inference is ~0.3 s and eleven of them plus the boot fit in 90 s, while
# the scalar baseline runs the same graph with the reference kernels on BOTH harts -- 7.2
# MMAC at 0.031 MAC/cycle is ~6.7 s on hart 0 and ~14 s on hart 1, three times each.
# console.py's idle detector cannot be used here: the apps print only when they finish, so
# "3 s of silence" is exactly what a running inference looks like.
SECONDS_READ_PEXT=90
SECONDS_READ_SCALAR=300
WANT_MTIME_HZ=34483
NCALIB=64
VWW_FEAT="${VWW_FEAT:?set VWW_FEAT to the Visual Wake Words feature directory}"

while [ $# -gt 0 ]; do
  case "$1" in
    --archs) ARCHS="${2:?}"; shift 2 ;;
    --scalar-archs) SCALAR_ARCHS="${2:?}"; shift 2 ;;
    --name)  NAME="${2:?}";  shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --bit)   BIT="${2:?}";   shift 2 ;;
    --feat)  VWW_FEAT="${2:?}"; shift 2 ;;
    --iters) ITERS="${2:?}"; shift 2 ;;
    --seconds-read) SECONDS_READ_PEXT="${2:?}"; SECONDS_READ_SCALAR="${2:?}"; shift 2 ;;
    --scalar-iters) SCALAR_ITERS="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only)   DO_BOARD=0; shift ;;
    --no-accuracy)  DO_ACC=0; shift ;;
    --per-channel)  PER_CHANNEL=1; shift ;;
    --per-tensor)   PER_CHANNEL=0; shift ;;
    --no-check)     EXPECT=""; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

MB="$ZCS/modelblaster"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
VISION="$IISWC_ROOT/fpga/pynq-z2/modelblaster/vision"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB -- scripts/00_bootstrap.sh --modelblaster"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
export IISWC_ROOT

for A in $ARCHS; do
  need_file "$VISION/weights/${A}_folded.npz" \
    "no trained weights for '$A' -- see fpga/pynq-z2/docs/CAMERA_TASK.md section 10"
done

# ---------------------------------------------------------------------------------
# Apply a ModelBlaster patch idempotently.
#
# THE THIRD CASE, which the obvious two-way test gets wrong.  patches/0060 edits the SAME
# hunks of pipeline/backends.py that 0009 does, so on a tree carrying both, 0009 neither
# applies (it is in) nor reverse-applies (0060 moved its context).  A lab that treats that
# as an error refuses to run on a perfectly good tree; one that ignores it silently runs
# on a tree that may be missing the backend entirely.  So the fallback is a POSITIVE test
# for what the patch provides, named per patch, and it says which of the three happened.
mb_patch () {   # $1 = patch basename (no .patch), $2... = grep -q marker test
  local p="$1"; shift
  local f="$IISWC_ROOT/patches/$p.patch"
  need_file "$f" "missing patch"
  if git -C "$MB" apply --check "$f" >/dev/null 2>&1; then
    run git -C "$MB" apply "$f"; info "applied $p"
  elif git -C "$MB" apply --reverse --check "$f" >/dev/null 2>&1; then
    info "$p already applied"
  elif [ $# -gt 0 ] && "$@" >/dev/null 2>&1; then
    info "$p neither applies nor reverse-applies, but the tree provides what it does"
    info "  (expected when a later patch has rewritten the same hunks -- 0060 over 0009)"
  else
    die "patches/$p.patch neither applies nor is applied to $MB, and the tree does not
       provide what it installs."
  fi
}

# Does the pipeline know the `pext` backend?  That is what 0009 installs, and it is a
# property of the tree rather than of the patch's line numbers.
mb_has_pext_backend () {
  ( cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
raise SystemExit(0 if 'pext' in backends.BACKENDS else 1)" )
}

step "1/6  the ModelBlaster patches"
mb_patch 0009-modelblaster-pext-backend mb_has_pext_backend
mb_patch 0070-modelblaster-vww-models

# PER-CHANNEL IS AN AXIS HERE, AND THE MEASUREMENT SAYS IT IS NOT OPTIONAL.
#
# Per-TENSOR int8 measures 52.60 % on this task against 82.37 % in fp32 -- chance, with a
# person recall of 0.7 % -- and per-CHANNEL measures 82.40 %, which is fp32 to within the
# noise. That is 29.8 points, against the 3.62 SPEECH_ON_ROCKET.md section 3.4 measured on
# the audio side; CAMERA_TASK.md section 6.3 has the mechanism.
#
# And it is buyable, which it was not when that section was written: patches/0060
# registered curated MBP kernels for conv2d_s8_pc and linear_s8_pc, so --per-channel keeps
# the packed-SIMD path instead of falling back to the scalar reference. This flag runs the
# A/B rather than assuming either half of it.
PC_ARG=()
[ "$PER_CHANNEL" -eq 1 ] && PC_ARG=(--per-channel)
if [ "$PER_CHANNEL" -eq 1 ]; then
  info "quantisation: per-CHANNEL (conv2d_s8_pc / linear_s8_pc, curated MBP via patches/0060)"
else
  info "quantisation: per-TENSOR"
fi

step "2/6  codegen: $(echo $ARCHS | wc -w) architecture(s)"
codegen () {   # $1 = arch, $2 = target
  local a="$1" t="$2" ir="$RUN/$1/$2/ir" gen="$RUN/$1/$2/gen" extra=()
  mkdir -p "$ir" "$gen" "$RUN/$1/$2/cache"
  [ "$t" = pext ] && extra=(--global-curated-dir "$KERNELS")
  ( cd "$ZCS" && python -m modelblaster.pipeline.extract_graph \
      --model "vww_$a" --out-dir "$ir" --quant "$QUANT" "${PC_ARG[@]}" \
      --num-calibration "$NCALIB" --fusion-target "$t" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "extract_graph ($a/$t) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_skeleton \
      --ir "$ir/graph.json" --weights "$ir/weights.npz" --io "$ir/io.npz" \
      --out-dir "$gen" --backend "$t" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "generate_skeleton ($a/$t) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_kernels \
      --ir "$ir/graph.json" --out-dir "$gen" --backend reference --target "$t" \
      --quant "$QUANT" --io "$ir/io.npz" --repo-root "$MB" \
      --build-dir "$RUN/$a/$t/kverify" --harness-dir "$MB/harness" \
      --cache-dir "$RUN/$a/$t/cache" --algorithms all "${extra[@]}" ) \
    >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "generate_kernels ($a/$t) failed"; }
  need_file "$gen/kernels.c" "codegen ($a/$t) produced no kernels"
}
for A in $ARCHS; do
  run codegen "$A" scalar
  run codegen "$A" pext
  # The two builds MUST be the same network, or nothing compared between them means
  # anything. Same check Lab B10 and Lab B17 make, for the same reason.
  cmp -s "$RUN/$A/scalar/ir/graph.json" "$RUN/$A/pext/ir/graph.json" \
    || die "$A: the scalar and pext IR differ"
  cmp -s "$RUN/$A/scalar/gen/test_golden.bin" "$RUN/$A/pext/gen/test_golden.bin" \
    || die "$A: the two baked int8 goldens differ"
  OPS=$(python3 -c "import json,collections;g=json.load(open('$RUN/$A/pext/ir/graph.json'));print(' '.join('%s x%d'%(k,v) for k,v in sorted(collections.Counter(o['op'] for o in g['ops']).items())))")
  info "$A: $OPS"
  # Which dispatches actually got a curated MBP kernel, read out of the generated C
  # rather than assumed. For mbnet this is the whole point of the lab.
  python3 "$IISWC_ROOT/fpga/pynq-z2/modelblaster/vision/curated_report.py" \
      "$RUN/$A/pext/gen/kernels.c" "$RUN/$A/pext/ir/graph.json" "$A" \
      > "$RUN/$A/curated.txt"
  sed 's/^/    /' "$RUN/$A/curated.txt"
  # Per-layer MAC counts, so the per-dispatch cycles the board reports can be turned
  # into cycles/MAC for ONE layer -- which is what the colour question is about.
  python3 - "$VISION" "$A" > "$RUN/$A/layer_macs.json" <<'PYL'
import json, sys
sys.path.insert(0, sys.argv[1])
from vision_models import ARCHS, FEED, FEED_SHAPE, macs_by_layer
a = sys.argv[2]
m = ARCHS[a]()
rows = macs_by_layer(m, FEED_SHAPE[FEED[a]])
json.dump([{"name": n, "in": list(i), "out": list(o), "ic": ic, "k": k, "macs": mm}
           for n, i, o, ic, k, mm in rows], sys.stdout, indent=1)
PYL
done

step "3/6  int8 accuracy on the whole held-out set"
if [ "$DO_ACC" -eq 1 ] && [ -f "$VWW_FEAT/meta.json" ]; then
  python3 "$VISION/int8_accuracy.py" --run "$RUN" --archs "$ARCHS" --feat "$VWW_FEAT" \
    | tee "$RUN/accuracy.txt" || warn "int8 accuracy sweep failed"
elif [ "$DO_ACC" -eq 0 ]; then
  info "--no-accuracy: skipping the held-out sweep (the cycle counts do not need it,"
  info "  but no accuracy number from this run is valid without it)"
else
  warn "no featurised corpus at $VWW_FEAT -- skipping the accuracy sweep (--feat)"
fi

step "4/6  build the Zephyr images"
MB_KERNEL_CFLAGS=$(cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['pext'].kernel_cflags))" 2>/dev/null || echo "-DMB_PEXT_HW=1")
for A in $ARCHS; do
  TARGETS="pext"
  case " $SCALAR_ARCHS " in *" $A "*) TARGETS="pext scalar" ;; esac
  for T in $TARGETS; do
    S="$SAMPLE_PEXT"; N="$ITERS"
    [ "$T" = scalar ] && { S="$SAMPLE_SCALAR"; N="$SCALAR_ITERS"; }
    D="$RUN/$A/$T"
    run west build -p always -b "$BOARD" "$S" -d "$D/build" -- \
        -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DMB_ITERS="$N" \
        -DMODELBLASTER_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS" >> "$RUN/build.log" 2>&1 \
      || { tail -40 "$RUN/build.log"; die "west build failed for $A/$T"; }
    cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
    cfg="$D/build/zephyr/.config"
    if [ "$T" = pext ]; then
      grep -q '^CONFIG_MB_PEXT=y' "$cfg" || die "$A/pext: CONFIG_MB_PEXT is not set"
    else
      grep -q '^CONFIG_MB_PEXT=y' "$cfg" && die "$A/scalar: CONFIG_MB_PEXT leaked into the baseline"
    fi
    grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$WANT_MTIME_HZ\$" "$cfg" \
      || die "$A/$T: board clock is not $WANT_MTIME_HZ"
    info "$A/$T: $(fsize "$D/zephyr.bin")"
  done
done
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }

step "5/6  run every image on one piece of silicon"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_micrgb.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "no bitstream"
  bitstream_identify "$BIT"
  bitstream_gate
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD_ARGS="--bitstream $(basename "$BIT") --hold"
else
  bitstream_identify ""
  HOLD_ARGS="--no-load --hold"
fi
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_micrgb.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q 'MAGIC = 0x5A5A0006' "$RUN/boot.log" || {
  cat "$RUN/boot.log"; die "wrong bitstream -- want the full-feature one (0x5A5A0006)"; }

for A in $ARCHS; do
  TARGETS="pext"
  case " $SCALAR_ARCHS " in *" $A "*) TARGETS="pext scalar" ;; esac
  for T in $TARGETS; do
    D="$RUN/$A/$T"
    SECS="$SECONDS_READ_PEXT"
    [ "$T" = scalar ] && SECS="$SECONDS_READ_SCALAR"
    run scp -q "$D/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
    "${SSH[@]}" "bash -lc '
      cd $PYNQ_DIR
      rm -f console.out
      nohup python3 -u console.py --seconds $SECS > console.out 2>/dev/null &
      CPID=\$!
      sleep 1.5
      echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_micrgb.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
      wait \$CPID
    '" >> "$RUN/boot.log" 2>&1 || true
    "${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$D/console.txt" 2>/dev/null || true
    if grep -qE 'MB_PEXT_RUN|MB_RATIO' "$D/console.txt" 2>/dev/null; then
      info "$A/$T ran"
    else
      warn "$A/$T produced no result -- see $D/console.txt"
    fi
  done
done

step "6/6  the table"
MB_PER_CHANNEL="$PER_CHANNEL" \
python3 "$IISWC_ROOT/fpga/pynq-z2/modelblaster/vision/report.py" \
    "$RUN" "$ARCHS" "$SCALAR_ARCHS" "$BOARD" | tee "$RUN/report.txt"

if [ -n "$EXPECT" ] && [ -f "$EXPECT" ]; then
  step "check  (vs $(basename "$EXPECT"))"
  python3 - "$RUN/run.json" "$EXPECT" <<'PY'
import json, sys
got = json.load(open(sys.argv[1])); exp = json.load(open(sys.argv[2]))
bad = 0
for k, want in exp.items():
    if k.startswith("_"):
        continue
    have = got.get(k)
    if isinstance(want, dict) and set(want) == {"min", "max"}:
        ok = have is not None and want["min"] <= have <= want["max"]
        s = "in [%s, %s]" % (want["min"], want["max"])
    else:
        ok = (have == want); s = repr(want)
    print("    %-5s %-32s expected %-22s got %s" % ("ok" if ok else "FAIL", k, s, have))
    bad += (not ok)
print("    %s" % ("PASS  reproduces the golden run" if not bad
                  else "FAIL  %d field(s) differ" % bad))
sys.exit(1 if bad else 0)
PY
fi
