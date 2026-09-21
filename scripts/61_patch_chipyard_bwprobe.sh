#!/usr/bin/env bash
# Install the TileLink bandwidth instrument into the Chipyard tree.
#
#   scripts/61_patch_chipyard_bwprobe.sh            install (idempotent)
#   scripts/61_patch_chipyard_bwprobe.sh --check    report only, exit 1 if missing
#   scripts/61_patch_chipyard_bwprobe.sh --remove   delete it again
#
# WHY THERE IS NO PATCH FILE.  scripts/04_patch_chipyard_mic.sh carries
# patches/0012 because the PDM microphone has to be mixed into DigitalTop, declared in
# iobinders/Ports.scala and punched out in IOBinders.scala -- three edits to files the
# shared Chipyard tree owns.  BwProbe needs none of that: it attaches through a
# testchipip SubsystemInjector, which is a Config key, so the whole peripheral is ONE
# NEW FILE and zero modified ones.  There is nothing for a patch to diff against, and
# `git -C $CHIPYARD_DIR status` stays as clean as it was.
#
# That is also the strongest thing about this experiment.  The bitstream it produces
# differs from the shipped full-feature one by exactly one TLClientNode, one
# TLRegisterNode and a BlackBox -- no IOBinder, no punched-out pin, no XDC, and not one
# line of pynqz2_rocket_top.v.  Whatever the bandwidth numbers turn out to be, they are
# not confounded by a different top level.
#
# THE VERILOG IS NOT COPIED EITHER.  mbxd_dma is a plain BlackBox, so Chipyard emits the
# instantiation and not the module, and tcl/build_rocket.tcl adds
# fpga/pynq-z2/rtl_study/rocc/mbxd_dma.v to the Vivado project directly -- the same file
# the out-of-context sweep synthesised and both Verilator testbenches ran.  One copy.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=install
case "${1-}" in
  --check)   MODE=check ;;
  --remove)  MODE=remove ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  "")        ;;
  *)         die "unknown argument: $1" ;;
esac

SRC="$IISWC_ROOT/fpga/pynq-z2/chipyard/BwProbe.scala"
CFG_SRC="$IISWC_ROOT/fpga/pynq-z2/chipyard/PynqZ2Configs.scala"
DST_REL="generators/chipyard/src/main/scala/bwprobe/BwProbe.scala"
CFG_DST_REL="generators/chipyard/src/main/scala/config/PynqZ2Configs.scala"

[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set.
    This step needs a real Chipyard tree. The bitstream itself does NOT: the generated
    Verilog is vendored in fpga/pynq-z2/chipyard/gensrc/ and unpacked by
    scripts/08_gensrc.sh."
[ -d "$CHIPYARD_DIR" ] || die "CHIPYARD_DIR=$CHIPYARD_DIR does not exist"
[ -f "$SRC" ] || die "missing $SRC"

DST="$CHIPYARD_DIR/$DST_REL"
CFG_DST="$CHIPYARD_DIR/$CFG_DST_REL"

case "$MODE" in
  check)
    [ -f "$DST" ] && cmp -s "$SRC" "$DST" || { warn "bwprobe: not installed or differs"; exit 1; }
    [ -f "$CFG_DST" ] && cmp -s "$CFG_SRC" "$CFG_DST" \
      || { warn "bwprobe: PynqZ2Configs.scala differs -- run without --check"; exit 1; }
    info "bwprobe: installed and identical"
    exit 0 ;;
  remove)
    step "removing the bandwidth instrument from $CHIPYARD_DIR"
    rm -f "$DST"
    rmdir "$(dirname "$DST")" 2>/dev/null || true
    info "removed $DST_REL (PynqZ2Configs.scala left alone; it is this repo's file)"
    exit 0 ;;
esac

step "installing the TileLink bandwidth instrument into $CHIPYARD_DIR"
mkdir -p "$(dirname "$DST")"
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
  info "already installed and identical ($DST_REL)"
else
  cp "$SRC" "$DST"
  info "installed $DST_REL"
fi
if [ -f "$CFG_DST" ] && cmp -s "$CFG_SRC" "$CFG_DST"; then
  info "config already installed and identical ($CFG_DST_REL)"
else
  cp "$CFG_SRC" "$CFG_DST"
  info "installed $CFG_DST_REL"
fi
info ""
info "Next: elaborate and vendor --"
info "  cd \$CHIPYARD_DIR && source env.sh"
info "  make -C sims/verilator CONFIG=PynqZ2RocketBigLittlePextTacitMicRgbBwConfig verilog"
info "  scripts/08_gensrc.sh --pack PynqZ2RocketBigLittlePextTacitMicRgbBwConfig"
