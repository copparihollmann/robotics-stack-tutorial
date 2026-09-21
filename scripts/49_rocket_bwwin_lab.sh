#!/usr/bin/env bash
# Lab B29 -- the system-bus side of the memory architecture (MEMORY_BANDWIDTH.md section 9), on
# 0x5A5A001C (bwwin): four 128-bit lanes at the CORE clock, the DMA aperture, and the coherence
# contract.  ONE LADDER STEP PER BOARD SESSION, a health check after each (scripts/35_rocket_rgb_leds.sh):
#
#   scripts/with_board.sh ./scripts/49_rocket_bwwin_lab.sh --step 1 --fclk1 100
#   scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh
#   ... --step 2, 3, 4, stopping at the first anomaly
#
#   step 1  one lane (HP0), 1 in flight, 64 KiB -- the least RREADY backpressure
#   step 2  one lane (HP0), 1/2/4/8 in flight, 16 MiB -- one port under sustained backpressure
#   step 3  every lane set x 1..8 in flight (SEQ included), the L2 flush cost, BwProbe through the L2
#   step 4  the aperture: BwProbe through it, the harts' loads and stores through it, the harts'
#           coherent write, the contract checks
#   step 5  two lanes on one DDR controller port (HP0+HP1): striped over one region vs regions 64 MiB apart
#
# A wrapper around a snapshot of scripts/43_rocket_bwlab.sh (as 48 does), with the guest switched to
# samples/bwwin_bench and host/run_rocket_bwl2.py as the runner (FCLK1 SET in reset, both clocks READ
# BACK from the SLCR before release).  What it adds:
#
#   1. A TIMING GATE PER CLOCK, as 48's: FCLK0 must close; the memory domain must close at the FCLK1 this
#      run sets.
#   2. THE MD5 MUST BE REGISTERED in scripts/lib/bitstream_id.sh as a bwwin build, or nothing loads.
#   3. ROWS: WIN_*, AP_*, the core rows and BwProbe rows count CORE (FCLK0) cycles, so mb_per_s is
#      B/cycle x the READ-BACK FCLK0; FLUSH_* and CONTRACT_* rows are added from their own console lines.
#   4. A STOP RULE.  0 console bytes, no "BWLAB done", or a Zephyr fatal error means the HP ports may be
#      held: the lab says STOP ALL BOARD WORK and exits 3, and no retry or reboot is attempted.
#
# Run it inside scripts/with_board.sh; it does not take the board lock itself.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
unset EXTRA_CFLAGS
STEP=""; FCLK1=""; NOTE=""; TAG=""; SECONDS_READ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step)    STEP="${2:?}"; shift 2 ;;
    --fclk1)   FCLK1="${2:?}"; shift 2 ;;
    --note)    NOTE="${2:?}"; shift 2 ;;
    --tag)     TAG="${2:?}"; shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$STEP" in 1|2|3|4|5) ;; *) die "--step must be 1, 2, 3, 4 or 5 (one per board session)" ;; esac
[ -n "$FCLK1" ] || die "bwwin puts the memory domain on FCLK1: give --fclk1"
[ -n "$SECONDS_READ" ] || SECONDS_READ=$([ "$STEP" -ge 3 ] && echo 300 || echo 180)
VARIANT=bwwin; MAGIC=0x5A5A001C; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwWinConfig; NCH=4
FCORE=34.4828
export EXTRA_CFLAGS="-DBWWIN_STEP=$STEP"
BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_${VARIANT}${TAG:+_$TAG}_z1"
BIT="$BUILD/pynqz1_rocket_micrgb_${VARIANT}${TAG:+_$TAG}.bit"
need_file "$BIT" "no bitstream -- fpga/pynq-z2/scripts/build_bwwin_z1.sh $VARIANT"
NAME="bwwinlab_step${STEP}${TAG:+_$TAG}_fclk1_$FCLK1"
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")

step "0/4  the bitstream is a registered bwwin build; timing closes at the clocks this run sets"
bitstream_identify "$BIT"
case "$BIT_NOTE" in
  *"NOT for measurement"*) die "md5 $BIT_MD5 is registered as NOT for measurement: $BIT_NOTE" ;;
  *0x5A5A001C*bwwin*) ;;
  *) die "md5 $BIT_MD5 is not registered as a 0x5A5A001C bwwin build in scripts/lib/bitstream_id.sh" ;;
esac
TIM="$BUILD/reports/timing_summary.rpt"
need_file "$TIM"
awk '/^Clock +Waveform/ {c=1} c && /^clk_fpga_[0-9]/ && !($1 in per) {per[$1]=$4} /^\| Intra Clock Table/ {t=1} t && /^clk_fpga_[0-9]/ {print $1, $2, $6, per[$1]} /^\| Inter Clock Table/ {t=0}' "$TIM" > "$RUN/timing.txt"
sed 's/^/   /' "$RUN/timing.txt"
python3 - "$RUN/timing.txt" "$FCLK1" <<'PY' || die "timing gate: this run would measure a design outside its timing closure"
import sys
rows = {l.split()[0]: (float(l.split()[1]), float(l.split()[2]), float(l.split()[3])) for l in open(sys.argv[1]) if l.strip()}
w0, h0, _ = rows["clk_fpga_0"]
ok = w0 >= 0 and h0 >= 0
if not ok: print("   clk_fpga_0 misses: WNS %.3f WHS %.3f" % (w0, h0))
w1, h1, per1 = rows["clk_fpga_1"]
need, have = per1 - w1, 1000.0 / float(sys.argv[2])
print("   memory domain closes at %.3f ns (%.2f MHz); this run: %.3f ns -> %s" % (need, 1000.0 / need, have, "ok" if have >= need else "REFUSED"))
ok = ok and have >= need and h1 >= 0
sys.exit(0 if ok else 1)
PY

step "1/4  the per-run clock file and fclk.py onto the board"
python3 - "$MAGIC" "$FCLK1" "$BIT_MD5" > "$RUN/bwl2_run.json" <<'PY'
import json, sys
print(json.dumps({"magic": sys.argv[1], "fclk1_mhz": float(sys.argv[2]), "md5": sys.argv[3]}))
PY
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$IISWC_ROOT/fpga/pynq-z2/host/ddrc_afi.py" \
    "$RUN/bwl2_run.json" "$PYNQ_HOST:$PYNQ_DIR/"
LAB43="$IISWC_ROOT/scripts/.43_snapshot_bwwin_$$.sh"
cleanup () { rm -f "$LAB43"; "${SSH[@]}" "rm -f $PYNQ_DIR/bwl2_run.json" >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "2/4  step $STEP (scripts/43_rocket_bwlab.sh snapshot, guest samples/bwwin_bench), rows to a scratch CSV"
sed 's#^SAMPLE="$IISWC_ROOT/samples/bwprobe_bench"$#SAMPLE="$IISWC_ROOT/samples/bwwin_bench"#' \
    "$IISWC_ROOT/scripts/43_rocket_bwlab.sh" > "$LAB43"
grep -q 'samples/bwwin_bench' "$LAB43" || die "could not point the 43 snapshot at samples/bwwin_bench"
bash -n "$LAB43" || die "scripts/43_rocket_bwlab.sh does not parse right now (someone is editing it?)"
SCRATCH="$RUN/rows.csv"
head -1 "$IISWC_ROOT/fpga/pynq-z2/bwlab/results.csv" > "$SCRATCH"
set +e
BIT_ACCEPTED="$BIT_MD5" BWLAB_CSV="$SCRATCH" bash "$LAB43" --name "$NAME/lab" --bit "$BIT" --build "$BUILD" \
    --runner run_rocket_bwl2.py --magic "$MAGIC" --config "$CFG" --ports "$NCH" \
    --fclk-core "$FCORE" --fclk-mem "$FCLK1" --seconds "$SECONDS_READ"
LAB_RC=$?
set -e
LABDIR="$IISWC_OUT/$NAME/lab"
CONSOLE="$LABDIR/console.txt"
if ! grep -q "MAGIC = $MAGIC" "$LABDIR/boot.log" 2>/dev/null; then
  die "the lab did not reach a loaded 0x5A5A001C (exit $LAB_RC; see $LABDIR/boot.log) -- nothing ran on the SoC"
fi
CBYTES=$( [ -f "$CONSOLE" ] && wc -c < "$CONSOLE" || echo 0 )
if [ "$CBYTES" -eq 0 ] || ! grep -q '^BWLAB done' "$CONSOLE" || grep -q 'FATAL ERROR' "$CONSOLE"; then
  NDONE=$(grep -c '^BWLAB done' "$CONSOLE" 2>/dev/null; true); NFATAL=$(grep -c 'FATAL ERROR' "$CONSOLE" 2>/dev/null; true)
  warn "console: $CBYTES bytes; 'BWLAB done' ${NDONE:-0} time(s); fatal ${NFATAL:-0}"
  printf '\n*** STOP ALL BOARD WORK: step %s did not complete (0 console bytes, no "BWLAB done", or a fatal error).\n' "$STEP"
  printf '*** The HP ports may be held.  Do not retry and do not reboot; message the coordinator.  Run record: %s\n\n' "$RUN"
  exit 3
fi
grep -h '^FCLK_READBACK ' "$LABDIR/boot.log" | tail -1 | sed 's/^FCLK_READBACK //' > "$RUN/fclk.json" || true
[ -s "$RUN/fclk.json" ] || die "no FCLK_READBACK in $LABDIR/boot.log -- the clocks were not verified, rows NOT appended"
[ "$(tail -n +2 "$SCRATCH" | wc -l)" -gt 0 ] || die "the lab produced no rows (exit $LAB_RC)"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 ddrc_afi.py" > "$RUN/ddrc_afi.json" 2>/dev/null \
  && "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 ddrc_afi.py --summary" > "$RUN/ddrc_afi.txt" 2>/dev/null \
  || { warn "ddrc_afi.py could not be read -- rows say so"; echo "not read" > "$RUN/ddrc_afi.txt"; echo "{}" > "$RUN/ddrc_afi.json"; }

step "3/4  rows: read-back clocks, ports per row, FLUSH and CONTRACT rows; the verdict"
python3 - "$SCRATCH" "$RUN/fclk.json" "$CONSOLE" "$STEP" "$NOTE" "$RUN/rows_final.csv" "$RUN/verdict.txt" \
          "$RUN/ddrc_afi.txt" "$BIT_MD5" "$MAGIC" "$CFG" <<'PY'
import csv, datetime, json, re, sys
src, fj, console, stp, note, dst, verdict, qos, md5, magic, cfg = sys.argv[1:12]
stp = int(stp)
LANE_HP = {"0": "HP0", "1": "HP1", "2": "HP2", "3": "HP3"}
DDRC_PORT = {"HP0": 3, "HP1": 3, "HP2": 2, "HP3": 2}
qtext = open(qos).read()
m = re.search(r"hpr_rd_p0123=(\d{4}) lpr_entries_field=(\d+)", qtext)
HPR = ("HPR rd p0123=%s; lpr_num_entries=%s" % m.groups()) if m else "unknown"
m = re.search(r"qos_hash=([0-9a-f]+)", qtext)
QH = m.group(1) if m else ""
qline = qtext.strip().splitlines()[-1] if qtext.strip() else "not read"
clk = json.load(open(fj)); f0 = clk["fclk0"]["mhz"]; f1 = clk["fclk1"]["mhz"]
txt = open(console).read()
def portset(ports):
    ports = sorted(ports, key=lambda x: int(x[2:]))
    return "+".join(ports), "+".join(str(x) for x in sorted({DDRC_PORT[p] for p in ports}, reverse=True))
winlane = {}
for mm in re.finditer(r'^WINLANE level=(\S+) out=(\d+) lane=(\d+) cycles=(\d+) beats=(\d+) reqs=(\d+) peak=(\d+)$', txt, re.M):
    lvl, out, lane, cyc, beats, reqs, peak = mm.groups()
    winlane.setdefault((lvl, out), []).append("lane%s cycles=%s words=%s reqs=%s peak=%s" % (lane, cyc, beats, reqs, peak))
rows = list(csv.DictReader(open(src)))
fields = open(src).readline().strip().split(",")
for c in ("burst_beats", "hp_port_set", "ddr_port_set", "scope", "hpr_state", "ddrqos_hash"):
    if c not in fields: fields.append(c)
out = []
for r in rows:
    lvl = r["level"]; core = r["notes"].startswith("core")
    r["fclk_core_mhz"] = "%.4f" % f0; r["fclk_mem_mhz"] = "%.4f" % f1
    r["mb_per_s"] = "%.1f" % (float(r["bytes_per_cycle"]) * f0)     # every row here counts CORE cycles
    r["burst_beats"] = "8"; r["hpr_state"], r["ddrqos_hash"] = HPR, QH
    extra = ["fclk_readback FCLK0=%.4f FCLK1=%.4f" % (f0, f1), "as-run " + qline, "bwwin ladder step %d" % stp]
    if lvl.startswith("WIN_"):
        if lvl == "WIN_L01_SPLIT":
            ports = ["HP0", "HP1"]; r["scope"] = "aggregate, lanes on regions 64 MiB apart"
        elif lvl == "WIN_SEQ":
            ports = ["HP0", "HP1", "HP2", "HP3"]; r["scope"] = "one D channel over HP0+HP1+HP2+HP3"
        else:
            ports = [LANE_HP[c] for c in lvl[len("WIN_L"):]]
            r["scope"] = "aggregate" if len(ports) > 1 else "port:" + ports[0]
        r["n_hp_ports"] = str(len(ports))
        r["hp_port_set"], r["ddr_port_set"] = portset(ports)
        extra.append("BwWindow: 128-bit lanes at the CORE clock, one async crossing each, no L2; cycles are FCLK0 cycles @ %.4f MHz" % f0)
        extra.append("; ".join(winlane.get((lvl, r["outstanding"]), ["no WINLANE lines"])))
    elif lvl.startswith("AP_"):
        r["hp_port_set"], r["ddr_port_set"] = portset(["HP0", "HP1", "HP2", "HP3"])
        r["scope"] = "harts through the DMA aperture (uncached, no L2)" if core else "BwProbe through the DMA aperture (uncached, no L2)"
        extra.append("DMA aperture 0x4000_0000 -> DDR 0x8000_0000, TLSourceShrinker(4), one async crossing; FCLK0 cycles")
    elif lvl == "DRAMW":
        r["scope"] = "core, via the L2 (coherent write, mb_write)"
    else:
        r["scope"] = "core, via the L2" if core else "BwProbe, via the L2"
    if core:
        r["notes"] = r["notes"].replace("membench mb_read", "membench mb_write" if lvl.endswith("W") else "membench mb_read")
    if note: extra.append(note)
    r["notes"] = r["notes"] + "; " + "; ".join(extra)
    out.append(r)
base = dict(timestamp=datetime.datetime.now().astimezone().isoformat(timespec="seconds"), bitstream_md5=md5,
            soc_magic=magic, config=cfg, fclk_core_mhz="%.4f" % f0, fclk_mem_mhz="%.4f" % f1, source="silicon",
            hpr_state=HPR, ddrqos_hash=QH, lut=rows[0].get("lut", ""), ff=rows[0].get("ff", ""), bram=rows[0].get("bram", ""),
            dsp=rows[0].get("dsp", ""), wns_ns=rows[0].get("wns_ns", ""), whs_ns=rows[0].get("whs_ns", ""))
flush = {}
for mm in re.finditer(r'^FLUSH level=(\S+) bytes=(\d+) blocks=(\d+) cycles=(\d+)$', txt, re.M):
    lvl, b, blocks, cyc = mm.groups()
    flush[lvl] = int(cyc) / int(blocks)
    r = dict(base, level=lvl, direction="flush", working_set_bytes=b, bytes_moved=b, cycles=cyc, outstanding="1",
             bytes_per_cycle="%.4f" % (int(b) / int(cyc)), mb_per_s="%.1f" % (int(b) / int(cyc) * f0),
             scope="core, L2 control +0x200, one write per 64-byte block",
             notes="L2 flush64 per block: cycles_per_block=%.3f blocks=%s; %s; bwwin ladder step %d" % (int(cyc) / int(blocks), blocks, "as-run " + qline, stp))
    out.append(r)
contracts = []
for mm in re.finditer(r'^CONTRACT test=(\S+) expect=(\S+) got=(\S+) ok=(\d)$', txt, re.M):
    t, e, g, ok = mm.groups()
    contracts.append((t, e, g, ok == "1"))
    out.append(dict(base, level="CONTRACT_" + t, direction="check", working_set_bytes=str(256 * 1024), outstanding="8",
                    scope="coherence contract (MEMORY_BANDWIDTH.md s9.4)",
                    notes="expect=%s got=%s %s; DMA reads by BwWindow lane 0 contiguous over HP0-HP3; bwwin ladder step %d" % (e, g, "ok" if ok == "1" else "CONTRACT VIOLATED", stp)))
with open(dst, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fields, lineterminator="\n", restval="", extrasaction="ignore"); w.writeheader(); w.writerows(out)

LEVER1 = {"L1": 7.0860, "L2": 2.8510}
lines, ok = [], True
core = {r["level"]: float(r["bytes_per_cycle"]) for r in out if r["notes"].startswith("core")}
for lvl, v in LEVER1.items():
    if lvl in core:
        d = 100.0 * (core[lvl] - v) / v; good = abs(d) <= 3.0; ok &= good
        lines.append("   core %-8s lever-1 %.3f  here %.3f  %+.1f%%  %s" % (lvl, v, core[lvl], d, "ok" if good else "*** DRIFTED ***"))
for lvl in ("DRAM", "DRAMW", "AP_DRAM", "AP_DRAMW"):
    if lvl in core:
        lines.append("   core %-8s %.4f B/cycle  %.1f MB/s  (reported)" % (lvl, core[lvl], core[lvl] * f0))
probe = [r for r in out if "mbxd_dma" in r["notes"]]
bad = [r for r in probe if "cksum_ok" not in r["notes"]]
ok &= not bad
if stp in (1, 2, 3, 5) and not any(r["level"].startswith("WIN_") for r in out):
    lines.append("   *** no WIN_ rows ***"); ok = False
if stp == 4 and not any(r["level"].startswith("AP_") for r in out):
    lines.append("   *** no AP_ rows ***"); ok = False
l2 = [r for r in probe if r["level"] == "L2" and int(r["outstanding"]) >= 2]
if any(abs(float(r["bytes_per_cycle"]) - 8.0) > 0.01 for r in l2):
    lines.append("   *** BwProbe's L2-hit path is not 8.00 at 2+ in flight ***"); ok = False
for r in probe:
    lines.append("   %-12s out=%-2s %8.4f B/cycle %8.1f MB/s  %s" % (r["level"], r["outstanding"], float(r["bytes_per_cycle"]),
                 float(r["mb_per_s"]), "ok" if "cksum_ok" in r["notes"] else "CHECKSUM MISMATCH"))
for k, v in flush.items():
    lines.append("   %-18s %.2f cycles per block" % (k, v))
for t, e, g, good in contracts:
    lines.append("   contract %-42s expect %-8s got %-8s %s" % (t, e, g, "ok" if good else "*** VIOLATED ***"))
    ok &= good
if stp == 4 and len(contracts) != 7:
    lines.append("   *** expected 7 CONTRACT lines, got %d ***" % len(contracts)); ok = False
m = re.search(r'^BWLAB done fails=(\d+)', txt, re.M)
if not m or m.group(1) != "0":
    lines.append("   *** guest reports fails=%s ***" % (m.group(1) if m else "?")); ok = False
lines.append("   checksums: %s" % ("all ok" if not bad else "%d MISMATCHED" % len(bad)))
lines.append("VERDICT " + ("PASS" if ok else "FAIL"))
open(verdict, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

step "4/4  append to fpga/pynq-z2/bwlab/results.csv (results lock)"
"$IISWC_ROOT/scripts/lib/with_lock.sh" results python3 - "$RUN/rows_final.csv" \
    "$IISWC_ROOT/fpga/pynq-z2/bwlab/results.csv" <<'PY'
import csv, sys
src, dst = sys.argv[1:3]
head = open(dst, newline="").readline().rstrip("\r\n").split(",")
rows = list(csv.DictReader(open(src, newline="")))
extra = sorted({k for r in rows for k, v in r.items() if k not in head and v})
if extra:
    sys.exit("results.csv has no column for %s -- not appending" % extra)
with open(dst, "a", newline="") as fh:
    csv.DictWriter(fh, fieldnames=head, lineterminator="\n", restval="", extrasaction="ignore").writerows(rows)
print("   appended %d rows by column name" % len(rows))
PY
python3 - "$RUN" "$BIT_MD5" "$MAGIC" "$CFG" "$LAB_RC" "$STEP" <<'PY'
import json, os, sys
run, md5, magic, cfg, rc, stp = sys.argv[1:7]
try:
    ddrc = json.load(open(os.path.join(run, "ddrc_afi.json")))
except Exception:
    ddrc = {"error": "unparseable"}
json.dump({"md5": md5, "variant": "bwwin", "magic": magic, "config": cfg, "ladder_step": int(stp), "lab_exit": int(rc),
           "fclk_readback": json.load(open(os.path.join(run, "fclk.json"))), "ddrc_afi_as_run": ddrc,
           "verdict": open(os.path.join(run, "verdict.txt")).read().splitlines()},
          open(os.path.join(run, "run.json"), "w"), indent=1)
PY
info "step $STEP: $(tail -n +2 "$RUN/rows_final.csv" | wc -l) rows appended; md5 $BIT_MD5; next: scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh"
grep -q "VERDICT PASS" "$RUN/verdict.txt" || die "verdict FAILED -- rows are appended and say so; see $RUN/verdict.txt"
