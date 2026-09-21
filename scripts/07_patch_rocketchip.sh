#!/usr/bin/env bash
# Apply patches/*-rocketchip-*.patch to the Chipyard tree's rocket-chip generator.
#
#   scripts/07_patch_rocketchip.sh              # apply if not already applied
#   scripts/07_patch_rocketchip.sh --check      # report only, exit 1 if unpatched
#   scripts/07_patch_rocketchip.sh --revert     # restore the .bak and remove the patch
#
# WHY THIS EXISTS, AND WHY IT IS CAREFUL
#
# $CHIPYARD_ROOT is a SHARED Chipyard checkout that other projects' working bitstreams are
# built from. It is not a submodule of this repo, it is not tracked here, and an edit made
# in it is invisible to this repo's git. So the change lives in patches/ and is applied
# from here -- exactly the arrangement scripts/06_patch_zephyr.sh uses for the Zephyr
# kernel -- and it keeps a .bak so a revert is a file copy rather than a re-derivation.
#
# The patch makes Rocket's mcycle counter free-run through `wfi`. mcycle is the timebase
# TACIT stamps every packet with; upstream stops it while the hart idles, so two harts
# that idle differently cannot be put on one timeline. See
# fpga/pynq-z2/docs/TACIT_MULTICORE.md.
#
# Idempotent by construction: the marker below only exists once the patch is in, and the
# script is a no-op when it is.
#
# THIS DOES NOT REBUILD ANYTHING. The generated Verilog under
# $CHIPYARD_ROOT/sims/verilator/generated-src/ is stale the moment this lands, and the
# bitstream built from it is stale too. Re-elaborate and rebuild:
#
#   cd $CHIPYARD_ROOT && source env.sh
#   make -C sims/verilator CONFIG=PynqZ2RocketBigLittleTacitConfig verilog
#   fpga/pynq-z2/scripts/build_smp_z1.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=apply
case "${1-}" in
  --check)  MODE=check ;;
  --revert) MODE=revert ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

RC="$CHIPYARD_ROOT/generators/rocket-chip"
TARGET="$RC/src/main/scala/rocket/CSR.scala"
BAK="$TARGET.bak_mcycle_wfi"
# The marker: a comment the patch introduces, unique to it. Present => already applied.
MARKER='TACIT-MULTICORE-MCYCLE-FREE-RUN'

[ -n "$CHIPYARD_ROOT" ] || die "CHIPYARD_DIR is not set.
    This script patches a Chipyard tree, so it needs one:  export CHIPYARD_DIR=/path/to/chipyard
    You only need a Chipyard install to CHANGE the SoC config. Building a bitstream from a
    pinned config uses the generated Verilog vendored in this repo -- scripts/08_gensrc.sh.
    See docs/REPRODUCING.md."
[ -d "$CHIPYARD_ROOT" ] || die "no Chipyard tree at $CHIPYARD_ROOT -- set CHIPYARD_DIR"
[ -f "$TARGET" ]        || die "missing: $TARGET  (is $CHIPYARD_ROOT really a Chipyard tree?)"

applied=0
grep -q "$MARKER" "$TARGET" && applied=1

if [ "$MODE" = revert ]; then
  step "rocket-chip: revert  ($TARGET)"
  [ "$applied" = 1 ] || { info "not patched -- nothing to do"; exit 0; }
  need_file "$BAK" "the backup is gone; recover with: git -C $RC checkout src/main/scala/rocket/CSR.scala
    (NOTE: that would also drop any OTHER local edits this shared tree carries)"
  cp "$BAK" "$TARGET"
  grep -q "$MARKER" "$TARGET" && die "revert did not take -- $TARGET still carries $MARKER"
  info "restored from $(basename "$BAK")"
  warn "the generated Verilog and the bitstream built from it are now stale -- re-elaborate"
  exit 0
fi

if [ "$applied" = 1 ]; then
  [ "$MODE" = check ] && { info "rocket-chip: already patched ($MARKER present)"; exit 0; }
  step "rocket-chip patches"
  info "already patched ($MARKER present in $(basename "$TARGET"))"
  exit 0
fi

if [ "$MODE" = check ]; then
  warn "rocket-chip: NOT patched -- run scripts/07_patch_rocketchip.sh"
  exit 1
fi

step "rocket-chip patches  ($RC)"
# The .bak is the revert path and the before/after Verilog baseline. Take it BEFORE the
# first patch lands, and never overwrite it on a re-run (the file would already be patched).
[ -f "$BAK" ] || { cp "$TARGET" "$BAK"; info "backup: $(basename "$BAK")"; }

n=0
for p in "$IISWC_ROOT"/patches/*-rocketchip-*.patch; do
  [ -e "$p" ] || continue
  info "applying $(basename "$p")"
  # -p1 --directory so the patch's a/src/... paths land inside the generator, and
  # --check first so a partial application is impossible.
  git -C "$RC" apply --check "$p" || die "patch does not apply cleanly: $p
    The shared tree is at a revision this patch was not made against, or another agent
    has edited CSR.scala. Check: git -C $RC diff src/main/scala/rocket/CSR.scala"
  git -C "$RC" apply "$p"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no patches/*-rocketchip-*.patch found"
grep -q "$MARKER" "$TARGET" || die "patch applied but $MARKER is still missing"

info "applied $n patch(es)"
info "  rocket/CSR.scala   mcycle free-runs through wfi (reg_wfi out of the counter enable)"
info "                     mcountinhibit(0) and io.status.cease are unchanged"
warn "generated Verilog is now stale. Re-elaborate before building a bitstream:"
warn "  cd $CHIPYARD_ROOT && source env.sh && \\"
warn "  make -C sims/verilator CONFIG=PynqZ2RocketBigLittleTacitConfig verilog"
