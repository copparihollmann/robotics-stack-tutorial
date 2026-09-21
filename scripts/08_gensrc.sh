#!/usr/bin/env bash
# Chipyard generated Verilog: unpack the vendored collateral, or repack it from a live
# Chipyard tree.
#
#   scripts/08_gensrc.sh                    unpack every vendored config (idempotent)
#   scripts/08_gensrc.sh --unpack CONFIG    unpack one
#   scripts/08_gensrc.sh --path   CONFIG    print the CHIPYARD_GENSRC dir for CONFIG
#   scripts/08_gensrc.sh --list             what is vendored, and where it came from
#   scripts/08_gensrc.sh --pack   CONFIG    re-pack from $CHIPYARD_DIR after re-elaborating
#
# WHY THIS EXISTS
#
# A bitstream build needs the GENERATED VERILOG, not Chipyard. Chipyard itself is a
# multi-hour, tens-of-GB install that pulls a Scala toolchain, a conda env and a dozen
# generators -- and it is only needed to CHANGE the SoC configuration. Separating the two
# is what lets someone with this repo and Vivado build the same bitstream we did:
#
#   build a bitstream from a pinned config   ->  vendored collateral, ~1 MB/config, seconds
#   change the config and re-elaborate       ->  a real Chipyard install, hours
#
# WHAT IS VENDORED, AND WHAT IS NOT
#
# Only the files Vivado reads: every path listed in <CONFIG>.top.f, plus the SRAM macro
# file gen-collateral/*.top.mems.v that the mem-gen pass emits and top.f does not list.
# That is ~14 MB of SystemVerilog, ~1 MB compressed. The other ~55 MB of an elaboration
# directory -- the FIRRTL, the annotation JSON, the chisel/firtool logs, the simulation-only
# TestHarness -- is not an input to any flow here and is not carried.
#
# PROVENANCE IS PART OF THE ARTIFACT. Each bundle ships a PROVENANCE file recording the
# Chipyard revision, the rocket-chip revision, and which of the rocket-chip patches
# were in the tree at elaboration time. "Chipyard at revision X plus patches/NNNN-*.patch"
# is a statement this file has to be able to make, because two of our configs are
# elaborated from DIFFERENT patch states.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

VENDOR_DIR="$IISWC_ROOT/fpga/pynq-z2/chipyard/gensrc"
DEST_ROOT="${CHIPYARD_GENSRC_ROOT:-$IISWC_OUT/gensrc}"
PREFIX="chipyard.harness.TestHarness"

MODE=unpack_all
CFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unpack) MODE=unpack; CFG="${2:?--unpack needs a CONFIG}"; shift 2 ;;
    --pack)   MODE=pack;   CFG="${2:?--pack needs a CONFIG}";   shift 2 ;;
    --path)   MODE=path;   CFG="${2:?--path needs a CONFIG}";   shift 2 ;;
    --list)   MODE=list; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

vendored_configs() {
  for t in "$VENDOR_DIR"/*.tar.gz; do
    [ -e "$t" ] || continue
    basename "$t" .tar.gz
  done
}

# ---------------------------------------------------------------- unpack ----
# top.f carries ABSOLUTE paths into whichever tree elaborated it, so it is regenerated
# here against the unpack location. Every consumer (tcl/build_rocket.tcl, tcl/ooc_area.tcl,
# rtl_study/pext/ooc_pext.tcl) then works unchanged.
do_unpack() {
  local cfg="$1"
  local tarball="$VENDOR_DIR/$cfg.tar.gz"
  [ -f "$tarball" ] || die "no vendored collateral for $cfg
    have: $(vendored_configs | tr '\n' ' ')
    to add one: elaborate it in a Chipyard tree, then scripts/08_gensrc.sh --pack $cfg"
  local dest="$DEST_ROOT/$PREFIX.$cfg"
  local stamp="$dest/.unpacked-from"
  local want; want="$(sha256sum "$tarball" | cut -d' ' -f1)"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
    info "$cfg  already unpacked at $dest"
    return 0
  fi
  step "unpack $cfg"
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tarball" -C "$dest" --strip-components=1
  local topf="$dest/$PREFIX.$cfg.top.f"
  need_file "$topf" "bundle is missing its top.f"
  # Rewrite the basename list into absolute paths under $dest.
  awk -v d="$dest/gen-collateral" '{ print d "/" $0 }' "$topf" > "$topf.abs"
  mv "$topf.abs" "$topf"
  local n; n=$(wc -l < "$topf")
  while read -r f; do [ -f "$f" ] || die "bundle references a file it does not carry: $f"; done < "$topf"
  echo "$want" > "$stamp"
  info "$n source files + $(ls "$dest"/gen-collateral/*.top.mems.v 2>/dev/null | wc -l) SRAM macro file(s)"
  info "CHIPYARD_GENSRC=$dest"
}

# ------------------------------------------------------------------ pack ----
do_pack() {
  local cfg="$1"
  [ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set.
    Packing collateral needs a real Chipyard tree that has already elaborated $cfg:
      export CHIPYARD_DIR=/path/to/chipyard
    See fpga/pynq-z2/chipyard/README.md for how to elaborate."
  [ -d "$CHIPYARD_DIR" ] || die "CHIPYARD_DIR does not exist: $CHIPYARD_DIR"
  local src="$CHIPYARD_DIR/sims/verilator/generated-src/$PREFIX.$cfg"
  [ -d "$src" ] || die "no elaboration for $cfg at $src
    run:  cd $CHIPYARD_DIR && source env.sh && make -C sims/verilator CONFIG=$cfg verilog"
  local topf="$src/$PREFIX.$cfg.top.f"
  need_file "$topf" "elaboration produced no top.f"

  step "pack $cfg  (from $src)"
  local stage; stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  local bundle="$stage/$PREFIX.$cfg"
  mkdir -p "$bundle/gen-collateral"

  local n=0
  while read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || die "top.f lists a file that does not exist: $f"
    cp "$f" "$bundle/gen-collateral/"
    basename "$f" >> "$bundle/$PREFIX.$cfg.top.f"
    n=$((n + 1))
  done < <(tr -d '\r' < "$topf")
  [ "$n" -gt 0 ] || die "top.f is empty"

  local mems=("$src"/gen-collateral/*.top.mems.v)
  [ -e "${mems[0]}" ] || die "no *.top.mems.v in $src/gen-collateral -- the mem-gen pass did not run"
  cp "${mems[@]}" "$bundle/gen-collateral/"

  # Provenance. This is the "Chipyard at revision X plus patches/NNNN-*.patch" statement.
  #
  # Patch state is measured by REVERSE-APPLYING each patch against the tree: a patch that
  # reverses cleanly is in. That is content-based and works for any patch, unlike grepping
  # for a marker string.
  #
  # The honest limitation: it measures the tree NOW, and the elaboration happened whenever
  # it happened. If a patch file is newer than the elaboration, this bundle was almost
  # certainly produced WITHOUT it, and the line below says so. Pack immediately after
  # elaborating and the question does not arise.
  local rc="$CHIPYARD_DIR/generators/rocket-chip"
  local elab_epoch; elab_epoch=$(stat -c%Y "$topf")
  local stale_warn=""
  {
    echo "config:            $cfg"
    echo "elaborated:        $(date -Is -d "@$elab_epoch")   (mtime of the generated top.f)"
    echo "packed:            $(date -Is)"
    echo "packed_by:         scripts/08_gensrc.sh"
    echo "source_files:      $n  (+ ${#mems[@]} SRAM macro file(s))"
    echo
    echo "chipyard_remote:   $(git -C "$CHIPYARD_DIR" remote get-url origin 2>/dev/null || echo '(not a git tree)')"
    echo "chipyard_rev:      $(git -C "$CHIPYARD_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "rocketchip_rev:    $(git -C "$rc" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo
    echo "# Every patch this repo applies to the rocket-chip generator -- both the"
    echo "# *-rocketchip-* ones (scripts/07) and the *-rocket-* ones (scripts/09) -- and"
    echo "# whether each was present in the tree at PACK time (measured by reverse-applying"
    echo "# it). 'stale' means the patch file is newer than this elaboration, so the bundle"
    echo "# predates it -- re-elaborate and re-pack."
    for pf in "$IISWC_ROOT"/patches/*-rocketchip-*.patch "$IISWC_ROOT"/patches/*-rocket-*.patch; do
      [ -e "$pf" ] || continue
      local applied=no note=""
      if git -C "$rc" apply --reverse --check "$pf" >/dev/null 2>&1; then applied=yes; fi
      if [ "$(stat -c%Y "$pf")" -gt "$elab_epoch" ]; then
        note="  <-- STALE: patch file is newer than this elaboration"
        stale_warn="$stale_warn $(basename "$pf")"
      fi
      printf 'patch:             %s  sha256=%s  applied_at_pack_time=%s%s\n' \
        "$(basename "$pf")" "$(sha256sum "$pf" | cut -c1-16)" "$applied" "$note"
    done
    echo
    echo "# Uncommitted delta in the Chipyard tree at pack time. A long list here is the"
    echo "# reason a bare revision is not enough to reproduce an elaboration."
    echo "chipyard_dirty:"
    git -C "$CHIPYARD_DIR" status --short 2>/dev/null | sed 's/^/  /' | head -40
    echo "rocketchip_dirty:"
    git -C "$rc" status --short 2>/dev/null | sed 's/^/  /' | head -40
  } > "$bundle/PROVENANCE"
  [ -z "$stale_warn" ] || warn "elaboration predates patch(es):$stale_warn -- recorded in PROVENANCE"

  mkdir -p "$VENDOR_DIR"
  # Deterministic tarball: sorted, no owner/mtime noise, so re-packing an unchanged
  # elaboration produces an identical blob and git sees no diff.
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' \
      -C "$stage" -cf - "$PREFIX.$cfg" | gzip -9n > "$VENDOR_DIR/$cfg.tar.gz"
  cp "$bundle/PROVENANCE" "$VENDOR_DIR/$cfg.provenance"
  ( cd "$VENDOR_DIR" && sha256sum ./*.tar.gz > SHA256SUMS )
  info "wrote $VENDOR_DIR/$cfg.tar.gz  ($(fsize "$VENDOR_DIR/$cfg.tar.gz"))"
  info "wrote $VENDOR_DIR/$cfg.provenance"
}

case "$MODE" in
  path)
    echo "$DEST_ROOT/$PREFIX.$CFG" ;;
  list)
    step "vendored Chipyard collateral  ($VENDOR_DIR)"
    found=0
    for cfg in $(vendored_configs); do
      found=1
      printf '\n  \033[1m%s\033[0m  (%s)\n' "$cfg" "$(fsize "$VENDOR_DIR/$cfg.tar.gz")"
      # The identity lines and the patch state -- the rest of the provenance (the Chipyard
      # tree's uncommitted delta) is long and lives in the file.
      grep -E '^(elaborated|packed|source_files|chipyard_remote|chipyard_rev|rocketchip_rev|patch):' \
        "$VENDOR_DIR/$cfg.provenance" 2>/dev/null | sed 's/^/    /'
    done
    [ "$found" = 1 ] || warn "nothing vendored yet" ;;
  pack)
    do_pack "$CFG" ;;
  unpack)
    do_unpack "$CFG" ;;
  unpack_all)
    step "Chipyard generated sources -> $DEST_ROOT"
    found=0
    for cfg in $(vendored_configs); do found=1; do_unpack "$cfg"; done
    [ "$found" = 1 ] || die "nothing vendored in $VENDOR_DIR"
    step "done"
    info "point a build at one with:  export CHIPYARD_GENSRC=\$(scripts/08_gensrc.sh --path CONFIG)" ;;
esac
