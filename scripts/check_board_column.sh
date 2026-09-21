#!/usr/bin/env bash
# Refuse to let a results.csv row exist without naming the board that produced it.
#
#   scripts/check_board_column.sh                 # check the tracked results.csv
#   scripts/check_board_column.sh path/to.csv
#
# WHY A SEPARATE CHECKER.  There is no single writer to guard.  scripts/43, 45, 48, 49 and
# 51 each carry their OWN inline csv.DictWriter, host/axiceil_lab.py has another, and
# lib/bwlab.sh's bwlab_row is a sixth that the measurement labs do not actually use.  Adding
# the column and guarding one writer is therefore not enough -- that was proved on
# 2026-09-17, when scripts/43 appended 21 rows with an empty board immediately after the
# guard went into bwlab_row.
#
# So this checks the ARTEFACT rather than the code path: any writer that forgets, now or in
# future, fails here loudly instead of leaving a blank that later reads as "unknown board".
# Run it after any lab that records numbers, and before committing results.csv.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="${1:-$ROOT/fpga/pynq-z2/bwlab/results.csv}"

python3 - "$CSV" "$ROOT/fpga/pynq-z2/bwlab/boards.csv" <<'PY'
import csv, sys, collections
csvpath, boardspath = sys.argv[1], sys.argv[2]

known = set()
for line in open(boardspath):
    if line.startswith("#") or line.startswith("board,"):
        continue
    if line.strip():
        known.add(line.split(",", 1)[0].strip())

rows = list(csv.reader(open(csvpath, newline="")))
hdr, data = rows[0], rows[1:]
if "board" not in hdr:
    sys.exit("FAIL: %s has no `board` column at all." % csvpath)
bi = hdr.index("board")

blank, unknown, ragged = [], collections.Counter(), collections.Counter()
for n, r in enumerate(data, start=2):
    ragged[len(r)] += 1
    v = r[bi].strip() if len(r) > bi else ""
    if not v:
        blank.append(n)
    elif v not in known:
        unknown[v] += 1

print("%s: %d rows" % (csvpath, len(data)))
print("  by board : %s" % dict(collections.Counter(
    (r[bi] if len(r) > bi and r[bi] else "<BLANK>") for r in data)))
print("  widths   : %s" % dict(ragged))

rc = 0
if blank:
    print("\nFAIL: %d row(s) name no board -- first at CSV line %s" % (len(blank), blank[:5]))
    print("      A blank here is indistinguishable from the other board's rows for the same")
    print("      bitstream md5. Backfill them explicitly; do not leave them empty.")
    rc = 1
if unknown:
    print("\nFAIL: board name(s) not in boards.csv: %s" % dict(unknown))
    print("      Add a row to fpga/pynq-z2/bwlab/boards.csv under the docs lock.")
    rc = 1
if len(ragged) > 1:
    print("\nWARN: rows are not all the same width -- a writer is using a stale field list.")
if rc == 0:
    print("\nOK: every row names a board, and every board is registered.")
sys.exit(rc)
PY
