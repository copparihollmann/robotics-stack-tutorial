#!/usr/bin/env bash
# Build the interface-ceiling instrument for the PYNQ-Z1 (MAGIC 0x5A5A0020).
# MEMORY_BANDWIDTH.md section 7.
#
#   fpga/pynq-z2/scripts/build_axiceil_z1.sh                  timed at 142.857 MHz (1000/7)
#   AXICEIL_FCLK_MHZ=200 AXICEIL_TAG=_f200 fpga/pynq-z2/scripts/build_axiceil_z1.sh
#
# Gate: sim/axiceil/run_axiceil_sim.sh must print ALL CHECKS PASSED first.  This bitstream
# writes PS DDR while Linux runs on it, and its register file sits on a GP0 port with no
# bus timeout, so nothing untested goes in.
#
# Vivado runs under scripts/lib/with_lock.sh vivado (a counting lock shared with the SoC
# builds).  `vivado -mode batch` exits 0 on a TCL ERROR, so success is the BITSTREAM_OK
# marker, and a negative WNS fails the build here even though a bitstream was written.
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
REPO="$(cd ../.. && pwd)"
TAG="${AXICEIL_TAG:-}"
LOG="${BUILD_LOG_DIR:-$REPO/out/axiceil/build${TAG}}"
mkdir -p "$LOG"

echo "=== [1/2] the instrument against four impolite HP-port models ==="
sim/axiceil/run_axiceil_sim.sh "$LOG/vsim" > "$LOG/sim.log" 2>&1 || {
  echo "FAILED: simulation"; tail -30 "$LOG/sim.log"; exit 1; }
grep -q "ALL CHECKS PASSED" "$LOG/sim.log" || {
  echo "FAILED: simulation did not pass"; grep "FAIL" "$LOG/sim.log" | head; exit 1; }
echo "  $(grep -c '  pass  ' "$LOG/sim.log") checks passed"

. ./scripts/require_vivado.sh

echo "=== [2/2] Vivado (timed at ${AXICEIL_FCLK_MHZ:-142.857} MHz) ==="
"$REPO/scripts/lib/with_lock.sh" vivado \
  vivado -mode batch -nojournal -nolog -source tcl/build_axiceil.tcl \
  > "$LOG/vivado.log" 2>&1 || true
grep -E "PS7_PRESET|TIMING_W|BITSTREAM_OK" "$LOG/vivado.log" || true
grep -q "BITSTREAM_OK" "$LOG/vivado.log" || {
  echo "FAILED: build"; grep -m5 "^ERROR" "$LOG/vivado.log"; exit 1; }
WNS=$(awk '/^TIMING_WNS:/{print $2}' "$LOG/vivado.log")
awk -v w="$WNS" 'BEGIN{exit !(w >= 0)}' || { echo "FAILED: WNS $WNS < 0 -- does not close at this clock"; exit 1; }
BIT="build_axiceil${TAG}_z1/pynqz1_axiceil.bit"
echo "  $BIT  md5 $(md5sum "$BIT" | cut -d' ' -f1)"
echo "AXICEIL_BUILD_DONE"
