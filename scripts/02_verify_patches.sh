#!/usr/bin/env bash
# Verify that every patched tree is EXACTLY its pinned base plus the tracked patches.
#
# Why this exists, given that every apply site already runs `git apply --check`:
# those gates prove a patch went in. They cannot prove that nothing else did. A file
# hand-edited on top of an applied patch still passes `git apply --reverse --check`,
# still passes every marker grep in 01_doctor.sh, and still produces correct results on
# this bench -- while a fresh checkout + `git apply` produces a DIFFERENT tree. That is
# the one failure mode that invalidates a reproducibility claim without breaking
# anything locally, so it gets its own gate.
#
#   scripts/02_verify_patches.sh              verify every tree that is present
#   scripts/02_verify_patches.sh --quiet      one line per tree, detail only on failure
#   scripts/02_verify_patches.sh --strict-optional
#                                             also FAIL if an optional patch is still applied
#
# An OPTIONAL patch (written "?patches/..." below) is applied for one session and reverted in
# it, so a tree is normally without it and both states verify.  A tree that still HAS one is
# reported loudly as TEMPORARY -- a forgotten revert must not read as clean -- and with
# --strict-optional it is a failure, which is how a lock session proves it reverted.
#
# Exit 0 if every present tree reconstructs byte-for-byte. Trees that are absent
# (CHIPYARD_DIR unset, submodule not checked out) are SKIPped, never failed: most
# people running these labs have no Chipyard tree and do not need one.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

QUIET=0; STRICT_OPTIONAL=0
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    --strict-optional) STRICT_OPTIONAL=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$a" >&2; exit 2 ;;
  esac
done

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/verify-patches.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

fails=0; skips=0; okays=0; notes=0
ok()   { okays=$((okays+1)); printf '  \033[1;32mok\033[0m    %-22s %s\n' "$1" "${2-}"; }
bad()  { fails=$((fails+1)); printf '  \033[1;31mDRIFT\033[0m %-22s %s\n' "$1" "${2-}"; }
skip() { skips=$((skips+1)); [ "$QUIET" = 1 ] || printf '  \033[2mskip\033[0m  %-22s %s\n' "$1" "${2-}"; }
note() { notes=$((notes+1)); printf '  \033[1;33m--\033[0m    %-22s %s\n' "$1" "${2-}"; }
# An optional patch that is STILL APPLIED: never silently "ok".
temp() {
  if [ "$STRICT_OPTIONAL" = 1 ]; then fails=$((fails+1)); printf '  \033[1;31mTEMP\033[0m  %-22s %s\n' "$1" "${2-}"
  else notes=$((notes+1)); printf '  \033[1;33mTEMP\033[0m  %-22s %s\n' "$1" "${2-}"; fi
}

# Files a patch touches, in either format we carry: `diff --git` (0001-0003, 0005-0007,
# 0009-0012) and a plain unified diff with a prose header (0004, 0008). Both always have
# ---/+++ lines, so parse those and take the union; /dev/null sides are new files.
patch_files () {
  { sed -n 's|^--- a/||p' "$1"; sed -n 's|^+++ b/||p' "$1"; } \
    | sed 's/\t.*$//' | grep -v '^/dev/null$' | sort -u
}

# verify_tree <label> <tree dir> <base commit> <patch>...
#
# Three outcomes, and the distinction matters. Several of these patches are applied on
# demand by the lab script that needs them (0005 by the bootstrap's full-install branch,
# 0009 by Lab B8), so a PRISTINE tree is a correct state, not a broken one. Only a tree
# that is neither pristine nor exactly base+patches indicates an edit that will not
# survive a fresh checkout.
#
# A patch written "?patches/NNNN-....patch" is OPTIONAL: it is applied only for the work
# that needs it and reverted afterwards, so the tree spends most of its life without it
# (patches/0110, the W-lane port, is applied inside one chipyard-lock session and reverted
# in the same one).  The tree then has FOUR correct states, and only the fourth is a
# failure: base + every patch; base + the required patches, the optional ones absent;
# pristine; anything else.
verify_tree () {
  local label="$1" tree="$2" base="$3"; shift 3
  local work="$SCRATCH/$label" files f p

  if [ ! -d "$tree/.git" ] && [ ! -f "$tree/.git" ]; then
    skip "$label" "not a git checkout: $tree"; return 0
  fi
  if ! git -C "$tree" cat-file -e "$base^{commit}" 2>/dev/null; then
    skip "$label" "base commit $base not present in $tree"; return 0
  fi

  files="$(for p in "$@"; do patch_files "${p#\?}"; done | sort -u)"
  mkdir -p "$work/base"

  # Extract each touched file AT THE BASE. A file the patch creates does not exist there;
  # leave it absent so `git apply` has to create it, which is the real test.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if git -C "$tree" cat-file -e "$base:$f" 2>/dev/null; then
      mkdir -p "$work/base/$(dirname "$f")"
      git -C "$tree" show "$base:$f" > "$work/base/$f"
    fi
  done <<< "$files"

  cp -a "$work/base" "$work/patched"
  cp -a "$work/base" "$work/required"       # the same, minus the optional patches

  # Apply the tracked patches, in order, to the pristine extraction.
  local nopt=0 pp optnames=""
  for p in "$@"; do
    pp="${p#\?}"
    [ "$pp" = "$p" ] || { nopt=$((nopt+1)); optnames="$optnames $(basename "$pp")"; }
    if ! ( cd "$work/patched" && git apply --whitespace=nowarn "$IISWC_ROOT/$pp" ) 2>"$SCRATCH/apply.err"; then
      # Distinguish "someone committed this patch upstream in that tree" from real damage:
      # if it reverse-applies to the base, the base already contains it.
      if ( cd "$work/base" && git apply --reverse --check "$IISWC_ROOT/$pp" ) 2>/dev/null; then
        skip "$label" "$(basename "$pp") already committed at $base -- cannot verify"
        return 0
      fi
      bad "$label" "$(basename "$pp") does not apply to $(git -C "$tree" rev-parse --short "$base")"
      sed 's/^/          /' "$SCRATCH/apply.err" >&2
      return 0
    fi
    if [ "$pp" = "$p" ]; then
      ( cd "$work/required" && git apply --whitespace=nowarn "$IISWC_ROOT/$pp" ) 2>/dev/null || true
    fi
  done

  # Compare the live tree against BOTH candidates.
  local nf=0 vs_patched=0 vs_required=0 vs_base=0 ndiff=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    nf=$((nf+1))
    _same () { # _same <candidate dir>
      if [ -e "$1/$f" ] && [ -e "$tree/$f" ]; then cmp -s "$1/$f" "$tree/$f"
      elif [ ! -e "$1/$f" ] && [ ! -e "$tree/$f" ]; then return 0
      else return 1; fi
    }
    _same "$work/patched"  || { vs_patched=$((vs_patched+1)); ndiff="$ndiff $f"; }
    _same "$work/required" || vs_required=$((vs_required+1))
    _same "$work/base"     || vs_base=$((vs_base+1))
  done <<< "$files"

  local short; short="$(git -C "$tree" rev-parse --short "$base")"
  if [ "$vs_patched" -eq 0 ] && [ "$nopt" -gt 0 ]; then
    # Every patch applied, optional ones included: correct only for as long as the session
    # that applied them is running.  Loud, and a failure under --strict-optional.
    temp "$label" "$nf file(s), $# patch(es) applied, base $short -- TEMPORARY:$optnames still applied, revert before leaving the tree"
  elif [ "$vs_patched" -eq 0 ]; then
    ok "$label" "$nf file(s), $# patch(es) applied, base $short"
  elif [ "$nopt" -gt 0 ] && [ "$vs_required" -eq 0 ]; then
    # Exactly base + the required patches: the optional ones are absent, which is their
    # normal state (applied for one session and reverted).
    ok "$label" "$nf file(s), $(($# - nopt)) patch(es) applied, base $short -- $nopt optional patch(es) not applied"
  elif [ "$vs_base" -eq 0 ]; then
    # Pristine at the pin. Correct for on-demand patches; the lab that needs them applies
    # them. Reported so the state is visible, but it is not a failure.
    note "$label" "pristine at $short -- $# patch(es) not applied (applied on demand)"
  else
    bad "$label" "neither pristine nor base+patches: $vs_patched of $nf file(s) differ:$ndiff"
    for f in $ndiff; do
      [ -e "$work/patched/$f" ] && [ -e "$tree/$f" ] || continue
      printf '          \033[2m--- expected (base+patches) / +++ live: %s\033[0m\n' "$f" >&2
      # `diff` exits 1 when the files differ -- which is exactly the case we are in --
      # and lib/common.sh sets pipefail, so without `|| true` this pipeline aborts the
      # whole script under set -e, silently skipping every tree after the first drifted
      # one. That is how the chipyard entry went unchecked.
      diff -u "$work/patched/$f" "$tree/$f" | tail -n +3 | head -20 | sed 's/^/          /' >&2 || true
    done
  fi

  # NEVER return non-zero. lib/common.sh sets -e, so a non-zero return here aborts the
  # whole script at the call site -- which silently skipped every tree listed after the
  # first drifted one. Failures are recorded in `fails` by bad(); the exit status of this
  # function carries no information and must not carry consequences.
  return 0
}

# Base commit for a submodule = what the PARENT records, i.e. what a fresh
# `git submodule update --init` checks out. That, not the submodule's current HEAD, is
# the base a from-scratch reproduction starts from.
pinned () { git -C "$1" ls-tree HEAD "$2" 2>/dev/null | awk '{print $3}'; }

step "Patch fidelity (pinned base + tracked patches == working tree)"

verify_tree spike     "$IISWC_ROOT/third_party/riscv-isa-sim" \
  "$(pinned "$IISWC_ROOT" third_party/riscv-isa-sim)" \
  patches/0001-spike-tacit-mmio-remap.patch \
  patches/0006-spike-mbp-pext-insns.patch

verify_tree decoder   "$IISWC_ROOT/third_party/tacit-decoder" \
  "$(pinned "$IISWC_ROOT" third_party/tacit-decoder)" \
  patches/0002-decoder-rtl-packet-layout.patch \
  patches/0007-decoder-mbp-pext-mnemonics.patch \
  patches/0010-decoder-merged-multihart-perfetto.patch

verify_tree zcs       "$ZCS" \
  "$(pinned "$IISWC_ROOT" zephyr-chipyard-sw)" \
  patches/0005-zcs-install-conda-stray-line.patch

verify_tree modelblaster "$ZCS/modelblaster" \
  "$(pinned "$ZCS" modelblaster)" \
  patches/0009-modelblaster-pext-backend.patch \
  patches/0020-modelblaster-kws-models.patch \
  patches/0060-modelblaster-pext-pc-and-int-nonlin.patch \
  patches/0070-modelblaster-vww-models.patch \
  patches/0100-modelblaster-moonshine-ops.patch \
  patches/0102-modelblaster-roccmoon-backend.patch \
  patches/0103-modelblaster-q16-lowering.patch \
  patches/0104-modelblaster-softmax-memo.patch \
  patches/0105-modelblaster-moonshine-stem-nhwc.patch \
  patches/0106-modelblaster-softmax-memo2.patch \
  patches/0107-modelblaster-permute-block.patch \
  patches/0108-modelblaster-int8-calibration-policy.patch \
  patches/0109-modelblaster-roccmoon-layernorm-lane.patch \
  patches/0111-modelblaster-silu-cat2-memo-lut.patch \
  patches/0112-modelblaster-fused-attention.patch \
  patches/0113-modelblaster-deterministic-calib-pool.patch \
  patches/0114-modelblaster-fused-attention-codegen.patch

# Trees this repo does not pin: the only available base is their own HEAD, which is
# correct for them -- they are checked out by west / Chipyard's own flow, not by us.
verify_tree zephyr    "$ZCS/zephyr_ws/zephyr" \
  "$(git -C "$ZCS/zephyr_ws/zephyr" rev-parse HEAD 2>/dev/null || echo none)" \
  patches/0003-zephyr-startup-tacit-dma-sink.patch \
  patches/0011-zephyr-dmic-pdm-mmio.patch \
  patches/0120-zephyr-i2c-sifive-msg-concat.patch

if [ -n "${CHIPYARD_DIR:-}" ] && [ -d "$CHIPYARD_DIR" ]; then
  verify_tree rocket-chip "$CHIPYARD_DIR/generators/rocket-chip" \
    "$(git -C "$CHIPYARD_DIR/generators/rocket-chip" rev-parse HEAD 2>/dev/null || echo none)" \
    patches/0004-rocketchip-mcycle-free-run.patch \
    patches/0008-rocket-pext-alu.patch \
    patches/0091-rocketchip-cachecork-releaseack-first.patch \
    patches/0101-rocket-roccdecode-declared-opcodes.patch
  # 0030 is deliberately absent: it patches generators/tacit, which is UNTRACKED in the
  # donor Chipyard tree, so there is no pinned base to reconstruct it from. Its own apply
  # script checks it by reverse-applying (scripts/03_patch_tacit.sh --check). 0031 touches
  # the one file of that change that IS in git, so it is checked here.
  # 0090 (TraceSinkDMA's crossing for asynchronous tiles) patches generators/tacit too and
  # is treated exactly like 0030: checked by reverse-apply in scripts/03_patch_tacit.sh
  # --check.  The tacit repo's HEAD (ee95492) now CONTAINS 0030's change, so a "pinned base"
  # there would be ambiguous between with-0030 and without; reverse-apply is content-based
  # and does not care which commit the working tree sits on.
  # 0091 touches only rocket-chip (a CDE Field read inside TLCacheCork); 0092 is the one that
  # needs the rocket-chip-inclusive-cache entry below.
  # rocket-chip-inclusive-cache: 0092 (skip clean Release, a default-off CDE Field in MSHR).
  # Applied with `git -C $CHIPYARD_DIR/generators/rocket-chip-inclusive-cache apply`; the tree
  # was pristine at 8e157c8 before it.
  verify_tree inclusive-cache "$CHIPYARD_DIR/generators/rocket-chip-inclusive-cache" \
    "$(git -C "$CHIPYARD_DIR/generators/rocket-chip-inclusive-cache" rev-parse HEAD 2>/dev/null || echo none)" \
    patches/0092-inclusivecache-skip-clean-release.patch
  # 0110 (the W-lane port, MEMORY_BANDWIDTH.md 9.9) is OPTIONAL: it is applied inside one
  # chipyard-lock session, elaborated, and reverted in that same session, so the tree is
  # normally without it.  Marked "?" so both states verify and neither is a drift.
  verify_tree chipyard "$CHIPYARD_DIR" \
    "$(git -C "$CHIPYARD_DIR" rev-parse HEAD 2>/dev/null || echo none)" \
    patches/0012-chipyard-pdm-mic.patch \
    patches/0031-arty200t-tacit-keep-bp.patch \
    "?patches/0110-chipyard-wlane-port.patch"
else
  skip "rocket-chip" "CHIPYARD_DIR unset -- only needed to re-elaborate the RTL"
  skip "chipyard"    "CHIPYARD_DIR unset -- only needed to re-elaborate the RTL"
  skip "inclusive-cache" "CHIPYARD_DIR unset -- only needed to re-elaborate the RTL"
fi

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[1;32m%d tree(s) reconstruct exactly\033[0m, %d pristine or temporary, %d skipped.\n' "$okays" "$notes" "$skips"; exit 0
else
  printf '\033[1;31m%d tree(s) have drifted from base+patches, or still carry an optional patch.\033[0m\n' "$fails"
  printf 'A tree that differs will NOT reproduce from a fresh checkout. Either fold the\n'
  printf 'extra edit into the patch (git -C <tree> diff > patches/NNNN-*.patch) or revert it.\n'
  exit 1
fi
