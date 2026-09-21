#!/usr/bin/env bash
# Lab B28 -- the 0.96" SSD1306 OLED on the camera shield's I2C bus, on bitstream 0x5A5A001E
# (fpga/pynq-z2/docs/OLED_SSD1306.md).
#
#   scripts/with_board.sh ./scripts/56_rocket_oled_board.sh
#   scripts/with_board.sh ./scripts/56_rocket_oled_board.sh --pattern-ms 6000 --frames 600
#   ./scripts/56_rocket_oled_board.sh --build-only        # no board, no lock needed
#
# DO NOT RUN THIS UNTIL the camera bitstream exists AND the coordinator says go: it loads the
# PL. Until an accepted md5 is in OLED_ACCEPTED (or scripts/lib/bitstream_id.sh), the gate in
# step 2 refuses every bitstream, which is the intended state.
#
# samples/oled_status on chipyard_pynqz1_cam, with or without a display fitted. The guest
# probes 0x3c then 0x3d with one NOP command and says which case it is in:
#
#   fitted      "oled: ready at 0x3c" -- then a test pattern (border, checkerboard, text, a
#               50 % bar), then the five-line status screen refreshing once a second while a
#               simulated capture loop runs at 30 fps
#   not fitted  "oled: no ACK at 0x3c/0x3d, not fitted" -- A PASS, not a failure. The shield
#               was ordered 2026-09-15 and the module is a separate part.
#
# WHAT THIS LAB CAN AND CANNOT PROVE. Like the RGB LEDs (RGB_LEDS.md section 6), the last step
# has no readback: nothing in software can see that the glass lit up. What it does prove:
#
#   PROVEN HERE      the module ACKed its address and every byte of every transfer (any NACK
#                    fails the SSD1306 driver and the sample reports FAILED); the init
#                    sequence and 1,024 framebuffer bytes went out per refresh; the number of
#                    refreshes; and that the 30 fps loop was never late -- the display costs
#                    idle time, not capture time
#   PROVEN EARLIER   that those bytes are the right ones: the host golden (scripts/54) and the
#                    same image out of the RTL (scripts/55)
#   NOT PROVEN       that the picture is right. LOOK AT THE DISPLAY: the pattern first, then
#                    "0x5A5A001E roccmoon", a frame counter, fps, a label with a bar, and RTF.
#
# A false "not fitted" is possible in one way worth knowing: a module whose SDA driver cannot
# pull this bus (1.5-2.2 kohm) below the FPGA's V_IL would not be seen. OLED_SSD1306.md
# section 1. If the module is fitted and this says otherwise, check the header's pin order
# against the module before suspecting software.
#
# AFTER THE SESSION (docs/EXPERIMENT_LOG_RULES.md): this script snapshots the run itself with
# archive/tools/archive_run.py and then runs the Lab 35 health check IN THIS SESSION. If the
# run reports PS_HOLDS or 0 console bytes, stop all board work and tell the coordinator.
#
# THE SNAPSHOT IS UNCONDITIONAL, and deliberately so: it runs whatever the verdict says. On
# 2026-09-17 a FAIL killed this script before its own snapshot, so the run most worth keeping
# kept no evidence (docs/EXPERIMENT_LOG.md L259). The scorer is written to the run directory
# as score.py and archived with it, so how a verdict was computed travels with the run.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

NAME="rocket_oled"
BOARD="chipyard_pynqz1_cam"
BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmooncam_z1"
BIT="$BUILD/pynqz1_rocket_micrgb_roccmooncam.bit"
RUNNER="run_rocket_roccmooncam.py"
SAMPLE="$IISWC_ROOT/samples/oled_status"
OVERLAY="$SAMPLE/oled.overlay"
WANT_MAGIC="0x5A5A001E"
CFGNAME="PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig"
FCLK_CORE=34.4828
WANT_MTIME_HZ=34483
PATTERN_MS=5000; FRAMES=450; PERIOD_MS=1000; IDLE_READ=40
DO_BOARD=1; DO_HEALTH=1; DO_ARCHIVE=1; SELFTEST=""
# The two side effects of steps 5 and 6, as commands, so --selftest can put stubs in their
# place. Nothing else should ever override these.
ARCHIVE_CMD="${ARCHIVE_CMD:-$IISWC_ROOT/archive/tools/archive_run.py}"
HEALTH_CMD="${HEALTH_CMD:-$IISWC_ROOT/scripts/35_rocket_rgb_leds.sh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --build) BUILD="${2:?}"; shift 2 ;;
    --pattern-ms) PATTERN_MS="${2:?}"; shift 2 ;;
    --frames) FRAMES="${2:?}"; shift 2 ;;
    --period-ms) PERIOD_MS="${2:?}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    --selftest) SELFTEST="${2:?pass|fail}"; shift 2 ;;
    --no-health) DO_HEALTH=0; shift ;;
    --no-archive) DO_ARCHIVE=0; shift ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"

# --selftest pass|fail: run steps 4-6 offline against a synthetic run directory, with the
# snapshot and the health check replaced by stubs that leave a marker. It exists for one
# reason: step 5 and step 6 only matter on the FAILING path, and that path is the one that
# was broken (L259, OLED_SSD1306.md 7.7.1). An untested scorer is how this went wrong the
# first time, so the fix ships with the failing path exercised.
if [ -n "$SELFTEST" ]; then
  T="$(mktemp -d "${TMPDIR:-/tmp}/oled-selftest.XXXXXX")"
  trap 'rm -rf "$T"' EXIT
  RUN="$T/run"; mkdir -p "$RUN/build/zephyr"
  NAME="oled_selftest"
  ARCHIVE_CMD="touch $T/archive_ran --"
  HEALTH_CMD="touch $T/health_ran"
  DO_BOARD=1; DO_ARCHIVE=1; DO_HEALTH=1
  cp "$IISWC_ROOT/archive/runs/rocket_oled@20260917T1427/fclk.json" "$RUN/fclk.json"
  cp "$IISWC_ROOT/archive/runs/rocket_oled@20260917T1427/clocks.json" "$RUN/clocks.json"
  echo "CONFIG_OLED_DEMO_FRAME_MS=33" > "$RUN/build/zephyr/.config"
  # the 14:27 run's own console: 3,600 frames after a 30 s pattern, 111 screens, never late
  cat > "$RUN/console.txt" <<'CON'
OLED_DEMO: start
oled: ready at 0x3c
OLED_DEMO: state=READY addr=0x3c frames=3600 drawn=111 late_max_ms=0 render_cycles=87800 xfer_cycles=2930786
OLED_DEMO: done
CON
  FRAMES=3600; PATTERN_MS=30000; PERIOD_MS=1000
  if [ "$SELFTEST" = fail ]; then
    # force the failing path without pretending the hardware failed: demand a screen count
    # nothing could draw. This is the exact shape of the 14:27 mis-score.
    SELFTEST_FLOOR=99999
  fi
  step "selftest ($SELFTEST): steps 4-6 offline, snapshot and health check stubbed"
fi
[ -n "$SELFTEST" ] || { rm -rf "$RUN"; mkdir -p "$RUN"; }

# The camera bitstream this lab may load. 659c6db6 is 0x5A5A001E as built 2026-09-17 11:33,
# already accepted for Lab B27 (scripts/66, scripts/lib/bitstream_id.sh); the coordinator
# cleared it for this lab on 2026-09-17. Anything else is refused by bitstream_gate whatever
# MAGIC it reports -- a new camera build has to be re-accepted here, not just rebuilt.
OLED_ACCEPTED="${OLED_ACCEPTED:-659c6db6ecdbe091a7ff4494881f4e2e}"
BIT_ACCEPTED="$OLED_ACCEPTED"

# The demo runs for FRAMES frames at 33 ms plus the pattern; the console reader outlives it.
RUN_S=$(( (FRAMES * 33 + PATTERN_MS) / 1000 + 6 ))

if [ -n "$SELFTEST" ]; then
  FRAME_MS=33; BIT_MD5="selftest"; SELFTEST_FLOOR="${SELFTEST_FLOOR:-}"
else
step "1/6  build the guest ($BOARD)"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
  -DEXTRA_DTC_OVERLAY_FILE="$OVERLAY" \
  -DCONFIG_OLED_DEMO_FRAMES="$FRAMES" -DCONFIG_OLED_DEMO_PATTERN_MS="$PATTERN_MS" \
  -DCONFIG_OLED_STATUS_PERIOD_MS="$PERIOD_MS" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$RUN/build/zephyr/zephyr.bin" "build produced no raw image"
cp "$RUN/build/zephyr/zephyr.elf" "$RUN/build/zephyr/zephyr.bin" "$RUN/build/zephyr/zephyr.dts" "$RUN/"
# The three things that turn a working display into a silently dark one.
grep -q '^CONFIG_I2C_SIFIVE=y' "$RUN/build/zephyr/.config" \
  || die "CONFIG_I2C_SIFIVE is not set: i2c@10040000 did not match sifive,i2c0"
grep -q '^CONFIG_SSD1306=y' "$RUN/build/zephyr/.config" \
  || die "CONFIG_SSD1306 is not set: the ssd1306 nodes in $OVERLAY did not match solomon,ssd1306fb"
grep -q '^CONFIG_CHARACTER_FRAMEBUFFER=y' "$RUN/build/zephyr/.config" || die "CFB is not in this image"
grep -q 'One address phase per TRANSFER' "$ZEPHYR_BASE/drivers/i2c/i2c_sifive.c" \
  || die "patches/0120 is not applied to $ZEPHYR_BASE -- run scripts/06_patch_zephyr.sh.
       Without it every ssd1306 write carries a repeated START and the screen is noise
       (fpga/pynq-z2/docs/OLED_SSD1306.md section 7.2)."
HZ=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$RUN/build/zephyr/.config" | cut -d= -f2)
[ "${HZ:-0}" = "$WANT_MTIME_HZ" ] || die "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, expected $WANT_MTIME_HZ"
FBUS=$(python3 - "$RUN/zephyr.dts" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"i2c@10040000 \{(.*?)\n\t\};", t, re.S)
f = re.search(r"clock-frequency = < (0x[0-9a-f]+|\d+) >", m.group(1)) if m else None
print(int(f.group(1), 0) if f else 0)
PY
)
[ "$FBUS" = "100000" ] || die "the built devicetree asks for clock-frequency=$FBUS, not 100000.
       One controller means one prescaler for the camera and the display; 400000 measures
       430.6 kHz, over the Fast-mode limit (OLED_SSD1306.md section 7.3)."
info "image: $(fsize "$RUN/zephyr.bin")   mtime: $HZ Hz   i2c bus: $FBUS Hz   0120: applied"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only"; exit 0; }

step "2/6  identify the bitstream, load the PL, read the clocks back"
need_file "$BIT" "no bitstream -- build it with fpga/pynq-z2/scripts/build_roccmooncam_z1.sh"
bitstream_identify "$BIT"
bitstream_gate
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
H0=$(date +%s.%N); B0=$("${SSH[@]}" "date +%s.%N" 2>/dev/null || echo ""); H1=$(date +%s.%N)
python3 -c "import json,sys,datetime; h0,h1=float(sys.argv[1]),float(sys.argv[2]); b=sys.argv[3]
out={'workstation_time': datetime.datetime.fromtimestamp((h0+h1)/2).astimezone().isoformat(timespec='seconds'),
     'board_time_epoch_s': float(b) if b else None,
     'board_minus_workstation_s': (float(b)-(h0+h1)/2) if b else None, 'ssh_round_trip_s': h1-h0}
json.dump(out, open(sys.argv[4],'w'), indent=1)" "$H0" "$H1" "$B0" "$RUN/clocks.json"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }

step "3/6  boot, and watch the display for ${RUN_S}s -- LOOK AT THE BOARD"
info "pattern for ${PATTERN_MS} ms, then the status screen every ${PERIOD_MS} ms while $FRAMES frames run"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $RUN_S --idle $IDLE_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
BYTES=$(wc -c < "$RUN/console.txt" 2>/dev/null || echo 0)
if [ "${BYTES:-0}" -eq 0 ] || grep -q "PS_HOLDS" "$RUN/boot.log"; then
  cat "$RUN/boot.log"
  die "0 console bytes or PS_HOLDS. STOP all board work and message the coordinator
       (docs/EXPERIMENT_LOG_RULES.md). Nothing from this run is a result."
fi
grep -E '^(OLED_DEMO|oled):' "$RUN/console.txt" | sed 's/^/    /' \
  || { tail -40 "$RUN/console.txt"; die "no OLED lines: the guest did not reach main()"; }

fi   # end of the board-only steps 1-3

step "4/6  run.json"
FRAME_MS=$(grep -E '^CONFIG_OLED_DEMO_FRAME_MS=' "$RUN/build/zephyr/.config" | cut -d= -f2)
export BIT_MD5 WANT_MAGIC CFGNAME FRAMES PATTERN_MS PERIOD_MS FRAME_MS FBUS SELFTEST_FLOOR
SCORE="$RUN/score.py"
cat > "$SCORE" <<'PY'
import json, os, re, sys
run = sys.argv[1]
con = open(os.path.join(run, "console.txt"), errors="replace").read()
m = re.search(r"^OLED_DEMO: state=(\w+) addr=0x([0-9a-f]+) frames=(\d+) drawn=(\d+) late_max_ms=(-?\d+)",
              con, re.M)
ready = re.search(r"^oled: ready at 0x([0-9a-f]+)", con, re.M)
absent = re.search(r"^oled: no ACK at 0x3c/0x3d, not fitted", con, re.M)
failed = re.search(r"^oled: (ACKed but init failed|refresh failed|framebuffer setup failed)", con, re.M)
out = {"lab": "B28 oled_status", "bitstream_md5": os.environ.get("BIT_MD5", ""),
       "soc_magic": os.environ.get("WANT_MAGIC", ""), "config": os.environ.get("CFGNAME", ""),
       "i2c_clock_frequency_hz": int(os.environ.get("FBUS", "0")),
       "demo": {k: int(os.environ.get(k.upper(), "0"))
                for k in ("frames", "pattern_ms", "period_ms", "frame_ms")},
       "fclk": json.load(open(os.path.join(run, "fclk.json"))),
       "clocks": json.load(open(os.path.join(run, "clocks.json"))),
       "booted": "OLED_DEMO: start" in con, "done": "OLED_DEMO: done" in con}
if m:
    out["state"], out["addr"] = m.group(1), int(m.group(2), 16)
    out["frames"], out["screens_drawn"], out["late_max_ms"] = (int(m.group(3)), int(m.group(4)), int(m.group(5)))
out["display_fitted"] = bool(ready)
out["not_fitted"] = bool(absent)
out["driver_failure"] = failed.group(1) if failed else None
# Every I2C transfer ACKed: the sample stops at the first failure and says so.
ok_bus = out["booted"] and out["done"] and not out["driver_failure"]
cyc = re.search(r"render_cycles=(\d+) xfer_cycles=(\d+)", con)
if cyc:
    out["last_render_cycles"], out["last_xfer_cycles"] = int(cyc.group(1)), int(cyc.group(2))
if out["display_fitted"]:
    # HOW MANY SCREENS TO EXPECT.  Two things the first version of this got wrong, and both
    # of them scored a working display as a failure (docs/EXPERIMENT_LOG.md L259):
    #
    #   1. THE PATTERN IS NOT PART OF THE STATUS WINDOW.  samples/oled_status shows the test
    #      pattern for --pattern-ms BEFORE the frame loop starts, and posts no status during
    #      it.  The old formula took the whole run as status time, so a run with a long
    #      pattern (--pattern-ms 30000) failed by construction.  Only frames x frame_ms is
    #      status time.
    #   2. A REFRESH IS NOT FREE.  The thread waits period_ms AFTER finishing the previous
    #      refresh, and a refresh is ~90 ms of busy-polled I2C at 100 kHz
    #      (fpga/pynq-z2/docs/OLED_SSD1306.md 7.5).  So the cycle is period + refresh, not
    #      period, which is another 8 % fewer screens at a 1 s period.
    #
    # Both are taken from THIS run: frame_ms from the built .config, the refresh cost from
    # the console line the sample prints.  The 0.8 is scheduling margin -- this is a floor,
    # not a prediction.
    frame_ms = max(out["demo"].get("frame_ms", 33), 1)
    hz = float(out["fclk"]["fclk0"]["mhz"]) * 1e6
    refresh_ms = (out.get("last_render_cycles", 0) + out.get("last_xfer_cycles", 0)) / hz * 1e3
    if refresh_ms <= 0:
        refresh_ms = 90.0   # the measured figure at clock-frequency = 100000
    cycle_ms = out["demo"]["period_ms"] + refresh_ms
    ideal = out["demo"]["frames"] * frame_ms / cycle_ms
    want = max(1, int(ideal * 0.8))
    if os.environ.get("SELFTEST_FLOOR"):        # --selftest fail: force the failing path
        want = int(os.environ["SELFTEST_FLOOR"])
    out["refresh_ms_measured"] = round(refresh_ms, 2)
    out["screens_ideal"] = round(ideal, 1)
    out["screens_expected_at_least"] = want
    ok = ok_bus and out.get("state") == "READY" and out.get("screens_drawn", 0) >= want \
         and out.get("late_max_ms", 999) <= 2
else:
    out["screens_expected_at_least"] = 0
    ok = ok_bus and out.get("state") == "ABSENT" and out.get("screens_drawn", 1) == 0
out["verdict"] = "PASS" if ok else "FAIL"
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)
print("   display: %s   state %s   screens drawn %s   loop late_max %s ms   verdict %s" % (
    "FITTED at 0x%02x" % out["addr"] if out["display_fitted"] else "not fitted",
    out.get("state"), out.get("screens_drawn"), out.get("late_max_ms"), out["verdict"]))
if out["display_fitted"]:
    print("   NOW LOOK AT THE DISPLAY: nothing here can see the glass. Expect the status screen,")
    print("   top line '0x5A5A001E roccmoon'. The pattern came first, %d ms of it." % out["demo"]["pattern_ms"])
else:
    print("   'not fitted' is a PASS. If a module IS plugged in, check its pin order and")
    print("   whether its SDA can pull this bus down (OLED_SSD1306.md section 1).")
print("   wrote %s" % os.path.join(run, "run.json"))
sys.exit(0 if out["verdict"] == "PASS" else 1)
PY
# `|| RC=$?` and nothing else: lib/common.sh sets -e AND pipefail, so a bare `RC=$?` after a
# failing pipeline never runs -- the shell exits first. That is exactly what happened on
# 2026-09-17 14:27: a verdict of FAIL killed the script HERE, before the snapshot below, so
# the run most worth keeping was the one that kept no evidence (L259). A verdict must never
# decide whether evidence is collected.
RC=0
{ python3 "$SCORE" "$RUN" | tee "$RUN/report.txt"; } || RC=$?

step "5/6  snapshot -- unconditional, whatever the verdict says"
if [ "$DO_ARCHIVE" -eq 1 ]; then
  run $ARCHIVE_CMD "$NAME" || warn "snapshot failed -- take one by hand"
fi
[ "$RC" -eq 0 ] || warn "verdict FAIL -- the run IS archived above; read it before believing the verdict"

step "6/6  health check"
if [ "$DO_HEALTH" -eq 1 ]; then
  # Called DIRECTLY, not through with_board.sh: this session already holds the board, and a
  # nested wrapper would wait for a lock it is itself holding. Lab 35 loads 0x5A5A0006, so
  # the camera bitstream is gone after this point -- that is the health check.
  info "Lab 35 health check in this session (it loads 0x5A5A0006 and leaves it there)"
  $HEALTH_CMD || die "Lab 35 health check FAILED after this run"
fi
if [ -n "$SELFTEST" ]; then
  fails=0
  [ -f "$T/archive_ran" ] || { fails=1; printf '  \033[1;31mSELFTEST FAIL\033[0m the snapshot did not run\n'; }
  [ -f "$T/health_ran" ]  || { fails=1; printf '  \033[1;31mSELFTEST FAIL\033[0m the health check did not run\n'; }
  for f in run.json report.txt score.py console.txt fclk.json clocks.json; do
    [ -s "$RUN/$f" ] || { fails=1; printf '  \033[1;31mSELFTEST FAIL\033[0m %s missing from the run directory\n' "$f"; }
  done
  want_rc=0; [ "$SELFTEST" = fail ] && want_rc=1
  [ "$RC" -eq "$want_rc" ] || { fails=1; printf '  \033[1;31mSELFTEST FAIL\033[0m exit status %s, expected %s\n' "$RC" "$want_rc"; }
  if [ "$fails" -eq 0 ]; then
    info "SELFTEST PASS ($SELFTEST): verdict $(python3 -c "import json;print(json.load(open('$RUN/run.json'))['verdict'])"), snapshot ran, health check ran, run directory complete"
    exit 0
  fi
  die "SELFTEST FAILED ($SELFTEST)"
fi
exit "$RC"
