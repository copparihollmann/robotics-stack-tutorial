#!/usr/bin/env bash
# SIMULATION ONLY.  Build the standalone L2 miss-path testbench for one generated L2 config.
#   ./build.sh [lever1|mshr12|cap256|cork|skip|wide]              -> obj_<cfg>/Vl2tb_top     (default lever1)
#   OBJ=$PWD/obj_rackfirst EXTRA=$PWD/rtl_variants/rackfirst/TLCacheCork.sv ./build.sh lever1   (cork what-if)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFGTAG="${1:-lever1}"; shift || true
CY=${CHIPYARD_DIR:?set CHIPYARD_DIR to a Chipyard checkout (see env.sh)}
CONFIG=$("$HERE/gen_top.py" "$CFGTAG" --config)
TOP=$("$HERE/gen_top.py" "$CFGTAG")
# The generated L2 comes from a Chipyard elaboration, or from the bundle this repo vendors
# (scripts/08_gensrc.sh --unpack $CONFIG puts it under out/gensrc).
GENROOT=${L2TB_GENSRC_ROOT:-$CY/sims/verilator/generated-src}
GEN=$GENROOT/chipyard.harness.TestHarness.$CONFIG/gen-collateral
MEMS=$GEN/chipyard.harness.TestHarness.$CONFIG.top.mems.v
ENGINE="$HERE/../rocc/mbxd_dma.v"
V=${VERILATOR:-$(command -v verilator || echo $CY/.conda-env/bin/verilator)}

OBJ="${OBJ:-$HERE/obj_$CFGTAG}"
mkdir -p "$OBJ"
"$V" --cc --exe --build -j 32 \
  -O3 --x-assign fast --x-initial fast --noassert \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
  -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  --top-module l2tb_top --Mdir "$OBJ" \
  -y "$GEN" +libext+.sv+.v \
  "$HERE/rtl/tl_delay.sv" "$TOP" ${EXTRA:-} "$MEMS" "$ENGINE" "$GEN/plusarg_reader.v" \
  "$HERE/csrc/main.cpp" \
  -CFLAGS "-O2 -std=c++17" \
  -o Vl2tb_top "$@"
echo "built $OBJ/Vl2tb_top  ($CONFIG)"
