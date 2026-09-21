#!/usr/bin/env bash
# Replay the board's first transfer (build 1 on 2026-09-16: HP0 write, 16-beat bursts, 8
# outstanding) against a strict HP-port model, on three RTLs.  Verilator; no board.
#
#   build 1 (4ab15e4)  the bitstream that was running when S_AXI_HP0 wedged
#   build 2 (942902a)  built, never run on the board
#   current            the RTL of the next build
#
# The model counts W beats that reach the port before their AW has been accepted, and can
# (orphan_early) refuse ever to answer such a burst and (cap_lag) keep a write counted against
# its issuing capability for N cycles after its B.  Those are models of hypotheses about the
# AFI, not of the silicon.  What this script establishes:
#   * build 1 sends no early W beat, at any lag tried, and finishes: this replay does NOT
#     reproduce the board's hang, so its cause is not established by simulation;
#   * build 2 does send early W beats (its AW and W slices decouple the two channels);
#   * the current RTL sends none, finishes, and leaves the port holding nothing.
set -euo pipefail
cd "$(dirname "$0")/../.."
V="${VERILATOR:-$(command -v verilator 2>/dev/null || true)}"
[ -n "$V" ] && [ -x "$V" ] || { echo "verilator not found: set \$VERILATOR" >&2; exit 1; }
OUT=${1:-/tmp/axiceil_repro}
FLAGS=(--binary --timing -O2 -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL
       -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-fatal --top-module tb_axiceil_repro)
build () {   # <tag> <git rev or "cur">
  local d="$OUT/$1"; mkdir -p "$d"
  for f in axiceil_core.v axiceil_port.v axiceil_guard.v; do
    if [ "$2" = cur ]; then cp "src/axiceil/$f" "$d/$f"; else git show "$2:fpga/pynq-z2/src/axiceil/$f" > "$d/$f"; fi
  done
  "$V" "${FLAGS[@]}" --Mdir "$d/obj" sim/axiceil/tb_axiceil_repro.sv sim/axiceil/axi3_hp_model.sv \
       "$d/axiceil_core.v" "$d/axiceil_port.v" "$d/axiceil_guard.v" > "$d/build.log" 2>&1
}
build b1 4ab15e4; build b2 942902a; build cur cur
fail=0
for lag in 0 16 64; do
  b1=$("$OUT/b1/obj/Vtb_axiceil_repro" +lag=$lag | grep '^REPRO')
  b2=$("$OUT/b2/obj/Vtb_axiceil_repro" +lag=$lag | grep '^REPRO')
  cu=$("$OUT/cur/obj/Vtb_axiceil_repro" +lag=$lag | grep '^REPRO')
  echo "build 1: $b1"; echo "build 2: $b2"; echo "current: $cu"
  echo "$b1" | grep -q 'early_w=0 finished=1' || { echo "  build 1 changed behaviour"; fail=1; }
  echo "$cu" | grep -q 'early_w=0 finished=1 abort_drained=1 port_holds_writes=0 b_beats=4096 model_errors=0' \
    || { echo "  current RTL did not finish cleanly"; fail=1; }
  [ "$lag" = 0 ] && { echo "$b2" | grep -q 'early_w=[1-9]' || { echo "  expected build 2 to send early W"; fail=1; }; }
done
[ "$fail" -eq 0 ] && echo "REPRO CHECKS PASSED" || { echo "REPRO CHECKS FAILED"; exit 1; }
