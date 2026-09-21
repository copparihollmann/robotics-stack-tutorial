#!/usr/bin/env bash
# MOONSHINE, LIVE -- clap, speak, read the transcript on the board's console.
#
#   moonshine_live.sh gen     # the vocab table, the embedding .S, the tail, the self-test
#   moonshine_live.sh image   # west build + the gates
#   moonshine_live.sh board   # load it and stream the console (Ctrl-C to stop)
#
# THE MODEL IS b126_rtf_n8's B = 1 GEN, NOT B134's B = 4 ONE, and that is the whole reason
# this script exists separately.  Same kernel_picks_digest (9005f05c...), same
# kernel_cflags_md5 (77424eb4...), so the KERNELS are identical -- but a live demo decodes one
# utterance and has no group to batch it with.  ***RTF_e2e at B = 1 is ~1.18, not the measured
# 0.892873***: about 4.7 s of compute for a 4.0 s window.  That is the price of B = 1 and it is
# stated on the console by the image itself.
set -euo pipefail
ROOT=${IISWC_ROOT:?source env.sh first}
MOON="$ROOT/fpga/pynq-z2/modelblaster/moonshine"
NAME="${NAME:-moonshine_live}"
RUN="$ROOT/out/$NAME"
GEN="${GEN:-$ROOT/out/b126_rtf_n8/gen}"          # THE B = 1 GEN
SRC="$ROOT/out/b126_rtf_n8"
SELFTEST_RUN="${SELFTEST_RUN:-$ROOT/out/b134_mic_wer}"
# PANEL=1 selects B135's 0x5A5A0037 -- the OLED bus and the four buttons -- and B136's Zephyr
# board for it.  Default is 0x5A5A0035, the bitstream every measured number runs on.
# ALL=1 selects B137's 0x5A5A0038 -- every interface at once, including the camera, with the
# nch8 engine and the P-extension retained and TACIT traded out to make room.
if [ "${ALL:-0}" = 1 ]; then
  BOARD="${BOARD:-chipyard_pynqz1_all_f40}"
  BIT="$ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98ball_z1/pynqz1_rocket_micrgb_roccmoonnch8f40b98ball.bit"
  BIT_MD5_WANT=ced0aab0c7b52f25338eeffe8f678e4f
  RUNNER_NAME=run_rocket_roccmoonnch8f40b98ball.py
  ML_OLED="${ML_OLED:-1}"
  ML_BUTTON="${ML_BUTTON:-0}"
elif [ "${PANEL:-0}" = 1 ]; then
  BOARD="${BOARD:-chipyard_pynqz1_panel_f40}"
  BIT="$ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98bpanel_z1/pynqz1_rocket_micrgb_roccmoonnch8f40b98bpanel.bit"
  BIT_MD5_WANT=f1f076322d221eceb6f096bbe42cf45f
  RUNNER_NAME=run_rocket_roccmoonnch8f40b98bpanel.py
  ML_OLED="${ML_OLED:-1}"
  ML_BUTTON="${ML_BUTTON:-0}"        # 1 needs a finger; 0 keeps the clap trigger
else
  BOARD="${BOARD:-chipyard_pynqz1_micrgb_f40}"
  BIT="$ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98b_z1/pynqz1_rocket_micrgb_roccmoonnch8f40b98b.bit"
  BIT_MD5_WANT=995798bedfb15cff077ab58710af3bf8
  RUNNER_NAME=run_rocket_roccmoonnch8f40b98b.py
  ML_OLED="${ML_OLED:-0}"
  ML_BUTTON="${ML_BUTTON:-0}"
fi
MLDEFS=""
[ "$ML_OLED"   = 1 ] && MLDEFS="$MLDEFS ML_OLED=1"
[ "$ML_BUTTON" = 1 ] && MLDEFS="$MLDEFS ML_BUTTON=1"
EXTRA=()
if [ "$ML_OLED" = 1 ]; then
  EXTRA+=( -DEXTRA_CONF_FILE="$ROOT/samples/moonshine_live/oled.conf"
           -DDTC_OVERLAY_FILE="$ROOT/samples/oled_status/oled.overlay" )
fi
: "${PYNQ_HOST:?set PYNQ_HOST=user@host -- the board with the microphone attached}"
. "$ROOT/env.sh"
PY="$ZCS/tools/miniforge3/envs/zephyr/bin/python"; [ -x "$PY" ] || PY=python
NM="$ROOT/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-nm"
CF="$(cat "$SRC/ar/kernel_cflags.txt")"

case "${1:?usage: moonshine_live.sh gen|image|board}" in
gen)
  mkdir -p "$RUN/gen"
  ( cd "$MOON" && MOONSHINE_DIR="${MOONSHINE_DIR:-$ROOT/out/moonshine}" \
      "$PY" emit_vocab.py --out "$RUN/gen" )
  # THE GATE ON THE DETOKENISER, AND IT COULD FAIL.  The C algorithm is run in Python over
  # every token sequence the board has actually produced and must equal the reference
  # tokenizer character for character.
  ( cd "$MOON" && MOONSHINE_DIR="${MOONSHINE_DIR:-$ROOT/out/moonshine}" \
      "$PY" emit_vocab.py --verify "$SELFTEST_RUN" )
  "$PY" "$MOON/emit_live_io.py" --emb "$SRC/hostref/emb.f32" --src "$SELFTEST_RUN/in.bin" \
      --out "$RUN/gen" --selftest-run "$SELFTEST_RUN" --selftest-slot 0
  ;;
image)
  [ -f "$RUN/gen/mb_vocab.c" ] || { echo "run gen first" >&2; exit 1; }
  mkdir -p "$RUN/ar"
  echo "$CF" > "$RUN/ar/kernel_cflags.txt"
  # THE CFLAGS ARE b126_rtf_n8's, BYTE FOR BYTE.  Two labs have compared eleven defines and
  # missed the one that mattered; this compares the string.
  cmp -s "$RUN/ar/kernel_cflags.txt" "$SRC/ar/kernel_cflags.txt" || {
    echo "FAIL: kernel cflags are not b126_rtf_n8's" >&2; exit 1; }
  echo "  cflags == b126_rtf_n8's ($(md5sum < "$RUN/ar/kernel_cflags.txt"))"
  echo "  board $BOARD   bitstream $(basename "$BIT")   ML_DEFS='${MLDEFS:- (none)}'"
  ( cd "$ROOT" && west build -p always -b "$BOARD" "$ROOT/samples/moonshine_live" \
      -d "$RUN/ar/build" -- -DBOARD_ROOT="$ROOT" -DMODEL_DIR="$GEN" \
      -DLIVE_GEN="$RUN/gen" -DMODELBLASTER_KERNEL_CFLAGS="$CF" \
      -DML_DEFS="$MLDEFS" "${EXTRA[@]}" ) > "$RUN/build.log" 2>&1 \
    || { tail -40 "$RUN/build.log"; echo "FAIL: west build" >&2; exit 1; }
  cp -f "$RUN/ar/build/zephyr/zephyr.bin" "$RUN/ar/zephyr.bin"
  cp -f "$RUN/ar/build/zephyr/zephyr.elf" "$RUN/ar/zephyr.elf"
  # THE ENGINE ARENA GATE, the same one every model image passes.
  KRE=$("$NM" "$RUN/ar/zephyr.elf" | awk '$3=="__kernel_ram_end"{print $1}')
  [ -n "$KRE" ] || { echo "FAIL: no __kernel_ram_end" >&2; exit 1; }
  "$PY" -c "
import sys
k=int('$KRE',16)
print('  __kernel_ram_end 0x%x   clear to 0x88000000: %d B' % (k, 0x88000000-k))
sys.exit(0 if k < 0x88000000 else 'the guest has grown INTO the engine arena')" || exit 1
  ls -l "$RUN/ar/zephyr.bin" | awk '{printf "  image %.1f MB\n", $5/1048576}'
  ;;
board)
  [ -f "$RUN/ar/zephyr.bin" ] || { echo "no image; run image first" >&2; exit 1; }
  [ "$(md5sum "$BIT" | cut -d' ' -f1)" = "$BIT_MD5_WANT" ] || { echo "FAIL: bitstream md5" >&2; exit 1; }
  SECS="${SECS:-1800}"
  RUNNER="$RUNNER_NAME"
  SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
  echo "== $NAME -> $PYNQ_HOST ($SECS s session) =="
  scp -q "$ROOT/fpga/pynq-z2/host/run_rocket.py" "$ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$ROOT/fpga/pynq-z2/host/console.py" \
      "$ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/ar/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk 40 --hold'"
  # THE CLOCK IS CHECKED, NOT ASSUMED: every RTF this image prints divides by 40 MHz.
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=40"
  "${SSH[@]}" "rm -f $PYNQ_DIR/console.out" || true
  "${SSH[@]}" "tail -F -s 0.05 -n +1 $PYNQ_DIR/console.out 2>/dev/null" &
  TAILPID=$!
  trap 'kill $TAILPID 2>/dev/null || true' EXIT
  "${SSH[@]}" "cd $PYNQ_DIR; ( nohup python3 -u console.py --seconds $SECS --idle $SECS > console.out 2>/dev/null </dev/null & ); sleep 1; cd $PYNQ_DIR; echo xilinx | sudo -S bash -lc \"cd $PYNQ_DIR; $PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" > load.log 2>&1; echo \"loader rc=\$?\"; tail -20 load.log"
  echo "== running.  CLAP to start, then SPEAK.  The transcript prints as ML_TEXT. =="
  echo "== Ctrl-C stops watching; the board keeps running until the session ends. =="
  wait $TAILPID 2>/dev/null || true
  ;;
*) echo "unknown stage: $1" >&2; exit 2 ;;
esac
