#!/usr/bin/env bash
# Lab B11 -- TWO harts, TWO TACIT traces, ONE timeline, TWO INSTRUCTION SETS.
#
#   west build (chipyard_pynqz1_pext) -> scp zephyr.bin -> PS writes DDR -> release reset
#   -> pulse custom_boot -> BOTH harts configure their own encoder + DMA sink
#   -> hart 0 runs a body built out of the four MBP packed-SIMD instructions,
#      hart 1 runs the same arithmetic through pext.h's software model
#   -> each sink streams into its own DDR buffer -> PS reads both over /dev/mem
#   -> ltrace-decoder --trace x2 -> ONE merged Perfetto file with a named track per hart,
#      the barrier located in both traces and its timestamps compared
#      -> the MBP instructions in hart 0's trace are checked AGAINST THE ELF
#
# This is scripts/26_rocket_tacit_smp.sh (Lab B7) moved onto the P-ext bitstream and
# pointed at something worth tracing. Neither 26 nor samples/tacit_smp is modified.
# PEXT_BITSTREAM.md section 7 left "TACIT has not been captured on this bitstream" as an
# open item and called the expectation that it would work "a prediction, not a
# measurement". This is the measurement.
#
# FOUR THINGS DIFFER FROM LAB B7, and each is a consequence of the extension:
#
#   * a different bitstream    build_rocket_pext_z1/pynqz1_rocket_pext.bit
#   * a different MAGIC        0x5A5A0004, so a run against the plain dual-core PL is
#                              refused rather than trapping on the first MBP op -- which
#                              would look exactly like the heterogeneity claim failing
#   * a different Zephyr board chipyard_pynqz1_pext (34483 Hz mtime, not 40000; that
#                              constant is also the UART baud divisor)
#   * a different FCLK         34.4828 MHz, programmed by run_rocket_pext.py
#
# AND ONE THING IS GENUINELY NEW: stage 8. The decoded traces are not trusted, they are
# checked against ground truth that does not come from the decoder:
#
#   1. THE ELF.  Every address hart 0's trace labels `mbp.*` is disassembled independently
#      out of the image -- opcode, funct7, funct3 and the three register fields -- and the
#      decoder's mnemonic and operands must agree field for field with
#      fpga/pynq-z2/sw/pext.h's encoding table. patches/0007 is what teaches the decoder
#      those names; this is the check that it teaches it the RIGHT ones.
#
#   2. THE TRIP COUNT.  samples/tacit_pext_smp prints PEXT_EXPECT before it runs: one of
#      each op per round, a compile-time trip count, no data-dependent exit. The decoded
#      dynamic counts must be exactly those four numbers. A decoder that dropped,
#      duplicated or mis-split packets around a custom opcode would still produce a
#      plausible-looking trace, and nothing else here would notice.
#
#   3. THE OTHER HART.  hart 1's trace must contain ZERO `mbp.*` and zero `unknown` at any
#      MBP address. That is the heterogeneity, seen in the trace rather than asserted.
#
#   4. THE CLOCK.  The span between the first and last MBP instruction in hart 0's trace,
#      in encoder timestamps, against the same interval measured by the guest with rdcycle.
#      Two independent readings of one duration on one hart.
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin / zephyr.dis   the traced guest, and its disassembly
#   console.txt                            TACIT_HART / TACIT_TIME / PEXT_EXPECT / PEXT_BODY
#   boot.log, drain.log                    the PS-side transcripts
#   hart0/, hart1/                         tacit.out, trace.txt, trace.perfetto.json
#   trace.merged.perfetto.json             BOTH harts in one file, a named track each --
#                                          mbp_body_hw next to mbp_body_sw on one axis
#   mbp_decode.txt                         stage 8 in full
#   run.json                               manifest, checked against expected/tacit_pext_smp.json
#
# The board is shared. Run this under the lock:
#   scripts/with_board.sh ./scripts/31_rocket_tacit_pext_smp.sh
#   scripts/with_board.sh ./scripts/31_rocket_tacit_pext_smp.sh --no-bitstream
#   scripts/with_board.sh ./scripts/31_rocket_tacit_pext_smp.sh --name X --no-expect
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$IISWC_ROOT/samples/tacit_pext_smp"
NAME="rocket_tacit_pext_smp"
BOARD="chipyard_pynqz1_pext"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_pext_z1/pynqz1_rocket_pext.bit"
LOAD_BIT=1
SECONDS_READ=60
EXPECT=""
NO_EXPECT=0
# Rocket's ExtMem base and where the FPGA top folds it into PS physical memory, from
# src/pynqz2_rocket_top.v: {4'd1, addr[27:0]}.
ROCKET_MEM_BASE=$((0x80000000))
PS_MEM_BASE=$((0x10000000))
# The function samples/tacit_pext_smp calls once per hart, immediately after the barrier.
MARKER=tacit_sync_marker
# The clock this bitstream is TIMED at, and the mtime rate x 1000 the board Kconfig has.
WANT_MTIME_HZ=34483

while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --bit)    BIT="${2:?}";    shift 2 ;;
    --marker) MARKER="${2:?}"; shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --expect) EXPECT="${2:?}"; shift 2 ;;
    --no-expect) NO_EXPECT=1; shift ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    -h|--help) sed -n '2,64p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"
need_exec "$TACIT_DECODER" "run scripts/05_build_tacit_tools.sh, or export TACIT_DECODER"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; BUILD="$RUN/build"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/8  build  ($BOARD)"
info "sample: $SAMPLE"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- -DBOARD_ROOT="$IISWC_ROOT" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"

NCPU=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${NCPU:-1}" -ge 2 ] || die "CONFIG_MP_MAX_NUM_CPUS=$NCPU -- this image would trace one hart"
grep -q '^CONFIG_SMP=y' "$BUILD/zephyr/.config" || die "CONFIG_SMP is not enabled in this image"
grep -q '^CONFIG_MB_PEXT=y' "$BUILD/zephyr/.config" || die "CONFIG_MB_PEXT is not set --
       hart 0 would execute pext.h's software model and BOTH traces would contain the
       same instructions, which is the one thing this lab exists not to report"
grep -q '^CONFIG_SCHED_CPU_MASK=y' "$BUILD/zephyr/.config" || die "CONFIG_SCHED_CPU_MASK
       is off -- k_thread_cpu_pin() would not exist, and the MBP body could land on the
       hart where MBP is an illegal instruction"
HZ=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${HZ:-0}" = "$WANT_MTIME_HZ" ] || die "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, expected
       $WANT_MTIME_HZ. That constant is the SiFive UART's baud divisor as well as the tick
       rate, so a mismatch shows up as a GARBLED console -- FPGA_END_TO_END.md 4.1."

# Where the marker lives, so the trace can be located by address as well as by name. A
# marker gcc inlined or cloned away would be caught right here rather than at the end.
NM="$ZEPHYR_SDK_INSTALL_DIR/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-nm"
[ -x "$NM" ] || NM=nm
MARKER_SYMS=$("$NM" -S --defined-only "$RUN/zephyr.elf" 2>/dev/null | awk -v m="$MARKER" '$4==m {print $1, $2}')
[ -n "$MARKER_SYMS" ] || die "no symbol '$MARKER' in the built ELF.
    The decoder resolves slice names from the symbol table; a marker that gcc inlined or
    cloned cannot be found in either trace. Check the noinline/noclone attributes."
MARKER_ADDR=0x$(awk '{print $1}' <<<"$MARKER_SYMS")
MARKER_SIZE=0x$(awk '{print $2}' <<<"$MARKER_SYMS")

# THE GROUND TRUTH for stage 8, extracted before the board is touched: every MBP encoding
# in the image, by address, decoded by hand out of the disassembly against PEXT_SPEC.md
# 3.0. `.insn` leaves no trace in Tag_RISCV_arch -- on purpose, it is what keeps the exact
# rv64imac multilib match -- so the disassembly is the only place this exists.
OBJDUMP="$(command -v riscv64-zephyr-elf-objdump || true)"
[ -n "$OBJDUMP" ] || die "riscv64-zephyr-elf-objdump not on PATH -- source env.sh"
"$OBJDUMP" -d "$RUN/zephyr.elf" > "$RUN/zephyr.dis"
python3 - "$RUN/zephyr.dis" "$RUN/mbp_sites.json" <<'PY' || die "no MBP encodings in the image -- hart 0 would trace nothing worth decoding"
import json, re, sys
names = ["dot8", "max8", "qmul", "clip8"]
sites, other = {}, 0
for m in re.finditer(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s", open(sys.argv[1]).read(), re.M):
    v = int(m.group(2), 16)
    if (v & 0x7f) != 0x0b:
        continue
    if (v >> 25) != 0 or ((v >> 12) & 7) > 3:
        other += 1
        continue
    sites["0x" + m.group(1).lstrip("0").rjust(1, "0")] = {
        "word": m.group(2), "op": names[(v >> 12) & 7],
        "rd": (v >> 7) & 31, "rs1": (v >> 15) & 31, "rs2": (v >> 20) & 31,
    }
json.dump({"sites": sites, "non_mbp_custom0": other}, open(sys.argv[2], "w"), indent=2)
for a, s in sorted(sites.items()):
    print(f"    {a}  {s['word']}  mbp.{s['op']:<5} x{s['rd']}, x{s['rs1']}, x{s['rs2']}")
print(f"    {len(sites)} MBP site(s) in the image" +
      (f", plus {other} custom-0 words that are NOT MBP" if other else ""))
sys.exit(0 if sites else 1)
PY
info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")   cpus: $NCPU   mtime: $HZ Hz"
info "marker: $MARKER at $MARKER_ADDR, $((MARKER_SIZE)) bytes"

step "2/8  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_pext.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "3/8  load the P-ext PL and hold the SoC in reset"
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
wrong_pl () {
  if grep -q 'MAGIC = 0x5A5A0003' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the plain DUAL-CORE bitstream is loaded (MAGIC 0x5A5A0003). It has no MBP unit on
       either hart, so hart 0's body would take an illegal-instruction trap inside the
       traced window. Re-run without --no-bitstream, or load $BIT."
  fi
  if grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the SINGLE-core bitstream is loaded (MAGIC 0x5A5A0002). Only one hart would
       trace, and a single trace has nothing to be synchronised against."
  fi
  if grep -q 'MAGIC = 0x5A5A0001' "$RUN/boot.log"; then
    cat "$RUN/boot.log"; die "the DRAM self-test bitstream is loaded (MAGIC 0x5A5A0001)."
  fi
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_pext.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_pext.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0004' "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "P-ext bitstream not reachable over GP0"
}
grep -E 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true
info "P-ext PL loaded, SoC held in reset"

step "4/8  boot both harts and capture the console"
# The console reader starts BEFORE the core: the SiFive UART's TX FIFO is 8 bytes deep.
# It stops the moment TACIT_SMP_DONE lands rather than holding the board for the timeout.
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_pext.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  for i in \$(seq 1 $SECONDS_READ); do
    grep -q TACIT_SMP_DONE console.out 2>/dev/null && break
    sleep 1
  done
  kill \$CPID 2>/dev/null
  wait \$CPID 2>/dev/null
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true

if [ -s "$RUN/console.txt" ]; then
  printf '%s\n' "----------------------------------------------------------------"
  cat "$RUN/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
else
  warn "no console output -- check $RUN/boot.log"
  grep -E 'STATUS|saw_mem' "$RUN/boot.log" | tail -6 || true
  die "the SoC produced no console output"
fi
grep -q '\*\*\* Booting Zephyr OS' "$RUN/console.txt" || die "the SoC did not boot; see $RUN/boot.log"
if grep -q '^TACIT_PEXT_FAIL' "$RUN/console.txt"; then
  die "guest reported: $(grep -m1 '^TACIT_PEXT_FAIL' "$RUN/console.txt")"
fi
grep -q '^TACIT_SMP_DONE' "$RUN/console.txt" ||
  die "no TACIT_SMP_DONE line -- the run did not complete; see $RUN/console.txt"

mapfile -t HART_LINES < <(grep '^TACIT_HART ' "$RUN/console.txt")
[ "${#HART_LINES[@]}" -eq 2 ] || die "expected 2 TACIT_HART lines, got ${#HART_LINES[@]}"

step "5/8  drain both buffers over /dev/mem"
HARTS=(); BYTES=()
for line in "${HART_LINES[@]}"; do
  grep -q NEVER_RAN <<<"$line" && die "a worker never ran: $line"
  h=$(sed -n 's/.* hart=\([0-9]*\).*/\1/p' <<<"$line")
  a=$(sed -n 's/.* buf=\(0x[0-9a-fA-F]*\).*/\1/p' <<<"$line")
  n=$(sed -n 's/.* bytes=\([0-9]*\).*/\1/p' <<<"$line")
  [ -n "$h" ] && [ -n "$a" ] && [ -n "$n" ] || die "could not parse: $line"
  [ "$n" -gt 0 ] 2>/dev/null || die "hart $h's sink wrote 0 bytes -- encoder target or sink address wrong
    line: $line"
  phys=$(( $((a)) - ROCKET_MEM_BASE + PS_MEM_BASE ))
  info "hart $h: $n bytes at Rocket $a = PS phys $(printf '0x%08X' $phys)"
  mkdir -p "$RUN/hart$h"
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 -u read_mem.py \
     --phys $(printf '0x%X' $phys) --bytes $n --out tacit$h.out" \
     >> "$RUN/drain.log" 2>&1 || { cat "$RUN/drain.log"; die "could not read hart $h's buffer"; }
  run scp -q "$PYNQ_HOST:$PYNQ_DIR/tacit$h.out" "$RUN/hart$h/tacit.out"
  got=$(stat -c%s "$RUN/hart$h/tacit.out")
  [ "$got" -eq "$n" ] || die "hart $h short read: got $got bytes, guest reported $n"
  HARTS+=("$h"); BYTES+=("$n")
done

step "6/8  decode both traces into one timeline"
# --encoder rtl: the hardware encoder's sync and trap packets carry neither the privilege
# byte nor the context varint that spike's trace_encoder_l emits. See
# fpga/pynq-z2/docs/TACIT_ON_FPGA.md.
#
# ONE decoder run, not two. `--trace FILE:HART:LABEL` (patches/0010) decodes every hart in
# a single pass and writes BOTH the per-hart trace.txt / trace.perfetto.json, next to each
# tacit.out where they have always been, AND trace.merged.perfetto.json: one file, one
# NAMED Perfetto track per hart. That is what makes the point of this lab visible in one
# picture -- mbp_body_hw and mbp_body_sw, the same arithmetic, side by side on one axis.
#
# THE LABELS COME FROM HERE, not from the decoder. Which hart carries the MBP datapath is
# a property of this bitstream, and the guest states it: PEXT_EXPECT prints on_hart=N.
# That is read rather than assumed, so a future build that swaps the roles relabels the
# tracks instead of mislabelling them.
# The leading space matters: the same line also carries `none_on_hart=`, and a greedy
# `.*` without it happily matches that one instead and labels the tracks backwards.
MBP_HART=$(sed -n 's/^PEXT_EXPECT .* on_hart=\([0-9]*\) .*/\1/p' "$RUN/console.txt" | head -1)
[ -n "$MBP_HART" ] || die "no PEXT_EXPECT line in $RUN/console.txt -- cannot tell which hart has MBP"
MERGED="$RUN/trace.merged.perfetto.json"
DEC_ARGS=(); LABELS=()
for h in "${HARTS[@]}"; do
  if [ "$h" = "$MBP_HART" ]; then lbl="hart $h (big, MBP)"; else lbl="hart $h (LITTLE, scalar)"; fi
  LABELS+=("$lbl")
  DEC_ARGS+=(--trace "$RUN/hart$h/tacit.out:$h:$lbl")
done
run "$TACIT_DECODER" \
    --binary "$RUN/zephyr.elf" \
    --encoder rtl \
    --to-txt --to-perfetto \
    "${DEC_ARGS[@]}" \
    --merged-perfetto "$MERGED" > "$RUN/decode.log" 2>&1 \
  || { tail -20 "$RUN/decode.log"; die "decode failed -- $RUN/decode.log"; }
need_file "$MERGED" "the decoder produced no merged perfetto trace"
# Split the one log back into the per-hart logs the manifest stage reads, so that stage
# keeps counting packets per hart rather than over the concatenation.
awk -v run="$RUN" '/^\[trace [0-9]+\] hart [0-9]+ / { out = run "/hart" $4 "/decode.log"; printf "" > out }
                   out != "" { print > out }' "$RUN/decode.log"
for h in "${HARTS[@]}"; do
  need_file "$RUN/hart$h/trace.perfetto.json" "hart $h: decoder produced no perfetto trace"
  grep -q 'detected FSync packet, trace ending' "$RUN/hart$h/decode.log" \
    || warn "hart $h: decoder did not reach the trailing sync packet -- stream may be truncated"
  p=$(sed -n 's/.*Decoded \([0-9]*\) packets.*/\1/p' "$RUN/hart$h/decode.log" | tail -1)
  i=$(grep -cE '^0x[0-9a-f]+: ' "$RUN/hart$h/trace.txt" 2>/dev/null || echo 0)
  info "hart $h: ${p:-0} packets, $i instructions, $(fsize "$RUN/hart$h/tacit.out")"
done
info "merged: $MERGED   (MBP hart is $MBP_HART, per the guest's PEXT_EXPECT line)"

step "7/8  correlate: the same barrier, in both traces"
python3 - "$RUN" "$SAMPLE" "$BOARD" "$MARKER" "$MARKER_ADDR" "$MARKER_SIZE" \
         "$IISWC_ROOT" "$ZCS" "${HARTS[0]}" "${HARTS[1]}" "${LABELS[0]}" "${LABELS[1]}" \
         "$MBP_HART" <<'PY'
import datetime, json, os, re, subprocess, sys

run, sample, board, marker, m_addr, m_size, root, zcs, h0, h1, l0, l1, mh = sys.argv[1:14]
m_lo = int(m_addr, 16)
m_hi = m_lo + int(m_size, 16)
harts = [int(h0), int(h1)]
labels = {int(h0): l0, int(h1): l1}
mbp_hart = int(mh)


def rev(p):
    try:
        return subprocess.run(["git", "-C", p, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip() or None
    except Exception:
        return None


def marker_ts_perfetto(path):
    """Timestamp of the marker's Begin slice -- the cycle the call executed."""
    if not os.path.exists(path):
        return None, 0
    txt = open(path).read()
    hits = [int(m.group(1)) for m in re.finditer(
        r'\{"args":\{"addr":"0x[0-9a-f]+"\},"cat":"function","name":"%s","ph":"B","pid":\d+,"tid":\d+,"ts":(\d+)\}'
        % re.escape(marker), txt)]
    if not hits:
        hits = [int(m.group(1)) for m in re.finditer(
            r'"name":"%s","ph":"B"[^}]*"ts":(\d+)' % re.escape(marker), txt)]
    return (hits[0] if hits else None), len(hits)


def marker_ts_txt(path):
    """The same instant read straight out of the decoded instruction stream, without
    going through the decoder's slice/symbol machinery at all."""
    if not os.path.exists(path):
        return None
    ts = None
    for line in open(path):
        if line.startswith('[timestamp: '):
            ts = int(line[12:line.index(']')])
        elif line.startswith('0x'):
            a = int(line[2:line.index(':')], 16)
            if m_lo <= a < m_hi:
                return ts
    return None


def read_merged(path):
    """Read the merged Perfetto file back and take it apart by track.

    The merge is the deliverable, so what it claims is checked against the per-hart files
    it was built from rather than trusted because the decoder exited 0. A track in
    Chrome/Perfetto JSON is nothing but the (pid, tid) pair on each event, and its NAME is
    two "ph":"M" metadata events carrying the same pair -- so "one timeline, a named track
    per hart" is a statement about those, and it is checkable.
    """
    out = {"path": os.path.relpath(path, run), "exists": os.path.exists(path),
           "events": 0, "metadata_events": 0, "tracks": {}}
    if not out["exists"]:
        return out
    open_frames = {}
    for e in json.load(open(path)).get("traceEvents", []):
        out["events"] += 1
        pid = str(e.get("pid"))
        t = out["tracks"].setdefault(pid, {
            "pid": e.get("pid"), "tids": [], "process_name": None, "thread_name": None,
            "slices": 0, "first_ts": None, "last_ts": None,
            "marker_ts": None, "marker_slices": 0, "spans": []})
        if e.get("tid") not in t["tids"]:
            t["tids"].append(e.get("tid"))
        if e.get("ph") == "M":
            out["metadata_events"] += 1
            if e.get("name") in ("process_name", "thread_name"):
                t[e["name"]] = (e.get("args") or {}).get("name")
            continue
        ts = e.get("ts")
        # B/E pair off against a per-track stack, which is what Perfetto itself does to
        # turn these events into slices. The widths that come out are what the UI draws.
        if e.get("ph") == "B":
            t["slices"] += 1
            open_frames.setdefault(pid, []).append((e.get("name"), ts))
            if e.get("name") == marker:
                t["marker_slices"] += 1
                if t["marker_ts"] is None:
                    t["marker_ts"] = ts
        elif e.get("ph") == "E" and open_frames.get(pid):
            name, t0 = open_frames[pid].pop()
            t["spans"].append({"name": name, "ts": t0,
                               "cycles": None if (ts is None or t0 is None) else ts - t0})
        if ts is not None:
            t["first_ts"] = ts if t["first_ts"] is None else min(t["first_ts"], ts)
            t["last_ts"] = ts if t["last_ts"] is None else max(t["last_ts"], ts)
    for t in out["tracks"].values():
        t["spans"].sort(key=lambda s: (s["ts"] is None, s["ts"]))
    return out

console = os.path.join(run, "console.txt")
lines = open(console).read().splitlines() if os.path.exists(console) else []
text = "\n".join(lines)

sw = {}
for m in re.finditer(r'^TACIT_TIME idx=(\d+) hart=(\d+) c_rv0=(\d+) c_rv1=(\d+) '
                     r'c_rv2=(\d+) c_marker=(\d+) t_rv0=(\d+) t_rv1=(\d+) t_rv2=(\d+)',
                     text, re.M):
    sw[int(m.group(2))] = dict(idx=int(m.group(1)), c_rv0=int(m.group(3)),
                               c_rv1=int(m.group(4)), c_rv2=int(m.group(5)),
                               c_marker=int(m.group(6)), t_rv0=int(m.group(7)),
                               t_rv1=int(m.group(8)), t_rv2=int(m.group(9)))
match_line = re.search(r'^PEXT_MATCH seed=(0x[0-9a-f]+) hw=(0x[0-9a-f]+) '
                       r'sw=(0x[0-9a-f]+) equal=(\d) split=(\d)', text, re.M)
body = {}
for m in re.finditer(r'^PEXT_BODY idx=(\d+) hart=(\d+) mbp=(\d+) rounds=(\d+) '
                     r'cycles=(\d+) result=(0x[0-9a-f]+)', text, re.M):
    body[int(m.group(2))] = dict(mbp=int(m.group(3)) == 1, rounds=int(m.group(4)),
                                 cycles=int(m.group(5)), result=m.group(6))

per_hart = {}
for h in harts:
    d = os.path.join(run, f"hart{h}")
    logp = os.path.join(d, "decode.log")
    log = open(logp).read() if os.path.exists(logp) else ""
    pk = re.findall(r"Decoded (\d+) packets", log)
    ts_pf, n_pf = marker_ts_perfetto(os.path.join(d, "trace.perfetto.json"))
    ts_tx = marker_ts_txt(os.path.join(d, "trace.txt"))
    txtp = os.path.join(d, "trace.txt")
    insns = 0
    first_ts = last_ts = None
    if os.path.exists(txtp):
        for line in open(txtp):
            if line.startswith('[timestamp: '):
                t = int(line[12:line.index(']')])
                first_ts = t if first_ts is None else first_ts
                last_ts = t
            elif line.startswith('0x'):
                insns += 1
    per_hart[h] = {
        "bytes": os.path.getsize(os.path.join(d, "tacit.out")),
        "packets": int(pk[-1]) if pk else 0,
        "instructions": insns,
        "trace_first_ts": first_ts,
        "trace_last_ts": last_ts,
        "marker_slices": n_pf,
        "marker_ts_perfetto": ts_pf,
        "marker_ts_txt": ts_tx,
        "sw": sw.get(h),
        "body": body.get(h),
    }

a, b = harts[0], harts[1]
pa, pb = per_hart[a], per_hart[b]


def sub(x, y):
    return None if (x is None or y is None) else x - y


trace_skew = sub(pb["marker_ts_perfetto"], pa["marker_ts_perfetto"])
trace_skew_txt = sub(pb["marker_ts_txt"], pa["marker_ts_txt"])
sw_skew_r0 = sub(pb["sw"]["c_rv0"] if pb["sw"] else None, pa["sw"]["c_rv0"] if pa["sw"] else None)
sw_skew_r1 = sub(pb["sw"]["c_rv1"] if pb["sw"] else None, pa["sw"]["c_rv1"] if pa["sw"] else None)
sw_skew_r2 = sub(pb["sw"]["c_rv2"] if pb["sw"] else None, pa["sw"]["c_rv2"] if pa["sw"] else None)
idle_cost = sub(sw_skew_r1, sw_skew_r0)

agree_txt = (trace_skew is not None and trace_skew_txt is not None
             and abs(trace_skew - trace_skew_txt) <= 64)
agree_sw = (trace_skew is not None and sw_skew_r2 is not None
            and abs(trace_skew - sw_skew_r2) <= 512)

merged = read_merged(os.path.join(run, "trace.merged.perfetto.json"))
mt = merged["tracks"]
merged_harts = sorted(int(k) for k in mt)
# Named, and named what the caller asked for -- a track called "0" is a track the reader
# still has to decode in their head.
merged_named = (merged_harts == sorted(harts)
                and all(mt[str(h)]["process_name"] == labels[h]
                        and mt[str(h)]["thread_name"] == labels[h]
                        and mt[str(h)]["tids"] == [h] for h in harts))
# And the same events, on the same axis, as the per-hart files. If the merge had rescaled,
# re-based or dropped anything, this is where it would show.
merged_matches = (merged_named
                  and all(mt[str(h)]["marker_ts"] == per_hart[h]["marker_ts_perfetto"]
                          and mt[str(h)]["marker_slices"] == per_hart[h]["marker_slices"]
                          for h in harts))
merged_skew = (sub(mt[str(b)]["marker_ts"], mt[str(a)]["marker_ts"]) if merged_named else None)
merged_span = ([min(mt[str(h)]["first_ts"] for h in harts),
                max(mt[str(h)]["last_ts"] for h in harts)] if merged_named else None)


def body_span(h):
    """The mbp_body_* slice on one hart, read out of the MERGED file.

    This is the picture the lab exists to produce: the same arithmetic, on two harts, on
    one axis, one of them with the datapath. Reading the widths back out of the merged
    file is how "they line up" stops being a claim about a screenshot.
    """
    for sp in mt.get(str(h), {}).get("spans", []):
        if sp["name"].startswith("mbp_body_"):
            return sp
    return None


bodies = {h: body_span(h) for h in harts} if merged_named else {h: None for h in harts}
mbp_body = bodies.get(mbp_hart)
scalar_hart = [h for h in harts if h != mbp_hart][0]
scalar_body = bodies.get(scalar_hart)
merged_bodies_present = mbp_body is not None and scalar_body is not None
# The heterogeneity, read off the merged timeline alone: the hart with the datapath spends
# fewer cycles in the same function. Not a bound, a direction -- the ratio is recorded but
# not checked, because it is a hardware measurement.
merged_mbp_body_shorter = (merged_bodies_present
                           and mbp_body["cycles"] is not None
                           and scalar_body["cycles"] is not None
                           and mbp_body["cycles"] < scalar_body["cycles"])

print(f"    marker: {marker} at {m_addr}")
for h in harts:
    p = per_hart[h]
    kind = "MBP" if (p["body"] and p["body"]["mbp"]) else "scalar"
    print(f"    hart {h} ({kind:>6}): trace [{p['trace_first_ts']} .. {p['trace_last_ts']}]  "
          f"{p['packets']} packets, {p['instructions']} insns, "
          f"{p['marker_slices']} marker slice(s)")
    print(f"            marker ts (perfetto) = {p['marker_ts_perfetto']}   "
          f"(trace.txt) = {p['marker_ts_txt']}   "
          f"rdcycle at barrier = {p['sw']['c_rv2'] if p['sw'] else None}")
print()
print(f"    SKEW hart{b} - hart{a}, at the barrier")
print(f"      from the TRACES    : {trace_skew} cycles   "
      f"(cross-checked in trace.txt: {trace_skew_txt})")
print(f"      from SOFTWARE      : {sw_skew_r2} cycles")
print(f"      at R0 / R1         : {sw_skew_r0} / {sw_skew_r1} cycles "
      f"(idle differential cost {idle_cost})")
print(f"      methods agree      : perfetto vs trace.txt {agree_txt}, "
      f"trace vs software {agree_sw}")
print()
print(f"    MERGED  {merged['path']}   {merged['events']} events, "
      f"{len(merged_harts)} track(s)")
for h in harts:
    t = mt.get(str(h))
    if not t:
        print(f"      hart {h}: MISSING from the merged file")
        continue
    print(f"      pid {t['pid']} tid {','.join(str(x) for x in t['tids'])}  "
          f"{t['process_name']!r}  {t['slices']} slice(s)  "
          f"[{t['first_ts']} .. {t['last_ts']}]  marker @{t['marker_ts']}")
    for sp in t["spans"]:
        print(f"          {sp['name']:<24} @{sp['ts']}  {sp['cycles']} cycles")
if merged_span:
    print(f"      one axis: {merged_span[0]} .. {merged_span[1]}  "
          f"({merged_span[1] - merged_span[0]} cycles wide), "
          f"skew from the merged file {merged_skew}")
if merged_bodies_present:
    print(f"      the body, on one axis: hart {mbp_hart} {mbp_body['name']} "
          f"{mbp_body['cycles']} cycles vs hart {scalar_hart} {scalar_body['name']} "
          f"{scalar_body['cycles']} cycles  "
          f"({scalar_body['cycles'] / mbp_body['cycles']:.1f}x)")
print(f"      merged agrees with the per-hart files: {merged_matches}")

json.dump({
    "name": os.path.basename(run),
    "generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "sample": sample,
    "board": board,
    "source": "fpga",
    "bitstream": "fpga/pynq-z2/build_rocket_pext_z1/pynqz1_rocket_pext.bit",
    "magic": "0x5A5A0004",
    "marker": {"symbol": marker, "addr": m_addr, "size": m_size},
    "console_lines": lines,
    "pins": {
        "zephyr-chipyard-sw": rev(zcs),
        "tacit-decoder": rev(os.path.join(root, "third_party", "tacit-decoder")),
    },
    "per_hart": {str(h): per_hart[h] for h in harts},
    "merged": merged,
    "results": {
        "booted": any(l.startswith("*** Booting Zephyr OS") for l in lines),
        "both_harts_traced": all(per_hart[h]["bytes"] > 0 and per_hart[h]["packets"] > 0
                                 for h in harts),
        "harts_traced": sorted(harts),
        "marker_found_once_in_both": all(per_hart[h]["marker_slices"] == 1 for h in harts),
        "perfetto_matches_txt": agree_txt,
        "trace_matches_software": agree_sw,
        "trace_skew_cycles": trace_skew,
        "sw_skew_cycles": sw_skew_r2,
        "synchronized": (trace_skew is not None and abs(trace_skew) < 10000),
        "run_ok": "TACIT_SMP_DONE harts=2 ok=1" in text,
        # The merged timeline, checked rather than assumed: it exists, it has one track
        # per hart carrying the caller's label in both process_name and thread_name, every
        # hart's marker sits at the same cycle it does in that hart's own file, and the
        # two bodies are both on it with the MBP one the shorter.
        "merged_trace_written": merged["exists"] and merged["events"] > 0,
        "merged_harts": merged_harts,
        "merged_tracks_named": merged_named,
        "merged_matches_per_hart": merged_matches,
        "merged_body_on_mbp_hart": mbp_body["name"] if mbp_body else None,
        "merged_body_on_scalar_hart": scalar_body["name"] if scalar_body else None,
        "merged_mbp_body_shorter": merged_mbp_body_shorter,
        # The routed MBP datapath against pext.h's own software model of it, both
        # compiled into ONE image from ONE seed, inside the traced window. The header is
        # the normative definition (PEXT_SPEC.md 3.5), so "equal" is the whole claim and
        # the two words are recorded so a future run is pinned to the same answer.
        "hw_matches_sw_model": bool(match_line) and match_line.group(4) == "1"
                               and match_line.group(5) == "1",
        "body_seed": match_line.group(1) if match_line else None,
        "body_result_hw": match_line.group(2) if match_line else None,
        "body_result_sw": match_line.group(3) if match_line else None,
    },
    "measured": {
        "trace_skew_cycles": trace_skew,
        "trace_skew_cycles_txt": trace_skew_txt,
        "sw_skew_r0_cycles": sw_skew_r0,
        "sw_skew_r1_cycles": sw_skew_r1,
        "sw_skew_r2_cycles": sw_skew_r2,
        "idle_differential_cost_cycles": idle_cost,
        "body_cycles": {str(h): (per_hart[h]["body"] or {}).get("cycles") for h in harts},
        "elf_bytes": os.path.getsize(os.path.join(run, "zephyr.elf")),
        "merged_events": merged["events"],
        "merged_trace_skew_cycles": merged_skew,
        "merged_span_cycles": merged_span,
        "merged_span_width_cycles": (merged_span[1] - merged_span[0]) if merged_span else None,
        "merged_body_cycles": {str(h): (bodies[h] or {}).get("cycles") for h in harts},
        "merged_body_cycles_ratio": (round(scalar_body["cycles"] / mbp_body["cycles"], 1)
                                     if merged_mbp_body_shorter else None),
    },
}, open(os.path.join(run, "run.json"), "w"), indent=2)
PY

step "8/8  the MBP instructions in the decoded stream, against the ELF"
# `set +e` around the pipeline: common.sh sets `pipefail`, so a failing check would
# otherwise take the script out before the diagnostic below ever prints. PIPESTATUS[0] is
# the checker's own status, not tee's.
set +e
python3 - "$RUN" "$RUN/mbp_sites.json" "${HARTS[0]}" "${HARTS[1]}" <<'PY' | tee "$RUN/mbp_decode.txt"
import json, os, re, sys
run, sites_path, h0, h1 = sys.argv[1:5]
harts = [int(h0), int(h1)]
sites = json.load(open(sites_path))["sites"]
site_addrs = {int(a, 16) for a in sites}

text = open(os.path.join(run, "console.txt")).read()
m = re.search(r'^PEXT_EXPECT rounds=(\d+) dot8=(\d+) max8=(\d+) qmul=(\d+) clip8=(\d+) '
              r'total=(\d+) on_hart=(\d+) none_on_hart=(\d+)', text, re.M)
if not m:
    print("    FAIL: the guest printed no PEXT_EXPECT line -- nothing to check against")
    sys.exit(1)
expect = {"dot8": int(m.group(2)), "max8": int(m.group(3)),
          "qmul": int(m.group(4)), "clip8": int(m.group(5))}
mbp_hart, scalar_hart = int(m.group(7)), int(m.group(8))
print(f"    the guest's claim (PEXT_EXPECT): {expect}, total {m.group(6)}, "
      f"on hart {mbp_hart}, none on hart {scalar_hart}")
print(f"    ground truth from the ELF      : {len(sites)} static MBP site(s)")
for a, s in sorted(sites.items(), key=lambda kv: int(kv[0], 16)):
    print(f"       {a}  {s['word']}  mbp.{s['op']:<5} rd=x{s['rd']} rs1=x{s['rs1']} rs2=x{s['rs2']}")

# Everything the decoder said about an MBP mnemonic, per hart, with its timestamps.
MBP_RE = re.compile(r'^(0x[0-9a-f]+): mbp\.(\w+)\s*(.*)$')
INSN_RE = re.compile(r'^(0x[0-9a-f]+): (\S+)')
per_hart = {}
for h in harts:
    p = os.path.join(run, f"hart{h}", "trace.txt")
    counts, seen, bad_operands, unknown_at_site = {}, {}, [], 0
    first_ts = last_ts = None
    ts = None
    for line in open(p):
        if line.startswith('[timestamp: '):
            ts = int(line[12:line.index(']')])
            continue
        mm = MBP_RE.match(line.rstrip('\n'))
        if mm:
            addr, op, ops = mm.group(1), mm.group(2), mm.group(3)
            counts[op] = counts.get(op, 0) + 1
            seen.setdefault(addr, (op, ops))
            if first_ts is None:
                first_ts = ts
            last_ts = ts
            continue
        mi = INSN_RE.match(line.rstrip('\n'))
        if mi and mi.group(2) == 'unknown' and int(mi.group(1), 16) in site_addrs:
            unknown_at_site += 1
    per_hart[h] = dict(counts=counts, seen=seen, unknown_at_site=unknown_at_site,
                       first_ts=first_ts, last_ts=last_ts)

operands_ok = True
counts_ok = True
isolation_ok = True

# --- 1. THE NAMES AND THE OPERANDS, field by field against the ELF -------------------
# patches/0007 rewrites rvdasm's "unknown" placeholder for exactly four encodings. This is
# the check that it rewrites them into the RIGHT thing, and it does not ask the decoder
# for anything but the text it printed.
print("\n    -- 1. every address the decoder called mbp.*, re-decoded from the image --")
REG = re.compile(r'x(\d+)')
for h in harts:
    for addr, (op, ops) in sorted(per_hart[h]["seen"].items(), key=lambda kv: int(kv[0], 16)):
        s = sites.get(addr)
        if s is None:
            print(f"    FAIL  hart {h} {addr}: decoder says mbp.{op}, but that address "
                  f"carries no MBP encoding in the image")
            operands_ok = False
            continue
        regs = [int(x) for x in REG.findall(ops)]
        # CLIP8 prints two operands: PEXT_SPEC.md 3.4 says rs2 is ignored, and pext.h
        # names x0 in the template, so there is nothing to print.
        want = [s["rd"], s["rs1"]] + ([] if s["op"] == "clip8" else [s["rs2"]])
        good = (op == s["op"]) and (regs == want)
        operands_ok = operands_ok and good
        print(f"    {'ok  ' if good else 'FAIL'}  hart {h} {addr}  word {s['word']}  "
              f"decoder: mbp.{op} {ops}   elf: funct3={['dot8','max8','qmul','clip8'].index(s['op'])} "
              f"rd=x{s['rd']} rs1=x{s['rs1']}" +
              ("" if s["op"] == "clip8" else f" rs2=x{s['rs2']}"))

# --- 2. THE DYNAMIC COUNTS, against a trip count the guest declared in advance --------
print("\n    -- 2. dynamic executions, against the guest's own declared trip count --")
got = per_hart[mbp_hart]["counts"]
for op in ("dot8", "max8", "qmul", "clip8"):
    good = got.get(op, 0) == expect[op]
    counts_ok = counts_ok and good
    print(f"    {'ok  ' if good else 'FAIL'}  hart {mbp_hart}  mbp.{op:<5} decoded "
          f"{got.get(op, 0):>4}   expected {expect[op]:>4}")

# --- 3. THE OTHER HART ---------------------------------------------------------------
print("\n    -- 3. the hart without the datapath --")
other = per_hart[scalar_hart]["counts"]
good = sum(other.values()) == 0
isolation_ok = isolation_ok and good
print(f"    {'ok  ' if good else 'FAIL'}  hart {scalar_hart}: {sum(other.values())} mbp.* "
      f"instruction(s) in its trace   expected 0")
for h in harts:
    good = per_hart[h]["unknown_at_site"] == 0
    isolation_ok = isolation_ok and good
    print(f"    {'ok  ' if good else 'FAIL'}  hart {h}: {per_hart[h]['unknown_at_site']} "
          f"instruction(s) decoded as `unknown` at an MBP address   expected 0")

# --- 4. THE SAME DURATION, TWO WAYS --------------------------------------------------
# The span from the first MBP instruction to the last, in encoder timestamps, against the
# guest's own rdcycle bracket around the same loop. They are not identical by
# construction: rdcycle brackets the whole call including its prologue, and the encoder
# stamps the packet that reported the control-flow event, so a few tens of cycles of
# difference is the expected shape.
bm = re.search(r'^PEXT_BODY idx=\d+ hart=%d mbp=1 rounds=\d+ cycles=(\d+)' % mbp_hart,
               text, re.M)
sw_cycles = int(bm.group(1)) if bm else None
p = per_hart[mbp_hart]
span = (p["last_ts"] - p["first_ts"]) if (p["first_ts"] is not None and p["last_ts"] is not None) else None
print("\n    -- 4. the MBP body's duration, from the trace and from rdcycle --")
print(f"    hart {mbp_hart}: first mbp at ts {p['first_ts']}, last at ts {p['last_ts']}"
      f"  -> span {span} cycles")
print(f"    hart {mbp_hart}: rdcycle around the whole body            -> {sw_cycles} cycles")
# The gate is the STRUCTURAL claim and nothing more: the encoder's own view of the body
# must be non-empty and must fit inside the rdcycle bracket the guest put around it. It
# cannot be equal -- rdcycle brackets the call including its prologue, and the last MBP
# instruction's timestamp is the packet that reported the branch before it, so the traced
# span is short by about one loop iteration. The size of that gap is MEASURED and left to
# expected/tacit_pext_smp.json to bound, for the same reason 26 bounds the skew rather
# than pinning it.
delta = None if (span is None or sw_cycles is None) else sw_cycles - span
dur_ok = (span is not None and sw_cycles is not None and span > 0 and span <= sw_cycles)
print(f"    {'ok  ' if dur_ok else 'FAIL'}  the traced span is non-empty and inside the "
      f"software bracket (delta {delta} cycles, "
      f"{'-' if delta is None else round(100.0 * delta / sw_cycles, 2)}% of it)")

# Fold the verdicts into the manifest the previous stage wrote.
manifest = json.load(open(os.path.join(run, "run.json")))
manifest["results"].update({
    "mbp_decoded_on_mbp_hart": sum(got.values()),
    "mbp_decoded_on_scalar_hart": sum(other.values()),
    "mbp_counts_match_trip_count": counts_ok,
    "mbp_operands_match_elf": operands_ok,
    "mbp_unknown_at_site": sum(per_hart[h]["unknown_at_site"] for h in harts),
    "mbp_body_span_inside_rdcycle": dur_ok,
})
manifest["measured"].update({
    "mbp_dynamic_counts": {str(h): per_hart[h]["counts"] for h in harts},
    "mbp_static_sites": sites,
    "mbp_body_trace_span_cycles": span,
    "mbp_body_rdcycle_cycles": sw_cycles,
    "mbp_body_span_delta_cycles": delta,
})
json.dump(manifest, open(os.path.join(run, "run.json"), "w"), indent=2)
sys.exit(0 if (operands_ok and counts_ok and isolation_ok and dur_ok) else 1)
PY
MBP_RC=${PIPESTATUS[0]}
set -e
[ "$MBP_RC" -eq 0 ] || die "the decoded MBP stream does not match the image -- see $RUN/mbp_decode.txt"

python3 -c "
import json,sys
d=json.load(open('$RUN/run.json'))
json.dump({'results':d['results'],'measured':{k:v for k,v in d['measured'].items() if k!='mbp_static_sites'}},sys.stdout,indent=2)
print()
"

[ "$NO_EXPECT" = 1 ] && { step "Done (--no-expect)"; info "merged trace: $MERGED"; exit 0; }
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
    # A skew is checked against a BOUND, not a value: the barrier's release latency is a
    # coherence round trip and moves a few tens of cycles between runs.
    if isinstance(want, dict) and "abs_max" in want:
        ok = have is not None and abs(have) <= want["abs_max"]
        shown = f"|x| <= {want['abs_max']}"
    elif isinstance(want, dict) and "within" in want:
        lo, hi = want["value"] * (1 - want["within"]), want["value"] * (1 + want["within"])
        ok = have is not None and lo <= have <= hi
        shown = f"{want['value']} +/-{want['within']*100:g}%"
    else:
        ok = have == want
        shown = want
    if not ok:
        bad += 1
    print(f"    {'ok  ' if ok else 'FAIL'}  {k:<32} expected {shown!s:>18}   got {have!s:>12}")
sys.exit(1 if bad else 0)
PYCHECK
  then printf '    \033[1;32mPASS\033[0m  both harts traced on one timeline, and only one of them is executing MBP\n'
  else printf '    \033[1;31mFAIL\033[0m  output differs from expected/ -- see the table above\n'; exit 1
  fi
else
  info "no golden file at $EXPECT -- skipping check"
fi

step "Done"
info "open  $MERGED  at https://ui.perfetto.dev -- both harts, one axis, a named track each"
info "the per-hart files are still there: $RUN/hart0/trace.perfetto.json, $RUN/hart1/trace.perfetto.json"
