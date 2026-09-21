#!/usr/bin/env bash
# Lab B32 -- record the board's own microphone, with the RGB LEDs telling the person in the
# room when to speak. The deliverable is a WAV a human can listen to and judge.
#
#   scripts/with_board.sh ./scripts/58_rocket_mic_led_record.sh                    # garden
#   PYNQ_HOST=xilinx@<board-ip> scripts/with_board_illixr.sh \
#       ./scripts/58_rocket_mic_led_record.sh                                      # illixr
#   scripts/with_board.sh ./scripts/58_rocket_mic_led_record.sh --seconds 10
#   ./scripts/58_rocket_mic_led_record.sh --build-only                             # no board
#
# EITHER BOARD, from the start: the host comes from $PYNQ_HOST and the lock from the wrapper
# you call, exactly as fpga/pynq-z2/docs/BRINGUP_ILLIXR.md describes. The board's logical
# name is resolved by scripts/lib/board_id.sh and recorded in run.json, so a recording is
# always attributable to a machine. NOTE, before choosing: every microphone lab this repo
# has run -- rocket_kws, rocket_kws_live_cnn, rocket_digits -- ran on GARDEN. The illixr
# board has never captured audio. For a run whose purpose is a human judgement of audio
# quality, use garden, or you are debugging the room and an unexercised capture chain at
# once.
#
# WHY THIS EXISTS. Every accuracy number on this programme is measured on LibriSpeech files.
# The demo will run on this microphone, in a room, and nobody has ever heard it. Lab B21's
# header flags exactly that gap. This lab closes the first half of it: audio a person can
# play. No transcription, no scoring.
#
# THE LED PROTOCOL -- the LEDs, not the console, say when to speak:
#
#   LD4 RED, steady ................. idle. DO NOT SPEAK.
#   LD4 AMBER, 3 blinks at 1 Hz ..... get ready. Still do not speak.
#   LD4 + LD5 both GREEN ............ SPEAK NOW. Recording.
#   LD5 green -> amber -> red ....... time left; red blinks for the last fifth. LD4 stays
#                                     GREEN throughout, so "still recording?" is one glance.
#   LD4 BLUE, steady ................ done. Stop speaking.
#
# LD0-LD3 ARE NOT CUES and cannot be: src/pynqz2_rocket_top.v ends with
# `assign leds = {err_burst_any, saw_mem, soc_resetn, hb[25]}`, so they are hard-wired PL
# status -- LD0 is a ~0.5 Hz heartbeat that blinks all the way through a recording and means
# nothing about when to speak. The cue is the two RGB lamps only.
#
# THE RATE IS 15,994 Hz, NOT 16,000. The PDM decimator cannot make exactly 16 kHz from this
# SoC's 1000/29 MHz clock; the driver reports what it got and this lab puts THAT in the WAV
# header. Moonshine and the KWS models assume 16 kHz, so the 0.04 % is deliberate and is
# recorded in run.json rather than rounded away.
#
# NOT host/record_pdm.py: that loads PYNQ's base overlay and overwrites the PL, Rocket
# included. This is the Zephyr DMIC path on our own bitstream, which is why Lab B14 exists.
#
# NUMBERING. This script was 57 for about half an hour and collided with
# scripts/57_rocket_moonshine_q16_board.sh (Lab B30), which existed first; the newcomer moves,
# because the never-renumber rule protects lab NUMBERS carried in evidence, not filenames. The
# lab number moved for the opposite reason: the first run of this lab went out labelled
# "B29 mic_led_record" before the number was checked, and B29 belongs to
# scripts/49_rocket_bwwin_lab.sh (claimed 09-17 08:07). B32 is this lab, per
# fpga/pynq-z2/LAB_REGISTRY.md; that one early run record is annotated rather than rewritten.
#
# Produces, under out/<name>/: mic.wav (the deliverable), mic.raw, console.txt, run.json.
# The snapshot into archive/runs/ is UNCONDITIONAL -- docs/EXPERIMENT_LOG_RULES.md,
# "Evidence collection must not be conditional on a verdict".
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

NAME="rocket_mic_led"
BOARD="chipyard_pynqz1_micrgb"
BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_z1"
BIT="$BUILD/pynqz1_rocket_micrgb.bit"
RUNNER="run_rocket_micrgb.py"
SAMPLE="$IISWC_ROOT/samples/mic_led_record"
WANT_MAGIC="0x5A5A0006"
PCM_PHYS=0x1C000000
FCLK_CORE=34.4828
WANT_MTIME_HZ=34483
SECONDS_REC=15; IDLE_MS=3000; BLINKS=3
DO_BOARD=1; DO_ARCHIVE=1; DO_HEALTH=0
ARCHIVE_CMD="${ARCHIVE_CMD:-$IISWC_ROOT/archive/tools/archive_run.py}"
HEALTH_CMD="${HEALTH_CMD:-$IISWC_ROOT/scripts/35_rocket_rgb_leds.sh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --seconds) SECONDS_REC="${2:?}"; shift 2 ;;
    --idle-ms) IDLE_MS="${2:?}"; shift 2 ;;
    --blinks) BLINKS="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    --health) DO_HEALTH=1; shift ;;
    --no-archive) DO_ARCHIVE=0; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
# the full-feature bitstream: the only one with BOTH the microphone and the RGB LEDs
BIT_ACCEPTED="${MICLED_ACCEPTED:-4c8f7bf79e2f2464908eca8656abd691}"
# console window: idle + blinks + recording + boot and print slack
SECONDS_READ=$(( IDLE_MS / 1000 + BLINKS + SECONDS_REC + 14 ))

step "1/6  build the guest ($BOARD, ${SECONDS_REC}s)"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
  -DCONFIG_MIC_LED_SECONDS="$SECONDS_REC" -DCONFIG_MIC_LED_IDLE_MS="$IDLE_MS" \
  -DCONFIG_MIC_LED_READY_BLINKS="$BLINKS" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$RUN/build/zephyr/zephyr.bin" "build produced no raw image"
cp "$RUN/build/zephyr/zephyr.elf" "$RUN/build/zephyr/zephyr.bin" "$RUN/"
grep -q '^CONFIG_AUDIO_DMIC=y' "$RUN/build/zephyr/.config" || die "no DMIC in this image"
grep -q '^CONFIG_GPIO_SIFIVE=y' "$RUN/build/zephyr/.config" \
  || die "CONFIG_GPIO_SIFIVE is not set: no LED cues would appear, and the person in the room
       would have nothing to watch. The gpio@10010000 node did not match sifive,gpio0."
HZ=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$RUN/build/zephyr/.config" | cut -d= -f2)
[ "${HZ:-0}" = "$WANT_MTIME_HZ" ] || die "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, expected $WANT_MTIME_HZ"
info "image: $(fsize "$RUN/zephyr.bin")   board: ${IISWC_BOARD:-unknown} ($PYNQ_HOST)"
sed -n '/LED PROTOCOL/,/^# LD0-LD3/p' "$0" | sed 's/^# \{0,1\}//' | sed 's/^/    /'
[ "$DO_BOARD" -eq 1 ] || { info "--build-only"; exit 0; }

step "2/6  identify the bitstream, load the PL, read the clocks back"
need_file "$BIT" "build it with fpga/pynq-z2/scripts/build_micrgb_z1.sh"
bitstream_identify "$BIT"
bitstream_gate
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$BIT" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC (mic + RGB)"; }
H0=$(date +%s.%N); B0=$("${SSH[@]}" "date +%s.%N" 2>/dev/null || echo ""); H1=$(date +%s.%N)
python3 -c "import json,sys,datetime; h0,h1=float(sys.argv[1]),float(sys.argv[2]); b=sys.argv[3]
json.dump({'workstation_time': datetime.datetime.fromtimestamp((h0+h1)/2).astimezone().isoformat(timespec='seconds'),
 'board_time_epoch_s': float(b) if b else None,
 'board_minus_workstation_s': (float(b)-(h0+h1)/2) if b else None}, open(sys.argv[4],'w'), indent=1)" \
 "$H0" "$H1" "$B0" "$RUN/clocks.json"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
info "microphone + RGB PL loaded ($WANT_MAGIC), SoC held in reset"

step "3/6  record -- WATCH LD4 AND LD5, speak on GREEN (${SECONDS_REC}s)"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out console.stamps
  nohup python3 -u console.py --seconds $SECONDS_READ --stamps console.stamps > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>"$RUN/console_fetch.err" || true
"${SSH[@]}" "cat $PYNQ_DIR/console.stamps" > "$RUN/console.stamps" 2>/dev/null || true
if [ ! -s "$RUN/console.txt" ]; then
  # keep the cause, not just the symptom (docs/EXPERIMENT_LOG_RULES.md)
  [ -s "$RUN/console_fetch.err" ] && { warn "console fetch said:"; sed 's/^/      /' "$RUN/console_fetch.err" >&2; }
  warn "no console output -- see $RUN/boot.log"
fi
grep -E '^MICLED:' "$RUN/console.txt" | sed 's/^/    /' || true

step "4/6  pull the PCM out of DRAM"
NBYTES=$(grep -oE 'pcm_buf 0x[0-9a-f]+ samples [0-9]+ bytes [0-9]+' "$RUN/console.txt" 2>/dev/null \
         | head -1 | awk '{print $6}')
if [ -z "${NBYTES:-}" ]; then
  warn "the guest never printed a pcm_buf line -- the capture did not complete"
else
  info "guest reports $NBYTES bytes at PS physical $PCM_PHYS"
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 -u read_mem.py --phys $PCM_PHYS --bytes $NBYTES --out mic.raw" \
    >> "$RUN/boot.log" 2>&1 || warn "read_mem.py failed -- see $RUN/boot.log"
  scp -q "$PYNQ_HOST:$PYNQ_DIR/mic.raw" "$RUN/mic.raw" 2>/dev/null || warn "could not copy mic.raw"
  [ -s "$RUN/mic.raw" ] && info "pulled $(fsize "$RUN/mic.raw")"
fi

step "5/6  write the WAV (true rate, not 16 kHz) and describe it"
SCORE="$RUN/score.py"
cat > "$SCORE" <<'PY'
import json, os, re, sys, wave
run = sys.argv[1]
con = open(os.path.join(run, "console.txt"), errors="replace").read()
def grab(pat, cast=str, default=None):
    m = re.search(pat, con, re.M)
    return cast(m.group(1)) if m else default
out = {"lab": "B32 mic_led_record", "board": os.environ.get("IISWC_BOARD", ""),
       "pynq_host": os.environ.get("PYNQ_HOST", ""),
       "bitstream_md5": os.environ.get("BIT_MD5", ""), "soc_magic": os.environ.get("WANT_MAGIC", ""),
       "seconds_requested": int(os.environ.get("SECONDS_REC", "0")),
       "booted": "MICLED: start" in con, "done": "MICLED: DONE" in con,
       "rate_hz": grab(r"MICLED: rate (\d+) Hz", int),
       "samples": grab(r"pcm_buf 0x[0-9a-f]+ samples (\d+)", int),
       "dc": grab(r"audio dc (-?\d+)", int), "rms": grab(r"audio dc -?\d+ rms (\d+)", int),
       "peak": grab(r"peak (\d+)", int), "clipped": grab(r"clipped (\d+)", int),
       "phases": dict(re.findall(r"MICLED: phase (\w+) t=(\d+) ms", con)),
       # the legend travels with the record: the person who reads this in six weeks was not
       # in the room and was never briefed on which lamp meant what
       "led_legend": [l.strip() for l in re.findall(r"^MICLED:   (.*)$", con, re.M)]}
for f in ("fclk.json", "clocks.json"):
    p = os.path.join(run, f)
    if os.path.exists(p):
        try: out[f.split(".")[0]] = json.load(open(p))
        except Exception: pass
raw = os.path.join(run, "mic.raw")
if os.path.exists(raw) and out["rate_hz"]:
    data = open(raw, "rb").read()
    n = len(data) // 2
    out["wav_samples"] = n
    out["wav_seconds"] = round(n / out["rate_hz"], 3)
    w = wave.open(os.path.join(run, "mic.wav"), "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(out["rate_hz"])
    w.writeframes(data[: n * 2]); w.close()
    out["wav"] = os.path.join(run, "mic.wav")
    # a level description, NOT a score: is there something to listen to at all?
    import array, math
    a = array.array("h"); a.frombytes(data[: n * 2])
    win = max(1, out["rate_hz"] // 10)
    loud = [max(1, int(math.sqrt(sum(float(v) * v for v in a[i:i + win]) / win)))
            for i in range(0, max(1, n - win), win)]
    if loud:
        q = sorted(loud)
        out["level_rms_p10"], out["level_rms_p50"], out["level_rms_p90"] = (
            q[len(q) // 10], q[len(q) // 2], q[min(len(q) - 1, 9 * len(q) // 10)])
        out["level_dbfs_p50"] = round(20 * math.log10(out["level_rms_p50"] / 32768.0), 1)
        out["level_dbfs_p90"] = round(20 * math.log10(out["level_rms_p90"] / 32768.0), 1)
        out["quiet_to_loud_db"] = round(20 * math.log10(out["level_rms_p90"] / out["level_rms_p10"]), 1)
ok = out["booted"] and out["done"] and out.get("wav") and out.get("rate_hz")
out["verdict"] = "PASS" if ok else "FAIL"
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)
print("   board %s   rate %s Hz   %s samples (%s s)   dc %s rms %s peak %s clipped %s" % (
    out["board"], out["rate_hz"], out.get("samples"), out.get("wav_seconds"),
    out.get("dc"), out.get("rms"), out.get("peak"), out.get("clipped")))
if "level_dbfs_p50" in out:
    print("   level: median %s dBFS, loud tenth %s dBFS, %s dB between the quiet and loud tenths"
          % (out["level_dbfs_p50"], out["level_dbfs_p90"], out["quiet_to_loud_db"]))
    print("   (a description, not a score -- the judgement is the listener's)")
print("   phases (ms): %s" % out["phases"])
print("   verdict %s" % out["verdict"])
sys.exit(0 if ok else 1)
PY
export BIT_MD5 WANT_MAGIC SECONDS_REC IISWC_BOARD PYNQ_HOST
RC=0
{ python3 "$SCORE" "$RUN" | tee "$RUN/report.txt"; } || RC=$?

step "6/6  snapshot -- unconditional, whatever the verdict says"
if [ "$DO_ARCHIVE" -eq 1 ]; then
  run $ARCHIVE_CMD "$NAME" || warn "snapshot failed -- take one by hand"
fi
if [ "$DO_HEALTH" -eq 1 ]; then
  info "Lab 35 health check in this session"
  $HEALTH_CMD || die "Lab 35 health check FAILED after this run"
else
  info "no health check (--health to run one): this lab leaves $WANT_MAGIC loaded, which is
       the same bitstream Lab 35 uses, and the LEDs are parked at LD4 BLUE = done"
fi
[ -s "$RUN/mic.wav" ] && { printf '\n'; info "LISTEN TO THIS:  $RUN/mic.wav"; }
exit "$RC"
