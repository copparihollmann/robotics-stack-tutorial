#!/usr/bin/env bash
# SIMULATION ONLY.  Build the two-clock system-bus + memory-bus testbench around the generated RTL of
# PynqZ2RocketBigLittlePextTacitMicRgbBwWinConfig (MEMORY_BANDWIDTH.md section 9).
#   ./build.sh            -> obj/Vwintb_top
# Assertions are ON (the generated TLMonitors check every TileLink edge inside both buses), unless NOASSERT=1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CY=${CHIPYARD_DIR:?set CHIPYARD_DIR to a Chipyard checkout (see env.sh)}
CONFIG=$("$HERE/gen_top.py" --config)
TOP=$("$HERE/gen_top.py")
GENROOT=${WINTB_GENSRC_ROOT:-$CY/sims/verilator/generated-src}
GEN=$GENROOT/chipyard.harness.TestHarness.$CONFIG/gen-collateral
MEMS=$GEN/chipyard.harness.TestHarness.$CONFIG.top.mems.v
ENGINE="$HERE/../rocc/mbxd_dma.v"
V=${VERILATOR:-$(command -v verilator || echo $CY/.conda-env/bin/verilator)}
OBJ="${OBJ:-$HERE/obj}"
ASSERT=--assert; [ "${NOASSERT:-0}" = 1 ] && ASSERT=--noassert
mkdir -p "$OBJ"
"$V" --cc --exe --build -j 32 -O3 --x-assign fast --x-initial fast $ASSERT \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
  -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  +define+PRINTF_COND=0 +define+STOP_COND=1 \
  --top-module wintb_top --Mdir "$OBJ" \
  -y "$GEN" +libext+.sv+.v \
  "$TOP" "$MEMS" "$ENGINE" "$GEN/plusarg_reader.v" \
  "$HERE/csrc/main.cpp" -CFLAGS "-O2 -std=c++17" -o Vwintb_top "$@"
echo "built $OBJ/Vwintb_top  ($CONFIG)"
