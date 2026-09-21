#!/usr/bin/env bash
# Lab B119 -- BUILD THE PATH FROM THE MICROPHONE TO THE ENCODER'S INPUT TENSOR.
#
#   ./scripts/77_rocket_mic_window.sh --build-only
#   PYNQ_HOST=xilinx@<board-ip> scripts/with_board.sh \
#       ./scripts/77_rocket_mic_window.sh --prebuilt out/rocket_mic_window_prebuilt
#   ./scripts/77_rocket_mic_window.sh --score-only out/rocket_mic_window      # no board
#
# WHAT THIS PRODUCES.  One 64,000-sample int8 window on the encoder's own input grid,
# assembled from the microphone through a 539/625 resampler, and the evidence that it is
# well formed.  IT DOES NOT RUN THE MODEL: the combined image has an open correctness
# defect (max_abs_err 65, Lab B117) and feeding it microphone audio would confound two
# unknowns.
#
# THE NUMBER THAT MAKES THE PATH NECESSARY.  Lab B110 measured the microphone at
# 18,552.875 Hz on this bitstream, not the 15,993.859 the RATE register reports -- that
# register is a compile-time Verilog constant computed for FCLK0 = 34.4828 MHz.  The
# encoder's first dispatch is hard-shaped IW = 64000 at 16 kHz, so raw microphone samples
# would present speech 15.955 % fast.  16000/(40e6/2156) = 539/625 EXACTLY.
#
# THE CONTROLS, AND EACH CAN FAIL.
#   MW_SYNTH   a 1000.000 Hz sine synthesised ON THE BOARD at f_mic, through the SAME
#              resampler, Goertzel'd at 1000 Hz and at 862.400 Hz -- where a pass-through
#              would put it.  No acoustic source, and the discriminator runs in the same
#              pass as the claim, which is the shape of B110's dc_bypass arm.
#   MW_AB      the DIRECT (cubic per output, 640 B of coefficients) and BANK (539 phases
#              materialised at boot, 86,240 B) evaluation orders, on the same samples,
#              timed, and required to be BYTE-IDENTICAL.  That measures whether a
#              539-phase table is affordable against a 16 KB L1D instead of arguing it.
#   MW_OVR     B110's defect re-run: CTRL[3] clear_sticky does NOT clear STATUS[3]
#              overrun; only fifo_reset does.  The capture arms its watch with fifo_reset
#              for that reason, and an overrun REFUSES the window.
#   MW_RATE    64,000 outputs must take 4.0002 s of mtime.  A pass-through would take
#              3.4496 s.  Measured against the clock, 16 % apart.
#
# NO RTL AND NO NEW BITSTREAM: the part is full (13,295 of 13,300 slices, five spare).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="rocket_mic_window"
BOARD="chipyard_pynqz1_micrgb_f40"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98b_z1/pynqz1_rocket_micrgb_roccmoonnch8f40b98b.bit"
RUNNER="run_rocket_roccmoonnch8f40b98b.py"
SAMPLE="$IISWC_ROOT/samples/mic_window"
WANT_MAGIC="0x5A5A0035"; FCLK_CORE=40; SECONDS_READ=180
LAB_REQUIRES="${LAB_REQUIRES:-mic}"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --fclk) FCLK_CORE="${2:?}"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --prebuilt) PREBUILT="${2:?}"; shift 2 ;;
    --score-only) SCORE_ONLY="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
[ -n "${BUILD_ONLY:-}" ] && RUN="$IISWC_OUT/${NAME}_prebuilt"
if [ -n "${SCORE_ONLY:-}" ]; then
  RUN="$SCORE_ONLY"; need_file "$RUN/console.txt" "nothing to score"
else
  rm -rf "$RUN"; mkdir -p "$RUN"
fi

GUEST_KHZ=$(python3 -c "
n=round(1000e6/(float('$FCLK_CORE')*1e6)); print(int(round((1000e6/n)/1000.0)))")
CLK_HZ=$(python3 -c "
n=round(1000e6/(float('$FCLK_CORE')*1e6)); print(int(round(1000e6/n)))")
info "clock: FCLK0 $FCLK_CORE MHz = $CLK_HZ Hz; guest CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ"
info "f_mic = $CLK_HZ / 2156 = $(python3 -c "print('%.4f' % ($CLK_HZ/2156.0))") Hz; ratio to 16 kHz = 539/625"

if [ -n "${SCORE_ONLY:-}" ]; then
  bitstream_identify "$BIT" >/dev/null
else
step "1/4  the off-board gates -- these run before any board time is spent"
run python3 "$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine/b119_resamp.py" --design \
    > "$RUN/design.txt" 2>&1 || { cat "$RUN/design.txt"; die "--design failed"; }
cat "$RUN/design.txt"
run python3 "$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine/b119_resamp.py" --verify-c \
    > "$RUN/verify_c.txt" 2>&1 || { cat "$RUN/verify_c.txt"; die "--verify-c FAILED"; }
cat "$RUN/verify_c.txt"
grep -q "VERIFY-C PASS" "$RUN/verify_c.txt" || die "--verify-c did not pass"

step "2/4  build the guest ($BOARD)"
if [ -n "${PREBUILT:-}" ]; then
  need_file "$PREBUILT/zephyr.bin" "no prebuilt image in $PREBUILT (run --build-only first)"
  cp "$PREBUILT/zephyr.bin" "$PREBUILT/zephyr.elf" "$RUN/"
  cp "$PREBUILT/build.log" "$RUN/build.log" 2>/dev/null || true
  cp "$PREBUILT/guest_khz.txt" "$RUN/guest_khz.txt" 2>/dev/null || true
  cp "$PREBUILT/verify_c.txt" "$PREBUILT/design.txt" "$RUN/" 2>/dev/null || true
  info "prebuilt image from $PREBUILT (built off the board lock)"
else
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
      > "$RUN/build.log" 2>&1 || { tail -40 "$RUN/build.log"; die "build failed"; }
  cp "$RUN/build/zephyr/zephyr.bin" "$RUN/build/zephyr/zephyr.elf" "$RUN/"
  sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$RUN/build/zephyr/.config" > "$RUN/guest_khz.txt"
fi
HZ=$(cat "$RUN/guest_khz.txt" 2>/dev/null || echo 0)
[ "$HZ" = "$GUEST_KHZ" ] || die "guest clock mismatch: board '$BOARD' built
       CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, --fclk $FCLK_CORE needs $GUEST_KHZ.  That
       constant also sets the UART divisor, so a mismatch GARBLES THE CONSOLE rather than
       failing, and would make the mtime-based rate wrong by the same factor."
info "image: $(fsize "$RUN/zephyr.bin")   mtime: $HZ Hz"
if [ -n "${BUILD_ONLY:-}" ]; then
  info "built, no board touched.  Now:  scripts/with_board.sh $0 --prebuilt $RUN"
  exit 0
fi

step "3/4  load the PL and capture"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"; bitstream_gate
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "" ""
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
cat "$RUN/fclk.json"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ --idle 150 > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $SECONDS_READ ] && ! grep -q MW_DONE console.out; do sleep 5; t=\$((t+5)); done
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t bytes=\$(wc -c < console.out)
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
[ -s "$RUN/console.txt" ] || { cat "$RUN/boot.log"; die "0 console bytes -- stop and report"; }
grep -q MW_DONE "$RUN/console.txt" || { tail -30 "$RUN/console.txt"; die "the capture did not finish"; }
grep -E "^MW_" "$RUN/console.txt" | grep -v "^MWD " | head -40 | sed 's/^/    /'
fi

step "4/4  the verdict"
export BIT_MD5 WANT_MAGIC LAB_REQUIRES LAB_FEATURES CLK_HZ
python3 "$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine/b119_score.py" "$RUN" | tee "$RUN/report.txt"
info "run.json written to $RUN/run.json"
