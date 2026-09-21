#!/usr/bin/env bash
# SIMULATION ONLY.  Build the two-clock private weight-channel testbench around the generated RTL of
# PynqZ2RocketBigLittlePextTacitMicRgbBwWLaneProbeConfig (MEMORY_BANDWIDTH.md s9.9).  Probe-level, pre-rev2b.
#   ./build.sh                    -> obj/Vwlanetb_top               (the generated RTL, plus the tb_dhold stall input)
#   MUTANT=skip_rlast ./build.sh  -> obj_skip_rlast/Vwlanetb_top    (negative control)
#   NOASSERT=1 OBJ=$PWD/obj_synth ./build.sh                        (monitors compiled out: the logic as synthesised)
# The RTL is read from a COPY of the elaboration (default archive/rtl_study/wlanetb/gensrc; WLANETB_GENSRC_ROOT
# overrides), never from the shared Chipyard tree.  Assertions are ON (the generated TLMonitors check every
# TileLink edge; STOP_COND=1 makes a firing monitor fatal), unless NOASSERT=1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTANT=${MUTANT:-none}
CONFIG=$("$HERE/gen_top.py" --config)
TOP=$("$HERE/gen_top.py" --mutant "$MUTANT")
GENROOT=${WLANETB_GENSRC_ROOT:-$(cd "$HERE/../../../.." && pwd)/archive/rtl_study/wlanetb/gensrc}
GEN=$GENROOT/chipyard.harness.TestHarness.$CONFIG/gen-collateral
MEMS=$GEN/chipyard.harness.TestHarness.$CONFIG.top.mems.v
# mbxd_dma is an external module of the elaboration; the copy taken with it is used, not the live rocc/ file.
ENGINE=$GENROOT/mbxd_dma.v
V=${VERILATOR:-verilator}
EXTRA=()
if [ "$MUTANT" = none ]; then OBJ="${OBJ:-$HERE/obj}"; else OBJ="${OBJ:-$HERE/obj_$MUTANT}"; EXTRA+=("$HERE/rtl/gen/BwBypass_mut_$MUTANT.sv"); fi
# NOASSERT=1 also defines SYNTHESIS: the generated monitors are `ifndef SYNTHESIS` $error/$fatal blocks, not SVA, so
# --noassert alone leaves them live.  With SYNTHESIS the simulated logic is what Vivado builds.
ASSERT=--assert; [ "${NOASSERT:-0}" = 1 ] && ASSERT="--noassert +define+SYNTHESIS"
mkdir -p "$OBJ"
"$V" --cc --exe --build -j 32 -O3 --x-assign fast --x-initial fast $ASSERT \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
  -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  +define+PRINTF_COND=0 +define+STOP_COND=1 \
  --top-module wlanetb_top --Mdir "$OBJ" \
  -y "$GEN" +libext+.sv+.v \
  "$TOP" "$HERE/rtl/gen/wlaneClockSinkDomain_tb.sv" "${EXTRA[@]}" "$MEMS" "$ENGINE" "$GEN/plusarg_reader.v" \
  "$HERE/csrc/main.cpp" -CFLAGS "-O2 -std=c++17" -o Vwlanetb_top
echo "built $OBJ/Vwlanetb_top  ($CONFIG, mutant=$MUTANT, verilator $("$V" --version | cut -d' ' -f2))"
