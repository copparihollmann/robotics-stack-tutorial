#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The TRAINING split for the model-side study, and the vocabulary the model actually emits on it.

librispeech_sets.py's two sets are for SELECTING (dev-clean) and REPORTING (test-clean) and must
never be trained on, nor used to choose a kept vocabulary that is then reported on test.  This
file decodes the LibriSpeech train-clean-100 shards that model_fetch_train.sh pins into a
memory-mappable cache, and -- because the reference transcripts are ALL UPPERCASE and Moonshine
emits cased, punctuated text, so the reference tokenisation is NOT the emitted one -- collects
the rows the float model emits when it transcribes that audio.

    python3 model_trainset.py --decode                       # parquet -> train_clean_100.{f32,npz}
    PYTHONPATH=$MOONSHINE_DIR/pylib python3 model_trainset.py --emit --json model_trainvocab.json

The cache is <librispeech>/train_clean_100.f32 (raw float32 PCM, np.memmap) plus train_clean_100.npz
(ids, texts, lens, offs).  Both are git-ignored under out/.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import glob
import json
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import librispeech_sets as ls  # noqa: E402
import moonshine_enc as me  # noqa: E402

STEM = "train_clean_100"
# the long QAT run of MOONSHINE_MODEL.md section 3.3.1 uses both splits in one cache
GLOBS = {"train_clean_100": ("train_clean_100_*.parquet",),
         "train_big": ("train_clean_100_*.parquet", "train_other_500_*.parquet")}


def paths(stem: str = STEM):
    d = ls.lsdir()
    return d / f"{stem}.f32", d / f"{stem}.npz"


def decode(stem: str = STEM):
    import pyarrow.parquet as pq
    pcm_p, meta_p = paths(stem)
    if pcm_p.exists() and meta_p.exists():
        print(f"  ok      {pcm_p.name}")
        return
    shards = sorted(f for g in GLOBS[stem] for f in glob.glob(str(ls.lsdir() / g)))
    if not shards:
        raise SystemExit("no train shards: run model_fetch_train.sh first")
    ids, texts, lens = [], [], []
    with open(str(pcm_p) + ".part", "wb") as fo:
        for sh in shards:
            rows = pq.read_table(sh, columns=["id", "speaker_id", "text", "audio"]).to_pylist()
            rows.sort(key=lambda r: r["id"])
            with cf.ThreadPoolExecutor(max_workers=32) as ex:
                wavs = list(ex.map(lambda r: ls._decode_one(r["audio"]["bytes"]), rows))
            for r, w in zip(rows, wavs):
                ids.append(r["id"]); texts.append(r["text"]); lens.append(len(w))
                fo.write(np.ascontiguousarray(w, dtype=np.float32).tobytes())
            print(f"  {os.path.basename(sh)}: {len(rows)} utterances, "
                  f"{sum(len(w) for w in wavs)/me.SR/3600:.2f} h")
    os.replace(str(pcm_p) + ".part", str(pcm_p))
    lens = np.asarray(lens, dtype=np.int64)
    np.savez(str(meta_p), ids=np.asarray(ids), texts=np.asarray(texts), lens=lens,
             offs=np.concatenate([[0], np.cumsum(lens)[:-1]]))
    print(f"  wrote {pcm_p} ({pcm_p.stat().st_size/1e9:.2f} GB) and {meta_p}")


class Train:
    """mmap-backed access to the decoded train split."""

    def __init__(self, stem: str = STEM):
        pcm_p, meta_p = paths(stem)
        z = np.load(str(meta_p), allow_pickle=False)
        self.ids = [str(s) for s in z["ids"]]
        self.texts = [str(s) for s in z["texts"]]
        self.lens, self.offs = z["lens"], z["offs"]
        self.pcm = np.memmap(str(pcm_p), dtype=np.float32, mode="r")   # raw float32 PCM

    def __len__(self):
        return len(self.ids)

    def wav(self, i: int) -> np.ndarray:
        return np.asarray(self.pcm[self.offs[i]:self.offs[i] + self.lens[i]], dtype=np.float32)

    def hours(self) -> float:
        return float(self.lens.sum()) / me.SR / 3600.0


def emit(json_path: str, limit: int = 0, batch: int = 16, max_new: int = 96):
    """Transcribe the train split with the float model and count which lm_head rows it emits.
    This -- not the uppercase reference text -- is what an English demo's vocabulary looks like."""
    import torch
    import model_vocab as mv
    import fq
    torch.set_grad_enabled(False)
    dev = fq.device()
    model, tok = mv.load_hf(dev)
    tr = Train()
    idx = list(range(len(tr)))
    if limit:
        idx = ls.even(idx, limit)
    cnt = np.zeros(model.config.vocab_size, dtype=np.int64)
    utt_rows = []
    t0 = time.time()
    # batch utterances of similar length so the padding is not the cost
    idx.sort(key=lambda i: int(tr.lens[i]))
    for b in range(0, len(idx), batch):
        chunk = idx[b:b + batch]
        n = int(max(tr.lens[i] for i in chunk))
        n = max(int(np.ceil(n / 384.0) * 384), 8000)
        x = np.zeros((len(chunk), n), dtype=np.float32)
        for j, i in enumerate(chunk):
            w = tr.wav(i)
            x[j, :len(w)] = w[:n]
        xv = torch.from_numpy(x).to(dev)
        enc = model.model.encoder(xv)
        gen = model.generate(encoder_outputs=enc, max_new_tokens=max_new, do_sample=False,
                             num_beams=1)
        for r in gen.tolist():
            rows = [t for t in r if t not in mv.SPECIAL]
            cnt[np.asarray(rows, dtype=np.int64)] += 1 if rows else 0
            utt_rows.append(len(rows))
        if b % (batch * 100) == 0:
            print(f"  {b}/{len(idx)}  distinct so far {int((cnt>0).sum())}  "
                  f"({time.time()-t0:.0f} s)", flush=True)
    order = np.argsort(-cnt)
    tot = int(cnt.sum())
    cum = np.cumsum(cnt[order]) / max(tot, 1)
    out = {"what": "lm_head rows the float model EMITS on LibriSpeech train-clean-100 (disjoint "
                   "from dev-clean and test-clean), the selection source for a pruned vocabulary",
           "utterances": len(idx), "hours": tr.hours() * len(idx) / max(len(tr), 1),
           "tokens_emitted": tot, "distinct_rows": int((cnt > 0).sum()),
           "tokens_per_utterance_mean": float(np.mean(utt_rows)),
           "max_new_tokens": max_new,
           "coverage_by_top_m": {str(m): float(cum[min(m, len(cum)) - 1])
                                 for m in (256, 512, 1024, 2048, 3072, 4096, 6144, 8192)},
           "counts_npy": str(ls.lsdir() / "model_train_row_counts.npy")}
    np.save(out["counts_npy"], cnt)
    json.dump(out, open(json_path, "w"), indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "coverage_by_top_m"}, indent=1))
    print("coverage:", out["coverage_by_top_m"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--decode", action="store_true")
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--json", default="model_trainvocab.json")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--stem", default=STEM, choices=sorted(GLOBS))
    a = ap.parse_args()
    if a.decode:
        decode(a.stem)
    if a.emit:
        emit(a.json, a.limit)


if __name__ == "__main__":
    main()
