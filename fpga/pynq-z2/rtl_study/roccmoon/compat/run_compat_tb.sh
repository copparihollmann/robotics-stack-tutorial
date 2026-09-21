#!/usr/bin/env bash
# THE GUARD THAT COST FOUR BOARD RUNS TO LEARN THE NEED FOR.
#
#   fpga/pynq-z2/rtl_study/roccmoon/compat/run_compat_tb.sh
#
# Runs sw/roccmoon/mbxr.c -- the CURRENT driver, whatever it is now -- against compat/, which is
# the engine 0x5A5A0028 and every pre-0x5A5A002E bitstream actually carry.  A runtime and a
# bitstream have an ABI in `st`'s rs2 and neither can check the other at runtime: a mismatch is
# MBXR_E_TIMEOUT from the first dispatch, with no error bit and nothing on the console.  This
# turns that into a failing script.
#
# THE EXPECTED NUMBERS ARE EXACT, not a range: the flat drain on old silicon must be the same
# machine it always was, to the Get, the Put and the cycle.  If they move, the flat path has
# changed behaviour on hardware that is already in the field.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/.."
SW="$R/../../sw/roccmoon"
B="${TB_BUILD:-$HERE/obj_dir}"
V="${VERILATOR:-verilator}"
BLESS=0; [ "${1:-}" = "--bless" ] && BLESS=1
exp () { sed -nE "s/^$1\t([0-9]+)$/\1/p" "$HERE/EXPECTED.tsv"; }

rm -rf "$B"; mkdir -p "$B"
"$V" --cc "$HERE/mbxr_engine.v" "$HERE/mbxr_st.v" "$R/mbxr_tseq.v" "$R/mbxr_datapath.v" \
     "$R/mbxd_spad2.v" "$R/../rocc/mbxd_dma.v" "$R/../rocc/mbx_mac.v" \
     +define+MBXR_BEHAVIOURAL --top-module mbxr_engine \
     --exe "$R/tb_mbxr.cpp" "$R/mbxr_drv_tb.cpp" \
     -Wno-fatal --Mdir "$B" -O2 \
     -CFLAGS "-O2 -DMBXR_TB_REV2 -DMBXR_TB_FLAT_ENGINE -I$SW" --build -j "${J:-8}" \
     > "$B/build.log" 2>&1 || { echo "FAILED: verilator build"; tail -30 "$B/build.log"; exit 1; }

"$B/Vmbxr_engine" --quick > "$B/run.log" 2>&1 || true
tail -2 "$B/run.log"
read -r gets puts cyc < <(sed -nE 's/^TileLink: ([0-9]+) Gets, ([0-9]+) Puts, [0-9]+ protocol errors, ([0-9]+) cycles.*/\1 \2 \3/p' "$B/run.log")
cases=$(sed -nE 's/^MBXR_TB_OK ([0-9]+) cases.*/\1/p' "$B/run.log")
rc=0
grep -q "^MBXR_TB_OK" "$B/run.log" || {
  echo "MBXR_COMPAT_FAIL: THE CURRENT DRIVER DOES NOT WORK ON A PRE-0x5A5A002E ENGINE."
  echo "  That is what four board runs looked like on 2026-09-18: image_bytes 98,304,"
  echo "  calls_engine 0, last_rc -4, on two boards, for three workstreams.  Do not take a"
  echo "  board until this passes."; exit 1; }
if [ "$BLESS" = 1 ]; then
  { sed -n '1,/^cases/!d;/^#/p' "$HERE/EXPECTED.tsv"
    printf 'cases\t%s\ngets\t%s\nputs\t%s\ncycles\t%s\n' "$cases" "$gets" "$puts" "$cyc"; } > "$HERE/EXPECTED.tsv.new"
  mv "$HERE/EXPECTED.tsv.new" "$HERE/EXPECTED.tsv"
  echo "MBXR_COMPAT_BLESSED $cases cases, $gets Gets, $puts Puts, $cyc cycles"; exit 0
fi
for n in cases gets puts cycles; do
  case $n in cases) got=$cases;; gets) got=$gets;; puts) got=$puts;; cycles) got=$cyc;; esac
  want=$(exp $n)
  [ "${got:-}" = "$want" ] || {
    echo "MBXR_COMPAT_FAIL: $n = ${got:-<none>}, EXPECTED.tsv says $want."
    echo "  The flat drain's behaviour on pre-002E silicon moved.  If you added a tb_mbxr case"
    echo "  that is expected -- re-bless with:  $0 --bless  -- and name the case in the commit."
    rc=1; }
done
[ $rc = 0 ] && echo "MBXR_COMPAT_OK $cases cases, $gets Gets, $puts Puts, $cyc cycles -- the flat drain on pre-002E silicon is unchanged"
exit $rc
