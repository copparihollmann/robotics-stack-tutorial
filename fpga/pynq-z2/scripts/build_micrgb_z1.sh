#!/usr/bin/env bash
# Build the dual-core big.LITTLE Rocket + TACIT + MBP P-ext + PDM microphone bitstream WITH
# the board's two RGB LEDs (LD4, LD5) reachable from software, for the PYNQ-Z1, at
# 34.4828 MHz.
#
# This is build_mic_z1.sh plus six package balls and one stock Chipyard peripheral: a
# sifive GPIO controller at 0x1001_0000 whose six pins are LD4{B,G,R} and LD5{B,G,R}.
#
# IT CARRIES ONE GATE THE OTHERS DO NOT, and it is the reason this script exists rather
# than a flag on build_mic_z1.sh.  NOBODY INVOLVED CAN SEE THE BOARD.  There is no readback
# path for an output pin, so "red is red" cannot be self-checked; what CAN be checked, and
# is, is that each of the six ports landed on the ball the vendor sources say it should.
# build_rocket.tcl asserts that against the ROUTED design (get_package_pins -of_objects,
# which the placer answers, not the XDC parser) and prints an RGB_PIN: line per port; this
# script then re-checks those six lines against its OWN copy of the table, and re-checks
# them a third time out of reports/post_route_io.rpt, which is written from the placement
# and can be read without Vivado.  Three statements of the same six facts; any disagreement
# is a loud error rather than a bitstream that lights the wrong LED.
#
# NOTE: `vivado -mode batch` exits 0 even when the TCL raised an ERROR, so `set -e` alone
# does not catch a failed build. Each stage is checked for its explicit success marker.
#
#   scripts/build_micrgb_z1.sh            full build, through to a bitstream
#   scripts/build_micrgb_z1.sh synth      stop after synthesis (the area gate)
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
STAGE="${1:-all}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"
REPO="$(cd ../.. && pwd)"

# The mapping, stated independently of tcl/build_rocket.tcl and of src/pynqz2_rgb.xdc.
# Source: Digilent digilent-xdc/Arty-Z7-20-Master.xdc (schematic net names Sch=LED4_B ..
# Sch=LED5_R) and Xilinx PYNQ's RGBLED class read against PYNQ's own Pynq-Z1 base.xdc.
# Both are quoted in full in src/pynqz2_rgb.xdc and docs/RGB_LEDS.md section 1.
RGB_TABLE="rgb_led[0]:L15 rgb_led[1]:G17 rgb_led[2]:N15 rgb_led[3]:G14 rgb_led[4]:L14 rgb_led[5]:M15"

run_sim () {
  local name="$1" script="$2"
  echo "=== [$3] $name ==="
  "./sim/$script" "$LOG/${script%.sh}" > "$LOG/${script%.sh}.log" 2>&1 || {
    echo "FAILED: $name"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  grep -q "ALL CHECKS PASSED" "$LOG/${script%.sh}.log" || {
    echo "FAILED: $name did not report a pass"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  echo "  $(grep -c '  pass  ' "$LOG/${script%.sh}.log") checks passed"
}

run_sim "GP0 register file (DRAM self-test)" run_ctrl_sim.sh     "0/5"
run_sim "GP0 register file (Rocket/SoC)"     run_soc_ctrl_sim.sh "0b/5"
run_sim "datapath integration"               run_dram_sim.sh     "0c/5"
run_sim "PDM microphone decimator"           run_pdm_sim.sh      "0d/5"

echo "=== [0e/5] MBP RTL selftest on the Verilator model ==="
if [ "${PEXT_SKIP_RTL_SIM:-0}" = 1 ]; then
  echo "  WAIVED by PEXT_SKIP_RTL_SIM=1: this build has NOT had its MBP gate run, and the log"
  echo "  says so on purpose.  Only the board's own exactness checks stand behind sw/pext.h here."
elif [ -z "${CHIPYARD_DIR:-}" ]; then
  echo "FAILED: the MBP RTL selftest needs CHIPYARD_DIR -- it compiles the TestHarness, which a"
  echo "        gensrc bundle deliberately does not carry.  This is NOT a reason to skip: set"
  echo "        CHIPYARD_DIR as well as CHIPYARD_GENSRC (the bundle still wins for the Verilog"
  echo "        Vivado reads, build_rocket.tcl 647).  To build without the gate, and have the log"
  echo "        record that a gate did not run, set PEXT_SKIP_RTL_SIM=1 explicitly."
  exit 1
else
  "$REPO/scripts/27_pext_rtl_sim.sh" > "$LOG/pext_rtl_sim.log" 2>&1 || {
    echo "FAILED: pext_rtl_selftest"; tail -30 "$LOG/pext_rtl_sim.log"; exit 1; }
  grep -q "PEXT_RTL_SELFTEST: PASS" "$LOG/pext_rtl_sim.log" || {
    echo "FAILED: pext_rtl_selftest did not report a pass"; tail -30 "$LOG/pext_rtl_sim.log"; exit 1; }
  grep -E "^(TOTAL|hart 0|hart 1)" "$LOG/pext_rtl_sim.log" | sed 's/^/  /' || true
fi

# Vivado from here on. Check for it once, with an explanation -- see docs/REPRODUCING.md.
. ./scripts/require_vivado.sh          # cwd is fpga/pynq-z2 -- see the cd above

echo "=== [1/1] dual-core Rocket + TACIT + MBP P-ext + microphone + RGB LEDs ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_micrgb.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_micrgb.log" | tail -8

BUILD=build_rocket_micrgb_z1

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_micrgb.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_micrgb.log"; exit 1; }
  grep -E "MIC_PIN|RGB_PIN_SYNTH" "$LOG/z1_rocket_micrgb.log" || true
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_micrgb.log" || {
  echo "FAILED: micrgb build"; grep -m3 "^ERROR" "$LOG/z1_rocket_micrgb.log"; exit 1; }

# ---- the pin gate, re-checked here rather than trusted ---------------------------------
echo "=== [2/2] the six RGB pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }

bad=0
for entry in $RGB_TABLE; do
  port="${entry%%:*}"; want="${entry##*:}"
  # 1. the line build_rocket.tcl printed from the routed design
  line=$(grep -F "RGB_PIN: $port -> " "$LOG/z1_rocket_micrgb.log" | head -1 || true)
  if [ -z "$line" ]; then
    echo "  FAIL  $port: build_rocket.tcl printed no post-route RGB_PIN line"; bad=1; continue
  fi
  got=$(printf '%s\n' "$line" | awk '{print $4}')
  # 2. report_io, written from the placement, parsed without Vivado
  rpt=$(awk -v p="$port" 'index($0, p) { print }' "$IO_RPT" | head -1 || true)
  if [ -z "$rpt" ]; then
    echo "  FAIL  $port: not present in $IO_RPT"; bad=1; continue
  fi
  if ! printf '%s\n' "$rpt" | grep -qE "(^|[^A-Za-z0-9])$want([^A-Za-z0-9]|$)"; then
    echo "  FAIL  $port: $IO_RPT does not put it on $want:"; echo "        $rpt"; bad=1; continue
  fi
  if [ "$got" != "$want" ]; then
    echo "  FAIL  $port: routed design says $got, this script's table says $want"; bad=1; continue
  fi
  echo "  ok    $port -> $want   (routed design, and $IO_RPT agrees)"
done
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$LOG/z1_rocket_micrgb.log" || {
  echo "  FAIL  build_rocket.tcl did not reach its own post-route pin gate"; bad=1; }
[ "$bad" -eq 0 ] || {
  echo "RGB PIN CHECK FAILED -- do not program this bitstream."; exit 1; }

echo
grep -E "MIC_PIN|RGB_PIN_SYNTH|RGB_PIN:|ACHIEVED_FCLK_HZ|TIMING_WNS|TIMING_WHS|BITSTREAM_OK" \
  "$LOG/z1_rocket_micrgb.log"
echo "MICRGB_BUILD_DONE"
