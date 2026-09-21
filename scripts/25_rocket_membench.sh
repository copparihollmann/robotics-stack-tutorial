#!/usr/bin/env bash
# Lab B4 -- characterise the memory hierarchy of the dual-core big.LITTLE Rocket on the
# physical PYNQ-Z1: bandwidth and load-to-use latency at L1D, L2 and DRAM-through-the-shim,
# per hart, and with both harts streaming at once.
#
#   west build (chipyard_pynqz1_smp)  ->  scp zephyr.bin  ->  PS writes DDR
#   ->  release reset  ->  pulse custom_boot  ->  both harts measure  ->  /dev/ttyPS1
#
# Same shape as 22_rocket_smp_run.sh, which it deliberately does not modify. The board
# handling is identical -- same dual-core bitstream, same MAGIC guard, same reset/boot
# sequence. What is different is what happens after the boot, and what is checked:
#
#   * a longer console window       the sweep takes minutes, not seconds, so the reader
#                                   waits for MEMBENCH_DONE and stops the moment it lands
#                                   rather than holding the board for a fixed timeout
#   * ELF gates before the board    soft-float ABI and no f/d in Tag_RISCV_arch, because
#                                   this core is rv64imac and a single emulated float in
#                                   an inner loop would make every number below wrong
#   * inner_loops.txt               the three measurement loops, disassembled out of the
#                                   built ELF, so the numbers can be traced to instructions
#   * a golden check on SHAPE       plateau ratios and cache-boundary positions, not raw
#                                   MB/s -- see expected/membench.json for why
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin   the guest
#   console.txt               what the SoC printed
#   inner_loops.txt           mb_read / mb_write / mb_chase, disassembled
#   boot.log                  the PS-side bring-up transcript
#   table.txt                 the measured hierarchy, formatted
#   run.json                  manifest: every measurement, plus the derived shape
#
# Usage:
#   scripts/with_board.sh ./scripts/25_rocket_membench.sh
#   scripts/with_board.sh ./scripts/25_rocket_membench.sh --no-bitstream
#   scripts/with_board.sh ./scripts/25_rocket_membench.sh --name membench_b --no-expect
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$IISWC_ROOT/samples/membench"
NAME="rocket_membench"
BOARD="chipyard_pynqz1_smp"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_smp_z1/pynqz1_rocket_smp.bit"
LOAD_BIT=1
SECONDS_READ=600
EXPECT=""
NO_EXPECT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --expect) EXPECT="${2:?}"; shift 2 ;;
    --no-expect) NO_EXPECT=1; shift ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; BUILD="$RUN/build"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/6  build  ($BOARD)"
info "sample: $SAMPLE"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- -DBOARD_ROOT="$IISWC_ROOT" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"

step "2/6  gate the image before the board sees it"
# Two harts, or "hart 1 alone" and "both harts" are the same measurement twice.
NCPU=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${NCPU:-1}" -ge 2 ] || die "CONFIG_MP_MAX_NUM_CPUS=$NCPU -- this image would run on one hart"
grep -q '^CONFIG_SMP=y' "$BUILD/zephyr/.config" || die "CONFIG_SMP is not enabled in this image"
grep -q '^CONFIG_SCHED_CPU_MASK=y' "$BUILD/zephyr/.config" \
  || die "CONFIG_SCHED_CPU_MASK=n -- k_thread_cpu_pin() would fail and nothing would be per-hart"
# -O2 at minimum: a benchmark built -Os measures a smaller loop, not the memory.
grep -q '^CONFIG_SPEED_OPTIMIZATIONS=y' "$BUILD/zephyr/.config" \
  || die "CONFIG_SPEED_OPTIMIZATIONS=n -- build this sample at -O2 or better"

# The core is rv64imac. A soft-float ABI is not a preference here: one float in an inner
# loop pulls in __adddf3 and the loop stops being a memory measurement.
RE="$(dirname "$(command -v riscv64-zephyr-elf-objdump)")/riscv64-zephyr-elf-readelf"
[ -x "$RE" ] || RE=riscv64-zephyr-elf-readelf
command -v "$RE" >/dev/null 2>&1 || die "riscv64-zephyr-elf-readelf not on PATH -- source env.sh"
ARCH=$("$RE" -A "$RUN/zephyr.elf" | sed -n 's/.*Tag_RISCV_arch: "\(.*\)"/\1/p')
FLAGS=$("$RE" -h "$RUN/zephyr.elf" | sed -n 's/^ *Flags: *//p')
case "$FLAGS" in *soft-float*) ;; *) die "ELF is not soft-float ABI: $FLAGS" ;; esac
case "$ARCH" in
  *_f[0-9]*|*_d[0-9]*|*_v[0-9]*) die "Tag_RISCV_arch has an FP/vector extension: $ARCH" ;;
esac
info "abi:  $FLAGS"
info "arch: $ARCH"

# The three inner loops, out of the ELF rather than out of the source, so the table in
# MEMORY_HIERARCHY.md can be traced to what actually executed.
riscv64-zephyr-elf-objdump -d --no-show-raw-insn "$RUN/zephyr.elf" \
  | awk '/<mb_read>:/{f=1} /<mb_chase>:/{g=1} f{print} g&&/[ \t]ret$/{exit}' \
  > "$RUN/inner_loops.txt" || true
# 32 loads per 256-byte iteration is the whole design of mb_read: it is what puts the
# L1-resident ceiling at 7.53 B/cycle instead of the 3.8 a summing loop would allow.
LD_PER_ITER=$(awk '/<mb_read>:/{f=1} f&&/bltu/{exit} f&&$2=="ld"{n++} END{print n+0}' \
  "$RUN/inner_loops.txt")
[ "${LD_PER_ITER:-0}" -eq 32 ] || warn "mb_read has $LD_PER_ITER loads per iteration, expected 32"
info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")   cpus: $NCPU"
info "mb_read inner loop: $LD_PER_ITER x ld per 256 B  ->  $RUN/inner_loops.txt"

step "3/6  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_smp.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "4/6  load the PL and hold the SoC in reset"
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
    die "the SINGLE-core bitstream is loaded (MAGIC 0x5A5A0002). Every 'both harts'
       number would be a single-hart number. Re-run without --no-bitstream."
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

step "5/6  run the sweep and capture the console"
info "this takes a few minutes; the reader stops as soon as MEMBENCH_DONE appears"
# The console reader must be listening BEFORE the core starts: the SiFive UART's TX FIFO
# is only 8 bytes deep, so a late reader loses the banner. It is torn down on the sentinel
# rather than on a fixed timeout, so the board lock is released as early as possible.
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_smp.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  for i in \$(seq 1 $SECONDS_READ); do
    grep -q MEMBENCH_DONE console.out 2>/dev/null && break
    sleep 1
  done
  sleep 1
  kill \$CPID 2>/dev/null || true
  wait \$CPID 2>/dev/null || true
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true

[ -s "$RUN/console.txt" ] || { warn "no console output -- check $RUN/boot.log"; }
grep -q '\*\*\* Booting Zephyr OS' "$RUN/console.txt" 2>/dev/null \
  || { tail -20 "$RUN/boot.log"; die "the SoC did not boot; see $RUN/boot.log"; }

step "6/6  analyse"
python3 - "$RUN" "$SAMPLE" "$BOARD" <<'PY'
import hashlib, json, os, re, sys

run, sample, board = sys.argv[1:4]

def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest() if os.path.exists(p) else None

text = open(os.path.join(run, 'console.txt')).read()
lines = text.splitlines()

def kvs(line):
    return dict(re.findall(r'(\w+)=(-?[\w.]+)', line))

bw, lat, chk = [], [], {}
for ln in lines:
    if ln.startswith('BW '):
        d = kvs(ln)
        bw.append(dict(phase=d['p'], hart=int(d['h']), op=d['op'], size=int(d['sz']),
                       reps=int(d['n']), mbps=int(d['mbps100']) / 100.0,
                       mbps_lo=int(d['lo']) / 100.0, mbps_hi=int(d['hi']) / 100.0,
                       bytes_per_cycle=int(d['bpc1000']) / 1000.0,
                       passes=int(d['pass']), overlap_pct=int(d.get('ovl', 0))))
    elif ln.startswith('LAT '):
        d = kvs(ln)
        lat.append(dict(phase=d['p'], hart=int(d['h']), size=int(d['sz']),
                        reps=int(d['n']), cycles=int(d['cyc100']) / 100.0,
                        cycles_lo=int(d['lo']) / 100.0, cycles_hi=int(d['hi']) / 100.0,
                        overlap_pct=int(d.get('ovl', 0)), cycle_ok=d['cycle_ok'] == '1'))
    elif ln.startswith('CHK '):
        parts = ln.split(None, 2)
        chk.setdefault(parts[1], []).append(kvs(parts[2]) if len(parts) > 2 else {})

def one(tag, key, cast=str, default=None):
    v = chk.get(tag)
    if not v or key not in v[0]:
        return default
    try:
        return cast(v[0][key])
    except ValueError:
        return default

def pick(rows, **sel):
    return [r for r in rows if all(r[k] == v for k, v in sel.items())]

def curve(phase, hart, op):
    rows = sorted(pick(bw, phase=phase, hart=hart, op=op), key=lambda r: r['size'])
    return [(r['size'], r['mbps']) for r in rows]

def latcurve(phase, hart):
    rows = sorted(pick(lat, phase=phase, hart=hart), key=lambda r: r['size'])
    return [(r['size'], r['cycles']) for r in rows]

def at(c, size):
    for s, v in c:
        if s == size:
            return v
    return None

# ---- where the cliffs are ------------------------------------------------------------
# A "drop" is a size at which read bandwidth falls to less than 75% of the previous size
# in the sweep. That is a statement about the SHAPE of the curve, which is a property of
# the cache geometry, and it does not move when DRAM refresh or the Linux-side ARM cores
# shift the absolute MB/s by a few percent.
def drops(c, frac=0.75):
    out = []
    for i in range(1, len(c)):
        if c[i - 1][1] > 0 and c[i][1] < frac * c[i - 1][1]:
            out.append(c[i][0])
    return out

derived = {}
for hart, ph in ((0, 'solo0'), (1, 'solo1')):
    cr = curve(ph, hart, 'rd')
    cw = curve(ph, hart, 'wr')
    cl = latcurve(ph, hart)
    derived[f'read_drops_hart{hart}'] = drops(cr)
    derived[f'write_drops_hart{hart}'] = drops(cw)
    derived[f'read_mbps_hart{hart}'] = {str(s): v for s, v in cr}
    derived[f'write_mbps_hart{hart}'] = {str(s): v for s, v in cw}
    derived[f'latency_cycles_hart{hart}'] = {str(s): v for s, v in cl}
    # Plateau probes: one size firmly inside each level, and their ratios.
    #
    #   L1   4 KiB   resident in BOTH L1Ds (hart 0 has 16 KiB, hart 1 only 4 KiB). The
    #                2 KiB point is not used as the L1 probe: at 2 KiB the chunk is a
    #                whole traversal, so one serialising rdcycle and one cursor update
    #                fall on only 32 cache lines and cost several percent.
    #   L2   32 KiB  past hart 1's L1 and half of hart 0's, comfortably inside the 64 KiB
    #                L2. 64 KiB is deliberately avoided: a working set that exactly fills
    #                a 4-way cache is a knife edge, and it is where the contention result
    #                lives.
    #   DRAM 16 MiB  256x the L2 and 8x hart 0's TLB reach.
    l1, l2, dr = at(cr, 4096), at(cr, 32768), at(cr, 16 * 1024 * 1024)
    if l1 and dr:
        derived[f'ratio_l1_over_dram_hart{hart}'] = round(l1 / dr, 2)
    if l2 and dr:
        derived[f'ratio_l2_over_dram_hart{hart}'] = round(l2 / dr, 2)
    wl1, wdr = at(cw, 4096), at(cw, 16 * 1024 * 1024)
    if wl1 and wdr:
        derived[f'ratio_wr_l1_over_dram_hart{hart}'] = round(wl1 / wdr, 2)
    rdr = at(cr, 16 * 1024 * 1024)
    if rdr and wdr:
        derived[f'ratio_dram_read_over_write_hart{hart}'] = round(rdr / wdr, 2)

    # Per-level load-to-use, straight off the chase curve.
    for name, sz in (('l1', 2048), ('l2', 32768), ('dram', 4 * 1024 * 1024)):
        v = at(cl, sz)
        if v:
            derived[f'{name}_latency_cycles_hart{hart}'] = v

    # HOW MANY MISSES THIS HART CAN HAVE IN FLIGHT AT ONCE.
    #
    # A streaming read of DRAM costs (cycles per 64-byte line); of the 8 loads that cover
    # a line, 1 misses and 7 hit in the L1 at ~1 cycle each. So
    #
    #     line_cycles  ~=  miss_latency / concurrency  +  7
    #
    # and the pointer chase measures miss_latency directly. Solving for concurrency turns
    # two independent measurements into a number for something that is otherwise only
    # readable out of the RTL: how many outstanding line fills the L1D supports.
    row = [r for r in bw if r['phase'] == ph and r['hart'] == hart
           and r['op'] == 'rd' and r['size'] == 16 * 1024 * 1024]
    dlat = derived.get(f'dram_latency_cycles_hart{hart}')
    if row and dlat and row[0]['bytes_per_cycle'] > 0:
        line_cycles = 64.0 / row[0]['bytes_per_cycle']
        derived[f'dram_line_cycles_hart{hart}'] = round(line_cycles, 2)
        if line_cycles > 7.5:
            derived[f'outstanding_misses_hart{hart}'] = round(dlat / (line_cycles - 7), 2)

# ---- contention ----------------------------------------------------------------------
cont = {}
for op in ('rd', 'wr'):
    for size in sorted({r['size'] for r in bw}):
        s0 = at(curve('solo0', 0, op), size)
        s1 = at(curve('solo1', 1, op), size)
        b0 = at(curve('both', 0, op), size)
        b1 = at(curve('both', 1, op), size)
        if None in (s0, s1, b0, b1):
            continue
        cont[f'{op}_{size}'] = dict(
            solo_hart0=s0, solo_hart1=s1, both_hart0=b0, both_hart1=b1,
            solo_sum=round(s0 + s1, 2), both_sum=round(b0 + b1, 2),
            scaling=round((b0 + b1) / max(s0, s1), 3),       # vs the faster hart alone
            efficiency=round((b0 + b1) / (s0 + s1), 3),      # vs both alone, added up
            hart0_retained=round(b0 / s0, 3), hart1_retained=round(b1 / s1, 3))
derived['contention'] = cont
# The two contention results worth naming: DRAM, where the harts share a link that neither
# can saturate, and 64 KiB, where they share a CAPACITY that together they overflow.
for tag, key in (('dram', 'rd_16777216'), ('l2_edge', 'rd_65536'),
                 ('dram_write', 'wr_16777216')):
    c = cont.get(key)
    if c:
        derived[f'contention_{tag}_efficiency'] = c['efficiency']
        derived[f'contention_{tag}_aggregate_mbps'] = c['both_sum']
        derived[f'contention_{tag}_hart1_retained'] = c['hart1_retained']

# ---- gates ---------------------------------------------------------------------------
peak_bpc = max([r['bytes_per_cycle'] for r in bw], default=0.0)
core_hz = one('clock', 'measured_hz', int)
nominal_hz = one('clock', 'nominal_hz', int)
flush = {d['tag']: d for d in chk.get('flush', []) if 'tag' in d}
phases = {d['p']: d for d in chk.get('phase', []) if 'p' in d}
dram_rows = [r for r in bw if r['size'] >= 4 * 1024 * 1024]

results = {
    'booted': '*** Booting Zephyr OS' in text,
    'completed': 'MEMBENCH_DONE' in text,
    'result_pass': 'RESULT: PASS' in text,
    'harts_observed': sorted({r['hart'] for r in bw}),
    'phases_observed': sorted({r['phase'] for r in bw}),
    'bw_points': len(bw),
    'lat_points': len(lat),
    'l2_banks': one('l2cfg', 'banks', int),
    'l2_ways': one('l2cfg', 'ways', int),
    'l2_lg_sets': one('l2cfg', 'lgSets', int),
    'l2_block': one('l2cfg', 'block', int),
    'core_clock_mhz': round(core_hz / 1e6) if core_hz else None,
    'core_clock_matches_nominal': bool(
        core_hz and nominal_hz and abs(core_hz - nominal_hz) < 0.01 * nominal_hz),
    'ceiling_violations': one('ceiling', 'violations', int),
    'peak_bytes_per_cycle_ok': peak_bpc <= 8.0,
    # Nothing through the AXI shim may exceed the 64-bit-at-40-MHz link: 320 MB/s.
    'dram_under_link_ceiling': all(r['mbps'] <= 320.0 for r in dram_rows),
    'chase_cycles_valid': all(r['cycle_ok'] for r in lat) and len(lat) > 0,
    # The flush must be doing something: a cold pass has to be measurably slower than the
    # warm pass right behind it, or every plateau in the sweep is measuring warm caches.
    'flush_effective_l2fit': int(flush.get('l2fit', {}).get('ratio100', 0)) >= 150,
    'flush_effective_l1fit': int(flush.get('l1fit', {}).get('ratio100', 0)) >= 150,
    # "Both harts ran" is not "both harts were hammering memory at the same instant". Two
    # independent witnesses: the per-measurement sampling of the partner's traffic flag
    # from inside each timed region, and the two workers' windows on the shared mtime
    # counter. A contention number taken without both of these means nothing -- the first
    # version of this benchmark wrapped its windows in irq_lock(), which under CONFIG_SMP
    # is a GLOBAL spinlock, and reported 100% scaling because the two harts were taking
    # turns rather than contending.
    'contention_overlapped': all(
        r['overlap_pct'] >= 90 for r in bw + lat if r['phase'] == 'both'),
    'contention_phase_overlap_pct': int(phases.get('both', {}).get('pct', 0)),
}
results.update({k: v for k, v in derived.items()
                if k.startswith(('read_drops', 'write_drops', 'ratio_',
                                 'outstanding_misses_', 'contention_dram',
                                 'contention_l2_edge'))})

json.dump({
    'board': board,
    'sample': sample,
    'bin_md5': md5(os.path.join(run, 'zephyr.bin')),
    'elf_md5': md5(os.path.join(run, 'zephyr.elf')),
    'clock': {'source': 'rdcycle', 'nominal_hz': nominal_hz, 'measured_hz': core_hz,
              'mtime_hz': one('clock', 'mtime_hz', int)},
    'config': (chk.get('window') or [{}])[0],
    'layout': (chk.get('layout') or [{}])[0],
    'flush': {'cost': (chk.get('flushcost') or [{}])[0], 'checks': flush},
    'phase_windows': phases,
    'bandwidth': bw,
    'latency': lat,
    'derived': derived,
    'console_lines': len(lines),
    'results': results,
}, open(os.path.join(run, 'run.json'), 'w'), indent=2)

# ---- a table a human can read --------------------------------------------------------
out = []
KB = 1024
def fmt(n):
    return f'{n // (1 << 20)}M' if n >= (1 << 20) else f'{n // KB}K'

sizes = sorted({r['size'] for r in bw})
out.append(f"clock: rdcycle @ {core_hz/1e6:.3f} MHz measured "
           f"({nominal_hz/1e6:.0f} MHz nominal), 1 tick = {1e9/core_hz:.2f} ns"
           if core_hz else "clock: unknown")
out.append(f"L2 config register: banks={results['l2_banks']} ways={results['l2_ways']} "
           f"lgSets={results['l2_lg_sets']} block={results['l2_block']}")
out.append("")
out.append("read / write bandwidth, MB/s (median of n reps, min-max in brackets)")
out.append(f"{'size':>6}  {'h0 read':>19} {'h0 write':>19} {'h1 read':>19} {'h1 write':>19}")
for s in sizes:
    cells = []
    for hart, ph in ((0, 'solo0'), (1, 'solo1')):
        for op in ('rd', 'wr'):
            r = pick(bw, phase=ph, hart=hart, op=op, size=s)
            cells.append(f"{r[0]['mbps']:7.1f} [{r[0]['mbps_lo']:5.1f}-{r[0]['mbps_hi']:5.1f}]"
                         if r else ' ' * 19)
    out.append(f"{fmt(s):>6}  " + ' '.join(cells))
out.append("")
out.append("pointer-chase load-to-use latency, core cycles/step (and ns at 40 MHz)")
out.append(f"{'size':>6}  {'hart 0':>20}  {'hart 1':>20}  {'h0 contended':>14}  {'h1 contended':>14}")
for s in sorted({r['size'] for r in lat}):
    def cell(ph, h, w=20):
        r = pick(lat, phase=ph, hart=h, size=s)
        if not r:
            return ' ' * w
        c = r[0]['cycles']
        return f"{c:8.2f} ({c*25:6.0f} ns)" if w == 20 else f"{c:14.2f}"
    out.append(f"{fmt(s):>6}  {cell('solo0',0)}  {cell('solo1',1)}  "
               f"{cell('both',0,14)}  {cell('both',1,14)}")
out.append("")
out.append("contention: both harts streaming the same size at once")
out.append("phase windows on the shared mtime counter: " +
           ' | '.join(f"{k}: {v.get('pct', v.get('dur', '?'))}" for k, v in phases.items()))
out.append("(ovl = %% of each timed window the partner was also loading the memory system)")
out.append(f"{'size':>6} {'op':>3}  {'h0 solo':>8} {'h1 solo':>8} {'h0 both':>8} "
           f"{'h1 both':>8} {'sum both':>9} {'vs sum solo':>11} {'ovl':>5}")
for key, c in cont.items():
    op, sz = key.split('_')
    ovl = [r['overlap_pct'] for r in bw
           if r['phase'] == 'both' and r['op'] == op and r['size'] == int(sz)]
    out.append(f"{fmt(int(sz)):>6} {op:>3}  {c['solo_hart0']:8.1f} {c['solo_hart1']:8.1f} "
               f"{c['both_hart0']:8.1f} {c['both_hart1']:8.1f} {c['both_sum']:9.1f} "
               f"{c['efficiency']*100:10.0f}% {min(ovl) if ovl else 0:4d}%")
open(os.path.join(run, 'table.txt'), 'w').write('\n'.join(out) + '\n')
print('\n'.join(out))
print(f"\n    manifest: {os.path.join(run, 'run.json')}")
print(f"    table:    {os.path.join(run, 'table.txt')}")
PY

[ -n "$EXPECT" ] || EXPECT="$IISWC_ROOT/expected/$(basename "$SAMPLE").json"
if [ "$NO_EXPECT" -eq 1 ]; then
  warn "--no-expect: golden check skipped"
elif [ -f "$EXPECT" ]; then
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
    # Ratios move by a few percent between runs (DRAM refresh, and two ARM cores running
    # Linux on the other half of the same DDR controller), so they carry a tolerance.
    # Booleans, cache geometry and boundary positions are compared exactly.
    if isinstance(want, dict) and "within" in want:
        lo, hi = want["value"] * (1 - want["within"]), want["value"] * (1 + want["within"])
        ok = isinstance(have, (int, float)) and lo <= have <= hi
        shown = f"{want['value']} +/-{want['within']*100:g}%"
    else:
        ok = have == want
        shown = want
    if not ok:
        bad += 1
    print(f"    {'ok  ' if ok else 'FAIL'}  {k:<32} expected {shown!s:>22}   got {have!s:>18}")
sys.exit(1 if bad else 0)
PYCHECK
  then printf '    \033[1;32mPASS\033[0m  reproduces the golden hierarchy\n'
  else printf '    \033[1;31mFAIL\033[0m  differs from expected/ -- see the table above\n'; exit 1
  fi
else
  info "no golden file at $EXPECT -- skipping check"
fi

step "Done"
info "console: $RUN/console.txt"
info "table:   $RUN/table.txt"
