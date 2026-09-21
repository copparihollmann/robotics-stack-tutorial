#!/usr/bin/env bash
# Build 0x5A5A0029: the full-feature Rocket SoC with engine revision 2a, the big core's
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
# rather than a missing table row -- two board sessions have been lost to that.  0x5A5A002A is
# run_rocket_lanesdev2.py; 0x5A5A0029 (archived) is run_rocket_lanesdev.py.
#
#   scripts/build_lanesdev_z1.sh          full build, through to a bitstream
#   scripts/build_lanesdev_z1.sh synth    stop after synthesis
#   ROCKET_FCLK_MHZ=30 scripts/build_lanesdev_z1.sh    the same at a lower clock
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
STAGE="${1:-all}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"
REPO="$(cd ../.. && pwd)"

# no RGB LEDs and no PDM microphone in this config, and no P-extension: the RGB pin
# check and the MBP RTL selftest below are skipped, which is most of why this build is
# quicker.  The engine DRC gate and the merged-engine tb_mbxr gate both still run.

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

echo "=== [0f/6] MBP RTL selftest -- SKIPPED: this config has no P-extension ==="
  echo "  (6 m 38 s of a 21-minute build; see LAYERNORM_LANE.md section 20)"

. ./scripts/require_vivado.sh

echo "=== [1/1] Rocket + engine revision 2a + the two lanes ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_lanesdev.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_lanesdev.log" | tail -8

BUILD=build_rocket_micrgb_lanesdev_z1
grep -E "^ENGINE_RTL:|^ENGINE_RTL_SRC" "$LOG/z1_rocket_lanesdev.log" || true

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_lanesdev.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_lanesdev.log"; exit 1; }
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_lanesdev.log" || {
  echo "FAILED: lanesdev build"; grep -m3 "^ERROR" "$LOG/z1_rocket_lanesdev.log"; exit 1; }

echo "LANESDEV_BUILD_DONE"
