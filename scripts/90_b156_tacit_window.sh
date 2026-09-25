#!/usr/bin/env bash
# Lab B156 -- THE DUAL-HART TACIT DEMO TRACE, BOUNDED BY ONE WALL-CLOCK WINDOW SO BOTH
# LANES ARE BUSY FOR THE WHOLE OF IT AND STOP TOGETHER.
#
#   PYNQ_HOST=xilinx@<your board> scripts/with_board.sh ./scripts/90_b156_tacit_window.sh
#
# WHAT WAS WRONG WITH THE B153 ARTEFACT, MEASURED ON THE ARTEFACT ITSELF.
#
# out/b153_duo/trace.merged.perfetto.json is 48.2 MB and 391,880 events, and it is correct:
# both lanes start in the reset vector, the [hw]/[sw] split holds, all five gates pass.  It
# is also 80 % a recording of an idle hart 0.
#
#   pid 0  mb_pext_conv_gather/pixel [hw]  2.16 s -> 11.09 s (23,680 B-events each), then
#          arch_spin_relax 13,635 / uart_sifive_poll_out 8,521 / console_out 8,437 to 55.04 s
#   pid 1  fe_log2_q8 0.14 s -> 55.03 s, mb_pext_conv_* [sw] -> 54.83 s
#
# B153's own write-up names the cause: "the run length is set by KWS_SECONDS, not
# SD_FRAMES".  SD_FRAMES counts camera frames at ~0.97 s each; KWS_SECONDS counts 32 ms
# audio blocks that the little hart's SOFTWARE P-extension model chews at ~0.22 s each,
# 6.9x real time.  Two counts cannot be made to agree without predicting both per-unit
# costs, and they move with every build.
#
# WHAT THIS LAB DOES INSTEAD.
#
#   1. ONE WALL CLOCK BOUNDS BOTH HARTS.  samples/tacit_duo's DUO_WINDOW_MS (Lab B156):
#      main() k_msleep()s -- never k_busy_wait(), which is the spin B153 found -- until a
#      deadline measured from the RESET VECTOR, stops both encoders while both workloads
#      are still mid-unit, and only then asks them to wind up.  Both lanes therefore end at
#      the same cycle by construction.  Each workload is over-fed so neither can finish
#      early: SD_FRAMES=0 (unbounded live loop) and KWS_SECONDS far past what the window can
#      reach.  The hooks are default-off in both parents (SD_STOP_HOOK / KWS_STOP_HOOK),
#      exactly like SD_NO_MAIN / KWS_NO_MAIN, so scripts/37, 38, 83, 86 and 87 are unchanged.
#
#   2. THE WINDOW IS SHORT, AND THE NUMBER COMES FROM MEASURED PER-UNIT COSTS.  Read off
#      B153's artefact: hart 0 reaches its first inference at 2.16 s and runs one every
#      0.97 s, so its 8 BAKED REPLAY frames -- the correctness gate, 8/8 decisions, 8/8
#      tensors, max |d| = 0 -- are done at 9.30 s and live camera frames follow at ~0.97 s.
#      Hart 1 runs the golden-logit check at 0.18 s and then one inference every 1.535 s
#      (1.30 s of it inside mb_pext_conv_* [sw]).  13 s therefore buys hart 0 its 8 replay
#      frames plus 3-4 live ones, and hart 1 ~8 inferences, with ~3.7 s of slack over the
#      replay gate.  55 s bought nothing past that but 44 s of idle hart 0 and a 48 MB file.
#
#   3. THE BUFFERS ARE SIZED FROM A NEW MEASUREMENT.  B153's hart-0 rate of 0.0084 B/core
#      cycle (0.0107 before its console cut) was measured over a run that was 80 % SPINNING,
#      so it is a blend of work and spin and it is not the signdet trace rate.  --calibrate
#      runs a short window and reads bytes-per-core-cycle per hart off the hardware's own
#      TR_SK_DMA_COUNT; the real run is sized from that and re-measures it.
#
# THE HARD GATES, WHICH NOTHING HERE MAY SKIP.  tacit.h exposes TR_SK_DMA_ADDR and
# TR_SK_DMA_COUNT and NO LIMIT REGISTER: the sink writes linearly from its base and neither
# wraps nor stops, so a lane that outruns its region silently overwrites the next one and
# both traces still decode.  COUNT[h] <= span[h] and base[1] >= base[0] + COUNT[0], every
# run, from the board's own registers.
#
# WHAT THIS LAB NEEDS, AND THE TWO THINGS THIS REPOSITORY DOES NOT SHIP.
#
#   1. THE BITSTREAM.  0x5A5A0039 'tracepanelcam', md5 54838985885eacd88c28cc38cb0c829a, the
#      only build in the family with a TACIT encoder AND a DMA sink on BOTH tiles.  It is one
#      of the five listed-but-untracked rows in fpga/pynq-z2/bitstreams.csv (README, "Bitstreams"):
#      point IISWC_BIT_DIR at a directory holding it, or drop it in /opt/iiswc/bit, or rebuild
#      it with fpga/pynq-z2/scripts/build_*_z1.sh.  load_pl() below refuses any other md5,
#      because a trace measured against a different PL is not a smaller problem than no trace.
#
#   2. THE DETECTOR'S TRAINED WEIGHTS -- and ONLY the weights.  Everything else this lab
#      needs is here: samples/kws_live and its cnn_tiny weights, samples/signdet_live,
#      samples/oled_status, the camera and OLED drivers, the SignDetLite architecture and
#      training code (fpga/pynq-z2/modelblaster/signdet/), the lowering flow
#      (scripts/84_signdet_lower.sh) and the eight baked replay frames, which are our own
#      bench captures and are tracked at $BAKE below.
#
#      The trained weights are GTSDB-derived and are not published anywhere by this project
#      (docs/SIGNDET_WEIGHTS.md).  So:
#
#        ./scripts/84_signdet_lower.sh          lowers a DETERMINISTIC RANDOM-weight model
#                                               (seed 144) into $SIGN_GEN.  Same shapes, same
#                                               kernels, same interface scales, no detection
#                                               ability.  The run below works end to end.
#        ./scripts/91_signdet_install_model.sh  installs the REAL lowered model from a local
#                                               directory -- what the tutorial image ships.
#
#      WHICH GATES MEAN WHAT.  Exactly one of the seven depends on the weights: GATE 4,
#      REPLAY.  With random weights it is reported NOT APPLICABLE and excluded from the
#      result; it is not quietly passed and it is not counted as a failure.  The other six --
#      lanes, buffers, from-reset coverage, rate, and B156's both-lanes-busy and
#      both-lanes-end-together -- are statements about the TRACING MECHANISM and the
#      SCHEDULE, and they gate in both modes.  This script reads which mode it is out of
#      $SIGN_GEN/signdet_weights.json and prints it before it builds anything.
#
# WHAT A CORRECT RESULT LOOKS LIKE, AND HOW TO TELL A WRONG ONE:
# expected/tacit_duo_window.json.  It carries the seven gates, the measured numbers of the
# 2026-09-23 13.309 s reference run, and -- the part worth reading first -- the shape of the
# artefact this lab exists to stop producing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

LAB=B156
NAME="${NAME:-b156}"
BOARD="${BOARD:-chipyard_pynqz1_trace_f40}"
BIT="${BIT:-$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_tracepanelcam_z1/pynqz1_rocket_micrgb_tracepanelcam.bit}"
B156_BIT_MD5="${B156_BIT_MD5:-54838985885eacd88c28cc38cb0c829a}"
RUNNER="${RUNNER:-run_rocket_tracepanelcam.py}"
WANT_MAGIC="${WANT_MAGIC:-0x5A5A0039}"
FCLK_CORE="${FCLK_CORE:-40}"
CLK_HZ="${CLK_HZ:-40000000}"
WANT_MTIME_HZ="${WANT_MTIME_HZ:-40000}"

SIGN_GEN="${SIGN_GEN:-$IISWC_ROOT/out/signdet/gen}"
KWS_GEN="${KWS_GEN:-$IISWC_ROOT/out/rocket_kws/cnn_tiny/pext/gen}"
KWS_META="${KWS_META:-$IISWC_ROOT/fpga/pynq-z2/modelblaster/kws/weights/cnn_tiny_meta.json}"
# THE EIGHT REPLAY FRAMES ARE TRACKED.  They are our own HM01B0 captures on our own bench
# (a hand holding a printed prop sign under the lab's ceiling tubes), baked to C by
# signdet/bake_live_frames.py; no third-party image is in them.  out/b146_signdet_live/bake
# is where scripts/87 writes a freshly baked set -- point BAKE there to use your own.
BAKE="${BAKE:-$IISWC_ROOT/fpga/pynq-z2/modelblaster/signdet/bake}"

# THE ONE KNOB THAT BOUNDS THE RUN.  Milliseconds of wall clock from the reset vector.
WINDOW_MS="${WINDOW_MS:-13000}"
# Over-feed, so neither lane can finish before the window closes and leave the other one
# recording an idle hart.  SD_FRAMES=0 is signdet_live's own "run until told to stop";
# KWS_SECONDS=60 is 1,875 audio blocks, ~410 s of little-hart work at the measured
# 0.22 s/block -- 30x what the window can reach.
SD_FRAMES="${SD_FRAMES:-0}"
KWS_SECONDS="${KWS_SECONDS:-60}"
KWS_INFER_EVERY="${KWS_INFER_EVERY:-10}"
SECONDS_READ="${SECONDS_READ:-180}"

DO_BUILD=1; DO_RUN=1; DO_DECODE=1; LOAD_BIT=1; BUILD_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --window-ms) WINDOW_MS="${2:?}"; shift 2 ;;
    --frames) SD_FRAMES="${2:?}"; shift 2 ;;
    --kws-seconds) KWS_SECONDS="${2:?}"; shift 2 ;;
    --infer-every) KWS_INFER_EVERY="${2:?}"; shift 2 ;;
    --seconds-read) SECONDS_READ="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --no-run) DO_RUN=0; shift ;;
    --no-decode) DO_DECODE=0; shift ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$WINDOW_MS" -gt 0 ] || die "WINDOW_MS must be > 0 -- a 0 window is Lab B153's work-bounded
       run, and scripts/89_b153_tacit_full.sh is where that lives"

RUN="$IISWC_OUT/$NAME"; mkdir -p "$RUN"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${PYNQ_HOST:-}")
KCF="-DMB_PEXT_HW=1 -falign-loops=4 -DMBXR_RT_STAGE_BLOCK=1 -DMBP_B74=1 -DMBP_B76=1 -DMBP_B86=1 -DMBP_B87=1 -DMBP_B86D=1 -DMBP_B101L=1 -DMBP_B102=1 -DMBP_B103=1 -DMBP_B101U=1"

[ -d "$SIGN_GEN" ] || die "no lowered detector at $SIGN_GEN.
       Lower one:  ./scripts/84_signdet_lower.sh                        (random weights, seed 144)
       or install: ./scripts/91_signdet_install_model.sh --from <dir>   (the real ones)
       See docs/SIGNDET_WEIGHTS.md."
for d in "$KWS_GEN" "$BAKE"; do
  [ -d "$d" ] || die "missing input tree: $d"
done
need_file "$BAKE/signdet_frames.c"
need_file "$KWS_META"

# WHICH WEIGHTS ARE ABOUT TO GO INTO THE IMAGE.  Read off the gen tree, never guessed, and
# read BEFORE anything is built so a random-weight run is announced rather than discovered in
# the gates.  A tree with no manifest is somebody's own lowering: it is treated as REAL, which
# is the direction that fails loudly instead of excusing a failure.
WMANIFEST="$SIGN_GEN/signdet_weights.json"
read -r SIGN_WMODE SIGN_OUT_PPB SIGN_REPLAY <<EOF
$(python3 "$IISWC_ROOT/scripts/lib/signdet_weights.py" "$WMANIFEST")
EOF

########################################################################################
build_duo () {
  local d="$1" frames="$2" secs="$3" win="$4"
  mkdir -p "$d"
  run west build -p always -b "$BOARD" "$IISWC_ROOT/samples/tacit_duo" -d "$d/build" -- \
      -DBOARD_ROOT="$IISWC_ROOT" \
      -DEXTRA_CONF_FILE="$IISWC_ROOT/samples/tacit_duo/from_reset.conf" \
      -DSIGN_MODEL_DIR="$SIGN_GEN" -DKWS_MODEL_DIR="$KWS_GEN" \
      -DKWS_FEATMAP="$RUN/kws_featmap.h" -DSD_FRAMES_DIR="$BAKE" \
      -DSD_DEFS="SD_THR_PCT=50 SD_FRAMES=$frames SD_MCLKDIV=3 SD_AE_TARGET=0x60 SD_BUTTON=0 SD_SNAP_LINE=1 SD_DUMP_GRID=0 SD_OUT_SCALE_PPB=${SIGN_OUT_PPB}u" \
      -DKWS_SECONDS="$secs" -DKWS_INFER_EVERY="$KWS_INFER_EVERY" \
      -DDUO_WINDOW_MS="$win" \
      -DMODELBLASTER_KERNEL_CFLAGS="$KCF" > "$d/build.log" 2>&1 \
    || { tail -40 "$d/build.log"; die "build failed -- $d/build.log"; }
  cp "$d/build/zephyr/zephyr.elf" "$d/build/zephyr/zephyr.bin" "$d/"

  # THE LINES THAT MUST BE IN THE IMAGE, CHECKED IN THE IMAGE.  A missing
  # CONFIG_STARTUP_TACIT_TARGET is the silent failure this family of labs is most exposed
  # to: the encoder would run, the arbiter would accept every byte for target 0, and the
  # sink would never see one.
  for kv in CONFIG_STARTUP_TACIT=y CONFIG_STARTUP_TACIT_TARGET=1 \
            CONFIG_STARTUP_TACIT_SINK_DMA_ADDR=0x81000000 \
            CONFIG_STARTUP_TACIT_SINK_DMA_SHIFT=26 CONFIG_MP_MAX_NUM_CPUS=2; do
    grep -q "^$kv\$" "$d/build/zephyr/.config" \
      || die "$d: .config is missing $kv -- without it this is not a from-reset two-hart trace"
  done
  grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$WANT_MTIME_HZ\$" "$d/build/zephyr/.config" \
    || die "$d: board clock is not $WANT_MTIME_HZ"
  # And the window itself, in the compile line rather than in this script's intent.
  grep -q "DUO_WINDOW_MS=$win" "$d/build/compile_commands.json" \
    || die "$d: DUO_WINDOW_MS=$win is not in the compile commands -- the image would be
       bounded by completed work and this lab's whole point would be silently absent"
  info "$(basename "$d"): bin=$(stat -c%s "$d/zephyr.bin") B  window_ms=$win frames=$frames kws_s=$secs"
}

load_pl () {
  # THE LOCK DOES NOT SELECT THE BOARD.  scripts/with_board.sh serialises access; which
  # board you get is PYNQ_HOST and nothing else.  This lab needs the board that has BOTH the
  # HM01B0 camera shield and the SSD1306 OLED on the I2C bus -- point it at one without them
  # and it gets as far as the bitstream and then reports shield=0 with no display.
  [ -n "${PYNQ_HOST:-}" ] || die "PYNQ_HOST is not set -- see board.conf.example. This lab
       needs a board with the camera shield AND the OLED; see fpga/pynq-z2/docs/CAMERA_Z1.md
       and OLED_SSD1306.md."
  "${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
  # The house refusal: resolves through $IISWC_BIT_DIR and /opt/iiswc/bit for the untracked
  # rows of fpga/pynq-z2/bitstreams.csv, and refuses an md5 the manifest disagrees with.
  BIT="$(bitstream_require "$BIT")"
  local md5; md5="$(md5sum "$BIT" | cut -d' ' -f1)"
  [ "$md5" = "$B156_BIT_MD5" ] || die "bitstream md5 $md5 != $B156_BIT_MD5 -- this lab needs
       0x5A5A0039 'tracepanelcam', the ONLY build with a TACIT encoder and sink on BOTH tiles"
  run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
  run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$PYNQ_HOST:$PYNQ_DIR/"
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  # sudo -n, never a password on stdin: BRINGUP.md SS1b installs the passwordless-sudo
  # drop-in, and a lab that cannot answer a prompt should fail rather than carry a secret.
  "${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u $RUNNER \
      --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" > "$RUN/boot.log" 2>&1 || true
  grep -aq "MAGIC = $WANT_MAGIC" "$RUN/boot.log" \
    || { grep -a MAGIC "$RUN/boot.log" || true
         die "expected MAGIC $WANT_MAGIC over GP0 -- the wrong PL is loaded; see $RUN/boot.log"; }
  grep -aE 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true
}

# BOARD CONSOLES CONTAIN BINARY, so every grep over one is `grep -a`.
run_image () {
  local d="$1" mark="$2"
  run scp -q "$d/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
  "${SSH[@]}" "bash -lc '
    cd $PYNQ_DIR
    rm -f console.out
    nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
    CPID=\$!
    sleep 1.5
    sudo -n bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
    for i in \$(seq 1 $SECONDS_READ); do grep -aq \"$mark\" console.out 2>/dev/null && break; sleep 1; done
    kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  '" >> "$d/boot.log" 2>&1 || true
  "${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$d/console.txt" 2>/dev/null || true
  [ -s "$d/console.txt" ] || die "$d: empty console -- look at $PYNQ_DIR/console.out over ssh"
  grep -aq "$mark" "$d/console.txt" || warn "$d: no '$mark' -- the run did not finish"
}

# Rocket's 0x8xxx_xxxx is folded into PS physical {4'd1, addr[27:0]} by the FPGA top, so a
# Rocket address A reads at 0x1000_0000 + (A - 0x8000_0000).  THE BASE IS READ OFF THE
# CONSOLE, never recomputed here.
drain_traces () {
  local d="$1" h n buf phys
  while read -r h buf n; do
    [ "${n:-0}" -gt 0 ] || { warn "hart $h drained 0 bytes"; continue; }
    phys=$(printf '0x%X' $(( buf - 0x80000000 + 0x10000000 )))
    mkdir -p "$d/hart$h"
    info "hart$h  rocket=$(printf '0x%08X' "$buf")  ps=$phys  bytes=$n"
    # -n MATTERS: without it ssh eats this loop's stdin and every later hart is skipped.
    "${SSH[@]}" -n "cd $PYNQ_DIR && sudo -n python3 -u read_mem.py \
        --phys $phys --bytes $n --out tacit$h.out" >> "$d/drain.log" 2>&1 \
      || { warn "$d: could not read hart $h's buffer"; continue; }
    run scp -q "$PYNQ_HOST:$PYNQ_DIR/tacit$h.out" "$d/hart$h/tacit.out" < /dev/null
    local got; got=$(stat -c%s "$d/hart$h/tacit.out")
    [ "$got" -eq "$n" ] || die "$d: hart $h short read ($got of $n)"
  done < <(grep -a "^DUO_TRACE_HART" "$d/console.txt" \
           | sed -E 's/.*hart=([0-9]+) buf=0x([0-9a-fA-F]+) bytes=([0-9]+) .*/\1 0x\2 \3/')
}

# THE SIZING ARITHMETIC, PRINTED.  Reads the run's own TR_SK_DMA_COUNT and span_cycles off
# the console and says what that rate implies for a window of the given length -- which is
# how the next run's buffers are checked BEFORE it is trusted, rather than after.
size_from_rate () {
  local d="$1" win="$2"
  python3 - "$d/console.txt" "$win" "$CLK_HZ" <<'PY'
import re, sys
con, win_ms, clk = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = {}
for l in open(con, errors="replace"):
    m = re.search(r"DUO_TRACE_HART hart=(\d+) buf=0x([0-9a-fA-F]+) bytes=(\d+) "
                  r"span_cycles=(\d+) .*buf_span=(\d+) full_pct=(\d+) armed=(\d+) "
                  r"bytes_per_cycle_x1e6=(\d+) fits=(\d+)", l)
    if m:
        rows[int(m.group(1))] = dict(buf=int(m.group(2), 16), bytes=int(m.group(3)),
                                     span_cycles=int(m.group(4)), buf_span=int(m.group(5)),
                                     full=int(m.group(6)), armed=int(m.group(7)),
                                     bpc=int(m.group(8)) / 1e6, fits=int(m.group(9)))
if not rows:
    sys.exit("no DUO_TRACE_HART line in %s" % con)
want_cyc = win_ms * clk // 1000
print("    %-5s %14s %14s %14s %14s %14s"
      % ("hart", "bytes", "span_cycles", "B/core cycle", "MB/s", "predicted @%dms" % win_ms))
bad = 0
for h in sorted(rows):
    r = rows[h]
    pred = r["bpc"] * want_cyc
    print("    %-5d %14d %14d %14.4f %14.2f %14.0f  (%.0f%% of %d B region)"
          % (h, r["bytes"], r["span_cycles"], r["bpc"], r["bpc"] * clk / 1e6, pred,
             100.0 * pred / r["buf_span"], r["buf_span"]))
    if pred > r["buf_span"]:
        bad = 1
        print("        OVERRUN PREDICTED -- the sink has no limit register: it would write "
              "into the next lane and both traces would still decode.")
end0 = rows[0]["buf"] + rows[0]["bytes"]
print("    base[1]=0x%08X >= base[0]+COUNT[0]=0x%08X : %s"
      % (rows[1]["buf"], end0, "yes" if rows[1]["buf"] >= end0 else "NO -- LANE 1 IS CORRUPT"))
sys.exit(bad)
PY
}

########################################################################################
step "0/6  inputs"
info "board   $BOARD          bitstream $WANT_MAGIC  $(basename "$BIT")"
info "sign    $SIGN_GEN"
if [ "$SIGN_REPLAY" = "not_applicable" ]; then
  cat <<BANNER
    ######################################################################################
    #  WEIGHTS: $SIGN_WMODE -- THIS DETECTOR CANNOT DETECT ANYTHING.
    #
    #  GATE 4 (REPLAY, 8/8 decisions, max |d| = 0) is NOT APPLICABLE and is excluded from
    #  the result.  It is not passed and it is not a failure: the board is being compared
    #  against a host run of a DIFFERENT model.
    #
    #  Every other gate still gates.  What this run demonstrates is the TRACING MECHANISM
    #  (two from-reset TACIT lanes, sized from a measured rate, neither overrunning), the
    #  SCHEDULING RESULT (both lanes busy for the whole window) and the LANE CONVERGENCE
    #  (both lanes end together).  None of that depends on the weights.
    #
    #  The real weights ship with the tutorial image.  See docs/SIGNDET_WEIGHTS.md.
    ######################################################################################
BANNER
else
  info "weights $SIGN_WMODE -- GATE 4 (REPLAY) applies and is a gate"
fi
info "scales  SD_OUT_SCALE_PPB=$SIGN_OUT_PPB  (from $WMANIFEST)"
info "kws     $KWS_GEN"
info "bound   ONE WALL CLOCK: DUO_WINDOW_MS=$WINDOW_MS from the reset vector"
info "feed    SD_FRAMES=$SD_FRAMES (0 = unbounded live loop)   KWS_SECONDS=$KWS_SECONDS  every=$KWS_INFER_EVERY"
python3 -c "
import json; p=json.load(open('$SIGN_GEN/kernel_picks.json'))['picks']
bad=[k for k,v in p.items() if 'curated' not in v['source']]
print('    sign kernels:', ', '.join('%s=%s'%(k,v['algorithm']) for k,v in p.items()))
raise SystemExit('NOT ALL CURATED PEXT: %s'%bad if bad else 0)"

step "1/6  build"
if [ "$DO_BUILD" = 1 ]; then
  run python3 "$IISWC_ROOT/fpga/pynq-z2/sw/tools/gen_feat_map.py" \
      --meta "$KWS_META" --out "$RUN/kws_featmap.h"
  build_duo "$IISWC_OUT/${NAME}_duo" "$SD_FRAMES" "$KWS_SECONDS" "$WINDOW_MS"
else
  info "skipped (--no-build)"
fi
[ "$BUILD_ONLY" = 1 ] && { step "Done (--build-only)"; exit 0; }

step "2/6  the board"
[ "$LOAD_BIT" = 1 ] && load_pl || info "skipped (--no-bitstream)"

step "3/6  run"
d="$IISWC_OUT/${NAME}_duo"
if [ "$DO_RUN" = 1 ]; then
  run_image "$d" "DUO_DONE"
  grep -a -E "^DUO_(BOOT|WINDOW|TRACE_MAP|TRACE_ARM|TRACE_HART|TRACE_GATE|TRACE_END|DONE|FAIL|WARN)" \
      "$d/console.txt" | sed 's/^/    /'
  step "3b/6  the measured rate, and what it implies for this window"
  size_from_rate "$d" "$WINDOW_MS" || die "a lane is predicted to overrun its region"
  step "4/6  drain"
  drain_traces "$d"
else
  info "skipped (--no-run)"
fi

step "5/6  decode both lanes into ONE timeline"
if [ "$DO_DECODE" = 1 ]; then
  need_exec "$TACIT_DECODER" "run scripts/05_build_tacit_tools.sh, or export TACIT_DECODER"
  [ -s "$d/hart0/tacit.out" ] && [ -s "$d/hart1/tacit.out" ] \
    || die "the run did not drain both sinks -- there is no merged timeline to make"
  run "$TACIT_DECODER" --binary "$d/zephyr.elf" --encoder rtl --to-txt --to-perfetto \
      --trace "$d/hart0/tacit.out:0:hart 0 (BIG, MBP) signdet_live" \
      --trace "$d/hart1/tacit.out:1:hart 1 (LITTLE, scalar) kws_live" \
      --merged-perfetto "$d/trace.merged.perfetto.json" > "$d/decode.log" 2>&1 \
    || { tail -20 "$d/decode.log"; die "decode failed -- $d/decode.log"; }
  # TWO DIFFERENT FAILURES LOOK THE SAME HERE (B153).
  #   * a lane that RAN OUT OF BUFFER stops mid-packet and never emits FSync; its
  #     DUO_TRACE_HART line says fits=0 and full_pct is near 100.
  #   * a lane whose hart was NOT RETIRING at the stop leaves the closing packet inside the
  #     encoder; its region is nearly empty and fits=1.  Under a WINDOW both harts are still
  #     running their workloads at the stop, so this should not happen at all -- the trail
  #     thread is kept anyway, because "should not" is not a mechanism.
  n=$(grep -ac "detected FSync packet" "$d/decode.log" || true)
  if [ "$n" -lt 2 ]; then
    grep -a "^DUO_TRACE_HART" "$d/console.txt" | sed 's/^/    /'
    die "only $n FSync packet(s) in $d/decode.log -- at least one lane did not close.
       fits=0 means it overran its region; fits=1 with a small full_pct means its hart was
       idle at the stop -- check the DUO_TRAIL line."
  fi
  # ONE NAME, TWO FUNCTIONS: pext.h is compiled twice into this image and both copies are
  # static, so GCC gives them one .constprop.0 name at two addresses.  Split them from the
  # DISASSEMBLY, never from which lane an event landed on.
  OBJD="$(find "${ZEPHYR_SDK_INSTALL_DIR:-/nonexistent}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)"
  [ -n "$OBJD" ] || OBJD="$(command -v riscv64-zephyr-elf-objdump || true)"
  [ -n "$OBJD" ] || die "no riscv64-zephyr-elf-objdump -- run scripts/00_bootstrap.sh"
  run python3 "$IISWC_ROOT/scripts/lib/b153_disambiguate.py" --objdump "$OBJD" \
      --elf "$d/zephyr.elf" --in "$d/trace.merged.perfetto.json" \
      --out "$d/trace.merged.perfetto.json"
  info "merged timeline: $d/trace.merged.perfetto.json ($(fsize "$d/trace.merged.perfetto.json"))"
fi

step "6/6  the gates"
# A --no-decode arm (the calibration one) has no timeline to gate.  Its numbers are the
# console's own TR_SK_DMA_COUNT, already printed in 3b, and they are the point of it.
if [ ! -s "$d/trace.merged.perfetto.json" ]; then
  info "no merged timeline in $d -- every gate below reads one, so there is nothing to run."
  info "decode it with: ./scripts/90_b156_tacit_window.sh --name $NAME --no-build --no-run --no-bitstream"
  step "Done (calibration arm: rates only)"
  exit 0
fi
# B153's five, unchanged -- lanes, buffers, from-reset coverage, the replay gate, the rate.
run python3 "$IISWC_ROOT/scripts/lib/b153_gates.py" --run "$d" --clk-hz "$CLK_HZ" \
    --weights-manifest "$WMANIFEST" \
    --out "$RUN/gates.json" | tee "$RUN/gates.txt"
# ... and B156's two, which are the ones B153 had no way to fail: is EVERY part of the
# window busy on BOTH lanes, and do the two lanes' model work end together?
run python3 "$IISWC_ROOT/scripts/lib/b156_lane_table.py" \
    --trace "$d/trace.merged.perfetto.json" --clk-hz "$CLK_HZ" --top 5 --buckets 13 \
    --match mb_pext_conv --match fe_log2_q8 \
    --gate-busy --json-out "$RUN/lanes.json" | tee "$RUN/lanes.txt"

step "Done"
info "run record: $RUN/gates.json  $RUN/lanes.json"
info "open it at https://ui.perfetto.dev"
