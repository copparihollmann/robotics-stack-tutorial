#!/usr/bin/env bash
# LEVER 4.  Build the full-feature Rocket SoC + the TileLink bandwidth instrument on a
# 128-BIT SYSTEM BUS, everything else as lever 1: one HP port, one clock at 34.4828 MHz.
# MAGIC 0x5A5A000A.
#
# WHY.  MEMORY_BANDWIDTH.md section 3.5 measured the L2-hit path at EXACTLY 8.00 B/cycle --
# one 64-bit TileLink beat per cycle -- so on that path the constraint is the sbus beat.
# A 128-bit sbus is the lever aimed at exactly that number.  Section 5 has the prediction,
# written before this was built.
#
# What differs from build_bw_z1.sh: only the generated Verilog.
# PynqZ2Configs.scala's WithWideSystemBus(128) widens the sbus and pins the two things a
# wider sbus would otherwise change behind the experiment's back -- both harts' L1 rowBits
# (back to 64) and the L2's MSHR count (held at 7).  The memory bus, ExtMem and S_AXI_HP0
# stay 64-bit: the L2 is the width adapter.  src/pynqz2_rocket_top.v, the XDC list and the
# -verilog_define set are the `bw` variant's, byte for byte.
#
# ONE MORE GATE THAN LEVER 1.  mbxd_dma.v is unmodified, and BwProbe.scala runs it at
# LGBEATS = 2 with its addresses in 2-byte units.  rtl_study/rocc/tb_mbxd_wide.sv checks
# that arithmetic against an out-of-order 128-bit responder before any Vivado runs.
#
# The CDC gate is kept although this variant has one clock: TraceSinkDMA's crossing is an
# AsynchronousCrossing whose width just changed, and the gate costs a report.
#
# NOTE: `vivado -mode batch` exits 0 even when the TCL raised an ERROR, so `set -e` alone
# does not catch a failed build. Each stage is checked for its explicit success marker.
#
#   scripts/build_bwwide_z1.sh            full build, through to a bitstream
#   scripts/build_bwwide_z1.sh synth      stop after synthesis (the area gate)
#   BWWIDE_BITS=256 scripts/build_bwwide_z1.sh   the 256-bit point (0x5A5A000F), section 5.7
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
STAGE="${1:-all}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"
REPO="$(cd ../.. && pwd)"
case "${BWWIDE_BITS:-128}" in
  128) VAR=bwwide;    BB=16 ;;
  256) VAR=bwwide256; BB=32 ;;
  *) echo "BWWIDE_BITS must be 128 or 256"; exit 2 ;;
esac

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

run_sim "GP0 register file (DRAM self-test)" run_ctrl_sim.sh     "0/6"
run_sim "GP0 register file (Rocket/SoC)"     run_soc_ctrl_sim.sh "0b/6"
run_sim "datapath integration"               run_dram_sim.sh     "0c/6"
run_sim "PDM microphone decimator"           run_pdm_sim.sh      "0d/6"

# The fill engine's own self-check, on the file Vivado is about to read.  It is the same
# rule the arithmetic blocks already follow (ROCC_STUDY.md 3.1): no block goes into a
# bitstream until it has been checked, and the responder in tb_mbxd.sv returns beats out
# of order on purpose because an engine that assumed in-order completion would pass a
# polite model and fail the L2.
echo "=== [0e/6] the fill engine, against an out-of-order memory model ==="
VERILATOR="${VERILATOR:-$(command -v verilator || true)}"
if [ -z "$VERILATOR" ] && [ -n "${CHIPYARD_DIR:-}" ]; then
  VERILATOR="$CHIPYARD_DIR/.conda-env/bin/verilator"
fi
if [ ! -x "$VERILATOR" ]; then
  echo "  SKIPPED: no verilator found (set VERILATOR=...)"
else
  rm -rf "$LOG/vmbxd"
  "$VERILATOR" --binary -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --Mdir "$LOG/vmbxd" \
     --top-module tb_mbxd rtl_study/rocc/tb_mbxd.sv rtl_study/rocc/mbxd_dma.v \
     rtl_study/rocc/mbxd_st.v > "$LOG/tb_mbxd.log" 2>&1 || {
    echo "FAILED: could not build tb_mbxd"; tail -20 "$LOG/tb_mbxd.log"; exit 1; }
  "$LOG/vmbxd/Vtb_mbxd" > "$LOG/tb_mbxd.run" 2>&1 || true
  grep -q "MBXD_TB_OK" "$LOG/tb_mbxd.run" || {
    echo "FAILED: tb_mbxd did not pass"; tail -20 "$LOG/tb_mbxd.run"; exit 1; }
  sed -n 's/^/  /p' "$LOG/tb_mbxd.run" | grep -E "MBXD" || true
fi

# ... and the same engine at THIS bitstream's parameters, wrapped as BwProbe.scala wraps it
# on a 128-bit bus: LGBEATS = 2, addresses shifted by one, each wide beat folded for the
# checksum.  A wrong shift would read the wrong blocks and still report a bytes-per-cycle.
echo "=== [0e2/6] the fill engine on a ${BWWIDE_BITS:-128}-bit bus, as BwProbe wraps it ==="
if [ ! -x "$VERILATOR" ]; then
  echo "  SKIPPED: no verilator found (set VERILATOR=...)"
else
  rm -rf "$LOG/vmbxdw"
  "$VERILATOR" --binary -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --Mdir "$LOG/vmbxdw" \
     --top-module tb_mbxd_wide -GBB=$BB rtl_study/rocc/tb_mbxd_wide.sv \
     rtl_study/rocc/mbxd_dma.v > "$LOG/tb_mbxd_wide.log" 2>&1 || {
    echo "FAILED: could not build tb_mbxd_wide"; tail -20 "$LOG/tb_mbxd_wide.log"; exit 1; }
  "$LOG/vmbxdw/Vtb_mbxd_wide" > "$LOG/tb_mbxd_wide.run" 2>&1 || true
  grep -q "MBXD_WIDE_TB_OK" "$LOG/tb_mbxd_wide.run" || {
    echo "FAILED: tb_mbxd_wide did not pass"; tail -20 "$LOG/tb_mbxd_wide.run"; exit 1; }
  grep -E "MBXD_WIDE" "$LOG/tb_mbxd_wide.run" | sed 's/^/  /' || true
fi

echo "=== [0f/6] MBP RTL selftest on the Verilator model ==="
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

. ./scripts/require_vivado.sh

echo "=== [1/1] full-feature Rocket + instrument, ${BWWIDE_BITS:-128}-bit system bus ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_$VAR.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_$VAR.log" | tail -8

BUILD=build_rocket_micrgb_${VAR}_z1

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_$VAR.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_$VAR.log"; exit 1; }
  grep -E "MIC_PIN|RGB_PIN_SYNTH" "$LOG/z1_rocket_$VAR.log" || true
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_$VAR.log" || {
  echo "FAILED: bwwide build"; grep -m3 "^ERROR" "$LOG/z1_rocket_$VAR.log"; exit 1; }

echo "=== [2/2] the six RGB pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }

bad=0
for entry in $RGB_TABLE; do
  port="${entry%%:*}"; want="${entry##*:}"
  # 1. the line build_rocket.tcl printed from the routed design
  line=$(grep -F "RGB_PIN: $port -> " "$LOG/z1_rocket_$VAR.log" | head -1 || true)
  if [ -z "$line" ]; then
    echo "  FAIL  $port: build_rocket.tcl printed no post-route RGB_PIN line"; bad=1; continue
  fi
  got=$(printf '%s\n' "$line" | awk '{print $4}')
  # 2. report_io, written from the placement, parsed without Vivado.  `index`, not a
  #    regex: the port name contains [ and ], and `$0 ~ p` quietly matches rgb_led0.
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
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$LOG/z1_rocket_$VAR.log" || {
  echo "FAILED: Vivado did not verify all six RGB pins post-route"; exit 1; }
[ "$bad" -eq 0 ] || { echo "FAILED: RGB pin mismatch"; exit 1; }

# ---- the CDC gate.  With two asynchronous clocks declared unrelated, an unsynchronised
# crossing is no longer a timing failure -- it is a silent one.  report_cdc is where it
# shows up, and CDC-1 ("unsynchronised crossing") is the severity that matters.
echo "=== [3/3] clock-domain crossings ==="
CDC="$BUILD/reports/cdc.rpt"
if [ -f "$CDC" ]; then
  # report_cdc's summary table is "Severity  Source Clock  Destination Clock ... Safe
  # Unsafe Unknown", one row per clock pair.  Sum the Unsafe and Unknown columns rather
  # than grepping for a severity string that is not in the file.
  read -r unsafe unknown <<EOF
$(awk '/^(Critical|Warning|Info) +/ {u+=$(NF-2); k+=$(NF-1)} END {print u+0, k+0}' "$CDC")
EOF
  echo "  report_cdc: $unsafe unsafe endpoint(s), $unknown unknown"
  awk '/^(Critical|Warning|Info) +/ {print "    " $0}' "$CDC"
  if [ "${unsafe:-0}" -gt 0 ] || [ "${unknown:-0}" -gt 0 ]; then
    echo "FAILED: unsafe or unknown clock-domain crossings -- run report_cdc -details"
    echo "        on $BUILD/post_route.dcp and look at the CDC-1 rows."
    exit 1
  fi
else
  echo "  (no cdc.rpt -- build_rocket.tcl did not write one)"
fi

echo "BWWIDE_BUILD_DONE"
