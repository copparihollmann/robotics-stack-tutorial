#!/usr/bin/env bash
# Build the QAT-without-split (QATU) int8 candidate all the way to GENERATED C and score it
# on dev-clean 765.  This is the driver behind MOONSHINE_MODEL.md 2.8.1.
#
# Two things here are load-bearing and neither is obvious from the pipeline's defaults:
#
#   MB_INT8_CALIB_POLICY=p99.9   Activation ranges from a POOLED 99.9th percentile of |x|
#                                over the whole calibration set, not the max.  patches/0108.
#                                Worth 25.81 WER points on the stock ladder and 5.05 here.
#                                The pooling matters as much as the percentile: taking the
#                                percentile per sample and then the max over samples gives
#                                ranges 1.09x (median) to 3.11x (stem_conv1) wider and costs
#                                5.05 points -- that is what falsified P13 the first time.
#   MOONSHINE_CAL_SET=librispeech Calibrate on the pinned LibriSpeech calibration set rather
#                                than the packaged speech clip, so calibration and evaluation
#                                see the same acoustic conditions.
#
# The guard below exists because scripts/53_moonshine_q16_host.sh line 70 runs
# fetch_moonshine.sh, which writes the pinned STOCK checkpoint into $MOONSHINE_DIR and
# silently clobbered the QAT one once.  The tell was a 109.66 % run whose float baseline was
# 7.30 % (stock) instead of 10.62 % (QAT).  Never let that reproduce as a plausible number.
#
#   MOONSHINE_DIR=/path/to/qat/checkpoint bash model_qatu_build.sh
set -euo pipefail

IISWC_ROOT="${IISWC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
export IISWC_ROOT
ZCS="$IISWC_ROOT/zephyr-chipyard-sw"
MB="$ZCS/modelblaster"
MOON="$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
PY="${PY:-$ZCS/tools/miniforge3/envs/zephyr/bin/python}"
export MOONSHINE_DIR="${MOONSHINE_DIR:-$IISWC_ROOT/out/moonshine_qat}"
STOCK="$IISWC_ROOT/out/moonshine/model.safetensors"
RUN="${RUN:-$IISWC_ROOT/out/qatu_real}"
# The record path is a variable because two checkpoints go through this driver (the 55-minute
# pilot and the 162.66-hour run) and a run that silently overwrote the other one's record would
# be exactly the clobber the guard above exists to prevent.
OUT_JSON="${OUT_JSON:-$MOON/model_qatu_c_dev.json}"

if [ -f "$STOCK" ] && cmp -s "$MOONSHINE_DIR/model.safetensors" "$STOCK"; then
  echo "REFUSING: \$MOONSHINE_DIR holds the STOCK checkpoint, not the QAT one" >&2; exit 1
fi
echo "guard ok: checkpoint differs from stock"

# moonshine_enc resolves the LibriSpeech cache, the HF python lib and the dummy calibration clip
# RELATIVE TO $MOONSHINE_DIR (librispeech_sets.lsdir() is me.moonshine_dir()/"librispeech").  A
# checkpoint directory that holds only weights therefore fails extraction with a FileNotFoundError
# about dev_clean.npz, which reads like missing data and is really a missing symlink.  Link them
# from the stock tree, which is where fetch_librispeech.sh puts them.
STOCKDIR="$(dirname "$STOCK")"
for l in librispeech pylib; do
  [ -e "$MOONSHINE_DIR/$l" ] || ln -s "$STOCKDIR/$l" "$MOONSHINE_DIR/$l"
done
for f in librispeech_dummy_clean_validation.parquet; do
  [ -e "$MOONSHINE_DIR/$f" ] || [ ! -e "$STOCKDIR/$f" ] || ln -s "$STOCKDIR/$f" "$MOONSHINE_DIR/$f"
done

export MB_INT8_CALIB_POLICY="${MB_INT8_CALIB_POLICY:-p99.9}"
export MOONSHINE_CAL_SET="${MOONSHINE_CAL_SET:-librispeech}"

rm -rf "$RUN"; mkdir -p "$RUN/ir"
echo "=== extract_graph: policy=$MB_INT8_CALIB_POLICY, cal set=$MOONSHINE_CAL_SET, 64 windows ==="
( cd "$ZCS" && env MB_INT8_GELU_AWARE_RANGES=1 MB_INT8_GOLDEN_C_FLOAT=1 MOONSHINE_WINDOW_S=4.0 \
    "$PY" -m modelblaster.pipeline.extract_graph --model moonshine_enc --out-dir "$RUN/ir" \
    --quant int8 --num-calibration 64 --fusion-target pext_nl ) > "$RUN/extract.log" 2>&1
echo "  extracted"

gen="$RUN/gen_nl"; rm -rf "$gen" "$gen.kverify" "$gen.cache"; mkdir -p "$gen"
( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_skeleton \
    --ir "$RUN/ir/graph.json" --weights "$RUN/ir/weights.npz" --io "$RUN/ir/io.npz" \
    --out-dir "$gen" --backend pext_nl \
  && "$PY" -m modelblaster.pipeline.generate_kernels \
    --ir "$RUN/ir/graph.json" --out-dir "$gen" --backend reference --target pext_nl --quant int8 \
    --io "$RUN/ir/io.npz" --repo-root "$MB" --build-dir "$gen.kverify" --harness-dir "$MB/harness" \
    --cache-dir "$gen.cache" --algorithms all --global-curated-dir "$KERNELS" ) > "$RUN/codegen.log" 2>&1
echo "  generated"

echo "=== fidelity on dev-clean 765 (gen_nl) ==="
PYTHONPATH="$ZCS:$IISWC_ROOT/out/moonshine/pylib" "$PY" "$MOON/q16_fidelity.py" --set dev \
  --jobs "${JOBS:-16}" --variant "QATU_nl:$RUN/ir:$gen" --workdir "$RUN/fid_dev" \
  --json "$OUT_JSON" 2>&1 | grep '^\[fidelity\]\|^wrote'

# q16_fidelity.py records the graph, not how it was calibrated.  A record that does not carry
# its calibration policy is unreadable six weeks from now, because the SAME graph under the
# default max policy scores 5.05 points worse.  Stamp it.
"$PY" - "$OUT_JSON" <<'PYEOF'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["calibration"] = {
    "MB_INT8_CALIB_POLICY": os.environ["MB_INT8_CALIB_POLICY"],
    "MOONSHINE_CAL_SET": os.environ["MOONSHINE_CAL_SET"],
    "num_calibration": 64,
    "pooled": True,
    "patch": "patches/0108-modelblaster-int8-calibration-policy.patch",
    "note": "percentile is POOLED over the calibration set; per-sample-then-max costs 5.05 points",
}
d["checkpoint_dir"] = os.environ["MOONSHINE_DIR"]
json.dump(d, open(p, "w"), indent=1)
print("stamped calibration provenance into", p)
PYEOF
echo "QATU_REAL_DONE"
