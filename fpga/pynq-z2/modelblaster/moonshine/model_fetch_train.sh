#!/usr/bin/env bash
# Fetch a TRAINING split for the model-side study (MOONSHINE_MODEL.md).
#
#   fpga/pynq-z2/modelblaster/moonshine/model_fetch_train.sh [n_clean] [n_other]
#       n_clean  train-clean-100 shards, 0..14   (default 4;  14 = the whole 100 h split)
#       n_other  train-other-500 shards, 0..8    (default 0;  8 = about 150 h more)
#
# WHY THIS IS A SEPARATE SCRIPT.  fetch_librispeech.sh fetches dev-clean and test-clean only:
# the fidelity sets of ROCC_DECOUPLED.md section 8.12, which are for SELECTING and REPORTING and must
# never be trained on.  Every training-based lever (QAT, structured pruning, distillation) needs
# audio that is neither of those.  These are LibriSpeech train-clean-100 shards, from the SAME
# pinned dataset revision, each sha256-pinned here the way fetch_librispeech.sh pins its two.
#
# train-clean-100 has 14 shards (0000..0013), about 6.4 GB and 100 h in total; 4 shards is about
# 1.9 GB and 29 h, which is what the one-hour pilots of MOONSHINE_MODEL.md section 3 use.  The long
# QAT run of section 3.3.1 uses all 14 plus 8 shards of train-other-500, about 250 h.  Every shard's
# sha256 is pinned here and re-checked after download.  Git-ignored under out/.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IISWC_ROOT="${IISWC_ROOT:-$(cd "$HERE/../../../.." && pwd)}"
MOONSHINE_DIR="${MOONSHINE_DIR:-$IISWC_ROOT/out/moonshine}"
N="${1:-4}"
NO="${2:-0}"
D="$MOONSHINE_DIR/librispeech"; mkdir -p "$D"
REPO=openslr/librispeech_asr
REV=71cacbfb7e2354c4226d01e70d77d5fca3d04ba1

# shard -> sha256 (the dataset server's x-linked-etag at $REV, checked again after download)
SHA=(
  "3098c6e44d1d49f8c62bd123775f1c492bda2cabd80f3ee70fe7800572371401"
  "011cb76e296b2650bab3ea54044c57d10293dadb05e9e96605b37c88e4bc89bd"
  "b836ad8f9b43b2d303d81bc91201d6b0b10806ee4407c4ab06af9ddfa963bb99"
  "f13450f202d20681ee89aab48a6b59f2dc36d5f7e1e9c36c59ba3cfae15d0049"
  "89d08c9934fd32dc97147f3177392c1e734bb5d13c60c967523d0ba05397c5f6"
  "fbc85ec6ddd6a0caced0e9978586f6b174392e68d09adc64a10a89679ecb713a"
  "61cffc43952f370a65d0855e3260de4d81815fd02eac8b33f3c118fad8eebda8"
  "cfb26522a7e15cc425714df94e874d347f5dbb3f603e348611989522d9833ca7"
  "e41ba4f3ca0b0de4b83e343f9d6cf90418f7bb9c80ebf1a8e663d8f46e5f1c1e"
  "ed130ea9bdaaf8d188eab0521cdd4b8aa5d507b0c3f8e8df5d90db2d10b4f5f1"
  "a6feec58aaa6a7e4247deb3bc3f10fedbc2e6aec2840dda663dd9ecc808575fc"
  "3196ef576660eb62055df0b1737c1e4866f1789176acc7d85a928aeb16b07f03"
  "33b99d9a1e9ddcf411cad97379fb74d5e53c0a8b5846d6c2fe06fb1d87166bcf"
  "5d25b68b6600db0dcf975c1cae12e3892a2ade5358731a275a2358637c2c0bd0"
)
# train-other-500, shards 0000..0007 (about 150 h)
SHA_OTHER=(
  "bc919b3e2e4c486972a75337534247e8452dee1ff1b676943876b9bb71d61c1f"
  "cb632fd057981bf6c610a40333653a2e6d3824408e5af76d4493ef4938d2de17"
  "24b6d56d19cda390025e8f6eb69871f169459827ebef30f2e66a1901b1f30bdf"
  "1ced8d04e637dd01778c3f28b33934f0b77977b2f5a107bba62f286ce01c0722"
  "a0b9ff40cd93b4bcbd25e6ff302ea79bd0f043291645a2c135fdb271d410ad86"
  "775fb79b82d81f4753f64c6c1f7869511532823ca008c7864c7c1345486a2f3f"
  "d08966a310f16045ade99fd81c402e6368a2444ece6cf89bbece57b1e5f6f53e"
  "3004f4af1f1b7582211f0063e5059110f0ac7729151559cc023f7977669be66a"
)
[ "$N" -le "${#SHA[@]}" ] || { echo "only ${#SHA[@]} shards are pinned here" >&2; exit 1; }

for ((i = 0; i < N; i++)); do
  s=$(printf "%04d" "$i")
  dst="$D/train_clean_100_$s.parquet"
  if [ -f "$dst" ] && echo "${SHA[$i]}  $dst" | sha256sum -c --status; then echo "  ok      $(basename "$dst")"; continue; fi
  echo "  fetch   $REPO@$REV/all/train.clean.100/$s.parquet"
  curl -fsSL --retry 3 -o "$dst.part" \
    "https://huggingface.co/datasets/$REPO/resolve/$REV/all/train.clean.100/$s.parquet"
  echo "${SHA[$i]}  $dst.part" | sha256sum -c --status || { echo "SHA256 MISMATCH $s" >&2; rm -f "$dst.part"; exit 1; }
  mv "$dst.part" "$dst"; echo "  ok      $(basename "$dst")"
done
for ((i = 0; i < NO; i++)); do
  s=$(printf "%04d" "$i")
  dst="$D/train_other_500_$s.parquet"
  if [ -f "$dst" ] && echo "${SHA_OTHER[$i]}  $dst" | sha256sum -c --status; then echo "  ok      $(basename "$dst")"; continue; fi
  echo "  fetch   $REPO@$REV/all/train.other.500/$s.parquet"
  curl -fsSL --retry 3 -o "$dst.part" \
    "https://huggingface.co/datasets/$REPO/resolve/$REV/all/train.other.500/$s.parquet"
  echo "${SHA_OTHER[$i]}  $dst.part" | sha256sum -c --status || { echo "SHA256 MISMATCH other $s" >&2; rm -f "$dst.part"; exit 1; }
  mv "$dst.part" "$dst"; echo "  ok      $(basename "$dst")"
done
echo "train shards in $D"
