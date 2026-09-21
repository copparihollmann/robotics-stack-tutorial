#!/usr/bin/env bash
# THE 6-BIT WEIGHT GRID, ON THE ENGINE THAT SHIPS (merge/, four lanes).
#
#   fpga/pynq-z2/rtl_study/roccmoon/run_int6_tb.sh
#
# Each shape runs TWICE -- eight bits and six -- over the SAME code matrix, so the pair is the
# measurement and not two runs of two things.  What it asserts:
#
#   * max_abs_err 0 against kernel_linear_s8 over THOSE CODES.  The reference is byte-identical
#     to the engine's input, so this is a real check and not a golden rebuilt from the changed
#     path: it says the packing, the sequencer's phase and the read port's 48-bit select
#     reproduce the arithmetic, not that the arithmetic is good (B75/B77 measured that).
#   * bytes_wgt and fill_beats MOVE.  That is the whole lever, and it is also this lever's
#     signature: the claw-back C's four labs all show fill_beats UNMOVED, so a result here with
#     fill_beats unmoved is not this lever working.
#   * the MAC step count does NOT move.  36 beats at either grid; only the words feeding them
#     change.  If steps move, the arithmetic gate above is comparing different work.
#
# The int8 path's own guard is compat/run_compat_tb.sh, whose numbers are exact and which this
# does not replace.  Run both.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$HERE/../../sw/roccmoon"
B="${TB_BUILD:-$HERE/obj_int6}"
V="${VERILATOR:-verilator}"
rm -rf "$B"; mkdir -p "$B"
"$V" --cc "$HERE/merge/mbxr_engine.v" "$HERE/merge/mbxr_lanes.v" \
     "$HERE/attn_unit/mbxa_unit.v" "$HERE/attn_unit/mbxa_rq.v" "$HERE/smx_lane/mbxr_smx.v" \
     "$HERE/ln_lane/mbxr_ln.v" "$HERE/lut_lane/mbxl_lut.v" \
     "$HERE/mbxr_st.v" "$HERE/mbxr_tseq.v" "$HERE/mbxr_datapath.v" "$HERE/mbxd_spad2.v" \
     "$HERE/../rocc/mbxd_dma.v" "$HERE/../rocc/mbx_mac.v" \
     +define+MBXR_BEHAVIOURAL --top-module mbxr_engine \
     --exe "$HERE/tb_mbxr.cpp" "$HERE/mbxr_drv_tb.cpp" \
     -Wno-fatal --Mdir "$B" -O2 -CFLAGS "-O2 -DMBXR_TB_REV2 -I$SW" --build -j "${J:-8}" \
     > "$B/build.log" 2>&1 || { echo "FAILED: verilator build"; tail -40 "$B/build.log"; exit 1; }

"$B/Vmbxr_engine" --int6 2>&1 | tee "$B/run.log"
grep -q "^MBXR_INT6_OK" "$B/run.log" || { echo "MBXR_INT6_FAIL -- see $B/run.log"; exit 1; }
