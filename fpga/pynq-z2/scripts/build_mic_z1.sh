#!/usr/bin/env bash
# Build the dual-core big.LITTLE Rocket + TACIT + MBP P-ext bitstream WITH the on-board
# PDM microphone attached to the periphery bus, for the PYNQ-Z1, at 34.4828 MHz.
#
# This is build_pext_z1.sh plus one peripheral, and it carries build_pext_z1.sh's four
# gates plus a fifth: sim/run_pdm_sim.sh, which checks the decimator's ANSWER -- DC gain,
# tone amplitude, sample period in system clocks, and the rejection of a tone that
# decimation would otherwise fold into the passband. A decimator that is subtly wrong
# still produces plausible-looking audio, and the place that costs you is on the board at
# the end of an hour of Vivado.
#
# NOTE: `vivado -mode batch` exits 0 even when the TCL raised an ERROR, so `set -e` alone
# does not catch a failed build. Each stage is checked for its explicit success marker.
#
#   scripts/build_mic_z1.sh            full build, through to a bitstream
#   scripts/build_mic_z1.sh synth      stop after synthesis (the area gate)
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
STAGE="${1:-all}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"
REPO="$(cd ../.. && pwd)"

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

echo "=== [1/1] dual-core Rocket + TACIT + MBP P-ext + PDM microphone ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_mic.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_mic.log" | tail -8
if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_mic.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_mic.log"; exit 1; }
  echo "SYNTH_DONE"
else
  grep -q "BITSTREAM_OK" "$LOG/z1_rocket_mic.log" || {
    echo "FAILED: mic build"; grep -m3 "^ERROR" "$LOG/z1_rocket_mic.log"; exit 1; }
  grep -E "MIC_PIN|ACHIEVED_FCLK_HZ|TIMING_WNS|TIMING_WHS|BITSTREAM_OK" "$LOG/z1_rocket_mic.log"
  echo "MIC_BUILD_DONE"
fi
