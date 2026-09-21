#!/usr/bin/env bash
# SIMULATION ONLY.  PROBE-LEVEL, PRE-REV2B gate for the private weight channel (MEMORY_BANDWIDTH.md s9.9, design (ii')).
# Builds the three testbench variants from the archived copy of the elaboration and runs the matrix:
#   gate      contract (8-beat Gets inside the weight window, no AW/W), abort-drain with R back-pressured, resume
#   negative  controls that must be CAUGHT: RREADY dropped during the drain; a lane that skips waiting for RLAST
#   char      characterisation, no pass/fail expectation: SoC reset length, out-of-window descriptor
# Logs: results/run_<stamp>/ (git-ignored), copied to archive/rtl_study/wlanetb/runs/<stamp>/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
STAMP=$(date +%Y%m%dT%H%M%S)
OUT="$HERE/results/run_$STAMP"; mkdir -p "$OUT"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  ( "$HERE/build.sh" > "$OUT/build_obj.log" 2>&1 ) &
  ( MUTANT=skip_rlast "$HERE/build.sh" > "$OUT/build_skip_rlast.log" 2>&1 ) &
  ( NOASSERT=1 OBJ="$HERE/obj_synth" "$HERE/build.sh" > "$OUT/build_synth.log" 2>&1 ) &
  wait
  for b in obj skip_rlast synth; do tail -1 "$OUT/build_$b.log" | grep -q '^built' || { echo "BUILD FAILED: $b"; exit 2; }; done
fi
SUM="$OUT/SUMMARY.txt"
{ echo "# wlanetb probe-level, pre-rev2b -- $(date -Iseconds)"
  echo "# RTL: $(cat "$REPO/archive/rtl_study/wlanetb/gensrc/PynqZ2RocketBigLittlePextTacitMicRgbBwWLaneProbeConfig.provenance" | head -2 | tr '\n' ' ')"
  echo "# binaries: obj $(md5sum < "$HERE/obj/Vwlanetb_top" | cut -c1-12)  skip_rlast $(md5sum < "$HERE/obj_skip_rlast/Vwlanetb_top" | cut -c1-12)  synth $(md5sum < "$HERE/obj_synth/Vwlanetb_top" | cut -c1-12)"
  printf '%-34s %-7s %-10s %-5s %-10s %s\n' name expect build exit outcome verdicts; } > "$SUM"
n_bad=0
run () {  # run <name> <expect PASS|CAUGHT|INFO> <build obj|skip_rlast|synth> <args...>
  local name=$1 expect=$2 build=$3; shift 3
  local bin="$HERE/obj/Vwlanetb_top"; [ "$build" = obj ] || bin="$HERE/obj_$build/Vwlanetb_top"
  timeout 900 "$bin" "$@" > "$OUT/$name.log" 2>&1; local rc=$?
  local v; v=$(grep -oE 'sweep lat=[0-9]+ out=[0-9]+ .*bpc=[0-9.]+|-> (PASS|FAIL)$|\| (DRAINED|NOT DRAINED:)[^|]*$|RESUME (OK|FAILED)|claim=[A-Za-z]+(\(outstanding=[0-9]+\))?|burst_beat=[^ ]+|Assertion failed[^\\]*|at [A-Za-z]+\.scala:[0-9]+' "$OUT/$name.log" | sed 's/^| //' | tr '\n' ';' | cut -c1-600)
  local outcome=INFO
  case $expect in
    PASS)   { [ $rc -eq 0 ] && grep -q ' -> PASS$' "$OUT/$name.log" && ! grep -q 'NOT DRAINED\|RESUME FAILED\| -> FAIL$' "$OUT/$name.log"; } && outcome=ok || { outcome=UNEXPECTED; n_bad=$((n_bad+1)); } ;;
    CAUGHT) { [ $rc -ne 0 ] && grep -q 'NOT DRAINED\|Assertion failed' "$OUT/$name.log"; } && outcome=CAUGHT || { outcome=MISSED; n_bad=$((n_bad+1)); } ;;
  esac
  printf '%-34s %-7s %-10s %-5s %-10s %s\n' "$name" "$expect" "$build" "$rc" "$outcome" "$v" >> "$SUM"
}
B=4096
# ---- gate: contract and throughput -----------------------------------------------------------------------------
run sweep_lat20_f100            PASS obj   --lat 20 --blocks $B --outs 1,2,4,8 sweep
run sweep_lat60_f100            PASS obj   --lat 60 --blocks $B --outs 1,8 sweep
run sweep_lat20_f125            PASS obj   --lat 20 --blocks $B --outs 8 --p1 8000 sweep
run sweep_lat20_f100_synth      PASS synth --lat 20 --blocks $B --outs 1,8 sweep
# ---- gate: abort (issue gate closed) with R back-pressured, then resume -----------------------------------------
for aa in 257 1024 2049 3001; do for sm in 16 23 37; do
  run abort_gate_a${aa}_s${sm}          PASS obj   --lat 20 --blocks $B --abort gate --abort-after $aa --stall-min $sm abort
done; done
run abort_gate_lat60                    PASS obj   --lat 60 --blocks $B --abort gate abort
run abort_gate_holdafter5000            PASS obj   --lat 20 --blocks $B --abort gate --hold-after 5000 abort
run abort_gate_f125                     PASS obj   --lat 20 --blocks $B --abort gate --p1 8000 abort
run abort_gate_synth                    PASS synth --lat 20 --blocks $B --abort gate abort
# ---- gate: abort by SoC reset held long enough ------------------------------------------------------------------
run abort_reset256_lat20                PASS obj   --lat 20 --blocks $B --abort reset --reset-cycles 256 abort
run abort_reset256_lat60                PASS obj   --lat 60 --blocks $B --abort reset --reset-cycles 256 abort
run abort_reset256_synth                PASS synth --lat 20 --blocks $B --abort reset --reset-cycles 256 abort
# ---- negative controls: must be CAUGHT ----------------------------------------------------------------------------
run neg_rdrop_gate                      CAUGHT obj        --lat 20 --blocks $B --abort gate --rdrop abort
run neg_rdrop_gate_synth                CAUGHT synth      --lat 20 --blocks $B --abort gate --rdrop abort
run neg_rdrop_reset256                  CAUGHT obj        --lat 20 --blocks $B --abort reset --reset-cycles 256 --rdrop abort
for aa in 257 1024 2049 3001; do
  run neg_skip_rlast_gate_a${aa}         CAUGHT skip_rlast --lat 20 --blocks $B --abort gate --abort-after $aa abort
done
run neg_skip_rlast_gate_lat60           CAUGHT skip_rlast --lat 60 --blocks $B --abort gate abort
run ctl_skip_rlast_sweep_is_blind       INFO   skip_rlast --lat 20 --blocks $B --outs 8 sweep
# ---- characterisation: SoC reset shorter than the PS needs to deliver what is outstanding --------------------------
for rc in 1 16 32 48 56 64 96; do
  run char_reset${rc}_lat20              INFO obj   --lat 20 --blocks $B --abort reset --reset-cycles $rc abort
  run char_reset${rc}_lat20_synth        INFO synth --lat 20 --blocks $B --abort reset --reset-cycles $rc abort
done
run char_oow                            INFO obj   --lat 20 oow
run char_oow_synth                      INFO synth --lat 20 oow
echo "# unexpected outcomes: $n_bad" >> "$SUM"
mkdir -p "$REPO/archive/rtl_study/wlanetb/runs"
cp -a "$OUT" "$REPO/archive/rtl_study/wlanetb/runs/$STAMP"
cp -a "$HERE/rtl/gen" "$REPO/archive/rtl_study/wlanetb/runs/$STAMP/rtl_gen"
cat "$SUM"
echo "archived: archive/rtl_study/wlanetb/runs/$STAMP"
exit $n_bad
