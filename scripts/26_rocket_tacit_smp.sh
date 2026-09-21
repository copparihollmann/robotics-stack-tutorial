#!/usr/bin/env bash
# Lab B7 -- TWO harts, TWO TACIT traces, ONE timeline.
#
#   west build (chipyard_pynqz1_smp) -> scp zephyr.bin -> PS writes DDR -> release reset
#   -> pulse custom_boot -> BOTH harts configure their own encoder + DMA sink and run
#   -> each sink streams into its own DDR buffer -> PS reads both over /dev/mem
#   -> ltrace-decoder --trace x2 -> ONE merged Perfetto file with a named track per hart,
#      and the same cross-hart barrier located in both traces and its timestamps compared
#
# This is scripts/21_rocket_tacit.sh's capture/decode flow and scripts/22_rocket_smp_run.sh's
# dual-core boot flow, joined. Neither of those is modified. What is genuinely new is the
# last stage: the two decoded traces are not just produced, they are CORRELATED, and the
# number that comes out is the skew between the two harts' timebases at a known common
# instant.
#
# THE MEASUREMENT. samples/tacit_smp pins one worker to each hart and has them meet at a
# barrier that, by construction, neither can leave until both are executing. Each worker
# calls tacit_sync_marker() the moment it leaves, exactly once, inside its traced window.
# So the marker appears exactly once in each hart's decoded trace, and the difference
# between its two timestamps is the skew between the harts' mcycle counters -- which is
# what TACIT stamps every packet with.
#
# The guest also reports the same skew from software (rdcycle, either side of the same
# barrier). The two numbers are independent and must agree; the manifest records both.
#
# BEFORE patches/0004, mcycle stops during `wfi`, the sample's 200 ms idle differential
# puts ~8 M cycles between the two counters, and the two traces cannot be placed on one
# axis. AFTER, both counters free-run from a common reset and the skew collapses to the
# barrier's own release latency. See fpga/pynq-z2/docs/TACIT_MULTICORE.md.
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin       the traced guest
#   console.txt                   what the SoC printed, including TACIT_HART/TACIT_TIME
#   boot.log                      the PS-side bring-up transcript
#   hart0/, hart1/                tacit.out, trace.txt, trace.perfetto.json per hart
#   trace.merged.perfetto.json    BOTH harts in one file, a named track each -- open this
#   run.json                      manifest, checked against expected/tacit_smp.json
#
# The board is shared. Run this under the lock:
#   scripts/with_board.sh ./scripts/26_rocket_tacit_smp.sh
#   scripts/with_board.sh ./scripts/26_rocket_tacit_smp.sh --no-bitstream
#   scripts/with_board.sh ./scripts/26_rocket_tacit_smp.sh --bit PATH --name X --no-expect
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$IISWC_ROOT/samples/tacit_smp"
NAME="rocket_tacit_smp"
BOARD="chipyard_pynqz1_smp"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_smp_z1/pynqz1_rocket_smp.bit"
LOAD_BIT=1
SECONDS_READ=60
EXPECT=""
NO_EXPECT=0
# Rocket's ExtMem base and where the FPGA top folds it into PS physical memory, from
# src/pynqz2_rocket_top.v: {4'd1, addr[27:0]}.
ROCKET_MEM_BASE=$((0x80000000))
PS_MEM_BASE=$((0x10000000))
# The function samples/tacit_smp calls once per hart, immediately after the barrier.
MARKER=tacit_sync_marker

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
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"
need_exec "$TACIT_DECODER" "run scripts/05_build_tacit_tools.sh, or export TACIT_DECODER"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; BUILD="$RUN/build"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/7  build  ($BOARD)"
info "sample: $SAMPLE"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- -DBOARD_ROOT="$IISWC_ROOT" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"

# The other half of the mistake the MAGIC guards against: a single-hart image on a
# dual-core PL traces one hart and proves nothing about a common timeline.
NCPU=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${NCPU:-1}" -ge 2 ] || die "CONFIG_MP_MAX_NUM_CPUS=$NCPU -- this image would trace one hart"
grep -q '^CONFIG_SMP=y' "$BUILD/zephyr/.config" || die "CONFIG_SMP is not enabled in this image"

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
info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")   cpus: $NCPU"
info "marker: $MARKER at $MARKER_ADDR, $((MARKER_SIZE)) bytes"

step "2/7  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_smp.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "3/7  load the dual-core PL and hold the SoC in reset"
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
  if grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the SINGLE-core bitstream is loaded (MAGIC 0x5A5A0002). Only one hart would
       trace, and a single trace has nothing to be synchronised against. Re-run without
       --no-bitstream, or load $BIT."
  fi
  if grep -q 'MAGIC = 0x5A5A0001' "$RUN/boot.log"; then
    cat "$RUN/boot.log"; die "the DRAM self-test bitstream is loaded (MAGIC 0x5A5A0001)."
  fi
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_smp.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_smp.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0003' "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "dual-core bitstream not reachable over GP0"
}
info "dual-core PL loaded, SoC held in reset"

step "4/7  boot both harts and capture the console"
# The console reader starts BEFORE the core: the SiFive UART's TX FIFO is 8 bytes deep.
# It stops the moment TACIT_SMP_DONE lands rather than holding the board for the timeout.
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_smp.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
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
grep -q '^TACIT_SMP_FAIL' "$RUN/console.txt" &&
  die "guest reported: $(grep -m1 '^TACIT_SMP_FAIL' "$RUN/console.txt")"
grep -q '^TACIT_SMP_DONE' "$RUN/console.txt" ||
  die "no TACIT_SMP_DONE line -- the run did not complete; see $RUN/console.txt"

# One TACIT_HART line per hart: idx, cpu, hart, buffer address, byte count.
mapfile -t HART_LINES < <(grep '^TACIT_HART ' "$RUN/console.txt")
[ "${#HART_LINES[@]}" -eq 2 ] || die "expected 2 TACIT_HART lines, got ${#HART_LINES[@]}"

step "5/7  drain both buffers over /dev/mem"
HARTS=(); ADDRS=(); BYTES=()
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
  HARTS+=("$h"); ADDRS+=("$a"); BYTES+=("$n")
done

step "6/7  decode both traces into one timeline"
# --encoder rtl: the hardware encoder's sync and trap packets carry neither the privilege
# byte nor the context varint that spike's trace_encoder_l emits. See
# fpga/pynq-z2/docs/TACIT_ON_FPGA.md.
#
# ONE decoder run, not two. `--trace FILE:HART:LABEL` (patches/0010) decodes every hart in
# a single pass and writes BOTH the per-hart trace.txt / trace.perfetto.json, next to each
# tacit.out where they have always been, AND trace.merged.perfetto.json -- one file, one
# named Perfetto track per hart, which is what ui.perfetto.dev needs to draw the two harts
# on one axis without the reader merging JSON by hand.
#
# THE LABELS COME FROM HERE, not from the decoder. Which hart is the big one is a property
# of PynqZ2RocketBigLittleTacitConfig (`WithNSmallCores(1) ++ WithNBigCores(1)` -> big is
# tileId 0, and it is the boot hart); the decoder has no way to know that and does not
# guess. See fpga/pynq-z2/docs/DUAL_CORE.md section 3.
#
# THE MERGE ASSUMES ONE TIMEBASE. Nothing rescales a timestamp: the merged file carries
# the same raw mcycle values the per-hart files carry, which is only meaningful because
# patches/0004 makes both harts' mcycle free-run. On an unpatched bitstream the two tracks
# come out ~8.9 M cycles apart and the skew check below is what catches it.
MERGED="$RUN/trace.merged.perfetto.json"
DEC_ARGS=(); LABELS=()
for h in "${HARTS[@]}"; do
  if [ "$h" -eq 0 ]; then lbl="hart $h (big)"; else lbl="hart $h (LITTLE)"; fi
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
info "merged: $MERGED"

step "7/7  correlate: the same barrier, in both traces"
python3 - "$RUN" "$SAMPLE" "$BOARD" "$MARKER" "$MARKER_ADDR" "$MARKER_SIZE" \
         "$IISWC_ROOT" "$ZCS" "${HARTS[0]}" "${HARTS[1]}" "${LABELS[0]}" "${LABELS[1]}" <<'PY'
import datetime, json, os, re, subprocess, sys

run, sample, board, marker, m_addr, m_size, root, zcs, h0, h1, l0, l1 = sys.argv[1:13]
m_lo = int(m_addr, 16)
m_hi = m_lo + int(m_size, 16)
harts = [int(h0), int(h1)]
labels = {int(h0): l0, int(h1): l1}


def rev(p):
    try:
        return subprocess.run(["git", "-C", p, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip() or None
    except Exception:
        return None


def marker_ts_perfetto(path):
    """Timestamp of the marker's Begin slice.

    The decoder stamps a Begin slice with the timestamp of the packet that reported the
    jump INTO the function -- i.e. the cycle the call executed. That is the quantity we
    want: the barrier instant on this hart's mcycle.
    """
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
    """Independent read of the same instant, straight out of the decoded instruction
    stream: the first instruction that falls inside the marker's address range, and the
    timestamp of the packet immediately before it.

    This does not go through the decoder's slice/symbol machinery at all, so it catches a
    marker that was found by name but attributed to the wrong packet.
    """
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

# What the guest reported from software, per hart: the same barrier, timed with rdcycle.
sw = {}
for m in re.finditer(r'^TACIT_TIME idx=(\d+) hart=(\d+) c_rv0=(\d+) c_rv1=(\d+) '
                     r'c_rv2=(\d+) c_marker=(\d+) t_rv0=(\d+) t_rv1=(\d+) t_rv2=(\d+)',
                     text, re.M):
    sw[int(m.group(2))] = dict(idx=int(m.group(1)), c_rv0=int(m.group(3)),
                               c_rv1=int(m.group(4)), c_rv2=int(m.group(5)),
                               c_marker=int(m.group(6)), t_rv0=int(m.group(7)),
                               t_rv1=int(m.group(8)), t_rv2=int(m.group(9)))

per_hart = {}
for h in harts:
    d = os.path.join(run, f"hart{h}")
    log = open(os.path.join(d, "decode.log")).read() if os.path.exists(os.path.join(d, "decode.log")) else ""
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

# The two methods measure the same instant by different routes -- one through the
# decoder's symbol resolution, one through the raw instruction stream and the guest's own
# rdcycle. Disagreement means one of them is reading the wrong event, and is the single
# most useful thing to notice here.
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

print(f"    marker: {marker} at {m_addr}")
for h in harts:
    p = per_hart[h]
    print(f"    hart {h}: trace [{p['trace_first_ts']} .. {p['trace_last_ts']}]  "
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
if merged_span:
    print(f"      one axis: {merged_span[0]} .. {merged_span[1]}  "
          f"({merged_span[1] - merged_span[0]} cycles wide), "
          f"skew from the merged file {merged_skew}")
print(f"      merged agrees with the per-hart files: {merged_matches}")

json.dump({
    "name": os.path.basename(run),
    "generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "sample": sample,
    "board": board,
    "source": "fpga",
    "marker": {"symbol": marker, "addr": m_addr, "size": m_size},
    "console_lines": lines,
    "pins": {
        "zephyr-chipyard-sw": rev(zcs),
        "tacit-decoder": rev(os.path.join(root, "third_party", "tacit-decoder")),
    },
    "per_hart": per_hart,
    "merged": merged,
    # The golden check compares the fields below. Absolute timestamps and byte counts are
    # deliberately NOT among them: the encoder stamps every packet with a delta in core
    # cycles, so a DRAM refresh or a differently-timed interrupt moves both. What is
    # checked is that both harts traced, that the marker was found exactly once in each,
    # that the two independent readings of the skew agree, and the ORDER OF MAGNITUDE of
    # the skew -- which is the whole point.
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
        # per hart carrying the caller's label in both process_name and thread_name, and
        # every hart's marker sits at the same cycle it does in that hart's own file.
        "merged_trace_written": merged["exists"] and merged["events"] > 0,
        "merged_harts": merged_harts,
        "merged_tracks_named": merged_named,
        "merged_matches_per_hart": merged_matches,
    },
    "measured": {
        "trace_skew_cycles": trace_skew,
        "trace_skew_cycles_txt": trace_skew_txt,
        "sw_skew_r0_cycles": sw_skew_r0,
        "sw_skew_r1_cycles": sw_skew_r1,
        "sw_skew_r2_cycles": sw_skew_r2,
        "idle_differential_cost_cycles": idle_cost,
        "elf_bytes": os.path.getsize(os.path.join(run, "zephyr.elf")),
        "merged_events": merged["events"],
        "merged_trace_skew_cycles": merged_skew,
        "merged_span_cycles": merged_span,
        "merged_span_width_cycles": (merged_span[1] - merged_span[0]) if merged_span else None,
    },
}, open(os.path.join(run, "run.json"), "w"), indent=2)
PY

python3 -c "
import json,sys
d=json.load(open('$RUN/run.json'))
json.dump({'results':d['results'],'measured':d['measured']},sys.stdout,indent=2)
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
    print(f"    {'ok  ' if ok else 'FAIL'}  {k:<28} expected {shown!s:>18}   got {have!s:>12}")
sys.exit(1 if bad else 0)
PYCHECK
  then printf '    \033[1;32mPASS\033[0m  both harts traced, and the barrier lands at the same timestamp in both\n'
  else printf '    \033[1;31mFAIL\033[0m  output differs from expected/ -- see the table above\n'; exit 1
  fi
else
  info "no golden file at $EXPECT -- skipping check"
fi

step "Done"
info "open  $MERGED  at https://ui.perfetto.dev -- both harts, one axis, a named track each"
info "the per-hart files are still there: $RUN/hart0/trace.perfetto.json, $RUN/hart1/trace.perfetto.json"
