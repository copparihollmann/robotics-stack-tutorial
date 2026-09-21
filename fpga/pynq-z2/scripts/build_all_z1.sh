#!/usr/bin/env bash
# Rebuild both bitstreams for the PYNQ-Z1. Sequential: Vivado is CPU-hungry and this
# avoids licence contention.
#
# NOTE: `vivado -mode batch` exits 0 even when the TCL raised an ERROR, so `set -e` alone
# does not catch a failed build. Each stage is checked for its explicit success marker.
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"

# Simulate the GP0 register file first. It takes seconds and needs no Vivado licence,
# and both hardware bugs found during Z1 bring-up (undriven RID, W accepted before AW)
# lived in this module and would have been caught here.
echo "=== [0/3] register-file simulation ==="
./sim/run_ctrl_sim.sh "$LOG/ctrl_sim" > "$LOG/ctrl_sim.log" 2>&1 || {
  echo "FAILED: register-file simulation"; tail -20 "$LOG/ctrl_sim.log"; exit 1; }
grep -q "ALL CHECKS PASSED" "$LOG/ctrl_sim.log" || {
  echo "FAILED: simulation did not report a pass"; tail -20 "$LOG/ctrl_sim.log"; exit 1; }
echo "  $(grep -c '  pass  ' "$LOG/ctrl_sim.log") checks passed"

# soc_ctrl_regs is the register file in the ROCKET bitstreams, and it is a near-copy of
# axi_ctrl_regs above -- same RID and same W-before-AW exposure. It had never been
# simulated at all; tb_soc_ctrl_regs.sv covers it, and also pins the SOC_MAGIC parameter
# that keeps the single-core and dual-core bitstreams distinguishable at 0x4000_0008.
echo "=== [0b/3] SoC register-file simulation ==="
./sim/run_soc_ctrl_sim.sh "$LOG/soc_ctrl_sim" > "$LOG/soc_ctrl_sim.log" 2>&1 || {
  echo "FAILED: SoC register-file simulation"; tail -20 "$LOG/soc_ctrl_sim.log"; exit 1; }
grep -q "ALL CHECKS PASSED" "$LOG/soc_ctrl_sim.log" || {
  echo "FAILED: simulation did not report a pass"; tail -20 "$LOG/soc_ctrl_sim.log"; exit 1; }
echo "  $(grep -c '  pass  ' "$LOG/soc_ctrl_sim.log") checks passed"

echo "=== [0c/3] datapath integration simulation ==="
./sim/run_dram_sim.sh "$LOG/dram_sim" > "$LOG/dram_sim.log" 2>&1 || {
  echo "FAILED: datapath simulation"; tail -20 "$LOG/dram_sim.log"; exit 1; }
grep -q "ALL CHECKS PASSED" "$LOG/dram_sim.log" || {
  echo "FAILED: datapath simulation did not report a pass"; tail -20 "$LOG/dram_sim.log"; exit 1; }
echo "  $(grep -c '  pass  ' "$LOG/dram_sim.log") checks passed"

# Vivado from here on. Check for it once, with an explanation -- see docs/REPRODUCING.md.
. ./scripts/require_vivado.sh          # cwd is fpga/pynq-z2 -- see the cd above

echo "=== [1/3] DRAM self-test ==="
vivado -mode batch -nojournal -nolog -source tcl/build_bitstream.tcl 2>&1 | tee $LOG/z1_dram.log | tail -5
grep -q "BITSTREAM_OK" $LOG/z1_dram.log || { echo "FAILED: dram test"; grep -m3 "^ERROR" $LOG/z1_dram.log; exit 1; }

echo "=== [2/3] Rocket + TACIT ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket.tcl -tclargs all 2>&1 | tee $LOG/z1_rocket.log | tail -5
grep -q "BITSTREAM_OK" $LOG/z1_rocket.log || { echo "FAILED: rocket"; grep -m3 "^ERROR" $LOG/z1_rocket.log; exit 1; }

echo "ALL_BUILDS_DONE"
