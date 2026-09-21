#!/usr/bin/env bash
# Serialise the PYNQ-Z1 attached to ILLIXR -- a different board from the one on garden.
#
#   scripts/with_board_illixr.sh <command...>
#
# WHY THIS EXISTS.  scripts/with_board.sh guards *the bench board on garden* through
# .board.lock.  The illixr board is a second, physically distinct board reached over the
# network (see fpga/pynq-z2/docs/BRINGUP_ILLIXR.md), so that lock says nothing about it:
# taking it would block the garden workstreams for no reason, and NOT taking a lock at all
# would let two agents drive this board at once.
#
# with_board.sh already reads $BOARD_LOCK, so this is the same queue machinery pointed at a
# different lock file -- not a second implementation.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BOARD_LOCK="${BOARD_LOCK_ILLIXR:-$root/.board_illixr.lock}"
exec "$root/scripts/with_board.sh" "$@"
