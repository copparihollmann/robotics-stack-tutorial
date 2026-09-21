#!/usr/bin/env bash
# Lab B36 -- IS THIS BOARD PARKED AND HEALTHY?  The smallest run that can say so, on any board,
# with a bitstream that board actually has.
#
#   PYNQ_HOST=xilinx@<board-ip> scripts/with_board_illixr.sh ./scripts/67_board_parked.sh --board-name illixr
#   scripts/with_board.sh ./scripts/67_board_parked.sh --board-name garden
#
# WHY IT EXISTS.  Lab 35 (scripts/35_rocket_rgb_leds.sh) is garden's park-and-check: it ends a
# session by loading 0x5A5A0006 and proving the PL, the PS clocks and the guest are alive.  The
# illixr card has no accepted 0x5A5A0006 build, so Lab 35 cannot run there, and the first engine
# session on it ended with a bitstream whose arithmetic is known wrong still in the PL and nothing
# having checked the board at all.  "The board was left however the last session left it" is how a
# later run gets misattributed.
#
# WHAT "PARKED AND HEALTHY" MEANS HERE.  Four things, each failing loudly and distinguishably:
#   1. REACHABLE   ssh answers and sudo does not ask for a password.
#   2. THE PL IS WHAT WE THINK   the parking bitstream loads and SOC_MAGIC reads back as its own.
#                  A board left holding someone else's build is exactly what this catches.
#   3. THE CLOCKS ARE WHAT WE THINK   FCLK0..3 read back FROM THE SLCR, not from the build's
#                  intent, and FCLK0 must be the parking build's.
#   4. THE SoC EXECUTES   samples/smp_hart_proof boots and reports RESULT: PASS -- both harts
#                  identified from the mhartid CSR, so this fails differently for "hart 1 never
#                  came out of the bootrom" than for "nothing booted".  Zero console bytes is a
#                  failure in its own right, not a quiet pass.
# It deliberately does NOT test an accelerator: a health check must not depend on the thing under
# investigation.  smp_hart_proof runs on any big.LITTLE build here.
#
# THE PARKING BITSTREAM IS PER BOARD, and is a build that board has RUN, not merely one that exists:
#   garden  0x5A5A0006 micrgb -- but prefer Lab 35 there, which also exercises the GPIO.
#   illixr  0x5A5A0007 bwlab (md5 737d2f57), the build the bandwidth lab ran on that card with DRAM
#           within 0.5 % of garden's.  Known good, accepted in lib/bitstream_id.sh, full-feature
#           micrgb SoC, and not an engine build -- so parking on it cannot leave a card holding a
#           bitstream whose arithmetic is under investigation.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

BOARD_NAME="${IISWC_BOARD:-garden}"
NAME=""
BIT=""; WANT_MAGIC=""; RUNNER=""; ZBOARD="chipyard_pynqz1_micrgb"; FCLK_CORE=34.4828
SAMPLE="$IISWC_ROOT/samples/smp_hart_proof"
while [ $# -gt 0 ]; do
  case "$1" in
    --board-name) BOARD_NAME="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --zephyr-board) ZBOARD="${2:?}"; shift 2 ;;
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
# the per-board parking build
if [ -z "$BIT" ]; then
  case "$BOARD_NAME" in
    illixr) BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_bw_z1/pynqz1_rocket_micrgb_bw.bit"
            WANT_MAGIC="${WANT_MAGIC:-0x5A5A0007}"; RUNNER="${RUNNER:-run_rocket_bw.py}" ;;
    garden) BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_z1/pynqz1_rocket_micrgb.bit"
            WANT_MAGIC="${WANT_MAGIC:-0x5A5A0006}"; RUNNER="${RUNNER:-run_rocket_micrgb.py}" ;;
    *) die "no parking bitstream defined for board '$BOARD_NAME' -- pass --bit/--magic/--runner" ;;
  esac
fi
[ -n "$NAME" ] || NAME="board_parked_$BOARD_NAME"
# THE PARKING BUILD'S OWN md5, DECLARED HERE.  The gate exists so a MEASUREMENT cannot be taken on
# an unvalidated build; a health check is not a measurement, but the discipline is worth keeping --
# so each board's parking build is named by md5 rather than the gate being bypassed.  A board whose
# parking build is not in this list has not been parked before and needs a decision, not a default.
case "$BOARD_NAME" in
  illixr) BIT_ACCEPTED="${BIT_ACCEPTED:-} 737d2f5707857105be90c24c7f6610a2" ;;   # 0x5A5A0007 bwlab
  garden) BIT_ACCEPTED="${BIT_ACCEPTED:-} 4c8f7bf79e2f2464908eca8656abd691" ;;   # 0x5A5A0006 micrgb
esac
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"

step "1/4  reachable  ($BOARD_NAME: $PYNQ_HOST)"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST ($BOARD_NAME). The board is off, the
       network is down, or this host has no key there.  NOT a healthy board."
"${SSH[@]}" "echo xilinx | sudo -S true" >/dev/null 2>&1 || die "sudo asks for a password on $BOARD_NAME"
info "ssh ok, passwordless sudo ok"

step "2/4  build the guest ($ZBOARD)"
run west build -p always -b "$ZBOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
  > "$RUN/build.log" 2>&1 || { tail -20 "$RUN/build.log"; die "guest build failed"; }
cp "$RUN/build/zephyr/zephyr.bin" "$RUN/build/zephyr/zephyr.elf" "$RUN/"
info "image: $(fsize "$RUN/zephyr.bin")"

step "3/4  load the parking bitstream and read the clocks BACK"
need_file "$BIT" "the parking bitstream for $BOARD_NAME is missing"
bitstream_identify "$BIT"
bitstream_gate
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL on $BOARD_NAME"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"
  die "the PL does not report $WANT_MAGIC after loading the parking bitstream.  Either the load
       failed or this board holds something else -- do not run anything else on it until this is
       explained."; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"
  die "FCLK0 is not $FCLK_CORE MHz as read back from the SLCR"; }
info "MAGIC $WANT_MAGIC, FCLK0..3: $(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(', '.join('%s=%s' % (k, d[k]['mhz']) for k in ('fclk0','fclk1','fclk2','fclk3')))" "$RUN/fclk.json")"

step "4/4  the SoC executes  (smp_hart_proof, both harts)"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds 60 --idle 20 > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
BYTES=$(wc -c < "$RUN/console.txt" 2>/dev/null || echo 0)
[ "${BYTES:-0}" -gt 0 ] || { cat "$RUN/boot.log"
  die "0 console bytes on $BOARD_NAME.  The board is wedged or the console path is broken; this is
       a failure, not a quiet pass.  Stop board work here and say so."; }
grep -q "RESULT: PASS" "$RUN/console.txt" || { tail -30 "$RUN/console.txt"
  die "smp_hart_proof did not report PASS on $BOARD_NAME ($BYTES console bytes)"; }
grep -E "^(hart|HART|RESULT)" "$RUN/console.txt" | sed 's/^/    /' | head -8

export BOARD_NAME WANT_MAGIC BIT_MD5 BYTES
python3 - "$RUN" <<'PY' | tee "$RUN/report.txt"
import json, os, sys
run = sys.argv[1]
con = open(os.path.join(run, "console.txt"), errors="replace").read()
out = {"lab": "B36 board_parked", "board": os.environ.get("BOARD_NAME"),
       "soc_magic": os.environ.get("WANT_MAGIC"), "bitstream_md5": os.environ.get("BIT_MD5"),
       "console_bytes": int(os.environ.get("BYTES", "0")),
       "fclk": json.load(open(os.path.join(run, "fclk.json"))),
       "result_pass": "RESULT: PASS" in con}
out["verdict"] = "PARKED" if out["result_pass"] else "FAIL"
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)
print("   board %s: MAGIC %s, md5 %s, %d console bytes -> %s"
      % (out["board"], out["soc_magic"], (out["bitstream_md5"] or "?")[:8], out["console_bytes"], out["verdict"]))
print("   the PL is left holding the parking bitstream, which is where the next session should find it.")
sys.exit(0 if out["verdict"] == "PARKED" else 1)
PY
