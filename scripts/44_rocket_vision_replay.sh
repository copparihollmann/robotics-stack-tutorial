#!/usr/bin/env bash
# Lab B24 -- the whole camera path on one hart: a 324x324 frame in DRAM, the front end,
# the network, an answer.
#
#   scripts/with_board.sh ./scripts/44_rocket_vision_replay.sh
#   scripts/with_board.sh ./scripts/44_rocket_vision_replay.sh --archs cnn
#   ./scripts/44_rocket_vision_replay.sh --build-only
#
# Lab B22 times the MODEL.  This times everything around it, which for a camera is not a
# rounding error: a 324x324 frame has 104,976 pixels and the network sees 9,216, so
# something has to do the reduction and that something is on the same hart.
#
# WHAT IS MEASURED, per replayed frame, with interrupts locked:
#
#   * ALL THREE front ends, on the same frames, in the same run:
#       frame_fe_mono96      324x324 luma   -> 1 x 96 x 96
#       frame_fe_rgb96       324x324 RGGB   -> 3 x 96 x 96   (bilinear demosaic)
#       frame_fe_bayer4_48   324x324 RGGB   -> 4 x 48 x 48   (no demosaic)
#     Both sensor frames are 104,976 bytes -- a colour HM01B0 sends exactly as many bytes
#     as a monochrome one, because the colour is in the filter array.  So the difference
#     between these three numbers IS the cost of colour on this core, with the DMA held
#     constant, and it is the number the sensor decision should be made against.
#
#   * the model, on whichever feature this architecture takes;
#   * end to end, as frames per second, against the sensor's ~59 fps at 324x324.
#
# AND ONE THING IS CHECKED: the device's feature against the one the HOST build of the
# same frame_fe.c produced, element by element, max_abs_err = 0.  That is the model's
# baked-golden gate applied one stage earlier.
#
# The frames are held-out Visual Wake Words images synthesised to 324x324 and baked into
# .rodata, so they sit in DDR where the capture DMA would leave them.  Replay is the
# method, not a substitute: a sensor pointed at a room does not give the same input twice,
# and Lab B17's cycle counts reproduce to 0.00 % of the median precisely because its input
# was stored.
#
# Runs on the FULL-FEATURE bitstream (MAGIC 0x5A5A0006).
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

ARCHS="cnn cnn_rgb cnn_bayer"
NAME="rocket_vision_replay"
BOARD="chipyard_pynqz1_micrgb"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_z1/pynqz1_rocket_micrgb.bit"
SAMPLE="$IISWC_ROOT/samples/vision_replay"
EXPECT="$IISWC_ROOT/expected/vision_replay.json"
NFRAMES=4
LOAD_BIT=1
DO_BOARD=1
SECONDS_READ=150
WANT_MTIME_HZ=34483
QUANT="int8"
PER_CHANNEL=1
NCALIB=64
VWW_ROOT="${VWW_ROOT:?set VWW_ROOT to the Visual Wake Words image root}"
VWW_FEAT="${VWW_FEAT:?set VWW_FEAT to the Visual Wake Words feature directory}"

while [ $# -gt 0 ]; do
  case "$1" in
    --archs) ARCHS="${2:?}"; shift 2 ;;
    --name)  NAME="${2:?}";  shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --bit)   BIT="${2:?}";   shift 2 ;;
    --frames) NFRAMES="${2:?}"; shift 2 ;;
    --corpus) VWW_ROOT="${2:?}"; shift 2 ;;
    --feat)  VWW_FEAT="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only)   DO_BOARD=0; shift ;;
    --per-channel)  PER_CHANNEL=1; shift ;;
    --per-tensor)   PER_CHANNEL=0; shift ;;
    --no-check)     EXPECT=""; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

MB="$ZCS/modelblaster"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
VISION="$IISWC_ROOT/fpga/pynq-z2/modelblaster/vision"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
export IISWC_ROOT
need_dir () { [ -d "$1" ] || die "$2"; }
need_dir "$VWW_ROOT" "no Visual Wake Words corpus at $VWW_ROOT (--corpus)"

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

step "1/5  the ModelBlaster patches"
mb_patch 0009-modelblaster-pext-backend mb_has_pext_backend
mb_patch 0070-modelblaster-vww-models

# PER-CHANNEL, for the reason CAMERA_TASK.md section 6.3 gives: per-TENSOR int8 measures
# 52.60 % on this task against 82.40 % per-channel, so a replay run at per-tensor produces
# a pipeline that works and an answer that does not. The default here is per-CHANNEL,
# which is the opposite of Lab B22's -- that lab measures the pair deliberately, this one
# runs the configuration that would ship.
PC_ARG=()
[ "$PER_CHANNEL" -eq 1 ] && PC_ARG=(--per-channel)
info "quantisation: $([ "$PER_CHANNEL" -eq 1 ] && echo per-CHANNEL || echo per-TENSOR)"

step "2/5  codegen + replay frames"
for A in $ARCHS; do
  need_file "$VISION/weights/${A}_folded.npz" "no trained weights for '$A'"
  ir="$RUN/$A/ir"; gen="$RUN/$A/gen"; frames="$RUN/$A/frames"
  mkdir -p "$ir" "$gen" "$frames" "$RUN/$A/cache"
  ( cd "$ZCS" && python -m modelblaster.pipeline.extract_graph \
      --model "vww_$A" --out-dir "$ir" --quant "$QUANT" "${PC_ARG[@]}" \
      --num-calibration "$NCALIB" --fusion-target pext ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "extract_graph ($A) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_skeleton \
      --ir "$ir/graph.json" --weights "$ir/weights.npz" --io "$ir/io.npz" \
      --out-dir "$gen" --backend pext ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "generate_skeleton ($A) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_kernels \
      --ir "$ir/graph.json" --out-dir "$gen" --backend reference --target pext \
      --quant "$QUANT" --io "$ir/io.npz" --repo-root "$MB" \
      --build-dir "$RUN/$A/kverify" --harness-dir "$MB/harness" \
      --cache-dir "$RUN/$A/cache" --algorithms all \
      --global-curated-dir "$KERNELS" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "generate_kernels ($A) failed"; }
  run python3 "$IISWC_ROOT/fpga/pynq-z2/sw/tools/gen_replay_frames.py" \
      --root "$VWW_ROOT" --feat "$VWW_FEAT" --arch "$A" --out "$frames" --n "$NFRAMES"
done

step "3/5  build the Zephyr images"
MB_KERNEL_CFLAGS=$(cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['pext'].kernel_cflags))" 2>/dev/null || echo "-DMB_PEXT_HW=1")
for A in $ARCHS; do
  D="$RUN/$A"
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DFRAMES_DIR="$D/frames" \
      -DMODELBLASTER_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS" >> "$RUN/build.log" 2>&1 \
    || { tail -40 "$RUN/build.log"; die "west build failed for $A"; }
  cp "$D/build/zephyr/zephyr.bin" "$D/build/zephyr/zephyr.elf" "$D/"
  cfg="$D/build/zephyr/.config"
  grep -q '^CONFIG_MB_PEXT=y' "$cfg" || die "$A: CONFIG_MB_PEXT is not set"
  grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$WANT_MTIME_HZ\$" "$cfg" \
    || die "$A: board clock is not $WANT_MTIME_HZ"
  info "$A: $(fsize "$D/zephyr.bin")"
done
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }

step "4/5  run on the silicon"
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
  D="$RUN/$A"
  run scp -q "$D/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
  "${SSH[@]}" "bash -lc '
    cd $PYNQ_DIR
    rm -f console.out
    nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
    CPID=\$!
    sleep 1.5
    echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_micrgb.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
    wait \$CPID
  '" >> "$RUN/boot.log" 2>&1 || true
  "${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$D/console.txt" 2>/dev/null || true
  if grep -q 'VR_MEDIAN' "$D/console.txt" 2>/dev/null; then
    info "$A ran"
  else
    warn "$A produced no result -- see $D/console.txt"
  fi
done

step "5/5  the table"
MB_PER_CHANNEL="$PER_CHANNEL" python3 "$VISION/replay_report.py" "$RUN" "$ARCHS" "$BOARD" | tee "$RUN/report.txt"

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
