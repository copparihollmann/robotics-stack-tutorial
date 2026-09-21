#!/usr/bin/env bash
# SIMULATION ONLY.  The final W-lane gate bench around the GENERATED revision-2b design (MEMORY_BANDWIDTH.md s9.9).
#   BENCH=mm2b ./build_rev2b.sh                   -> obj_mm2b/     the TWO-CLOCK MM bench (s9.14): the real driver
#                                                   (sw/roccmoon/mbxr.c) running dispatches on this DUT, with a
#                                                   TileLink responder on client A and the AXI memory on the lane.
#   ./build_rev2b.sh                               -> obj2b/        monitors on (generated TLMonitors, fatal)
#   NOASSERT=1 ./build_rev2b.sh                    -> obj2b_synth/  SYNTHESIS defined: the logic as Vivado builds it
#   MUTANT=nowindow NOASSERT=1 ./build_rev2b.sh    -> obj2b_nowindow_synth/
#   MUTANT=holdfromquiet NOASSERT=1 ./build_rev2b.sh -> obj2b_holdfromquiet_synth/
#   STOPCOND=0 ./build_rev2b.sh                    -> obj2b_nostop/  monitors report every firing and the run continues
# RTL from archive/rtl_study/wlanetb/gate_rev2b/ (the lock-session copy and the 433898d Verilog), never a shared tree.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTANT=${MUTANT:-none}
if [ -z "${WLANETB2B_ROOT:-}" ]; then
  arcs=("$(cd "$HERE/../../../.." && pwd)"/archive/rtl_study/wlanetb/gate_rev2b*)   # a glob, not `ls`
  ROOT="${arcs[-1]}"
else
  ROOT="$WLANETB2B_ROOT"
fi
CONFIG=$("$HERE/gen_top_rev2b.py" --config)
TOP=$("$HERE/gen_top_rev2b.py" --mutant "$MUTANT")
GEN=$ROOT/gensrc/chipyard.harness.TestHarness.$CONFIG/gen-collateral
rtls=("$ROOT"/rtl_*)
R="${rtls[-1]}/fpga/pynq-z2/rtl_study"
V=${VERILATOR:-verilator}
DMA2=$R/roccmoon/rev2/mbxd_dma2.v; [ "$MUTANT" = nowindow ] && DMA2=$HERE/rtl/gen2b/mbxd_dma2_mut_nowindow.v
HOLD=(); [ "$MUTANT" = holdfromquiet ] && HOLD=("$HERE/rtl/gen2b/WLaneResetHold_mut_holdfromquiet.sv")
SUF=""; [ "$MUTANT" != none ] && SUF="_$MUTANT"
ASSERT=--assert; [ "${NOASSERT:-0}" = 1 ] && { ASSERT="--noassert +define+SYNTHESIS"; SUF="${SUF}_synth"; }
STOPCOND=${STOPCOND:-1}; [ "$STOPCOND" = 0 ] && SUF="${SUF}_nostop"   # STOPCOND=0: monitors print and carry on (diagnosis)
BENCH=${BENCH:-gate}
case "$BENCH" in
  gate) MAIN="$HERE/csrc/main_rev2b.cpp"; BIN=Vwlanetb2b_top; OBJDEF="$HERE/obj2b$SUF" ;;
  mm2b) MAIN="$HERE/csrc/main_mm2b.cpp";  BIN=Vmm2b;          OBJDEF="$HERE/obj_mm2b$SUF" ;;
  *) echo "unknown BENCH $BENCH (gate|mm2b)"; exit 2 ;;
esac
OBJ="${OBJ:-$OBJDEF}"
mkdir -p "$OBJ"
"$V" --cc --exe --build -j 32 -O3 --x-assign fast --x-initial fast $ASSERT \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
  -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  +define+PRINTF_COND=0 +define+STOP_COND=$STOPCOND +define+MBXR_BEHAVIOURAL \
  --top-module wlanetb2b_top --Mdir "$OBJ" \
  -y "$GEN" +libext+.sv+.v \
  "$TOP" "$HERE/rtl/gen2b/wlaneClockSinkDomain_tb.sv" "${HOLD[@]}" "$GEN/plusarg_reader.v" \
  "$R/roccmoon/rev2/mbxr_engine.v" "$R/roccmoon/rev2/mbxr_wx.v" "$DMA2" "$R/roccmoon/rev2/mbxd_spad2.v" \
  "$R/roccmoon/rev2/mbxr_st.v" "$R/roccmoon/mbxr_tseq.v" "$R/roccmoon/mbxr_datapath.v" "$R/rocc/mbxd_dma.v" "$R/rocc/mbx_mac.v" \
  "$MAIN" -CFLAGS "-O2 -std=c++17 -I$(cd "$HERE/../../sw/roccmoon" && pwd) -I$(cd "$HERE/../../sw" && pwd)" -o $BIN
echo "built $OBJ/$BIN  ($CONFIG, bench=$BENCH, mutant=$MUTANT, assert=$ASSERT, verilator $("$V" --version | cut -d' ' -f2))"
