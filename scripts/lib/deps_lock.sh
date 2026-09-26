#!/usr/bin/env bash
# Read a pinned revision out of deps.lock -- ONE definition, checked rather than printed.
#
#   . scripts/lib/deps_lock.sh
#   rev=$(deps_pin zephyr_kernel)            # the 40-char sha, or "" if unpinned
#   deps_pin_require zephyr_kernel           # ... or die naming the key
#   deps_assert_rev <dir> <key> [<what>]     # refuse a checkout that is not at the pin
#
# WHY THIS EXISTS.  deps.lock was prose for a human and nothing read it, so every revision in
# it was documentation: B185 found the XPU-RT scheduler pinned NOWHERE machine-readable, and
# scripts/12_xpurt_coloc_sweep.sh accepting any directory with a scripts/ child -- which means
# a clone of `dev` produced numbers under the name of a revision it was not.  A pin nobody
# checks is a comment.  These three functions are what turn it into a gate.
#
# The format is deliberately the dullest thing that works: a line starting with `pin`, a key,
# and a 40-character sha, so `grep` finds it and a human reading deps.lock still sees a table.
# Short shas are REFUSED on purpose -- an abbreviation is ambiguous across repositories and
# across time, and this file's whole job is to be unambiguous.

_deps_lock_file() { printf '%s\n' "${IISWC_ROOT:?IISWC_ROOT unset -- source scripts/lib/common.sh first}/deps.lock"; }

# deps_pin <key> -> the 40-char sha on stdout, empty if the key is absent.
deps_pin() {
  local key="${1:?deps_pin needs a key}" f rev
  f="$(_deps_lock_file)"
  [ -f "$f" ] || return 0
  # Last match wins, so a correction appended later is the one that counts.
  rev="$(sed -n "s/^pin[[:space:]]\\{1,\\}${key}[[:space:]]\\{1,\\}\\([0-9a-f]\\{40\\}\\)[[:space:]]*\$/\\1/p" "$f" | tail -1)"
  printf '%s\n' "$rev"
}

# deps_pin_require <key> -> the sha, or die.
deps_pin_require() {
  local key="${1:?deps_pin_require needs a key}" rev
  rev="$(deps_pin "$key")"
  [ -n "$rev" ] || die "no machine-readable pin for '$key' in $(_deps_lock_file)
    Add a line:   pin $key <40-char sha>
    See the MACHINE-READABLE PINS block at the end of that file."
  printf '%s\n' "$rev"
}

# deps_assert_rev <checkout-dir> <key> [<human name>]
# Refuse a checkout whose HEAD is not the pinned revision.  This is the whole point: the
# failure we are preventing is SILENT -- a different revision builds and runs and produces
# numbers, and nothing in the output says which scheduler or which kernel made them.
deps_assert_rev() {
  local dir="${1:?deps_assert_rev needs a directory}" key="${2:?... and a key}" what="${3-$2}"
  local want have
  want="$(deps_pin_require "$key")"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$what: $dir is not a git checkout, so its revision cannot be verified against the
    pin ($key = ${want:0:12}).  A tarball or a copied tree cannot be checked; use a clone."
  have="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  if [ "$have" != "$want" ]; then
    die "$what is at the WRONG REVISION.
      pinned (deps.lock, pin $key):  $want
      this checkout:                 ${have:-<unknown>}
    Fix it in the checkout, not here:
      git -C $dir fetch origin && git -C $dir checkout --detach $want
    If the pin itself is what changed, update deps.lock and say so in the log entry --
    every number measured with the old revision was measured with the old revision."
  fi
  # A dirty tree is a different tree.  Say so rather than blessing the sha.
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    warn "$what is at the pinned revision $want but the working tree is DIRTY --
    tracked files are modified, so what runs is not what the pin names:
      git -C $dir status --short"
  fi
}
