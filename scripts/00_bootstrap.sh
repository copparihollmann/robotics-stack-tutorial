#!/usr/bin/env bash
# Bootstrap the Zephyr build environment inside the zephyr-chipyard-sw submodule.
#
#   scripts/00_bootstrap.sh                 # full install: conda + Zephyr SDK + submodules (~40-70 min, ~12 GB)
#   scripts/00_bootstrap.sh --modelblaster  # ... and check out ModelBlaster too (Lab B5 only)
#   scripts/00_bootstrap.sh --reuse PATH    # borrow an already-installed workspace's conda + SDK (seconds)
#
# THE FULL PATH IS THE SHIPPING PATH. It downloads and installs everything into this
# checkout -- nothing is borrowed from another directory on the machine. See
# docs/REPRODUCING.md for durations, disk, and how to verify each stage.
#
# The --reuse path is a developer convenience for machines that already carry a built
# zephyr-chipyard-sw workspace. It symlinks (never copies) the toolchain and the module
# trees, so it costs almost no disk -- but the result is NOT self-contained: the symlinks
# point outside the repo and break the moment the donor moves. The Zephyr kernel itself is
# always a real local clone, because we patch it -- symlinking it would write our edits
# into the donor's tree.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

REUSE=""
MODELBLASTER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --reuse) REUSE="${2:?--reuse needs a path}"; shift 2 ;;
    --modelblaster) MODELBLASTER=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# --- direct submodules ----------------------------------------------------------------
# A plain `git clone` leaves these empty. Initialise them here rather than making the
# reader remember a second command; NOT --recursive, because zephyr-chipyard-sw's own
# submodule list is large and is checked out selectively by its install_submodules.sh.
if [ -z "$(ls -A "$ZCS" 2>/dev/null)" ] \
   || [ -z "$(ls -A "$IISWC_ROOT/third_party/riscv-isa-sim" 2>/dev/null)" ] \
   || [ -z "$(ls -A "$IISWC_ROOT/third_party/tacit-decoder" 2>/dev/null)" ]; then
  step "Checking out submodules"
  run git -C "$IISWC_ROOT" submodule update --init
fi
[ -d "$ZCS" ] || die "submodule not checked out: $ZCS  (run: git submodule update --init)"

# --- ModelBlaster is declared with an SSH URL -------------------------------------------
# zephyr-chipyard-sw/.gitmodules points `modelblaster` at git@github.com:ucb-bar/ModelBlaster.git.
# That needs an SSH key, which a container and most fresh machines do not have -- and the
# repo is public over https. Rewrite the URL in THIS clone's config (never in the donor's
# .gitmodules, which is upstream's file). Costs nothing when the submodule is never used.
#
# Only Lab B5 (scripts/24_rocket_modelblaster.sh) needs ModelBlaster, so it stays opt-in:
# the checkout happens with --modelblaster, or later with
#   git -C zephyr-chipyard-sw submodule update --init modelblaster
if git -C "$ZCS" config -f .gitmodules --get submodule.modelblaster.url >/dev/null 2>&1; then
  MB_SSH="$(git -C "$ZCS" config -f .gitmodules --get submodule.modelblaster.url)"
  case "$MB_SSH" in
    git@github.com:*|ssh://git@github.com/*)
      MB_HTTPS="https://github.com/${MB_SSH#*github.com[:/]}"
      git -C "$ZCS" config submodule.modelblaster.url "$MB_HTTPS"
      info "modelblaster URL -> $MB_HTTPS  (was SSH; no key needed)" ;;
  esac
fi

step "Zephyr workspace: $ZCS"

if [ -n "$REUSE" ]; then
  REUSE="$(cd "$REUSE" && pwd)" || die "--reuse path does not exist"
  need_file "$REUSE/tools/miniforge3/etc/profile.d/conda.sh" "donor has no conda install"
  [ -d "$REUSE/tools/miniforge3/envs/zephyr" ] || die "donor has no 'zephyr' conda env: $REUSE"

  info "reusing toolchain from $REUSE"
  mkdir -p "$ZCS/tools"
  for link in tools/miniforge3 tools-manual; do
    tgt="$REUSE/$link"
    [ -e "$tgt" ] || { warn "donor lacks $link -- skipping"; continue; }
    if [ -L "$ZCS/$link" ]; then rm -f "$ZCS/$link"
    elif [ -e "$ZCS/$link" ]; then die "$ZCS/$link exists and is not a symlink; refusing to clobber"; fi
    ln -s "$tgt" "$ZCS/$link"
    info "  $link -> $tgt"
  done

  # The west workspace lives under zephyr_ws/. The big, never-patched trees (modules is
  # 2.4 GB) are symlinked to the donor; the KERNEL IS NOT.
  #
  # zephyr/ gets a real local clone, because we patch it -- arch/riscv/core/reset.S for
  # boot-time TACIT tracing, for one. A symlink there writes those edits straight into the
  # donor's tree, which other projects on this machine are using. Cloning from the donor is
  # a local object copy: ~4 s and 1.3 GB, against 2.4 GB of modules we do not touch.
  if [ -d "$REUSE/zephyr_ws" ]; then
    step "Linking the west workspace from the donor"
    mkdir -p "$ZCS/zephyr_ws"
    for entry in modules bootloader tools; do
      src="$REUSE/zephyr_ws/$entry"
      dst="$ZCS/zephyr_ws/$entry"
      [ -e "$src" ] || continue
      if [ -L "$dst" ]; then rm -f "$dst"
      elif [ -d "$dst" ] && [ -z "$(ls -A "$dst" 2>/dev/null)" ]; then rmdir "$dst"
      elif [ -e "$dst" ]; then warn "$dst exists and is not empty -- leaving it alone"; continue; fi
      ln -s "$src" "$dst"
      info "  zephyr_ws/$entry -> $src"
    done

    # .west is three lines of config with relative paths; own it.
    if [ -L "$ZCS/zephyr_ws/.west" ]; then rm -f "$ZCS/zephyr_ws/.west"; fi
    if [ ! -d "$ZCS/zephyr_ws/.west" ] && [ -d "$REUSE/zephyr_ws/.west" ]; then
      cp -aL "$REUSE/zephyr_ws/.west" "$ZCS/zephyr_ws/.west"
      info "  zephyr_ws/.west  (local copy)"
    fi

    if [ -L "$ZCS/zephyr_ws/zephyr" ]; then
      warn "zephyr_ws/zephyr is a symlink into the donor -- replacing with a local clone"
      rm -f "$ZCS/zephyr_ws/zephyr"
    fi
    # .git is a directory for a standalone clone and a FILE for a submodule checkout; ask
    # git rather than testing for either.
    if ! git -C "$ZCS/zephyr_ws/zephyr" rev-parse --git-dir >/dev/null 2>&1; then
      step "Cloning zephyr from the donor (local objects, seconds)"
      REV=$(git -C "$REUSE/zephyr_ws/zephyr" rev-parse HEAD)
      UPSTREAM=$(git -C "$REUSE/zephyr_ws/zephyr" remote get-url origin)
      run git clone --no-hardlinks -q "$REUSE/zephyr_ws/zephyr" "$ZCS/zephyr_ws/zephyr"
      run git -C "$ZCS/zephyr_ws/zephyr" remote set-url origin "$UPSTREAM"
      run git -C "$ZCS/zephyr_ws/zephyr" checkout -q "$REV"
      info "  zephyr_ws/zephyr  $REV  (origin: $UPSTREAM)"
    else
      info "  zephyr_ws/zephyr  already a local checkout"
    fi
    git -C "$ZCS" config submodule.zephyr_ws/zephyr.ignore all 2>/dev/null || true
  else
    step "Fetching zephyr_ws/zephyr from origin"
    run git -C "$ZCS" submodule update --init zephyr_ws/zephyr
  fi

else
  step "Full install (conda, Zephyr SDK, submodules) -- this takes a while"

  # patches/*-zcs-*.patch fix the upstream installer itself. At the pin, line 6 of
  # scripts/install_conda.sh is the literal text `scripts/install_conda.sh#` -- a comment
  # that lost its `#` -- so bash runs it as a command and the installer dies with 127
  # before it downloads anything. Nobody had hit it because every run so far reused an
  # already-installed workspace. Same arrangement as every other patch here: it lives in
  # patches/, it is applied from a script, and it is idempotent.
  for p in "$IISWC_ROOT"/patches/*-zcs-*.patch; do
    [ -e "$p" ] || continue
    if git -C "$ZCS" apply --reverse --check "$p" >/dev/null 2>&1; then
      info "already applied: $(basename "$p")"
    else
      git -C "$ZCS" apply --check "$p" 2>/dev/null \
        || die "patch does not apply cleanly: $p
    zephyr-chipyard-sw is at a revision this patch was not made against.
    Pin in deps.lock: $(git -C "$ZCS" rev-parse --short HEAD 2>/dev/null)"
      run git -C "$ZCS" apply "$p"
    fi
  done

  # These are the upstream scripts; we call them rather than reimplement them so the
  # tutorial tracks whatever zephyr-chipyard-sw does.
  #
  # install_conda.sh must be SOURCED (it says so, and it leaves conda on PATH for the two
  # that follow). It deliberately does not set -e, so run it in a subshell that does not
  # either -- otherwise its own tolerated failures abort the bootstrap.
  ( cd "$ZCS" && set +e; . scripts/install_conda.sh )
  need_file "$ZCS/tools/miniforge3/etc/profile.d/conda.sh" \
    "install_conda.sh left no conda install -- see the output above"

  ( cd "$ZCS" && bash scripts/install_submodules.sh )
  [ -d "$ZCS/tools/miniforge3/envs/zephyr" ] \
    || die "install_submodules.sh did not create the 'zephyr' conda env
    log: $ZCS/.install_submodules.log"

  ( cd "$ZCS" && bash scripts/install_toolchain_sdk.sh )
  [ -d "$ZCS/tools-manual" ] || die "install_toolchain_sdk.sh installed no SDK"
fi

# The kernel checkout is not tracked by this repo, so everything we need from it lives in
# patches/ and is applied from here. Idempotent -- safe on a tree that is already patched.
run "$IISWC_ROOT/scripts/06_patch_zephyr.sh"

if [ "$MODELBLASTER" = 1 ]; then
  step "ModelBlaster  (Lab B5 only)"
  run git -C "$ZCS" submodule update --init modelblaster
fi

# The FPGA flows read generated Verilog, not Chipyard. Unpacking the vendored collateral
# costs a second and removes the only remaining reason to have a Chipyard tree on hand.
if [ -n "$(ls -A "$IISWC_ROOT/fpga/pynq-z2/chipyard/gensrc" 2>/dev/null)" ]; then
  run "$IISWC_ROOT/scripts/08_gensrc.sh"
fi

step "Bootstrap done"
info "next:  scripts/01_doctor.sh"
