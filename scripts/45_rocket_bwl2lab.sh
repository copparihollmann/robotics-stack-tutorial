#!/usr/bin/env bash
# Lab B22, on the L2-miss-path bitstreams (MEMORY_BANDWIDTH.md section 6) -- and on any
# bandwidth bitstream whose FCLK1 has to be SET and VERIFIED rather than assumed.
#
#   scripts/with_board.sh ./scripts/45_rocket_bwl2lab.sh --variant bwl2mshr
#   scripts/with_board.sh ./scripts/45_rocket_bwl2lab.sh --variant bwl2cap
#   scripts/with_board.sh ./scripts/45_rocket_bwl2lab.sh --variant bwl2fast --tag f40 --fclk1 40
#   scripts/with_board.sh ./scripts/45_rocket_bwl2lab.sh --variant bwfast --fclk1 100 \
#        --note "lever 2 re-run at a verified FCLK1"
#
# It is a wrapper, not a second lab: the guest, the instrument sweep, the row format and the
# first calibration print are scripts/43_rocket_bwlab.sh's, unchanged.  What it adds:
#
#   1. THE CLOCKS ARE SET AND READ BACK.  host/run_rocket_bwl2.py sets FCLK1 through
#      pynq.ps.Clocks while the SoC is held in reset and reads FCLK0 and FCLK1 back from the
#      SLCR with host/fclk.py before the SoC leaves reset.  The readback, not the request, is
#      what goes into results.csv (fclk_mem_mhz) and into run.json beside the md5.
#   2. THE INSTRUMENT'S CLOCK.  BwProbe counts cycles of the clock it sits on.  On bwl2fast
#      that is FCLK1, not the tiles' FCLK0, so MB/s is B/cycle x FCLK1 there and the notes
#      say so.  Core rows are always tile cycles.
#   3. A TIMING GATE.  A build whose routed design misses setup or hold on any clock is not
#      measured (--allow-timing-fail overrides, and says so in every row).
#   4. A CALIBRATION VERDICT PER VARIANT.  On a build where the tiles and the L2 share a clock
#      the core half must reproduce lever 1 (0x5A5A0007: L1 7.086, L2 2.851, DRAM 1.369
#      B/cycle) within 3 %.  On bwl2fast only L1 must: every L1 miss now crosses an
#      AsynchronousCrossing, so the core's L2 and DRAM figures are EXPECTED to move, and how
#      far is the cost of the crossing, reported rather than gated.
#   5. Rows go to a scratch CSV first and are appended to fpga/pynq-z2/bwlab/results.csv
#      under scripts/lib/with_lock.sh results.
#
#   5b. --writer: the guest instead runs a write-and-verify loop on hart 1 over 1 MiB of DRAM
#      (16x the L2, so its evictions are dirty) while hart 0 runs the instrument's DRAM read at
#      4 and 8 in flight.  WRITER lines (per-line store latency max, a p99.9 bound, lines over
#      1,000 cycles, mismatches) go into the DRAMW rows' notes, and any mismatch fails the run.
#      The silicon counterpart of the model's concurrent-writer test (MEMORY_BANDWIDTH.md s6.8).
#   6. --lenet: then Lab B10 (scripts/30_rocket_mb_lenet_pext_board.sh) on the SAME loaded
#      configuration -- the MBP LeNet and the scalar LeNet on hart 0 -- whose cycle counts are
#      what an asynchronous tile crossing costs a real network.  Appended to
#      fpga/pynq-z2/bwlab/core_cost.csv.  --lenet-only skips the bandwidth half.
#
# Run it inside scripts/with_board.sh; it does not take the board lock itself.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

unset EXTRA_CFLAGS
VARIANT=""; TAG=""; FCLK1=""; NOTE=""; ALLOW_TIMING_FAIL=0; SECONDS_READ=300; EXTRA=(); LENET=0; SKIP_BW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="${2:?}"; shift 2 ;;
    --tag)     TAG="${2:?}"; shift 2 ;;
    --fclk1)   FCLK1="${2:?}"; shift 2 ;;
    --note)    NOTE="${2:?}"; shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --allow-timing-fail) ALLOW_TIMING_FAIL=1; shift ;;
    --lenet)   LENET=1; shift ;;
    --mid-kb)  export EXTRA_CFLAGS="-DBWLAB_MID_KB=${2:?}"; shift 2 ;;
    --writer)  export EXTRA_CFLAGS="-DBWLAB_WRITER=1"; shift ;;
    --lenet-only) LENET=1; SKIP_BW=1; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
FCORE=34.4828
case "$VARIANT" in
  bw)       MAGIC=0x5A5A0007; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwConfig ;;
  bwfast)   MAGIC=0x5A5A0008; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwFastConfig
            [ -n "$FCLK1" ] || die "bwfast puts the memory domain on FCLK1: give --fclk1" ;;
  bwl2mshr) MAGIC=0x5A5A000B; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwL2Mshr12Config ;;
  bwl2cap)  MAGIC=0x5A5A000C; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwL2Cap256Config ;;
  bwl2cork) MAGIC=0x5A5A000E; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwL2CorkConfig ;;
  bwl2skip) MAGIC=0x5A5A001A; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwL2SkipConfig ;;
  bwl2wsf)  MAGIC=0x5A5A0018; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipFastConfig
            [ -n "$FCLK1" ] || die "bwl2wsf puts the memory bus on FCLK1: give --fclk1" ;;
  bwl2wsmf) MAGIC=0x5A5A0019; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipM12FastConfig
            [ -n "$FCLK1" ] || die "bwl2wsmf puts the memory bus on FCLK1: give --fclk1" ;;
  bwl2fast) MAGIC=0x5A5A000D; CFG=PynqZ2RocketBigLittlePextTacitMicRgbBwL2FastConfig
            [ -n "$FCLK1" ] || die "bwl2fast puts the L2 on FCLK1: give --fclk1" ;;
  *) die "--variant must be bw, bwfast, bwl2mshr, bwl2cap, bwl2cork, bwl2skip, bwl2wsf, bwl2wsmf or bwl2fast" ;;
esac
case "$VARIANT" in bwfast|bwl2fast|bwl2wsf|bwl2wsmf) ;; *) [ -z "$FCLK1" ] || die "$VARIANT does not use FCLK1" ;; esac

BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_${VARIANT}${TAG:+_$TAG}_z1"
BIT="$BUILD/pynqz1_rocket_micrgb_${VARIANT}${TAG:+_$TAG}.bit"
need_file "$BIT" "no bitstream -- fpga/pynq-z2/scripts/build_bwl2_z1.sh $VARIANT"
NAME="bwl2lab_${VARIANT}${TAG:+_$TAG}${FCLK1:+_fclk1_$FCLK1}"
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")

step "0/4  timing gate: $BUILD"
TIM="$BUILD/reports/timing_summary.rpt"
need_file "$TIM"
awk '/^\| Intra Clock Table/ {t=1} t && /^clk_fpga_[0-9]/ {print "   " $1 "  WNS " $2 "  WHS " $6} /^\| Inter Clock Table/ {t=0}' "$TIM" | tee "$RUN/timing.txt"
if awk '/^\| Intra Clock Table/ {t=1} t && /^clk_fpga_[0-9]/ && ($2+0 < 0 || $6+0 < 0) {bad=1} /^\| Inter Clock Table/ {t=0} END {exit !bad}' "$TIM"; then
  [ "$ALLOW_TIMING_FAIL" = 1 ] || die "this build misses timing on at least one clock; it is a
       result (the failing path), not a machine to measure.  --allow-timing-fail to override."
  NOTE="${NOTE:+$NOTE; }TIMING FAILED, measured anyway"
fi

# The Zephyr image's clock.  mtime ticks at the UNCORE clock / 1000, and the same number
# sets the SiFive UART divisor, so on bwl2fast it has to follow FCLK1 or the console is
# garbled.  Every other variant keeps the board's 34483.
unset EXTRA_CONF_FILE
if [ "$VARIANT" = bwl2fast ]; then
  HZ=$(python3 -c "print(round(float('$FCLK1') * 1000))")
  if [ "$HZ" != 34483 ]; then
    printf 'CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=%s\n' "$HZ" > "$RUN/uncore_clock.conf"
    export EXTRA_CONF_FILE="$RUN/uncore_clock.conf"
    info "guest: CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ (the uncore is on FCLK1)"
  fi
fi

step "1/4  the per-run clock file, and fclk.py, onto the board"
bitstream_identify "$BIT"
python3 - "$MAGIC" "$FCLK1" "$BIT_MD5" > "$RUN/bwl2_run.json" <<'PY'
import json, sys
magic, f1, md5 = sys.argv[1:4]
print(json.dumps({"magic": magic, "fclk1_mhz": float(f1) if f1 else None, "md5": md5}))
PY
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/bwl2_run.json" "$PYNQ_HOST:$PYNQ_DIR/"
cleanup () { rm -f "$IISWC_ROOT/scripts/.43_snapshot_$$.sh"; "${SSH[@]}" "rm -f $PYNQ_DIR/bwl2_run.json" >/dev/null 2>&1 || true; }
trap cleanup EXIT

CAL_FAIL=0
if [ "$SKIP_BW" = 0 ]; then
step "2/4  the lab (scripts/43_rocket_bwlab.sh), rows to a scratch CSV"
SCRATCH="$RUN/rows.csv"
# A SNAPSHOT of scripts/43, run in place of the file itself.  Several agents edit 43 while
# labs run, and bash reads a script incrementally -- an edit landing mid-run turned one of
# these runs into "syntax error near unexpected token" half way through.  The copy lives
# beside the original so its `lib/` paths still resolve, and it is removed on exit.
LAB43="$IISWC_ROOT/scripts/.43_snapshot_$$.sh"
cp "$IISWC_ROOT/scripts/43_rocket_bwlab.sh" "$LAB43"
bash -n "$LAB43" || die "scripts/43_rocket_bwlab.sh does not parse right now (someone is editing it?)"
info "43 snapshot md5 $(md5sum "$LAB43" | cut -d' ' -f1)"
head -1 "$IISWC_ROOT/fpga/pynq-z2/bwlab/results.csv" > "$SCRATCH"
set +e
BWLAB_CSV="$SCRATCH" BIT_ACCEPTED="${BIT_ACCEPTED:-} $BIT_MD5" \
  bash "$LAB43" --name "$NAME/lab" --bit "$BIT" --build "$BUILD" \
    --runner run_rocket_bwl2.py --magic "$MAGIC" --config "$CFG" \
    --fclk-core "$FCORE" --fclk-mem "${FCLK1:-$FCORE}" --seconds "$SECONDS_READ" "${EXTRA[@]}"
LAB_RC=$?
set -e
LABDIR="$IISWC_OUT/$NAME/lab"
grep -h '^FCLK_READBACK ' "$LABDIR/boot.log" | tail -1 | sed 's/^FCLK_READBACK //' > "$RUN/fclk.json" || true
[ -s "$RUN/fclk.json" ] || die "no FCLK_READBACK in $LABDIR/boot.log -- the clocks were not verified, rows NOT appended"
[ "$(tail -n +2 "$SCRATCH" | wc -l)" -gt 0 ] || die "the lab produced no rows (exit $LAB_RC)"

step "3/4  rows: the as-run clocks, the instrument's clock, the calibration verdict"
python3 - "$SCRATCH" "$RUN/fclk.json" "$VARIANT" "$NOTE" "$RUN/rows_final.csv" "$RUN/verdict.txt" "$LABDIR/console.txt" <<'PY'
import csv, json, re, sys
src, fj, variant, note, dst, verdict, console = sys.argv[1:8]
writer = {}
try:
    for m in re.finditer(r"^WRITER phase=(\S+) (.*)$", open(console).read(), re.M):
        writer[m.group(1)] = m.group(2).strip()
except OSError:
    pass
clk = json.load(open(fj))
f0 = clk["fclk0"]["mhz"]; f1 = clk["fclk1"]["mhz"]
fast = variant == "bwl2fast"
uses_f1 = variant in ("bwfast", "bwl2fast", "bwl2wsf", "bwl2wsmf")
rows = list(csv.DictReader(open(src)))
fields = open(src).readline().strip().split(",")
out = []
for r in rows:
    r["fclk_core_mhz"] = "%.4f" % f0
    r["fclk_mem_mhz"] = "%.4f" % (f1 if uses_f1 else f0)
    core = r["notes"].startswith("core")
    probe_mhz = f1 if (fast and not core) else f0
    r["mb_per_s"] = "%.1f" % (float(r["bytes_per_cycle"]) * probe_mhz)
    extra = ["fclk_readback FCLK0=%.4f FCLK1=%.4f" % (f0, f1)]
    if not core:
        extra.append("probe cycles are %s cycles @ %.4f MHz" % ("FCLK1 (uncore+L2)" if fast else "FCLK0", probe_mhz))
    if writer and r["level"] == "DRAMW":
        ph = "probe%s" % r["outstanding"]
        extra.append("writer on hart 1 while this ran: %s; writer alone: %s" % (writer.get(ph, "?"), writer.get("quiet", "?")))
    if note:
        extra.append(note)
    r["notes"] = r["notes"] + "; " + "; ".join(extra)
    out.append(r)
with open(dst, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fields); w.writeheader(); w.writerows(out)

# Calibration verdict.
LEVER1 = {"L1": 7.0860, "L2": 2.8510, "DRAM": 1.3690}   # 0x5A5A0007, results.csv
# startswith, not `in`: the probe rows' notes now say "uncore", which contains "core".
core = {r["level"]: float(r["bytes_per_cycle"]) for r in out if r["notes"].startswith("core")}
lines, ok = [], True
for lvl in ("L1", "L2", "DRAM"):
    if lvl not in core: continue
    d = 100.0 * (core[lvl] - LEVER1[lvl]) / LEVER1[lvl]
    gated = (lvl == "L1") or not fast
    good = abs(d) <= 3.0
    if gated: ok &= good
    tag = ("ok" if good else "*** DRIFTED ***") if gated else "crossing cost (reported, not gated)"
    lines.append("   core %-4s lever-1 %.3f  here %.3f  %+.1f%%  %s" % (lvl, LEVER1[lvl], core[lvl], d, tag))
prb = {}
for r in out:
    if "mbxd_dma" in r["notes"]:
        prb.setdefault(r["level"], {})[int(r["outstanding"])] = (float(r["bytes_per_cycle"]), float(r["mb_per_s"]), r["notes"])
for lvl in sorted(prb):
    for o in sorted(prb[lvl]):
        b, m, n = prb[lvl][o]
        lines.append("   probe %-5s out=%d  %.4f B/cycle  %.1f MB/s  %s" % (lvl, o, b, m, "cksum_ok" if "cksum_ok" in n else "CHECKSUM MISMATCH"))
        if "cksum_ok" not in n: ok = False
l2 = prb.get("L2", {})
if any(o >= 2 and abs(v[0] - 8.0) > 0.01 for o, v in l2.items()):
    lines.append("   *** the instrument's L2-hit path is not at 8.00 B/cycle at 2+ in flight ***"); ok = False
for ph, txt in writer.items():
    lines.append("   writer %-7s %s" % (ph, txt))
    mm = re.search(r"bad=(\d+)", txt)
    if mm and int(mm.group(1)) != 0:
        lines.append("   *** the hart-1 writer read back %s wrong words ***" % mm.group(1)); ok = False
lines.append("CALIBRATION " + ("PASS" if ok else "FAIL"))
open(verdict, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

step "4/4  append to fpga/pynq-z2/bwlab/results.csv (results lock)"
"$IISWC_ROOT/scripts/lib/with_lock.sh" results \
  bash -c "tail -n +2 '$RUN/rows_final.csv' >> '$IISWC_ROOT/fpga/pynq-z2/bwlab/results.csv'"
info "appended $(tail -n +2 "$RUN/rows_final.csv" | wc -l) rows; md5 $BIT_MD5; clocks $(cat "$RUN/fclk.json" | head -c 400)"
python3 - "$RUN" "$BIT_MD5" "$VARIANT" "$TAG" "$MAGIC" "$CFG" "$LAB_RC" <<'PY'
import json, sys, os
run, md5, variant, tag, magic, cfg, rc = sys.argv[1:8]
json.dump({"md5": md5, "variant": variant, "tag": tag, "magic": magic, "config": cfg,
           "lab_exit": int(rc), "fclk_readback": json.load(open(os.path.join(run, "fclk.json"))),
           "verdict": open(os.path.join(run, "verdict.txt")).read().splitlines()},
          open(os.path.join(run, "run.json"), "w"), indent=1)
PY
grep -q "CALIBRATION PASS" "$RUN/verdict.txt" || { warn "calibration FAILED -- rows are appended and say so; see $RUN/verdict.txt"; CAL_FAIL=1; }
fi

if [ "$LENET" = 1 ]; then
  step "5/5  Lab B10 LeNet (MBP and scalar) on this configuration"
  HZ_L=34483
  [ "$VARIANT" = bwl2fast ] && HZ_L=$(python3 -c "print(round(float('$FCLK1') * 1000))")
  # scripts/30 re-loads the bitstream through run_rocket_bwl2.py, which reads the same
  # bwl2_run.json and so sets and verifies the same FCLK1 again.
  LAB30="$IISWC_ROOT/scripts/.30_snapshot_$$.sh"
  cp "$IISWC_ROOT/scripts/30_rocket_mb_lenet_pext_board.sh" "$LAB30"
  # --board chipyard_pynqz1_micrgb, not Lab B10's chipyard_pynqz1_pext: every bitstream here
  # is the micrgb SoC (7 PLIC sources, GPIO, microphone).  The pext board's image -- md5
  # b3cda337, byte-identical to the one validated on 0x5A5A0004 -- took an instruction access
  # fault at mepc 0 on 0x5A5A0007.
  bash "$LAB30" --name "$NAME/lenet" --bit "$BIT" --board chipyard_pynqz1_micrgb \
      --runner run_rocket_bwl2.py --magic "$MAGIC" --mtime-hz "$HZ_L" \
    || { rm -f "$LAB30"; die "Lab B10 failed on this configuration -- see $IISWC_OUT/$NAME/lenet"; }
  rm -f "$LAB30"
  grep -h '^FCLK_READBACK ' "$IISWC_OUT/$NAME/lenet/boot.log" | tail -1 | sed 's/^FCLK_READBACK //' > "$RUN/fclk_lenet.json"
  [ -s "$RUN/fclk_lenet.json" ] || die "Lab B10 ran without an FCLK readback -- not recorded"
  python3 - "$IISWC_OUT/$NAME/lenet/run.json" "$RUN/fclk_lenet.json" "$BIT_MD5" "$MAGIC" "$CFG" \
            "$VARIANT${TAG:+_$TAG}" "$NOTE" "$RUN/core_cost_rows.csv" <<'PY'
import csv, datetime, json, sys
rj, fj, md5, magic, cfg, variant, note, out = sys.argv[1:9]
d = json.load(open(rj)); c = json.load(open(fj))
m = d["measured"]
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
fields = ["timestamp", "bitstream_md5", "soc_magic", "config", "variant", "fclk0_mhz",
          "fclk1_mhz", "workload", "hart", "median_cycles", "min_cycles", "max_cycles",
          "iters", "bitexact", "source", "notes"]
rows = []
for key, wl in (("pext_hart0", "lenet_int8_mbp"), ("scalar_hart0", "lenet_int8_scalar"),
                ("scalar_hart1", "lenet_int8_scalar")):
    if key not in m: continue
    v = m[key]
    rows.append(dict(timestamp=now, bitstream_md5=md5, soc_magic=magic, config=cfg,
                     variant=variant, fclk0_mhz="%.4f" % c["fclk0"]["mhz"],
                     fclk1_mhz="%.4f" % c["fclk1"]["mhz"], workload=wl, hart=key[-1],
                     median_cycles=v.get("median_cycles", ""), min_cycles=v.get("min_cycles", ""),
                     max_cycles=v.get("max_cycles", ""), iters=d.get("iters", ""),
                     # run.json has no "bitexact" key: Lab B10 records max_abs_err_vs_scalar_golden
                     # (the column was empty on every row before 2026-09-17; bwlab/errata.csv).
                     bitexact=("" if d.get("results", {}).get("max_abs_err_vs_scalar_golden") is None
                               else str(d["results"]["max_abs_err_vs_scalar_golden"] == 0)),
                     source="silicon", notes="scripts/30 via 45_rocket_bwl2lab.sh; cycles are tile (hart) cycles" + ("; " + note if note else "")))
    print("   %-18s hart %s  median %s cycles" % (wl, key[-1], v.get("median_cycles")))
with open(out, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fields); w.writeheader(); w.writerows(rows)
PY
  CC="$IISWC_ROOT/fpga/pynq-z2/bwlab/core_cost.csv"
  "$IISWC_ROOT/scripts/lib/with_lock.sh" results bash -c \
    "[ -f '$CC' ] || head -1 '$RUN/core_cost_rows.csv' > '$CC'; tail -n +2 '$RUN/core_cost_rows.csv' >> '$CC'"
  info "LeNet rows appended to $CC"
fi
[ "$CAL_FAIL" = 0 ] || die "calibration FAILED on the bandwidth half -- see $RUN/verdict.txt"
