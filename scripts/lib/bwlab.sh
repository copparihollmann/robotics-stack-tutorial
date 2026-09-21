# SPDX-License-Identifier: Apache-2.0
#
# The accumulating bandwidth record.  ONE file, appended to and never rewritten, across
# every bitstream and every session -- out/bwlab/results.csv.
#
# WHY IT IS A REQUIREMENT AND NOT A NICETY.  This campaign builds several bitstreams and
# measures each of them at several working-set sizes and several outstanding counts.  A
# number quoted in a document with no row behind it cannot be re-checked, and a
# disappointing final number with no per-lever rows cannot be attributed.  So every
# figure that appears in MEMORY_BANDWIDTH.md is one line of this file, and the
# SIMULATED values live in the same table tagged `sim` so sim-against-silicon divergence
# is visible at a glance rather than argued in prose.
#
# IT LIVES IN THE TREE, NOT IN out/.  out/ is gitignored -- it is where run artifacts go
# and it is wiped by every lab that writes to it.  The progression across bitstreams IS
# the evidence here, so the record is a tracked file that grows by append and is committed
# as it grows.
#
#   bwlab_init                            create the file with its header if absent
#   bwlab_row <field>=<value> ...         append one row; unknown fields are rejected
#
# Fields (order is fixed by the header; anything not given is left empty):
#   timestamp bitstream_md5 soc_magic config fclk_core_mhz fclk_mem_mhz n_hp_ports
#   outstanding burst_bytes working_set_bytes level direction bytes_moved cycles
#   bytes_per_cycle mb_per_s lut ff bram dsp wns_ns whs_ns source notes
#
# `source` is `silicon` or `sim`; `level` is L1, L2 or DRAM.
BWLAB_CSV="${BWLAB_CSV:-$IISWC_ROOT/fpga/pynq-z2/bwlab/results.csv}"
# The full header, used ONLY to create the file if it does not exist.  When the file exists
# the header IN THE FILE is authoritative -- see bwlab_row.  This list used to be 24 fields
# while the header had grown to 30, so bwlab_row wrote 24-field rows into a 30-column file
# (949 rows are 24 wide, 1269 are 30).  Nothing was misread, because a short CSV row reads as
# an empty tail -- but appending one more column would have put its value under `burst_beats`
# for half the writers.  Reading the header is what makes adding a column safe.
BWLAB_FIELDS="timestamp bitstream_md5 soc_magic config fclk_core_mhz fclk_mem_mhz n_hp_ports outstanding burst_bytes working_set_bytes level direction bytes_moved cycles bytes_per_cycle mb_per_s lut ff bram dsp wns_ns whs_ns source notes burst_beats hp_port_set ddr_port_set scope hpr_state ddrqos_hash board"

# Which physical board produced the row.  Resolved from PYNQ_HOST via bwlab/boards.csv, or
# from $IISWC_BOARD.  Sourced here so every writer gets it without having to remember.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board_id.sh"

bwlab_init () {
  mkdir -p "$(dirname "$BWLAB_CSV")"
  if [ ! -f "$BWLAB_CSV" ]; then
    printf '%s\n' "$(echo $BWLAB_FIELDS | tr ' ' ',')" > "$BWLAB_CSV"
  fi
}

bwlab_row () {
  bwlab_init
  # Resolve the board BEFORE writing.  board_name refuses rather than guessing, so a row can
  # never be recorded without naming the machine that produced it.
  local _board
  _board="$(board_name)" || return 1
  python3 - "$BWLAB_CSV" "$_board" "$@" <<'PYB'
import csv, sys, datetime
path, board = sys.argv[1], sys.argv[2]
# The header in the file is authoritative: a column added by another writer is picked up
# automatically, and every row is written full width and correctly aligned.
with open(path, newline="") as fh:
    fields = next(csv.reader(fh))
row = {f: "" for f in fields}
row["timestamp"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
if "board" in row:
    row["board"] = board
for kv in sys.argv[3:]:
    if "=" not in kv:
        sys.exit("bwlab_row: expected field=value, got %r" % kv)
    k, v = kv.split("=", 1)
    if k not in row:
        sys.exit("bwlab_row: unknown field %r; known: %s" % (k, " ".join(fields)))
    row[k] = v
if not row.get("board"):
    sys.exit("bwlab_row: REFUSING to write a row with no board. Two boards run the same\n"
             "  bitstream md5, so config+md5 no longer identifies a machine. See\n"
             "  fpga/pynq-z2/bwlab/boards.csv and scripts/lib/board_id.sh.")
with open(path, "a", newline="") as fh:
    csv.DictWriter(fh, fieldnames=fields, lineterminator="\n").writerow(row)
PYB
}
