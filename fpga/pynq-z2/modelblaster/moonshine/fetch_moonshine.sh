#!/usr/bin/env bash
# Fetch everything the Moonshine encoder work needs, at pinned revisions, and CHECK it.
#
#   fpga/pynq-z2/modelblaster/moonshine/fetch_moonshine.sh            # into $MOONSHINE_DIR
#
# $MOONSHINE_DIR defaults to $IISWC_ROOT/out/moonshine (git-ignored).  Nothing here is
# committed: the checkpoint is 108 MB and not ours to redistribute.
#
#   1. UsefulSensors/moonshine-tiny @ 390624ed: model.safetensors, config.json,
#      generation_config.json, preprocessor_config.json, tokenizer.json.  Every file's
#      sha256 is checked; a mismatch deletes the file and fails.
#   2. hf-internal-testing/librispeech_asr_dummy @ 5be91486: the one parquet shard (73
#      dev-clean utterances), sha256-checked, decoded with ffmpeg to 16 kHz float32 and
#      written to speech.npz.  Decoding needs pyarrow; when the Python in use has none, it
#      is installed with `pip --target $MOONSHINE_DIR/pylib` -- NEVER into the shared env.
#   3. transformers 4.48.0 (the version whose modeling_moonshine.py the port is checked
#      against, and the first with Moonshine at all) into the same isolated pylib, --no-deps.
#      Only moonshine_enc.py --check-hf and host_fidelity.py import it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IISWC_ROOT="${IISWC_ROOT:-$(cd "$HERE/../../../.." && pwd)}"
MOONSHINE_DIR="${MOONSHINE_DIR:-$IISWC_ROOT/out/moonshine}"
PY="${PY:-$IISWC_ROOT/zephyr-chipyard-sw/tools/miniforge3/envs/zephyr/bin/python}"
[ -x "$PY" ] || PY=python3
mkdir -p "$MOONSHINE_DIR"

CKPT_REPO=UsefulSensors/moonshine-tiny
CKPT_REV=390624ed33d594443aa4aa221f5b9f283b545b5a
SPEECH_REPO=hf-internal-testing/librispeech_asr_dummy
SPEECH_REV=5be91486e11a2d616f4ec5db8d3fd248585ac07a

fetch() {  # repo_type repo rev path dest sha256
  local url
  if [ "$1" = dataset ]; then url="https://huggingface.co/datasets/$2/resolve/$3/$4"
  else url="https://huggingface.co/$2/resolve/$3/$4"; fi
  if [ -f "$5" ] && echo "$6  $5" | sha256sum -c --status; then
    echo "  ok      $(basename "$5")"; return 0
  fi
  echo "  fetch   $url"
  curl -fsSL --retry 3 -o "$5.part" "$url"
  if ! echo "$6  $5.part" | sha256sum -c --status; then
    echo "  SHA256 MISMATCH for $4: got $(sha256sum "$5.part" | cut -d' ' -f1), want $6" >&2
    rm -f "$5.part"; exit 1
  fi
  mv "$5.part" "$5"; echo "  ok      $(basename "$5")"
}

echo "checkpoint $CKPT_REPO @ $CKPT_REV -> $MOONSHINE_DIR"
fetch model "$CKPT_REPO" "$CKPT_REV" model.safetensors "$MOONSHINE_DIR/model.safetensors" \
  867cd2215804859c55aa972d740bd5002be149b4e7526328c895d2408848c736
fetch model "$CKPT_REPO" "$CKPT_REV" config.json "$MOONSHINE_DIR/config.json" \
  47a43777a14e17b1ffd5f533e021d4d18c3c475cbb96de0947ce409e16444ded
fetch model "$CKPT_REPO" "$CKPT_REV" generation_config.json "$MOONSHINE_DIR/generation_config.json" \
  a8e1437432c3ba7d0fca84ced5b3a254bf0c42b8e75fc336497cdcb56675e303
fetch model "$CKPT_REPO" "$CKPT_REV" preprocessor_config.json "$MOONSHINE_DIR/preprocessor_config.json" \
  99272fe8ccfab114b68b478681ea47ee3a1ce62bb788cb92dd6e4f69fb1f1da2
fetch model "$CKPT_REPO" "$CKPT_REV" tokenizer.json "$MOONSHINE_DIR/tokenizer.json" \
  6579793438bc4fbafffacf699169ff53e3769c5a0a0f5e71cdee8853e8130deb

echo "speech $SPEECH_REPO @ $SPEECH_REV"
PARQ="$MOONSHINE_DIR/librispeech_dummy_clean_validation.parquet"
fetch dataset "$SPEECH_REPO" "$SPEECH_REV" clean/validation-00000-of-00001.parquet "$PARQ" \
  4e69a06fa5edc90921e5e7e39a7084881f8b3ed9c805c574f4f39c6fde27c603

PYLIB="$MOONSHINE_DIR/pylib"
need_pip=()
PYTHONPATH="$PYLIB${PYTHONPATH:+:$PYTHONPATH}" "$PY" -c "import pyarrow" 2>/dev/null || need_pip+=(pyarrow)
PYTHONPATH="$PYLIB${PYTHONPATH:+:$PYTHONPATH}" "$PY" -c "
import transformers, sys
sys.exit(0 if transformers.__version__ == '4.48.0' else 1)" 2>/dev/null || need_pip+=(transformers==4.48.0)
if [ ${#need_pip[@]} -gt 0 ]; then
  echo "isolated pip --target $PYLIB: ${need_pip[*]}"
  "$PY" -m pip install -q --no-deps --target "$PYLIB" "${need_pip[@]}"
fi

if [ ! -f "$MOONSHINE_DIR/speech.npz" ]; then
  command -v ffmpeg >/dev/null || { echo "ffmpeg is required to decode the flac clips" >&2; exit 1; }
  PYTHONPATH="$PYLIB${PYTHONPATH:+:$PYTHONPATH}" "$PY" - "$PARQ" "$MOONSHINE_DIR/speech.npz" <<'PY'
import subprocess, sys
import numpy as np
import pyarrow.parquet as pq
rows = pq.read_table(sys.argv[1]).to_pylist()
rows.sort(key=lambda r: r["id"])
out = {"n": np.int64(len(rows)),
       "ids": np.array([r["id"] for r in rows]),
       "texts": np.array([r["text"] for r in rows])}
for i, r in enumerate(rows):
    pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "s16le", "-ac", "1",
                          "-ar", "16000", "pipe:1"], input=r["audio"]["bytes"],
                         capture_output=True, check=True).stdout
    out[f"wav{i}"] = (np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0)
np.savez(sys.argv[2], **out)
print(f"  decoded {len(rows)} utterances -> {sys.argv[2]}")
PY
else
  echo "  ok      speech.npz"
fi
echo "MOONSHINE_DIR=$MOONSHINE_DIR"
