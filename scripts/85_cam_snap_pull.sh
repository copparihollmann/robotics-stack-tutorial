#!/usr/bin/env bash
# 85_cam_snap_pull.sh -- pull one frame off the board for every button press.
#
# samples/cam_snap prints, AFTER it has swept the L2 so the PS can see DRAM:
#
#   SNAP seq=3 addr=0x80123456 bytes=105624 stride=326 h=324 rc=0 dma_status=0x0a
#        saweof=1 class=14 name=Stop pct=76 second=17 mean=98 sd=31 distinct=187 ms=344 ...
#
# This watches the live console that scripts/83 is writing and, for each such line, reads
# that buffer back over SSH and turns it into a picture.  Run it BESIDE the board session,
# not inside it: the board session owns the lock and the console, this owns nothing and can
# be killed at any time without disturbing the run.
#
# ============================================================================================
# THIS PULLER IS ONLY SOUND AGAINST A GUEST THAT HOLDS THE FRAME.  READ THIS BEFORE REUSING IT.
# ============================================================================================
# It reads the guest's frame buffer over SSH *after* seeing the SNAP line.  That is safe for
# samples/cam_snap, which blocks on a button press and therefore leaves the buffer untouched
# until the operator presses again -- seconds, not milliseconds.
#
# It is NOT safe against a FREE-RUNNING guest.  samples/signdet_live has a single
# `static uint8_t frame[CAP_BYTES]` (src/main.c:189) overwritten every ~238 ms, so by the time
# this script's ssh + read_mem round trip completes, the bytes belong to a LATER inference than
# the line that triggered the pull.  Lab B147 measured the damage: across 78 frames pulled from
# a live demo, the filename's class suffix matched the board's own decision for that frame on
# only 39 of 78 -- one of them, snap_047_none, holds a centred STOP.
#
# So: the .raw bytes are a real frame, but the NAME is not a label, and pairing the two is a
# mistake that looks like data.  Against a free-running guest, use the frames as unlabelled
# captures or make the guest double-buffer and hold.  The warning below is printed every run
# rather than left in a comment nobody opens.
#
# WHY THE ADDRESS COMES FROM THE LINE AND IS NOT BAKED IN.  It is the guest's own `frame`
# buffer and it moves whenever the image is relinked.  A hardcoded address would keep
# working and quietly return somebody else's memory.
#
#   ./scripts/85_cam_snap_pull.sh --name cam_snap --host xilinx@<your board>
#
set -euo pipefail

NAME="cam_snap"
PYNQ_HOST="${PYNQ_HOST:-}"
PYNQ_DIR="${PYNQ_DIR:-/home/xilinx/tutorial}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --host) PYNQ_HOST="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# THE CONSOLE TO WATCH IS THE BOARD'S, NOT THE LOCAL COPY.  scripts/83 only fetches
# console.out into out/<name>/console.txt AFTER the whole board block returns, so the local
# file is 0 bytes for the entire session -- a puller watching it sees nothing until the run
# is over, by which point the frame buffer holds only the LAST frame and every snap would
# come back as the same picture.  console.py writes the board-side file unbuffered (-u), so
# tailing it over SSH is live.
# NO DEFAULT ADDRESS.  Any baked-in one is right on exactly one network and on every other
# is nothing at all, or somebody else's board.  See board.conf.example.
[ -n "$PYNQ_HOST" ] || { echo "PYNQ_HOST is not set -- no board to pull from." >&2
  echo "  PYNQ_HOST=xilinx@<board-ip> $0 --name <run>   (or set it in board.conf)" >&2
  exit 1; }

REMOTE_CONSOLE="$PYNQ_DIR/console.out"
OUT="$ROOT/out/$NAME/snaps"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
mkdir -p "$OUT"

echo "watching $PYNQ_HOST:$REMOTE_CONSOLE"
echo
echo "  NOTE: the class in each filename is the SNAP line's, but the bytes are read after it."
echo "        Against a button-gated guest (samples/cam_snap) they correspond.  Against a"
  echo "        free-running one (samples/signdet_live, ~238 ms/frame) they often do NOT --"
  echo "        B147 measured 39/78 agreement.  Treat those .raw files as UNLABELLED."
echo
echo "writing  $OUT"
# The board session creates the console a few seconds in; wait rather than failing, so the
# operator can start these two in either order.
until "${SSH[@]}" "test -f $REMOTE_CONSOLE" 2>/dev/null; do sleep 2; done

# -F (= --follow=name --retry): scripts/83 does `rm -f console.out` on every run, and a tail
# holding the old inode would sit there reporting nothing for ever.
"${SSH[@]}" "tail -n +1 -F $REMOTE_CONSOLE" 2>/dev/null | while read -r line; do
  case "$line" in
    SNAP\ seq=*) ;;
    *) continue ;;
  esac

  seq=$(sed -n 's/.*\bseq=\([0-9]*\).*/\1/p'  <<<"$line")
  addr=$(sed -n 's/.*\baddr=\(0x[0-9a-fA-F]*\).*/\1/p' <<<"$line")
  cls=$(sed -n  's/.*\bname=\([^ ]*\).*/\1/p'  <<<"$line")
  pct=$(sed -n  's/.*\bpct=\([0-9]*\).*/\1/p'  <<<"$line")
  eof=$(sed -n  's/.*\bsaweof=\([0-9]*\).*/\1/p' <<<"$line")
  [ -n "$seq" ] && [ -n "$addr" ] || continue

  if [ "${eof:-0}" != "1" ]; then
    echo "  snap $seq: saweof=0 -- the DMA did not see end-of-frame, not pulling a torn frame"
    continue
  fi

  # The guest's view is 0x8xxx_xxxx; the PS sees the same DRAM at 0x1xxx_xxxx.
  ps_phys=$(python3 -c "print(hex(0x10000000 | (int('$addr',16) & 0x0fffffff)))")
  stem=$(printf "snap_%03d_%s" "$seq" "${cls:-unknown}")

  if ! "${SSH[@]}" "cd $PYNQ_DIR && sudo -n python3 read_mem.py \
        --phys $ps_phys --bytes 105624 --out snap.raw" >/dev/null 2>&1; then
    echo "  snap $seq: the PS could not read $ps_phys"
    continue
  fi
  scp -q "$PYNQ_HOST:$PYNQ_DIR/snap.raw" "$OUT/$stem.raw" || { echo "  snap $seq: scp failed"; continue; }

  # --width is the STRIDE (326); --crop-left 2 drops the padding columns to give 324x324.
  # cam_view writes a DIRECTORY: {mosaic.png, rgb.png, stats.json}.
  python3 "$ROOT/fpga/pynq-z2/host/cam_view.py" --raw "$OUT/$stem.raw" \
      --width 326 --height 324 --crop-left 2 --out "$OUT/$stem" >/dev/null 2>&1 \
    || { echo "  snap $seq: cam_view failed on $OUT/$stem.raw"; continue; }

  # stats.json carries the two discriminators that separate a picture from a flat field or
  # from noise (cam_view --selftest proves the separation): bayer_ratio is < 1 for a scene
  # and ~1 for white noise; neighbour_r is strongly positive for a scene and ~0 for noise.
  # Printed per snap so a bad frame is obvious AT THE BENCH, not at analysis time.
  read -r br nr <<<"$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('%.3f %.3f' % (d.get('bayer_ratio',float('nan')), d.get('neighbour_r',float('nan'))))" \
      "$OUT/$stem/stats.json" 2>/dev/null || echo "nan nan")"

  echo "  snap $seq -> $OUT/$stem/rgb.png   class=${cls:-?} ${pct:-?}%   bayer_ratio=$br neighbour_r=$nr"
done
