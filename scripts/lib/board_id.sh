# SPDX-License-Identifier: Apache-2.0
#
# Identify WHICH PHYSICAL BOARD a run is talking to, so its rows can never be blended with
# another machine's.
#
# WHY THIS EXISTS.  scripts/lib/bitstream_id.sh identifies the BUILD in the PL by md5,
# because SOC_MAGIC names only the configuration.  This file answers the other half of the
# same question: md5 identifies the silicon's CONTENTS, not the silicon.  From 2026-09-17
# there are two PYNQ-Z1s -- one on garden, one on illixr -- and the first cross-board
# experiment runs THE SAME md5 on both.  Joining on config + bitstream_md5, which
# MAGIC_REGISTRY.md prescribes and which is right for every earlier question, would put both
# machines under one key and average them into a number neither produced.
#
#   require_pynq_host       -> dies with an instruction unless PYNQ_HOST is set
#   board_identify          -> sets BOARD_NAME, BOARD_HOST, BOARD_CID; prints them
#   board_gate              -> dies unless BOARD_NAME is set and is in boards.csv
#
# Resolution order, and it deliberately ends in a refusal rather than a guess:
#   1. $IISWC_BOARD, if the caller set it explicitly -- this is also the answer for a board
#      that is not ours: boards.csv registers THIS project's two machines, it is not a list
#      anyone else has to join
#   2. a lookup of $PYNQ_HOST in fpga/pynq-z2/bwlab/boards.csv
#   3. die -- an unknown board is never silently recorded as blank or as "unknown"
#
# $PYNQ_HOST itself has NO built-in default as of 2026-09-21; env.sh reads it from the
# environment or from the untracked board.conf (see board.conf.example).
#
# board_identify also reads the SD card CID off the board and compares it with the registry.
# That is a TRIPWIRE, not the identity: it catches a card moved between boards, or PYNQ_HOST
# pointed somewhere unexpected. A mismatch warns loudly; a missing registry CID is filled in
# by hand, not automatically, because a card swap must be noticed by a person.

BOARDS_CSV="${BOARDS_CSV:-$IISWC_ROOT/fpga/pynq-z2/bwlab/boards.csv}"

_board_die () { printf '\033[31merror\033[0m board_id: %s\n' "$*" >&2; exit 1; }

# require_pynq_host -- the single refusal point for "which board".
#
# env.sh used to default PYNQ_HOST to this bench's address. It no longer does (see the long
# comment there), so every path that is about to open an ssh connection calls this first and
# gets an instruction instead of a connection to whatever happens to answer at a stale IP.
require_pynq_host () {
  # `[ ... ] && return 0` would trip errexit in every caller that runs under `set -e`,
  # exiting silently with the message unprinted. The `if` form is not style, it is the fix.
  if [ -n "${PYNQ_HOST:-}" ]; then return 0; fi
  printf '\033[31merror\033[0m board_id: PYNQ_HOST is not set -- no board to talk to.\n' >&2
  printf '\n' >&2
  printf '        Set it for one command:      PYNQ_HOST=xilinx@<board-ip> %s ...\n' "${0##*/}" >&2
  printf '        or once for this checkout:   cp board.conf.example board.conf  &&  $EDITOR board.conf\n' >&2
  printf '\n' >&2
  printf '        There is no default on purpose: any baked-in address is right on exactly one\n' >&2
  printf '        network, and on every other one it is nothing at all or a board that is not yours.\n' >&2
  printf '        See board.conf.example and fpga/pynq-z2/docs/BRINGUP.md.\n' >&2
  exit 1
}

# board_lookup_by_host <pynq_host> -> board name on stdout, empty if unknown
board_lookup_by_host () {
  awk -F, -v h="$1" '!/^#/ && NR>0 && $2==h {print $1; exit}' "$BOARDS_CSV"
}

board_registry_cid () {
  awk -F, -v b="$1" '!/^#/ && $1==b {print $3; exit}' "$BOARDS_CSV"
}

# Resolve the board name without touching the board.  Used by bwlab_row on every row, so it
# must be cheap and must never open an ssh connection.
board_name () {
  if [ -n "${IISWC_BOARD:-}" ]; then printf '%s\n' "$IISWC_BOARD"; return 0; fi
  local host="${PYNQ_HOST:-}"
  if [ -z "$host" ]; then
    printf '\033[31merror\033[0m board_id: neither IISWC_BOARD nor PYNQ_HOST is set.\n' >&2
    printf '        Name the board (IISWC_BOARD=...) or the host (PYNQ_HOST=user@ip); see board.conf.example.\n' >&2
    return 1
  fi
  local name; name="$(board_lookup_by_host "$host")"
  if [ -z "$name" ]; then
    printf '\033[31merror\033[0m board_id: PYNQ_HOST=%s is not in %s, and IISWC_BOARD is not set.\n' \
      "$host" "$BOARDS_CSV" >&2
    printf '        Every results.csv row must name the board that produced it.\n' >&2
    printf '        If this is OUR hardware: add a row to boards.csv (under scripts/lib/with_lock.sh docs).\n' >&2
    printf '        If it is YOUR OWN board: boards.csv is this project provenance record of its two\n' >&2
    printf '        machines, not a list you have to join -- set IISWC_BOARD=<short-name> instead\n' >&2
    printf '        (board.conf is the place to keep it).\n' >&2
    return 1
  fi
  printf '%s\n' "$name"
}

# Full identification, including a round trip to the board.  Call once per run, next to
# bitstream_identify and the clock readback -- not per row.
board_identify () {
  require_pynq_host
  BOARD_HOST="$PYNQ_HOST"
  BOARD_NAME="$(board_name)" || _board_die "cannot resolve the board"
  BOARD_CID="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$BOARD_HOST" \
                 'cat /sys/block/mmcblk0/device/cid 2>/dev/null' 2>/dev/null | tr -d '[:space:]')"
  local want; want="$(board_registry_cid "$BOARD_NAME")"
  printf '    board: %s  (%s)\n' "$BOARD_NAME" "$BOARD_HOST"
  if [ -z "$BOARD_CID" ]; then
    printf '    board: SD card CID unreadable -- recorded as empty, NOT as a match\n'
  elif [ -z "$want" ]; then
    printf '    board: SD card CID %s  (no CID on record for %s; add it to boards.csv)\n' \
      "$BOARD_CID" "$BOARD_NAME"
  elif [ "$BOARD_CID" = "$want" ]; then
    printf '    board: SD card CID %s  matches the registry\n' "$BOARD_CID"
  else
    printf '\033[33m[warn]\033[0m board_id: SD card CID %s does NOT match the %s row (%s).\n' \
      "$BOARD_CID" "$BOARD_NAME" "$want" >&2
    printf '        Either the card was moved between boards, or PYNQ_HOST points somewhere\n' >&2
    printf '        unexpected. Resolve this before recording a number.\n' >&2
  fi
  export BOARD_NAME BOARD_HOST BOARD_CID
}

board_gate () {
  [ -n "${BOARD_NAME:-}" ] || _board_die "BOARD_NAME is not set -- call board_identify first"
  [ -n "$(board_lookup_by_host "${BOARD_HOST:-}")" ] || [ -n "${IISWC_BOARD:-}" ] \
    || _board_die "board '$BOARD_NAME' is not in $BOARDS_CSV"
}

# board_stamp_json <file> [...]  -- merge board identity into an existing JSON manifest.
#
# run.json is built ad hoc in ~15 labs, each with its own json.dump, so there is no single
# place to add a field.  This stamps them after the fact instead: idempotent, additive, and
# it never rewrites a value that is already there and disagrees -- it fails, because a
# manifest that already names a different board is a fact to investigate, not to overwrite.
board_stamp_json () {
  [ -n "${BOARD_NAME:-}" ] || _board_die "board_stamp_json: call board_identify first"
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    BOARD_NAME="$BOARD_NAME" BOARD_HOST="${BOARD_HOST:-}" BOARD_CID="${BOARD_CID:-}" \
    python3 - "$f" <<'PYJ'
import json, os, sys
p = sys.argv[1]
try:
    with open(p) as fh:
        d = json.load(fh)
except Exception as e:
    sys.exit("board_stamp_json: %s is not readable JSON (%s)" % (p, e))
if not isinstance(d, dict):
    sys.exit("board_stamp_json: %s is not a JSON object" % p)
want = os.environ["BOARD_NAME"]
have = d.get("board")
if have and have != want:
    sys.exit("board_stamp_json: REFUSING -- %s already says board=%r, not %r" % (p, have, want))
d["board"] = want
d["board_host"] = os.environ.get("BOARD_HOST", "")
d["board_sd_card_cid"] = os.environ.get("BOARD_CID", "")
with open(p, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
print("    board: stamped %s -> board=%s" % (p, want))
PYJ
  done
}
