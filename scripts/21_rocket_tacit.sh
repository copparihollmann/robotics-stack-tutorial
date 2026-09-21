#!/usr/bin/env bash
# Lab B2 -- the same TACIT flow as Lab A, but the trace comes off real silicon:
#
#   west build (chipyard_pynqz1) -> scp zephyr.bin -> PS writes DDR -> release reset
#   -> Rocket configures the TACIT encoder + DMA sink and runs -> sink streams the
#   encoded trace into DDR -> PS reads it over /dev/mem -> ltrace-decoder --to-perfetto
#
# Nothing on the PS side touches the TACIT registers. They live at 0x0300_0000 /
# 0x0301_0000 in *Rocket's* address space, which M_AXI_GP0 does not reach, and the Zynq
# GP ports have no bus timeout -- a read to an unbacked PL address locks the ARM until the
# watchdog fires. The guest configures them; the PS only reads the DRAM buffer.
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin   the traced guest
#   console.txt               what Rocket printed, including TACIT_DONE addr=.. bytes=..
#   boot.log                  the PS-side bring-up transcript
#   tacit.out                 encoded TACIT packets, straight out of DDR
#   trace.txt                 decoded control-flow trace
#   trace.perfetto.json       load at https://ui.perfetto.dev
#   run.json                  manifest, checked against expected/<sample>.json
#
# The board is shared. Run this under the lock:
#   scripts/with_board.sh ./scripts/21_rocket_tacit.sh
#   scripts/with_board.sh ./scripts/21_rocket_tacit.sh --no-bitstream
#   scripts/with_board.sh ./scripts/21_rocket_tacit.sh --sample PATH --name X
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# In THIS repo, not in the zephyr-chipyard-sw submodule: that submodule is pinned and
# carries `ignore = untracked`, so a sample added there would be invisible to git and
# would not survive a re-clone. Same reasoning as boards/chipyard/pynqz1/.
SAMPLE="$IISWC_ROOT/samples/tacit_dma"
NAME="rocket_tacit"
BOARD="chipyard_pynqz1"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_z1/pynqz1_rocket_tacit.bit"
LOAD_BIT=1
SECONDS_READ=30
EXPECT=""
# Rocket's ExtMem base and where the FPGA top folds it into PS physical memory, from
# src/pynqz2_rocket_top.v: {4'd1, addr[27:0]}.
ROCKET_MEM_BASE=$((0x80000000))
PS_MEM_BASE=$((0x10000000))

while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --expect) EXPECT="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"
need_exec "$TACIT_DECODER" "run scripts/05_build_tacit_tools.sh, or export TACIT_DECODER"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; BUILD="$RUN/build"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/6  build  ($BOARD)"
info "sample: $SAMPLE"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- -DBOARD_ROOT="$IISWC_ROOT" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"
info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")"

step "2/6  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "3/6  load the PL and hold Rocket in reset"
if [ "$LOAD_BIT" -eq 1 ]; then
  # Present AND the file this repo ships: fpga/pynq-z2/bitstreams.csv holds the md5, and
  # $IISWC_BIT_DIR / /opt/iiswc/bit are searched when it is not in the checkout. The old
  # need_file here said "build it with build_*_z1.sh", which no attendee is going to do.
  BIT="$(bitstream_require "$BIT")"
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD_ARGS="--bitstream $(basename "$BIT") --hold"
else
  HOLD_ARGS="--no-load --hold"
fi
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log" || { cat "$RUN/boot.log"; die "Rocket bitstream not reachable over GP0"; }
info "PL loaded, SoC held in reset"

step "4/6  boot Rocket and capture the console"
# The console reader starts BEFORE the core: the SiFive UART's TX FIFO is 8 bytes deep.
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true

if [ -s "$RUN/console.txt" ]; then
  printf '%s\n' "----------------------------------------------------------------"
  cat "$RUN/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
else
  warn "no console output -- check $RUN/boot.log"
  grep -E 'STATUS|saw_mem' "$RUN/boot.log" | tail -6 || true
  die "Rocket produced no console output"
fi
grep -q '\*\*\* Booting Zephyr OS' "$RUN/console.txt" || die "Rocket did not boot; see $RUN/boot.log"

# The guest reports where it put the trace and how many bytes the sink actually wrote
# (trace-sink-dma's addr_counter, read after its flush completed).
DONE_LINE=$(grep -m1 '^TACIT_DONE ' "$RUN/console.txt" || true)
[ -n "$DONE_LINE" ] || {
  grep -q 'TACIT_FAIL' "$RUN/console.txt" && die "guest reported: $(grep -m1 TACIT_FAIL "$RUN/console.txt")"
  die "no TACIT_DONE line -- is this sample driving the DMA sink? see $RUN/console.txt"
}
TRACE_ADDR=$(sed -n 's/.*addr=\(0x[0-9a-fA-F]*\).*/\1/p' <<<"$DONE_LINE")
TRACE_BYTES=$(sed -n 's/.*bytes=\([0-9]*\).*/\1/p' <<<"$DONE_LINE")
[ -n "$TRACE_ADDR" ] && [ -n "$TRACE_BYTES" ] || die "could not parse: $DONE_LINE"
[ "$TRACE_BYTES" -gt 0 ] 2>/dev/null || die "the sink wrote 0 bytes -- encoder target or sink address wrong"
PHYS=$(( $((TRACE_ADDR)) - ROCKET_MEM_BASE + PS_MEM_BASE ))
info "sink wrote $TRACE_BYTES bytes at Rocket $TRACE_ADDR = PS phys $(printf '0x%08X' $PHYS)"

step "5/6  drain the buffer over /dev/mem"
# sudo's password prompt has no trailing newline, so it lands on the same line as
# read_mem.py's report. Strip it rather than filtering the line out.
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 -u read_mem.py \
   --phys $(printf '0x%X' $PHYS) --bytes $TRACE_BYTES --out tacit.out" \
   > "$RUN/drain.log" 2>&1 || { cat "$RUN/drain.log"; die "could not read the trace buffer"; }
sed 's/^\[sudo\] password for [^:]*: //' "$RUN/drain.log" | sed 's/^/    /'
run scp -q "$PYNQ_HOST:$PYNQ_DIR/tacit.out" "$RUN/tacit.out"
need_file "$RUN/tacit.out" "nothing came back from the board"
GOT=$(stat -c%s "$RUN/tacit.out")
[ "$GOT" -eq "$TRACE_BYTES" ] || die "short read: got $GOT bytes, guest reported $TRACE_BYTES"
info "tacit.out: $(fsize "$RUN/tacit.out")  ($TRACE_BYTES bytes)"

step "6/6  decode  (txt + perfetto)"
# --encoder rtl: the hardware encoder's sync and trap packets carry neither the privilege
# byte nor the context varint that spike's trace_encoder_l emits, and it leaves the trap
# from-address unshifted. See fpga/pynq-z2/docs/TACIT_ON_FPGA.md.
( cd "$RUN" && run "$TACIT_DECODER" \
    --binary "$RUN/zephyr.elf" \
    --encoded-trace "$RUN/tacit.out" \
    --encoder rtl \
    --to-txt --to-perfetto ) > "$RUN/decode.log" 2>&1 \
  || { tail -20 "$RUN/decode.log"; die "decode failed -- log at $RUN/decode.log"; }
need_file "$RUN/trace.perfetto.json" "decoder produced no perfetto trace"
grep -q 'detected FSync packet, trace ending' "$RUN/decode.log" \
  || warn "decoder did not reach the trailing sync packet -- the stream may be truncated"
PACKETS=$(sed -n 's/.*Decoded \([0-9]*\) packets.*/\1/p' "$RUN/decode.log" | tail -1)
TXT_LINES=$(wc -l < "$RUN/trace.txt" 2>/dev/null || echo 0)
INSNS=$(grep -cE '^0x[0-9a-f]+: ' "$RUN/trace.txt" 2>/dev/null || echo 0)
SLICES=$(grep -o '"ph":"B"' "$RUN/trace.perfetto.json" 2>/dev/null | wc -l || echo 0)
info "packets: ${PACKETS:-0}   instructions: $INSNS   perfetto slices: $SLICES"
# The first slices are the evidence for *where* the trace starts. A trace that opens on
# main() and one that opens on z_prep_c are the same size to within a factor of two; only
# the names distinguish them.
FIRST_SLICES=$(grep -o '"name":"[^"]*","ph":"B"' "$RUN/trace.perfetto.json" 2>/dev/null \
  | sed 's/"name":"//; s/","ph":"B"//' | awk '!seen[$0]++' | head -10 | tr '\n' ' ')
info "opens on: ${FIRST_SLICES:-<none>}"

step "manifest"
python3 - "$RUN" "$SAMPLE" "$BOARD" "$TRACE_ADDR" "$PHYS" "$TRACE_BYTES" \
         "${PACKETS:-0}" "$INSNS" "$TXT_LINES" "$SLICES" "$IISWC_ROOT" "$ZCS" <<'PY'
import datetime, json, os, re, subprocess, sys
(run, sample, board, addr, phys, nbytes, packets, insns, txt_lines, slices,
 root, zcs) = sys.argv[1:13]
nbytes, packets, insns, txt_lines, slices = map(int, (nbytes, packets, insns, txt_lines, slices))

def rev(p):
    try:
        return subprocess.run(["git", "-C", p, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip() or None
    except Exception:
        return None

console = os.path.join(run, "console.txt")
lines = open(console).read().splitlines() if os.path.exists(console) else []

# Which functions the decoded trace actually contains, and in what order it opens.
#
# This is the difference between a trace of the workload and a trace of the whole guest,
# and a byte count cannot tell them apart. The probe list is Zephyr's early boot path as
# it appears in Lab A's Spike trace, minus the transport-specific bits (Spike consoles
# over HTIF, this board over a SiFive UART).
BOOT_PROBES = ["z_prep_c", "arch_bss_zero", "memset", "soc_interrupt_init", "z_cstart",
               "z_sys_init_run_level", "do_device_init", "plic_init",
               "sys_clock_driver_init", "uart_console_init",
               "z_riscv_switch_to_main_no_multithreading", "bg_thread_main",
               "boot_banner", "main"]
pf = os.path.join(run, "trace.perfetto.json")
opened, seen = [], set()
if os.path.exists(pf):
    for m in re.finditer(r'"name":"([^"]*)","ph":"B"', open(pf).read()):
        n = m.group(1)
        if n not in seen:
            seen.add(n)
            opened.append(n)
boot_symbols = [p for p in BOOT_PROBES if p in seen]
# z_prep_c is the first C function the reset vector calls and z_cstart is the kernel
# entry: both present means the encoder was already running before either was reached.
traced_from_boot = "z_prep_c" in seen and "z_cstart" in seen
json.dump({
    "name": os.path.basename(run),
    "generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "sample": sample,
    "board": board,
    "source": "fpga",
    "trace_buffer": {"rocket": addr, "ps_phys": f"0x{int(phys):08X}"},
    "console_lines": lines,
    "pins": {
        "zephyr-chipyard-sw": rev(zcs),
        "tacit-decoder": rev(os.path.join(root, "third_party", "tacit-decoder")),
    },
    # The golden check compares the fields below. tacit_out_bytes is deliberately NOT
    # among them: the encoder timestamps every packet with a delta in core cycles, so a
    # DRAM refresh or a differently-timed interrupt shifts a varint from one byte to two
    # and the total moves by a few tens of bytes between otherwise identical runs.
    "results": {
        "booted": any(l.startswith("*** Booting Zephyr OS") for l in lines),
        "sink_wrote_bytes": nbytes > 0,
        "decoded_ok": packets > 0 and insns > 0,
        "packets_decoded": packets,
        "instructions_decoded": insns,
        "decoded_txt_lines": txt_lines,
        "perfetto_begin_slices": slices,
        "traced_from_boot": traced_from_boot,
        "first_slice": opened[0] if opened else None,
        "boot_symbols": boot_symbols,
    },
    "measured": {
        "distinct_slice_names": len(seen),
        "first_slices": opened[:12],
        "tacit_out_bytes": nbytes,
        "bits_per_instruction": round(nbytes * 8 / insns, 3) if insns else None,
        "elf_bytes": os.path.getsize(os.path.join(run, "zephyr.elf")),
    },
}, open(os.path.join(run, "run.json"), "w"), indent=2)
PY
cat "$RUN/run.json"

[ -n "$EXPECT" ] || EXPECT="$IISWC_ROOT/expected/$(basename "$SAMPLE").json"
if [ -f "$EXPECT" ]; then
  step "check  (vs $(basename "$EXPECT"))"
  if python3 - "$RUN/run.json" "$EXPECT" <<'PYCHECK'
import json, sys
got = json.load(open(sys.argv[1]))["results"]
exp = json.load(open(sys.argv[2]))
bad = 0
for k, want in exp.items():
    if k.startswith("_"):
        continue
    have = got.get(k)
    # Counts that depend on when the timer interrupt lands are checked to a tolerance;
    # booleans and anything given exactly are compared exactly.
    if isinstance(want, dict) and "within" in want:
        lo, hi = want["value"] * (1 - want["within"]), want["value"] * (1 + want["within"])
        ok = have is not None and lo <= have <= hi
        shown = f"{want['value']} +/-{want['within']*100:g}%"
    else:
        ok = have == want
        shown = want
    if not ok:
        bad += 1
    print(f"    {'ok  ' if ok else 'FAIL'}  {k:<24} expected {shown!s:>20}   got {have!s:>10}")
sys.exit(1 if bad else 0)
PYCHECK
  then printf '    \033[1;32mPASS\033[0m  reproduces the golden run\n'
  else printf '    \033[1;31mFAIL\033[0m  output differs from expected/ -- see the table above\n'; exit 1
  fi
else
  info "no golden file at $EXPECT -- skipping check"
fi

step "Done"
info "open  $RUN/trace.perfetto.json  at https://ui.perfetto.dev"
