#!/usr/bin/env bash
# The bypass family (MEMORY_BANDWIDTH.md section 8).  One script for every variant in it:
#
#   scripts/build_bwbypass_z1.sh <variant> [synth|all]
#
#   bwbypassl2  MAGIC 0x5A5A0014  lever 3 with channel 1 on S_AXI_HP2 (the OTHER DDR
#                                  controller port), L2 in the path, one clock -- the control
#   bwbypass    MAGIC 0x5A5A0015  the fusion: BwBypass (2 lanes on MBUS, no L2), channels
#                                  on HP0 + HP2, the memory bus on FCLK1 @ 100 MHz
#   bwbypass01  MAGIC 0x5A5A0016  the same SoC with channel 1 on S_AXI_HP1 (HP0 + HP1: one DDR
#                                  controller port)
#   bwbypass4   MAGIC 0x5A5A0017  4 lanes on HP0-HP3 (four channels), memory bus on FCLK1 @ 100 MHz
#
# Everything checked below is what build_bwports_z1.sh checks, because the variants are
# built from the same top level and the same gates apply: the simulation suite, the fill
# engine against its out-of-order memory model, the six RGB pins in the routed design,
# and report_cdc.  Vivado reads build_rocket.tcl with ROCKET_VARIANT set; the variant's
# flags live there and nowhere else.
#
# NOTE: `vivado -mode batch` exits 0 even when the TCL raised an ERROR, so `set -e` alone
# does not catch a failed build. Each stage is checked for its explicit success marker.
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
VARIANT="${1:?usage: build_bwbypass_z1.sh <variant> [synth|all]}"
case "$VARIANT" in
  bwbypassl2|bwbypass|bwbypass01|bwbypass4) ;;
  *) echo "not a bypass-family variant: $VARIANT" >&2; exit 2 ;;
esac
STAGE="${2:-all}"
# A memory-clock build of one variant: ROCKET_FCLK_MEM_MHZ=111.111 ROCKET_BUILD_TAG=f111.  Same
# config and MAGIC, a different md5; build_rocket.tcl appends the tag to the build directory.
TAG="${ROCKET_BUILD_TAG:-}"
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

echo "=== [1/1] $VARIANT${TAG:+ ($TAG)}, FCLK1=${ROCKET_FCLK_MEM_MHZ:-variant default} ($STAGE) ==="
ROCKET_VARIANT="$VARIANT" vivado -mode batch -nojournal -nolog -source tcl/build_rocket.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log" | tail -8

BUILD=build_rocket_micrgb_${VARIANT}${TAG:+_$TAG}_z1

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log"; exit 1; }
  grep -E "MIC_PIN|RGB_PIN_SYNTH" "$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log" || true
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log" || {
  echo "FAILED: $VARIANT build"; grep -m3 "^ERROR" "$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log"; exit 1; }

echo "=== [2/2] the six RGB pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }

bad=0
for entry in $RGB_TABLE; do
  port="${entry%%:*}"; want="${entry##*:}"
  # 1. the line build_rocket.tcl printed from the routed design
  line=$(grep -F "RGB_PIN: $port -> " "$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log" | head -1 || true)
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
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log" || {
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

echo "BWBYPASS_BUILD_DONE $VARIANT${TAG:+ $TAG}"
