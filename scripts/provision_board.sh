#!/usr/bin/env bash
# Put everything a lab needs onto a board, and check the board is actually lab-ready.
#
#   scripts/provision_board.sh                       # uses $PYNQ_HOST
#   PYNQ_HOST=xilinx@<board-ip> scripts/provision_board.sh
#   scripts/provision_board.sh --check               # report only, copy nothing
#
# WHY THIS EXISTS.  Labs scp only the handful of files they think they need, and then call
# others that a one-time manual setup happened to leave on the bench board.  scripts/51
# invokes fclk.py and read_rmb_log.py on the board but scp's neither; on garden they were
# already there, so nobody noticed.  On a second board they are absent and the lab fails at
# the point of measurement.
#
# THE FILE LIST IS DERIVED, NOT MAINTAINED.  It is computed here from what the labs actually
# reference -- every `python3 <tool>.py` invoked in a lab, every `host/<tool>.py` a lab sends,
# and every $RUNNER -- intersected with what exists in fpga/pynq-z2/host/.  A list frozen in
# this file would rot the moment a lab gained a tool, which is the failure it exists to fix.
#
# Idempotent: it md5s both ends and copies only what differs, then verifies.
set -euo pipefail
IISWC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export IISWC_ROOT
. "$IISWC_ROOT/scripts/lib/board_id.sh"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# No baked-in host: see env.sh and board.conf.example. This script does not source
# env.sh (it wants none of the Zephyr toolchain), so it reads board.conf the same way.
IISWC_BOARD_CONF="${IISWC_BOARD_CONF:-$IISWC_ROOT/board.conf}"
if [ -z "${PYNQ_HOST:-}" ] && [ -f "$IISWC_BOARD_CONF" ]; then
  # shellcheck disable=SC1090
  . "$IISWC_BOARD_CONF"
fi
require_pynq_host
PYNQ_DIR="${PYNQ_DIR:-/home/xilinx/tutorial}"
H="$IISWC_ROOT/fpga/pynq-z2/host"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_grn" "$*" "$c_off"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

step "0/4  which board"
board_identify
board_gate
info "dir: $PYNQ_DIR"

step "1/4  derive the board-side file list from what the labs reference"
# Scan every lab, but not this script -- it mentions the patterns it greps for.
LABS=$(ls "$IISWC_ROOT"/scripts/*.sh | grep -v provision_board.sh)
mapfile -t WANT < <(
  {
    grep -hoE 'python3 (-u )?[a-z0-9_]+\.py' $LABS | grep -oE '[a-z0-9_]+\.py'
    grep -hoE 'host/[a-z0-9_]+\.py'          $LABS | sed 's|host/||'
    # RUNNER is usually quoted: RUNNER="run_rocket_roccmoon.py"
    grep -hoE 'RUNNER="?[a-z0-9_]+\.py'      $LABS | sed 's/RUNNER="\?//'
  } | sort -u | while read -r f; do [ -f "$H/$f" ] && printf '%s\n' "$f"; done
)
[ "${#WANT[@]}" -gt 0 ] || die "derived an empty file list -- that cannot be right"
info "${#WANT[@]} board-side tools: ${WANT[*]}"

step "2/4  compare both ends by md5"
"${SSH[@]}" "mkdir -p $PYNQ_DIR" || die "cannot reach $PYNQ_HOST"
REMOTE_MD5="$("${SSH[@]}" "cd $PYNQ_DIR 2>/dev/null && md5sum ${WANT[*]} 2>/dev/null" || true)"
NEED=()
for f in "${WANT[@]}"; do
  l=$(md5sum "$H/$f" | cut -d' ' -f1)
  r=$(printf '%s\n' "$REMOTE_MD5" | awk -v f="$f" '$2==f {print $1}')
  if [ "$l" != "$r" ]; then NEED+=("$f"); fi
done
if [ "${#NEED[@]}" -eq 0 ]; then
  info "all ${#WANT[@]} already present and identical -- nothing to copy"
else
  info "${#NEED[@]} differ or are missing: ${NEED[*]}"
fi

step "3/4  copy what differs"
if [ "$CHECK_ONLY" = 1 ]; then
  info "--check: copying nothing"
elif [ "${#NEED[@]}" -gt 0 ]; then
  ( cd "$H" && scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "${NEED[@]}" "$PYNQ_HOST:$PYNQ_DIR/" )
  BAD=0
  AFTER="$("${SSH[@]}" "cd $PYNQ_DIR && md5sum ${NEED[*]}")"
  for f in "${NEED[@]}"; do
    l=$(md5sum "$H/$f" | cut -d' ' -f1)
    r=$(printf '%s\n' "$AFTER" | awk -v f="$f" '$2==f {print $1}')
    [ "$l" = "$r" ] || { warn "md5 mismatch after copy: $f"; BAD=1; }
  done
  [ "$BAD" = 0 ] || die "a file did not survive the copy"
  info "copied and md5-verified ${#NEED[@]} file(s)"
fi

step "4/4  is the board actually lab-ready?"
# These are the commissioning differences a stock card does not have.  Each one fails a lab
# in a way that does NOT look like a missing file.  See fpga/pynq-z2/docs/BRINGUP_ILLIXR.md s8.
RC=0
chk () { # chk <description> <remote test> <why it matters>
  if "${SSH[@]}" "$2" >/dev/null 2>&1; then printf '    ok   %s\n' "$1"
  else printf '%s    MISSING%s %s\n           -> %s\n' "$c_red" "$c_off" "$1" "$3"; RC=1; fi
}
chk "passwordless sudo"        "sudo -n true" \
    "every board tool runs under sudo; without it labs hang or fail on a password prompt"
chk "/dev/ttyPS1 (EMIO UART)"  "test -c /dev/ttyPS1" \
    "the guest console. Needs boot-patches/patch_boot_dtb.sh + reboot"
chk "xilinx in dialout"        "test -r /dev/ttyPS1" \
    "without it console.py reads NOTHING and the lab reports 'no console output'"
chk "DDR window reserved"      "grep -q 'mem=256M' /proc/cmdline" \
    "without it Linux owns all 512 MB and a guest write to 0x1000_0000 hits kernel memory"
# Must be tested the way the labs invoke it -- $PYNQ_ENV activates the venv. A bare
# `python3 -c "import pynq"` over ssh fails on a perfectly good board.
chk "pynq python package"      "bash -lc 'source /usr/local/share/pynq-venv/bin/activate; python3 -c \"import pynq\"'" \
    "bitstream download needs it"
[ "$RC" = 0 ] || warn "board is NOT fully commissioned -- see BRINGUP_ILLIXR.md section 8"

printf '\n%s==> provisioned %s (%s)%s\n' "$c_grn" "$BOARD_NAME" "$PYNQ_HOST" "$c_off"
exit $RC
