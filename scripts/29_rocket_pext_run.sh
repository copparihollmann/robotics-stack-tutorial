#!/usr/bin/env bash
# Lab B9 -- run the MBP packed-SIMD acceptance test on the FPGA:
#
#   west build (chipyard_pynqz1_pext)  ->  scp zephyr.bin  ->  PS writes DDR
#   ->  release reset  ->  pulse custom_boot  ->  hart 0 wakes hart 1  ->  /dev/ttyPS1
#
# Same shape as 22_rocket_smp_run.sh, which it deliberately does not modify. The
# differences are all consequences of the extension and of the clock it forced:
#
#   * a different bitstream          build_rocket_pext_z1/pynqz1_rocket_pext.bit
#   * a different MAGIC              0x5A5A0004, so a run against the plain dual-core PL
#                                    is refused rather than silently trapping later
#   * a different Zephyr board       chipyard_pynqz1_pext (34483 Hz mtime, not 40000)
#   * a different FCLK               34.4828 MHz, programmed by run_rocket_pext.py
#   * a stricter golden check        the manifest records that hart 0 COMPUTED and that
#                                    hart 1 TRAPPED, not just that something booted
#
# WHAT "PASS" MEANS HERE, and why each half is mandatory:
#
#   POSITIVE  hart 0 executes DOT8/MAX8/QMUL/CLIP8 and every result matches
#             fpga/pynq-z2/sw/pext.h byte for byte. That header is the frozen contract; if
#             the routed silicon disagrees with it, the silicon is wrong.
#   NEGATIVE  hart 1 executes the same four ENCODINGS and each one raises an
#             illegal-instruction exception (mcause=2) without writing rd. This is the
#             whole heterogeneity claim. A build that accidentally gave both tiles the
#             unit -- dropping .atTileIds(0) does exactly that, and it elaborates, routes
#             and boots -- would pass every other check in this file.
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin   the guest
#   console.txt               what the SoC printed
#   console.stamps            the same lines, timestamped on the HOST clock
#   boot.log                  the PS-side bring-up transcript, incl. the FCLK readback
#   run.json                  manifest, including the per-hart evidence and the clock
#
# Usage:
#   scripts/with_board.sh ./scripts/29_rocket_pext_run.sh
#   scripts/with_board.sh ./scripts/29_rocket_pext_run.sh --sample PATH --name X
#   scripts/with_board.sh ./scripts/29_rocket_pext_run.sh --no-bitstream
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$IISWC_ROOT/samples/pext_hart_proof"
NAME="rocket_pext"
BOARD="chipyard_pynqz1_pext"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_pext_z1/pynqz1_rocket_pext.bit"
LOAD_BIT=1
SECONDS_READ=30
# The clock this bitstream is TIMED at. Also the mtime rate x 1000 the board Kconfig
# carries, and the value run_rocket_pext.py programs. All three must agree.
WANT_MTIME_HZ=34483
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; BUILD="$RUN/build"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/5  build  ($BOARD)"
info "sample: $SAMPLE"
# BOARD_ROOT points at this repo: the board lives here, not in the west-managed zephyr
# checkout, so `west update` cannot clobber it.
run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- -DBOARD_ROOT="$IISWC_ROOT" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"

# Three things about the BUILT image, checked before the board is touched. Each of them
# fails in a way that would otherwise look like a hardware fault.
NCPU=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${NCPU:-1}" -ge 2 ] || die "CONFIG_MP_MAX_NUM_CPUS=$NCPU -- hart 1 would never run, and
       the negative test would pass by never executing anything"
grep -q '^CONFIG_SMP=y' "$BUILD/zephyr/.config" || die "CONFIG_SMP is not enabled in this image"
HZ=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${HZ:-0}" = "$WANT_MTIME_HZ" ] || die "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, expected
       $WANT_MTIME_HZ. That constant sets the SiFive UART's baud divisor as well as the
       tick rate, so a mismatch here shows up as a GARBLED console rather than a silent
       one -- see FPGA_END_TO_END.md 4.1."
info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")   cpus: $NCPU   mtime: $HZ Hz"

# The four MBP encodings must actually be in the image. A build that silently fell back to
# pext.h's software model would print PASS while executing no custom-0 instruction at all.
#
# Only enforced for a sample that is SUPPOSED to contain them. This runner also carries
# ordinary Zephyr apps onto this bitstream -- samples/smp_hart_proof is run on it to show
# the plain dual-core path still works -- and those legitimately have none.
case "$(basename "$SAMPLE")" in
  pext_*) WANT_INSN=4 ;;
  *)      WANT_INSN=0 ;;
esac
OBJDUMP="$(command -v riscv64-zephyr-elf-objdump || true)"
if [ -n "$OBJDUMP" ]; then
  "$OBJDUMP" -d "$RUN/zephyr.elf" > "$RUN/zephyr.dis"
  NINSN=$(grep -cE '^\s+[0-9a-f]+:\s+[0-9a-f]{8}\s+\.insn' "$RUN/zephyr.dis" || true)
  info "custom-0 .insn words in the image: $NINSN  (this sample needs >= $WANT_INSN)"
  [ "${NINSN:-0}" -ge "$WANT_INSN" ] || die "fewer than $WANT_INSN custom-0 instructions in
       the image -- did MB_PEXT_HW=1 take? See samples/pext_hart_proof/CMakeLists.txt."
else
  warn "no riscv64-zephyr-elf-objdump on PATH; skipping the encoding check"
fi

step "2/5  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_pext.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "3/5  load the PL, set FCLK0 and hold the SoC in reset"
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
# run_rocket_pext.py exits non-zero on a MAGIC mismatch, so diagnose that BEFORE retrying
# with a password -- otherwise the real cause is buried under a sudo fallback.
wrong_pl () {
  if grep -q 'MAGIC = 0x5A5A0003' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the plain DUAL-CORE bitstream is loaded (MAGIC 0x5A5A0003). It has no MBP unit on
       either hart, so hart 0 would trap on the first instruction and the negative test
       would 'pass' for the wrong reason. Re-run without --no-bitstream, or load
       fpga/pynq-z2/build_rocket_pext_z1/pynqz1_rocket_pext.bit."
  fi
  if grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the SINGLE-core bitstream is loaded (MAGIC 0x5A5A0002)."
  fi
  if grep -q 'MAGIC = 0x5A5A0001' "$RUN/boot.log"; then
    cat "$RUN/boot.log"; die "the DRAM self-test bitstream is loaded (MAGIC 0x5A5A0001)."
  fi
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_pext.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  # The board's sudo may still want a password; fall back rather than fail the run.
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_pext.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0004' "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "P-ext bitstream not reachable over GP0"
}
grep -E 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true
info "P-ext PL loaded, SoC held in reset"

step "4/5  boot both harts and capture the console"
# The console reader must be listening BEFORE the core starts: the SiFive UART's TX FIFO is
# only 8 bytes deep, so a late reader loses the banner. --stamps gives the host-clock
# timing that section 5 uses to check the guest's own idea of its clock.
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out console.stamps
  nohup python3 -u console.py --seconds $SECONDS_READ --stamps console.stamps > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_pext.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
"${SSH[@]}" "cat $PYNQ_DIR/console.stamps" > "$RUN/console.stamps" 2>/dev/null || true

step "5/5  result"
if [ -s "$RUN/console.txt" ]; then
  printf '%s\n' "----------------------------------------------------------------"
  cat "$RUN/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
else
  warn "no console output -- check $RUN/boot.log"
  grep -E 'STATUS|saw_mem' "$RUN/boot.log" | tail -6 || true
fi

python3 - "$RUN" "$SAMPLE" "$BOARD" "$WANT_MTIME_HZ" <<'PY'
import hashlib, json, os, re, sys
run, sample, board, want_hz = sys.argv[1:5]
want_hz = int(want_hz)

def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest() if os.path.exists(p) else None

text = ''
console = os.path.join(run, 'console.txt')
if os.path.exists(console):
    text = open(console).read()
lines = text.splitlines()

boot = ''
bootlog = os.path.join(run, 'boot.log')
if os.path.exists(bootlog):
    boot = open(bootlog).read()

# --- per-hart evidence, straight out of the console -------------------------------
# These are the HARDWARE's answers: mhartid and misa read from the CSRs, mcause read by a
# trap handler that only runs if a trap actually happened.
traps = re.findall(r'hart1 (\w+)\s+trapped: mcause=(\d+) mepc=(0x[0-9a-f]+) '
                   r'mtval=(0x[0-9a-f]+) rd=(0x[0-9a-f]+)', text)
executed = re.findall(r'hart0 (\w+)\s+executed: rd=(0x[0-9a-f]+)', text)
checks = dict(re.findall(r'(\w+)=([01])\b',
                         next((l for l in lines if l.startswith('CHECKS')), '')))
total = re.search(r'TOTAL (\d+) checks, (\d+) failures', text)
misa = re.findall(r'hart (\d) \((?:BIG|LITTLE)\)\s+misa = (0x[0-9a-f]+)\s+"([^"]+)"', text)

# --- samples/smp_hart_proof's own evidence, when THAT is the sample -----------------
# This runner drives any Zephyr app on this bitstream, and requirement 3 of the P-ext
# bring-up is that the plain dual-core SMP path still works on it. Extracting these here
# means `--sample samples/smp_hart_proof` checks against the EXISTING
# expected/smp_hart_proof.json rather than needing a second golden file -- and a golden
# file written for the 40 MHz dual-core bitstream passing unchanged on the 34.4828 MHz
# P-ext one is exactly the statement worth making.
# Both spellings: smp_hart_proof prints "mhartid = N", pext_hart_proof prints
# "cpu N / mhartid N". Both are the mhartid CSR read on a pinned worker, which is what
# this field means -- the set of harts the HARDWARE said it was running on.
harts_observed = sorted({int(m) for m in re.findall(r'mhartid\s*=?\s*(\d+)', text)})
smp_checks = dict(re.findall(r'(\w+)=([01])\b',
                             next((l for l in lines if l.startswith('CHECKS')), '')))

# --- the clock, three independent ways --------------------------------------------
# 1. what the PS programmed and read back out of the SLCR (outside the SoC entirely)
m = re.search(r'FCLK0_HZ = (\d+)', boot)
fclk_hz = int(m.group(1)) if m else None
# 2. the guest's mcycle-per-mtime-tick ratio -- the hardware divider, a pure integer
m = re.search(r'CLOCK_MCYCLES=(\d+) CLOCK_MTICKS=(\d+)', text)
mcycles, mticks = (int(m.group(1)), int(m.group(2))) if m else (None, None)
divider = round(mcycles / mticks) if (mcycles and mticks) else None
# 3. how long the guest's self-declared interval took on the HOST clock. This is the only
#    one that does not assume CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC, so it is the one that
#    can catch that constant being wrong.
probe_ms = None
wall_ms = None
stamps = os.path.join(run, 'console.stamps')
if os.path.exists(stamps):
    t_start = t_end = None
    for ln in open(stamps):
        try:
            t, rest = ln.split(' ', 1)
        except ValueError:
            continue
        if 'CLOCK_PROBE_START' in rest:
            t_start = float(t)
            mm = re.search(r'START (\d+) ms', rest)
            if mm:
                probe_ms = int(mm.group(1))
        elif 'CLOCK_PROBE_END' in rest and t_start is not None:
            t_end = float(t)
    if t_start is not None and t_end is not None:
        wall_ms = round((t_end - t_start) * 1000.0, 1)

# The guest thinks the interval was probe_ms long, using mtime. If mtime really ticks at
# want_hz, the wall clock agrees. Report the ratio rather than a verdict.
wall_ratio = round(wall_ms / probe_ms, 4) if (wall_ms and probe_ms) else None
core_hz_from_wall = None
if wall_ms and probe_ms and mcycles:
    core_hz_from_wall = int(round(mcycles / (wall_ms / 1000.0)))

manifest = {
    'board': board,
    'sample': sample,
    'bin_md5': md5(os.path.join(run, 'zephyr.bin')),
    'elf_md5': md5(os.path.join(run, 'zephyr.elf')),
    'console_lines': lines,
    'measured': {
        'fclk_hz_from_ps': fclk_hz,
        'mcycles': mcycles,
        'mticks': mticks,
        'mcycle_per_mtime': divider,
        'guest_interval_ms': probe_ms,
        'host_wall_ms': wall_ms,
        'wall_over_guest': wall_ratio,
        'core_hz_from_wall_clock': core_hz_from_wall,
        'sys_clock_hw_cycles_per_sec': want_hz,
        'total_checks': int(total.group(1)) if total else None,
        'total_failures': int(total.group(2)) if total else None,
        'hart1_traps': [{'op': o, 'mcause': int(c), 'mepc': e, 'mtval': v, 'rd': r}
                        for (o, c, e, v, r) in traps],
        'misa': {h: {'value': v, 'isa': s} for (h, v, s) in misa},
    },
    # Checked against expected/<sample>.json.
    'results': {
        'booted': '*** Booting Zephyr OS' in text,
        'arch_num_cpus': next((int(x) for x in
                               re.findall(r'arch_num_cpus\s*=\s*(\d+)', text)), None),
        # hart 0 computed all four, bit-exactly against sw/pext.h
        'pext_ops': checks.get('pext_ops') == '1',
        'hart0_ops_executed': len(executed),
        'hart0_legal': checks.get('hart0_legal') == '1',
        # THE NEGATIVE TEST: four illegal-instruction traps on hart 1, rd never written
        'hart1_traps': checks.get('hart1_traps') == '1',
        'hart1_trap_count': len(traps),
        'hart1_all_illegal': bool(traps) and all(int(c) == 2 for (_, c, _, _, _) in traps),
        'hart1_rd_unwritten': bool(traps) and all(
            r == '0xa5a5a5a5a5a5a5a5' for (_, _, _, _, r) in traps),
        'isa_match': checks.get('isa_match') == '1',
        'harts_observed': harts_observed,
        # hart 0 has misa.S|misa.U, hart 1 has neither: the documented useVM=false
        # asymmetry, and an independent witness that the pinning really split the harts.
        'priv_split': checks.get('priv_split') == '1',
        'mcycle_per_mtime': divider,
        # Either banner: pext_hart_proof prints its own, smp_hart_proof prints RESULT.
        'result_pass': ('PEXT_HART_PROOF: PASS' in text) or ('RESULT: PASS' in text),
    },
}
# smp_hart_proof's four checks, ADDED ONLY WHEN THAT SAMPLE PRODUCED THEM. Emitting them
# unconditionally would put `barrier: false` in the manifest of a run that never attempted
# a barrier, which reads as a failure rather than as "not applicable".
if 'distinct_harts' in smp_checks:
    manifest['results'].update({
        'distinct_harts': smp_checks.get('distinct_harts') == '1',
        'barrier': smp_checks.get('barrier') == '1',
        'overlap': smp_checks.get('overlap') == '1',
        'pingpong': smp_checks.get('pingpong') == '1',
    })
json.dump(manifest, open(os.path.join(run, 'run.json'), 'w'), indent=2)
print(f"    manifest: {os.path.join(run, 'run.json')}")
if fclk_hz:
    print(f"    FCLK0 read back from the SLCR : {fclk_hz} Hz ({fclk_hz/1e6:.4f} MHz)")
if divider:
    print(f"    mcycle per mtime tick         : {divider}  (hardware divider)")
if core_hz_from_wall:
    print(f"    core clock vs the HOST clock  : {core_hz_from_wall} Hz "
          f"({core_hz_from_wall/1e6:.3f} MHz, {wall_ms} ms wall for a "
          f"{probe_ms} ms guest interval)")
PY

grep -q '\*\*\* Booting Zephyr OS' "$RUN/console.txt" 2>/dev/null \
  || die "the SoC did not boot; see $RUN/boot.log"

EXPECT="$IISWC_ROOT/expected/$(basename "$SAMPLE").json"
if [ -f "$EXPECT" ]; then
  step "check  (vs $(basename "$EXPECT"))"
  python3 - "$RUN/run.json" "$EXPECT" <<'PYCHECK' || die "golden check failed"
import json, sys
got = json.load(open(sys.argv[1]))["results"]
exp = json.load(open(sys.argv[2]))
bad = 0
for k, want in exp.items():
    if k.startswith("_"):
        continue
    have = got.get(k)
    if have != want:
        bad += 1
    print(f"    {'ok  ' if have == want else 'FAIL'}  {k:<20} expected {want!r}   got {have!r}")
sys.exit(1 if bad else 0)
PYCHECK
fi

step "MBP RUNS ON HART 0 AND TRAPS ON HART 1 -- output in $RUN/console.txt"
