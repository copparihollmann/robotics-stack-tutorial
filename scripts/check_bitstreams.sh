#!/usr/bin/env bash
# Is every bitstream this repo claims to ship actually here, and intact?
#
#   scripts/check_bitstreams.sh              # report; exit 1 if anything required is missing or wrong
#   scripts/check_bitstreams.sh --all        # also require the ones marked 'untracked'
#   scripts/check_bitstreams.sh --write      # regenerate fpga/pynq-z2/bitstreams.csv md5/bytes from disk
#
# WHY THIS EXISTS.  scripts/02_verify_patches.sh does this for the patch series: it does not
# grep for a marker, it reconstructs and compares.  Nothing did it for bitstreams, and the
# bitstream is the one artefact a tutorial attendee cannot regenerate -- no Vivado, no
# Chipyard, no licence.  Before this, a missing .bit produced "build it with
# fpga/pynq-z2/scripts/build_pext_z1.sh" (advice for someone who is not going to) and a
# CORRUPT or SUBSTITUTED .bit produced no message at all: the labs never hashed the file they
# were about to download into the PL.
#
# Rows marked 'git' are tracked and a clone has them; those are required by default.  Rows
# marked 'untracked' live on the build host and travel on the SD card or in the release
# tarball -- they are reported but not required unless --all, and $IISWC_BIT_DIR and
# /opt/iiswc/bit are searched for them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$IISWC_ROOT/scripts/lib/bitstream_id.sh"

REQUIRE_ALL=0; WRITE=0
for a in "$@"; do
  case "$a" in
    --all) REQUIRE_ALL=1 ;;
    --write) WRITE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done

MANIFEST="$BIT_MANIFEST"
need_file "$MANIFEST" "the bitstream manifest is missing"

if [ "$WRITE" = 1 ]; then
  step "rewriting md5 and bytes in $(basename "$MANIFEST") from the files on disk"
  IISWC_ROOT="$IISWC_ROOT" MANIFEST="$MANIFEST" python3 - <<'PYW'
import csv, hashlib, io, os
root = os.environ["IISWC_ROOT"]; man = os.environ["MANIFEST"]
lines = open(man).read().split("\n")
hdr = next(n for n, l in enumerate(lines) if l.startswith("file,md5"))
out = lines[:hdr + 1]
changed = 0
for row in csv.reader(lines[hdr + 1:]):
    if not row:
        continue
    p = os.path.join(root, row[0])
    if os.path.exists(p):
        b = open(p, "rb").read()
        md5, n = hashlib.md5(b).hexdigest(), str(len(b))
        if (row[1], row[2]) != (md5, n):
            print("    update: %s  %s -> %s" % (row[0], row[1][:8] or "(new)", md5[:8]))
            changed += 1
        row[1], row[2] = md5, n
    else:
        print("    skip (absent, row left as written): %s" % row[0])
    buf = io.StringIO(); csv.writer(buf, lineterminator="").writerow(row)
    out.append(buf.getvalue())
open(man, "w").write("\n".join(out) + "\n")
print("    %d row(s) changed" % changed)
PYW
  exit 0
fi

step "bitstream manifest: $MANIFEST"
fail=0; miss=0; ok=0; elsewhere=0
while IFS=, read -r f md5 bytes magic avail role; do
  case "$f" in \#*|file|"") continue ;; esac
  base="$(basename "$f")"
  path="$IISWC_ROOT/$f"
  where=""
  if [ ! -f "$path" ]; then
    for d in "${IISWC_BIT_DIR:-}" /opt/iiswc/bit; do
      if [ -n "$d" ] && [ -f "$d/$base" ]; then path="$d/$base"; where=" (from $d)"; break; fi
    done
  fi
  if [ ! -f "$path" ]; then
    if [ "$avail" = "git" ] || [ "$REQUIRE_ALL" = 1 ]; then
      printf '  \033[31mMISSING\033[0m  %-10s %s\n' "$avail" "$f"
      fail=$((fail+1))
    else
      printf '  \033[2m--     \033[0m  %-10s %s  (not on this machine; SD card / tarball)\n' "$avail" "$f"
      miss=$((miss+1))
    fi
    continue
  fi
  got="$(md5sum "$path" | cut -d' ' -f1)"
  if [ "$got" != "$md5" ]; then
    printf '  \033[31mWRONG  \033[0m  %-10s %s\n            have %s  want %s\n' "$avail" "$f" "$got" "$md5"
    fail=$((fail+1))
  else
    printf '  \033[32mok     \033[0m  %-10s %-8s %s%s\n' "$avail" "${magic:--}" "$f" "$where"
    ok=$((ok+1)); [ -n "$where" ] && elsewhere=$((elsewhere+1))
  fi
done < "$MANIFEST"

echo
info "$ok verified, $miss not required here, $fail problem(s)"
[ "$elsewhere" -gt 0 ] && info "$elsewhere resolved outside the checkout (IISWC_BIT_DIR / /opt/iiswc/bit)"
if [ "$fail" -gt 0 ]; then
  die "the bitstreams above are missing or are not the ones this repo ships.
       A bitstream you cannot verify is one the goldens in expected/ do not describe.
       See the "Bitstreams" section of README.md."
fi
step "bitstreams ok"
