#!/usr/bin/env bash
# LEVER 3.  Build the full-feature Rocket SoC + the TileLink bandwidth instrument with TWO
# memory channels: ChipTop's axi4_mem_0 and axi4_mem_1, each through its own
# axi4_to_axi3 shim into S_AXI_HP0 and S_AXI_HP1, everything at 34.4828 MHz.
# MAGIC 0x5A5A0009.
#
# WHY.  Lever 2 (0x5A5A0008) tripled the memory-path clock and moved DRAM bandwidth by
# -1%, and MEMORY_BANDWIDTH.md section 3.5 attributes the DRAM cap to the L2's miss
# handling, which sits IN FRONT of the memory channels.  If that is right a second HP port
# changes nothing.  This bitstream is the test of that attribution.  Built on lever 1 and
# not on lever 2, so the comparison isolates ports at one clock.
#
# THE CDC GATE STAYS even though this variant has one clock: it costs a report and it
# would catch a second channel wired to the wrong clock.
#
# What differs from build_bw_z1.sh: WithNMemoryChannels(2) in the generated Verilog, the
# PYNQZ2_NMEM2 block in src/pynqz2_rocket_top.v (a textual duplicate of channel 0's wires,
# shim, address fold and HP port -- the other builds keep byte-identical RTL), and
# PCW_USE_S_AXI_HP1 in the PS7.  HP ports need no package pins and no XDC.  The notes
# below were written for lever 1's build and still apply to everything else.
#
# This is build_micrgb_z1.sh plus one peripheral and NOTHING ELSE: same top level, same
# XDC files, same -verilog_define set, same two harts, same microphone, same RGB LEDs,
# same 64 KB inclusive L2, same AXI4-to-AXI3 shim.  The instrument attaches through a
# testchipip SubsystemInjector and has no pins, so src/pynqz2_rocket_top.v is textually
# unchanged and `u_soc` keeps its hierarchy path.
#
# WHY THAT MATTERS MORE THAN USUAL HERE.  The number this bitstream exists to produce is
# a bytes-per-cycle figure that will be compared with MEMORY_HIERARCHY.md's 1.34, measured
# on a different bitstream.  Any other difference between the two designs would be a
# confound.  There is one difference, and it is the thing being measured.
#
# The RGB pin gate is carried over verbatim: this build has the same six package balls and
# the same reason nobody can see them.
#
# NOTE: `vivado -mode batch` exits 0 even when the TCL raised an ERROR, so `set -e` alone
# does not catch a failed build. Each stage is checked for its explicit success marker.
#
#   scripts/build_bwports_z1.sh            full build, through to a bitstream
#   scripts/build_bwports_z1.sh synth      stop after synthesis (the area gate)
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
STAGE="${1:-all}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"
REPO="$(cd ../.. && pwd)"

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

echo "=== [1/1] full-feature Rocket + instrument, two memory channels ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_bwports.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_bwports.log" | tail -8

BUILD=build_rocket_micrgb_bwports_z1

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_bwports.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_bwports.log"; exit 1; }
  grep -E "MIC_PIN|RGB_PIN_SYNTH" "$LOG/z1_rocket_bwports.log" || true
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_bwports.log" || {
  echo "FAILED: bwports build"; grep -m3 "^ERROR" "$LOG/z1_rocket_bwports.log"; exit 1; }

echo "=== [2/2] the six RGB pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }

bad=0
for entry in $RGB_TABLE; do
  port="${entry%%:*}"; want="${entry##*:}"
  # 1. the line build_rocket.tcl printed from the routed design
  line=$(grep -F "RGB_PIN: $port -> " "$LOG/z1_rocket_bwports.log" | head -1 || true)
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
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$LOG/z1_rocket_bwports.log" || {
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

echo "BWPORTS_BUILD_DONE"
