#!/usr/bin/env bash
# Simulate soc_ctrl_regs -- the GP0 register file in the Rocket bitstreams.
#
# tb_ctrl_regs.sv covers axi_ctrl_regs (the DRAM self-test's register file). This covers
# the other one, which had never been simulated at all despite being a near-copy carrying
# the same two hardware bugs' worth of risk. Verilator, so it needs no Vivado licence and
# runs in seconds.
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
OUT=${1:-/tmp/soc_ctrl_sim}
"$V" --binary --timing -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-fatal \
     --Mdir "$OUT" --top-module tb_soc_ctrl_regs sim/tb_soc_ctrl_regs.sv src/soc_ctrl_regs.v
"$OUT/Vtb_soc_ctrl_regs"
