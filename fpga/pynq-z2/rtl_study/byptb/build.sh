#!/usr/bin/env bash
# SIMULATION ONLY.  Build the bypass memory-bus testbench around the generated RTL.
#   ./build.sh [bypass]            -> obj_bypass/Vbyptb_top
# Assertions are ON (the generated TLMonitors check the lanes' TileLink), unless NOASSERT=1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFGTAG="${1:-bypass}"; shift || true
CY=${CHIPYARD_DIR:?set CHIPYARD_DIR to a Chipyard checkout (see env.sh)}
CONFIG=$("$HERE/gen_top.py" "$CFGTAG" --config)
NCH=$("$HERE/gen_top.py" "$CFGTAG" --nch)
TOP=$("$HERE/gen_top.py" "$CFGTAG")
GENROOT=${BYPTB_GENSRC_ROOT:-$CY/sims/verilator/generated-src}
GEN=$GENROOT/chipyard.harness.TestHarness.$CONFIG/gen-collateral
MEMS=$GEN/chipyard.harness.TestHarness.$CONFIG.top.mems.v
ENGINE="$HERE/../rocc/mbxd_dma.v"
V=${VERILATOR:-$(command -v verilator || echo $CY/.conda-env/bin/verilator)}
OBJ="${OBJ:-$HERE/obj_$CFGTAG}"
ASSERT=--assert; [ "${NOASSERT:-0}" = 1 ] && ASSERT=--noassert
mkdir -p "$OBJ"
"$V" --cc --exe --build -j 32 -O3 --x-assign fast --x-initial fast $ASSERT \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
  -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  +define+PRINTF_COND=0 +define+STOP_COND=1 \
  --top-module byptb_top --Mdir "$OBJ" \
  -y "$GEN" +libext+.sv+.v \
  "$TOP" "$MEMS" "$ENGINE" "$GEN/plusarg_reader.v" \
  "$HERE/csrc/main.cpp" -CFLAGS "-O2 -std=c++17 -DNCH=$NCH" -o Vbyptb_top "$@"
echo "built $OBJ/Vbyptb_top  ($CONFIG)"
