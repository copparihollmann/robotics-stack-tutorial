#!/usr/bin/env bash
# The LN path of merge/mbxr_lanes.v, end to end: the engine's real mbxd_spad2 in, the streamer,
# mbxr_ln, the packer, and the drain words mbxr_st would swallow.  This is the half no other
# suite reaches (LAYERNORM_LANE.md s16.5, s17).
#
#   rtl_study/roccmoon/ln_lane/run_glue.sh            full
#   rtl_study/roccmoon/ln_lane/run_glue.sh --quick
#
# Expect a final line beginning LNG_TB_OK.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
R="$here/../.."
B="${LNG_BUILD:-${TMPDIR:-/tmp}/ln_glue}"
V="${VERILATOR:-verilator}"
mkdir -p "$B"
"$V" --cc --exe --build -j 12 -O3 -Wno-fatal --Mdir "$B/obj" --top-module mbxr_ln_glue \
  -CFLAGS "-O2" \
  "$here/mbxr_ln_glue.v" "$R/roccmoon/merge/mbxr_lanes.v" \
  "$R/roccmoon/attn_unit/mbxa_unit.v" "$R/roccmoon/attn_unit/mbxa_rq.v" \
  "$R/roccmoon/smx_lane/mbxr_smx.v" "$here/mbxr_ln.v" \
  "$R/roccmoon/lut_lane/mbxl_lut.v" \
  "$R/roccmoon/mbxr_datapath.v" "$R/roccmoon/mbxd_spad2.v" \
  "$here/tb_lnglue.cpp" -o Vtb > "$B/build.log" 2>&1 || {
    echo "FAILED: build"; tail -25 "$B/build.log"; exit 1; }
"$B/obj/Vtb" "$@"
