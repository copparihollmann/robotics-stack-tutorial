#!/usr/bin/env bash
# The LUT lane's Verilator gate.  T4_LANES.md s5 states what this evidence covers: functional
# cycles only -- Verilator has no timing delays, so nothing here licenses a claim about
# silicon.  Timing is tcl/ooc_lut.tcl's business and area is its own.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="${TB_BUILD:-$HERE/obj_dir}"
VERILATOR="${VERILATOR:-verilator}"
RTL="${RTL:-$HERE/mbxl_lut.v}"
rm -rf "$B"; mkdir -p "$B"
"$VERILATOR" --lint-only -Wall "$RTL" --top-module mbxl_lut > "$B/lint.log" 2>&1 || {
  echo "FAILED: verilator lint"; cat "$B/lint.log"; exit 1; }
"$VERILATOR" --cc "$RTL" --top-module mbxl_lut --exe "$HERE/tb_lut.cpp" \
  --Mdir "$B" -O2 -CFLAGS "-O2" --build -j 4 > "$B/build.log" 2>&1 || {
  echo "FAILED: verilator build"; tail -40 "$B/build.log"; exit 1; }
"$B/Vmbxl_lut"
