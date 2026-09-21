#!/usr/bin/env bash
# Lab B22 -- the memory port, measured. Two ways, one bitstream, one session.
#
#   scripts/with_board.sh ./scripts/43_rocket_bwlab.sh
#   scripts/with_board.sh ./scripts/43_rocket_bwlab.sh --build-only  # no board
#
# ROCC_DECOUPLED.md section 4.4 SIMULATES rtl_study/rocc/mbxd_dma.v against a memory model
# and gets 1.34 -> 5.10 B/cycle at four transactions in flight and 7.89 at eight.  The
# model's credibility rests entirely on two rows nobody fitted: at ONE transaction in
# flight it produces 1.28 against the board's measured 1.34 for DRAM and 2.56 against the
# board's measured 2.82 for the L2.  This lab is what turns the rest of that sweep into
# measurements -- or falsifies it.
#
# THE FALSIFICATION TEST IS THE BOTTOM OF THE SWEEP, NOT THE TOP, and it is checked
# first.  A single outstanding 64-byte Get is very nearly what a blocking D-cache already
# does, so one-in-flight has to land near the core's own figure.  If it does not, the
# model is wrong about this memory system and nothing above one outstanding means
# anything -- so the lab prints that comparison before the headline and says so.
#
# AND THE CORE FIGURE IS MEASURED HERE TOO, not quoted.  The guest runs samples/membench's
# own `mb_read` assembly kernel -- the one that produced Lab B6's numbers -- over the same
# buffer, in the same image, minutes before the instrument reads it.  Quoting 1.34 from a
# different bitstream at a different clock would be comparing two machines.
#
# EVERY ROW LANDS IN fpga/pynq-z2/bwlab/results.csv (or $BWLAB_CSV), appended and never
# rewritten, so the progression across bitstreams and sessions is the evidence rather than
# a paragraph.
#
#   --channels also build the guest with BWLAB_CHANNELS: two DRAM reads that differ only
#              in which memory channel they use -- DRAM_1CH (every request on channel 0)
#              and DRAM_2CH (alternating).  WithNMemoryChannels(2) splits on address[6],
#              i.e. per 64-byte block.  Lever 3.
#
#              (An earlier revision had --spread / level DRAM_ALT, written on the belief
#              that the split was per 4 KiB page.  It is not; see MEMORY_BANDWIDTH.md s3.6
#              for what the six DRAM_ALT rows in results.csv actually measured.)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bwlab.sh"

NAME="rocket_bwlab"
BOARD="chipyard_pynqz1_micrgb"
BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_bw_z1"
BIT="$BUILD/pynqz1_rocket_micrgb_bw.bit"
RUNNER="run_rocket_bw.py"
SAMPLE="$IISWC_ROOT/samples/bwprobe_bench"
WANT_MAGIC="0x5A5A0007"
CFGNAME="PynqZ2RocketBigLittlePextTacitMicRgbBwConfig"
FCLK_CORE=34.4828
FCLK_MEM=34.4828
NPORTS=1
LOAD_BIT=1; DO_BOARD=1; SECONDS_READ=300; CHANNELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name)   NAME="${2:?}"; shift 2 ;;
    --board)  BOARD="${2:?}"; shift 2 ;;
    --bit)    BIT="${2:?}"; shift 2 ;;
    --build)  BUILD="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --magic)  WANT_MAGIC="${2:?}"; shift 2 ;;
    --config) CFGNAME="${2:?}"; shift 2 ;;
    --fclk-core) FCLK_CORE="${2:?}"; shift 2 ;;
    --fclk-mem)  FCLK_MEM="${2:?}"; shift 2 ;;
    --ports)  NPORTS="${2:?}"; shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --channels) CHANNELS=(-DBWLAB_CHANNELS=1); shift ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only) DO_BOARD=0; shift ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"

# The bitstreams THIS lab has been validated against, kept here rather than added to
# lib/bitstream_id.sh's global BIT_ACCEPTED.
#
# That list is shared with the speech labs, and widening it would let one of them run
# happily on a bitstream nobody has re-measured it on -- which is the exact failure the
# md5 gate exists to prevent, and it would be caused by the gate.  So this lab extends
# the list with its own builds only, and bitstream_note() still NAMES them so a run
# never prints "UNKNOWN" for a bitstream this repository built on purpose.
#
#   737d2f57...  lever 1: the instrument, one HP port, everything at 34.4828 MHz
#   f507f18f...  lever 2: + the memory bus, the AXI shim and S_AXI_HP0 on FCLK1 (designed
#                100 MHz; ran at 142.8571 -- fpga/pynq-z2/bwlab/errata.csv)
#   62ea1a99...  lever 3: lever 1 + a second memory channel into S_AXI_HP1, one clock
#   e18c817d...  lever 4: lever 1 on a 128-bit system bus, one clock, one HP port
#   49d2a1f4...  lever 4, second point, first build: 256-bit sbus, reports MAGIC 0x5A5A000E (a collision, errata.csv)
#   d3478730...  lever 4, second point, rebuilt under its own MAGIC 0x5A5A000F
#   0df4d1d1...  lever 3 on HP0+HP2 (bwbypassl2): channel 1 on S_AXI_HP2, L2 in the path, one clock
#   c17d1a2b...  the bypass fusion (bwbypass): BwBypass 2 lanes on MBUS, HP0+HP2, memory bus on FCLK1, patch 0061
#   b13f237d...  the bypass fusion on HP0+HP1 (bwbypass01): BwBypass 2 lanes on MBUS, memory bus on FCLK1, patch 0061
#   387cbb78...  bwbypass01 f111: FCLK1 target 9.000 ns, closes at 110.7 MHz (not runnable above 100)
#   bacbe69b...  bwbypass01 f125: FCLK1 target 8.000 ns, closes at 115.9 MHz, run at 111.111
#   bf600a3b...  bwbypass4: BwBypass 4 lanes on MBUS, HP0-HP3, memory bus on FCLK1, patch 0061
BIT_ACCEPTED="${BIT_ACCEPTED:-} 737d2f5707857105be90c24c7f6610a2 f507f18f8a42cd42993e9f35ab9a787f 62ea1a99280c6a6920557ea4c845291d e18c817d7600045c1f628ed4f4355f98 49d2a1f420e37f7659970942bd7be85a d3478730fcfcc5f7efc882fe420c26be 0df4d1d1204f9c18faf047183ac8818b c17d1a2b0f7ec45e1a62298cf625507c b13f237d3a99e102babe790ccfc5b69a 387cbb78742641e58273e42d26ea5354 bacbe69b7b1a080399dfba2351ac9f7d bf600a3b1de77d34487ac1399b05aea1"

# ... and their names, kept here for the same reason.  bitstream_note() in the shared
# library says "UNKNOWN -- no speech lab has been validated against this build" for
# these, which is TRUE and should stay true; this lab is not a speech lab and adds its
# own identification rather than weakening that sentence.
bwlab_note () {
  case "$1" in
    737d2f5707857105be90c24c7f6610a2)
      echo "lever 1: full-feature + the TileLink bandwidth instrument, 1 HP port @ 34.4828 MHz (36,067 LUT, WNS +0.852)" ;;
    f507f18f8a42cd42993e9f35ab9a787f)
      echo "lever 1+2: the same, memory bus + AXI shim + S_AXI_HP0 on FCLK1 @ 100 MHz (36,455 LUT, WNS +1.223 core / +0.690 mem)" ;;
    62ea1a99280c6a6920557ea4c845291d)
      echo "lever 1+3: the same, two memory channels into S_AXI_HP0 + S_AXI_HP1 @ 34.4828 MHz (36,378 LUT, WNS +0.776)" ;;
    e18c817d7600045c1f628ed4f4355f98)
      echo "lever 1+4: the same on a 128-bit TileLink system bus, L1 rowBits 64, L2 7 MSHRs (38,710 LUT, WNS +1.337)" ;;
    49d2a1f420e37f7659970942bd7be85a)
      echo "lever 1+4 at 256 bits, first build, reports 0x5A5A000E (collides with the cork config; errata.csv) (46,782 LUT, WNS +0.962)" ;;
    d3478730fcfcc5f7efc882fe420c26be)
      echo "lever 1+4 at 256 bits (0x5A5A000F): 256-bit TileLink system bus, L1 rowBits 64, L2 7 MSHRs (46,782 LUT, WNS +0.962)" ;;
    0df4d1d1204f9c18faf047183ac8818b)
      echo "lever 1+3 on HP0+HP2 (0x5A5A0014): channel 1 on S_AXI_HP2, the other DDR controller port, one clock (36,359 LUT, WNS +0.934)" ;;
    c17d1a2b0f7ec45e1a62298cf625507c)
      echo "the bypass fusion (0x5A5A0015): BwBypass 2 lanes on MBUS (no L2), channels on HP0+HP2, memory bus on FCLK1 timed at 100 MHz (40,221 LUT, WNS +0.927 core / +0.456 mem)" ;;
    b13f237d3a99e102babe790ccfc5b69a)
      echo "the bypass fusion on HP0+HP1 (0x5A5A0016): BwBypass 2 lanes on MBUS (no L2), channels on HP0+HP1 (one DDR controller port), memory bus on FCLK1 at 100 MHz (40,217 LUT, WNS +1.413 core / +0.723 mem)" ;;
    387cbb78742641e58273e42d26ea5354)
      echo "bwbypass01 f111 (0x5A5A0016): FCLK1 timed at 9.000 ns, WNS -0.030 -> closes at 110.7 MHz; run only at <= 100 MHz (40,248 LUT)" ;;
    bacbe69b7b1a080399dfba2351ac9f7d)
      echo "bwbypass01 f125 (0x5A5A0016): FCLK1 timed at 8.000 ns, WNS -0.627 -> closes at 115.9 MHz; run at <= 111.111 MHz (40,310 LUT, core WNS +0.499)" ;;
    bf600a3b1de77d34487ac1399b05aea1)
      echo "the bypass on all four HP ports (0x5A5A0017): BwBypass 4 lanes x 8 on MBUS, channels on HP0-HP3, memory bus on FCLK1 at 100 MHz (44,277 LUT, WNS +0.479 core / +0.368 mem)" ;;
    *) echo "not a bandwidth-lab build" ;;
  esac
}

step "1/3  build"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" "${CHANNELS[@]}" > "$RUN/build.log" 2>&1 \
  || { tail -30 "$RUN/build.log"; die "build failed"; }
cp "$RUN/build/zephyr/zephyr.elf" "$RUN/build/zephyr/zephyr.bin" "$RUN/"
info "image: $(fsize "$RUN/zephyr.bin")"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only"; exit 0; }

step "2/3  run"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" \
      "$RUN/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "no bitstream -- build it with fpga/pynq-z2/scripts/build_bw_z1.sh"
  bitstream_identify "$BIT"
  info "           $(bwlab_note "$BIT_MD5")"
  bitstream_gate
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD="--bitstream $(basename "$BIT") --hold"
else bitstream_identify ""; HOLD="--no-load --hold"; fi
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER $HOLD'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream:
       this lab needs $WANT_MAGIC.  SOC_MAGIC names the CONFIGURATION, and a bitstream
       without the instrument answers 0 at 0x100A_0000 and reports a well-formed
       0.00 B/cycle."; }

# THE CLOCKS ARE A READING, NOT AN INTENTION.  The PS clocks are not part of the bitstream:
# MAGIC and md5 can both be right and FCLKn still be whatever the boot image left there
# (fpga/pynq-z2/bwlab/errata.csv: lever 2 logged 100 MHz and ran at 142.8571).  So read
# them from the SLCR, refuse to measure on a mismatch, keep the JSON beside the console,
# and put the READ values -- not --fclk-core/--fclk-mem -- into every row.
FCLK_EXPECT=(--expect "FCLK0=$FCLK_CORE")
[ "$FCLK_MEM" = "$FCLK_CORE" ] || FCLK_EXPECT+=(--expect "FCLK1=$FCLK_MEM")
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py ${FCLK_EXPECT[*]}" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "the PS
       clocks are not the ones this bitstream was built for -- see $RUN/fclk.err"; }
FCLK_MEM_DESIGNED="$FCLK_MEM"
read -r FCLK_CORE FCLK_MEM FCLK_CTRL <<EOF
$(python3 - "$RUN/fclk.json" "$FCLK_MEM_DESIGNED" "$FCLK_CORE" <<'PYF'
import json, sys
j = json.load(open(sys.argv[1]))
single = sys.argv[2] == sys.argv[3]
mem = j["fclk0"] if single else j["fclk1"]
print(j["fclk0"]["mhz"], mem["mhz"], "fclk0_ctrl=%s,fclk1_ctrl=%s" % (j["fclk0"]["ctrl"], j["fclk1"]["ctrl"]))
PYF
)
EOF
info "as-run clocks (SLCR): FCLK0 $FCLK_CORE MHz, memory domain $FCLK_MEM MHz  ($FCLK_CTRL)"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
printf '%s\n' "----------------------------------------------------------------"
cat "$RUN/console.txt"
printf '%s\n' "----------------------------------------------------------------"

step "3/3  verdict, and the rows"
# Post-route cost IN CONTEXT.  The out-of-context 327 LUT is not the number that matters;
# this is.
UTIL="$BUILD/reports/post_route_util.rpt"
TIM="$BUILD/reports/timing_summary.rpt"
LUT=""; FF=""; BRAM=""; DSP=""; WNS=""; WHS=""
if [ -f "$UTIL" ]; then
  LUT=$(awk -F'|' '/\| Slice LUTs +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  FF=$(awk -F'|' '/\| Slice Registers +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  BRAM=$(awk -F'|' '/\| Block RAM Tile +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  DSP=$(awk -F'|' '/\| DSPs +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
fi
if [ -f "$TIM" ]; then
  WNS=$(awk '/^ *WNS\(ns\)/{getline; getline; print $1; exit}' "$TIM")
  # WHS is NOT on a line of its own: the Design Timing Summary header is one line,
  # "WNS(ns) TNS(ns) ... WHS(ns) ...", with the values two lines below, so WHS is field 5
  # of that values line.  The old pattern /^ *WHS\(ns\)/ never matched, and every row
  # before this fix has an empty whs_ns (fpga/pynq-z2/bwlab/errata.csv).
  WHS=$(awk '/^ *WNS\(ns\) +TNS\(ns\)/{getline; getline; print $5; exit}' "$TIM")
fi
info "post-route, in context: LUT=$LUT FF=$FF BRAM=$BRAM DSP=$DSP WNS=$WNS WHS=$WHS"

export BWLAB_CSV="${BWLAB_CSV:-$IISWC_ROOT/fpga/pynq-z2/bwlab/results.csv}"
export WANT_MAGIC CFGNAME FCLK_CORE FCLK_MEM NPORTS LUT FF BRAM DSP WNS WHS
export FCLK_CTRL="${FCLK_CTRL:-}"
bwlab_init
python3 - "$RUN/console.txt" "$BWLAB_CSV" <<'PY' | tee "$RUN/report.txt"
import csv, datetime, os, re, sys
console, csvpath = sys.argv[1], sys.argv[2]
txt = open(console).read()
env = dict(md5=os.environ.get("BIT_MD5", ""), magic=os.environ.get("WANT_MAGIC", ""),
           cfg=os.environ.get("CFGNAME", ""), fc=os.environ.get("FCLK_CORE", ""),
           fm=os.environ.get("FCLK_MEM", ""), np=os.environ.get("NPORTS", ""),
           lut=os.environ.get("LUT", ""), ff=os.environ.get("FF", ""),
           bram=os.environ.get("BRAM", ""), dsp=os.environ.get("DSP", ""),
           wns=os.environ.get("WNS", ""), whs=os.environ.get("WHS", ""))
SHAPE_NOTE = {
    "DRAM_1CH": "stride 128 B, address[6]=0 on every request (one memory channel) ",
    "DRAM_2CH": "stride 192 B, address[6] alternates (both memory channels) ",
}
# A wide system bus (MEMORY_BANDWIDTH.md section 5) prints PROBEW after PROBE: TileLink D
# beats and the bus beat width.  64 * reqs / dbeats is the bytes each beat carried, from
# two counters on two different channels; no other bitstream prints the line.
widths = {}
for m in re.finditer(r'^PROBEW level=(\S+) bytes=(\d+) out=(\d+) dbeats=(\d+) '
                     r'beat_bytes=(\d+)$', txt, re.M):
    lvl, size, out, dbeats, bb = m.groups()
    widths[(lvl, size, out)] = (int(dbeats), int(bb))
rows = []
for m in re.finditer(r'^CORE level=(\S+) bytes=(\d+) moved=(\d+) cycles=(\d+) '
                     r'bpc_x1000=(\d+)$', txt, re.M):
    lvl, size, moved, cyc, bpc = m.groups()
    rows.append(dict(level=lvl, working_set_bytes=size, outstanding="1",
                     burst_bytes="64", direction="rd", bytes_moved=moved, cycles=cyc,
                     bytes_per_cycle="%.4f" % (int(bpc) / 1000.0),
                     notes="core, membench mb_read"))
for m in re.finditer(r'^PROBE level=(\S+) bytes=(\d+) out=(\d+) cycles=(\d+) beats=(\d+) '
                     r'reqs=(\d+) peak=(\d+) denied=(\d+) cksum_ok=(\d)$', txt, re.M):
    lvl, size, out, cyc, beats, reqs, peak, den, ck = m.groups()
    moved = int(beats) * 8
    rows.append(dict(level=lvl, working_set_bytes=size, outstanding=out,
                     burst_bytes="64", direction="rd", bytes_moved=str(moved), cycles=cyc,
                     bytes_per_cycle="%.4f" % (moved / float(cyc)),
                     notes="mbxd_dma %speak_inflight=%s reqs=%s denied=%s cksum_%s%s"
                           % (SHAPE_NOTE.get(lvl, ""),
                              peak, reqs, den, "ok" if ck == "1" else "MISMATCH",
                              (" dbeats=%d beat_bytes=%d bytes_per_beat_by_counters=%.3f"
                               % (widths[(lvl, size, out)][0], widths[(lvl, size, out)][1],
                                  64.0 * int(reqs) / max(1, widths[(lvl, size, out)][0])))
                              if (lvl, size, out) in widths else "")))
# NO ROWS IS A FAILURE, NOT A PASS.  Every check below is "all rows are fine", which is
# vacuously true of zero rows -- a run whose console captured nothing printed an empty
# calibration table, an empty sweep and "every run returned the bytes that were asked for",
# and exited 0.  Refuse before anything is appended.
if not any("core" in r["notes"] for r in rows) or not any("mbxd_dma" in r["notes"] for r in rows):
    print("*** NO MEASUREMENT: %d CORE and %d PROBE rows parsed from %s (%d bytes of console)."
          % (sum("core" in r["notes"] for r in rows), sum("mbxd_dma" in r["notes"] for r in rows),
             console, len(txt)))
    print("    Nothing was appended.  Check the console path (/dev/ttyPS1 on the board) and re-run.")
    sys.exit(2)
fields = open(csvpath).readline().strip().split(",")
# Which physical board produced these rows.  Resolved and exported by scripts/lib/common.sh
# from PYNQ_HOST via bwlab/boards.csv.  This lab has its own DictWriter and does NOT go
# through bwlab_row, so the refusal has to live here too: two boards run the same bitstream
# md5, and a row that does not name its machine cannot be told apart from the other board's.
board = os.environ.get("IISWC_BOARD", "").strip()
if not board:
    sys.exit("*** REFUSING to append %d rows: IISWC_BOARD is unset.\n"
             "    Set PYNQ_HOST to a board listed in fpga/pynq-z2/bwlab/boards.csv, or export\n"
             "    IISWC_BOARD. A results.csv row that does not name its board cannot be\n"
             "    separated from the other board's rows for the same bitstream md5."
             % len(rows))
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
with open(csvpath, "a", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fields)
    for r in rows:
        full = {f: "" for f in fields}
        full.update(timestamp=now, bitstream_md5=env["md5"], soc_magic=env["magic"],
                    config=env["cfg"], fclk_core_mhz=env["fc"], fclk_mem_mhz=env["fm"],
                    n_hp_ports=env["np"], lut=env["lut"], ff=env["ff"], bram=env["bram"],
                    dsp=env["dsp"], wns_ns=env["wns"], whs_ns=env["whs"], source="silicon",
                    board=board)
        full.update(r)
        if os.environ.get("FCLK_CTRL"):
            full["notes"] = full["notes"] + " as_run " + os.environ["FCLK_CTRL"]
        fps = float(r["bytes_per_cycle"]) * float(env["fc"] or 0)
        full["mb_per_s"] = "%.1f" % fps
        w.writerow(full)
print("   appended %d rows to %s" % (len(rows), csvpath))

core = {r["level"]: float(r["bytes_per_cycle"]) for r in rows if "core" in r["notes"]}
prb  = {}
for r in rows:
    if "mbxd_dma" in r["notes"]:
        prb.setdefault(r["level"], {})[int(r["outstanding"])] = float(r["bytes_per_cycle"])

# Lab B6's numbers, for the calibration gate.  MEMORY_HIERARCHY.md section 2, hart 0.
B6 = {"L1": 7.03, "L2": 2.82, "DRAM": 1.34}

print("\n-- CALIBRATION FIRST: does the core half reproduce Lab B6 on this bitstream?")
ok = True
for lvl in ("L1", "L2", "DRAM"):
    if lvl in core:
        d = 100.0 * (core[lvl] - B6[lvl]) / B6[lvl]
        good = abs(d) < 10
        ok &= good
        print("   %-5s Lab B6 %.2f B/cycle   here %.2f   %+.1f%%   %s"
              % (lvl, B6[lvl], core[lvl], d, "ok" if good else "*** DRIFTED ***"))
print("   (same mb_read kernel, a different bitstream and a different clock; if these")
print("    disagree the instrument is not measuring the machine Lab B6 measured)")

print("\n-- AND THE SECOND CHECK: what one transaction in flight implies about latency")
print("   The instrument has NO L1.  MEMORY_HIERARCHY.md section 5 decomposes the core's")
print("   41.23-cycle miss as 16.05 cycles of L1+L2 lookup plus 25.2 past the L2, and")
print("   charges a streaming read miss_latency/concurrency + 7 per line because seven of")
print("   the eight loads covering a line HIT.  So one-outstanding here must be FASTER")
print("   than the core, and the round trip it implies must sit between 25.2 cycles and")
print("   the core's 41.2.  Outside that band the model is wrong about this memory system.")
# On a wide system bus a 64-byte Get is 64/beat_bytes beats, not 8: the link bound is the
# beat width, and the round trip loses (8 - beats) serving cycles, so the band's floor
# moves down by exactly that many.  On a 64-bit bus both terms are the original ones.
beat_bytes = max([bb for (_, bb) in widths.values()] or [8])
nbeats = 64 // beat_bytes
for lvl in ("L2", "DRAM"):
    if lvl in prb and 1 in prb[lvl] and lvl in core:
        rt = 64.0 / prb[lvl][1]
        band = (prb[lvl][1] > core[lvl]) and (prb[lvl][1] <= beat_bytes + 0.05)
        if lvl == "DRAM":
            band = band and (25.2 - (8 - nbeats) <= rt <= 41.3)
        ok &= band
        print("   %-5s core %.2f   instrument @1 %.2f B/cycle -> %.1f cycles per 64 B   %s"
              % (lvl, core[lvl], prb[lvl][1], rt,
                 "consistent" if band else "*** INCONSISTENT ***"))

print("\n-- the sweep, measured")
print("   %-8s %8s %10s %10s" % ("level", "out", "B/cycle", "MB/s"))
for lvl in ("L2", "DRAM", "DRAM_1CH", "DRAM_2CH"):
    for o in sorted(prb.get(lvl, {})):
        print("   %-8s %8d %10.2f %10.1f"
              % (lvl, o, prb[lvl][o], prb[lvl][o] * float(env["fc"] or 0)))
bad = [r for r in rows if "MISMATCH" in r["notes"]]
if widths:
    wbad = [k for k, (db, bb) in widths.items()
            for r in rows if (r["level"], r["working_set_bytes"], r["outstanding"]) == k
            and "mbxd_dma" in r["notes"]
            and db * bb != 64 * int(re.search(r'reqs=(\d+)', r["notes"]).group(1))]
    print("\n   width: %s" % ("every beat of every run carried %d bytes (DBEATS x %d == REQS x 64)"
                              % (beat_bytes, beat_bytes) if not wbad
                              else "*** %d run(s) where DBEATS x BEAT_BYTES != REQS x 64 ***"
                              % len(wbad)))
    ok &= not wbad
print("\n   checksum: %s" % ("every run returned the bytes that were asked for"
                             if not bad else "*** %d run(s) MISMATCHED ***" % len(bad)))
sys.exit(0 if ok and not bad else 1)
PY
