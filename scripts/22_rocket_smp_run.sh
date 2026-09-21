#!/usr/bin/env bash
# Lab B3 -- build a Zephyr SMP app and run it on BOTH harts of the dual-core big.LITTLE
# Rocket, on the FPGA:
#
#   west build (chipyard_pynqz1_smp)  ->  scp zephyr.bin  ->  PS writes DDR
#   ->  release reset  ->  pulse custom_boot  ->  hart 0 wakes hart 1  ->  /dev/ttyPS1
#
# Same shape as 20_rocket_run.sh, which it deliberately does not modify. The differences
# are all consequences of there being two harts:
#
#   * a different bitstream          build_rocket_smp_z1/pynqz1_rocket_smp.bit
#   * a different MAGIC              0x5A5A0003, so a run against the single-core PL is
#                                    refused rather than silently running on one hart
#   * a different Zephyr board       chipyard_pynqz1_smp (CONFIG_MP_MAX_NUM_CPUS=2)
#   * a stricter golden check        the manifest records which harts actually executed,
#                                    not just that something booted
#
# NOTHING extra is needed to start hart 1: the bootrom's hart 0 path writes every other
# hart's MSIP before clearing its own. See fpga/pynq-z2/docs/DUAL_CORE.md.
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin   the guest
#   console.txt               what the SoC printed
#   boot.log                  the PS-side bring-up transcript
#   run.json                  manifest, including per-hart evidence
#
# Usage:
#   scripts/22_rocket_smp_run.sh                                   # smp_hart_proof
#   scripts/22_rocket_smp_run.sh --sample PATH --name X
#   scripts/22_rocket_smp_run.sh --no-bitstream                    # reuse the loaded PL
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$IISWC_ROOT/samples/smp_hart_proof"
NAME="rocket_smp"
BOARD="chipyard_pynqz1_smp"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_smp_z1/pynqz1_rocket_smp.bit"
LOAD_BIT=1
SECONDS_READ=25
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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

# A dual-core bitstream with a single-core image on it is the other half of the mistake
# the MAGIC guards against, so check the image really was built for two harts.
NCPU=$(grep -E '^CONFIG_MP_MAX_NUM_CPUS=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${NCPU:-1}" -ge 2 ] || die "CONFIG_MP_MAX_NUM_CPUS=$NCPU -- this image would run on one hart"
grep -q '^CONFIG_SMP=y' "$BUILD/zephyr/.config" || die "CONFIG_SMP is not enabled in this image"
info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")   cpus: $NCPU"

step "2/5  reach the board"
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

step "3/5  load the PL and hold the SoC in reset"
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
# run_rocket_smp.py exits non-zero on a MAGIC mismatch, so diagnose that BEFORE retrying
# with a password -- otherwise the real cause is buried under a sudo fallback.
wrong_pl () {
  if grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log"; then
    cat "$RUN/boot.log"
    die "the SINGLE-core bitstream is loaded (MAGIC 0x5A5A0002). This image would boot on
       one hart and prove nothing. Re-run without --no-bitstream, or load
       fpga/pynq-z2/build_rocket_smp_z1/pynqz1_rocket_smp.bit."
  fi
  if grep -q 'MAGIC = 0x5A5A0001' "$RUN/boot.log"; then
    cat "$RUN/boot.log"; die "the DRAM self-test bitstream is loaded (MAGIC 0x5A5A0001)."
  fi
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_smp.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  # The board's sudo may still want a password; fall back rather than fail the run.
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_smp.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
# 0x5A5A0003 is the dual-core design. Anything else and this image would run on one hart.
grep -q 'MAGIC = 0x5A5A0003' "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "dual-core bitstream not reachable over GP0"
}
info "dual-core PL loaded, SoC held in reset"

step "4/5  boot both harts and capture the console"
# The console reader must be listening BEFORE the core starts: the SiFive UART's TX FIFO is
# only 8 bytes deep, so a late reader loses the banner.
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_smp.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true

step "5/5  result"
if [ -s "$RUN/console.txt" ]; then
  printf '%s\n' "----------------------------------------------------------------"
  cat "$RUN/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
else
  warn "no console output -- check $RUN/boot.log"
  grep -E 'STATUS|saw_mem' "$RUN/boot.log" | tail -6 || true
fi

python3 - "$RUN" "$SAMPLE" "$BOARD" <<'PY'
import hashlib, json, os, re, sys
run, sample, board = sys.argv[1:4]
def md5(p):
    return hashlib.md5(open(p,'rb').read()).hexdigest() if os.path.exists(p) else None
console = os.path.join(run, 'console.txt')
text = open(console).read() if os.path.exists(console) else ''
lines = text.splitlines()

# Per-hart evidence, straight out of the console. `mhartid` is read from the CSR on each
# pinned worker, so the set below is what the HARDWARE reported, not what Zephyr assumed.
harts = sorted({int(m) for m in re.findall(r'mhartid = (\d+)', text)})
ncpus = next((int(m) for m in re.findall(r'arch_num_cpus\s*=\s*(\d+)', text)), None)
checks = dict(re.findall(r'(\w+)=([01])\b', next(
    (l for l in lines if l.startswith('CHECKS')), '')))
m = re.search(r'overlap : (\d+) ticks \((\d+)%', text)
pingpong = re.search(r'(\d+)/(\d+) round trips', text)

json.dump({
    'board': board,
    'sample': sample,
    'bin_md5': md5(os.path.join(run,'zephyr.bin')),
    'elf_md5': md5(os.path.join(run,'zephyr.elf')),
    'console_lines': lines,
    'measured': {
        'overlap_ticks':   int(m.group(1)) if m else None,
        'overlap_percent': int(m.group(2)) if m else None,
        'pingpong_rounds': int(pingpong.group(1)) if pingpong else None,
    },
    # Checked against expected/<sample>.json.
    'results': {
        'booted': '*** Booting Zephyr OS' in text,
        'arch_num_cpus': ncpus,
        'harts_observed': harts,
        'distinct_harts': checks.get('distinct_harts') == '1',
        'barrier': checks.get('barrier') == '1',
        'overlap': checks.get('overlap') == '1',
        'pingpong': checks.get('pingpong') == '1',
        'result_pass': 'RESULT: PASS' in text,
    },
}, open(os.path.join(run,'run.json'),'w'), indent=2)
print(f"    manifest: {os.path.join(run,'run.json')}")
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
    print(f"    {'ok  ' if have == want else 'FAIL'}  {k:<16} expected {want!r}   got {have!r}")
sys.exit(1 if bad else 0)
PYCHECK
fi

step "BOTH HARTS RAN -- output in $RUN/console.txt"
