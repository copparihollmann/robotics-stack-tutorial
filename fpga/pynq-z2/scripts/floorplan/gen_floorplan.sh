#!/usr/bin/env bash
# Extract and plot the post-route floorplan for a PYNQ bitstream.
#
#   scripts/floorplan/gen_floorplan.sh [build_dir] [outdir]
#
# Defaults to the fullest build (dual core + P-ext + mic). Needs Vivado for the extract
# step only; re-plotting from an existing extract needs just python3 + matplotlib, which
# is why the extractor output is committed alongside the PNG.
#
#   --plot-only   skip Vivado and re-render from the committed extract
#
# Vivado is a shared resource on this machine. `open_checkpoint` on a xc7z020 is light
# next to a place-and-route, but this still refuses to start if a build is running unless
# you pass --force, because a bitstream build is usually the thing you care about more.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"          # fpga/pynq-z2

VIVADO="${VIVADO:-vivado}"   # override VIVADO= if it is not on PATH
PLOT_ONLY=0; FORCE=0; pos=()
for a in "$@"; do
  case "$a" in
    --plot-only) PLOT_ONLY=1 ;;
    --force)     FORCE=1 ;;
    -*)          echo "unknown option: $a" >&2; exit 1 ;;
    *)           pos+=("$a") ;;
  esac
done
BUILD="${pos[0]:-$root/build_rocket_micrgb_z1}"
OUT="${pos[1]:-$root/docs/floorplan}"

mkdir -p "$OUT"

# ABSOLUTE from here on. The extract runs inside its own mktemp working directory (see
# below), so a relative BUILD or OUT taken from the caller's cwd resolves against the temp
# dir instead -- Vivado then cannot open the checkpoint, and the run below used to swallow
# that and re-plot the PREVIOUS extract, reporting success for numbers that never moved.
BUILD="$(cd "$(dirname "$BUILD")" && pwd)/$(basename "$BUILD")"
OUT="$(cd "$OUT" && pwd)"

if [ "$PLOT_ONLY" -eq 0 ]; then
  DCP="$BUILD/post_route.dcp"
  [ -f "$DCP" ] || { echo "no post-route checkpoint: $DCP" >&2; exit 1; }
  [ -x "$VIVADO" ] || { echo "vivado not found: $VIVADO  (use --plot-only to re-render)" >&2; exit 1; }

  if [ "$FORCE" -eq 0 ] && pgrep -f 'bin/vivado' >/dev/null 2>&1; then
    echo "Vivado is already running on this machine. Re-run with --force to extract anyway," >&2
    echo "or with --plot-only to re-render from the committed extract." >&2
    exit 2
  fi

  # Its own working directory, so the .Xil scratch never lands in the repo or collides
  # with a concurrent build's.
  work="$(mktemp -d "${TMPDIR:-/tmp}/floorplan.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  echo "==> extracting from $DCP"
  # The extract MUST be allowed to fail loudly. `| grep ... || true` hid a Vivado that
  # never opened the checkpoint, and the plot step below happily re-rendered the stale
  # CSV -- a floorplan that says it is current and is not. Keep the exit status.
  elog="$work/extract.log"
  if ! ( cd "$work" && "$VIVADO" -mode batch -nojournal -nolog \
      -source "$here/extract_floorplan_zynq.tcl" \
      -tclargs "$DCP" "$OUT" ) > "$elog" 2>&1; then
    echo "extract failed -- $OUT was NOT updated. Vivado said:" >&2
    tail -30 "$elog" >&2
    exit 1
  fi
  grep -E '^(====|----)' "$elog" || true
  grep -q "EXTRACT DONE" "$elog" || {
    echo "extract did not reach EXTRACT DONE -- $OUT may be stale. Vivado said:" >&2
    tail -30 "$elog" >&2
    exit 1; }
fi

echo "==> plotting"
python3 "$here/plot_floorplan_zynq.py" --indir "$OUT" --out "$OUT/floorplan.png" \
  --title-note "${TITLE_NOTE:-Zephyr SMP guest}"

# The per-block LOC dumps are large and re-derivable; keep the numbers, drop the bulk.
rm -f "$OUT"/util_*.rpt
echo "==> $OUT/floorplan.png"
