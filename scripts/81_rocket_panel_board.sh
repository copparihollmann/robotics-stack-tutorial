#!/usr/bin/env bash
# Lab B136 -- the first board session on 0x5A5A0037, the tutorial panel, and the acceptance
# test for the two Zephyr boards that were written for it.
#
#   scripts/with_board.sh ./scripts/81_rocket_panel_board.sh
#   scripts/with_board.sh ./scripts/81_rocket_panel_board.sh --seconds 30
#   scripts/with_board.sh ./scripts/81_rocket_panel_board.sh --oled     # 0x5A5A0036, A and B only
#   ./scripts/81_rocket_panel_board.sh --build-only                     # no board, no lock needed
#
# THREE PROOFS, RUN SEPARATELY AND SCORED SEPARATELY, because they fail for different reasons
# and one of them cannot be finished without a person:
#
#   A  THE CONSOLE.  Zephyr's own samples/hello_world, built for chipyard_pynqz1_panel_f40,
#      must print "Hello World! chipyard_pynqz1_panel_f40/rocketchip_virt_riscv64".  This is
#      the proof the board definition exists for: 0x5A5A0037's PLIC puts the UART on source 2
#      where 0x5A5A0035's has it on 1, and an image with the wrong number does not crash --
#      IT PRINTS NOTHING AND LOOKS LIKE A DEAD BOARD.  The banner also carries the board
#      target, so a PASS here says WHICH board file was used, not merely that something ran.
#
#   B  THE OLED IS REACHABLE.  samples/oled_status NOP-probes 0x3c then 0x3d and says
#         oled: ready at 0x3c                    -- the module ACKed
#         oled: no ACK at 0x3c/0x3d, not fitted  -- nothing is on the bus
#      BOTH ARE VALID FINDINGS and this script reports which, because the OLED on this
#      machine is wired DIRECTLY to two PL balls (SCL = P16, SDA = P15 -- the "SCL" and "SDA"
#      positions at the end of shield row J6) and may simply not be plugged in.  What a
#      "ready" proves is that a target ACKed its address on this SoC's own TLI2C; what it
#      does not prove is that the picture is right -- LOOK AT THE GLASS.  See
#      docs/OLED_SSD1306.md section 9.1 before wiring anything.
#
#   C  A BUTTON PRESS REACHES THE SoC.  samples/panel_buttons polls the four pins for
#      --seconds and reports per button whether its level EVER CHANGED.  THIS ONE NEEDS A
#      HUMAN AT THE BENCH.  If nobody presses anything the sample reports pressed_any=NO and
#      this script scores phase C as UNPRESSED -- not PASS and not FAIL.
#
#      *** A STABLE PIN READING IS NOT EVIDENCE THAT A BUTTON WORKS. ***  An unpressed
#      button and a pin whose path to the GPIO register is broken both read 0 forever.  The
#      scorer refuses to call C proven without a transition, and run.json records
#      human_present so the record says whether anyone was ever there.  Do not widen this.
#
# THE SILICON, and it is not rebuilt or modified by this script:
#   0x5A5A0037  roccmoonnch8f40b98bpanel  md5 f1f076322d221eceb6f096bbe42cf45f  (default)
#   0x5A5A0036  roccmoonnch8f40b98boled   md5 6c4a33661dd811bd1716051eb7435ad7  (--oled)
# Both fclk 40 MHz.  0x5A5A0035 (995798be) is untouched.
#
# --oled runs A and B only: 0x5A5A0036's GPIO controller has six pins and no button is wired
# to any of them, so samples/panel_buttons does not compile for chipyard_pynqz1_oled_f40 (a
# BUILD_ASSERT on the sw0 alias says so) and phase C is skipped rather than faked.
#
# BOARD SAFETY.  A 0-byte console or a PS_HOLDS means STOP: this script dies with that
# instruction rather than retrying, per docs/EXPERIMENT_LOG_RULES.md.  The snapshot into
# archive/runs/ is UNCONDITIONAL and runs whatever the verdict says -- L259 is why.
#
# Produces, under out/<name>/: console_a.txt, console_b.txt, console_c.txt, run.json,
# report.txt, plus each image's build directory.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

NAME="rocket_panel"
VARIANT="panel"
SECONDS_BTN=20
DO_BOARD=1; DO_ARCHIVE=1
HUMAN="unknown"
BIT=""
ARCHIVE_CMD="${ARCHIVE_CMD:-$IISWC_ROOT/archive/tools/archive_run.py}"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --seconds) SECONDS_BTN="${2:?}"; shift 2 ;;
    --oled) VARIANT="oled"; shift ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --human) HUMAN="yes"; shift ;;
    --no-human) HUMAN="no"; shift ;;
    --build-only) DO_BOARD=0; shift ;;
    --no-archive) DO_ARCHIVE=0; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$VARIANT" in
  panel)
    BOARD="chipyard_pynqz1_panel_f40"
    BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98bpanel_z1"
    BIT="${BIT:-$BUILD/pynqz1_rocket_micrgb_roccmoonnch8f40b98bpanel.bit}"
    RUNNER="run_rocket_roccmoonnch8f40b98bpanel.py"
    WANT_MAGIC="0x5A5A0037"
    CFGNAME="PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cBtnConfig"
    BIT_ACCEPTED="${PANEL_ACCEPTED:-f1f076322d221eceb6f096bbe42cf45f}"
    DO_BTN=1 ;;
  oled)
    BOARD="chipyard_pynqz1_oled_f40"
    BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98boled_z1"
    BIT="${BIT:-$BUILD/pynqz1_rocket_micrgb_roccmoonnch8f40b98boled.bit}"
    RUNNER="run_rocket_roccmoonnch8f40b98boled.py"
    WANT_MAGIC="0x5A5A0036"
    CFGNAME="PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cConfig"
    BIT_ACCEPTED="${PANEL_ACCEPTED:-6c4a33661dd811bd1716051eb7435ad7}"
    DO_BTN=0 ;;
esac
FCLK_CORE=40.0
WANT_MTIME_HZ=40000
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
ZEPHYR_SAMPLES="$ZCS/zephyr_ws/zephyr/samples"

# ---------------------------------------------------------------------------------------
step "1/6  build the three guests for $BOARD"
build_one() {   # build_one <tag> <sample dir> [extra cmake args...]
  local tag="$1" sample="$2"; shift 2
  run west build -p always -b "$BOARD" "$sample" -d "$RUN/build_$tag" -- \
      -DBOARD_ROOT="$IISWC_ROOT" "$@" > "$RUN/build_$tag.log" 2>&1 \
    || { tail -30 "$RUN/build_$tag.log"; die "build $tag failed -- see $RUN/build_$tag.log"; }
  need_file "$RUN/build_$tag/zephyr/zephyr.bin" "build $tag produced no raw image"
  cp "$RUN/build_$tag/zephyr/zephyr.bin" "$RUN/zephyr_$tag.bin"
  local hz
  hz=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$RUN/build_$tag/zephyr/.config" | cut -d= -f2)
  [ "${hz:-0}" = "$WANT_MTIME_HZ" ] \
    || die "$tag: CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$hz, expected $WANT_MTIME_HZ.
       A 34483 guest on this 40 MHz PL reads 133,779 baud against the host's 115,200 and
       GARBLES the console -- which does not look like a clock problem."
  info "$tag: $(fsize "$RUN/zephyr_$tag.bin")"
}
build_one a "$ZEPHYR_SAMPLES/hello_world"
build_one b "$IISWC_ROOT/samples/oled_status" \
  -DEXTRA_DTC_OVERLAY_FILE="$IISWC_ROOT/samples/oled_status/oled.overlay"
# The interrupt number the console depends on, taken from the IMAGE rather than from the DTS
# that produced it.  This is the one value that makes a wrong board look like a dead board.
UART_IRQ=$(grep -oE '#define DT_N_S_uart_10020000_IRQ_IDX_0_VAL_irq [0-9]+' \
  "$RUN/build_a/zephyr/include/generated/zephyr/devicetree_generated.h" | awk '{print $3}')
[ "${UART_IRQ:-}" = "2" ] \
  || die "the built image puts the UART on PLIC source '${UART_IRQ:-none}', not 2.
       0x5A5A0036/0037 move the UART to source 2 because the TLI2C takes source 1.  A guest
       with this wrong prints nothing and looks like a dead board."
info "console IRQ in the built image: PLIC source $UART_IRQ  (0x5A5A0035's is 1)"
if [ "$DO_BTN" -eq 1 ]; then
  build_one c "$IISWC_ROOT/samples/panel_buttons" -DCONFIG_PANEL_BTN_SECONDS="$SECONDS_BTN"
  grep -q '^CONFIG_GPIO_SIFIVE=y' "$RUN/build_c/zephyr/.config" \
    || die "CONFIG_GPIO_SIFIVE is not set: no button could be read and no lamp could light."
else
  info "c: SKIPPED -- $BOARD has no sw0 alias (this SoC's GPIO has six pins, no buttons)"
fi
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: nothing was loaded and no board was touched"; exit 0; }

# ---------------------------------------------------------------------------------------
step "2/6  identify the bitstream, load the PL, read the clocks back"
need_file "$BIT" "B135 built it; this script never builds or modifies a bitstream"
bitstream_identify "$BIT"
bitstream_gate
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
SCP_FILES=("$RUN/zephyr_a.bin" "$RUN/zephyr_b.bin")
PHASES="a b"
if [ "$DO_BTN" -eq 1 ]; then SCP_FILES+=("$RUN/zephyr_c.bin"); PHASES="a b c"; fi
run scp -q "${SCP_FILES[@]}" "$BIT" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_roccmoon.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
# The runner is a SYMLINK in the repo and scp would copy its target under the wrong name --
# and the MAGIC this loader insists on is looked up from the name it is invoked as.  Make the
# link on the board instead, so the lookup works there.
run "${SSH[@]}" "cd $PYNQ_DIR && ln -sfn run_rocket_roccmoon.py $RUNNER"
for t in $PHASES; do
  l=$(md5sum "$RUN/zephyr_$t.bin" | cut -d' ' -f1)
  r=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr_$t.bin" | cut -d' ' -f1)
  [ "$l" = "$r" ] || die "zephyr_$t.bin corrupted in transfer"
done
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" \
  || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
H0=$(date +%s.%N); B0=$("${SSH[@]}" "date +%s.%N" 2>/dev/null || echo ""); H1=$(date +%s.%N)
python3 -c "import json,sys,datetime; h0,h1=float(sys.argv[1]),float(sys.argv[2]); b=sys.argv[3]
json.dump({'workstation_time': datetime.datetime.fromtimestamp((h0+h1)/2).astimezone().isoformat(timespec='seconds'),
 'board_time_epoch_s': float(b) if b else None,
 'board_minus_workstation_s': (float(b)-(h0+h1)/2) if b else None}, open(sys.argv[4],'w'), indent=1)" \
 "$H0" "$H1" "$B0" "$RUN/clocks.json"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
info "$WANT_MAGIC loaded, SoC held in reset, FCLK0 read back at $FCLK_CORE MHz"

# boot_phase <tag> <console seconds> -- run one image and keep its console.
boot_phase() {
  local tag="$1" secs="$2"
  "${SSH[@]}" "bash -lc '
    cd $PYNQ_DIR
    rm -f console_$tag.out
    nohup python3 -u console.py --seconds $secs > console_$tag.out 2>/dev/null &
    CPID=\$!
    sleep 1.5
    echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr_$tag.bin\" 2>&1 | grep -v sudo
    wait \$CPID
  '" >> "$RUN/boot.log" 2>&1 || true
  "${SSH[@]}" "cat $PYNQ_DIR/console_$tag.out" > "$RUN/console_$tag.txt" 2>/dev/null || true
  local bytes; bytes=$(wc -c < "$RUN/console_$tag.txt" 2>/dev/null || echo 0)
  if [ "${bytes:-0}" -eq 0 ] || grep -q "PS_HOLDS" "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "phase $tag: 0 console bytes or PS_HOLDS. STOP all board work and tell the
       coordinator (docs/EXPERIMENT_LOG_RULES.md). Nothing from this run is a result.
       On THIS lab 0 bytes has a specific first suspect: the console's PLIC source.
       $WANT_MAGIC puts the UART on source 2; an image built for chipyard_pynqz1_micrgb_f40
       puts it on 1, which is the I2C controller here, and prints nothing."
  fi
  info "phase $tag: $bytes console bytes"
}

step "3/6  A -- does the console work?  (hello_world on $BOARD)"
boot_phase a 20
grep -E "^Hello World!" "$RUN/console_a.txt" | sed 's/^/    /' || true

step "4/6  B -- is the OLED reachable?  (samples/oled_status, 0x3c then 0x3d)"
boot_phase b 60
grep -E "^oled: |^OLED_DEMO: " "$RUN/console_b.txt" | sed 's/^/    /' || true

if [ "$DO_BTN" -eq 1 ]; then
  step "5/6  C -- does a button read CHANGE when pressed?  ($SECONDS_BTN s)"
  printf '\n'
  printf '    ############################################################\n'
  printf '    #  PRESS BTN0, BTN1, BTN2 AND BTN3 NOW, one after another. #\n'
  printf '    #  LD4 goes GREEN while a button is held and RED when not. #\n'
  printf '    #  Nobody at the bench?  That is fine and it will be       #\n'
  printf '    #  reported as UNPRESSED, not as a failure and not a pass. #\n'
  printf '    ############################################################\n\n'
  boot_phase c $(( SECONDS_BTN + 15 ))
  grep -E "^PANEL_BTN: " "$RUN/console_c.txt" | sed 's/^/    /' || true
else
  step "5/6  C -- SKIPPED (this SoC has no buttons)"
  : > "$RUN/console_c.txt"
fi

# ---------------------------------------------------------------------------------------
step "6/6  score it, and say plainly what is NOT proven"
UTIL="$BUILD/reports/post_route_util.rpt"; TIM="$BUILD/reports/timing_summary.rpt"
LUT=""; FF=""; BRAM=""; DSP=""; WNS=""; WHS=""
if [ -f "$UTIL" ]; then
  LUT=$(awk -F'|' '/\| Slice LUTs +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  FF=$(awk -F'|' '/\| Slice Registers +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  BRAM=$(awk -F'|' '/\| Block RAM Tile +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  DSP=$(awk -F'|' '/\| DSPs +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
fi
[ -f "$TIM" ] && { read -r WNS WHS <<< "$(awk '/^ *WNS\(ns\)/{getline; getline; print $1, $5; exit}' "$TIM")"; }
SCORE="$RUN/score.py"
# The scorer travels with the run (EXPERIMENT_LOG_RULES.md): how a verdict was computed must
# be readable from the archived directory alone.
cat > "$SCORE" <<'PY'
import json, os, re, sys
run = sys.argv[1]
def con(tag):
    p = os.path.join(run, "console_%s.txt" % tag)
    return open(p, errors="replace").read() if os.path.exists(p) else ""
a, b, c = con("a"), con("b"), con("c")
board = os.environ.get("BOARD", "")
do_btn = os.environ.get("DO_BTN", "0") == "1"

# --- A: the console -------------------------------------------------------------------
banner = re.search(r"^Hello World! (\S+)", a, re.M)
a_target = banner.group(1) if banner else None
a_ok = bool(banner) and a_target.startswith(board)

# --- B: the OLED ----------------------------------------------------------------------
ready = re.search(r"^oled: ready at 0x([0-9a-f]{2})", b, re.M)
absent = "oled: no ACK at 0x3c/0x3d, not fitted" in b
summary = re.search(r"^OLED_DEMO: state=(\w+) addr=0x([0-9a-f]+) frames=(\d+) drawn=(\d+)", b, re.M)
b_state = ("READY" if ready else "ABSENT" if absent else
           (summary.group(1) if summary else "NO_OUTPUT"))
b_addr = ("0x" + ready.group(1)) if ready else None

# --- C: the buttons -------------------------------------------------------------------
btns = []
for m in re.finditer(r"^PANEL_BTN: sw(\d) pin=(\d+) init=(\d) lo=(\d+) hi=(\d+) "
                     r"rise=(\d+) fall=(\d+) changed=(YES|NO)", c, re.M):
    btns.append({"sw": int(m.group(1)), "pin": int(m.group(2)), "init": int(m.group(3)),
                 "lo": int(m.group(4)), "hi": int(m.group(5)), "rise": int(m.group(6)),
                 "fall": int(m.group(7)), "changed": m.group(8) == "YES"})
pressed_any = "PANEL_BTN: pressed_any=YES" in c
c_ran = "PANEL_BTN: done" in c
changed = [x["sw"] for x in btns if x["changed"]]
if not do_btn:
    c_state = "SKIPPED"
elif not c_ran:
    c_state = "NO_OUTPUT"
elif pressed_any and len(changed) == len(btns) and btns:
    c_state = "ALL_PRESSED"
elif pressed_any:
    c_state = "SOME_PRESSED"
else:
    c_state = "UNPRESSED"

# A "verdict" that quietly turned UNPRESSED into a pass would be the whole defect this lab
# was written to avoid, so the three phases are scored SEPARATELY and the overall verdict is
# PASS only when nothing is outstanding.
overall = ("PASS" if a_ok and b_state in ("READY",) and c_state in ("ALL_PRESSED", "SKIPPED")
           else "FAIL" if not a_ok
           else "INCOMPLETE")
out = {"lab": "B136 panel_board", "board_def": board,
       "soc_magic": os.environ.get("WANT_MAGIC", ""), "config": os.environ.get("CFGNAME", ""),
       "bitstream_md5": os.environ.get("BIT_MD5", ""),
       "pynq_host": os.environ.get("PYNQ_HOST", ""), "board": os.environ.get("IISWC_BOARD", ""),
       "uart_plic_source_in_image": int(os.environ.get("UART_IRQ", "0")),
       "human_at_the_bench": os.environ.get("HUMAN", "unknown"),
       "button_window_s": int(os.environ.get("SECONDS_BTN", "0")),
       "phase_a_console": {"ok": a_ok, "banner_target": a_target},
       "phase_b_oled": {"state": b_state, "addr": b_addr,
                        "frames": int(summary.group(3)) if summary else None,
                        "drawn": int(summary.group(4)) if summary else None},
       "phase_c_buttons": {"state": c_state, "pressed_any": pressed_any,
                           "buttons": btns, "changed": changed},
       "verdict": overall,
       "post_route": {k.lower(): os.environ.get(k, "") for k in ("LUT", "FF", "BRAM", "DSP", "WNS", "WHS")},
       "not_proven": []}
for f in ("fclk.json", "clocks.json"):
    p = os.path.join(run, f)
    if os.path.exists(p):
        try: out[f.split(".")[0]] = json.load(open(p))
        except Exception: pass
np = out["not_proven"]
if b_state == "READY":
    np.append("that the PICTURE on the OLED is right -- nothing in software can see the "
              "glass. A person has to look at it.")
if b_state == "ABSENT":
    np.append("anything about the display: no target ACKed 0x3c or 0x3d. Either nothing is "
              "wired to P16/P15, or it is wired wrongly. This is a finding, not a failure.")
if c_state == "UNPRESSED":
    np.append("THAT ANY BUTTON WORKS. No pin level changed during the window. An unpressed "
              "button and a broken path read identically, and this run cannot tell them "
              "apart. Re-run with a person at the bench.")
if c_state == "SOME_PRESSED":
    np.append("that buttons %s work: those pins never changed while the others did."
              % [x["sw"] for x in btns if not x["changed"]])
if c_state == "SKIPPED":
    np.append("anything about buttons: this SoC has none.")
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)
print("   A console : %-12s banner=%s" % ("PASS" if a_ok else "FAIL", a_target))
print("   B oled    : %-12s addr=%s" % (b_state, b_addr))
print("   C buttons : %-12s changed=%s" % (c_state, changed))
print("   verdict   : %s" % overall)
for line in np:
    print("   NOT PROVEN: %s" % line)
print("   wrote %s" % os.path.join(run, "run.json"))
sys.exit(0 if overall == "PASS" else 1)
PY
export BOARD DO_BTN WANT_MAGIC CFGNAME BIT_MD5 UART_IRQ HUMAN SECONDS_BTN LUT FF BRAM DSP WNS WHS
set +e
python3 "$SCORE" "$RUN" | tee "$RUN/report.txt"
VERDICT_RC=${PIPESTATUS[0]}
set -e

# UNCONDITIONAL, and before the exit code is honoured: on 2026-09-17 a FAIL killed a script
# before its own snapshot and the run most worth keeping kept no evidence (L259).
if [ "$DO_ARCHIVE" -eq 1 ]; then
  step "archive the run"
  run $ARCHIVE_CMD "$NAME" || warn "archive_run.py failed -- snapshot $RUN by hand"
fi
exit "$VERDICT_RC"
