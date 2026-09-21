#!/usr/bin/env bash
# Lab B27 (host only) -- the Moonshine encoder quantisations that transcribe, as GENERATED C.
#
#   ./scripts/53_moonshine_q16_host.sh                                  # R, R3, F3PR on dev-clean
#   ./scripts/53_moonshine_q16_host.sh --sets test                      # test-clean: ONCE per candidate
#   ./scripts/53_moonshine_q16_host.sh --candidates R --skip-fidelity   # plan, IR, code, gates only
#
# ROCC_DECOUPLED.md 8.13 chose these in float simulation (quant_fix.py, fq.py).  Only the
# generated integer C counts, so per candidate:
#   1. plan      moonshine/q16_plan_<cand>.json: quant_fix.build()'s decision on the 64 dev-clean
#                calibration windows, frozen (committed; --replan rebuilds it with q16_plan.py)
#   2. extract   modelblaster.pipeline.extract_q16 (patches/0103): the integer lowering and its
#                golden, every activation dumped for the gates
#   3. codegen   ref  ModelBlaster's reference kernels (each new one IS its integer golden)
#                cur  curated kernels for the NEW kinds, reference for every stock kind
#                nl   --target pext_nl with every curated kernel: what a board runs
#   4. gates     q16_gates.py: (a) ref vs golden at every dispatch, (b) cur vs golden at every
#                dispatch + q16_stress.c (-O2, ASan+UBSan) + rv64imac objects, (c) nl per
#                dispatch and its host-C golden
#   5. fidelity  q16_fidelity.py: WER of ref and nl over every utterance of the set that fits
#                4 s, against the reference and the float encoder, with the candidate's float
#                simulation rerun on the same utterances and paired bootstrap gaps
#   6. compare   q16_compare.py, once every candidate has dev and test: the candidates side by
#                side and pairwise (pext_nl builds), paired bootstrap intervals over utterances
#
# Candidates are q16_plan.py's keys:
#   R     "FINAL R: split stem (1, 64), stem weights 2 group(s), adds per-channel + o_proj/fc2 rows"
#   R3    "FINAL R: split stem (1, 16, 256), stem weights 4 group(s), ..."
#   F3PR  "CD F3PR: stem int16 + adds per-channel + rows + per-row"
# No board.  The GPU is used when present (float encoder, float simulation, HF decoder).
# Produces out/<name>/<cand>/{ir,gen_ref,gen_cur,gen_nl,gates}, q16_gates_<cand>.json and
# q16_fidelity_<cand>_<set>.json.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

NAME="q16"
CANDIDATES="R R3 F3PR"
SETS="dev"
REPLAN=0
GATES=1
FIDELITY=1
JOBS=$(( $(nproc) > 8 ? $(nproc) - 4 : $(nproc) ))
STRESS_SCALE=50
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --candidates) CANDIDATES="${2:?}"; shift 2 ;;
    --sets) SETS="${2:?}"; shift 2 ;;
    --replan) REPLAN=1; shift ;;
    --skip-gates) GATES=0; shift ;;
    --skip-fidelity) FIDELITY=0; shift ;;
    --jobs) JOBS="${2:?}"; shift 2 ;;
    --stress-scale) STRESS_SCALE="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

MB="$ZCS/modelblaster"
MOON="$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB"
RUN="$IISWC_OUT/$NAME"
mkdir -p "$RUN"
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export IISWC_ROOT
export MOONSHINE_DIR="${MOONSHINE_DIR:-$IISWC_OUT/moonshine}"
PY="$ZCS/tools/miniforge3/envs/zephyr/bin/python"; [ -x "$PY" ] || PY=python

step "0/5  checkpoint, LibriSpeech, patches"
"$MOON/fetch_moonshine.sh" > "$RUN/fetch.log" 2>&1 || { cat "$RUN/fetch.log"; die "fetch_moonshine.sh failed"; }
"$MOON/fetch_librispeech.sh" >> "$RUN/fetch.log" 2>&1 || { tail -20 "$RUN/fetch.log"; die "fetch_librispeech.sh failed"; }
for P in 0009-modelblaster-pext-backend 0060-modelblaster-pext-pc-and-int-nonlin; do
  F="$IISWC_ROOT/patches/$P.patch"
  if git -C "$MB" apply --check "$F" >/dev/null 2>&1; then run git -C "$MB" apply "$F"; fi
done
# The 0100.. stack exactly as scripts/50 applies it (later patches edit hunks of earlier ones, so
# the stack is checked from its top).  0103 touches nothing any of them edits, so it is checked
# on its own both ways: it applies, or it is already in.
MB_STACK="0100-modelblaster-moonshine-ops 0102-modelblaster-roccmoon-backend 0104-modelblaster-softmax-memo 0105-modelblaster-moonshine-stem-nhwc 0106-modelblaster-softmax-memo2"
if git -C "$MB" apply --reverse --check "$IISWC_ROOT/patches/${MB_STACK##* }.patch" >/dev/null 2>&1; then
  info "patch stack through ${MB_STACK##* } already applied"
else
  for P in $MB_STACK; do
    F="$IISWC_ROOT/patches/$P.patch"
    if git -C "$MB" apply --check "$F" >/dev/null 2>&1; then run git -C "$MB" apply "$F"
    elif git -C "$MB" apply --reverse --check "$F" >/dev/null 2>&1; then info "$P already applied"
    else die "patches/$P neither applies nor is already applied to $MB"; fi
  done
fi
F="$IISWC_ROOT/patches/0103-modelblaster-q16-lowering.patch"
if git -C "$MB" apply --reverse --check "$F" >/dev/null 2>&1; then info "0103 already applied"
elif git -C "$MB" apply --check "$F" >/dev/null 2>&1; then run git -C "$MB" apply "$F"
else die "patches/0103 neither applies nor is already applied to $MB"; fi

codegen () {  # ir gen kind(ref|cur|nl)
  local ir="$1" gen="$2" kind="$3" extra=()
  case "$kind" in
    ref) ;;
    cur) extra=(--global-curated-dir "$KERNELS"
                --keep-reference-ops gelu_s8,softmax_s8,linear_s8,linear_s8_pc,conv2d_s8,matmul_b_s8,rope_s8,permute4_s8) ;;
    nl)  extra=(--global-curated-dir "$KERNELS") ;;
  esac
  rm -rf "$gen" "$gen.kverify" "$gen.cache"; mkdir -p "$gen"
  ( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_skeleton \
      --ir "$ir/graph.json" --weights "$ir/weights.npz" --io "$ir/io.npz" --out-dir "$gen" --backend pext_nl \
    && "$PY" -m modelblaster.pipeline.generate_kernels \
      --ir "$ir/graph.json" --out-dir "$gen" --backend reference --target pext_nl --quant int8 \
      --io "$ir/io.npz" --repo-root "$MB" --build-dir "$gen.kverify" --harness-dir "$MB/harness" \
      --cache-dir "$gen.cache" --algorithms all "${extra[@]}" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "codegen $kind failed ($gen)"; }
}

for C in $CANDIDATES; do
  D="$RUN/$C"
  PLAN="$MOON/q16_plan_$C.json"
  step "1/5  $C: plan"
  if [ "$REPLAN" -eq 1 ] || [ ! -f "$PLAN" ]; then
    ( cd "$IISWC_ROOT" && PYTHONPATH="$ZCS:$MOONSHINE_DIR/pylib" "$PY" "$MOON/q16_plan.py" \
        --candidate "$C" --out "$PLAN" ) > "$RUN/plan_$C.log" 2>&1 || { tail -20 "$RUN/plan_$C.log"; die "q16_plan.py $C failed"; }
  fi
  info "$(python3 -c "import json,sys; p=json.load(open(sys.argv[1])); print(p['quant_fix_key'])" "$PLAN")"
  step "2/5  $C: extract_q16"
  rm -rf "$D/ir"; mkdir -p "$D/ir"
  ( cd "$ZCS" && MB_INT8_DUMP_ACTIVATIONS="$D/ir/acts.npz" "$PY" -m modelblaster.pipeline.extract_q16 \
      --model moonshine_enc --plan "$PLAN" --out-dir "$D/ir" ) > "$D/extract.log" 2>&1 \
    || { tail -30 "$D/extract.log"; die "extract_q16 $C failed"; }
  info "$(grep '^\[extract_q16\]' "$D/extract.log")"
  step "3/5  $C: codegen (ref, cur, nl)"
  for K in ref cur nl; do codegen "$D/ir" "$D/gen_$K" "$K"; done
  if [ "$GATES" -eq 1 ]; then
    step "4/5  $C: host gates"
    SKIP=(); [ "$C" = "$(echo $CANDIDATES | cut -d' ' -f1)" ] || SKIP=(--skip-stress)   # the stress is model-independent
    ( cd "$IISWC_ROOT" && "$PY" "$MOON/q16_gates.py" --label "$C" --ir "$D/ir" --ref-gen "$D/gen_ref" \
        --cur-gen "$D/gen_cur" --ew-gen "$D/gen_nl" --workdir "$D/gates" --json "$RUN/q16_gates_$C.json" \
        --stress-scale "$STRESS_SCALE" "${SKIP[@]}" ) 2>&1 | grep -v "ld: \|NOTE: This" | tee "$D/gates.log"
    grep -q '^PASS' "$D/gates.log" || die "host gates failed for $C"
  fi
  if [ "$FIDELITY" -eq 1 ]; then
    for SET in $SETS; do
      step "5/5  $C: fidelity on $SET-clean"
      ( cd "$IISWC_ROOT" && PYTHONPATH="$ZCS:$MOONSHINE_DIR/pylib" "$PY" "$MOON/q16_fidelity.py" --set "$SET" \
          --jobs "$JOBS" --float-sim "$C" --variant "${C}_ref:$D/ir:$D/gen_ref" --variant "${C}_nl:$D/ir:$D/gen_nl" \
          --workdir "$D/fid_$SET" --json "$RUN/q16_fidelity_${C}_$SET.json" ) 2>&1 \
        | grep '^\[fidelity\]\|^wrote' | tee "$D/fidelity_$SET.log"
      [ -f "$RUN/q16_fidelity_${C}_$SET.json" ] || die "q16_fidelity.py $C $SET failed"
    done
  fi
done
if [ "$FIDELITY" -eq 1 ]; then
  have=1
  for C in R R3 F3PR; do for SET in dev test; do [ -f "$RUN/q16_fidelity_${C}_$SET.json" ] || have=0; done; done
  if [ "$have" -eq 1 ]; then
    step "side by side: q16_compare.py"
    ( cd "$IISWC_ROOT" && "$PY" "$MOON/q16_compare.py" --fid-dir "$RUN" --workdir-pattern "{cand}/fid_{set}" \
        --json "$RUN/q16_results.json" ) | tee "$RUN/q16_results.txt"
  else
    info "q16_compare.py needs R, R3 and F3PR on dev and test; not run"
  fi
fi
step "done: $RUN"
