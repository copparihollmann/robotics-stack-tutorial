#!/usr/bin/env bash
# The PDM microphone peripheral, checked against a real sigma-delta modulator.
#
# This is a build gate for the same reason the other three are: a decimator that is
# subtly wrong still produces plausible-looking audio, and the place that costs you is
# on the board, at the end of an hour of Vivado.  The testbench checks the ANSWER --
# the DC gain, the tone amplitude, the sample period in system clocks, and the
# rejection of a tone that decimation would otherwise fold into the passband.
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
OUT=${1:-/tmp/pdm_sim}
# -Isrc is for `include "pdm_fir_coeffs.vh"`, the generated coefficient table.
"$V" --binary --timing -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-fatal \
     -Isrc --Mdir "$OUT" --top-module tb_pdm_mic \
     sim/tb_pdm_mic.sv src/pdm_mic_core.v src/pdm_mic_capture.v src/pdm_cic4.v \
     src/pdm_fir_mac.v src/pdm_dcblock.v src/pdm_mic_fifo.v
"$OUT/Vtb_pdm_mic"
