#!/usr/bin/env bash
# Serialise a shared resource across agents working in parallel.
#
#   scripts/lib/with_lock.sh <resource> <command...>
#
# Several agents now build, elaborate and measure at once, and a handful of things in this
# repo are single-writer by nature. Each gets one named lock here so nobody invents their own:
#
#   chipyard  sbt elaboration in the donor Chipyard tree, PynqZ2Configs.scala (both copies),
#             chipyard/gensrc/SHA256SUMS. sbt in one project is not safe to run twice at once.
#   toplevel  src/pynqz2_rocket_top.v, tcl/build_rocket.tcl's variant switch, the PS7 preset.
#             Hold it for the edit, not for the build.
#   git       `git commit`. Two concurrent commits race on .git/index.lock.
#
#             THE LOCK DOES NOT COVER `git add`, AND THE INDEX IS ONE SHARED FILE.
#             `git commit` commits THE INDEX, not the paths you passed to `git add` -- so
#             another agent staging between your add and your commit lands in YOUR commit,
#             under YOUR message. This has happened twice; careful path naming cannot
#             prevent it, because the race is not in the naming.
#
#             Always commit with an explicit pathspec:
#                 git add <paths> && with_lock.sh git git commit -F msg -- <paths>
#             `commit -- <paths>` takes those paths' working-tree content and leaves the
#             rest of the index alone, so a concurrent stage stays staged and stays theirs.
#
#             And do NOT `git reset` to undo a bad commit here: several agents share this
#             index and history. One `reset --soft HEAD~1` recovered only because the other
#             agent's commit happened to sit one below and the content was still in the
#             index -- luck, not judgement. Record the mistake in a follow-up commit
#             instead; a later correction is cheap and a rewritten shared history is not.
#   results   appending to fpga/pynq-z2/bwlab/results.csv. Append-only, never rewrite.
#   docs      the documentation set under docs/ and fpga/pynq-z2/docs/.
#   vivado    a COUNTING lock: VIVADO_SLOTS (default 8) place-and-routes at once. Holds a
#             slot for the lifetime of the command.
#
# The board is not here -- it already has scripts/with_board.sh and .board.lock.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$root/.locks"
[ $# -ge 2 ] || { echo "usage: $0 <chipyard|toplevel|git|results|docs|vivado> <command...>" >&2; exit 2; }
res="$1"; shift

case "$res" in
  chipyard|toplevel|git|results|docs)
    exec flock --timeout "${LOCK_TIMEOUT:-14400}" "$root/.locks/$res.lock" "$@" ;;
  vivado)
    slots="${VIVADO_SLOTS:-8}"
    deadline=$(( $(date +%s) + ${LOCK_TIMEOUT:-14400} ))
    while :; do
      for i in $(seq 1 "$slots"); do
        exec 9>"$root/.locks/vivado.$i.lock"
        if flock -n 9; then
          echo "[with_lock] vivado slot $i/$slots" >&2
          exec "$@"          # fd 9 stays open in the child, so the slot is held until it exits
        fi
        exec 9>&-
      done
      [ "$(date +%s)" -lt "$deadline" ] || { echo "[with_lock] no vivado slot free before timeout" >&2; exit 1; }
      sleep "${LOCK_POLL:-30}"
    done ;;
  *) echo "unknown resource '$res'" >&2; exit 2 ;;
esac
