#!/usr/bin/env bash
# Lab B27 -- the bypass family (MEMORY_BANDWIDTH.md section 8): the SoC's own path toward the
# interface ceiling, with the L2 out of the path.
#
#   scripts/with_board.sh ./scripts/48_rocket_bwbypass_lab.sh --variant bwbypassl2
#   scripts/with_board.sh ./scripts/48_rocket_bwbypass_lab.sh --variant bwbypass --fclk1 100
#
# A wrapper around scripts/43_rocket_bwlab.sh (run from a snapshot, as 45 does), and
# host/run_rocket_bwl2.py, which SETS FCLK1 while the SoC is in reset and READS BOTH CLOCKS
# BACK from the SLCR with host/fclk.py before it leaves reset.  What this adds:
#
#   1. THE GUEST.  bwbypassl2 builds with --channels (DRAM_1CH / DRAM_2CH: one channel, or
#      HP0 and HP2 alternating).  bwbypass builds with EXTRA_CFLAGS=-DBWLAB_BYPASS=1: the
#      BwBypass lane sweep at 0x100B_0000 (levels BYP_*), after the SBUS sweep.  bwbypass as
#      built has two lanes on HP0 + HP2.
#   2. A TIMING GATE PER CLOCK.  FCLK0 must close at its constraint.  The memory domain must
#      close AT THE CLOCK THIS RUN SETS: 1000/FCLK1 >= 10.000 - WNS(clk_fpga_1).  A run below
#      the build's 100 MHz is legal; a run above closure is refused.  WHS >= 0 on both.
#   3. CLOCKS AND PORTS PER ROW.  fclk_core_mhz / fclk_mem_mhz are the READ-BACK values.
#      BYP_* rows count memory-bus cycles, so mb_per_s = B/cycle x FCLK1 there and FCLK0
#      everywhere else.  n_hp_ports is the ports the row's traffic used: the lane set for
#      BYP_*, the bitstream's channel count otherwise.  Per-lane windows and beats are in
#      the notes.
#   4. THE DDR CONTROLLER AND AFIs AS RUN.  host/ddrc_afi.py (read-only; it avoids the AFI
#      registers that can hang an unclocked port) is read after the lab with the PL still
#      loaded: its one-line summary goes into every row's notes, the JSON into run.json.  The
#      PS7 preset's QoS is what was asked for; this is what the FSBL left running.
#   5. Rows go to a scratch CSV, then to fpga/pynq-z2/bwlab/results.csv under
#      scripts/lib/with_lock.sh results; run.json keeps md5 + clock readback + verdict.
#
# Run it inside scripts/with_board.sh; it does not take the board lock itself.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
unset EXTRA_CFLAGS
VARIANT=""; FCLK1=""; NOTE=""; SECONDS_READ=480; TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="${2:?}"; shift 2 ;;
    --fclk1)   FCLK1="${2:?}"; shift 2 ;;
    --note)    NOTE="${2:?}"; shift 2 ;;
    --tag)     TAG="${2:?}"; shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
FCORE=34.4828
EXTRA=(); LANEPORTS=""
case "$VARIANT" in
  bwbypassl2) MAGIC=0x5A5A0014; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwPortsConfig; NCH=2
              [ -z "$FCLK1" ] || die "bwbypassl2 has one clock"; EXTRA=(--channels) ;;
  bwbypass)   MAGIC=0x5A5A0015; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwBypassConfig; NCH=2; LANEPORTS="0:HP0,1:HP2"
              [ -n "$FCLK1" ] || die "bwbypass puts the memory domain on FCLK1: give --fclk1"
              export EXTRA_CFLAGS="-DBWLAB_BYPASS=1" ;;
  bwbypass01) MAGIC=0x5A5A0016; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwBypassConfig; NCH=2; LANEPORTS="0:HP0,1:HP1"
              [ -n "$FCLK1" ] || die "bwbypass01 puts the memory domain on FCLK1: give --fclk1"
              export EXTRA_CFLAGS="-DBWLAB_BYPASS=1" ;;
  bwbypass4)  MAGIC=0x5A5A0017; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwBypass4Config; NCH=4; LANEPORTS="0:HP0,1:HP1,2:HP2,3:HP3"
              [ -n "$FCLK1" ] || die "bwbypass4 puts the memory domain on FCLK1: give --fclk1"
              export EXTRA_CFLAGS="-DBWLAB_BYPASS=1" ;;
  *) die "--variant must be bwbypassl2, bwbypass, bwbypass01 or bwbypass4" ;;
esac
BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_${VARIANT}${TAG:+_$TAG}_z1"
BIT="$BUILD/pynqz1_rocket_micrgb_${VARIANT}${TAG:+_$TAG}.bit"
need_file "$BIT" "no bitstream -- fpga/pynq-z2/scripts/build_bwbypass_z1.sh $VARIANT"
NAME="bwbypasslab_${VARIANT}${TAG:+_$TAG}${FCLK1:+_fclk1_$FCLK1}"
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")

step "0/4  timing gate at the clocks this run will set"
TIM="$BUILD/reports/timing_summary.rpt"
need_file "$TIM"
awk '/^Clock +Waveform/ {c=1} c && /^clk_fpga_[0-9]/ && !($1 in per) {per[$1]=$4} /^\| Intra Clock Table/ {t=1} t && /^clk_fpga_[0-9]/ {print $1, $2, $6, per[$1]} /^\| Inter Clock Table/ {t=0}' "$TIM" > "$RUN/timing.txt"
sed 's/^/   /' "$RUN/timing.txt"
python3 - "$RUN/timing.txt" "${FCLK1:-}" <<'PY' || die "timing gate: this run would measure a design outside its timing closure"
import sys
rows = {l.split()[0]: (float(l.split()[1]), float(l.split()[2]), float(l.split()[3])) for l in open(sys.argv[1]) if l.strip()}
f1 = sys.argv[2]
ok = True
w0, h0, _ = rows["clk_fpga_0"]
if w0 < 0 or h0 < 0: print("   clk_fpga_0 misses: WNS %.3f WHS %.3f" % (w0, h0)); ok = False
if f1:
    w1, h1, per1 = rows["clk_fpga_1"]
    need = per1 - w1                    # the period at which the memory domain closes
    have = 1000.0 / float(f1)
    print("   memory domain closes at %.3f ns (%.2f MHz); this run: %.3f ns (%.4f MHz) -> %s"
          % (need, 1000.0 / need, have, float(f1), "ok" if have >= need else "REFUSED"))
    if have < need or h1 < 0: ok = False
sys.exit(0 if ok else 1)
PY

step "1/4  the per-run clock file, and fclk.py, onto the board"
bitstream_identify "$BIT"
python3 - "$MAGIC" "$FCLK1" "$BIT_MD5" > "$RUN/bwl2_run.json" <<'PY'
import json, sys
magic, f1, md5 = sys.argv[1:4]
print(json.dumps({"magic": magic, "fclk1_mhz": float(f1) if f1 else None, "md5": md5}))
PY
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$IISWC_ROOT/fpga/pynq-z2/host/ddrc_afi.py" \
    "$RUN/bwl2_run.json" "$PYNQ_HOST:$PYNQ_DIR/"
LAB43="$IISWC_ROOT/scripts/.43_snapshot_bwbypass_$$.sh"
cleanup () { rm -f "$LAB43"; "${SSH[@]}" "rm -f $PYNQ_DIR/bwl2_run.json" >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "2/4  the lab (scripts/43_rocket_bwlab.sh snapshot), rows to a scratch CSV"
cp "$IISWC_ROOT/scripts/43_rocket_bwlab.sh" "$LAB43"
bash -n "$LAB43" || die "scripts/43_rocket_bwlab.sh does not parse right now (someone is editing it?)"
SCRATCH="$RUN/rows.csv"
head -1 "$IISWC_ROOT/fpga/pynq-z2/bwlab/results.csv" > "$SCRATCH"
set +e
BWLAB_CSV="$SCRATCH" bash "$LAB43" --name "$NAME/lab" --bit "$BIT" --build "$BUILD" \
    --runner run_rocket_bwl2.py --magic "$MAGIC" --config "$CFG" --ports "$NCH" \
    --fclk-core "$FCORE" --fclk-mem "${FCLK1:-$FCORE}" --seconds "$SECONDS_READ" "${EXTRA[@]}"
LAB_RC=$?
set -e
LABDIR="$IISWC_OUT/$NAME/lab"
grep -h '^FCLK_READBACK ' "$LABDIR/boot.log" | tail -1 | sed 's/^FCLK_READBACK //' > "$RUN/fclk.json" || true
[ -s "$RUN/fclk.json" ] || die "no FCLK_READBACK in $LABDIR/boot.log -- the clocks were not verified, rows NOT appended"
[ "$(tail -n +2 "$SCRATCH" | wc -l)" -gt 0 ] || die "the lab produced no rows (exit $LAB_RC)"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 ddrc_afi.py" > "$RUN/ddrc_afi.json" 2>/dev/null \
  && "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 ddrc_afi.py --summary" > "$RUN/ddrc_afi.txt" 2>/dev/null \
  || { warn "ddrc_afi.py could not be read -- rows say so"; echo "not read" > "$RUN/ddrc_afi.txt"; echo "{}" > "$RUN/ddrc_afi.json"; }
info "DDRC/AFI as run: $(head -c 300 "$RUN/ddrc_afi.txt")"

step "3/4  rows: as-run clocks, the instrument's clock, the ports used; the verdict"
python3 - "$SCRATCH" "$RUN/fclk.json" "$LABDIR/console.txt" "$VARIANT" "$NCH" "$NOTE" \
          "$RUN/rows_final.csv" "$RUN/verdict.txt" "$RUN/ddrc_afi.txt" "$LANEPORTS" <<'PY'
import csv, json, re, sys
src, fj, console, variant, nch, note, dst, verdict, qos, laneports = sys.argv[1:11]
lane_hp = dict(x.split(':') for x in laneports.split(',')) if laneports else {}
# results.csv's shared columns (s7's convention, host/axiceil_lab.py): HP port set "HP0+HP2",
# DDR controller ports sorted high to low "3+2", the as-run QoS state and its hash.
DDRC_PORT = {"HP0": 3, "HP1": 3, "HP2": 2, "HP3": 2}
try:
    qtext = open(qos).read()
except OSError:
    qtext = qos
m = re.search(r"hpr_rd_p0123=(\d{4}) lpr_entries_field=(\d+)", qtext)
HPR_STATE = ("HPR rd p0123=%s; lpr_num_entries=%s" % m.groups()) if m else "unknown"
m = re.search(r"qos_hash=([0-9a-f]+)", qtext)
QOS_HASH = m.group(1) if m else ""
def portset(ports):
    ports = sorted(ports, key=lambda x: int(x[2:]))
    return "+".join(ports), "+".join(str(x) for x in sorted({DDRC_PORT[p] for p in ports}, reverse=True))
qos = open(qos).read().strip().splitlines()[-1] if open(qos).read().strip() else "not read"
clk = json.load(open(fj)); f0 = clk["fclk0"]["mhz"]; f1 = clk["fclk1"]["mhz"]
memclk = variant in ("bwbypass", "bwbypass01", "bwbypass4")
txt = open(console).read()
lanes = {}
for m in re.finditer(r'^BYPLANE level=(\S+) out=(\d+) lane=(\d+) cycles=(\d+) beats=(\d+) reqs=(\d+) peak=(\d+)$', txt, re.M):
    lvl, out, lane, cyc, beats, reqs, peak = m.groups()
    lanes.setdefault((lvl, out), []).append("lane%s cycles=%s beats=%s reqs=%s peak=%s" % (lane, cyc, beats, reqs, peak))
def byp_lanes(level):
    """lanes a BYP_ level used: BYP_L01 -> ['0','1']; BYP_SEQ -> lane 0 over every channel."""
    return None if level == "BYP_SEQ" else list(level[len("BYP_L"):])
rows = list(csv.DictReader(open(src)))
fields = open(src).readline().strip().split(",")
out = []
for r in rows:
    byp = r["level"].startswith("BYP_")
    core = r["notes"].startswith("core")
    r["fclk_core_mhz"] = "%.4f" % f0
    r["fclk_mem_mhz"] = "%.4f" % (f1 if memclk else f0)
    mhz = f1 if byp else f0
    r["mb_per_s"] = "%.1f" % (float(r["bytes_per_cycle"]) * mhz)
    ls = byp_lanes(r["level"]) if byp else None
    if byp and ls is not None:
        ports = sorted({lane_hp[l] for l in ls})
    else:
        ports = sorted(set(lane_hp.values())) if lane_hp else (["HP0", "HP2"] if variant == "bwbypassl2" else [])
    if byp:
        r["n_hp_ports"] = str(len(ports))
    if ports:
        r["hp_port_set"], r["ddr_port_set"] = portset(ports)
    r["burst_beats"] = r.get("burst_beats") or "8"
    r["scope"] = ("aggregate" if byp and ls is not None and len(ls) > 1 else
                  "port:" + ports[0] if byp and ls is not None else
                  "one D channel over " + "+".join(ports) if byp else
                  "core, via the L2" if core else "BwProbe, via the L2")
    r["hpr_state"], r["ddrqos_hash"] = HPR_STATE, QOS_HASH
    extra = ["fclk_readback FCLK0=%.4f FCLK1=%.4f" % (f0, f1), "as-run " + qos]
    if byp:
        extra.append("BwBypass on MBUS, no L2; ports %s%s; cycles are memory-bus (FCLK1) cycles @ %.4f MHz"
                     % ("+".join(ports), " behind ONE D channel (lane 0, contiguous)" if ls is None else "", f1))
        extra.append("; ".join(lanes.get((r["level"], r["outstanding"]), ["no BYPLANE lines"])))
    elif not core:
        extra.append("BwProbe on SBUS behind the L2; cycles are FCLK0 cycles; %s memory channels" % nch)
    if note:
        extra.append(note)
    r["notes"] = r["notes"] + "; " + "; ".join(extra)
    out.append(r)
for c in ("burst_beats", "hp_port_set", "ddr_port_set", "scope", "hpr_state", "ddrqos_hash"):
    if c not in fields: fields.append(c)
with open(dst, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fields, lineterminator="\n", restval=""); w.writeheader(); w.writerows(out)

LEVER1 = {"L1": 7.0860, "L2": 2.8510, "DRAM": 1.3690}
lines, ok = [], True
core = {r["level"]: float(r["bytes_per_cycle"]) for r in out if r["notes"].startswith("core")}
for lvl in ("L1", "L2", "DRAM"):
    if lvl not in core: continue
    d = 100.0 * (core[lvl] - LEVER1[lvl]) / LEVER1[lvl]
    gated = not (memclk and lvl == "DRAM")
    good = abs(d) <= 3.0
    if gated: ok &= good
    lines.append("   core %-4s lever-1 %.3f  here %.3f  %+.1f%%  %s" % (lvl, LEVER1[lvl], core[lvl], d,
                 ("ok" if good else "*** DRIFTED ***") if gated else "crossing cost (reported, not gated)"))
bad = [r for r in out if "mbxd_dma" in r["notes"] and "cksum_ok" not in r["notes"]]
if bad: ok = False
l2 = [r for r in out if r["level"] == "L2" and "mbxd_dma" in r["notes"] and int(r["outstanding"]) >= 2]
if any(abs(float(r["bytes_per_cycle"]) - 8.0) > 0.01 for r in l2):
    lines.append("   *** BwProbe's L2-hit path is not 8.00 at 2+ in flight ***"); ok = False
if memclk and not any(r["level"].startswith("BYP_") for r in out):
    lines.append("   *** no BYP_ rows: the bypass sweep did not run ***"); ok = False
for r in out:
    if "mbxd_dma" in r["notes"] and (r["level"].startswith("BYP_") or r["level"].startswith("DRAM")):
        lines.append("   %-12s out=%-2s %8.4f B/cycle %8.1f MB/s  %s" % (r["level"], r["outstanding"],
                     float(r["bytes_per_cycle"]), float(r["mb_per_s"]), "ok" if "cksum_ok" in r["notes"] else "CHECKSUM MISMATCH"))
lines.append("   checksums: %s" % ("all ok" if not bad else "%d MISMATCHED" % len(bad)))
lines.append("VERDICT " + ("PASS" if ok else "FAIL"))
open(verdict, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

step "4/4  append to fpga/pynq-z2/bwlab/results.csv (results lock)"
# Remapped by COLUMN NAME at append time, under the lock: results.csv's header can gain
# columns while a run is in progress (s7 added six), and a positional append would misalign.
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
info "appended $(tail -n +2 "$RUN/rows_final.csv" | wc -l) rows; md5 $BIT_MD5"
python3 - "$RUN" "$BIT_MD5" "$VARIANT" "$MAGIC" "$CFG" "$LAB_RC" <<'PY'
import json, os, sys
run, md5, variant, magic, cfg, rc = sys.argv[1:7]
try:
    ddrc = json.load(open(os.path.join(run, "ddrc_afi.json")))
except Exception:
    ddrc = {"error": "unparseable", "raw": open(os.path.join(run, "ddrc_afi.json")).read()[:2000]}
json.dump({"md5": md5, "variant": variant, "magic": magic, "config": cfg, "lab_exit": int(rc),
           "fclk_readback": json.load(open(os.path.join(run, "fclk.json"))),
           "ddrc_afi_as_run": ddrc,
           "verdict": open(os.path.join(run, "verdict.txt")).read().splitlines()},
          open(os.path.join(run, "run.json"), "w"), indent=1)
PY
grep -q "VERDICT PASS" "$RUN/verdict.txt" || die "verdict FAILED -- rows are appended and say so; see $RUN/verdict.txt"
