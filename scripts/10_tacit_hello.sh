#!/usr/bin/env bash
# Lab A -- the end-to-end Spike TACIT flow:
#
#   west build (spike_riscv64)  ->  spike --trace=l  ->  ltrace-decoder --to-perfetto
#
# Produces, under out/<name>/:
#   zephyr.elf            the traced guest
#   tacit.out             encoded TACIT packets
#   tacit.debug           spike's per-instruction ground truth (for cross-checking)
#   trace.txt             decoded control-flow trace
#   trace.perfetto.json   load at https://ui.perfetto.dev
#   run.json              manifest: pins, sizes, counts -- the reproducibility record
#
# Usage:
#   scripts/10_tacit_hello.sh                          # samples/tacit, full-boot trace
#   scripts/10_tacit_hello.sh --sample PATH --name X   # any Zephyr app
#   scripts/10_tacit_hello.sh --isa rv64gcv_zicntr     # e.g. for RVV guests
#   scripts/10_tacit_hello.sh --cmake-arg -DX=1        # repeatable; passed to west after --
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$ZCS/samples/tacit"
NAME="tacit_hello"
ISA=""
BOARD="spike_riscv64"
EXPECT=""
# Extra -D flags for the sample's CMakeLists. Empty by default, so the golden run in
# expected/tacit.json is built exactly as it always was.
CMAKE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --isa)    ISA="${2:?}";    shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --expect) EXPECT="${2:?}";  shift 2 ;;
    --cmake-arg) CMAKE_ARGS+=("${2:?}"); shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_exec "$TACIT_SPIKE"   "run scripts/05_build_tacit_tools.sh, or export TACIT_SPIKE"
need_exec "$TACIT_DECODER" "run scripts/05_build_tacit_tools.sh, or export TACIT_DECODER"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"

RUN="$IISWC_OUT/$NAME"
BUILD="$RUN/build"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/4  build  ($BOARD)"
info "sample: $SAMPLE"
WEST_ARGS=(-p always -b "$BOARD" "$SAMPLE" -d "$BUILD")
if [ ${#CMAKE_ARGS[@]} -gt 0 ]; then
  WEST_ARGS+=(-- "${CMAKE_ARGS[@]}")
fi
run west build "${WEST_ARGS[@]}" > "$RUN/build.log" 2>&1 \
  || { tail -30 "$RUN/build.log"; die "build failed -- full log at $RUN/build.log"; }
ELF="$BUILD/zephyr/zephyr.elf"
need_file "$ELF" "build produced no ELF"
cp "$ELF" "$RUN/zephyr.elf"
info "elf: $(fsize "$RUN/zephyr.elf")"

step "2/4  spike --trace=l"
SPIKE_ARGS=(--trace=l)
[ -n "$ISA" ] && SPIKE_ARGS=(--isa="$ISA" "${SPIKE_ARGS[@]}")
# The L-encoder writes tacit.out / tacit.log / tacit.debug into the CWD, so run there.
( cd "$RUN" && run "$TACIT_SPIKE" "${SPIKE_ARGS[@]}" "$RUN/zephyr.elf" ) > "$RUN/spike.log" 2>&1 \
  || { tail -20 "$RUN/spike.log"; die "spike failed -- log at $RUN/spike.log"; }
need_file "$RUN/tacit.out" "spike emitted no trace -- is this the patched TACIT spike?"
INSNS=$(wc -l < "$RUN/tacit.debug" 2>/dev/null || echo 0)
TRACE_BYTES=$(stat -c%s "$RUN/tacit.out")
info "tacit.out: $(fsize "$RUN/tacit.out")   instructions traced: $INSNS"
grep -q "Hello World" "$RUN/spike.log" && info "guest console: Hello World! (guest ran to completion)"

step "3/4  decode  (txt + perfetto)"
( cd "$RUN" && run "$TACIT_DECODER" \
    --binary "$RUN/zephyr.elf" \
    --encoded-trace "$RUN/tacit.out" \
    --to-txt --to-perfetto ) > "$RUN/decode.log" 2>&1 \
  || { tail -20 "$RUN/decode.log"; die "decode failed -- log at $RUN/decode.log"; }
need_file "$RUN/trace.perfetto.json" "decoder produced no perfetto trace"
TXT_LINES=$(wc -l < "$RUN/trace.txt" 2>/dev/null || echo 0)
SLICES=$(grep -o '"ph":"B"' "$RUN/trace.perfetto.json" 2>/dev/null | wc -l || echo 0)
PACKETS=$(grep -oiE '[0-9]+ packets' "$RUN/decode.log" | head -1 || true)

step "4/4  manifest"
cat > "$RUN/run.json" <<JSON
{
  "name": "$NAME",
  "generated": "$(date -Is)",
  "sample": "$SAMPLE",
  "board": "$BOARD",
  "spike_isa": "${ISA:-default}",
  "pins": {
    "zephyr-chipyard-sw": "$(git -C "$ZCS" rev-parse HEAD 2>/dev/null)",
    "tacit-decoder": "$(git -C "$IISWC_ROOT/third_party/tacit-decoder" rev-parse HEAD 2>/dev/null)",
    "riscv-isa-sim": "$(git -C "$IISWC_ROOT/third_party/riscv-isa-sim" rev-parse HEAD 2>/dev/null)"
  },
  "results": {
    "elf_bytes": $(stat -c%s "$RUN/zephyr.elf"),
    "tacit_out_bytes": $TRACE_BYTES,
    "instructions_traced": $INSNS,
    "decoded_txt_lines": $TXT_LINES,
    "perfetto_begin_slices": $SLICES,
    "bits_per_instruction": $(awk "BEGIN{ if ($INSNS>0) printf \"%.2f\", ($TRACE_BYTES*8)/$INSNS; else print 0 }")
  }
}
JSON
cat "$RUN/run.json"

# Compare against golden values so a run says PASS/FAIL rather than leaving the reader
# to eyeball six numbers. Defaults to expected/<sample basename>.json when it exists.
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
    mark = "ok  " if have == want else "FAIL"
    if have != want:
        bad += 1
    print(f"    {mark}  {k:<24} expected {want:>10}   got {have if have is not None else 'missing':>10}")
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
