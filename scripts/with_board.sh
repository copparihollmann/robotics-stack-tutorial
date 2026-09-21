#!/usr/bin/env bash
# Serialise access to the one physical PYNQ-Z1 -- first come, first served.
#
#   scripts/with_board.sh <command...>
#
# There is a single board on the bench and several workstreams want it. Loading a bitstream
# out from under someone else's running test produces confusing garbage at best, and a hung
# board at worst. Wrap every board-touching command in this.
#
#   scripts/with_board.sh ./scripts/20_rocket_run.sh --sample ...
#   scripts/with_board.sh ssh $PYNQ_HOST 'cat /proc/cmdline'
#
# WHY A QUEUE AND NOT JUST flock. This used to be `exec flock "$LOCK" "$@"`, and flock is not
# FIFO: every release wakes all waiters and they race. With six requests queued, the oldest --
# the interface-ceiling lab, waiting 49 minutes, whose number every other workstream is
# measured against -- had roughly a one-in-six chance per release and a 2-hour timeout running
# down. So each caller now takes a ticket named by its arrival time, and only the oldest live
# ticket may try the lock.
#
# A ticket is live while its own with_board.sh process is running; stale tickets (a caller that
# crashed, or a pid the kernel has since reused for something else) are cleared on sight, so
# nothing can wedge the queue. Callers that `flock .board.lock` directly still respect the lock
# but skip the queue -- use this wrapper instead.
#
# Waits up to BOARD_LOCK_TIMEOUT seconds (default 7200) rather than failing immediately.
set -euo pipefail
_WB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The lock lives beside the checkout, not at an absolute path into one person's scratch
# directory. scripts/with_board_illixr.sh already derives its own this way.
LOCK="${BOARD_LOCK:-$_WB_ROOT/.board.lock}"
TIMEOUT="${BOARD_LOCK_TIMEOUT:-7200}"
POLL="${BOARD_POLL:-2}"
[ $# -gt 0 ] || { echo "usage: with_board.sh <command...>" >&2; exit 2; }
touch "$LOCK"
QDIR="$LOCK.queue"
mkdir -p "$QDIR"

me="$(date +%s%N).$$"
printf '%s\n' "$*" > "$QDIR/$me"
cleanup() { rm -f "$QDIR/$me"; }
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

live() {   # live <pid>: is that pid still a with_board.sh? No pipes, so pipefail cannot lie.
  local c
  [ -r "/proc/$1/cmdline" ] || return 1
  # The braces matter: a bare `2>/dev/null` silences tr, not the shell's own failed redirect,
  # and that message would otherwise land in every lab log whenever a stale ticket is cleared.
  c="$( { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null )" || return 1
  case "$c" in *with_board*) return 0 ;; *) return 1 ;; esac
}

deadline=$(( $(date +%s) + TIMEOUT ))
announced=0
while :; do
  head=""
  for t in $(ls -1 "$QDIR" 2>/dev/null | sort); do
    if live "${t##*.}"; then head="$t"; break; fi
    rm -f "$QDIR/$t"
  done
  if [ "$head" = "$me" ]; then
    exec 9>>"$LOCK"
    if flock -n 9; then break; fi
    exec 9>&-
  elif [ "$announced" -eq 0 ]; then
    ahead=0
    for t in $(ls -1 "$QDIR" 2>/dev/null | sort); do [[ "$t" < "$me" ]] && ahead=$((ahead+1)); done
    echo "[with_board] queued behind $ahead request(s)" >&2
    announced=1
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "[with_board] no board after ${TIMEOUT}s" >&2; exit 1; }
  sleep "$POLL"
done
# Leave the queue once the lock is held, so the next caller can line up behind the lock itself.
cleanup
trap - EXIT TERM INT
exec "$@"          # fd 9 stays open in the command, so the board is held until it exits
