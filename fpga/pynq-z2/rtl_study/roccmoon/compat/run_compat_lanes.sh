#!/usr/bin/env bash
# THE LANE DISPATCHERS ON THE SILICON THREE WORKSTREAMS ARE ACTUALLY RUNNING.
#
#   fpga/pynq-z2/rtl_study/roccmoon/compat/run_compat_lanes.sh
#
# run_compat_tb.sh proves the CURRENT driver still drives a pre-0x5A5A002E engine.  That engine
# has no lanes, so it cannot say anything about mbxr_lanes.h / mbxr_lane_dispatch.h, which issue
# `st` themselves -- and 0x5A5A0029/002A/002B/002C/002D are what the attention, LayerNorm and
# LUT workstreams load.  This runs the current dispatchers against compat/merge_mbxr_engine.v,
# which is that engine frozen.
#
# It uses lut_lane/tb_lutint.cpp because that is the bench which drives a lane THROUGH
# mbxr_lanes INTO mbxr_st -- the integration a lane's own unit bench does not cover, and the
# one 0x5A5A002C hung in.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/.."
SW="$R/../../sw/roccmoon"
B="${TB_BUILD:-$HERE/obj_lanes}"
V="${VERILATOR:-verilator}"
rm -rf "$B"; mkdir -p "$B"
"$V" --cc "$HERE/merge_mbxr_engine.v" "$R/merge/mbxr_lanes.v" \
     "$R/attn_unit/mbxa_unit.v" "$R/attn_unit/mbxa_rq.v" "$R/smx_lane/mbxr_smx.v" \
     "$R/ln_lane/mbxr_ln.v" "$R/lut_lane/mbxl_lut.v" \
     "$HERE/mbxr_st.v" "$R/mbxr_tseq.v" "$R/mbxr_datapath.v" "$R/mbxd_spad2.v" \
     "$R/../rocc/mbxd_dma.v" "$R/../rocc/mbx_mac.v" \
     +define+MBXR_BEHAVIOURAL --top-module mbxr_engine \
     --exe "$R/lut_lane/tb_lutint.cpp" "$R/mbxr_drv_tb.cpp" \
     -Wno-fatal --Mdir "$B" -O2 -CFLAGS "-O2 -DMBXR_TB_REV2 -I$SW" --build -j "${J:-8}" \
     > "$B/build.log" 2>&1 || { echo "FAILED: verilator build"; tail -30 "$B/build.log"; exit 1; }
rc=0
for mode in --lut --lanes; do
  "$B/Vmbxr_engine" $mode > "$B/run$mode.log" 2>&1 || true
  line=$(tail -1 "$B/run$mode.log")
  echo "$mode -> $line"
  case "$line" in MBXR_LUT_OK*|MBXR_LANES_OK*) ;; *) rc=1 ;; esac
done
[ $rc = 0 ] && echo "MBXR_COMPAT_LANES_OK -- the lane dispatchers still drive pre-002E lane silicon" \
            || echo "MBXR_COMPAT_LANES_FAIL -- a lane dispatcher no longer works on 0029..002D"
exit $rc
