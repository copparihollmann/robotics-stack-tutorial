#!/usr/bin/env bash
# Shared helpers. Every script sources this, which in turn sources env.sh.
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$(cd "$_LIB_DIR/../.." && pwd)/env.sh"

_c_grn=$'\033[1;32m'; _c_red=$'\033[1;31m'; _c_yel=$'\033[1;33m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'

step() { printf '\n%s==> %s%s\n' "$_c_grn" "$*" "$_c_off"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[warn]%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }
run()  { printf '%s    $ %s%s\n' "$_c_dim" "$*" "$_c_off"; "$@"; }

need_file() { [ -f "$1" ] || die "missing: $1${2:+  ($2)}"; }
need_exec() { [ -x "$1" ] || die "not executable: $1${2:+  ($2)}"; }

# Human-readable byte count for a file.
fsize() { du -h "$1" 2>/dev/null | cut -f1; }

# ---- which physical board -------------------------------------------------------------
#
# Every script sources this file, which makes it the one place that can guarantee a run
# knows which machine it is talking to.  From 2026-09-17 there are two PYNQ-Z1s and the
# first cross-board experiment runs THE SAME bitstream md5 on both, so `config +
# bitstream_md5` -- the join MAGIC_REGISTRY.md prescribes -- no longer identifies a machine.
#
# Resolved here and EXPORTED, so the inline CSV writers in scripts/43, 45, 48, 49 and 51
# (each of which has its own DictWriter and none of which goes through bwlab_row) can stamp
# it without re-deriving it.  Resolution is quiet and non-fatal here: a lab that never
# records a number should not fail because a board is unregistered.  The refusal happens at
# the point a row is written, where it belongs -- see scripts/lib/board_id.sh.
. "$_LIB_DIR/board_id.sh"
IISWC_BOARD="$(board_name 2>/dev/null || true)"
export IISWC_BOARD

# ---- which bitstream ------------------------------------------------------------------
#
# Sourced here, not per-lab, for the same reason board_id.sh is: bitstream_require() is the
# refusal point for "the file I am about to download into the PL is not the one this repo
# ships", and a refusal that only some labs can reach is not a refusal.  The 39 labs that
# already source this file by hand keep working -- it defines functions and two `:-`
# defaults, so a second source is a no-op and a lab that narrows BIT_ACCEPTED afterwards
# still wins.
. "$_LIB_DIR/bitstream_id.sh"
