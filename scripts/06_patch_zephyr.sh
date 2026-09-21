#!/usr/bin/env bash
# Apply patches/*-zephyr-*.patch to the Zephyr kernel checkout.
#
#   scripts/06_patch_zephyr.sh              # apply if not already applied
#   scripts/06_patch_zephyr.sh --check      # report only, exit 1 if unpatched
#
# The kernel lives at $ZCS/zephyr_ws/zephyr. It is a git checkout that THIS repo does not
# track (the gitlink carries `ignore = all`), so an edit made there is invisible to git and
# does not survive a re-clone. Anything we need from it therefore lives in patches/ and is
# applied from here, the same way scripts/05_build_tacit_tools.sh applies the spike and
# decoder patches.
#
# Idempotent by construction: the marker below only exists once the patch is in, and the
# script is a no-op when it is. scripts/00_bootstrap.sh and scripts/23_rocket_tacit_boot.sh
# both call it, so a fresh clone and an edit-run loop both end up patched without anyone
# having to remember.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CHECK_ONLY=0
case "${1-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

ZEPHYR="$ZCS/zephyr_ws/zephyr"
# The marker: the Kconfig symbol patches/0003 introduces. Present => 0003 is applied.
MARKER_FILE="$ZEPHYR/arch/riscv/core/reset.S"
MARKER='CONFIG_STARTUP_TACIT_SINK_DMA_ADDR'
# Every patch that must be present for the tree to be considered patched, as
# marker-file:marker-string pairs. One line per patch. A tree that has some but not all
# of these is PARTIALLY patched, which is what happens when a patch is added to this
# repo after somebody's tree was already patched -- and is exactly the state the single
# early-exit below used to report as "already patched" while silently leaving the new
# patch out. The loop applies whatever is missing and skips whatever is there.
MARKERS="\
arch/riscv/core/reset.S:CONFIG_STARTUP_TACIT_SINK_DMA_ADDR
drivers/audio/dmic_pdm_mmio.c:DT_DRV_COMPAT iiswc_pdm_mic
drivers/i2c/i2c_sifive.c:One address phase per TRANSFER"

all_markers_present () {
  local line f m
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line%%:*}"; m="${line#*:}"
    grep -q "$m" "$ZEPHYR/$f" 2>/dev/null || return 1
  done <<< "$MARKERS"
  return 0
}

[ -d "$ZEPHYR" ] || die "no Zephyr kernel at $ZEPHYR -- run scripts/00_bootstrap.sh"

# Refuse to write into somebody else's tree. scripts/00_bootstrap.sh always makes this a
# real local clone precisely so that these patches have somewhere safe to land; if it is
# still a symlink into a donor workspace, patching it would edit a tree shared with other
# projects on this machine.
if [ -L "$ZCS/zephyr_ws/zephyr" ]; then
  die "$ZCS/zephyr_ws/zephyr is a symlink into a donor workspace -- refusing to patch it.
    Re-run scripts/00_bootstrap.sh --reuse <donor> to replace it with a local clone."
fi
# `-d .git` is wrong here. The full scripts/00_bootstrap.sh path gets this kernel via
# `git submodule update --init zephyr_ws/zephyr`, and a submodule's .git is a FILE holding
# a gitdir: pointer, not a directory -- so the directory test rejected a perfectly good
# checkout and the first from-scratch bootstrap died right here. Ask git instead.
git -C "$ZEPHYR" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$ZEPHYR is not a git checkout -- cannot apply patches safely"

if all_markers_present; then
  [ "$CHECK_ONLY" = 1 ] && { info "zephyr: already patched"; exit 0; }
  step "Zephyr kernel patches"
  info "already patched (every marker present)"
  exit 0
fi

if [ "$CHECK_ONLY" = 1 ]; then
  warn "zephyr: NOT patched -- run scripts/06_patch_zephyr.sh"
  exit 1
fi

step "Zephyr kernel patches  ($ZEPHYR)"
applied=0
present=0
for p in "$IISWC_ROOT"/patches/*-zephyr-*.patch; do
  [ -e "$p" ] || continue
  # Already in? `git apply --reverse --check` succeeds only if the patch is applied.
  if git -C "$ZEPHYR" apply --reverse --check "$p" 2>/dev/null; then
    info "already applied: $(basename "$p")"
    present=$((present + 1))
    continue
  fi
  info "applying $(basename "$p")"
  git -C "$ZEPHYR" apply --check "$p" || die "patch does not apply cleanly: $p
    The kernel checkout is at a revision this patch was not made against, or it carries
    local edits. Check: git -C $ZEPHYR status"
  git -C "$ZEPHYR" apply "$p"
  applied=$((applied + 1))
done
[ $((applied + present)) -gt 0 ] || die "no patches/*-zephyr-*.patch found"
all_markers_present || die "patches applied but a marker is still missing -- check $MARKERS"
info "applied $applied patch(es), $present already present"
info "  arch/riscv/core/reset.S    program the TACIT sink + target before enable"
info "  soc/.../Kconfig.soc        CONFIG_STARTUP_TACIT_{TARGET,SINK_DMA_ADDR,SINK_DMA_SHIFT}"
info "  drivers/audio/dmic_pdm_mmio.c   Zephyr DMIC driver for the PL microphone"
info "  drivers/i2c/i2c_sifive.c   one address phase per I2C transfer, not per message"
