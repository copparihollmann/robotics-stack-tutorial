#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The multi-speaker fidelity sets for Moonshine's int8 encoder: LibriSpeech test-clean and
dev-clean, pinned, decoded once, split once.

host_fidelity.py's first check used hf-internal-testing/librispeech_asr_dummy: ONE speaker, 16
whole-transcript utterances.  That is a smoke test.  These are the sets the fidelity numbers
are reported on from ROCC_DECOUPLED.md section 8.12 on:

  EVAL   test-clean, EVERY utterance whose audio fits the 4.0 s window whole (so its
         LibriSpeech transcript is the reference for the whole window).  Never used to choose
         anything.
  TUNE   dev-clean utterances that fit 4.0 s whole: used to choose calibration policies,
         migration strengths and which tensors get more bits.  Disjoint from CAL.
  CAL    dev-clean utterances longer than 4.0 s, centre-cropped, evenly spaced over the
         id-sorted list (ids sort by speaker, so across all 40 dev-clean speakers).

Source: openslr/librispeech_asr @ 71cacbfb7e2354c4226d01e70d77d5fca3d04ba1,
  all/test.clean/0000.parquet        sha256 7113aa4c...017df0 (2,620 utterances, 40 speakers)
  all/validation.clean/0000.parquet  sha256 c816e936...186a9770 (2,703 utterances, 40 speakers)
fetched by fetch_librispeech.sh into $MOONSHINE_DIR/librispeech/ (git-ignored).

    python3 librispeech_sets.py --decode      # parquet -> test_clean.npz, dev_clean.npz
    python3 librispeech_sets.py --summary     # counts per set
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import pathlib
import subprocess
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import moonshine_enc as me  # noqa: E402

SETS = {"test_clean": "test_clean.parquet", "dev_clean": "dev_clean.parquet"}


def lsdir() -> pathlib.Path:
    return me.moonshine_dir() / "librispeech"


def _decode_one(b: bytes) -> np.ndarray:
    pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "s16le", "-ac", "1",
                          "-ar", "16000", "pipe:1"], input=b, capture_output=True, check=True).stdout
    return np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0


def decode(name: str) -> pathlib.Path:
    import pyarrow.parquet as pq
    src = lsdir() / SETS[name]
    dst = lsdir() / f"{name}.npz"
    if dst.exists():
        return dst
    rows = pq.read_table(str(src), columns=["id", "speaker_id", "text", "audio"]).to_pylist()
    rows.sort(key=lambda r: r["id"])
    with cf.ThreadPoolExecutor(max_workers=32) as ex:
        wavs = list(ex.map(lambda r: _decode_one(r["audio"]["bytes"]), rows))
    lens = np.array([len(w) for w in wavs], dtype=np.int64)
    offs = np.concatenate([[0], np.cumsum(lens)[:-1]])
    np.savez(str(dst), ids=np.array([r["id"] for r in rows]), texts=np.array([r["text"] for r in rows]),
             speakers=np.array([r["speaker_id"] for r in rows], dtype=np.int64),
             lens=lens, offs=offs, pcm=np.concatenate(wavs).astype(np.float32))
    print(f"  decoded {len(rows)} utterances -> {dst}")
    return dst


class Corpus:
    def __init__(self, name: str):
        z = np.load(str(lsdir() / f"{name}.npz"), allow_pickle=False)
        self.name = name
        self.ids = [str(s) for s in z["ids"]]
        self.texts = [str(s) for s in z["texts"]]
        self.speakers = [int(s) for s in z["speakers"]]
        self.lens, self.offs, self.pcm = z["lens"], z["offs"], z["pcm"]

    def wav(self, i: int) -> np.ndarray:
        return self.pcm[self.offs[i]:self.offs[i] + self.lens[i]]

    def short(self) -> list:
        return [i for i in range(len(self.ids)) if self.lens[i] <= me.N_SAMPLES]

    def long(self) -> list:
        return [i for i in range(len(self.ids)) if self.lens[i] > me.N_SAMPLES]


def even(xs: list, n: int) -> list:
    if n >= len(xs):
        return list(xs)
    return [xs[j] for j in np.unique(np.round(np.linspace(0, len(xs) - 1, n)).astype(int))]


def eval_set(n: int | None = None) -> tuple:
    c = Corpus("test_clean")
    idx = c.short()
    if n:
        idx = even(idx, n)
    return c, idx


def tune_set(n: int | None = None) -> tuple:
    c = Corpus("dev_clean")
    idx = c.short()
    if n:
        idx = even(idx, n)
    return c, idx


def cal_set(n: int = 64) -> tuple:
    c = Corpus("dev_clean")
    return c, even(c.long(), n)


def summary() -> dict:
    out = {}
    for label, (c, idx) in (("eval(test-clean <=4s)", eval_set()), ("tune(dev-clean <=4s)", tune_set()),
                            ("cal(dev-clean >4s, 64 windows)", cal_set(64))):
        out[label] = {"utterances": len(idx), "speakers": len({c.speakers[i] for i in idx}),
                      "words": int(sum(len(c.texts[i].split()) for i in idx)),
                      "seconds": float(sum(min(c.lens[i], me.N_SAMPLES) for i in idx) / me.SR)}
    return out


REVISION = "openslr/librispeech_asr@71cacbfb7e2354c4226d01e70d77d5fca3d04ba1"
SHA256 = {"all/test.clean/0000.parquet": "7113aa4c3cf963fb54697145719a7725f984c8836d1c494a554cbb9f1a017df0",
          "all/validation.clean/0000.parquet": "c816e936fed8b83d5e3de28795bff1bcd3b46b3f1a5815bad4395d20186a9770"}


def manifest() -> dict:
    """The pinned source and every utterance id in every set, so a set can be rebuilt and
    checked without re-running the split."""
    out = {"source": REVISION, "sha256": SHA256, "window_s": me.WINDOW_S, "summary": summary(), "sets": {}}
    for label, (c, idx) in (("eval_test_clean_le4s", eval_set()), ("tune_dev_clean_le4s", tune_set()),
                            ("cal_dev_clean_gt4s_64", cal_set(64))):
        out["sets"][label] = [c.ids[i] for i in idx]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--decode", action="store_true")
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--manifest", help="write the pinned manifest (source, sha256, every set's ids) here")
    a = ap.parse_args()
    if a.manifest:
        json.dump(manifest(), open(a.manifest, "w"), indent=1)
        print(f"wrote {a.manifest}")
    if a.decode:
        for name in SETS:
            decode(name)
    if a.summary:
        print(json.dumps(summary(), indent=1))


if __name__ == "__main__":
    main()
