#!/usr/bin/env bash
# Fetch and decode the multi-speaker fidelity sets (librispeech_sets.py): LibriSpeech
# test-clean and dev-clean, one parquet shard each, pinned by revision and sha256.
#
#   fpga/pynq-z2/modelblaster/moonshine/fetch_librispeech.sh     # into $MOONSHINE_DIR/librispeech
#
# 692 MB of parquet, git-ignored under out/.  Decoding needs ffmpeg and pyarrow (fetch_moonshine.sh
# puts pyarrow in $MOONSHINE_DIR/pylib).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IISWC_ROOT="${IISWC_ROOT:-$(cd "$HERE/../../../.." && pwd)}"
MOONSHINE_DIR="${MOONSHINE_DIR:-$IISWC_ROOT/out/moonshine}"
PY="${PY:-$IISWC_ROOT/zephyr-chipyard-sw/tools/miniforge3/envs/zephyr/bin/python}"
[ -x "$PY" ] || PY=python3
D="$MOONSHINE_DIR/librispeech"; mkdir -p "$D"
REPO=openslr/librispeech_asr
REV=71cacbfb7e2354c4226d01e70d77d5fca3d04ba1

fetch() {  # path dest sha256
  if [ -f "$2" ] && echo "$3  $2" | sha256sum -c --status; then echo "  ok      $(basename "$2")"; return 0; fi
  echo "  fetch   $REPO@$REV/$1"
  curl -fsSL --retry 3 -o "$2.part" "https://huggingface.co/datasets/$REPO/resolve/$REV/$1"
  echo "$3  $2.part" | sha256sum -c --status || { echo "SHA256 MISMATCH for $1" >&2; rm -f "$2.part"; exit 1; }
  mv "$2.part" "$2"; echo "  ok      $(basename "$2")"
}
fetch all/test.clean/0000.parquet "$D/test_clean.parquet" 7113aa4c3cf963fb54697145719a7725f984c8836d1c494a554cbb9f1a017df0
fetch all/validation.clean/0000.parquet "$D/dev_clean.parquet" c816e936fed8b83d5e3de28795bff1bcd3b46b3f1a5815bad4395d20186a9770
MOONSHINE_DIR="$MOONSHINE_DIR" PYTHONPATH="$MOONSHINE_DIR/pylib${PYTHONPATH:+:$PYTHONPATH}" \
  "$PY" "$HERE/librispeech_sets.py" --decode --summary
