#!/usr/bin/env bash
# Lab B -- build a Zephyr app and run it on Rocket, on the FPGA:
#
#   west build (chipyard_pynqz1)  ->  scp zephyr.bin  ->  PS writes DDR  ->  release reset
#   ->  pulse custom_boot  ->  console on /dev/ttyPS1
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin   the guest
#   console.txt               what Rocket printed
#   boot.log                  the PS-side bring-up transcript
#   run.json                  manifest
#
# Usage:
#   scripts/20_rocket_run.sh                                   # hello_world
#   scripts/20_rocket_run.sh --sample PATH --name X
#   scripts/20_rocket_run.sh --no-bitstream                    # reuse the loaded PL
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$ZCS/samples/hello_world"
NAME="rocket_hello"
BOARD="chipyard_pynqz1"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_z1/pynqz1_rocket_tacit.bit"
LOAD_BIT=1
SECONDS_READ=20
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
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
info "bin: $(fsize "$RUN/zephyr.bin")   elf: $(fsize "$RUN/zephyr.elf")"

step "2/5  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "3/5  load the PL and hold Rocket in reset"
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
  # The board's sudo may still want a password; fall back rather than fail the run.
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0002' "$RUN/boot.log" || { cat "$RUN/boot.log"; die "Rocket bitstream not reachable over GP0"; }
info "PL loaded, SoC held in reset"

step "4/5  boot Rocket and capture the console"
# The console reader must be listening BEFORE the core starts: the SiFive UART's TX FIFO is
# only 8 bytes deep, so a late reader loses the banner.
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
import hashlib, json, os, sys
run, sample, board = sys.argv[1:4]
def md5(p):
    return hashlib.md5(open(p,'rb').read()).hexdigest() if os.path.exists(p) else None
console = os.path.join(run, 'console.txt')
text = open(console).read() if os.path.exists(console) else ''
lines = text.splitlines()
json.dump({
    'board': board,
    'sample': sample,
    'bin_md5': md5(os.path.join(run,'zephyr.bin')),
    'elf_md5': md5(os.path.join(run,'zephyr.elf')),
    'console_lines': lines,
    # Checked against expected/<sample>.json. Deliberately NOT bin_bytes or md5: the build
    # path is embedded in the image, so those shift between checkouts.
    'results': {
        'booted': '*** Booting Zephyr OS' in text,
        'console_lines': len(lines),
        'hello_line': next((l for l in lines if l.startswith('Hello World!')), None),
    },
}, open(os.path.join(run,'run.json'),'w'), indent=2)
print(f"    manifest: {os.path.join(run,'run.json')}")
PY

grep -q '\*\*\* Booting Zephyr OS' "$RUN/console.txt" 2>/dev/null \
  || die "Rocket did not boot; see $RUN/boot.log"

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

step "ROCKET BOOTED -- output in $RUN/console.txt"
