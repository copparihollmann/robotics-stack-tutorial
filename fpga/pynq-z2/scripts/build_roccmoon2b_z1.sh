#!/usr/bin/env bash
# Engine revision 2b on the PYNQ-Z1: 0x5A5A0028 plus the WEIGHT LANE -- the engine's weight half in its
# own clock domain, its Gets out of ChipTop's axi4_wlane_0 onto S_AXI_HP2 at FCLK1 = 100 MHz
# (MEMORY_BANDWIDTH.md sections 9.9 and 9.10).  MAGIC 0x5A5A0013.
#
# THE GATE BEFORE VIVADO is the W-lane gate, rtl_study/wlanetb: the generated revision-2b design --
# mbxr_engine_core, mbxr_whalf, the lane's TileLink-to-AXI chain, mbxr_wquiet and WLaneResetHold --
# against an AXI4 memory standing in for HP2, on two clocks, with fence bit 41 enforced.  It checks
# the AR contract, the abort-drain, the short-reset case (finding (a)), the window case (finding (b)),
# the liveness case, and eleven negative controls.  It runs on the SAME NINE ENGINE FILES Vivado is
# about to read: their md5s are compared against the archived copy the bench builds from, and a
# mismatch stops the build rather than simulating something else.  tb_mbxr (the engine against
# ModelBlaster's reference kernel) is the other half of the RTL gate and runs here too.
#
#   scripts/build_roccmoon2b_z1.sh          full build, through to a bitstream
#   scripts/build_roccmoon2b_z1.sh synth    stop after synthesis
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
STAGE="${1:-all}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"
REPO="$(cd ../.. && pwd)"
R="$(pwd)/rtl_study"

RGB_TABLE="rgb_led[0]:L15 rgb_led[1]:G17 rgb_led[2]:N15 rgb_led[3]:G14 rgb_led[4]:L14 rgb_led[5]:M15"

# The nine files this variant's tcl adds to the Vivado project, in the same order.
ENGINE_FILES="roccmoon/rev2/mbxr_engine.v roccmoon/rev2/mbxr_wx.v roccmoon/rev2/mbxd_dma2.v
              roccmoon/rev2/mbxd_spad2.v roccmoon/rev2/mbxr_st.v
              roccmoon/mbxr_tseq.v roccmoon/mbxr_datapath.v
              rocc/mbxd_dma.v rocc/mbx_mac.v"

run_sim () {
  local name="$1" script="$2"
  echo "=== [$3] $name ==="
  "./sim/$script" "$LOG/${script%.sh}" > "$LOG/${script%.sh}.log" 2>&1 || {
    echo "FAILED: $name"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  grep -q "ALL CHECKS PASSED" "$LOG/${script%.sh}.log" || {
    echo "FAILED: $name did not report a pass"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  echo "  $(grep -c '  pass  ' "$LOG/${script%.sh}.log") checks passed"
}

run_sim "GP0 register file (DRAM self-test)" run_ctrl_sim.sh     "0/7"
run_sim "GP0 register file (Rocket/SoC)"     run_soc_ctrl_sim.sh "0b/7"
run_sim "datapath integration"               run_dram_sim.sh     "0c/7"
run_sim "PDM microphone decimator"           run_pdm_sim.sh      "0d/7"

# The engine and its driver, against ModelBlaster's reference kernel, on the files Vivado is about
# to read (the same gate roccmoonall runs, with revision 2b's files).
echo "=== [0e/7] mbxr_engine + mbxr.c against kernel_linear_s8 (tb_mbxr) ==="
VERILATOR="${VERILATOR:-$(command -v verilator || true)}"
if [ -z "$VERILATOR" ] && [ -n "${CHIPYARD_DIR:-}" ]; then
  VERILATOR="$CHIPYARD_DIR/.conda-env/bin/verilator"
fi
if [ ! -x "$VERILATOR" ]; then
  echo "  SKIPPED: no verilator found (set VERILATOR=...)"
else
  rm -rf "$LOG/vmbxr2b"
  "$VERILATOR" --cc --exe --build -j 8 -O3 -Wno-fatal -DMBXR_BEHAVIOURAL --Mdir "$LOG/vmbxr2b" \
     --top-module mbxr_engine -CFLAGS "-O2 -DMBXR_TB_REV2 -I$(pwd)/sw/roccmoon" \
     "$R/roccmoon/rev2/mbxr_engine.v" "$R/roccmoon/rev2/mbxr_wx.v" "$R/roccmoon/rev2/mbxd_dma2.v" \
     "$R/roccmoon/rev2/mbxd_spad2.v" "$R/roccmoon/rev2/mbxr_st.v" \
     "$R/roccmoon/mbxr_tseq.v" "$R/roccmoon/mbxr_datapath.v" "$R/rocc/mbxd_dma.v" "$R/rocc/mbx_mac.v" \
     "$R/roccmoon/tb_mbxr.cpp" "$R/roccmoon/mbxr_drv_tb.cpp" -o Vtb > "$LOG/tb_mbxr2b.log" 2>&1 || {
    echo "FAILED: could not build tb_mbxr"; tail -20 "$LOG/tb_mbxr2b.log"; exit 1; }
  "$LOG/vmbxr2b/Vtb" --quick > "$LOG/tb_mbxr2b.run" 2>&1 || true
  grep -q "MBXR_TB_OK" "$LOG/tb_mbxr2b.run" || {
    echo "FAILED: tb_mbxr did not pass"; tail -20 "$LOG/tb_mbxr2b.run"; exit 1; }
  grep -E "MBXR_TB_OK|TileLink:" "$LOG/tb_mbxr2b.run" | sed 's/^/  /'
fi

# The W-lane gate, on the same nine files.
echo "=== [0g/7] the W lane on two clocks (rtl_study/wlanetb, fence bit 41 enforced) ==="
# A glob, not `ls`: nothing here depends on the caller's ls flags or aliases.
gate_arcs=("$REPO"/archive/rtl_study/wlanetb/gate_rev2b*)
GATE_ARC=""; [ -d "${gate_arcs[-1]:-}" ] && GATE_ARC="${gate_arcs[-1]}"
if [ -z "$GATE_ARC" ]; then
  echo "FAILED: no archive/rtl_study/wlanetb/gate_rev2b* copy -- the gate needs one elaboration of this config"
  exit 1
fi
gate_rtls=("$GATE_ARC"/rtl_*)
GATE_RTL="${gate_rtls[-1]}/fpga/pynq-z2/rtl_study"
[ -d "$GATE_RTL" ] || { echo "FAILED: $GATE_ARC has no rtl_<commit> copy"; exit 1; }
bad=0
for f in $ENGINE_FILES; do
  a=$(md5sum < "$GATE_RTL/$f" | cut -d' ' -f1)
  b=$(md5sum < "$R/$f" | cut -d' ' -f1)
  if [ "$a" != "$b" ]; then
    echo "  MISMATCH $f: the gate simulated $a, Vivado would read $b"; bad=1
  else
    echo "  ok  $f  $b"
  fi
done
[ "$bad" -eq 0 ] || {
  echo "FAILED: the W-lane gate's RTL copy is not what Vivado would read."
  echo "        Re-elaborate under the chipyard lock and re-run the gate (rtl_study/wlanetb/README.md)."
  exit 1; }
if [ ! -x "$VERILATOR" ]; then
  echo "  SKIPPED: no verilator found (set VERILATOR=...)"
else
  READY_BIT=1 ./rtl_study/wlanetb/run_rev2b.sh > "$LOG/wlanetb_gate.log" 2>&1 || {
    echo "FAILED: the W-lane gate reported unexpected outcomes"; grep -E 'GATE_FAIL|MISSED|unexpected' "$LOG/wlanetb_gate.log" | head -10; exit 1; }
  grep -E '^# unexpected outcomes' "$LOG/wlanetb_gate.log" | sed 's/^/  /'
  awk '!/^#|^name/ && NF {c[$5]++} END {for (k in c) printf "  %-10s %d\n", k, c[k]}' "$LOG/wlanetb_gate.log"
fi

echo "=== [0f/7] MBP RTL selftest on the Verilator model ==="
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
  # It compiles and runs inside the Chipyard tree, so it takes the chipyard lock -- for the 90
  # seconds it needs, not for the 40 minutes of Vivado that follow.
  "$REPO/scripts/lib/with_lock.sh" chipyard "$REPO/scripts/27_pext_rtl_sim.sh" > "$LOG/pext_rtl_sim.log" 2>&1 || {
    echo "FAILED: pext_rtl_selftest"; tail -30 "$LOG/pext_rtl_sim.log"; exit 1; }
  grep -q "PEXT_RTL_SELFTEST: PASS" "$LOG/pext_rtl_sim.log" || {
    echo "FAILED: pext_rtl_selftest did not report a pass"; tail -30 "$LOG/pext_rtl_sim.log"; exit 1; }
  grep -E "^(TOTAL|hart 0|hart 1)" "$LOG/pext_rtl_sim.log" | sed 's/^/  /' || true
fi

. ./scripts/require_vivado.sh

echo "=== [1/1] full-feature Rocket + engine revision 2b + the W lane ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_roccmoon2b.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_roccmoon2b.log" | tail -8

BUILD=build_rocket_micrgb_roccmoon2b_z1

# What the build must have printed about the lane, whatever the stage.
grep -E "^ENGINE_RTL: " "$LOG/z1_rocket_roccmoon2b.log" | sed 's/^/  /'
[ "$(grep -c '^ENGINE_RTL: ' "$LOG/z1_rocket_roccmoon2b.log")" -eq 9 ] || {
  echo "FAILED: the build did not print all nine ENGINE_RTL md5 lines"; exit 1; }
grep -E "^PS7 FCLK1 \(W lane\)|^WLANE_RESET_FREE: " "$LOG/z1_rocket_roccmoon2b.log" | sed 's/^/  /'
grep -q "^WLANE_RESET_FREE: " "$LOG/z1_rocket_roccmoon2b.log" || {
  echo "FAILED: the post-synthesis reset-free check did not run"; exit 1; }

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_roccmoon2b.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_roccmoon2b.log"; exit 1; }
  grep -E "MIC_PIN|RGB_PIN_SYNTH" "$LOG/z1_rocket_roccmoon2b.log" || true
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_roccmoon2b.log" || {
  echo "FAILED: roccmoon2b build"; grep -m3 "^ERROR" "$LOG/z1_rocket_roccmoon2b.log"; exit 1; }

echo "=== [2/2] the six RGB pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }
bad=0
for entry in $RGB_TABLE; do
  port="${entry%%:*}"; want="${entry##*:}"
  line=$(grep -F "RGB_PIN: $port -> " "$LOG/z1_rocket_roccmoon2b.log" | head -1 || true)
  if [ -z "$line" ]; then
    echo "  FAIL  $port: build_rocket.tcl printed no post-route RGB_PIN line"; bad=1; continue
  fi
  got=$(printf '%s\n' "$line" | awk '{print $4}')
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
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$LOG/z1_rocket_roccmoon2b.log" || {
  echo "FAILED: Vivado did not verify all six RGB pins post-route"; exit 1; }
[ "$bad" -eq 0 ] || { echo "FAILED: RGB pin mismatch"; exit 1; }

echo "ROCCMOON2B_BUILD_DONE"
