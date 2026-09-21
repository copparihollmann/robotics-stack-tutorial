#!/usr/bin/env bash
# Integration simulation: register file + self-test engine + AXI3 memory.
set -euo pipefail
cd "$(dirname "$0")/.."
# Verilator, in order of preference: an explicit $VERILATOR, then PATH, then the Chipyard
# conda env as a last resort. A hard-coded path into someone else's Chipyard checkout makes
# this unbuildable from a fresh clone -- see docs/REPRODUCING.md.
# `|| true` is load-bearing: under `set -e` a failing command substitution inside the
# assignment aborts the script before the $CHIPYARD_DIR fallback below can run, and
# before the error message -- so on a host without verilator on PATH this exited 1
# with completely empty output.
V="${VERILATOR:-$(command -v verilator 2>/dev/null || true)}"
if [ -z "$V" ] && [ -n "${CHIPYARD_DIR:-}" ] && [ -x "$CHIPYARD_DIR/.conda-env/bin/verilator" ]; then
  V="$CHIPYARD_DIR/.conda-env/bin/verilator"
fi
[ -n "$V" ] && [ -x "$V" ] || { echo "verilator not found: set \$VERILATOR or put it on PATH" >&2; exit 1; }
OUT=${1:-/tmp/dram_sim}
"$V" --binary --timing -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-fatal \
     --Mdir "$OUT" --top-module tb_dramtest \
     sim/tb_dramtest.sv src/axi_ctrl_regs.v src/axi_dram_selftest.v sim/axi3_slave_mem.v
"$OUT/Vtb_dramtest"
