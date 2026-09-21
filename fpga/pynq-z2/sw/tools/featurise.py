#!/usr/bin/env python3
"""Build a keyword-spotting training set with THE SAME front end the board runs.

    python3 featurise.py --root /path/to/speech_commands_v2 --out /path/to/feat

The point of this file is that it does not reimplement anything.  It compiles
fpga/pynq-z2/sw/audio_fe.c for the host as a shared object and calls fe_mfcc_clip()
through ctypes, so the features a model is trained on are produced by the same C, the
same tables and the same fixed-point rounding the Zephyr image executes.  The usual
train/inference front-end mismatch -- a librosa MFCC in training against a hand-written
one on the device -- cannot happen here by construction.

One mismatch does remain and is not fixable in software: the corpus is sampled at
exactly 16000 Hz and this board's PDM decimator produces 15993.859 Hz (MICROPHONE.md
3.2).  That is 0.038 % -- about a quarter of a mel bin at the top of the band -- and it
is recorded rather than corrected.

Emits, under --out:
    train_x.npy / val_x.npy / test_x.npy   int8  [N, 1, nframes, ndct]
    train_y.npy / ...                      int64 [N]
    meta.json                              geometry, the Q8->int8 map, label names
"""
from __future__ import annotations

import argparse, ctypes, hashlib, json, os, pathlib, re, subprocess, sys, wave
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
SW = HERE.parent

# MLPerf Tiny's 12 classes: ten words, plus silence and everything else.
WORDS = ["yes", "no", "up", "down", "left", "right", "on", "off", "stop", "go"]
LABELS = ["_silence_", "_unknown_"] + WORDS
CLIP_SAMPLES = 16000


def build_lib(geom: str, arith: str, tmp: pathlib.Path) -> ctypes.CDLL:
    """Compile audio_fe.c for the host.  arith='int' is what the board runs."""
    geo = {"asr": (512, 400, 160), "kws": (512, 480, 320)}[geom]
    so = tmp / f"libaudiofe_{geom}_{arith}.so"
    defs = [f"-DFE_NFFT={geo[0]}", f"-DFE_FRAME_LEN={geo[1]}", f"-DFE_HOP_LEN={geo[2]}"]
    defs += {"int": ["-DFE_ARITH_INT=1", "-DMB_PEXT_HW=0"],
             "float": ["-DFE_ARITH_FLOAT=1"]}[arith]
    cmd = ["gcc", "-O2", "-fPIC", "-shared", "-I", str(SW), *defs,
           str(SW / "audio_fe.c"), str(SW / f"audio_fe_tables_{geom}.c"),
           "-o", str(so), "-lm"]
    subprocess.run(cmd, check=True)
    lib = ctypes.CDLL(str(so))
    lib.fe_nframes.restype = ctypes.c_int
    lib.fe_mfcc_clip.restype = ctypes.c_int
    return lib


def which_set(rel: str, val_pct=10.0, test_pct=10.0) -> str:
    """The upstream partition rule, verbatim in intent.

    Google's which_set() hashes the speaker id -- everything before '_nohash_' -- so
    every utterance by one speaker lands in one split.  Reimplementing this correctly
    matters more than it looks: partitioning by FILE instead leaks a speaker across
    train and test and inflates accuracy by several points.
    """
    base = os.path.basename(rel)
    name = re.sub(r"_nohash_.*$", "", base)
    h = hashlib.sha1(name.encode()).hexdigest()
    MAX = 2 ** 27 - 1
    pct = (int(h, 16) % (MAX + 1)) * (100.0 / MAX)
    if pct < val_pct:
        return "val"
    if pct < val_pct + test_pct:
        return "test"
    return "train"


# This microphone's measured noise floor is -60.9 dBFS, rms 29.6 counts
# (MICROPHONE.md section 8).  Short clips are padded to that, NOT to zeros: a zero
# region drives every mel band to the log floor, which is a value no microphone ever
# produces, so a model trained on zero padding learns a feature that cannot occur at
# inference.  Deterministic per file, so the training set is reproducible.
BOARD_NOISE_RMS = 29.6


def read_wav(path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        assert w.getsampwidth() == 2 and w.getnchannels() == 1, path
        d = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    if len(d) < CLIP_SAMPLES:
        seed = int(hashlib.sha1(os.path.basename(str(path)).encode()).hexdigest()[:8], 16)
        rng = np.random.default_rng(seed)
        pad = np.round(rng.standard_normal(CLIP_SAMPLES - len(d)) * BOARD_NOISE_RMS)
        d = np.concatenate([d, np.clip(pad, -32768, 32767).astype(np.int16)])
    return d[:CLIP_SAMPLES].copy()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--geom", default="kws", choices=["asr", "kws"])
    ap.add_argument("--ndct", type=int, default=10)
    ap.add_argument("--nmel", type=int, default=40)
    ap.add_argument("--logmel", action="store_true",
                    help="emit the 40 log-mel bands instead of 10 MFCC")
    ap.add_argument("--unknown-per-split", type=int, default=4000,
                    help="how many _unknown_ clips to keep; the corpus has ~25 non-target "
                         "words and taking all of them makes the class 2/3 of the set")
    ap.add_argument("--silence-per-split", type=int, default=2000)
    ap.add_argument("--limit", type=int, default=0, help="debug: cap files scanned")
    ap.add_argument("--jobs", type=int, default=max(1, os.cpu_count() // 2))
    a = ap.parse_args()

    root = pathlib.Path(a.root)
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    tmp = out / "_build"; tmp.mkdir(exist_ok=True)
    lib = build_lib(a.geom, "int", tmp)
    ncoef = a.nmel if a.logmel else a.ndct
    nframes = lib.fe_nframes(CLIP_SAMPLES)
    print(f"[featurise] geometry {a.geom}: {nframes} frames x {ncoef} coefficients")

    # ---- enumerate ----------------------------------------------------------------
    files = []            # (path, label_index, split)
    for d in sorted(p for p in root.iterdir() if p.is_dir()):
        if d.name == "_background_noise_":
            continue
        li = LABELS.index(d.name) if d.name in LABELS else LABELS.index("_unknown_")
        for w in sorted(d.glob("*.wav")):
            files.append((w, li, which_set(f"{d.name}/{w.name}")))
    if a.limit:
        files = files[:a.limit]
    print(f"[featurise] {len(files)} wav files under {root}")

    # Cap _unknown_ per split. Deterministic: sorted order, strided take.
    unk = LABELS.index("_unknown_")
    keep, bysplit = [], {"train": [], "val": [], "test": []}
    for f in files:
        (bysplit[f[2]] if f[1] == unk else keep).append(f)
    for sp, lst in bysplit.items():
        n = min(len(lst), a.unknown_per_split if sp == "train" else a.unknown_per_split // 5)
        step = max(1, len(lst) // n) if n else 1
        keep += lst[::step][:n]
    files = keep
    print(f"[featurise] {len(files)} after capping _unknown_")

    # ---- featurise ----------------------------------------------------------------
    scratch = ctypes.create_string_buffer(1 << 16)     # >= sizeof(struct fe_scratch)
    buf = (ctypes.c_int16 * (nframes * ncoef))()
    X = {"train": [], "val": [], "test": []}
    Y = {"train": [], "val": [], "test": []}
    for i, (path, li, sp) in enumerate(files):
        pcm = read_wav(path)
        n = lib.fe_mfcc_clip(pcm.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)),
                             CLIP_SAMPLES, scratch, buf, 0 if a.logmel else 1)
        assert n == nframes, (n, nframes)
        X[sp].append(np.frombuffer(buf, dtype=np.int16).reshape(nframes, ncoef).copy())
        Y[sp].append(li)
        if i % 5000 == 0:
            print(f"  {i}/{len(files)}", flush=True)

    # ---- silence ------------------------------------------------------------------
    # Not zeros: a zero clip has every mel band at the log floor, which is a value no
    # microphone ever produces, and a model trained on it learns a feature that cannot
    # occur at inference. The corpus ships _background_noise_ for exactly this.
    noise = []
    nd = root / "_background_noise_"
    if nd.is_dir():
        for w in sorted(nd.glob("*.wav")):
            with wave.open(str(w), "rb") as h:
                noise.append(np.frombuffer(h.readframes(h.getnframes()), dtype="<i2"))
    if noise:
        rng = np.random.default_rng(1234)
        for sp, n in (("train", a.silence_per_split),
                      ("val", a.silence_per_split // 5),
                      ("test", a.silence_per_split // 5)):
            for _ in range(n):
                src = noise[rng.integers(len(noise))]
                o = rng.integers(0, len(src) - CLIP_SAMPLES)
                g = rng.uniform(0.0, 1.0)
                pcm = np.clip(src[o:o + CLIP_SAMPLES].astype(np.float32) * g,
                              -32768, 32767).astype(np.int16)
                lib.fe_mfcc_clip(pcm.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)),
                                 CLIP_SAMPLES, scratch, buf, 0 if a.logmel else 1)
                X[sp].append(np.frombuffer(buf, dtype=np.int16).reshape(nframes, ncoef).copy())
                Y[sp].append(LABELS.index("_silence_"))
    else:
        print("[featurise] WARN: no _background_noise_ -- no silence class")

    # ---- the Q8 -> int8 map -------------------------------------------------------
    # PER COEFFICIENT, not one pair for the whole tensor.  The MFCC coefficients do not
    # share a dynamic range -- c0 spans ~46,000 Q8 and c9 spans ~3,400 -- so a single
    # (offset, shift) sized for c0 quantises c1..c9 to about sixteen levels and throws
    # away most of what the model needs.  Twenty integers on the device, one subtract
    # and one shift per value, which is what a shared map costs anyway.
    tr = np.stack(X["train"]).astype(np.int32)          # [N, frames, coef]
    off = np.zeros(ncoef, dtype=np.int32)
    shift = np.zeros(ncoef, dtype=np.int32)
    for k in range(ncoef):
        lo, hi = np.percentile(tr[:, :, k], 0.5), np.percentile(tr[:, :, k], 99.5)
        off[k] = int(round((lo + hi) / 2))
        span = max(1.0, (hi - lo) / 2)
        shift[k] = max(0, int(np.ceil(np.log2(span / 127.0))))
        print(f"[featurise]   coef {k:2d}: p0.5={lo:8.0f} p99.5={hi:8.0f} "
              f"off={off[k]:7d} shift={shift[k]} "
              f"(1 step = {2**shift[k] * 3.0103 / 256.0:.2f} dB)")

    meta = {"geometry": a.geom, "nframes": nframes, "ncoef": ncoef,
            "feature": "logmel" if a.logmel else "mfcc",
            "labels": LABELS,
            "off_q8": off.tolist(), "shift": shift.tolist(),
            "dct_row_scale": [0.25, 1.0],
            "board_noise_rms": BOARD_NOISE_RMS,
            "sample_rate_corpus": 16000, "sample_rate_board": 15993.859,
            "clip_samples": CLIP_SAMPLES,
            "counts": {k: len(v) for k, v in Y.items()}}
    for sp in ("train", "val", "test"):
        x = np.stack(X[sp]).astype(np.int32)
        q = np.clip((x - off[None, None, :]) >> shift[None, None, :],
                    -127, 127).astype(np.int8)
        np.save(out / f"{sp}_x.npy", q[:, None, :, :])
        np.save(out / f"{sp}_y.npy", np.array(Y[sp], dtype=np.int64))
        print(f"[featurise] {sp}: {q.shape[0]} clips, "
              f"clipped {(np.abs((x - off[None, None, :]) >> shift[None, None, :]) > 127).mean() * 100:.2f}% of values, "
              f"saturated-at-int16 {(np.abs(x) >= 32767).mean() * 100:.3f}%")
    json.dump(meta, open(out / "meta.json", "w"), indent=2)
    print("[featurise] wrote", out)


if __name__ == "__main__":
    main()
