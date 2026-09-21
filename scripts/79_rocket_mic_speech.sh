#!/usr/bin/env bash
# Lab B122 -- SPEAK INTO THE MICROPHONE.  Play a known utterance through the bench speaker,
# capture it on the board's PDM microphone, and price the acoustic path against the same
# utterance fed from file through the same int8 input-grid quantiser.
#
#   ./scripts/79_rocket_mic_speech.sh --build-only
#   ./scripts/79_rocket_mic_speech.sh --make-wavs                              # no board
#   PYNQ_HOST=xilinx@<board-ip> scripts/with_board.sh \
#       ./scripts/79_rocket_mic_speech.sh --name b122_sweep --play sweep \
#           --prebuilt out/rocket_mic_speech_prebuilt
#   PYNQ_HOST=xilinx@<board-ip> scripts/with_board.sh \
#       ./scripts/79_rocket_mic_speech.sh --name b122_silence --play none \
#           --prebuilt out/rocket_mic_speech_prebuilt
#   PYNQ_HOST=xilinx@<board-ip> scripts/with_board.sh \
#       ./scripts/79_rocket_mic_speech.sh --name b122_utt --play utt --amp 0.08 \
#           --prebuilt out/rocket_mic_speech_prebuilt
#   ./scripts/79_rocket_mic_speech.sh --score-only out/b122_utt --ref 1272-128104-0014 \
#           --control-window out/b122_silence                                  # no board
#
# THE UTTERANCE IS NOT ARBITRARY.  LibriSpeech dev-clean 1272-128104-0014, "BY HARRY QUILTER
# M A", 2.245 s, is the utterance Lab B114 transcribed FROM FILE on this bitstream as "By
# Harry Quelter m a".  Same utterance, same model, two input paths -- so the number that
# means something is the delta between them, not either absolute.
#
# WHY NO SYNCHRONISATION IS BUILT.  The board captures 96,000 resampled outputs (6.0002 s)
# and the window is chosen out of that by energy onset, so the utterance has to land inside
# a 6 s buffer with 3.7 s of slack: required precision +-0.5 s against serial jitter of
# milliseconds.  The playback fires off the board's own MS_CAP_BEGIN line, read over a
# `tail -F` of the console, and the whole path is timestamped in play.json.  Clock drift
# between the speaker's DAC and the decimator is 100 ppm over 4 s = 0.4 ms and is ignored.
#
# GARDEN IS A SHARED LAB MACHINE.  Every run of this script that is not `--play none` makes
# audible noise.  --play sweep makes SIX presentations, --play utt makes ONE.  Keep the
# count in the write-up.
#
# NO RTL AND NO NEW BITSTREAM: the part is full (13,295 of 13,300 slices).
# THE MODEL IS NOT RUN HERE: B117's max_abs_err 65 is open on the merged image and feeding
# it microphone audio would confound two unknowns.  The encoder-only arm is separate.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="rocket_mic_speech"
BOARD="chipyard_pynqz1_micrgb_f40"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98b_z1/pynqz1_rocket_micrgb_roccmoonnch8f40b98b.bit"
RUNNER="run_rocket_roccmoonnch8f40b98b.py"
SAMPLE="$IISWC_ROOT/samples/mic_speech"
MOON="$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine"
WAVDIR="$IISWC_ROOT/archive/b122/wav"
WANT_MAGIC="0x5A5A0035"; FCLK_CORE=40; SECONDS_READ=180
LAB_REQUIRES="${LAB_REQUIRES:-mic}"
UID_UTT="1272-128104-0014"
PLAY="none"; AMP="0.08"; WAV=""; DELAY=""; CUE=""; ALSA_DEV="plughw:1,0"
REF=""; CTLWIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --fclk) FCLK_CORE="${2:?}"; shift 2 ;;
    --uid) UID_UTT="${2:?}"; shift 2 ;;
    --play) PLAY="${2:?}"; shift 2 ;;
    --amp) AMP="${2:?}"; shift 2 ;;
    --wav) WAV="${2:?}"; shift 2 ;;
    --delay) DELAY="${2:?}"; shift 2 ;;
    --cue) CUE="${2:?}"; shift 2 ;;
    --dev) ALSA_DEV="${2:?}"; shift 2 ;;
    --ref) REF="${2:?}"; shift 2 ;;
    --control-window) CTLWIN="${2:?}"; shift 2 ;;
    --make-wavs) MAKE_WAVS=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --prebuilt) PREBUILT="${2:?}"; shift 2 ;;
    --score-only) SCORE_ONLY="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
[ -n "${BUILD_ONLY:-}" ] && RUN="$IISWC_OUT/${NAME}_prebuilt"

# ---- the WAVs.  No board, no noise: writing them is silent. -------------------------------
if [ -n "${MAKE_WAVS:-}" ]; then
  step "the playback material"
  mkdir -p "$WAVDIR"
  run python3 "$MOON/b122_wav.py" --uid "$UID_UTT" --sweep \
      --out "$WAVDIR/sweep.wav" --json "$WAVDIR/sweep.json" > "$WAVDIR/sweep.log"
  run python3 "$MOON/b122_wav.py" --uid "$UID_UTT" --utt 0.08 \
      --out "$WAVDIR/utt_0.08.wav" --json "$WAVDIR/utt_0.08.json" > "$WAVDIR/utt_0.08.log"
  run python3 "$MOON/b122_wav.py" --uid "$UID_UTT" --utt 0.08 --silent \
      --out "$WAVDIR/silent_probe.wav" --json "$WAVDIR/silent_probe.json" \
      > "$WAVDIR/silent_probe.log"
  info "$ python3 b122_acoustic.py --selftest"
  python3 "$MOON/b122_acoustic.py" --selftest > "$WAVDIR/selftest.json"
  info "wrote $WAVDIR/{sweep,utt_0.08,silent_probe}.wav and selftest.json"
  exit 0
fi

case "$PLAY" in
  none) : ;;
  sweep) [ -n "$WAV" ] || WAV="$WAVDIR/sweep.wav"; [ -n "$CUE" ] || CUE="MS_MON_BEGIN"
         [ -n "$DELAY" ] || DELAY="0.50" ;;
  utt)   [ -n "$WAV" ] || WAV="$WAVDIR/utt_$AMP.wav"; [ -n "$CUE" ] || CUE="MS_CAP_BEGIN"
         # 0.45 s: the board prints the cue, then spends ~46 ms in SETTLING and ~64 ms on
         # B119's 1024-output DC-blocker PREROLL before the buffer starts; aplay's own
         # start latency measures ~0.2 s (b122_play.py --probe on a SILENT file); the WAV
         # carries 0.30 s of lead.  Nominal onset ~0.84 s into a 6.0 s buffer.
         [ -n "$DELAY" ] || DELAY="0.45" ;;
  *) die "--play must be none, sweep or utt" ;;
esac

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
run python3 "$MOON/b119_resamp.py" --design > "$RUN/design.txt" 2>&1 \
    || { cat "$RUN/design.txt"; die "--design failed"; }
run python3 "$MOON/b119_resamp.py" --verify-c > "$RUN/verify_c.txt" 2>&1 \
    || { cat "$RUN/verify_c.txt"; die "--verify-c FAILED"; }
grep -q "VERIFY-C PASS" "$RUN/verify_c.txt" || die "--verify-c did not pass"
info "b119_resamp.h verifies against its host twin (the header this sample INCLUDES, not a copy)"
md5sum "$IISWC_ROOT/samples/mic_window/src/b119_resamp.h" \
       "$IISWC_ROOT/samples/mic_window/src/b119_rs_coeffs.h" > "$RUN/resamp_md5.txt"
cat "$RUN/resamp_md5.txt" | sed 's/^/    /'

step "2/4  build the guest ($BOARD)"
if [ -n "${PREBUILT:-}" ]; then
  need_file "$PREBUILT/zephyr.bin" "no prebuilt image in $PREBUILT (run --build-only first)"
  cp "$PREBUILT/zephyr.bin" "$PREBUILT/zephyr.elf" "$RUN/"
  cp "$PREBUILT/build.log" "$RUN/build.log" 2>/dev/null || true
  cp "$PREBUILT/guest_khz.txt" "$RUN/guest_khz.txt" 2>/dev/null || true
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
  info "built, no board touched.  Now:  scripts/with_board.sh $0 --prebuilt $RUN --play ..."
  exit 0
fi

step "3/4  load the PL, arm the playback, capture"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"; bitstream_gate
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "" ""
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
info "board: PYNQ_HOST=$PYNQ_HOST  IISWC_BOARD=$IISWC_BOARD  (the speaker is on garden, the"
info "       microphone is on this board -- both must be the garden bench or the numbers"
info "       do not share a room, let alone a clock)"

# THE PLAYBACK ARM.  `dima` is not in the `audio` group on garden, so a plain aplay reports
# "no soundcards found" even though card 1 is there; sudo -n is used for the one call and
# the mixer state is recorded so a level can be reproduced.
if [ "$PLAY" != "none" ]; then
  need_file "$WAV" "no playback WAV -- run $0 --make-wavs first"
  cp "${WAV%.wav}.json" "$RUN/wav.json" 2>/dev/null || true
  sudo -n amixer -c 1 scontents > "$RUN/mixer.txt" 2>&1 || warn "could not read the mixer"
  grep -E "Simple mixer control 'PCM',0" -A 6 "$RUN/mixer.txt" | sed 's/^/    /' || true
  info "playback: $WAV  cue=$CUE  delay=${DELAY}s  dev=$ALSA_DEV"
else
  info "playback: NONE -- this arm is the silence control"
fi

run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
cat "$RUN/fclk.json"

# THE STALE-CONSOLE TRAP.  The console file is removed FIRST, in its own ssh, before the
# tail that arms the playback is started: a `tail -F -n +1` opened on the PREVIOUS run's
# console.out would see that run's MS_CAP_BEGIN and fire the speaker into nothing.
"${SSH[@]}" "rm -f $PYNQ_DIR/console.out" || true
PLAY_PID=""
if [ "$PLAY" != "none" ]; then
  (
    "${SSH[@]}" "tail -F -s 0.05 -n +1 $PYNQ_DIR/console.out 2>/dev/null" \
      | python3 "$MOON/b122_play.py" --wav "$WAV" --cue "$CUE" --delay "$DELAY" \
          --dev "$ALSA_DEV" --timeout 150 --log "$RUN/play.json"
  ) > "$RUN/play.log" 2>&1 &
  PLAY_PID=$!
  info "playback armed (pid $PLAY_PID), waiting for the board to say $CUE"
fi

"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  nohup python3 -u console.py --seconds $SECONDS_READ --idle 150 --stamps stamps.txt > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $SECONDS_READ ] && ! grep -q MS_DONE console.out; do sleep 5; t=\$((t+5)); done
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t bytes=\$(wc -c < console.out)
'" >> "$RUN/boot.log" 2>&1 || true
if [ -n "$PLAY_PID" ]; then wait "$PLAY_PID" || true; fi
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
"${SSH[@]}" "cat $PYNQ_DIR/stamps.txt" > "$RUN/stamps.txt" 2>/dev/null || true
[ -s "$RUN/console.txt" ] || { cat "$RUN/boot.log"; die "0 console bytes -- stop and report"; }
grep -q MS_DONE "$RUN/console.txt" || { tail -30 "$RUN/console.txt"; die "the capture did not finish"; }
grep -E "^MS_" "$RUN/console.txt" | grep -vE "^MSD |^MS_LVL " | head -30 | sed 's/^/    /'
if [ -f "$RUN/play.json" ]; then info "playback record:"; sed 's/^/    /' "$RUN/play.json"; fi
fi

step "4/4  the verdict"
export BIT_MD5 WANT_MAGIC LAB_REQUIRES LAB_FEATURES CLK_HZ
ARGS=()
[ -f "$RUN/wav.json" ] && ARGS+=(--wav "$RUN/wav.json")
[ -n "$REF" ] && ARGS+=(--ref "$REF")
[ -n "$CTLWIN" ] && ARGS+=(--control-window "$CTLWIN")
python3 "$MOON/b122_score.py" "$RUN" "${ARGS[@]}" | tee "$RUN/report.txt"
info "run.json written to $RUN/run.json"
