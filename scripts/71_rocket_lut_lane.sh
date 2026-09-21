#!/usr/bin/env bash
# Lab B37 -- M1/M2/M3: THE FIRST DISPATCH EVER ISSUED TO T4's LUT LANE.
#
#   ./scripts/71_rocket_lut_lane.sh --build-only
#   scripts/with_board.sh ./scripts/71_rocket_lut_lane.sh --prebuilt out/rocket_lut_lane_prebuilt
#
# WHY.  `0x5A5A002C` has carried `mbxl_lut` since 2026-09-17 -- 8 elements/cycle, 0 DSP, 0 BRAM,
# +581 LUT in context, 53 Verilator dispatches / 73,936 byte checks / 0 differ, 11 of 11 mutants
# killed -- and NOTHING HAS EVER DISPATCHED TO IT.  MAGIC_REGISTRY.md's own row says that until
# M1 and M2 run it records "a closed build and not a function".
#
# PREDICTED BEFORE THIS RAN, T4_LANES.md s10 (commit 3414a2a):
#   M1  slope 0.125 cycles/element [0.118, 0.140], intercept 150 cycles [110, 400]
#   M2  1,300-2,900 cycles per 8,192-element tile PIPELINED, against a 3,100-4,400 SEQUENTIAL
#       control.  The control is not optional: a sequential harness lands in the serialised
#       band whatever the hardware permits and is indistinguishable by cycle count from an
#       engine that does not overlap (T4_LANES.md s8.5).
#   M3  placement 14-16 cycles/byte byte-wise, 2.0-3.0 word-wise.  s10.1's sensitivity table
#       says this decides the end-to-end answer and M1 does not.
#   PROJECTION  RTF_e2e 5.533 -> 5.069 [5.06, 5.09], falsified by P-F1/P-F2/P-F3 in s10.1.
#
# AND THE BYTE CHECK IS THE POINT, NOT A BONUS.  s8.5 outcome 3: a `cfg` that re-points the
# lane mid-stream, or a load into the buffer the lane is reading, produces plausible cycle
# counts over corrupted data with no error bit anywhere.  A timing fit cannot see it.  This
# script FAILS on `not_compared` (438eb27) and on `lut_ok = 0`.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

LUT2_MD5="${LUT2_MD5:-}"          # filled in below once 0x5A5A002D is built and archived
NAME="rocket_lut_lane"
BOARD="chipyard_pynqz1_micrgb"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonlut_z1/pynqz1_rocket_micrgb_roccmoonlut.bit"
RUNNER="run_rocket_roccmoonlut.py"
SAMPLE="$IISWC_ROOT/samples/lut_lane_smoke"
WANT_MAGIC="0x5A5A002C"; FCLK_CORE=34.4828; SECONDS_READ=300
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    # NEVER HOLD THE BOARD ACROSS A BUILD: step 1 needs no board, so it is done off the lock.
    --build-only) BUILD_ONLY=1; shift ;;
    --prebuilt) PREBUILT="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
# 0x5A5A002C, roccmoonlut at 350db66.  Pinned, not widened: this is the only build that
# contains the lane, and running this lab on one that does not is the f256a3b failure.
# 0x5A5A002C (roccmoonlut, the lane with the HELD out_valid: arm A hung on it, arm B measured
# M1 within 256 words on it) and 0x5A5A002D (roccmoonlut2, out_valid pulsed).  Both are pinned
# by md5, not widened: running this lab on a build without the lane is the f256a3b failure, and
# running it on the unfixed lane without knowing which is the arm-A failure.
BIT_ACCEPTED="${BIT_ACCEPTED:-} fc26e76dc83e7826206252bd0be64bbe $LUT2_MD5"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
[ -n "${BUILD_ONLY:-}" ] && RUN="$IISWC_OUT/${NAME}_prebuilt"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/3  build the guest ($BOARD)"
if [ -n "${PREBUILT:-}" ]; then
  need_file "$PREBUILT/zephyr.bin" "no prebuilt image in $PREBUILT (run --build-only first)"
  cp "$PREBUILT/zephyr.bin" "$PREBUILT/zephyr.elf" "$RUN/"
  cp "$PREBUILT/build.log" "$RUN/build.log" 2>/dev/null || true
  info "prebuilt image from $PREBUILT (built off the board lock)"
else
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
      > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed"; }
  cp "$RUN/build/zephyr/zephyr.bin" "$RUN/build/zephyr/zephyr.elf" "$RUN/"
fi
info "image: $(fsize "$RUN/zephyr.bin")"
if [ -n "${BUILD_ONLY:-}" ]; then
  info "built, no board touched.  Now:  scripts/with_board.sh $0 --prebuilt $RUN"
  exit 0
fi

step "2/3  load the PL and run"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"; bitstream_gate
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE"; }
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ --idle 60 > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $SECONDS_READ ] && ! grep -q LL_DONE console.out; do sleep 5; t=\$((t+5)); done
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t bytes=\$(wc -c < console.out)
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
[ -s "$RUN/console.txt" ] || { cat "$RUN/boot.log"; die "0 console bytes"; }
grep -q LL_DONE "$RUN/console.txt" || { tail -30 "$RUN/console.txt"; die "the bench did not finish"; }
grep -E "^LL_" "$RUN/console.txt" | sed 's/^/    /'

step "3/3  score the three measurements against the committed predictions"
export BIT_MD5 WANT_MAGIC IISWC_BOARD
python3 - "$RUN" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run = sys.argv[1]
txt = open(os.path.join(run, "console.txt"), errors="replace").read()
CLK = 34482759.0
NOT_COMPARED = 0xffffffff

def rows(pat):
    return [m.groupdict() for m in re.finditer(pat, txt)]

m1 = rows(r"LL_M1 words=(?P<words>\d+)\s+els=(?P<els>\d+)\s+rc=(?P<rc>-?\d+) (?P<what>\S+)\s+"
          r"cfg=(?P<cfg>\d+) go=(?P<go>\d+) poll=(?P<poll>\d+) polls=(?P<polls>\d+) "
          r"total=(?P<total>\d+) u_err=0x(?P<uerr>[0-9a-f]+) differ=(?P<differ>\d+)")
seq = rows(r"LL_M2SEQ tile=(?P<tile>\d+)\s+buf=(?P<buf>\d+) rc=(?P<rc>-?\d+) (?P<what>\S+)\s+"
           r"tile_cycles=(?P<tc>\d+) cfg=(?P<cfg>\d+) go=(?P<go>\d+) poll=(?P<poll>\d+) "
           r"polls=(?P<polls>\d+) u_err=0x(?P<uerr>[0-9a-f]+) differ=(?P<differ>\d+)")
pipe = rows(r"LL_M2PIPE tile=(?P<tile>\d+)\s+buf=(?P<buf>\d+) rc=(?P<rc>-?\d+) (?P<what>\S+)\s+"
            r"tile_cycles=(?P<tc>\d+) cfg=(?P<cfg>\d+) go=(?P<go>\d+) poll=(?P<poll>\d+) "
            r"polls=(?P<polls>\d+) u_err=0x(?P<uerr>[0-9a-f]+) differ=(?P<differ>\d+)")
m3 = rows(r"LL_M3 (?P<tag>\S+)\s+bytes=(?P<bytes>\d+) cycles=(?P<cycles>\d+)")
sweep = re.search(r"LL_SWEEP max_clean_words=(-?\d+) max_clean_elements=(-?\d+)", txt)
stop = re.search(r"LL_STOP ownership did not come back at (\d+) words \((\d+) elements\)", txt)
differ = [{"bad": int(a), "bytes": int(b), "words": int(c)}
          for a, b, c in re.findall(r"LL_DIFFER (\d+) of (\d+) bytes differ at (\d+) words", txt)]
skip = re.search(r"LL_SKIP M2 not run: the lane completed only (\d+) of (\d+) words", txt)
ref = rows(r"LL_REFUSE w0=(?P<w0>\d+)\s+n=(?P<n>\d+)\s+u_err=0x(?P<uerr>[0-9a-f]+) "
           r"want=(?P<want>\S+) polls=(?P<polls>\d+) own=(?P<own>\d+)")
cnt = re.search(r"LL_COUNT attempted=(\d+) ok=(\d+) refused=(\d+) last_rc=(-?\d+) "
                r"last_uerr=0x([0-9a-f]+) bytes_checked=(\d+) bytes_differ=(\d+) "
                r"fence_timeouts=(\d+)", txt)
tab = re.search(r"LL_TABLE entries=256 cycles=(\d+) per_lcfg=(\d+)", txt)
rst = re.search(r"LL_RESET status=(0x[0-9a-f]+) own=(\d+) u_err=0x([0-9a-f]+) u_idle=(\d+)", txt)
cfgb = re.search(r"LL_CFGBUSY u_err=0x([0-9a-f]+)", txt)

out = {"lab": "B37 lut_lane M1/M2/M3", "soc_magic": os.environ.get("WANT_MAGIC"),
       "bitstream_md5": os.environ.get("BIT_MD5"), "board": os.environ.get("IISWC_BOARD"),
       "clock_hz": CLK,
       "fclk": json.load(open(os.path.join(run, "fclk.json"))),
       "prediction": {"source": "T4_LANES.md s10, commit 3414a2a",
                      "m1_slope": [0.118, 0.140], "m1_slope_point": 0.125,
                      "m1_intercept": [110, 400], "m1_intercept_point": 150,
                      "m2_pipe": [1300, 2900], "m2_pipe_point": 1900,
                      "m2_seq": [3100, 4400], "m2_seq_point": 3750,
                      "m3_byte_cyc_per_byte": [10, 20], "m3_word_cyc_per_byte": [1.2, 5.0],
                      "rtf_e2e_projection": 5.069, "rtf_e2e_band": [5.06, 5.09]},
       "reset": {"status": rst.group(1), "own": int(rst.group(2)),
                 "u_err": int(rst.group(3), 16), "u_idle": int(rst.group(4))} if rst else None,
       "refusals": [{k: (int(v, 16) if k == "uerr" else v if k == "want" else int(v))
                     for k, v in r.items()} for r in ref],
       "cfg_while_busy_uerr": int(cfgb.group(1), 16) if cfgb else None,
       "table_load_cycles": int(tab.group(1)) if tab else None,
       "cycles_per_lcfg": int(tab.group(2)) if tab else None,
       "m1": m1, "m2_seq": seq, "m2_pipe": pipe, "m3": m3,
       "max_clean_words": int(sweep.group(1)) if sweep else None,
       "max_clean_elements": int(sweep.group(2)) if sweep else None,
       "stopped_at_words": int(stop.group(1)) if stop else None,
       "clean_return_wrong_data": differ,
       "m2_skipped": bool(skip)}

fails, notes = [], []
if cnt:
    out["counters"] = {"attempted": int(cnt.group(1)), "ok": int(cnt.group(2)),
                       "refused": int(cnt.group(3)), "last_rc": int(cnt.group(4)),
                       "last_uerr": int(cnt.group(5), 16),
                       "bytes_checked": int(cnt.group(6)), "bytes_differ": int(cnt.group(7)),
                       "fence_timeouts": int(cnt.group(8))}
else:
    out["counters"] = None
    fails.append("no LL_COUNT line: the bench did not reach its counters")

# ---- the rule this campaign keeps paying for: a zero that means NOTHING RAN is not a pass.
c = out["counters"] or {}
if c.get("ok", 0) == 0:
    fails.append("lut_ok = 0: NO LANE DISPATCH COMPLETED.  Every clean-looking zero below is "
                 "a zero that means nothing ran (438eb27).")
if c.get("bytes_checked", 0) == 0:
    out["check_meaning"] = "not_compared"
    fails.append("bytes_checked = 0: nothing was byte-compared, so bytes_differ = 0 means "
                 "NOT COMPARED and not MATCHED")
elif c.get("bytes_differ", 1) == 0:
    out["check_meaning"] = "matched"
else:
    out["check_meaning"] = "differs"
    fails.append("%d of %d drained bytes differ: s8.5 outcome 3 (the t_abuf collision or a "
                 "load into the buffer the lane is reading).  EVERY CYCLE COUNT IN THIS RUN "
                 "IS A MEASUREMENT OF CORRUPTED DATA." % (c["bytes_differ"], c["bytes_checked"]))
for d in out["clean_return_wrong_data"]:
    fails.append("%d of %d bytes differ at %d words WITH rc = 0 and u_err = 0x0: a CLEAN RETURN "
                 "OVER WRONG DATA, which no correctness gate on the return code can see"
                 % (d["bad"], d["bytes"], d["words"]))
if out["stopped_at_words"] is not None:
    fails.append("the lane did not return ownership at %d words (%d elements): the sweep "
                 "stopped there" % (out["stopped_at_words"], out["stopped_at_words"] * 8))
if c.get("fence_timeouts", 0):
    fails.append("%d fence timeouts: the engine did not report itself idle" % c["fence_timeouts"])

# ---- M1: least squares over the sweep, best of the two reps at each size -------------------
# THE LEVER ARM IS A PRECONDITION OF THE FIT, NOT A DETAIL.  The poll loop quantises every
# total by one poll (~20-40 cycles on B33's numbers).  Over a 2,048-to-8,192-element span that
# is +/-0.013 on the slope; over an 8-to-384-element span it is +/-0.4, which is not a
# measurement of anything.  So the fit refuses below 256 clean words and says why, rather than
# printing a number with a 300 % interval next to a band it cannot fall outside of.
ok1 = [d for d in m1 if int(d["rc"]) == 0 and int(d["differ"]) == 0]
big = max([int(d["words"]) for d in ok1], default=0)
# A POINT WHERE THE LANE FINISHED BEFORE THE FIRST POLL CARRIES NO SLOPE, AND ARM C'S ALL-POINTS
# FIT WAS DRAGGED 6 % LOW BY SEVEN OF THEM.  The poll quantum is ~21 cycles (measured: 126 cycles
# across 6 polls between 128 and 256 words), so a dispatch shorter than one quantum returns on
# poll 1 whatever its length: 8, 16 and 24 words all came back at exactly 233 cycles.  Those
# points measure the WRAPPER and sit on a flat floor, so including them biases the slope down and
# the intercept up.  BOTH FITS ARE REPORTED and the prediction is scored on the resolved one,
# with the all-points number printed beside it so the exclusion is visible rather than silent.
res1 = [d for d in ok1 if int(d["polls"]) >= 2]
if ok1 and big < 256:
    notes.append("M1: the sweep stopped at %d words, so the widest clean span is %d elements "
                 "and the poll quantum alone is +/-%.2f on the slope -- NO FIT REPORTED"
                 % (big, big * 8, 2 * 30.0 / max(big * 8 - 64, 1)))
    out["m1_no_fit_reason"] = "lever arm too short: %d clean words" % big
elif len(ok1) >= 4:
    def lsq(rowset):
        best = {}
        for d in rowset:
            n, t = int(d["els"]), int(d["total"])
            best[n] = min(best.get(n, t), t)
        xs, ys = list(best.keys()), [best[k] for k in best]
        n = len(xs); sx = sum(xs); sy = sum(ys)
        sxx = sum(x * x for x in xs); sxy = sum(x * y for x, y in zip(xs, ys))
        m = (n * sxy - sx * sy) / float(n * sxx - sx * sx)
        return m, (sy - m * sx) / float(n), best
    slope_all, icept_all, best_all = lsq(ok1)
    out["m1_slope_all_points"] = slope_all
    out["m1_intercept_all_points"] = icept_all
    out["m1_points"] = best_all
    if len(res1) >= 4:
        slope, icept, _ = lsq(res1)
        out["m1_fit_basis"] = "polls >= 2 (%d of %d sizes); the rest returned on poll 1 and sit on a flat wrapper floor" % (len(set(int(d["words"]) for d in res1)), len(set(int(d["words"]) for d in ok1)))
    else:
        slope, icept = slope_all, icept_all
        out["m1_fit_basis"] = "all points: fewer than four sizes resolved more than one poll"
    out["m1_slope_cycles_per_element"] = slope
    out["m1_cycles_per_word"] = slope * 8
    out["m1_intercept_cycles"] = icept
    out["m1_slope_within"] = 0.118 <= slope <= 0.140
    out["m1_intercept_within"] = 110 <= icept <= 400
elif not ok1:
    notes.append("M1: no clean dispatch completed -- no fit")
else:
    notes.append("M1: fewer than four clean sizes completed -- no fit")

def band(vals, lo, hi, tag):
    if not vals:
        notes.append("%s: no clean tiles" % tag)
        return None
    v = sorted(vals)
    med = v[len(v) // 2]
    return {"n": len(v), "min": v[0], "median": med, "max": v[-1],
            "within": lo <= med <= hi, "band": [lo, hi]}

# tile 0 of each M2 run pays for a cold table walk and the first buffer flip; the steady
# tiles are what the model is about, so both are reported and the fit uses tiles >= 1.
if out["m2_skipped"]:
    notes.append("M2 was not run and the record says so: the lane completed only %s of 1024 "
                 "words cleanly, so a full-tile dispatch would hang and every number after it "
                 "would be a measurement of a stuck lane" % out["max_clean_words"])
out["m2_seq_fit"] = band([int(d["tc"]) for d in seq if int(d["rc"]) == 0
                          and int(d["differ"]) == 0 and int(d["tile"]) >= 1], 3100, 4400, "M2-seq")
out["m2_pipe_fit"] = band([int(d["tc"]) for d in pipe if int(d["rc"]) == 0
                           and int(d["differ"]) == 0 and int(d["tile"]) >= 1], 1300, 2900, "M2-pipe")
if out["m2_seq_fit"] and out["m2_pipe_fit"]:
    d = out["m2_seq_fit"]["median"] - out["m2_pipe_fit"]["median"]
    out["m2_overlap_saving_per_tile"] = d
    out["m2_verdict"] = ("the engine overlaps the fill with the lane" if d > 600 else
                         "M2-pipe is not distinguishable from the sequential control: the "
                         "engine does not overlap (T4_LANES.md s8.5 outcome 3)")

for d in m3:
    d["cycles_per_byte"] = int(d["cycles"]) / float(d["bytes"])
mm = {d["tag"]: d["cycles_per_byte"] for d in m3}
out["m3_cycles_per_byte"] = mm
if "a_byte_near" in mm and "c_byte_warm" in mm:
    out["m3_cold_warm_ratio"] = mm["a_byte_near"] / mm["c_byte_warm"]
# COMPUTED BEFORE THE DUMP, NOT WHILE PRINTING.  Arm B printed these two ratios and wrote null
# for both into run.json, because they were derived inside the print block after json.dump had
# already run -- a number visible in the terminal and absent from the record is the one shape
# of instrument defect this campaign keeps paying for.
for _a, _b, _lab in (("a_byte_near", "b_word_near", "near"), ("a_byte_far", "b_word_far", "far")):
    if _a in mm and _b in mm:
        out["m3_width_ratio_" + _lab] = mm[_a] / mm[_b]
if "a_byte_near" in mm and "a_byte_far" in mm:
    out["m3_alias_ratio"] = mm["a_byte_far"] / mm["a_byte_near"]

out["fails"] = fails
out["notes"] = notes
out["verdict"] = "FAIL" if fails else "PASS"
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)

p = print
p("   MAGIC %s  md5 %s  board %s" % (out["soc_magic"], out["bitstream_md5"], out["board"]))
if out["reset"]:
    p("   reset: u_err=0x%x u_idle=%d own=%d  (u_err MUST be 0 from reset -- unlike a_err's 0x9)"
      % (out["reset"]["u_err"], out["reset"]["u_idle"], out["reset"]["own"]))
for r in out["refusals"]:
    p("   refuse w0=%-5d n=%-5d u_err=0x%x want=%s own=%d" % (r["w0"], r["n"], r["uerr"],
                                                             r["want"], r["own"]))
if out["cfg_while_busy_uerr"] is not None:
    p("   cfg-while-busy u_err=0x%x (want bit 1)" % out["cfg_while_busy_uerr"])
if out["table_load_cycles"]:
    p("   table: 256 entries in %d cycles, %d per lcfg" % (out["table_load_cycles"],
                                                           out["cycles_per_lcfg"]))
if "m1_slope_cycles_per_element" in out:
    p("   M1 SLOPE  %.4f cycles/element = %.3f cycles per 64-bit word   predicted 0.125 "
      "[0.118, 0.140] -> %s" % (out["m1_slope_cycles_per_element"], out["m1_cycles_per_word"],
                                "WITHIN" if out["m1_slope_within"] else "FALSIFIED"))
    p("   M1 INTERCEPT %.0f cycles   predicted 150 [110, 400] -> %s"
      % (out["m1_intercept_cycles"], "WITHIN" if out["m1_intercept_within"] else "FALSIFIED"))
    p("   M1 fit basis: %s" % out["m1_fit_basis"])
    p("   M1 all-points fit, for comparison: %.4f c/element, intercept %.0f (biased low: the "
      "short sizes return on poll 1 whatever their length)"
      % (out["m1_slope_all_points"], out["m1_intercept_all_points"]))
for tag, key in (("M2-seq (control)", "m2_seq_fit"), ("M2-pipe (test)", "m2_pipe_fit")):
    f = out.get(key)
    if f:
        p("   %-18s n=%d  min %d  MEDIAN %d  max %d   predicted %s -> %s"
          % (tag, f["n"], f["min"], f["median"], f["max"], f["band"],
             "WITHIN" if f["within"] else "FALSIFIED"))
if "m2_verdict" in out:
    p("   M2 overlap: pipelined saves %d cycles/tile -- %s"
      % (out["m2_overlap_saving_per_tile"], out["m2_verdict"]))
if out["max_clean_words"] is not None:
    p("   SWEEP  largest byte-clean dispatch: %d words = %d elements (of 1024 / 8192)"
      % (out["max_clean_words"], out["max_clean_elements"]))
for tag in ("a_byte_near", "b_word_near", "d_vbyte_near", "a_byte_far", "b_word_far",
            "c_byte_warm"):
    if tag in mm:
        p("   M3 %-12s %.2f cycles/byte" % (tag, mm[tag]))
for lab in ("near", "far"):
    if "m3_width_ratio_" + lab in out:
        p("   M3 byte/word ratio (%s) %.2fx -- the engine's own placement is 14.9 c/B "
          "(ENGINE_WAIT_ANATOMY.md s2)" % (lab, out["m3_width_ratio_" + lab]))
if "m3_alias_ratio" in out:
    p("   M3 far/near %.2fx -- the same loop, one with src and dst 8 MB apart" % out["m3_alias_ratio"])
c = out["counters"] or {}
p("   COUNTERS attempted=%s ok=%s refused=%s last_rc=%s last_uerr=0x%x "
  "bytes_checked=%s bytes_differ=%s  check_meaning=%s"
  % (c.get("attempted"), c.get("ok"), c.get("refused"), c.get("last_rc"),
     c.get("last_uerr", 0), c.get("bytes_checked"), c.get("bytes_differ"),
     out.get("check_meaning")))
for n in notes:
    p("   note: %s" % n)
for f in fails:
    p("   FAIL: %s" % f)
p("   VERDICT %s" % out["verdict"])
sys.exit(1 if fails else 0)
PY
rc=${PIPESTATUS[0]}
info "run.json written to $RUN/run.json"
exit "$rc"
