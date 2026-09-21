#!/usr/bin/env bash
# The long QAT run of MOONSHINE_MODEL.md section 3.3.1: per-tensor int8 WITHOUT the split-dispatch
# stem, on train-clean-100 in full plus a slice of train-other-500 (~250 h), to decide whether
# section 8.13's stem plan is needed at all.
#
#   IISWC_ROOT=... MOONSHINE_DIR=... PY=... model_qat_long.sh
#
# PREDICTION P11 is committed in MOONSHINE_MODEL.md section 3.3.1 BEFORE this runs: eval WER 9.8 %
# (interval 9.0-10.5), so it MISSES the 9.52 % bar; falsified below 9.52 or above 10.84.
#
# Stopping rule, whichever first: an 8-hour wall-clock cap, or a plateau -- dev WER on a fixed
# 256-utterance evenly-spaced subset every 30 min, stop after 3 evaluations without a 0.10-point
# improvement.  The BEST-DEV checkpoint is kept, not the last, and the eval set runs once on it.
#
# GPU etiquette: takes ONE free card, named in the log, and refuses if none is free.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IISWC_ROOT="${IISWC_ROOT:-$(cd "$HERE/../../../.." && pwd)}"
export IISWC_ROOT
export MOONSHINE_DIR="${MOONSHINE_DIR:-$IISWC_ROOT/out/moonshine}"
export ARCHIVE="${ARCHIVE:-$IISWC_ROOT/archive}"
PY="${PY:-$IISWC_ROOT/zephyr-chipyard-sw/tools/miniforge3/envs/zephyr/bin/python}"
[ -x "$PY" ] || PY=python3
L="${LOGDIR:-$IISWC_ROOT/logs}"; mkdir -p "$L"
cd "$HERE"

"$PY" -u model_trainset.py --decode --stem train_big > "$L/trainset_big.log" 2>&1 || {
  echo "decode failed; see $L/trainset_big.log" >&2; exit 1; }
echo "==> train_big decoded"

G=""
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader); do
  [ "$(nvidia-smi --id="$g" --query-compute-apps=pid --format=csv,noheader | wc -l)" -eq 0 ] && { G=$g; break; }
done
[ -n "$G" ] || { echo "no free GPU; refusing to share" >&2; exit 1; }
echo "==> long QAT on GPU $G"

CUDA_VISIBLE_DEVICES=$G "$PY" -u model_train.py --lever qat --data-stem train_big \
  --minutes 480 --lr 1e-4 --eval-every-min 30 --eval-subset 256 --plateau 3 --plateau-delta 0.001 \
  --test --json model_pilot_qat_long.json --tag qat_long > "$L/qat_long.log" 2>&1
echo "==> LONG QAT DONE (GPU $G)"
