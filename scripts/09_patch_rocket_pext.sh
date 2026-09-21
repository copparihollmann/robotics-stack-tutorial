#!/usr/bin/env bash
# Apply patches/0008-rocket-pext-alu.patch to the Chipyard tree's rocket-chip generator,
# and install the config that turns the extension on for hart 0.
#
#   scripts/09_patch_rocket_pext.sh                 apply if not already applied
#   scripts/09_patch_rocket_pext.sh --check         report only, exit 1 if unpatched
#   scripts/09_patch_rocket_pext.sh --revert        restore the .bak_pext files
#   scripts/09_patch_rocket_pext.sh --install-config  copy PynqZ2Configs.scala into the tree
#   scripts/09_patch_rocket_pext.sh --verify        THE ACCEPTANCE TEST: elaborate the
#                                                   UNPATCHED baseline config with the patch
#                                                   in place and diff the generated Verilog
#                                                   against a pre-patch snapshot
#
# WHY THIS EXISTS, AND WHY IT IS SEPARATE FROM 07_patch_rocketchip.sh
#
# $CHIPYARD_ROOT is a SHARED Chipyard checkout that other projects' working bitstreams are
# built from, so nothing is ever edited in it directly -- the change lives in patches/ and
# is applied from here, exactly as 06_patch_zephyr.sh and 07_patch_rocketchip.sh do.
#
# This is a SECOND rocket-chip patch and it has its own script because 07 is single-purpose:
# it has one marker (the mcycle one), and when that marker is present it exits early without
# looking at anything else. Note the filename too: 07 globs patches/*-rocketchip-*.patch, and
# this patch is deliberately named *-rocket-* so that glob does NOT pick it up. The two
# patches are independent and either can be applied without the other.
#
# WHAT IT CHANGES: four files in the rocket-chip generator, adding MBP -- four packed-SIMD
# instructions in custom-0, integrated into Rocket's ALU, enabled per tile. A config that
# does not set usePExt is unaffected; --verify is the measurement that says so rather than
# the assertion.
#
# THIS DOES NOT REBUILD ANYTHING. Re-elaborate, then re-vendor:
#   cd $CHIPYARD_DIR && source env.sh
#   make -C sims/verilator CONFIG=PynqZ2RocketBigLittlePextTacitConfig verilog
#   scripts/08_gensrc.sh --pack PynqZ2RocketBigLittlePextTacitConfig
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=apply
case "${1-}" in
  --check)          MODE=check ;;
  --revert)         MODE=revert ;;
  --install-config) MODE=install_config ;;
  --verify)         MODE=verify ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

RC="$CHIPYARD_ROOT/generators/rocket-chip"
PATCH="$IISWC_ROOT/patches/0008-rocket-pext-alu.patch"
CONFIG_SRC="$IISWC_ROOT/fpga/pynq-z2/chipyard/PynqZ2Configs.scala"
CONFIG_DST="$CHIPYARD_ROOT/generators/chipyard/src/main/scala/config/PynqZ2Configs.scala"
BASE_CONFIG=PynqZ2RocketBigLittleTacitConfig
PEXT_CONFIG=PynqZ2RocketBigLittlePextTacitConfig

TARGETS="src/main/scala/tile/Core.scala
src/main/scala/rocket/ALU.scala
src/main/scala/rocket/IDecode.scala
src/main/scala/rocket/RocketCore.scala"

# The marker: a string the patch introduces, unique to it. Present => already applied.
MARKER='MBP packed SIMD is defined on RV64 only'
MARKER_FILE="$RC/src/main/scala/rocket/ALU.scala"

[ -n "${CHIPYARD_ROOT:-}" ] || die "CHIPYARD_DIR is not set.
    This script patches a Chipyard tree, so it needs one:  export CHIPYARD_DIR=/path/to/chipyard
    You only need a Chipyard install to CHANGE the SoC config. Building a bitstream from a
    pinned config uses the generated Verilog vendored in this repo -- scripts/08_gensrc.sh."
[ -d "$RC" ] || die "no rocket-chip generator at $RC -- is $CHIPYARD_ROOT really a Chipyard tree?"
need_file "$PATCH"

applied=0
grep -q "$MARKER" "$MARKER_FILE" 2>/dev/null && applied=1

# ------------------------------------------------------------------ config ----
install_config() {
  need_file "$CONFIG_SRC"
  [ -d "$(dirname "$CONFIG_DST")" ] || die "no chipyard config directory at $(dirname "$CONFIG_DST")"
  if cmp -s "$CONFIG_SRC" "$CONFIG_DST"; then
    info "PynqZ2Configs.scala already matches this repo's copy"
    return 0
  fi
  [ -f "$CONFIG_DST.bak_pext" ] || { cp "$CONFIG_DST" "$CONFIG_DST.bak_pext" 2>/dev/null || true; }
  cp "$CONFIG_SRC" "$CONFIG_DST"
  info "installed $CONFIG_DST"
  info "  adds WithPExtOnTiles and $PEXT_CONFIG; the existing configs are untouched"
}

# ------------------------------------------------------------------ modes ----
case "$MODE" in
install_config)
  step "install PynqZ2Configs.scala"
  install_config
  exit 0
  ;;

revert)
  step "rocket-chip P-ext: revert  ($RC)"
  [ "$applied" = 1 ] || { info "not patched -- nothing to do"; exit 0; }
  for t in $TARGETS; do
    need_file "$RC/$t.bak_pext" "the backup is gone; recover with: git -C $RC checkout $t
    (NOTE: that would also drop any OTHER local edits this shared tree carries -- and it
     carries several)"
  done
  for t in $TARGETS; do cp "$RC/$t.bak_pext" "$RC/$t"; info "restored $t"; done
  grep -q "$MARKER" "$MARKER_FILE" && die "revert did not take -- $MARKER_FILE still carries the marker"
  warn "the generated Verilog and anything built from it are now stale -- re-elaborate"
  exit 0
  ;;

check)
  if [ "$applied" = 1 ]; then
    info "rocket-chip P-ext: already patched (marker present in rocket/ALU.scala)"
    cmp -s "$CONFIG_SRC" "$CONFIG_DST" \
      || warn "but PynqZ2Configs.scala in the tree differs from this repo's copy
    run: scripts/09_patch_rocket_pext.sh --install-config"
    exit 0
  fi
  warn "rocket-chip P-ext: NOT patched -- run scripts/09_patch_rocket_pext.sh"
  exit 1
  ;;

verify)
  # THE ACCEPTANCE TEST FOR THE PATCH ITSELF.
  #
  # An earlier agent declared a generator patch "layout-identical by construction" when it
  # had silently dropped a register's write path. So this does not reason about the patch,
  # it elaborates the BASELINE config -- the one that does NOT set usePExt, and which two
  # tracked bitstreams are built from -- with the patch reverted and again with it applied,
  # and diffs every generated file.
  #
  # TWO THINGS HAVE TO STAND DOWN TOGETHER, and finding that out the hard way is why the
  # restore is a trap and not a line at the end. Reverting the generator alone leaves
  # PynqZ2Configs.scala naming RocketCoreParams.usePExt, which then does not exist, and the
  # whole Scala build fails -- leaving the SHARED tree reverted. So the config is truncated
  # at its MBP-PEXT-CONFIG-BEGIN sentinel for the duration, and an EXIT trap puts both back
  # however this ends, including on Ctrl-C.
  step "patch acceptance: elaborate $BASE_CONFIG before and after"
  need_file "$RC/src/main/scala/rocket/ALU.scala.bak_pext" "run the apply mode first"
  need_file "$CONFIG_DST" "run scripts/09_patch_rocket_pext.sh --install-config first"
  grep -q 'MBP-PEXT-CONFIG-BEGIN' "$CONFIG_DST" \
    || die "$CONFIG_DST has no MBP-PEXT-CONFIG-BEGIN sentinel -- it is not this repo's copy"

  GS="$CHIPYARD_ROOT/sims/verilator/generated-src/chipyard.harness.TestHarness.$BASE_CONFIG/gen-collateral"
  WORK="$(mktemp -d)"
  cp "$CONFIG_DST" "$WORK/PynqZ2Configs.scala.keep"

  verify_restore() {
    local rc_code=$?
    cp "$WORK/PynqZ2Configs.scala.keep" "$CONFIG_DST" 2>/dev/null || true
    if ! grep -q "$MARKER" "$MARKER_FILE" 2>/dev/null; then
      git -C "$RC" apply "$PATCH" 2>/dev/null \
        && info "restored: patch re-applied, config restored" \
        || warn "COULD NOT RE-APPLY THE PATCH -- the shared tree is left reverted.
    Fix by hand:  git -C $RC apply $PATCH"
    else
      info "restored: config put back"
    fi
    rm -rf "$WORK"
    return $rc_code
  }
  trap verify_restore EXIT

  elaborate() {
    ( set +u +e
      cd "$CHIPYARD_ROOT" && . ./env.sh >/dev/null 2>&1
      make -C sims/verilator CONFIG="$BASE_CONFIG" verilog ) >"$WORK/elab.log" 2>&1 \
      || { tail -25 "$WORK/elab.log"; die "elaboration failed"; }
  }

  info "standing the patch and the P-ext config down; elaborating the pre-patch baseline ..."
  sed -n '1,/^\/\/ MBP-PEXT-CONFIG-BEGIN$/p' "$WORK/PynqZ2Configs.scala.keep" \
    | sed '$d' > "$CONFIG_DST"
  for t in $TARGETS; do cp "$RC/$t.bak_pext" "$RC/$t"; done
  elaborate
  cp -r "$GS" "$WORK/before"

  info "re-applying; elaborating the post-patch baseline ..."
  cp "$WORK/PynqZ2Configs.scala.keep" "$CONFIG_DST"
  git -C "$RC" apply "$PATCH" || die "patch does not apply cleanly"
  elaborate
  cp -r "$GS" "$WORK/after"

  # firtool stamps every wire with the Scala source line it came from, and this patch adds
  # comment lines, so those move. Strip them and compare the logic.
  # NOTE every `|| true` below. common.sh sets `set -euo pipefail`, and `diff` exits 1
  # when it finds differences -- which is the EXPECTED case here -- so a naked `diff | wc`
  # or `diff | head` takes the whole script down before it prints anything. That is exactly
  # how the first version of this failed: silently, with the shared tree half-reverted.
  strip='s{[ \t]*//[ \t]*\@\[[^\]]*\]}{}g; s/[ \t]+$//'
  nfiles=$(ls "$WORK/before" | wc -l)
  diff -rq "$WORK/before" "$WORK/after" > "$WORK/differ.txt" || true
  raw=$(wc -l < "$WORK/differ.txt")
  real=0
  while read -r f; do
    [ -n "$f" ] || continue
    perl -pe "$strip" "$WORK/before/$f" > "$WORK/b.txt"
    perl -pe "$strip" "$WORK/after/$f"  > "$WORK/a.txt"
    if ! diff -q "$WORK/b.txt" "$WORK/a.txt" >/dev/null; then
      real=$((real + 1))
      echo "  --- $f ---"
      diff "$WORK/b.txt" "$WORK/a.txt" | head -12 || true
    fi
  done < <(sed -nE 's/^Files .*\/([^/]+) and .* differ$/\1/p' "$WORK/differ.txt")

  info "$nfiles generated files; $raw differ byte-for-byte; $real differ after stripping firtool source-locator comments"
  if [ "$real" = 0 ]; then
    step "PASS: the patch is inert for a config that does not set usePExt"
    exit 0
  fi
  warn "the differences above are what this patch does to the baseline config."
  warn "Expected and acceptable: simulation-only \$error strings inside \`ifndef SYNTHESIS"
  warn "that quote an assertion's own source line number. Anything else is a real change."
  exit 0
  ;;
esac

# ----------------------------------------------------------------- apply ----
if [ "$applied" = 1 ]; then
  step "rocket-chip P-ext patch"
  info "already patched (marker present in rocket/ALU.scala)"
  install_config
  exit 0
fi

step "rocket-chip P-ext patch  ($RC)"
# The .bak_pext files are the revert path AND the before/after elaboration baseline for
# --verify. Take them BEFORE the patch lands, and never overwrite them on a re-run.
for t in $TARGETS; do
  need_file "$RC/$t"
  [ -f "$RC/$t.bak_pext" ] || { cp "$RC/$t" "$RC/$t.bak_pext"; info "backup: $t.bak_pext"; }
done

info "applying $(basename "$PATCH")"
git -C "$RC" apply --check "$PATCH" || die "patch does not apply cleanly: $PATCH
    The shared tree is at a revision this patch was not made against, or another agent has
    edited one of: $(echo $TARGETS | tr '\n' ' ')
    Check: git -C $RC diff $(echo $TARGETS | tr '\n' ' ')"
git -C "$RC" apply "$PATCH"
grep -q "$MARKER" "$MARKER_FILE" || die "patch applied but the marker is still missing"

install_config

info "applied 1 patch"
info "  tile/Core.scala          usePExt on CoreParams, concrete default false"
info "  rocket/RocketCore.scala  the RocketCoreParams field, PExtDecode in decode_table,"
info "                           and a require() that refuses usePExt together with RoCC"
info "  rocket/IDecode.scala     the four custom-0 BitPats and the PExtDecode table"
info "  rocket/ALU.scala         fn 20-23 and the DOT8/MAX8/QMUL/CLIP8 datapath"
warn "generated Verilog is now stale. Re-elaborate before building anything:"
warn "  cd $CHIPYARD_ROOT && source env.sh && \\"
warn "  make -C sims/verilator CONFIG=$PEXT_CONFIG verilog"
warn "then re-vendor:  scripts/08_gensrc.sh --pack $PEXT_CONFIG"
