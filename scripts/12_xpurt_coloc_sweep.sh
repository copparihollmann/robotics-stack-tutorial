#!/usr/bin/env bash
# Lab A4 -- TWO NETWORKS ON TWO HARTS, SCHEDULED: the co-located Moonshine +
# SignDetLite plan, with SignDetLite PERIODIC at T = 1000 ms (1.00 fps, 4
# declared instances) and Moonshine the non-periodic job measured around it.
#
#   ./scripts/12_xpurt_coloc_sweep.sh                 # all 44 cells
#   STAGE=heur ./scripts/12_xpurt_coloc_sweep.sh      # the nine heuristics only
#   STAGE=cpsat CPSAT_BUDGET=300 ./scripts/12_xpurt_coloc_sweep.sh   # a short solve
#
# HOST ONLY.  No board, no lock, no bitstream -- but every DURATION in it was
# measured on one.  The question is the one a robot actually has: a speech model
# that must finish, a detector that must not miss its frame, two harts that hold
# different instruction sets, and a memory system they share.
#
# WHAT IT ANSWERS, and the third line is the lab:
#
#   * Under measured DRAM contention, CP-SAT lands Moonshine at 5,412.25 ms --
#     past the 4,000 ms real-time-factor-1 reference.  Turning on the
#     left-shift COMPACTION post-pass takes it to 3,992.30 ms: 1,419.95 ms
#     recovered, with op_deadline_miss_count 0 in BOTH, so no detector frame was
#     traded for it.  On the uncontended arm the same pass is worth 376.15 ms
#     (3,649.06 -> 3,272.91).
#   * NONE OF THE NINE HEURISTICS CLEARS BOTH OBJECTIVES.  All 36 heuristic
#     cells fail: the best makespan (heft = critical_path, 4,251.12 ms) misses
#     three of the four detector windows, and edf -- the only policy landing all
#     four -- ends 6,076.00 ms, 2,076 ms past the reference.
#   * Quote the three crossings together, always: 0.25 fps heuristic, 1.0 fps
#     achieved, 2.62 fps capacity.  The middle figure is a solver result, not
#     the machine's limit.
#
# WHAT YOU NEED, AND WHAT THIS REPOSITORY SHIPS.
#
#   XPU-RT itself is NOT vendored here: clone it (github.com/ucb-bar/XPU-RT) and
#   point XPURT_ROOT at it.  It needs an interpreter with ortools -- build one
#   from fpga/pynq-z2/requirements-xpurt.txt and point XPURT_PY at it; ortools
#   9.15.6755 is what every number quoted above was solved with, and it pins
#   protobuf, so pin the whole closure rather than ortools alone.
#
#   EVERYTHING THE SOLVE READS IS IN THIS REPOSITORY, under
#   fpga/pynq-z2/xpurt/ -- the spec, the two dispatch graphs that carry the hard
#   machine exclusions, the four board-measured per-dispatch cost tables, and
#   the DRAM contention model.  They are laid out under exactly the relative
#   paths the spec names, and each cell below symlinks them over its private
#   copy of XPU-RT, so your XPU-RT checkout is READ and never written.
#
#   The goldens -- all 44 rows, the four refusals and the compaction table --
#   are expected/xpurt_coloc2m_b157.json.
#
# THE SPEC IS NOT MODIFIED.  data/toplevel/networks_pynqz1_coloc2m_sdp_b4_T1000.json
# already has the shape this lab needs:
#   signdet   period = window_duration = 1000.0, num_instances = 4
#   moonshine NO period, NO window_duration           (non-periodic, measured)
#   scheduler.restrict_makespan_to_nonperiodic = True
# 4000 ms is the UNCONTENDED GOAL (RTF = 1 on a 4 s utterance), never a deadline
# on Moonshine -- see `Correction to L396` in docs/EXPERIMENT_LOG.md.
#
# ------------------------------------------------------------------ the traps
# 1. THE SPEC'S `"contention": {"enabled": true}` BLOCK IS NEVER READ.  The
#    string "contention" does not appear in run_xpurt_schedule.py's spec
#    parsing at all; only the `--contention PATH` flag installs a model
#    (:1629-1645).  A previous lab solved the `none` arm for hours and filed it
#    as `dram`.  Every cell here therefore records the grep of its own log:
#    the `none` arm must have NO "--contention: loaded" line and the `dram` arm
#    must name contention_b4_dram.json.  b157_report.py re-checks this per cell
#    and refuses to label a cell it cannot confirm.
#
# 2. `XPURT_CPSAT_PYTHON` IS MANDATORY.  cpsat_scheduler.py shells the solve out
#    to an interpreter that has ortools; cpsat_available() tries
#    $XPURT_CPSAT_PYTHON then the PATH's `python3` -- never sys.executable --
#    so running the venv's python by absolute path without the env var finds
#    /usr/bin/python3, which has no ortools.  It is exported below and the
#    report greps every log for a surviving "no interpreter with ortools".
#
# ------------------------------------------------- which CP-SAT path, and why
# There are two CP-SAT implementations in this checkout:
#   scheduler_cpsat.cpsat_schedule   `--scheduler cpsat`.  Hints presence and
#       chosen_start only -- 4,522 of 23,329 non-fixed variables, 19.4 % (B152c)
#       -- and CP-SAT completes the rest itself, worse than the seed.  HEFT and
#       fifo seeds give bit-identical output: the warm start is inert.
#   cpsat_scheduler.cpsat_schedule   `--solver cpsat`.  Replays the seed on the
#       integer microsecond grid (_integerize) and hints start, end, duration
#       and presence together, or refuses the hint outright.  It keeps the seed.
# This sweep uses `cpsat_warmbest_b157` (b157_inject/sitecustomize.py), which is
# B152c's `cpsat_warmbest_repaired` -- best-of-nine seed handed to
# cpsat_scheduler -- with one change: the search-worker count comes from
# XPURT_CPSAT_WORKERS instead of the hard-coded 1.  B152c measured 1 worker at
# 4031.77 ms / 16 misses against 8 workers at 3133.40 ms / 0 misses on the
# adjacent cell, so 1 is not a neutral default.  The cost is that CP-SAT is
# reproducible only at workers=1; the count is recorded in metadata.solve_env.
# Registering in the SCHEDULERS REGISTRY (rather than driving `--solver cpsat`
# directly) is also what makes the compaction arm possible at all:
# schedulers.get_scheduler() is the only place _wrap_with_compaction is applied,
# so XPURT_COMPACT=1 is a silent no-op on the bare `--solver cpsat` path.
#
# COMPACTION.  For the nine heuristics the left-shift pass is expected to
# recover nothing -- a list scheduler already places each op at its earliest
# feasible instant -- but it was worth 455.75 ms on a CP-SAT solve at T2000
# (B155 fig 2).  Both arms are run and both are reported.  XPURT_COMPACT lands
# in metadata.solve_env of every emitted schedule, so the arm is verifiable from
# the artifact and not only from this script.
#
# ISOLATION.  run_xpurt_schedule.py writes schedules/scheduled_<spec>_<sched>_
# profiled.json relative to the CWD and the name carries neither the contention
# arm nor the compaction arm, so four cells of one scheduler would overwrite one
# another.  Each cell runs in its own symlink farm of the XPU-RT tree with
# private schedules/ and plots/ directories; nothing in XPU-RT is written.
#
# HOST ONLY.  No board, no .board.lock, no bitstream.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

XPURT="${XPURT_ROOT:-${XPURT:-}}"
[ -n "$XPURT" ] && [ -d "$XPURT/scripts" ] || die "XPURT_ROOT is not set, or does not look
       like an XPU-RT checkout.  git clone https://github.com/ucb-bar/XPU-RT and
       export XPURT_ROOT=/path/to/XPU-RT"
PY="${XPURT_PY:-${PY:-}}"
[ -n "$PY" ] && [ -x "$PY" ] || die "XPURT_PY is not set to an interpreter that has ortools.
       python3 -m venv /path/to/venv
       /path/to/venv/bin/pip install -r fpga/pynq-z2/requirements-xpurt.txt
       export XPURT_PY=/path/to/venv/bin/python
       cpsat_available() tries \$XPURT_CPSAT_PYTHON and then the PATH's python3 --
       NEVER sys.executable -- so an interpreter given by absolute path without the
       env var below silently finds /usr/bin/python3, which has no ortools."

# THE DATA THE SOLVE READS, all of it committed here, laid out under exactly the
# relative paths the spec names so a cell resolves them from its own directory.
DATA="${DATA:-$IISWC_ROOT/fpga/pynq-z2/xpurt}"
INJECT="${INJECT:-$IISWC_ROOT/scripts/lib/b157_inject}"
ARCH="${ARCH:-$IISWC_OUT/b157}"
WORK="${WORK:-$ARCH/work}"
# The DRAM contention model, measured on the board: plateau aggregate 0.924.  The
# `none` arm passes no --contention at all and must be verified to have none.
CONTDIR="${CONTDIR:-$DATA/artifacts/pynqz1_coloc}"

SPEC="${SPEC:-$DATA/networks_pynqz1_coloc2m_sdp_b4_T1000.json}"
BASE="networks_pynqz1_coloc2m_sdp_b4_T1000"
POLICIES="${POLICIES:-edf fifo heft peft critical_path min_min max_min round_robin fastest_device}"
CPSAT_SCHED="${CPSAT_SCHED:-cpsat_warmbest_b157}"
CPSAT_BUDGET="${CPSAT_BUDGET:-1800}"
CONT_ARMS="${CONT_ARMS:-none dram}"
COMPACT_ARMS="${COMPACT_ARMS:-plain compact}"
CPSAT_WORKERS="${CPSAT_WORKERS:-6}"
JOBS="${JOBS:-9}"
STAGE="${STAGE:-both}"          # heur | cpsat | both

export XPURT_CPSAT_PYTHON="${XPURT_CPSAT_PYTHON:-$PY}"
export XPURT_CPSAT_WORKERS="$CPSAT_WORKERS"

mkdir -p "$ARCH/logs" "$ARCH/schedules" "$WORK"

# One cell: <scheduler> <contention-arm> <compaction-arm> <budget-or-empty>
run_cell() {
  local sched="$1" cont="$2" comp="$3" budget="${4:-}"
  local tag="${sched}_${cont}_${comp}"
  local cell="$WORK/$tag"
  local log="$ARCH/logs/${tag}.log"
  local outdir="$ARCH/schedules/${cont}/${comp}"
  mkdir -p "$cell/schedules" "$cell/plots" "$outdir"
  # Symlink farm: everything XPU-RT has except the two output directories.
  local e b
  for e in "$XPURT"/*; do
    b=$(basename "$e")
    case "$b" in schedules|plots) continue;; esac
    ln -sfn "$e" "$cell/$b"
  done
  # ... and then THIS REPOSITORY's data over the top of whatever XPU-RT happened to
  # have there.  The spec names gen_pynqz1_2m_sdp_b4/... and artifacts/... relative to
  # the CWD, which is this cell; linking them here is what lets the solve read the
  # board-measured costs, the dispatch graphs and the contention model without anyone
  # having to drop files into a shared XPU-RT checkout.
  for e in "$DATA"/*; do
    b=$(basename "$e")
    case "$b" in *.json) continue;; esac       # the spec is passed by absolute path
    ln -sfn "$e" "$cell/$b"
  done

  local cargs=()
  [ "$cont" != "none" ] && cargs=(--contention "$CONTDIR/contention_b4_${cont}.json")
  local sargs=(--scheduler "$sched" --profiled)
  [ -n "$budget" ] && sargs+=(--cpsat-time-limit "$budget")

  # `env` takes its options BEFORE any NAME=VALUE, so every -u goes first --
  # appending one after an assignment makes env treat it as a program name
  # ("env: '-u': No such file or directory") and the cell dies having solved
  # nothing.  XPURT_NO_COMPACT is cleared in both arms because it is an explicit
  # force-off that would beat XPURT_COMPACT=1 (schedulers.py:159).
  local envs=(env -u XPURT_NO_COMPACT)
  [ "$comp" != "compact" ] && envs+=(-u XPURT_COMPACT)
  envs+=("PYTHONPATH=$INJECT" "XPURT_CPSAT_PYTHON=$XPURT_CPSAT_PYTHON"
         "XPURT_CPSAT_WORKERS=$XPURT_CPSAT_WORKERS")
  [ "$comp" = "compact" ] && envs+=("XPURT_COMPACT=1")

  if ! (cd "$cell" && "${envs[@]}" "$PY" "$XPURT/scripts/run_xpurt_schedule.py" \
        --networks-json "$SPEC" "${sargs[@]}" "${cargs[@]}") >"$log" 2>&1; then
    echo "FAILED $tag -- see $log"; return 0
  fi
  local suf f
  for suf in "" _metrics _report; do
    f="$cell/schedules/scheduled_${BASE}_${sched}_profiled${suf}.json"
    [ -f "$f" ] && cp "$f" "$outdir/"
  done
  echo "ok $tag $(grep -am1 '^Makespan (non-periodic)' "$log" || true)"
}
export -f run_cell
export XPURT PY DATA INJECT ARCH WORK CONTDIR SPEC BASE XPURT_CPSAT_PYTHON XPURT_CPSAT_WORKERS

if [ "$STAGE" = "heur" ] || [ "$STAGE" = "both" ]; then
  # Parallel over POLICIES (distinct output filenames); the four arms of one
  # policy are serialised inside the worker because they share a filename.
  for p in $POLICIES; do echo "$p"; done | xargs -P "$JOBS" -n 1 bash -c '
    for cont in '"$CONT_ARMS"'; do for comp in '"$COMPACT_ARMS"'; do
      run_cell "$0" "$cont" "$comp" ""
    done; done'
fi

if [ "$STAGE" = "cpsat" ] || [ "$STAGE" = "both" ]; then
  # All four CP-SAT cells share one scheduler name, hence one output filename --
  # but each runs in its OWN cell directory, so they are safe in parallel.
  for cont in $CONT_ARMS; do for comp in $COMPACT_ARMS; do
    echo "$cont $comp"
  done; done | xargs -P 4 -n 2 bash -c \
      'run_cell "'"$CPSAT_SCHED"'" "$0" "$1" "'"$CPSAT_BUDGET"'"'
fi

echo "done -> $ARCH/schedules/<contention>/<compaction>/ and $ARCH/logs/"
echo "score it:  python3 scripts/lib/b157_report.py --root $ARCH --gen-root $DATA/gen_pynqz1_2m_sdp_b4"
echo "then diff the table against expected/xpurt_coloc2m_b157.json"
