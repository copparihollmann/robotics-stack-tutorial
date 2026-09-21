#!/usr/bin/env bash
# Lab B33 -- THE FIRST LANE DISPATCH EVER ISSUED ON SILICON (ROCC_DECOUPLED.md s8.15.21/22).
#
#   ./scripts/69_rocket_lane_smoke.sh --build-only
#   scripts/with_board.sh ./scripts/69_rocket_lane_smoke.sh --prebuilt out/rocket_lane_smoke_prebuilt
#
# WHY.  Functs 9/10/11 are decoded in the merged engine and no software has ever issued one.  The
# number that decides three workstreams' interface designs -- what a lane dispatch costs in
# software -- is a BOUND carried from the GEMM path (4,701-5,190 cycles, flat), and a GEMM
# dispatch pays for a weight-image cache walk, mbxr_wimage_plan and mbxr_run's tiling planner
# that a lane dispatch never executes.  PREDICTED BEFORE THIS RAN: 300-1,200 cycles, point ~600,
# FALSIFIED above 1,200.
#
# NO KERNEL EXISTS YET, DELIBERATELY: this measures the wrapper before anyone writes 500 lines
# against the optimistic assumption, and it needs no correct data to do it (mbxr_ln.v guarantees
# the stream length never depends on the data).
#
# BITSTREAM.  Defaults to 0x5A5A002A, not the 0x5A5A0029 the task named: 002A is 0029 plus ten
# lines of streamer, its LayerNorm path is identical, it is the build the variant now produces,
# and its runner exists.  0029 is archived and can be passed with --bit/--magic/--runner.
# groupnorm_s16 is NOT reachable through either and is not dispatched here.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="rocket_lane_smoke"
BOARD="chipyard_pynqz1_micrgb"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonlanes_z1/pynqz1_rocket_micrgb_roccmoonlanes.bit"
RUNNER="run_rocket_roccmoonlanes2.py"
SAMPLE="$IISWC_ROOT/samples/lane_smoke"
WANT_MAGIC="0x5A5A002A"; FCLK_CORE=34.4828; SECONDS_READ=300
# This bench issues lgo on the LayerNorm lane and nothing else -- no engine job, no
# P-extension kernel -- so ln_lane is the whole of what it needs and the whole of what it
# may be run on.  It has no kernel_picks.json: there is no codegen here, the sample IS the
# lane driver, so the declaration is the only half of the gate available to it.
LAB_REQUIRES="${LAB_REQUIRES:-ln_lane}"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    # NEVER HOLD THE BOARD ACROSS A BUILD.  Step 1 needs no board at all, so it can be done off
    # the lock and handed to the board run:
    #   ./scripts/68_rocket_memo_table.sh --build-only
    #   scripts/with_board.sh ./scripts/68_rocket_memo_table.sh --prebuilt out/rocket_memo_table_prebuilt
    --build-only) BUILD_ONLY=1; shift ;;
    --prebuilt) PREBUILT="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
# 0x5A5A0028: this lab runs no accelerator, but it must still not run on an unidentified build.
BIT_ACCEPTED="${BIT_ACCEPTED:-} 1e8ea02d47dc9c2c7590a879de6c1d77 3710420a"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
[ -n "${BUILD_ONLY:-}" ] && RUN="$IISWC_OUT/${NAME}_prebuilt"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/3  build the guest ($BOARD)"
if [ -n "${PREBUILT:-}" ]; then
  # the image was built off the board lock by --build-only; the ops list is recorded there
  need_file "$PREBUILT/zephyr.bin" "no prebuilt image in $PREBUILT (run --build-only first)"
  cp "$PREBUILT/zephyr.bin" "$PREBUILT/zephyr.elf" "$RUN/"
  cp "$PREBUILT/build.log" "$RUN/build.log" 2>/dev/null || true
  info "prebuilt image from $PREBUILT (built off the board lock)"
else
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
      > "$RUN/build.log" 2>&1 || { tail -20 "$RUN/build.log"; die "build failed"; }
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
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "" ""
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
  while [ \$t -lt $SECONDS_READ ] && ! grep -q LS_DONE console.out; do sleep 5; t=\$((t+5)); done
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t bytes=\$(wc -c < console.out)
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
[ -s "$RUN/console.txt" ] || { cat "$RUN/boot.log"; die "0 console bytes"; }
grep -q LS_DONE "$RUN/console.txt" || { tail -20 "$RUN/console.txt"; die "the bench did not finish"; }
grep -E "^LS_" "$RUN/console.txt" | sed 's/^/    /'

step "3/3  the wrapper, fitted from two dispatch sizes"
export BIT_MD5 WANT_MAGIC LAB_REQUIRES LAB_FEATURES
python3 - "$RUN" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run = sys.argv[1]
txt = open(os.path.join(run, "console.txt"), errors="replace").read()
CLK = 34482759.0
LAT = 550.0                       # cycles of lane latency per dispatch (LAYERNORM_LANE.md s7)

disp = [{"rows": int(r), "k": int(k), "words": int(w), "rc": int(rc), "what": what.strip(),
         "cfg": int(cf), "go": int(go), "poll": int(po), "polls": int(np), "total": int(tt),
         "status": st, "l_err": int(le, 16)}
        for r, k, w, rc, what, cf, go, po, np, tt, st, le in re.findall(
            r"LS_DISP rows=(\d+)\s+k=(\d+) words=(\d+)\s+rc=(-?\d+) (\S+)\s+cfg=(\d+) "
            r"go=(\d+) poll=(\d+) polls=(\d+) total=(\d+) status=(0x[0-9a-f]+) l_err=0x([0-9a-f]+)", txt)]
guards = [{"M": int(m), "K": int(k), "rc": int(rc), "name": n}
          for m, k, rc, n in re.findall(r"LS_GUARD M=(\d+) K=(\d+) rc=(-?\d+) (\S+)", txt)]
probe = re.search(r"LS_PROBE rows=1 k=(\d+) words=(\d+) rc=(-?\d+) (\S+)\s+cfg=(\d+) go=(\d+) "
                  r"poll=(\d+) polls=(\d+) status=(0x[0-9a-f]+) own=(\d+) drained=(\d+) "
                  r"ln_idle=(\d+) l_err=0x([0-9a-f]+)", txt)
reset = re.search(r"LS_RESET status=(0x[0-9a-f]+) own=(\d+) ln_idle=(\d+) drained=(\d+) "
                  r"l_err=0x([0-9a-f]+)", txt)
out = {"lab": "B33 lane_smoke", "bitstream_md5": os.environ.get("BIT_MD5"),
       "soc_magic": os.environ.get("WANT_MAGIC"),
       "requires": os.environ.get("LAB_REQUIRES"),
       "features": os.environ.get("LAB_FEATURES"),
       "fclk": json.load(open(os.path.join(run, "fclk.json"))),
       "reset_status": reset.group(1) if reset else None,
       "reset_l_err": int(reset.group(5), 16) if reset else None,
       "guards": guards, "dispatches": disp,
       "prediction": {"wrapper_lo": 300, "wrapper_hi": 1200, "point": 600,
                      "source": "ROCC_DECOUPLED.md 8.15.21"}}

# THE TWO-POINT FIT: the same shape at two row counts.  slope = cycles per element on silicon,
# intercept = the wrapper plus the lane's fixed latency; the wrapper is the intercept less 550.
ok = [d for d in disp if d["rc"] == 0]
best = {}
for d in ok:
    best[d["rows"]] = min(best.get(d["rows"], d["total"]), d["total"])   # A/B/A/B -> take the best
if len(best) >= 2:
    r1, r2 = min(best), max(best)
    n1, n2 = r1 * disp[0]["k"], r2 * disp[0]["k"]
    cpe = (best[r2] - best[r1]) / float(n2 - n1)
    intercept = best[r1] - cpe * n1
    out["silicon_cycles_per_element"] = cpe
    out["fixed_per_dispatch"] = intercept
    out["wrapper_cycles"] = intercept - LAT
    out["wrapper_within_prediction"] = 300.0 <= (intercept - LAT) <= 1200.0
    out["rows_used"] = [r1, r2]
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)

print("   reset: l_err=0x%02x %s" % (out["reset_l_err"] or 0,
      "(bit0 = config unusable until K is written -- expected)" if (out["reset_l_err"] or 0) & 1
      else "(bit0 clear: the lane already had a K)"))
for g in guards:
    print("   guard M=%-4d K=%-6d rc=%-4d %s" % (g["M"], g["K"], g["rc"], g["name"]))
for d in disp:
    print("   rows=%-3d words=%-5d rc=%-3d %-12s cfg=%-6d go=%-5d poll=%-8d polls=%-8d total=%d"
          % (d["rows"], d["words"], d["rc"], d["what"], d["cfg"], d["go"], d["poll"],
             d["polls"], d["total"]))
if "wrapper_cycles" in out:
    print("   SILICON: %.4f cycles/element (LAYERNORM_LANE.md simulated 1.000)" % out["silicon_cycles_per_element"])
    print("   fixed per dispatch %.0f cycles, less %.0f of lane latency ->" % (out["fixed_per_dispatch"], LAT))
    print("   THE WRAPPER: %.0f cycles  (predicted 300-1,200, point 600) -> %s"
          % (out["wrapper_cycles"], "WITHIN" if out["wrapper_within_prediction"] else "FALSIFIED"))
    print("   at 18 decoder layernorms/token that is %.3f ms/token, %.1f %% of T3's 9.65 ms gain"
          % (18 * out["wrapper_cycles"] / CLK * 1e3, 100 * 18 * out["wrapper_cycles"] / CLK * 1e3 / 9.645))
else:
    print("   NO FIT: fewer than two dispatch sizes completed -- see the rc values above")
if probe:
    print("   PROBE rows=1 (4.5 drain blocks, nothing pads to a block): rc=%s %s own=%s drained=%s"
          % (probe.group(3), probe.group(4), probe.group(10), probe.group(11)))
PY
info "run.json written"
