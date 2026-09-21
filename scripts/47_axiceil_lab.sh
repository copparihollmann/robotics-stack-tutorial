#!/usr/bin/env bash
# Lab B28 -- the interface ceiling: the peak DRAM bandwidth the Zynq PS exposes to the PL.
#
#   scripts/with_board.sh ./scripts/47_axiceil_lab.sh --plan minimal --build <build dir>
#   plans: minimal ladder ceilingkeep | smoke ceiling1 clock burst outstanding ports full
#   (comma-separated plans run in order in one board session)
#
# AFTER 2026-09-16 (docs/BOARD_FINDINGS.md): build 1 left S_AXI_HP0 wedged for every later
# bitstream until the PS was reset.  The runner now classifies every stop from handshake counts
# at the PS pins; if it reports PS_HOLDS this script says so and every board workstream must stop
# until the board is reset and a known-good lab passes.  The first run of a new build is
# `minimal` and nothing else.
#
# MEMORY_BANDWIDTH.md section 7.  Every other bandwidth workstream measures a SoC's memory
# path; this measures the hardware interface behind all of them, with nothing in between: a
# raw AXI3 master per S_AXI_HP port (fpga/pynq-z2/src/axiceil/, MAGIC 0x5A5A0020), a
# measurement window counted in fabric cycles, per-ID concurrency, burst length 1-16, reads,
# writes or both, on any subset of the four HP ports, in one bitstream.
#
# What each run records, and refuses to measure without (host/run_axiceil.py):
#   * the bitstream's md5, gated against the builds below;
#   * FCLK0 read back from the SLCR AND counted by the fabric over a host-timed second;
#   * the DDR controller's and AFIs' configuration read back (host/ddrc_afi.py), before and
#     after, its hash on every row -- the PS7 preset is not what runs on PYNQ;
#   * /proc/iomem: no DDR write unless Linux owns nothing at or above 0x1000_0000;
#   * data integrity: every read beat compared in the fabric, every write read back.
#
# Rows go to fpga/pynq-z2/bwlab/results.csv under the results lock; the raw JSON lines, including
# the full DDRC/AFI register dump, are kept in fpga/pynq-z2/bwlab/axiceil/.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

NAME=""
PLAN="minimal"
BUILD="$IISWC_ROOT/fpga/pynq-z2/build_axiceil_v5_z1"
BIT=""
FMAX=""
LOAD_BIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)  PLAN="${2:?}"; shift 2 ;;
    --name)  NAME="${2:?}"; shift 2 ;;
    --build) BUILD="${2:?}"; shift 2 ;;
    --bit)   BIT="${2:?}"; shift 2 ;;
    --fmax)  FMAX="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
BIT="${BIT:-$BUILD/pynqz1_axiceil.bit}"
NAME="${NAME:-axiceil_$PLAN}"
TS=$(date +%Y%m%dT%H%M%S)
RUN="$IISWC_OUT/axiceil/$NAME-$TS"; mkdir -p "$RUN"
KEEP="$IISWC_ROOT/fpga/pynq-z2/bwlab/axiceil"; mkdir -p "$KEEP"
H="$IISWC_ROOT/fpga/pynq-z2/host"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=15 "$PYNQ_HOST")
BDIR="$PYNQ_DIR/axiceil"

# The builds this lab has been validated against (sim/axiceil gate + timing closed), kept here
# rather than in the speech labs' BIT_ACCEPTED, as scripts/43_rocket_bwlab.sh does.
AXICEIL_ACCEPTED="${AXICEIL_ACCEPTED:-}"
axiceil_note () {
  grep -h "^$1 " "$IISWC_ROOT/fpga/pynq-z2/bwlab/axiceil/BUILDS" 2>/dev/null | cut -d' ' -f2- || true
}

step "1/4  bitstream, plan"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "build it with fpga/pynq-z2/scripts/build_axiceil_z1.sh"
  bitstream_identify "$BIT"
  NOTE=$(axiceil_note "$BIT_MD5")
  [ -n "$NOTE" ] || case " $AXICEIL_ACCEPTED " in *" $BIT_MD5 "*) NOTE="accepted by AXICEIL_ACCEPTED" ;; esac
  [ -n "$NOTE" ] || die "bitstream md5 $BIT_MD5 is not a validated axiceil build
       (fpga/pynq-z2/bwlab/axiceil/BUILDS lists them: md5, fmax, closure).  Add it there only after
       sim/axiceil/run_axiceil_sim.sh passed and the build closed timing."
  info "           $NOTE"
else
  bitstream_identify ""
fi
if [ -z "$FMAX" ]; then
  FMAX=$(grep -h "^$BIT_MD5 " "$KEEP/BUILDS" 2>/dev/null | sed -n 's/.*fmax=\([0-9.]*\).*/\1/p' | head -1)
  [ -n "$FMAX" ] || die "no --fmax and no fmax= for this md5 in $KEEP/BUILDS"
fi
# Plans a build is accepted for, where BUILDS limits it (the coordinator's acceptance of build 5).
case "$BIT_MD5" in
  15187f82890dd05f3428ff467ae5039b)
    for p in ${PLAN//,/ }; do
      case "$p" in ladder8|ladder9|ladder10) ;; *) die "build 5 is accepted for ladder8, ladder9 and ladder10 only, not '$p'" ;; esac
    done ;;
esac
python3 "$H/axiceil_lab.py" plan "$PLAN" --fmax "$FMAX" > "$RUN/plan.json"
info "plan $PLAN: $(python3 -c "import json;j=json.load(open('$RUN/plan.json'));print(len(j['points']),'points,',sum(p['repeat'] for p in j['points']),'runs, top clock',max(p['fclk_mhz'] for p in j['points']),'MHz')")"

step "2/4  to the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
"${SSH[@]}" "mkdir -p $BDIR"
run scp -q "$H/run_axiceil.py" "$H/ddrc_afi.py" "$H/fclk.py" "$H/zynq_preflight.py" \
    "$RUN/plan.json" "$PYNQ_HOST:$BDIR/"
LOADARG="--no-load"
if [ "$LOAD_BIT" -eq 1 ]; then
  run scp -q "$BIT" "$PYNQ_HOST:$BDIR/axiceil.bit"
  LOADARG="--bitstream axiceil.bit"
fi

# The board's clock is not the workstation's (2026-09-17: it read 2025-05-04); the runner's JSON
# carries board times, so rows add this offset.  Measured on each side of one ssh round trip.
H0=$(date +%s.%N); B0=$("${SSH[@]}" 'date +%s.%N'); H1=$(date +%s.%N)
CLOCK_OFFSET=$(python3 -c "print(round(($H0 + $H1) / 2 - $B0, 1))")
echo "$CLOCK_OFFSET" > "$RUN/clock_offset"
info "board clock offset: $CLOCK_OFFSET s (workstation - board)"

step "3/4  run"
"${SSH[@]}" "cd $BDIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_axiceil.py $LOADARG --plan plan.json'" \
  > "$RUN/run.jsonl" 2> "$RUN/run.err" || true
grep -v "password for" "$RUN/run.err" | tail -5 || true
cp "$RUN/run.jsonl" "$KEEP/$TS-$NAME.jsonl"
python3 "$H/axiceil_lab.py" table "$RUN/run.jsonl" | tee "$RUN/table.txt"
if grep -q '"kind":"PS_HOLDS"' "$RUN/run.jsonl"; then
  printf '%s\n' "${_c_red}################################################################################"
  printf '%s\n' "  PS_HOLDS: the PS still holds HP transactions this instrument issued."
  printf '%s\n' "  STOP ALL BOARD WORK. S_AXI_HP ports stay wedged across bitstream loads; only a PS"
  printf '%s\n' "  reset clears them (docs/BOARD_FINDINGS.md). Tell the coordinator now."
  printf '%s\n' "################################################################################${_c_off}"
fi
grep -q '"kind":"done"' "$RUN/run.jsonl" || warn "the runner did not finish the plan (see $RUN/run.err); logging what it measured"

step "4/4  rows"
"$IISWC_ROOT/scripts/lib/with_lock.sh" results \
  python3 "$H/axiceil_lab.py" rows "$RUN/run.jsonl" --md5 "$BIT_MD5" --build "$BUILD" --clock-offset "$CLOCK_OFFSET"
info "raw: $KEEP/$TS-$NAME.jsonl"
grep -q '"kind":"done"' "$RUN/run.jsonl" || die "incomplete run"
