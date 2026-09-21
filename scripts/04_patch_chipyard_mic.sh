#!/usr/bin/env bash
# Apply patches/0012-chipyard-pdm-mic.patch to the Chipyard tree, and install the config
# that instantiates it.
#
#   scripts/04_patch_chipyard_mic.sh                  apply if not already applied
#   scripts/04_patch_chipyard_mic.sh --check          report only, exit 1 if unpatched
#   scripts/04_patch_chipyard_mic.sh --revert         reverse-apply the patch
#   scripts/04_patch_chipyard_mic.sh --install-config copy PynqZ2Configs.scala into the tree
#
# The number is arbitrary and the company it keeps is not: this belongs beside
# 07_patch_rocketchip.sh and 09_patch_rocket_pext.sh, but 10 and 11 are labs, so it sits in
# the free part of the setup band instead.
#
# WHY IT EXISTS.  $CHIPYARD_DIR is a SHARED checkout that other projects' working
# bitstreams are built from, so nothing is edited in it directly -- the change lives in
# patches/ and is applied from here, exactly as 06/07/09 do.
#
# WHAT IT CHANGES -- four files in the chipyard generator, and nothing else:
#
#   generators/chipyard/src/main/scala/pdmmic/PdmMic.scala   NEW.  PdmMicParams/PdmMicKey,
#       a TLRegisterNode wrapper around the pdm_mic_core BlackBox, CanHavePeripheryPdmMic,
#       and the WithPdmMic fragment.
#   .../DigitalTop.scala          one line: mix in pdmmic.CanHavePeripheryPdmMic
#   .../iobinders/Ports.scala     three lines: case class PdmMicPort
#   .../iobinders/IOBinders.scala WithPdmMicPunchthrough, modelled on WithOspiPunchthrough
#
# A config that does not set PdmMicKey is unaffected, and that is MEASURED rather than
# asserted: re-elaborating PynqZ2RocketBigLittlePextTacitConfig with this patch in place
# produces 506 generated files that are byte-identical to the pre-patch bundle once the
# FIRRTL source-location comments (@[IOBinders.scala:432] -> :447, a pure line-number
# shift from the fifteen lines inserted above) are stripped.  The recipe is in
# fpga/pynq-z2/docs/MICROPHONE.md section 9.2; re-run it after touching this patch.
#
# THE VERILOG IS NOT IN THIS PATCH.  pdm_mic_core is a plain BlackBox -- a FIRRTL
# extmodule -- so Chipyard emits the instantiation and not the module.  The module stays in
# fpga/pynq-z2/src/, which is what sim/run_pdm_sim.sh tests and what tcl/build_rocket.tcl
# adds to the Vivado project.  One copy, not three.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=apply
case "${1-}" in
  --check)          MODE=check ;;
  --revert)         MODE=revert ;;
  --install-config) MODE=config ;;
  -h|--help)        sed -n '2,12p' "$0"; exit 0 ;;
  "")               ;;
  *)                die "unknown argument: $1" ;;
esac

PATCH="$IISWC_ROOT/patches/0012-chipyard-pdm-mic.patch"
CFG_SRC="$IISWC_ROOT/fpga/pynq-z2/chipyard/PynqZ2Configs.scala"
CFG_DST_REL="generators/chipyard/src/main/scala/config/PynqZ2Configs.scala"

[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set.
    This step needs a real Chipyard tree -- see env.sh and docs/REPRODUCING.md. The
    bitstream itself does NOT: the generated Verilog is vendored in
    fpga/pynq-z2/chipyard/gensrc/PynqZ2RocketBigLittlePextTacitMicConfig.tar.gz and
    unpacked by scripts/08_gensrc.sh."
[ -d "$CHIPYARD_DIR" ] || die "CHIPYARD_DIR=$CHIPYARD_DIR does not exist"
[ -f "$PATCH" ] || die "missing $PATCH"
git -C "$CHIPYARD_DIR" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$CHIPYARD_DIR is not a git checkout -- cannot apply patches safely"

install_config () {
  local dst="$CHIPYARD_DIR/$CFG_DST_REL"
  if [ -f "$dst" ] && cmp -s "$CFG_SRC" "$dst"; then
    info "config already installed and identical ($CFG_DST_REL)"
  else
    cp "$CFG_SRC" "$dst"
    info "installed $CFG_DST_REL"
  fi
}

# `git apply --reverse --check` succeeds only if the patch is already in. Note the
# ABSOLUTE path: git resolves a relative one against the repo it is operating on, which is
# not this one, and the check then silently reports "not applied" for a patched tree.
applied () { git -C "$CHIPYARD_DIR" apply --reverse --check "$PATCH" 2>/dev/null; }

case "$MODE" in
  check)
    if applied; then
      info "chipyard PDM mic: already patched"
      if cmp -s "$CFG_SRC" "$CHIPYARD_DIR/$CFG_DST_REL"; then
        info "chipyard PDM mic: config installed and identical"
        exit 0
      fi
      warn "chipyard PDM mic: PATCHED but PynqZ2Configs.scala differs -- run --install-config"
      exit 1
    fi
    warn "chipyard PDM mic: NOT patched -- run scripts/04_patch_chipyard_mic.sh"
    exit 1
    ;;
  revert)
    step "reverting the chipyard PDM mic patch"
    applied || die "not applied -- nothing to revert"
    git -C "$CHIPYARD_DIR" apply --reverse "$PATCH"
    info "reverted. PynqZ2Configs.scala is left alone; it is this repo's file."
    exit 0
    ;;
  config)
    step "installing PynqZ2Configs.scala into $CHIPYARD_DIR"
    install_config
    exit 0
    ;;
esac

step "Chipyard PDM microphone patch  ($CHIPYARD_DIR)"
if applied; then
  info "already patched"
else
  git -C "$CHIPYARD_DIR" apply --check "$PATCH" || die "patch does not apply cleanly: $PATCH
    The Chipyard tree is at a revision this patch was not made against, or it carries
    local edits to the four files above. Check: git -C $CHIPYARD_DIR status"
  git -C "$CHIPYARD_DIR" apply "$PATCH"
  info "applied $(basename "$PATCH")"
fi
install_config
info "  generators/chipyard/.../pdmmic/PdmMic.scala   the peripheral"
info "  generators/chipyard/.../DigitalTop.scala      mixed in"
info "  generators/chipyard/.../iobinders/*.scala     PdmMicPort + WithPdmMicPunchthrough"
info ""
info "Next: elaborate and vendor --"
info "  cd \$CHIPYARD_DIR && source env.sh"
info "  make -C sims/verilator CONFIG=PynqZ2RocketBigLittlePextTacitMicConfig verilog"
info "  scripts/08_gensrc.sh --pack PynqZ2RocketBigLittlePextTacitMicConfig"
