#!/usr/bin/env bash
# Apply the TACIT encoder patches to the Chipyard tree.
#
#   scripts/03_patch_tacit.sh            apply if not already applied
#   scripts/03_patch_tacit.sh --check    report only, exit 1 if unpatched
#   scripts/03_patch_tacit.sh --revert   reverse-apply both patches
#
# It sits beside 04_patch_chipyard_mic.sh, 06_patch_zephyr.sh, 07_patch_rocketchip.sh
# and 09_patch_rocket_pext.sh; 03 is simply the free number below them.
#
# WHY IT EXISTS.  $CHIPYARD_DIR is a SHARED checkout that other projects' working
# bitstreams are built from, so nothing is edited in it directly -- the change lives in
# patches/ and is applied from here, exactly as 04/06/07/09 do.
#
# WHAT IT CHANGES -- four files, and nothing else:
#
#   generators/tacit/src/main/scala/DSCBranchPredictor.scala   TacitBPParams gains
#       `enable: Boolean = true`, which gates ELABORATION of the predictor.
#   generators/tacit/src/main/scala/TacitEncoder.scala         `bp` becomes an Option;
#       with it off, is_bp_mode is a false.B literal and is_bt_mode a true.B one, so the
#       counters, the 1024:1 read mux, the write decoder, bp_hit_count and bp_miss_flag
#       are never emitted.
#   generators/tacit/chipyard/TacitConfigs.scala               WithTacitEncoder(useBP =
#       false) by default -- which is what every PynqZ2* config picks up.
#   fpga/src/main/scala/arty200t/TacitAccelConfigs.scala       one line, so the arty200t
#       configs that share this tree keep the predictor they were measured with.
#
# WHY IT IS SAFE TO DEFAULT IT OFF.  The predictor only feeds the BrPredict path
# (bp_mode === 2). The mode register resets to 0 (BrTarget), nothing in this repo ever
# writes it, and the decoder's --br-mode defaults to 0 as well. See
# fpga/pynq-z2/docs/TACIT_AREA.md for the evidence and the measured 6,082 LUT it frees.
#
# THE PRISTINE COPIES.  Because generators/tacit is untracked, git holds no pre-patch
# copy of those three files anywhere. `<file>.bak_tacitbp` alongside each of them is that
# copy, kept deliberately. --revert does not need them (it reverse-applies the patch), but
# if the patch file is ever lost they are the only way back.
#
# THE VERIFICATION ASYMMETRY.  `generators/tacit` is UNTRACKED in the donor Chipyard
# tree, so scripts/02_verify_patches.sh cannot reconstruct it from a pinned base the way
# it does for rocket-chip and the submodules. 0031 touches the one tracked file and IS
# checked there; 0030 is checked here, by reverse-applying it, which is content-based and
# catches a hand-edit on top of the patch the same way.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=apply
case "${1-}" in
  --check)   MODE=check ;;
  --revert)  MODE=revert ;;
  -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
  "")        ;;
  *)         die "unknown argument: $1" ;;
esac

P30="$IISWC_ROOT/patches/0030-tacit-optional-branch-predictor.patch"
P31="$IISWC_ROOT/patches/0031-arty200t-tacit-keep-bp.patch"
# 0090: TraceSinkDMA's async crossing sourced from the TILE's clock domain when the tile is
# asynchronous (rocket.WithAsynchronousCDCs).  Byte-identical for synchronous tiles.
P90="$IISWC_ROOT/patches/0090-tacit-tracesinkdma-async-tile-crossing.patch"

[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set.
    This step needs a real Chipyard tree -- see env.sh and docs/REPRODUCING.md. The
    bitstream itself does NOT: the generated Verilog is vendored in
    fpga/pynq-z2/chipyard/gensrc/ and unpacked by scripts/08_gensrc.sh."
[ -d "$CHIPYARD_DIR" ] || die "CHIPYARD_DIR=$CHIPYARD_DIR does not exist"
[ -f "$P30" ] || die "missing $P30"
[ -f "$P31" ] || die "missing $P31"
[ -f "$P90" ] || die "missing $P90"
[ -d "$CHIPYARD_DIR/generators/tacit" ] || die "no generators/tacit in $CHIPYARD_DIR --
    the TACIT generator is untracked in the donor tree and has to be present already."
git -C "$CHIPYARD_DIR" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$CHIPYARD_DIR is not a git checkout -- cannot apply patches safely"

# ABSOLUTE paths: git resolves a relative one against the repo it operates on, which is
# not this one, and the check then silently reports "not applied" for a patched tree.
applied () { git -C "$CHIPYARD_DIR" apply --reverse --check "$1" 2>/dev/null; }

case "$MODE" in
  check)
    rc=0
    if applied "$P30"; then info "tacit encoder: already patched (0030)"
    else warn "tacit encoder: NOT patched -- run scripts/03_patch_tacit.sh"; rc=1; fi
    if applied "$P31"; then info "arty200t tacit configs: already patched (0031)"
    else warn "arty200t tacit configs: NOT patched (0031)"; rc=1; fi
    if applied "$P90"; then info "tacit trace sink crossing: already patched (0090)"
    else warn "tacit trace sink crossing: NOT patched (0090)"; rc=1; fi
    exit $rc
    ;;
  revert)
    step "reverting the TACIT encoder patches"
    for p in "$P90" "$P31" "$P30"; do
      if applied "$p"; then
        git -C "$CHIPYARD_DIR" apply --reverse "$p"
        info "reverted $(basename "$p")"
      else
        warn "$(basename "$p") is not applied -- nothing to revert"
      fi
    done
    info "re-elaborate and re-pack to put the predictor back in the vendored collateral."
    exit 0
    ;;
esac

step "TACIT encoder patches  ($CHIPYARD_DIR)"
for p in "$P30" "$P31" "$P90"; do
  if applied "$p"; then
    info "already applied: $(basename "$p")"
  else
    git -C "$CHIPYARD_DIR" apply --check "$p" || die "patch does not apply cleanly: $p
    The Chipyard tree carries local edits to the files above, or generators/tacit is at a
    different revision. Check: git -C $CHIPYARD_DIR status"
    git -C "$CHIPYARD_DIR" apply "$p"
    info "applied $(basename "$p")"
  fi
done
info ""
info "Next: elaborate and vendor --"
info "  cd \$CHIPYARD_DIR && source env.sh"
info "  make -C sims/verilator CONFIG=PynqZ2RocketTacitConfig verilog"
info "  scripts/08_gensrc.sh --pack PynqZ2RocketTacitConfig"
