#!/usr/bin/env bash
# Build the dual-core big.LITTLE Rocket + TACIT bitstream for the PYNQ-Z1.
#
# Gated on the Verilator testbenches first. They take seconds, need no Vivado licence, and
# exist because three real hardware bugs reached the board through RTL that had never been
# simulated -- one of them locked the CPU hard enough to need a physical power cycle.
#
# NOTE: `vivado -mode batch` exits 0 even when the TCL raised an ERROR, so `set -e` alone
# does not catch a failed build. Each stage is checked for its explicit success marker.
#
#   scripts/build_smp_z1.sh            full build, through to a bitstream
#   scripts/build_smp_z1.sh synth      stop after synthesis (the area gate)
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
STAGE="${1:-all}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"

run_sim () {
  local name="$1" script="$2"
  echo "=== [$3] $name ==="
  "./sim/$script" "$LOG/${script%.sh}" > "$LOG/${script%.sh}.log" 2>&1 || {
    echo "FAILED: $name"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  grep -q "ALL CHECKS PASSED" "$LOG/${script%.sh}.log" || {
    echo "FAILED: $name did not report a pass"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  echo "  $(grep -c '  pass  ' "$LOG/${script%.sh}.log") checks passed"
}

run_sim "GP0 register file (DRAM self-test)" run_ctrl_sim.sh     "0/3"
run_sim "GP0 register file (Rocket/SoC)"     run_soc_ctrl_sim.sh "0b/3"
run_sim "datapath integration"               run_dram_sim.sh     "0c/3"

# Vivado from here on. Check for it once, with an explanation -- see docs/REPRODUCING.md.
. ./scripts/require_vivado.sh          # cwd is fpga/pynq-z2 -- see the cd above

echo "=== [1/1] dual-core Rocket + TACIT ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_smp.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_smp.log" | tail -8
if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_smp.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_smp.log"; exit 1; }
  echo "SYNTH_DONE"
else
  grep -q "BITSTREAM_OK" "$LOG/z1_rocket_smp.log" || {
    echo "FAILED: dual-core build"; grep -m3 "^ERROR" "$LOG/z1_rocket_smp.log"; exit 1; }
  grep -E "TIMING_WNS|TIMING_WHS|BITSTREAM_OK" "$LOG/z1_rocket_smp.log"
  echo "SMP_BUILD_DONE"
fi
