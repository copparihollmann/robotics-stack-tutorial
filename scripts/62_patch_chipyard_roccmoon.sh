#!/usr/bin/env bash
# Install the decoupled RoCC engine (ROCC_DECOUPLED.md 8) into the Chipyard tree.
#
#   scripts/62_patch_chipyard_roccmoon.sh            install (idempotent)
#   scripts/62_patch_chipyard_roccmoon.sh --check    report only, exit 1 if anything is missing
#
# THREE THINGS, and only one of them modifies a file the Chipyard tree owns:
#   fpga/pynq-z2/chipyard/RoccMoon.scala    -> generators/chipyard/src/main/scala/roccmoon/  (new file)
#   fpga/pynq-z2/chipyard/RoccMoonWLane.scala -> the same directory, ONLY in a tree that has patches/0110's
#       chipyard.wlane (generators/chipyard/src/main/scala/wlane/WLanePort.scala); in any other tree an
#       installed copy is removed, because it references chipyard.wlane and would not compile
#   fpga/pynq-z2/chipyard/PynqZ2Configs.scala -> generators/chipyard/src/main/scala/config/  (this repo's file)
#   patches/0101-rocket-roccdecode-declared-opcodes.patch -> generators/rocket-chip          (a patch)
#
# 0101 is OPT-IN (a Field, RoCCDecodeOpcodes, that only WithRoccMoon sets), because this tree is shared and a
# change to RoCCDecode's default would change other projects' RoCC configurations.
#
# The Verilog is not copied: mbxr_engine is a plain BlackBox and tcl/build_rocket.tcl adds
# rtl_study/roccmoon/*.v to Vivado, the same files tb_mbxr checked.
#
# Hold the chipyard lock around this AND the elaboration that follows it:
#   scripts/lib/with_lock.sh chipyard bash -c 'scripts/62_patch_chipyard_roccmoon.sh && ...'
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=install
case "${1-}" in
  --check) MODE=check ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set (the bitstream itself needs only fpga/pynq-z2/chipyard/gensrc)"
SRC="$IISWC_ROOT/fpga/pynq-z2/chipyard/RoccMoon.scala"
WL_SRC="$IISWC_ROOT/fpga/pynq-z2/chipyard/RoccMoonWLane.scala"
WLC_SRC="$IISWC_ROOT/fpga/pynq-z2/chipyard/PynqZ2ConfigsWLane.scala"   # the 2b CONFIG, same rule
CFG_SRC="$IISWC_ROOT/fpga/pynq-z2/chipyard/PynqZ2Configs.scala"
PATCH="$IISWC_ROOT/patches/0101-rocket-roccdecode-declared-opcodes.patch"
DST="$CHIPYARD_DIR/generators/chipyard/src/main/scala/roccmoon/RoccMoon.scala"
WL_DST="$CHIPYARD_DIR/generators/chipyard/src/main/scala/roccmoon/RoccMoonWLane.scala"
WLC_DST="$CHIPYARD_DIR/generators/chipyard/src/main/scala/config/PynqZ2ConfigsWLane.scala"
WLANE_TREE="$CHIPYARD_DIR/generators/chipyard/src/main/scala/wlane/WLanePort.scala"   # patches/0110
CFG_DST="$CHIPYARD_DIR/generators/chipyard/src/main/scala/config/PynqZ2Configs.scala"
RC="$CHIPYARD_DIR/generators/rocket-chip"

applied () { git -C "$RC" apply --reverse --check "$PATCH" >/dev/null 2>&1; }

if [ "$MODE" = check ]; then
  rc=0
  { [ -f "$DST" ] && cmp -s "$SRC" "$DST"; } || { warn "RoccMoon.scala not installed or differs"; rc=1; }
  { [ -f "$CFG_DST" ] && cmp -s "$CFG_SRC" "$CFG_DST"; } || { warn "PynqZ2Configs.scala differs"; rc=1; }
  applied || { warn "patches/0101 not applied to rocket-chip"; rc=1; }
  if [ -f "$WLANE_TREE" ]; then
    { [ -f "$WL_DST" ] && cmp -s "$WL_SRC" "$WL_DST"; } || { warn "the tree has chipyard.wlane but RoccMoonWLane.scala is not installed or differs"; rc=1; }
    { [ -f "$WLC_DST" ] && cmp -s "$WLC_SRC" "$WLC_DST"; } || { warn "the tree has chipyard.wlane but PynqZ2ConfigsWLane.scala is not installed or differs"; rc=1; }
  else
    [ ! -e "$WL_DST" ] || { warn "RoccMoonWLane.scala is installed in a tree without chipyard.wlane (patches/0110): it will not compile"; rc=1; }
    [ ! -e "$WLC_DST" ] || { warn "PynqZ2ConfigsWLane.scala is installed in a tree without chipyard.wlane (patches/0110): NOTHING in the tree will compile"; rc=1; }
  fi
  [ $rc = 0 ] && info "roccmoon: installed, config identical, 0101 applied"
  exit $rc
fi

step "installing the decoupled RoCC engine into $CHIPYARD_DIR"
mkdir -p "$(dirname "$DST")"
cmp -s "$SRC" "$DST" 2>/dev/null && info "RoccMoon.scala already identical" || { cp "$SRC" "$DST"; info "installed roccmoon/RoccMoon.scala"; }
if [ -f "$WLANE_TREE" ]; then
  cmp -s "$WL_SRC" "$WL_DST" 2>/dev/null && info "RoccMoonWLane.scala already identical" || { cp "$WL_SRC" "$WL_DST"; info "installed roccmoon/RoccMoonWLane.scala (the tree has patches/0110)"; }
  cmp -s "$WLC_SRC" "$WLC_DST" 2>/dev/null && info "PynqZ2ConfigsWLane.scala already identical" || { cp "$WLC_SRC" "$WLC_DST"; info "installed config/PynqZ2ConfigsWLane.scala (the tree has patches/0110)"; }
elif [ -e "$WL_DST" ]; then
  rm -f "$WL_DST" "$WLC_DST"; info "removed roccmoon/RoccMoonWLane.scala and config/PynqZ2ConfigsWLane.scala: this tree has no chipyard.wlane (patches/0110)"
fi
cmp -s "$CFG_SRC" "$CFG_DST" 2>/dev/null && info "PynqZ2Configs.scala already identical" || { cp "$CFG_SRC" "$CFG_DST"; info "installed config/PynqZ2Configs.scala"; }
if applied; then
  info "patches/0101 already applied"
else
  git -C "$RC" apply --check "$PATCH" || die "patches/0101 does not apply to $RC"
  git -C "$RC" apply "$PATCH"
  info "applied patches/0101 to rocket-chip"
fi
