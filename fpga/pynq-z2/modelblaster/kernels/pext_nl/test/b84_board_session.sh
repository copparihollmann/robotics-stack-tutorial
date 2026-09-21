#!/usr/bin/env bash
# Lab B84 -- the decoder levers that were declined on the claw-back `C`, ONE ARM PAIR.
#
#   scripts/with_board.sh fpga/pynq-z2/modelblaster/kernels/pext_nl/test/b84_board_session.sh
#
# ONE BITSTREAM, ONE TREE, ONE HOLD, CONTROL FIRST.  L354 measured a cross-bitstream decoder
# absolute carrying +-4.5 M cycles from a bimodal fill placement, so the control is taken IN
# SESSION on the SAME bitstream: no placement draw can sit between a control and its treatment
# and every delta stands on its own.
#
#   A  b84_dec_ctl     b80_dec_int6_b76's configuration EXACTLY.  Its zephyr.bin is already
#                      known BYTE-IDENTICAL to b82_dec_unr_off's (md5 a71fc221...), so this
#                      arm is a positive control against two prior records.
#   B  b84_dec_bundle  A + -DMBP_B74=1 -DMBP_B84=1     (two -D, nothing else)
#
# Both images are ALREADY BUILT (--build-only, before the lock).  This script only runs them.
# Band: B84_BAND.md, commit 8aeabfa, committed before any board time.
#
# A THIRD IMAGE, b84_dec_lane (B + --cat2-lane), is built and gated and is NOT run here: the
# coordinator's hold is one arm pair.  Its prediction stands in B84_BAND.md section 5.
#
# ---------------------------------------------------------------------------------------
# THE BITSTREAM GATE, AND WHY THIS IS NOT A WIDENING
# ---------------------------------------------------------------------------------------
# scripts/58's accepted list is "${BIT_ACCEPTED:-} ${ROCCMOON_ACCEPTED:-32d10e5d...}", so a lab
# on 0x5A5A002F has to name that build for its own session; B80, B81, B82 and B83 each did.
# This script does NOT hardcode an md5 and does NOT edit scripts/lib/bitstream_id.sh.  It reads
# the accepted value out of fpga/pynq-z2/MAGIC_FEATURES.tsv -- the project's own registry of
# what each build CONTAINS, which carries a full validated row for this one -- and then refuses
# to run unless the .bit file on disk hashes to exactly that row.  So the gate is sourced from
# the registry and checked against the file, which is strictly stronger than naming a literal.
set -uo pipefail
cd "$(dirname "$0")/../../../../../.."
R="$(pwd)"
MAGIC=0x5A5A002F
VARIANT=roccmoonint6
TSV="$R/fpga/pynq-z2/MAGIC_FEATURES.tsv"
BIT="$R/fpga/pynq-z2/build_rocket_micrgb_${VARIANT}_z1/pynqz1_rocket_micrgb_${VARIANT}.bit"
IR="$R/out/b77_dec_int6/ir"
LOG="${B84_LOG:-$R/out/b84_board.log}"

[ -r "$TSV" ] || { echo "no $TSV -- cannot tell a registered build from an invented one"; exit 2; }
[ -r "$BIT" ] || { echo "no bitstream at $BIT"; exit 2; }
REG_MD5=$(awk -F'\t' -v m="$MAGIC" -v v="$VARIANT" '$2==m && $3==v {print $1; exit}' "$TSV")
[ -n "$REG_MD5" ] || { echo "MAGIC_FEATURES.tsv has no $VARIANT row for $MAGIC"; exit 2; }
FILE_MD5=$(md5sum "$BIT" | cut -d' ' -f1)
if [ "$FILE_MD5" != "$REG_MD5" ]; then
  echo "REFUSING: $BIT hashes to $FILE_MD5 but $MAGIC's registry row is $REG_MD5."
  echo "          The file on disk is not the build the registry describes."
  exit 2
fi
echo "bitstream matches its MAGIC_FEATURES.tsv row for $MAGIC ($VARIANT)"
export ROCCMOON_ACCEPTED="$REG_MD5"

exec > >(tee -a "$LOG") 2>&1
COMMON=(--ir "$IR" --magic "$MAGIC" --bit "$BIT"
        --runner run_rocket_roccmoonint6.py
        --weight-bits 6 --fclk 34.4828 --board-only)
RC=0
park () { echo; echo "===== PARK ($1) ====="; ./scripts/67_board_parked.sh --board-name garden 2>&1 | tail -4; }
trap 'echo; echo "=== trap: parking before release ==="; park after_trap' EXIT

arm () {  # arm <name> <kernel-cflags>
  local name="$1" kcf="$2"
  echo; echo "################ ARM $name ################"; date
  ./scripts/58_rocket_moonshine_dec_board.sh --name "$name" "${COMMON[@]}" \
      --kernel-cflags "$kcf" || RC=$?
  local c="$R/out/$name/dec_q16/console.txt" b="$R/out/$name/boot.log"
  if [ ! -s "$b" ]; then
    echo "PRE-BOARD REFUSAL on $name: no boot.log, the PL was never loaded -- STOPPING"
    exit 8
  fi
  if [ ! -s "$c" ]; then
    echo "BOARD SAFETY: $name console is 0 bytes after the PL was loaded -- STOPPING"
    exit 9
  fi
  if grep -q "PS_HOLDS" "$c" 2>/dev/null; then
    echo "BOARD SAFETY: $name console reports PS_HOLDS -- STOPPING"
    exit 9
  fi
  grep -E "^MB_PEXT_RUN" "$c" | head -1
}

park before
arm b84_dec_ctl    "-falign-loops=4 -DMBP_B76=1"
arm b84_dec_bundle "-falign-loops=4 -DMBP_B76=1 -DMBP_B74=1 -DMBP_B84=1"
echo; echo "################ done, rc=$RC ################"; date
exit $RC
