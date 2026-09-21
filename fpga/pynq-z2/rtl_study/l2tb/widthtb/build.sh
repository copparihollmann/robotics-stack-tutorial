#!/usr/bin/env bash
# SIMULATION ONLY.  The 0x5A5A0018/0019 memory port (generated mbus coupler + src/axi4_to_axi3.v)
# under a C++ TileLink master and S_AXI_HP0 slave.  See main.cpp.
#   ./build.sh [config]     (default PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipFastConfig)
#   ./obj_<config>/Vwidthtb_top [--blocks N] [--rlat C] [--stall]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../../.." && pwd)"
CONFIG="${1:-PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipFastConfig}"; shift || true
CY=${CHIPYARD_DIR:?set CHIPYARD_DIR to a Chipyard checkout (see env.sh)}
GEN=${WIDTHTB_GENSRC_ROOT:-$REPO/out/gensrc}/chipyard.harness.TestHarness.$CONFIG/gen-collateral
[ -d "$GEN" ] || { echo "no $GEN -- scripts/08_gensrc.sh --unpack $CONFIG" >&2; exit 1; }
# The coupler's TileLink source width follows the L2's outer source count (4 bits at 7 MSHRs,
# 5 at 12), read from the generated port list.
SRC_W=$(awk '/^module TLInterconnectCoupler_mbus_to_memory_controller_port_named_axi4\(/ {f=1}
             f && /auto_tl_in_a_bits_source/ { if (match($0, /\[([0-9]+):0\]/, m)) print m[1]+1; else print 1; exit }' \
        "$GEN/TLInterconnectCoupler_mbus_to_memory_controller_port_named_axi4.sv")
[ -n "$SRC_W" ] || { echo "cannot read the coupler's source width" >&2; exit 1; }
# ... and how many of those sources the L2 may actually use (the widget's TLMonitor bound).
MON=$(grep -o "TLMonitor_[0-9]* monitor" "$GEN/TLWidthWidget16_3.sv" | awk '{print $1}')
SRC_N=$(grep -o "io_in_a_bits_source < [0-9]*'h[0-9a-fA-F]*" "$GEN/$MON.sv" | head -1 | sed "s/.*'h//")
[ -n "$SRC_N" ] || { echo "cannot read the source bound from $MON" >&2; exit 1; }
SRC_N=$((16#$SRC_N))
V=${VERILATOR:-$(command -v verilator || echo $CY/.conda-env/bin/verilator)}
OBJ="${OBJ:-$HERE/obj_$CONFIG}"
mkdir -p "$OBJ"
"$V" --cc --exe --build -j 16 -O2 --x-assign fast --x-initial fast --noassert \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
  -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  --top-module widthtb_top -GSRC_W=$SRC_W --Mdir "$OBJ" -y "$GEN" +libext+.sv+.v \
  "$HERE/tb_top.sv" "$REPO/fpga/pynq-z2/src/axi4_to_axi3.v" "$GEN/plusarg_reader.v" \
  "$HERE/main.cpp" -CFLAGS "-O2 -std=c++17 -DSRC_W=$SRC_W -DSRC_N=$SRC_N" -o Vwidthtb_top "$@" > "$OBJ/build.log" 2>&1 \
  || { tail -30 "$OBJ/build.log"; exit 1; }
echo "built $OBJ/Vwidthtb_top ($CONFIG, TileLink source width $SRC_W, $SRC_N sources)"
