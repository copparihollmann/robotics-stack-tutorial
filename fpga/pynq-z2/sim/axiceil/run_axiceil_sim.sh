#!/usr/bin/env bash
# Simulate the interface-ceiling instrument (MEMORY_BANDWIDTH.md s7): axiceil_core against
# four impolite HP-port models.  Verilator; no Vivado licence.  Gate for build_axiceil_z1.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
V="${VERILATOR:-$(command -v verilator 2>/dev/null || true)}"
if [ -z "$V" ] && [ -n "${CHIPYARD_DIR:-}" ] && [ -x "$CHIPYARD_DIR/.conda-env/bin/verilator" ]; then
  V="$CHIPYARD_DIR/.conda-env/bin/verilator"
fi
[ -n "$V" ] && [ -x "$V" ] || { echo "verilator not found: set \$VERILATOR or put it on PATH" >&2; exit 1; }
OUT=${1:-/tmp/axiceil_sim}
"$V" --binary --timing -O2 -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
     -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-fatal --Mdir "$OUT" --top-module tb_axiceil \
     sim/axiceil/tb_axiceil.sv sim/axiceil/axi3_hp_model.sv \
     src/axiceil/axiceil_core.v src/axiceil/axiceil_port.v src/axiceil/axiceil_guard.v
"$OUT/Vtb_axiceil"
