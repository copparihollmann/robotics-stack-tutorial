#!/usr/bin/env bash
# Lab B122 -- RUN THE STANDALONE ENCODER ON TWO AUDIO WINDOWS THAT DIFFER IN NOTHING ELSE.
#
#   ./scripts/80_rocket_enc_audio_ab.sh --name b122_enc_mic  --gen out/b122_enc/gen_mic  --build-only
#   PYNQ_HOST=xilinx@<board-ip> scripts/with_board.sh \
#       ./scripts/80_rocket_enc_audio_ab.sh --name b122_enc_mic --gen out/b122_enc/gen_mic --board-only
#
# WHY THE ENCODER ALONE AND NOT THE MERGED IMAGE.  The combined encoder+prologue+decoder
# image has an OPEN correctness defect -- Lab B117: the first inference is the host's to the
# byte on all 4,389 dispatches, the SECOND diverges at dispatch 17, max_abs_err 65.  Feeding
# it microphone audio would confound the acoustic question with a known unrelated one.  The
# STANDALONE encoder is the arm B117's C1 proved exact across two inferences, and it is the
# one this lab runs.
#
# WHAT THE TWO ARMS SHARE, AS A RECORDED FACT AND NOT AN INTENTION.  b122_encio.py builds
# each arm's gen by SYMLINKING model.c, kernels.c, weights.c, buffers.c, model.h, kernels.h,
# weights.h, test_io.h and kernel_picks.json out of ONE source gen -- Lab B114's own control,
# out/b114_enc_ctl_board/enc_q16/gen -- so the only regular files in an arm are its 64,000
# input bytes, its 47,520 golden bytes and the .incbin wrapper that points at them.  A second
# codegen pass would probably have produced the same C; "probably the same" is the class of
# claim this campaign keeps catching, so it is not used.
#
# AND THE CONTROL THAT SAYS THE MACHINERY IS SOUND: an arm built this way from the SOURCE
# GEN's OWN input re-bakes B114's test_golden.bin byte for byte (0 of 47,520 differ).
#
# NO CODEGEN, NO RTL, NO NEW BITSTREAM.  The kernel cflags are taken from the source gen's
# sibling kernel_cflags.txt and asserted against --expect-cflags, because a cflag string is
# not a configuration and two labs have already compared eleven defines and missed the one
# that mattered (scripts/57's own note).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mbxr_abi.sh"

NAME="b122_enc_ab"
GEN=""
SRC_META="$IISWC_ROOT/out/b114_enc_ctl_board/enc_q16"
SAMPLE="$IISWC_ROOT/samples/modelblaster_pext"
BOARD="chipyard_pynqz1_micrgb_f40"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98b_z1/pynqz1_rocket_micrgb_roccmoonnch8f40b98b.bit"
RUNNER="run_rocket_roccmoonnch8f40b98b.py"
WANT_MAGIC="0x5A5A0035"; FCLK_CORE=40; ITERS=2; MAXREAD=900
LAB_REQUIRES="${LAB_REQUIRES:-rocc_engine pext}"
DO_BOARD=1; BOARD_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --gen) GEN="${2:?}"; shift 2 ;;
    --src-meta) SRC_META="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --fclk) FCLK_CORE="${2:?}"; shift 2 ;;
    --iters) ITERS="${2:?}"; shift 2 ;;
    --maxread) MAXREAD="${2:?}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    --board-only) BOARD_ONLY=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$GEN" ] || die "--gen <dir> is required (build it with b122_encio.py)"
GEN="$(cd "$GEN" && pwd)"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; D="$RUN/enc"
PY="$ZCS/tools/miniforge3/envs/zephyr/bin/python"; [ -x "$PY" ] || PY=python
GUEST_KHZ=$(python3 -c "
n=round(1000e6/(float('$FCLK_CORE')*1e6)); print(int(round((1000e6/n)/1000.0)))")

if [ "$BOARD_ONLY" -eq 0 ]; then
  rm -rf "$RUN"; mkdir -p "$D"
  step "1/3  the gen this arm runs, and what it shares"
  need_file "$GEN/test_input.bin" "no input in $GEN"
  need_file "$GEN/test_golden.bin" "no golden in $GEN -- bake it with hostrun first"
  [ "$(stat -c %s "$GEN/test_input.bin")" = 64000 ] || die "the input is not 64,000 bytes"
  [ "$(stat -c %s "$GEN/test_golden.bin")" = 47520 ] || die "the golden is not 47,520 bytes"
  ln -sfn "$GEN" "$D/gen"
  md5sum "$GEN"/*.c "$GEN"/*.h "$GEN"/test_input.bin "$GEN"/test_golden.bin \
      > "$D/gen_md5.txt" 2>/dev/null || true
  grep -E "test_input|test_golden|model\.c|kernels\.c|weights\.c" "$D/gen_md5.txt" | sed 's/^/    /'
  CF="$(cat "$SRC_META/kernel_cflags.txt")"
  cp "$SRC_META/kernel_selectors.txt" "$D/kernel_selectors.txt"
  echo "$CF" > "$D/kernel_cflags.txt"
  info "kernel cflags (from $SRC_META, NOT re-derived):"
  info "  $CF"
  cat "$D/kernel_selectors.txt" | sed 's/^/    /'

  step "2/3  build the image (MB_ITERS=$ITERS, MB_WARMUP=0 -- both passes are timed)"
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DMB_ITERS="$ITERS" -DMB_WARMUP=0 \
      -DMB_JOIN_TIMEOUT_S=7200 -DMODELBLASTER_KERNEL_CFLAGS="$CF" \
      -DMB_HARNESS_CFLAGS=-DMBXR_RT_LUT=1 > "$RUN/build.log" 2>&1 \
    || { tail -40 "$RUN/build.log"; die "west build failed"; }
  cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
  grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ\$" "$D/build/zephyr/.config" \
    || die "guest clock mismatch: --fclk $FCLK_CORE needs $GUEST_KHZ"
  # THE ABI GATE.  The engine's drain descriptor changed shape at 0x5A5A002E and a mismatched
  # pair does not fail loudly -- it returns MBXR_E_TIMEOUT from the first dispatch.  Refuse
  # the pair here, before with_board.sh is called.
  mbxr_abi_gate "$D/zephyr.elf" "$WANT_MAGIC" || die "guest/bitstream ABI mismatch"
  info "image: $(fsize "$D/zephyr.bin") ($(stat -c %s "$D/zephyr.bin") bytes)"
  [ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }
fi

step "3/3  the board"
need_file "$D/zephyr.bin" "no image -- run without --board-only first"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"
BIT_ACCEPTED="${BIT_ACCEPTED:-} ${ROCCMOON_ACCEPTED:-32d10e5d47a4ca1f120f6f6d34e04b4e}"
bitstream_gate
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "$D/gen/kernel_picks.json" "$(cat "$D/kernel_cflags.txt")"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
info "board: PYNQ_HOST=$PYNQ_HOST  IISWC_BOARD=$IISWC_BOARD"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
run scp -q "$D/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
info "running (up to $MAXREAD s; the reader stops at the RESULT line)"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $MAXREAD > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $MAXREAD ] && ! grep -q \"^RESULT:\" console.out; do sleep 5; t=\$((t+5)); done
  sleep 2
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t console_bytes=\$(wc -c < console.out)
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
[ -s "$RUN/console.txt" ] || { cat "$RUN/boot.log"; die "0 console bytes"; }
grep -E "^MB_PEXT_RUN|^RESULT:" "$RUN/console.txt" | sed 's/^/    /'
export WANT_MAGIC IISWC_BOARD BIT_MD5
python3 - "$RUN" "$GEN" <<'PYS' | tee "$RUN/report.txt"
import hashlib, json, os, re, sys
run, gen = sys.argv[1], sys.argv[2]
txt = open(os.path.join(run, "console.txt"), errors="replace").read()
d = {"run": run, "gen": gen,
     "bitstream_md5": os.environ.get("BIT_MD5"), "board": os.environ.get("IISWC_BOARD"),
     "soc_magic": os.environ.get("WANT_MAGIC")}
m = re.search(r"^MB_PEXT_RUN (.*)$", txt, re.M)
d["mb_pext_run"] = dict((k, int(v)) for k, v in re.findall(r"(\w+)=(-?\d+)", m.group(1))) if m else None
d["result_line"] = (re.search(r"^RESULT:.*$", txt, re.M) or [None])[0] if re.search(r"^RESULT:", txt, re.M) else None
for f in ("test_input.bin", "test_golden.bin"):
    d[f] = hashlib.md5(open(os.path.join(gen, f), "rb").read()).hexdigest()
r = d["mb_pext_run"] or {}
d["checks"] = [
    {"what": "the board reproduced THIS arm's host-C golden (max_abs_err == 0)",
     "pass": r.get("max_abs_err") == 0},
    {"what": "two inferences really ran (min != max)", "pass": r.get("min") != r.get("max")},
]
d["all_pass"] = all(c["pass"] for c in d["checks"])
json.dump(d, open(os.path.join(run, "run.json"), "w"), indent=1)
print("   board %s   magic %s   md5 %s" % (d["board"], d["soc_magic"], d["bitstream_md5"]))
print("   input  md5 %s" % d["test_input.bin"])
print("   golden md5 %s" % d["test_golden.bin"])
print("   %s" % (d["result_line"] or "NO RESULT LINE"))
print("   MB_PEXT_RUN %s" % json.dumps(r))
for c in d["checks"]:
    print("   [%s] %s" % ("PASS" if c["pass"] else "FAIL", c["what"]))
print("   B122-ENC %s" % ("ALL CHECKS PASS" if d["all_pass"] else "SOME CHECKS FAILED"))
PYS
