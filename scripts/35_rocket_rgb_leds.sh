#!/usr/bin/env bash
# Lab B15 -- drive the PYNQ-Z1's two RGB LEDs (LD4, LD5) from Zephyr, on the FPGA, through
# the standard GPIO API:
#
#   west build (chipyard_pynqz1_micrgb)  ->  scp zephyr.bin  ->  PS writes DDR
#   ->  release reset  ->  Zephyr opens /soc/gpio@10010000  ->  22 s of colour
#   ->  and the whole time, the ARM watches the same six wires over GP0
#
# Same shape as 34_rocket_mic_capture.sh, which it deliberately does not modify. The
# differences:
#
#   * a different bitstream    build_rocket_micrgb_z1/pynqz1_rocket_micrgb.bit
#   * a different MAGIC        0x5A5A0006. The RGB design is the mic design plus a stock
#                              sifive GPIO controller -- same harts, same ISA, same clock,
#                              same microphone, same pins for everything else -- so an
#                              image built for either boots on the other and says nothing.
#   * a different Zephyr board chipyard_pynqz1_micrgb (= pynqz1_mic + the gpio node)
#   * a second observer        the ARM samples STATUS[9:4] over M_AXI_GP0 while the guest
#                              runs, so the six signals are watched by something that is
#                              not the program driving them.
#
# ---------------------------------------------------------------------------------------
# WHAT "PASS" MEANS HERE, AND WHAT IT CANNOT MEAN.
#
# NOBODY CAN SEE THE BOARD FROM HERE. An output pin has no readback: there is no way, in
# software, to establish that the LED silkscreened LD4 turned red. This lab therefore
# checks everything up to that last step and says clearly where it stops.
#
#   PROVEN BY THIS SCRIPT
#     readbacks         every step's six-bit pattern read back out of the controller's
#                       input_value register and compared with what was written. Covers
#                       Zephyr -> output_value/output_en -> six ChipTop ports -> the FPGA
#                       top's pad model -> input_value. A permuted or truncated bit vector
#                       anywhere in there fails.
#     quiescent zero    with all six off, the readback is 000000 and not 111111 -- so the
#                       comparisons above are not passing through an inverted pad model.
#     host agreement    the ARM, reading GP0 as a different master on a different bus with
#                       no help from the guest, sees the SAME six signals take the SAME
#                       distinct values. That is the closest thing to an independent
#                       witness these pins have.
#     park state        after the run the board holds one specific asymmetric pattern, and
#                       both observers agree on which.
#     timing            the steps really were RGB_STEP_MS apart, so the printed schedule
#                       matches what a person watching actually saw.
#
#   PROVEN AT BUILD TIME, NOT HERE
#     each of the six ports landed on the package ball the vendor sources name, asserted
#     against the ROUTED design -- see fpga/pynq-z2/scripts/build_micrgb_z1.sh.
#
#   NOT PROVEN BY ANYTHING AUTOMATIC
#     that N15 is LD4's RED die. Two independent vendor sources say so
#     (fpga/pynq-z2/docs/RGB_LEDS.md section 1) and they agree, but it is a fact about a
#     PCB. LOOK AT THE BOARD. The run parks at LD4 red + LD5 blue precisely so that one
#     glance settles it.
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin   the guest
#   console.txt               the per-step narration and readbacks
#   host_status.txt           the ARM's samples of STATUS[9:4] during the run
#   run.json                  manifest
#
# OVER SERIAL ALONE. This runner uses ssh/scp because this bench has a network; the lab
# does not need one, and of everything in this repo it is the one that degrades best to a
# single micro-USB cable. That cable carries the ARM's Linux console on /dev/ttyPS0, and
# Rocket's console is /dev/ttyPS1 ON THE BOARD (UART.md section B) -- so loading the PL,
# booting the guest, reading the narration and running read_rgb_status.py are all just
# typing at the serial shell. The part that does not work over serial is getting the 4.0 MB
# .bit across: pre-stage it on the SD card. And the part nobody else has: THE RESULT DOES
# NOT HAVE TO COME BACK. Every other hardware lab here produces a trace, a WAV or a tensor
# that has to reach the workstation; this one produces photons. See RGB_LEDS.md section 9.4.
#
# Usage:
#   scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh
#   scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh --no-bitstream
#   scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh --step-ms 2000 --cycles 5
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$IISWC_ROOT/samples/rgb_led_walk"
NAME="rocket_rgb"
BOARD="chipyard_pynqz1_micrgb"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_z1/pynqz1_rocket_micrgb.bit"
EXPECT="$IISWC_ROOT/expected/rgb_led_walk.json"
LOAD_BIT=1
STEP_MS=1000
CYCLES=2
WANT_MTIME_HZ=34483
while [ $# -gt 0 ]; do
  case "$1" in
    --sample)  SAMPLE="${2:?}"; shift 2 ;;
    --name)    NAME="${2:?}";   shift 2 ;;
    --board)   BOARD="${2:?}";  shift 2 ;;
    --step-ms) STEP_MS="${2:?}"; shift 2 ;;
    --cycles)  CYCLES="${2:?}";  shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --no-check) EXPECT=""; shift ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"

# 11 steps a cycle (the sample's own table), plus boot, plus slack.
STEPS_PER_CYCLE=11
RUN_S=$(( (CYCLES * STEPS_PER_CYCLE * STEP_MS) / 1000 ))
SECONDS_READ=$(( RUN_S + 14 ))

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; BUILD="$RUN/build"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/6  build  ($BOARD)"
info "sample: $SAMPLE   ${CYCLES} cycles x ${STEPS_PER_CYCLE} steps x ${STEP_MS} ms = ${RUN_S} s"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- -DBOARD_ROOT="$IISWC_ROOT" \
  -DRGB_STEP_MS="$STEP_MS" -DRGB_CYCLES="$CYCLES" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"

# The driver is stock Zephyr and is default-y on the devicetree node, so the thing that can
# go wrong is the NODE, not the driver: a compatible that does not match leaves
# CONFIG_GPIO_SIFIVE unset and every gpio call returns -ENODEV at a point where the console
# still looks perfectly healthy.
grep -q '^CONFIG_GPIO_SIFIVE=y' "$BUILD/zephyr/.config" \
  || die "CONFIG_GPIO_SIFIVE is not set in this image -- the gpio@10010000 node did not
       match the sifive,gpio0 binding, so the controller would never be probed and every
       LED would stay dark with no error. Check boards/chipyard/pynqz1_micrgb."
HZ=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${HZ:-0}" = "$WANT_MTIME_HZ" ] || die "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, expected
       $WANT_MTIME_HZ. That constant sets the SiFive UART's baud divisor as well as the
       tick rate, so a mismatch shows up as a GARBLED console -- see FPGA_END_TO_END.md 4.1."
info "bin: $(fsize "$RUN/zephyr.bin")   mtime: $HZ Hz   gpio_sifive: in"

step "2/6  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_micrgb.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_rgb_status.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "3/6  load the PL, set FCLK0 and hold the SoC in reset"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "build it with fpga/pynq-z2/scripts/build_micrgb_z1.sh"
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD_ARGS="--bitstream $(basename "$BIT") --hold"
else
  HOLD_ARGS="--no-load --hold"
fi
wrong_pl () {
  # `|| true` is load-bearing: common.sh sets `set -euo pipefail`, so a grep that finds
  # nothing kills the script before the fallback below runs. See 34_rocket_mic_capture.sh.
  M=$(grep -oE 'MAGIC = 0x5A5A000[0-9]' "$RUN/boot.log" 2>/dev/null | head -1 || true)
  case "$M" in
    "MAGIC = 0x5A5A0005") cat "$RUN/boot.log"; die "the MICROPHONE bitstream is loaded
       ($M). It has no GPIO controller: 0x1001_0000 is not in its address map, so the
       driver would read back zeros, every LED would stay dark, and the run would look
       healthy. Re-run without --no-bitstream." ;;
    "MAGIC = 0x5A5A0004") cat "$RUN/boot.log"; die "the P-EXT bitstream is loaded ($M)." ;;
    "MAGIC = 0x5A5A0003") cat "$RUN/boot.log"; die "the plain DUAL-CORE bitstream is loaded ($M)." ;;
    "MAGIC = 0x5A5A0002") cat "$RUN/boot.log"; die "the SINGLE-core bitstream is loaded ($M)." ;;
    "MAGIC = 0x5A5A0001") cat "$RUN/boot.log"; die "the DRAM self-test bitstream is loaded ($M)." ;;
  esac
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_micrgb.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_micrgb.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0006' "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "RGB bitstream not reachable over GP0"
}
grep -E 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true
info "RGB PL loaded, SoC held in reset"

step "4/6  boot, and watch the same wires from two places at once"
# Three things run concurrently on the board: console.py on /dev/ttyPS1 (what the guest
# says), read_rgb_status.py on /dev/mem (what the PL is driving, as seen by the ARM), and
# the guest itself. The second is the point -- it is an observer with no connection to the
# program under test.
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out console.stamps host_status.out
  nohup python3 -u console.py --seconds $SECONDS_READ --stamps console.stamps > console.out 2>/dev/null &
  CPID=\$!
  echo xilinx | sudo -S nohup python3 -u read_rgb_status.py --watch $SECONDS_READ --interval 0.2 > host_status.out 2>&1 &
  SPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_micrgb.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
  wait \$SPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out"     > "$RUN/console.txt"     2>/dev/null || true
"${SSH[@]}" "cat $PYNQ_DIR/console.stamps"  > "$RUN/console.stamps"  2>/dev/null || true
"${SSH[@]}" "cat $PYNQ_DIR/host_status.out" > "$RUN/host_status.txt" 2>/dev/null || true

if [ -s "$RUN/console.txt" ]; then
  printf '%s\n' "----------------------------------------------------------------"
  cat "$RUN/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
else
  warn "no console output -- check $RUN/boot.log"
fi

step "5/6  and what the board is holding NOW, with the guest idle"
# The guest has finished and returned from main(); the GPIO registers hold their last
# value, so this reads the parked state minutes later if need be. A separate invocation
# from the watcher above, deliberately: if the watcher had died this would still answer.
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 -u read_rgb_status.py" \
  2>/dev/null | grep -v sudo > "$RUN/host_park.txt" || true
cat "$RUN/host_park.txt" | sed 's/^/    /' || true

step "6/6  check"
python3 - "$RUN" "$SAMPLE" "$BOARD" "$STEP_MS" "$CYCLES" "$STEPS_PER_CYCLE" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run, sample, board = sys.argv[1:4]
step_ms, cycles, steps_per_cycle = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])

def read(name):
    p = os.path.join(run, name)
    return open(p, errors='replace').read() if os.path.exists(p) else ''

con  = read('console.txt')
hst  = read('host_status.txt')
park = read('host_park.txt')

# The sample prints its bit patterns MSB-first: [LD5.r LD5.g LD5.b LD4.r LD4.g LD4.b].
def msb6(s):
    return int(s, 2)

steps = [(int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4).strip(),
          msb6(m.group(5)), msb6(m.group(6)), m.group(7))
         for m in re.finditer(
             r'RGB: t=\s*(\d+) ms\s+cycle (\d+) step\s*(\d+)/\s*\d+\s+(.{1,30}?)\s+'
             r'drive=([01]{6}) read=([01]{6}) (ok|MISMATCH)', con)]

m = re.search(r'RGB: quiescent readback ([01]{6}) \(expect 000000\) (ok|MISMATCH)', con)
quiescent_ok = bool(m) and m.group(2) == 'ok'

m = re.search(r'RGB: PARK\s+(.+?)\s+drive=([01]{6}) read=([01]{6}) (ok|MISMATCH)', con)
park_drive = msb6(m.group(2)) if m else None
park_read  = msb6(m.group(3)) if m else None
park_ok    = bool(m) and m.group(4) == 'ok'

m = re.search(r'RGB: readbacks (\d+) ok, (\d+) mismatched', con)
rb_ok  = int(m.group(1)) if m else 0
rb_bad = int(m.group(2)) if m else -1

m = re.search(r'RGB: elapsed (\d+) ms for (\d+) steps of (\d+) ms \(expect (\d+)\)', con)
elapsed_ms, elapsed_want = (int(m.group(1)), int(m.group(4))) if m else (0, 1)

# What the ARM saw, independently.
host_seen = set()
for mm in re.finditer(r'RGB_STATUS t=[\d.]+ status=0x[0-9A-Fa-f]{8} rgb=0b([01]{6})', hst):
    host_seen.add(msb6(mm.group(1)))
m = re.search(r'RGB_STATUS_SAMPLES (\d+)', hst)
host_samples = int(m.group(1)) if m else 0
m = re.search(r'RGB_STATUS status=0x[0-9A-Fa-f]{8} rgb=0b([01]{6}) value=(\d+)', park)
host_park = int(m.group(2)) if m else None

# THE CROSS-CHECK. Every distinct pattern the guest says it drove for a whole step must
# also have been seen by the ARM over GP0. The watcher samples at 200 ms into 1000 ms
# steps, so it cannot miss one unless the signals never got there.
guest_masks = sorted({s[4] for s in steps})
missed = [v for v in guest_masks if v not in host_seen]

out = {
    'board': board, 'sample': os.path.basename(sample),
    'step_ms': step_ms, 'cycles': cycles,
    'booted': 'RGB_LED_WALK starting' in con,
    'done': 'RGB: DONE' in con,
    'controller_ready': 'gpio controller not ready' not in con,
    'steps_logged': len(steps),
    'steps_expected': cycles * steps_per_cycle,
    'readbacks_ok': rb_ok, 'readbacks_bad': rb_bad,
    'quiescent_zero': quiescent_ok,
    'park_drive': park_drive, 'park_read': park_read, 'park_ok': park_ok,
    'guest_distinct_masks': guest_masks,
    'host_samples': host_samples,
    'host_distinct_masks': sorted(host_seen),
    'host_missed_masks': missed,
    'host_saw_every_guest_mask': host_samples > 0 and not missed,
    'host_park': host_park,
    'host_agrees_on_park': (host_park is not None and host_park == park_drive),
    'elapsed_ms': elapsed_ms,
    'timing_ok': elapsed_want > 0 and abs(elapsed_ms - elapsed_want) < 0.10 * elapsed_want,
}

NAMES = ["LD4.blue", "LD4.green", "LD4.red", "LD5.blue", "LD5.green", "LD5.red"]
def pretty(v):
    if v is None:
        return "?"
    lit = ",".join(NAMES[i] for i in range(6) if v & (1 << i)) or "-none-"
    return "0b" + format(v, '06b') + " " + lit

print("  guest: %d steps logged (expected %d), %d readbacks ok / %d bad"
      % (out['steps_logged'], out['steps_expected'], rb_ok, rb_bad))
print("  guest: quiescent readback is zero: %s" % quiescent_ok)
print("  guest: %d ms elapsed for %d steps, expected %d (%s)"
      % (elapsed_ms, out['steps_expected'], elapsed_want,
         "ok" if out['timing_ok'] else "OFF"))
print("  host : %d GP0 samples, %d distinct patterns" % (host_samples, len(host_seen)))
print("  the guest drove these patterns, and the ARM saw each one over GP0:")
for v in guest_masks:
    print("      %-40s  %s" % (pretty(v), "seen by host" if v in host_seen else "*** NOT SEEN ***"))
print("  parked state, guest says : %s" % pretty(park_drive))
print("  parked state, host says  : %s" % pretty(host_park))
print()
print("  LOOK AT THE BOARD. It should be holding LD4 RED and LD5 BLUE right now.")
print("  Nothing above proves the colour -- only that the right six wires carry the right")
print("  six bits. fpga/pynq-z2/docs/RGB_LEDS.md section 6 says exactly what is and is not")
print("  established without a person.")

out['result_pass'] = bool(
    out['booted'] and out['done'] and out['controller_ready']
    and out['steps_logged'] == out['steps_expected']
    and out['readbacks_bad'] == 0 and out['readbacks_ok'] >= out['steps_expected']
    and out['quiescent_zero'] and out['park_ok']
    and out['host_saw_every_guest_mask'] and out['host_agrees_on_park']
    and out['timing_ok'])
json.dump(out, open(os.path.join(run, 'run.json'), 'w'), indent=2)
PY

if [ -n "$EXPECT" ] && [ -f "$EXPECT" ]; then
  python3 - "$RUN/run.json" "$EXPECT" <<'PYCHECK' || die "golden check failed"
import json, sys
got = json.load(open(sys.argv[1]))
exp = json.load(open(sys.argv[2]))
bad = 0
print("\n\033[1;32m==> check  (vs %s)\033[0m" % sys.argv[2].split('/')[-1])
for k, want in exp.items():
    if k.startswith('_'):
        continue
    have = got.get(k)
    if isinstance(want, list) and len(want) == 2 and all(isinstance(v, (int, float)) for v in want) \
       and not isinstance(have, list):
        ok = have is not None and want[0] <= have <= want[1]
        shown = "[%s .. %s]" % tuple(want)
    else:
        ok = (have == want)
        shown = want
    print("    %-4s %-26s expected %-30s got %s" % ("ok" if ok else "BAD", k, shown, have))
    bad += (not ok)
sys.exit(1 if bad else 0)
PYCHECK
  info "reproduces the golden run"
fi

step "Done"
info "console $RUN/console.txt"
info "report  $RUN/report.txt"
warn "the PL now holds the RGB bitstream (MAGIC 0x5A5A0006) and the LEDs are PARKED at"
warn "LD4 RED + LD5 BLUE. LOOK AT THE BOARD -- that is the check no software can do."
warn "The bench has one board: the next lab that runs will overwrite this. Re-park with"
warn "  scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh"
warn "or hand it back to the MBP labs with"
warn "  scripts/with_board.sh ./scripts/29_rocket_pext_run.sh"
