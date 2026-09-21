#!/usr/bin/env bash
# The five training pilots of MOONSHINE_MODEL.md section 3, in the order section 4.4 ranks them.
#
#   fpga/pynq-z2/modelblaster/moonshine/model_pilots.sh            # all five, ~4 h
#   fpga/pynq-z2/modelblaster/moonshine/model_pilots.sh base qat   # a subset
#
# GPU ETIQUETTE.  The TITAN RTX is shared.  This script REFUSES TO START if another process holds
# the card, and says so, because that is what stopped these runs the first time (section 3.2).
# Override with MODEL_PILOTS_FORCE=1 only if you know the other job is yours.
#
# Each pilot writes a curated JSON here and its checkpoint to archive/model_pilots/<tag>/, never
# to git.  Predictions P9 and P10 are on record in MOONSHINE_MODEL.md section 2.0 (commit 8c03c68)
# and must be scored in the doc and in docs/EXPERIMENT_LOG.md when these run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IISWC_ROOT="${IISWC_ROOT:-$(cd "$HERE/../../../.." && pwd)}"
MOONSHINE_DIR="${MOONSHINE_DIR:-$IISWC_ROOT/out/moonshine}"
PY="${PY:-$IISWC_ROOT/zephyr-chipyard-sw/tools/miniforge3/envs/zephyr/bin/python}"
[ -x "$PY" ] || PY=python3
export PYTHONPATH="$MOONSHINE_DIR/pylib${PYTHONPATH:+:$PYTHONPATH}"
CNT="$MOONSHINE_DIR/librispeech/model_train_row_counts.npy"

# Only the cards this run will use.  On a multi-GPU host set CUDA_VISIBLE_DEVICES first; with it
# unset every card counts, which is the single-GPU case.
busy=0
if [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
  for g in ${CUDA_VISIBLE_DEVICES//,/ }; do
    u=$(nvidia-smi --id="$g" --query-compute-apps=pid --format=csv,noheader | wc -l)
    [ "$u" -gt 0 ] && { echo "GPU $g is in use:" >&2; nvidia-smi --id="$g" --query-compute-apps=pid,used_memory --format=csv >&2; busy=1; }
  done
else
  busy=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)
fi
if [ "$busy" -gt 0 ] && [ "${MODEL_PILOTS_FORCE:-0}" != "1" ]; then
  echo "refusing to start (set CUDA_VISIBLE_DEVICES to free cards, or MODEL_PILOTS_FORCE=1)" >&2
  exit 1
fi
[ -f "$CNT" ] || { echo "run model_trainset.py --emit first ($CNT)" >&2; exit 1; }

want() { [ $# -eq 0 ] && return 0; for w in "$@"; do [ "$w" = "$SEL" ] && return 0; done; return 1; }
run() { SEL="$1"; shift; if [ ${#WANT[@]} -eq 0 ] || want "${WANT[@]}"; then echo "=== $SEL ==="; "$@"; fi; }
WANT=("$@")

cd "$HERE"
run base   "$PY" -u model_base.py --wer --price --json model_base.json
run qat    "$PY" -u model_train.py --lever qat --minutes 55 --lr 1e-4 --test \
                 --json model_pilot_qat.json --tag qat
run heads  "$PY" -u model_train.py --lever heads --heads 6 --minutes 50 --lr 2e-4 --test \
                 --json model_pilot_heads6.json --tag heads6
run vocab  "$PY" -u model_train.py --lever vocab --keep-rows 6144 --train-counts "$CNT" \
                 --minutes 50 --lr 5e-5 --test --json model_pilot_vocab6144.json --tag vocab6144
run ffn    "$PY" -u model_train.py --lever ffn --ffn 768 --minutes 45 --lr 2e-4 \
                 --json model_pilot_ffn768.json --tag ffn768
run layers "$PY" -u model_train.py --lever declayers --dec-layers 4 --minutes 45 --lr 2e-4 \
                 --json model_pilot_declayers4.json --tag declayers4
echo "pilots done"
