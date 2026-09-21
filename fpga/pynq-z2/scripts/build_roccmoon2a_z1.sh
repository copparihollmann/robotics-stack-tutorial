#!/usr/bin/env bash
# Build the full-feature Rocket SoC PLUS engine REVISION 2a as a RoCC on hart 1, for the PYNQ-Z1,
# at 34.4828 MHz.  MAGIC 0x5A5A0012.  ROCC_DECOUPLED.md section 8.15.5.  build_roccmoon_z1.sh with
# the revision-2a RTL in the gate (and its protocol-violation cases, MBXR_TB_REV2).
#
# build_micrgb_z1.sh plus one accelerator and nothing else: same top level, same XDC files,
# same -verilog_define set.  The engine's two TileLink clients attach through a testchipip
# SubsystemInjector and its command path is a RoCC inside hart 1's tile, so there are no pins.
#
# THE GATE BEFORE VIVADO is tb_mbxr: the engine RTL Vivado is about to read, driven by the
# driver hart 1 runs (sw/roccmoon/mbxr.c), against ModelBlaster's kernel_linear_s8 copied
# verbatim, with an adversarial two-client TileLink memory that checks the protocol.  No
# byte of it is allowed to differ.
#
#   scripts/build_roccmoon2a_z1.sh          full build, through to a bitstream
#   scripts/build_roccmoon2a_z1.sh synth    stop after synthesis
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

# The engine and its driver, against ModelBlaster's reference kernel, on the files Vivado is
# about to read.
echo "=== [0e/6] mbxr_engine + mbxr.c against kernel_linear_s8 (tb_mbxr) ==="
VERILATOR="${VERILATOR:-$(command -v verilator || true)}"
if [ -z "$VERILATOR" ] && [ -n "${CHIPYARD_DIR:-}" ]; then
  VERILATOR="$CHIPYARD_DIR/.conda-env/bin/verilator"
fi
if [ ! -x "$VERILATOR" ]; then
  echo "  SKIPPED: no verilator found (set VERILATOR=...)"
else
  R="$(pwd)/rtl_study"
  rm -rf "$LOG/vmbxr"
  "$VERILATOR" --cc --exe --build -j 8 -O3 -Wno-fatal -DMBXR_BEHAVIOURAL --Mdir "$LOG/vmbxr" \
     --top-module mbxr_engine -CFLAGS "-O2 -DMBXR_TB_REV2 -I$(pwd)/sw/roccmoon" \
     "$R/roccmoon/mbxr_engine.v" "$R/roccmoon/mbxr_tseq.v" "$R/roccmoon/mbxr_datapath.v" \
     "$R/roccmoon/mbxr_st.v" "$R/roccmoon/mbxd_spad2.v" "$R/rocc/mbxd_dma.v" "$R/rocc/mbx_mac.v" \
     "$R/roccmoon/tb_mbxr.cpp" "$R/roccmoon/mbxr_drv_tb.cpp" -o Vtb > "$LOG/tb_mbxr.log" 2>&1 || {
    echo "FAILED: could not build tb_mbxr"; tail -20 "$LOG/tb_mbxr.log"; exit 1; }
  "$LOG/vmbxr/Vtb" --quick > "$LOG/tb_mbxr.run" 2>&1 || true
  grep -q "MBXR_TB_OK" "$LOG/tb_mbxr.run" || {
    echo "FAILED: tb_mbxr did not pass"; tail -20 "$LOG/tb_mbxr.run"; exit 1; }
  grep -E "MBXR_TB_OK|TileLink:" "$LOG/tb_mbxr.run" | sed 's/^/  /'
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

echo "=== [1/1] full-feature Rocket + engine revision 2a ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_roccmoon2a.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_roccmoon2a.log" | tail -8

BUILD=build_rocket_micrgb_roccmoon2a_z1

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_roccmoon2a.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_roccmoon2a.log"; exit 1; }
  grep -E "MIC_PIN|RGB_PIN_SYNTH" "$LOG/z1_rocket_roccmoon2a.log" || true
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_roccmoon2a.log" || {
  echo "FAILED: roccmoon build"; grep -m3 "^ERROR" "$LOG/z1_rocket_roccmoon2a.log"; exit 1; }

echo "=== [2/2] the six RGB pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }

bad=0
for entry in $RGB_TABLE; do
  port="${entry%%:*}"; want="${entry##*:}"
  # 1. the line build_rocket.tcl printed from the routed design
  line=$(grep -F "RGB_PIN: $port -> " "$LOG/z1_rocket_roccmoon2a.log" | head -1 || true)
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
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$LOG/z1_rocket_roccmoon2a.log" || {
  echo "FAILED: Vivado did not verify all six RGB pins post-route"; exit 1; }
[ "$bad" -eq 0 ] || { echo "FAILED: RGB pin mismatch"; exit 1; }

echo "ROCCMOON2A_BUILD_DONE"
