#!/usr/bin/env bash
# SIMULATION ONLY.  THE FINAL W-LANE GATE on the generated revision-2b design (MEMORY_BANDWIDTH.md s9.9).
#   GATE      the generated design as elaborated (P4 at 433898d): contract, abort-drain, resume, findings (a) and (b)
#   NEGATIVE  controls and mutants that must be CAUGHT
#   INFO      characterisation, and a bench-only CANDIDATE FIX (--fix-resethold) that is not the generated design
# Builds: obj2b (monitors on, fatal), obj2b_synth (SYNTHESIS), obj2b_nowindow_synth and obj2b_holdfromquiet_synth
# (mutants), obj2b_nostop (diagnosis).
# READY_BIT=1 drives every run the way mbxr_dev.lane_wait does: fence bit 41 before each weight load (the build gate).
# Logs: results/run2b_<stamp>/, copied to $GATE_ARC/runs/<stamp>/ (GATE_ARC defaults to the newest gate_rev2b* archive).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
STAMP=$(date +%Y%m%dT%H%M%S)
OUT="$HERE/results/run2b_$STAMP"; mkdir -p "$OUT"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  "$HERE/build_rev2b.sh" > "$OUT/build_obj2b.log" 2>&1 || { echo "BUILD FAILED obj2b"; exit 2; }
  NOASSERT=1 "$HERE/build_rev2b.sh" > "$OUT/build_obj2b_synth.log" 2>&1 || { echo "BUILD FAILED synth"; exit 2; }
  MUTANT=nowindow NOASSERT=1 "$HERE/build_rev2b.sh" > "$OUT/build_obj2b_nowindow_synth.log" 2>&1 || { echo "BUILD FAILED nowindow"; exit 2; }
  MUTANT=holdfromquiet NOASSERT=1 "$HERE/build_rev2b.sh" > "$OUT/build_obj2b_holdfromquiet_synth.log" 2>&1 || { echo "BUILD FAILED holdfromquiet"; exit 2; }
  STOPCOND=0 "$HERE/build_rev2b.sh" > "$OUT/build_obj2b_nostop.log" 2>&1 || { echo "BUILD FAILED nostop"; exit 2; }
fi
if [ -z "${GATE_ARC:-}" ]; then arcs=("$REPO"/archive/rtl_study/wlanetb/gate_rev2b*); GATE_ARC="${arcs[-1]}"; fi
export WLANETB2B_ROOT="$GATE_ARC"      # one RTL copy for the generator, the builds and this header
SUM="$OUT/SUMMARY.txt"
{ echo "# wlanetb rev2b gate -- $(date -Iseconds)"
  echo "# RTL: $(head -2 "$GATE_ARC/gensrc/PynqZ2RocketBigLittlePextTacitMicRgbRoccMoon2bCheckConfig.provenance" | tr '\n' ' ')  ready_bit_enforced=${READY_BIT:-0}"
  echo "# RTL copy: $GATE_ARC  wlaneClockSinkDomain.sv md5 $(md5sum < "$GATE_ARC"/gensrc/chipyard.harness.TestHarness.PynqZ2RocketBigLittlePextTacitMicRgbRoccMoon2bCheckConfig/gen-collateral/wlaneClockSinkDomain.sv | cut -c1-12)  RoccMoonEngine2b.sv md5 $(md5sum < "$GATE_ARC"/gensrc/chipyard.harness.TestHarness.PynqZ2RocketBigLittlePextTacitMicRgbRoccMoon2bCheckConfig/gen-collateral/RoccMoonEngine2b.sv | cut -c1-12)"
  echo "# binaries: obj2b $(md5sum < "$HERE/obj2b/Vwlanetb2b_top" | cut -c1-12)  synth $(md5sum < "$HERE/obj2b_synth/Vwlanetb2b_top" | cut -c1-12)  nowindow_synth $(md5sum < "$HERE/obj2b_nowindow_synth/Vwlanetb2b_top" | cut -c1-12)  holdfromquiet_synth $(md5sum < "$HERE/obj2b_holdfromquiet_synth/Vwlanetb2b_top" | cut -c1-12)  nostop $(md5sum < "$HERE/obj2b_nostop/Vwlanetb2b_top" | cut -c1-12)"
  printf '%-40s %-6s %-15s %-4s %-10s %s\n' name expect build exit outcome verdicts; } > "$SUM"
n_unexp=0
run () {  # run <name> <PASS|CAUGHT|INFO> <build> <args...>
  local name=$1 expect=$2 build=$3; shift 3
  local bin="$HERE/$build/Vwlanetb2b_top"
  timeout 1800 "$bin" "$@" ${READY_BIT:+--ready-bit} +verilator+error+limit+100000 > "$OUT/$name.log" 2>&1; local rc=$?
  local v; v=$(grep -oE 'sweep lat=[0-9]+ cap=[0-9]+ .*B_per_lane_cycle=[0-9.]+|window [a-z_]+ .* -> (PASS|FAIL)|at_release: outstanding=[0-9]+|quiet_hold=[a-zA-Z_()/]+|-> (DRAINED, NEXT LOAD EXACT|FAIL:.*)$|quiet_claim_violations=[0-9]+|contract_bad=[0-9]+|lane_reset_outside_soc_reset=[0-9]+|watchdog [A-Z ]+|lane_left_reset_and_load_done=[0-9]|lane_reset_asserted_throughout=[0-9]|at [A-Za-z0-9]+\.scala:[0-9]+' "$OUT/$name.log" | sed 's/window \([a-z_]*\) .* -> /window \1 -> /' | sort -u | tr '\n' ';' | cut -c1-700)
  local outcome=INFO
  case $expect in
    PASS)   { [ $rc -eq 0 ] && grep -q '^WLANETB2B end .* -> PASS$' "$OUT/$name.log"; } && outcome=ok || { outcome=GATE_FAIL; n_unexp=$((n_unexp+1)); } ;;
    CAUGHT) [ $rc -ne 0 ] && outcome=CAUGHT || { outcome=MISSED; n_unexp=$((n_unexp+1)); } ;;
  esac
  printf '%-40s %-6s %-15s %-4s %-10s %s\n' "$name" "$expect" "$build" "$rc" "$outcome" "$v" >> "$SUM"
}
S=obj2b_synth; M=obj2b; N=obj2b_nowindow_synth; H=obj2b_holdfromquiet_synth
# ---- GATE: contract and throughput ----------------------------------------------------------------------------------
run g_sweep_lat20                 PASS $M --lat 20 --caps 1,2,3,4 sweep
run g_sweep_lat20_synth           PASS $S --lat 20 --caps 1,2,3,4 sweep
run g_sweep_lat60                 PASS $M --lat 60 --caps 4 sweep
run g_sweep_lane125               PASS $M --lat 20 --caps 4 --p1 8000 sweep
run g_sweep_29_13_synth           PASS $S --lat 20 --caps 4 --p1 13000 sweep
run g_sweep_29_29_synth           PASS $S --lat 20 --caps 4 --p1 29000 sweep
run g_sweep_10_29_synth           PASS $S --lat 20 --caps 4 --p0 10000 --p1 29000 sweep
# ---- GATE: abort (SoC reset, held long) with Gets outstanding and R back-pressured; drain; resume exact ------------
for lat in 20 60; do for aa in 37 100 301; do
  run g_abort_reset256_lat${lat}_a${aa}      PASS $M --lat $lat --reset-cycles 256 --abort-after $aa abort
done; done
run g_abort_reset256_synth                  PASS $S --lat 20 --reset-cycles 256 abort
run g_abort_reset256_lane125                PASS $M --lat 20 --reset-cycles 256 --p1 8000 abort
run g_abort_reset256_10_29_synth            PASS $S --lat 20 --reset-cycles 256 --p0 10000 --p1 29000 abort
# ---- GATE: finding (b), window --------------------------------------------------------------------------------------
run g_window                                PASS $M window
run g_window_synth                          PASS $S window
run g_window_29_29_synth                    PASS $S --p1 29000 window
# ---- GATE: finding (a), short SoC reset with bursts outstanding, next load at once (as synthesised) ------------------
# lat 120: a PS slow enough that bursts are still outstanding when even a 56-cycle reset is released
for lat in 20 60 120; do for rc in 10 20 32 48 56; do
  run g_a_reset${rc}_lat${lat}_synth         PASS $S --lat $lat --reset-cycles $rc abort
done; done
# --nohold: reset while fresh Gets are still inside the PS latency, so even 56-cycle resets release with bursts due
for rc in 10 32 56; do
  run g_a_reset${rc}_lat120_nohold_synth     PASS $S --lat 120 --reset-cycles $rc --nohold abort
done
# ---- GATE: liveness, an RLAST that never arrives ---------------------------------------------------------------------
run g_stuck_lat60_reset10                   PASS $S --lat 60 --reset-cycles 10 stuck
run g_stuck_lat120_reset56_monitors         PASS $M --lat 120 --reset-cycles 56 stuck
run g_stuck_10_29_synth                     PASS $S --lat 60 --reset-cycles 10 --p0 10000 --p1 29000 stuck
# ---- NEGATIVE CONTROLS and MUTANTS ------------------------------------------------------------------------------------
run n_rdrop_reset256                        CAUGHT $M --lat 20 --reset-cycles 256 --rdrop abort
run n_rdrop_reset256_synth                  CAUGHT $S --lat 20 --reset-cycles 256 --rdrop abort
run n_rfirst_sweep_synth                    CAUGHT $S --lat 20 --caps 4 --rfirst sweep
run n_rfirst_reset256_synth                 CAUGHT $S --lat 60 --reset-cycles 256 --rfirst abort
run n_nowindow_synth                        CAUGHT $N window
run n_noresethold_reset10_lat60_synth       CAUGHT $S --lat 60 --reset-cycles 10 --noresethold abort
run n_noresethold_reset20_lat20_synth       CAUGHT $S --lat 20 --reset-cycles 20 --noresethold abort
run n_noresethold_reset56_lat120_nohold     CAUGHT $S --lat 120 --reset-cycles 56 --nohold --noresethold abort
run n_noresethold_noquiet_reset56_lat120    CAUGHT $S --lat 120 --reset-cycles 56 --nohold --noresethold --noquiet abort
run n_holdfromquiet_sweep_synth             CAUGHT $H --lat 20 --caps 4 sweep
run n_holdfromquiet_abort_synth             CAUGHT $H --lat 60 --reset-cycles 10 abort
# ---- INFO: the layers, and the monitors ------------------------------------------------------------------------------
for rc in 10 20 56; do
  run i_a_reset${rc}_lat60_monitors_nostop   INFO obj2b_nostop --lat 60 --reset-cycles $rc abort
done
run i_noquiet_reset10_lat60_synth           INFO $S --lat 60 --reset-cycles 10 --noquiet abort
run i_noquiet_reset56_lat120_nohold_synth   INFO $S --lat 120 --reset-cycles 56 --nohold --noquiet abort
run i_stuck_noresethold_lat60_synth         INFO $S --lat 60 --reset-cycles 10 --noresethold stuck
echo "# unexpected outcomes (GATE_FAIL or MISSED): $n_unexp" >> "$SUM"
DEST="$GATE_ARC/runs/$STAMP"; mkdir -p "$DEST"
cp -a "$OUT/." "$DEST/"; cp -a "$HERE/rtl/gen2b" "$DEST/rtl_gen2b"
cp -p "$HERE/csrc/main_rev2b.cpp" "$HERE/gen_top_rev2b.py" "$HERE/build_rev2b.sh" "$HERE/run_rev2b.sh" "$DEST/"
cat "$SUM"
echo "archived: ${GATE_ARC#$REPO/}/runs/$STAMP"
exit $n_unexp
