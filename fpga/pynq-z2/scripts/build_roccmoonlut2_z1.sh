#!/usr/bin/env bash
# Build 0x5A5A002D: 0x5A5A002C's SoC -- the full-feature Rocket with engine revision 2a and
# THREE lanes -- with ONE GATE CHANGED in mbxl_lut.v: out_valid is a one-cycle pulse per word
# instead of a held valid.  Lab B37 arm A hung the LUT lane on its first silicon dispatch
# because mbxr_st has no ready and pushes on every cycle in_valid is high, so a held valid
# pushed the same word once per cycle until the FIFO overflowed and almost_full never cleared
# again (T4_LANES.md s11, commit 506c4c8).
#
# A NEW MAGIC RATHER THAN A SECOND BUILD OF 002C, for one reason: another workstream is
# running 0x5A5A002C md5 fc26e76d right now and its md5 gate pins that file.  Overwriting it
# would break a live measurement.  This is the case the registry's "two builds of one config
# share a MAGIC" rule permits and the concurrency does not.
#
# THE NEW GATE IN THIS BUILD is tb_lutint on the merged engine: the LUT lane through
# mbxr_lanes into mbxr_st, which is the integration that was covered by nothing and is where
# the fault lived.  lut_lane/run_tb.sh covered the lane against a MODEL of the sink.
#
# (from build_roccmoonlanes_z1.sh) the full-feature Rocket SoC with engine revision 2a, the big core's
# pipelined multiplier and 0092's skipped clean Release -- that is 0x5A5A0028 exactly -- PLUS
# the two lanes merged into the engine (rtl_study/roccmoon/merge/).  PYNQ-Z1, 34.4828 MHz.
# fpga/pynq-z2/docs/LAYERNORM_LANE.md s13.
#
# It is build_roccmoonall_z1.sh with one change: the engine RTL the gate runs on, and the RTL
# Vivado reads, come from rtl_study/roccmoon/merge/ and the two lane directories.  The
# elaborated SoC is 0028's (the BlackBox port list does not change), so the same gensrc
# bundle, top level, XDC and -verilog_define set are used.
#
# THE GATE BEFORE VIVADO is tb_mbxr on the MERGED engine.  With the lanes idle the engine must
# still be byte for byte ModelBlaster's kernel_linear_s8: that is what proves the merge has
# not disturbed the engine, and it is the only automated check this build has on the merge.
# The lanes themselves are verified in attn_unit/ and ln_lane/; mbxr_lanes.v's streamer and
# arbitration are verified by neither, and MAGIC_REGISTRY.md says so.
#
# BEFORE A BOARD SESSION: host/run_rocket_roccmoon.py's EXPECT_BY_RUNNER table must carry this
# build's MAGIC under the runner name you will invoke, and the symlink must exist.  A missing
# entry is refused AFTER the MAGIC is read correctly, so the failure looks like a bad bitstream
# rather than a missing table row -- two board sessions have been lost to that.  0x5A5A002D is
# run_rocket_roccmoonlut2.py, a symlink to run_rocket_roccmoon.py; both land with this script.
#
#   scripts/build_roccmoonlut2_z1.sh          full build, through to a bitstream
#   scripts/build_roccmoonlut2_z1.sh synth    stop after synthesis
#   ROCKET_FCLK_MHZ=30 scripts/build_roccmoonlut2_z1.sh    the same at a lower clock
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

echo "=== [0e/6] the MERGED engine + mbxr.c against kernel_linear_s8 (tb_mbxr) ==="
VERILATOR="${VERILATOR:-$(command -v verilator || true)}"
if [ -z "$VERILATOR" ] && [ -n "${CHIPYARD_DIR:-}" ]; then
  VERILATOR="$CHIPYARD_DIR/.conda-env/bin/verilator"
fi
if [ ! -x "$VERILATOR" ]; then
  echo "FAILED: no verilator found (set VERILATOR=...).  This build's ONLY automated check on"
  echo "        the merge is this gate, so it is not skippable."
  exit 1
fi
R="$(pwd)/rtl_study"
rm -rf "$LOG/vmbxr_lanes"
"$VERILATOR" --cc --exe --build -j 8 -O3 -Wno-fatal -DMBXR_BEHAVIOURAL --Mdir "$LOG/vmbxr_lanes" \
   --top-module mbxr_engine -CFLAGS "-O2 -DMBXR_TB_REV2 -I$(pwd)/sw/roccmoon" \
   "$R/roccmoon/merge/mbxr_engine.v" "$R/roccmoon/merge/mbxr_lanes.v" \
   "$R/roccmoon/attn_unit/mbxa_unit.v" "$R/roccmoon/attn_unit/mbxa_rq.v" \
   "$R/roccmoon/smx_lane/mbxr_smx.v" "$R/roccmoon/ln_lane/mbxr_ln.v" \
   "$R/roccmoon/lut_lane/mbxl_lut.v" \
   "$R/roccmoon/mbxr_tseq.v" "$R/roccmoon/mbxr_datapath.v" \
   "$R/roccmoon/mbxr_st.v" "$R/roccmoon/mbxd_spad2.v" "$R/rocc/mbxd_dma.v" "$R/rocc/mbx_mac.v" \
   "$R/roccmoon/tb_mbxr.cpp" "$R/roccmoon/mbxr_drv_tb.cpp" -o Vtb > "$LOG/tb_mbxr_lanes.log" 2>&1 || {
  echo "FAILED: could not build tb_mbxr on the merged RTL"; tail -20 "$LOG/tb_mbxr_lanes.log"; exit 1; }
"$LOG/vmbxr_lanes/Vtb" --quick > "$LOG/tb_mbxr_lanes.run" 2>&1 || true
grep -q "MBXR_TB_OK" "$LOG/tb_mbxr_lanes.run" || {
  echo "FAILED: tb_mbxr did not pass on the merged RTL"; tail -20 "$LOG/tb_mbxr_lanes.run"; exit 1; }
grep -E "MBXR_TB_OK|TileLink:" "$LOG/tb_mbxr_lanes.run" | sed 's/^/  /'

# THE LANE DISPATCH PATH, which until now no gate exercised.  tb_mbxr --quick runs the engine
# with the lanes IDLE; this runs the lanes, through sw/roccmoon/mbxr_lanes.h -- the same driver
# header the board runs -- against the reference this op is defined by.  It exists because three
# board loads found three faults in that path at one fault per load: a partial-block tile that
# hangs, an affine index that produces a plausible wrong answer, and a fence that read instead of
# waiting.  Each is a case here now.
echo "=== [0e1/6] the LANE dispatch path (tb_mbxr --lanes) ==="
"$LOG/vmbxr_lanes/Vtb" --lanes > "$LOG/tb_lanes.run" 2>&1 || true
grep -q "MBXR_LANES_OK" "$LOG/tb_lanes.run" || {
  echo "FAILED: the lane dispatch cases did not pass"; tail -25 "$LOG/tb_lanes.run"; exit 1; }
grep -E "MBXR_LANES_OK|fault [0-9]" "$LOG/tb_lanes.run" | sed 's/^/  /'

# THE GATE THIS BUILD EXISTS FOR.  tb_mbxr --lanes drives lanes 2 and 3; nothing drove lane 4
# through mbxr_st until arm A hung on silicon.  This is that case, and it is not skippable.
# It now also carries the REFACTOR'S gate: the same dispatches issued through the shared path
# in sw/roccmoon/mbxr_lane_dispatch.h must be BYTE-IDENTICAL to the hand-written sequence, and
# the precondition matrix must refuse every case by name.  A refactor that also fixes things
# cannot be bisected, so byte-identity is the condition it lands under.
echo "=== [0e1b/6] the LUT LANE through the merged engine and mbxr_st (tb_lutint) ==="
rm -rf "$LOG/vlutint"
"$VERILATOR" --cc --exe --build -j 8 -O3 -Wno-fatal -DMBXR_BEHAVIOURAL --Mdir "$LOG/vlutint" \
   --top-module mbxr_engine -CFLAGS "-O2 -DMBXR_TB_REV2 -I$(pwd)/sw/roccmoon" \
   "$R/roccmoon/merge/mbxr_engine.v" "$R/roccmoon/merge/mbxr_lanes.v" \
   "$R/roccmoon/attn_unit/mbxa_unit.v" "$R/roccmoon/attn_unit/mbxa_rq.v" \
   "$R/roccmoon/smx_lane/mbxr_smx.v" "$R/roccmoon/ln_lane/mbxr_ln.v" \
   "$R/roccmoon/lut_lane/mbxl_lut.v" \
   "$R/roccmoon/mbxr_tseq.v" "$R/roccmoon/mbxr_datapath.v" \
   "$R/roccmoon/mbxr_st.v" "$R/roccmoon/mbxd_spad2.v" "$R/rocc/mbxd_dma.v" "$R/rocc/mbx_mac.v" \
   "$R/roccmoon/lut_lane/tb_lutint.cpp" "$R/roccmoon/mbxr_drv_tb.cpp" -o Vtb \
   > "$LOG/tb_lutint.log" 2>&1 || {
  echo "FAILED: could not build tb_lutint"; tail -20 "$LOG/tb_lutint.log"; exit 1; }
"$LOG/vlutint/Vtb" --lut > "$LOG/tb_lutint.run" 2>&1 || true
grep -q "MBXR_LUT_OK" "$LOG/tb_lutint.run" || {
  echo "FAILED: the LUT lane did not pass through the merged engine"; tail -25 "$LOG/tb_lutint.run"; exit 1; }
grep -E "MBXR_LUT_OK|^LUT words|^PRECOND|^SHARED" "$LOG/tb_lutint.run" | sed 's/^/  /'

echo "=== [0e2/6] synthesis DRC on the merged engine (multiple-driver nets) ==="
. ./scripts/require_vivado.sh
vivado -mode batch -nojournal -nolog -source tcl/drc_lanes_engine.tcl > "$LOG/engine_drc.log" 2>&1 || true
if grep -q "ENGINE_DRC_CLEAN" "$LOG/engine_drc.log"; then
  echo "  ENGINE_DRC_CLEAN (no multiple-driver nets)"
else
  echo "FAILED: the merged engine does not pass opt_design's DRC out of context."
  grep -E "ENGINE_DRC_FAILED|MDRV|has multiple drivers|^ERROR" "$LOG/engine_drc.log" | head -10
  echo "  A Verilator suite cannot find this class: it merges same-clock multiple drivers."
  exit 1
fi

echo "=== [0f/6] MBP RTL selftest on the Verilator model ==="
if [ "${PEXT_SKIP_RTL_SIM:-0}" = 1 ]; then
  echo "  WAIVED by PEXT_SKIP_RTL_SIM=1: this build has NOT had its MBP gate run, and the log"
  echo "  says so on purpose."
elif [ -z "${CHIPYARD_DIR:-}" ]; then
  echo "FAILED: the MBP RTL selftest needs CHIPYARD_DIR.  To build without the gate, and have"
  echo "        the log record that a gate did not run, set PEXT_SKIP_RTL_SIM=1 explicitly."
  exit 1
else
  "$REPO/scripts/27_pext_rtl_sim.sh" > "$LOG/pext_rtl_sim.log" 2>&1 || {
    echo "FAILED: pext_rtl_selftest"; tail -30 "$LOG/pext_rtl_sim.log"; exit 1; }
  grep -q "PEXT_RTL_SELFTEST: PASS" "$LOG/pext_rtl_sim.log" || {
    echo "FAILED: pext_rtl_selftest did not report a pass"; tail -30 "$LOG/pext_rtl_sim.log"; exit 1; }
  grep -E "^(TOTAL|hart 0|hart 1)" "$LOG/pext_rtl_sim.log" | sed 's/^/  /' || true
fi

. ./scripts/require_vivado.sh

echo "=== [1/1] Rocket + engine revision 2a + the two lanes ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_roccmoonlut2.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_roccmoonlut2.log" | tail -8

BUILD=build_rocket_micrgb_roccmoonlut2_z1
grep -E "^ENGINE_RTL:|^ENGINE_RTL_SRC" "$LOG/z1_rocket_roccmoonlut2.log" || true

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_roccmoonlut2.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_roccmoonlut2.log"; exit 1; }
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_roccmoonlut2.log" || {
  echo "FAILED: roccmoonlut2 build"; grep -m3 "^ERROR" "$LOG/z1_rocket_roccmoonlut2.log"; exit 1; }

echo "=== [2/2] the six RGB pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }
bad=0
for entry in $RGB_TABLE; do
  port="${entry%%:*}"; want="${entry##*:}"
  line=$(grep -F "RGB_PIN: $port -> " "$LOG/z1_rocket_roccmoonlut2.log" | head -1 || true)
  if [ -z "$line" ]; then
    echo "  FAIL  $port: build_rocket.tcl printed no post-route RGB_PIN line"; bad=1; continue
  fi
  got=$(printf '%s\n' "$line" | awk '{print $4}')
  rpt=$(awk -v p="$port" 'index($0, p) { print }' "$IO_RPT" | head -1 || true)
  if [ -z "$rpt" ]; then echo "  FAIL  $port: not present in $IO_RPT"; bad=1; continue; fi
  if ! printf '%s\n' "$rpt" | grep -qE "(^|[^A-Za-z0-9])$want([^A-Za-z0-9]|$)"; then
    echo "  FAIL  $port: $IO_RPT does not put it on $want:"; echo "        $rpt"; bad=1; continue
  fi
  if [ "$got" != "$want" ]; then
    echo "  FAIL  $port: routed design says $got, this script's table says $want"; bad=1; continue
  fi
  echo "  ok    $port -> $want   (routed design, and $IO_RPT agrees)"
done
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$LOG/z1_rocket_roccmoonlut2.log" || {
  echo "FAILED: Vivado did not verify all six RGB pins post-route"; exit 1; }
[ "$bad" -eq 0 ] || { echo "FAILED: RGB pin mismatch"; exit 1; }

echo "ROCCMOONLUT2_BUILD_DONE"
