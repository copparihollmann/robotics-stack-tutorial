#!/usr/bin/env bash
# Lab B25 -- the decoupled RoCC engine on the silicon (ROCC_DECOUPLED.md section 8).
#
#   scripts/with_board.sh ./scripts/51_rocket_roccmoon.sh
#   scripts/with_board.sh ./scripts/51_rocket_roccmoon.sh --build-only
#
# ANOTHER BITSTREAM OF THE ENGINE FAMILY (0x5A5A0011, 0012, 0028): pass --bit/--magic/--runner
# /--config for it and ROCCMOON_ACCEPTED=<its md5>.  The sample is the same; what differs is
# which MAGIC the runner and this script insist on, so a run can never be scored against the
# wrong machine.
#
# samples/roccmoon_bench on bitstream 0x5A5A0010, in five sections, each a line on the console
# and a key in run.json:
#
#   placement   custom-1 on hart 1 answers with the engine's identity; custom-1 on hart 0
#               traps (no RoCC there); MBP.DOT8 on hart 1 still traps (patches/0101)
#   exactness   random shapes: engine vs ModelBlaster's kernel_linear_s8 reference, and the
#               curated MBP kernel vs the same reference; gate max_abs_err = 0
#   shapes      Moonshine Tiny's encoder and decoder linear shapes, the curated MBP kernel on
#               hart 0 against the engine driven from hart 1, same bytes out
#   port        the decode projection's 9.4 MB of weights at an outstanding cap of 1..8, as
#               the engine counts its own fill beats and fill-busy cycles; appended to
#               fpga/pynq-z2/bwlab/results.csv beside the bandwidth instrument's rows
#               (--no-csv: a repeat run that should not add rows)
#   kernel_files  the curated kernel files a ModelBlaster model links (kernels/roccmoon/):
#               Moonshine's three stem convolutions and a misaligned K=203 linear, each
#               against the curated MBP kernel, with the runtime's hand-off diagnostics
#   matmul_b    the encoder's attention matmul swept in N at fixed M,K and in K at fixed M,N,
#               which is the degree of freedom the encoder's two real shapes lack; the K sweep
#               straddles a ceil(K/8) step so the per-DOT8 cost and the per-scratch-byte cost
#               separate (MATMUL_B_COST.md sections 6-8)
#
# run.json carries the bitstream md5 and the PS clocks READ from the SLCR (fclk.py), not the
# clocks the build asked for.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

NAME="rocket_roccmoon"
BOARD="chipyard_pynqz1_micrgb"
BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoon_z1"
BIT="$BUILD/pynqz1_rocket_micrgb_roccmoon.bit"
RUNNER="run_rocket_roccmoon.py"
SAMPLE="$IISWC_ROOT/samples/roccmoon_bench"
WANT_MAGIC="0x5A5A0010"
CFGNAME="PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonConfig"
# --fclk <MHz>: THE PL CLOCK THIS RUN IS LOADED AT, TIMED AT AND DIVIDED BY -- one flag, so the
# four places that have to agree cannot drift apart.  It sets (1) the FCLK0 the runner programs
# on the load path, (2) the FCLK0 fclk.py reads back out of the SLCR and refuses, (3) the
# CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC this run's guest must have been built with, and (4) the Hz
# this run's cycles are divided by to make an RTF.  Pair it with the matching --board: on this
# port the clock reaches software through that Kconfig symbol alone, and that symbol also sets
# the SiFive UART's baud divisor, so a guest built for the wrong clock GARBLES THE CONSOLE and
# runs mtime fast -- it does not fail.  Default 34.4828 (1000/29), which is every build before
# 0x5A5A0030.
FCLK_CORE=34.4828
# IDLE_READ is how long the console and DRAM-log readers wait on SILENCE before giving up, and
# this bench goes quiet for a long time: the kernel_files stage runs stem_conv3 on hart 0 alone,
# 3.93 G cycles = 114 s at 34.4828 MHz with nothing printed until it ends.  At the old 90 s the
# 0x5A5A0028 run was cut off inside that case and never printed RMB_DONE (2026-09-17); 240 s clears
# the longest case with margin.  A run without "RMB_DONE ok=1" is INCOMPLETE, whatever it printed.
LOAD_BIT=1; DO_BOARD=1; IDLE_READ=240; DO_CSV=1
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --build) BUILD="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --fclk) FCLK_CORE="${2:?}"; shift 2 ;;
    --config) CFGNAME="${2:?}"; shift 2 ;;
    --idle) IDLE_READ="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --no-csv) DO_CSV=0; shift ;;
    --build-only) DO_BOARD=0; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
# FCLK0 = 1000 MHz / N for an integer N on this PS7 (the IO PLL is 50 x 20), so derive the Hz
# from N and not from the rounded MHz: that reproduces the repo's 34482759 = round(1e9/29) to
# the Hz and is exact at 1000/25 = 40 MHz.  GUEST_KHZ is CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC,
# which sets mtime AND the UART baud divisor -- wrong, it garbles the console rather than failing.
read -r CLK_HZ GUEST_KHZ <<EOF_CLK
$(python3 -c "
import sys
f = float(sys.argv[1])
n = round(1000.0 / f)
if n < 1 or abs(1000.0 / n - f) > 0.02 * f:
    sys.exit('the PS7 cannot deliver %g MHz: nearest is %g' % (f, 1000.0 / max(1, n)))
print('%d %d' % (round(1e9 / n), round(1e6 / n)))
" "$FCLK_CORE")
EOF_CLK
[ -n "${CLK_HZ:-}" ] || die "could not derive the core clock in Hz from --fclk $FCLK_CORE"
printf '%s\n' "$CLK_HZ" > "$RUN/clock_hz.txt"
info "clock: FCLK0 $FCLK_CORE MHz = $CLK_HZ Hz; guest CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ"

# This lab's own validated builds, NOT added to lib/bitstream_id.sh's shared list (see
# scripts/43_rocket_bwlab.sh for why a lab extends the gate rather than widening it).
# 7475c1b2: 0x5A5A0010 as built in f69acfb, validated by Lab B25 runs 7 and 8 (placement, 40 random
# cases and every Moonshine shape exact, RMB_DONE ok=1) and by Lab B26's engine images.
ROCCMOON_ACCEPTED="${ROCCMOON_ACCEPTED:-7475c1b20b34f42e3bbe192f41cee58f}"
BIT_ACCEPTED="${BIT_ACCEPTED:-} $ROCCMOON_ACCEPTED"
roccmoon_note () {
  case "$1" in
    *) echo "a build of the decoupled RoCC engine ($WANT_MAGIC)" ;;
  esac
}

step "1/3  build the guest"
# $RMB_WEST_EXTRA reaches west's CMake arguments unquoted, for a build-time knob this lab does not
# own: 0x5A5A0013 needs -DEXTRA_CPPFLAGS=-DRMB_LANE_WAIT=2000000 so mbxr.c waits on fence bit 41
# before every dispatch (samples/roccmoon_bench/src/main.c, MEMORY_BANDWIDTH.md 9.14.1).  Empty by
# default, so every existing invocation is unchanged.
run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
  ${RMB_WEST_EXTRA:-} \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed"; }
cp "$RUN/build/zephyr/zephyr.elf" "$RUN/build/zephyr/zephyr.bin" "$RUN/"
# --board and --fclk are a PAIR: this is the check that makes them one.  A guest built for
# another clock does not fail on this silicon -- it garbles the console and runs mtime off by
# the ratio, because CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC is both the timer tick and the baud divisor.
grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ\$" "$RUN/build/zephyr/.config" \
  || die "guest clock mismatch: board '$BOARD' built CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$RUN/build/zephyr/.config"), --fclk $FCLK_CORE needs $GUEST_KHZ"
# THE GUEST AND THE BITSTREAM HAVE AN ABI, AND NEITHER CAN CHECK THE OTHER AT RUNTIME.  The
# engine's drain descriptor changed shape at 0x5A5A002E; a mismatched pair does not fail loudly,
# it returns MBXR_E_TIMEOUT with no error bit from the first dispatch.  Four board sessions were
# spent on that on 2026-09-18.  Refuse the pair HERE, before with_board.sh is called.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mbxr_abi.sh"
mbxr_abi_gate "$RUN/zephyr.elf" "$WANT_MAGIC" || die "guest/bitstream ABI mismatch -- refusing to take the board"

OBJDUMP=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)
"$OBJDUMP" -d "$RUN/zephyr.elf" > "$RUN/dis.txt"
python3 - "$RUN/dis.txt" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
words = re.findall(r'^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s', t, re.M)
c0 = sum(1 for w in words if (int(w, 16) & 0x7f) == 0x0b)
c1 = sum(1 for w in words if (int(w, 16) & 0x7f) == 0x2b)
sf = sorted(set(re.findall(r'<(__(?:add|sub|mul|div|fix|float)[a-z]*(?:sf|df)[0-9a-z]*)>', t)))
print("    custom-0 (MBP) encodings %d, custom-1 (engine) encodings %d, soft-float %s"
      % (c0, c1, ",".join(sf) if sf else "none"))
PY
info "image: $(fsize "$RUN/zephyr.bin")"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only"; exit 0; }

step "2/3  run"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$IISWC_ROOT/fpga/pynq-z2/host/read_rmb_log.py" \
      "$RUN/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "no bitstream -- build it with fpga/pynq-z2/scripts/build_roccmoon_z1.sh"
  bitstream_identify "$BIT"
  info "           $(roccmoon_note "$BIT_MD5")"
  bitstream_gate
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD="--bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold"
else bitstream_identify ""; HOLD="--no-load --hold"; fi
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER $HOLD'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
# Two clocks: the board's Linux clock has been ~43.2 M s behind the workstation (it read
# 2025-05-04 on 2026-09-17).  Record both, and the offset measured inside this session.
H0=$(date +%s.%N); B0=$("${SSH[@]}" "date +%s.%N" 2>/dev/null || echo ""); H1=$(date +%s.%N)
python3 -c "import json,sys,datetime; h0,h1=float(sys.argv[1]),float(sys.argv[2]); b=sys.argv[3]
out={'workstation_time': datetime.datetime.fromtimestamp((h0+h1)/2).astimezone().isoformat(timespec='seconds'),
     'board_time_epoch_s': float(b) if b else None,
     'board_minus_workstation_s': (float(b)-(h0+h1)/2) if b else None, 'ssh_round_trip_s': h1-h0}
json.dump(out, open(sys.argv[4],'w'), indent=1)" "$H0" "$H1" "$B0" "$RUN/clocks.json"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
# THE RESULT DOES NOT DEPEND ON THE UART.  The bench also writes every RMB_ line into DRAM at
# Rocket 0x87F0_0000 = PS physical 0x17F0_0000 ({magic "RMBLOG01", len, done, pad}, text).
# Zero that header from the PS before the program starts, so a log left by an earlier run
# cannot be read as this one's; then read it back while the console reads too.
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 read_rmb_log.py --clear" >> "$RUN/boot.log" 2>&1 \
  || die "could not clear the DRAM log header"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds 0 --idle $IDLE_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
# the DRAM log: wait for done (or for it to stop growing), then copy the text
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 read_rmb_log.py --wait-idle $IDLE_READ" \
  > "$RUN/console_mem.txt" 2>>"$RUN/boot.log" || true
# Whichever copy holds more RMB_ lines is the record (the UART can stop early; the DRAM log
# can be read before the bench is done); boot.log says which, and whether the log was done.
N_UART=$(grep -cE "^RMB_" "$RUN/console.txt" || true)
N_MEM=$(grep -cE "^RMB_" "$RUN/console_mem.txt" || true)
if [ "${N_MEM:-0}" -gt "${N_UART:-0}" ]; then
  warn "the console returned $N_UART RMB_ lines, the DRAM log $N_MEM; using the DRAM log"
  cp "$RUN/console.txt" "$RUN/console_uart.txt"
  cp "$RUN/console_mem.txt" "$RUN/console.txt"
fi
grep -E "^RMB_" "$RUN/console.txt" || { tail -40 "$RUN/console.txt"; die "no RMB_ lines on the console or in the DRAM log"; }

step "3/3  run.json, and the port rows"
UTIL="$BUILD/reports/post_route_util.rpt"; TIM="$BUILD/reports/timing_summary.rpt"
LUT=""; FF=""; BRAM=""; DSP=""; WNS=""; WHS=""
if [ -f "$UTIL" ]; then
  LUT=$(awk -F'|' '/\| Slice LUTs +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  FF=$(awk -F'|' '/\| Slice Registers +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  BRAM=$(awk -F'|' '/\| Block RAM Tile +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  DSP=$(awk -F'|' '/\| DSPs +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
fi
# WNS, TNS, WHS, THS are ONE ROW under ONE header in Vivado's design summary -- there is no line
# that begins "WHS(ns)".  The old parser looked for one and recorded an empty whs in every
# run.json it wrote (out/rocket_roccmoon/, out/rocket_roccmoon_r8/); those rows stand as written,
# and ROCC_DECOUPLED.md's WHS figures were read from timing_summary.rpt, not from that field.
# Columns of the data row: 1 WNS, 2 TNS, 3 TNS failing, 4 TNS total, 5 WHS, 6 THS, 7 THS failing.
if [ -f "$TIM" ]; then
  read -r WNS TNS_FAIL WHS THS_FAIL <<<"$(awk '/^ *WNS\(ns\)/ {getline; getline; print $1, $3, $5, $7; exit}' "$TIM")"
fi
WNS_NOTE="worst setup (WNS) and hold (WHS) slack over EVERY clock in the design, from Vivado's design summary row in reports/timing_summary.rpt; the per-clock rows are in the same file. TNS failing endpoints ${TNS_FAIL:-?}, THS failing ${THS_FAIL:-?}."
export BIT_MD5 WANT_MAGIC CFGNAME LUT FF BRAM DSP WNS WHS WNS_NOTE
python3 - "$RUN" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run = sys.argv[1]
txt = open(os.path.join(run, "console.txt")).read()
# THE CLOCK EVERY CYCLE COUNT HERE IS DIVIDED BY, READ FROM THE RUN DIRECTORY.
#
# It was the literal `CLK = 34482759.0` until 2026-09-18 (Lab B81), and it is the one constant
# in this file that CANNOT FAIL LOUDLY.  model_rtf_e2e.py takes `clock_hz` out of the record and
# only checks that the two halves AGREE -- and two halves at the same WRONG clock agree
# perfectly.  So a run on 0x5A5A0030 (FCLK0 40.0000 MHz) scored against a stale 34482759 does
# not error: it reports the OLD RTF at the NEW clock, and nothing downstream refuses it.
#
# The lab writes the clock it asked the board for into clock_hz.txt beside this file, fclk.py
# reads the SLCR back to confirm the board agrees, and the guest's own
# CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC is checked against the same number before the board is
# taken.  Three statements of one fact, and this reads the archived one.  The old constant
# survives ONLY as the fallback for a run directory written before the file existed -- which is
# exactly the set of runs it was the right number for.
def _clock_hz(run_dir, default=34482759.0):
    p = os.path.join(run_dir, "clock_hz.txt")
    if os.path.exists(p):
        return float(open(p).read().split()[0])
    return default


CLK = _clock_hz(run)
def kv(line):
    return {k: (int(v) if re.fullmatch(r'-?\d+', v) else v) for k, v in re.findall(r'(\w+)=(\S+)', line)}
out = {"lab": "B25 roccmoon_bench", "bitstream_md5": os.environ.get("BIT_MD5", ""),
       "clock_hz": CLK,
       "soc_magic": os.environ.get("WANT_MAGIC", ""), "config": os.environ.get("CFGNAME", ""),
       "fclk": json.load(open(os.path.join(run, "fclk.json"))),
       "clocks": (json.load(open(os.path.join(run, "clocks.json")))
                  if os.path.exists(os.path.join(run, "clocks.json")) else None),
       "post_route": {k.lower(): os.environ.get(k, "") for k in ("LUT", "FF", "BRAM", "DSP", "WNS", "WHS")},
       "post_route_wns_note": os.environ.get("WNS_NOTE", ""),
       "placement": [kv(l) for l in re.findall(r'^RMB_PLACE (.*)$', txt, re.M)],
       "placement_ok": [kv(l) for l in re.findall(r'^RMB_PLACE_RESULT (.*)$', txt, re.M)],
       "exactness": [kv(l) for l in re.findall(r'^RMB_EXACT (.*)$', txt, re.M)],
       "exactness_failures": [kv(l) for l in re.findall(r'^RMB_EXACT_FAIL (.*)$', txt, re.M)],
       "shapes": [kv(l) for l in re.findall(r'^RMB_OP (.*)$', txt, re.M)],
       "port": [kv(l) for l in re.findall(r'^RMB_PORT (.*)$', txt, re.M)],
       "shapes_place_chunk": [kv(l) for l in re.findall(r'^RMB_OPC (.*)$', txt, re.M)],
       "kernel_files": [kv(l) for l in re.findall(r'^RMB_KOP (.*)$', txt, re.M)],
       "kernel_files_progress": [kv(l) for l in re.findall(r'^(RMB_KOP_(?:BEGIN|CORE) .*)$', txt, re.M)],
       "matmul_b": [kv(l) for l in re.findall(r'^RMB_MMB (.*)$', txt, re.M)],
       "hangs": [kv(l) for l in re.findall(r'^RMB_HANG (.*)$', txt, re.M)],
       "done": [kv(l) for l in re.findall(r'^RMB_DONE (.*)$', txt, re.M)]}
bl = open(os.path.join(run, "boot.log"), errors="replace").read()
m = re.findall(r"dram log: magic=\S+ len=(\d+) done=(\d+)", bl)
out["dram_log"] = {"len": int(m[-1][0]), "done": int(m[-1][1])} if m else None
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)
print("   placement:", out["placement_ok"], "  exactness:", out["exactness"],
      " failures:", len(out["exactness_failures"]))
print("   %-11s %9s %13s %13s %13s %7s %9s %9s %6s" % ("shape", "MACs", "core cyc", "engine cyc",
      "eng(hart0)", "x", "fill B/c", "fill KB", "err"))
for s in out["shapes"]:
    fbpc = 8.0 * s["fill_beats"] / max(1, s["cyc_fill"])
    print("   %-11s %9d %13d %13d %13d %7.2f %9.2f %9d %6d" % (s["name"], s["macs"], s["core_cycles"],
          s["eng_cycles"], s["eng_h0_cycles"], s["core_cycles"] / max(1, s["eng_h0_cycles"]), fbpc,
          (s["bytes_a"] + s["bytes_w"]) // 1024, s["max_abs_err"]))
for c in out["shapes_place_chunk"]:
    base = [s for s in out["shapes"] if s["name"] == c["name"]]
    b = base[0] if base else {}
    print("   %-11s placement byte-wise: h1 %9s cycles (place %9s)   64-byte runs: h1 %9d (place %9d)  err %d"
          % (c["name"], b.get("eng_cycles", "-"), b.get("cyc_place", "-"), c["eng_cycles"], c["cyc_place"],
             c["max_abs_err"]))
for p in out["port"]:
    print("   port cap %d: %.3f B/cycle over %d fill-busy cycles (%d beats)"
          % (p["cap"], 8.0 * p["fill_beats"] / max(1, p["cyc_fill"]), p["cyc_fill"], p["fill_beats"]))
for k in out["kernel_files"]:
    print("   kernel file %-22s engine_calls %s fallback_calls %s core %s kernel %s max_abs_err %s"
          % (k.get("name"), k.get("engine_calls"), k.get("fallback_calls"), k.get("core_cycles", "-"),
             k.get("kernel_cycles", "-"), k.get("max_abs_err")))
print("   dram log:", out["dram_log"], "  done:", out["done"], "  hangs:", len(out["hangs"]))
print("   wrote %s" % os.path.join(run, "run.json"))
PY

# ---- the engine's own fill port joins the bandwidth record ------------------------------
# One row per outstanding cap, level DRAM (the decode projection's 9.4 MB of weights, far
# larger than the L2), bytes and cycles as the ENGINE counted them: fill beats x 8 over the
# cycles its fill engine was busy.  The same mbxd_dma.v the instrument rows measured, now
# inside an accelerator doing real work, so the two can be read side by side.
if [ -f "$RUN/run.json" ] && [ "$DO_CSV" = 1 ]; then
  export BWLAB_CSV="${BWLAB_CSV:-$IISWC_ROOT/fpga/pynq-z2/bwlab/results.csv}"
  "$IISWC_ROOT/scripts/lib/with_lock.sh" results python3 - "$RUN/run.json" "$BWLAB_CSV" <<'PYCSV'
import csv, datetime, json, os, sys
run = json.load(open(sys.argv[1])); path = sys.argv[2]
rows = run.get("port", [])
if not rows:
    print("   no port rows"); sys.exit(0)
fields = open(path, newline="").readline().strip().split(",")
fc = run["fclk"]["fclk0"]["mhz"]
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
pr = run.get("post_route", {})
with open(path, "a", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fields, lineterminator="\r\n")
    for p in rows:
        if p.get("rc", 0) != 0 or not p.get("cyc_fill"):
            continue
        moved = 8 * p["fill_beats"]
        bpc = moved / float(p["cyc_fill"])
        r = {f: "" for f in fields}
        r.update(timestamp=now, bitstream_md5=run["bitstream_md5"], soc_magic=run["soc_magic"],
                 config=run["config"], fclk_core_mhz=fc, fclk_mem_mhz=fc, n_hp_ports=1,
                 outstanding=p["cap"], burst_bytes=64, working_set_bytes=p.get("bytes_w", ""),
                 level="DRAM", direction="rd", bytes_moved=moved, cycles=p["cyc_fill"],
                 bytes_per_cycle="%.4f" % bpc, mb_per_s="%.1f" % (bpc * float(fc)),
                 lut=pr.get("lut", ""), ff=pr.get("ff", ""), bram=pr.get("bram", ""),
                 dsp=pr.get("dsp", ""), wns_ns=pr.get("wns", ""), whs_ns=pr.get("whs", ""),
                 source="silicon",
                 notes="roccmoon engine fill (mbxr_engine, client W on SBUS): decode projection "
                       "288x32768 planar image, %d weight loads, engine-counted fill-busy cycles"
                       % p.get("loads_w", 0))
        w.writerow(r)
print("   appended %d engine port rows to %s" % (len(rows), path))
PYCSV
fi
