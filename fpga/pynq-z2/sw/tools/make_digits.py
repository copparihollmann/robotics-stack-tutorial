#!/usr/bin/env python3
"""Build a CONNECTED-DIGIT corpus out of Speech Commands, featurised by the board's front end.

    python3 make_digits.py --root /path/to/speech_commands_v2 --out /path/to/feat_digits

Isolated-word classification (Labs B17/B18) is not transcription: the output is one of
twelve slots. This makes the smallest task that genuinely is -- a variable-length digit
string, decoded with CTC, scored with edit distance -- out of audio that is real:
utterances are built by concatenating REAL Speech Commands recordings of `zero`..`nine`,
with real silence between them and real background noise underneath.

Two things are deliberate and both matter for the number this produces being honest:

  * THE SPLIT IS BY SPEAKER, not by utterance. Google's which_set() hashes the speaker id
    out of the filename, so no voice appears in both training and test. Concatenating
    clips first and splitting afterwards would leak every speaker into every split and
    the word error rate would be fiction.
  * THE FEATURES COME FROM audio_fe.c, compiled for the host and called through ctypes --
    the same C the Zephyr image runs. There is no second front end to disagree with.

Emits, under --out:
    {train,val,test}_x.npy   int8  [N, 1, FRAMES, NCOEF]
    {train,val,test}_y.npy   int8  [N, MAXDIG]   digit labels, -1 padded
    {train,val,test}_l.npy   int32 [N]           label lengths
    meta.json
"""
from __future__ import annotations

import argparse, ctypes, json, pathlib, sys
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import featurise as F  # noqa: E402

DIGITS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
CLIP_SAMPLES = 64160          # 4.01 s -> exactly 200 frames at the kws geometry
FRAMES = 200
MAXDIG = 5


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--geom", default="kws", choices=["asr", "kws"])
    ap.add_argument("--per-split", type=int, default=24000,
                    help="training utterances to synthesise (val/test get a fifth each)")
    ap.add_argument("--min-digits", type=int, default=1)
    ap.add_argument("--max-digits", type=int, default=MAXDIG)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()

    root = pathlib.Path(a.root)
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    tmp = out / "_build"; tmp.mkdir(exist_ok=True)
    lib = F.build_lib(a.geom, "int", tmp)
    nframes = lib.fe_nframes(CLIP_SAMPLES)
    assert nframes == FRAMES, (nframes, FRAMES)
    print(f"[digits] {a.geom} geometry: {CLIP_SAMPLES} samples -> {nframes} frames")

    # ---- the pool of single-digit recordings, partitioned by SPEAKER ------------------
    pool = {"train": [[] for _ in DIGITS], "val": [[] for _ in DIGITS],
            "test": [[] for _ in DIGITS]}
    for di, d in enumerate(DIGITS):
        for w in sorted((root / d).glob("*.wav")):
            pool[F.which_set(f"{d}/{w.name}")][di].append(w)
    for sp in pool:
        print(f"[digits] {sp}: " + " ".join("%s=%d" % (DIGITS[i], len(pool[sp][i]))
                                            for i in range(10)))

    noise = []
    nd = root / "_background_noise_"
    if nd.is_dir():
        import wave
        for w in sorted(nd.glob("*.wav")):
            with wave.open(str(w), "rb") as h:
                noise.append(np.frombuffer(h.readframes(h.getnframes()), dtype="<i2"))

    scratch = ctypes.create_string_buffer(1 << 16)
    buf = (ctypes.c_int16 * (nframes * 10))()

    for sp, n_utt in (("train", a.per_split), ("val", a.per_split // 5),
                      ("test", a.per_split // 5)):
        rng = np.random.default_rng(a.seed + hash(sp) % 1000)
        # int16, NOT int8: these are Q8 log2 values spanning thousands, and the
        # int8 quantisation happens later from the TRAINING set's percentiles. An
        # int8 array here silently truncates every value to its low byte, and the
        # only symptom is that the percentiles come out near zero and every feature
        # saturates at +-127 -- which looks like a scaling choice, not a bug.
        X = np.empty((n_utt, nframes, 10), dtype=np.int16)
        Y = np.full((n_utt, MAXDIG), -1, dtype=np.int8)
        L = np.zeros(n_utt, dtype=np.int32)
        for u in range(n_utt):
            ndig = int(rng.integers(a.min_digits, a.max_digits + 1))
            # Lead-in silence, then digits separated by gaps. Everything is bounded so a
            # five-digit utterance still fits the 4.01 s window; the generator retries
            # rather than truncating, because a clipped final digit is a mislabelled
            # example and there is no way to notice it later.
            for _attempt in range(20):
                pcm = np.zeros(CLIP_SAMPLES, dtype=np.float32)
                pos = int(rng.integers(1600, 6400))
                labs, ok = [], True
                for k in range(ndig):
                    di = int(rng.integers(10))
                    cand = pool[sp][di]
                    if not cand:
                        ok = False; break
                    clip = F.read_wav(cand[int(rng.integers(len(cand)))]).astype(np.float32)
                    # trim the corpus's own leading/trailing near-silence so the digits
                    # sit closer together than 1 s apart
                    e = np.abs(clip)
                    idx = np.nonzero(e > max(60.0, e.max() * 0.06))[0]
                    if len(idx):
                        clip = clip[max(0, idx[0] - 400):min(len(clip), idx[-1] + 400)]
                    if pos + len(clip) > CLIP_SAMPLES - 800:
                        ok = False; break
                    pcm[pos:pos + len(clip)] += clip * float(rng.uniform(0.6, 1.0))
                    labs.append(di)
                    pos += len(clip) + int(rng.integers(800, 4000))
                if ok and len(labs) == ndig:
                    break
            else:
                ndig = 1; labs = [0]
                pcm = np.zeros(CLIP_SAMPLES, dtype=np.float32)
            if noise:
                src = noise[int(rng.integers(len(noise)))]
                o = int(rng.integers(0, len(src) - CLIP_SAMPLES))
                pcm += src[o:o + CLIP_SAMPLES].astype(np.float32) * float(rng.uniform(0.0, 0.25))
            q = np.clip(pcm, -32768, 32767).astype(np.int16)
            lib.fe_mfcc_clip(q.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)),
                             CLIP_SAMPLES, scratch, buf, 1)
            X[u] = np.frombuffer(buf, dtype=np.int16).reshape(nframes, 10).astype(np.int16)
            Y[u, :ndig] = labs
            L[u] = ndig
            if u % 4000 == 0:
                print(f"  {sp} {u}/{n_utt}", flush=True)
        np.save(out / f"{sp}_q8.npy", X.astype(np.int16))
        np.save(out / f"{sp}_y.npy", Y)
        np.save(out / f"{sp}_l.npy", L)
        print(f"[digits] {sp}: {n_utt} utterances, mean {L.mean():.2f} digits")

    # The Q8 -> int8 map, per coefficient, from the TRAINING set only.
    tr = np.load(out / "train_q8.npy").astype(np.int32)
    off = np.zeros(10, dtype=np.int32); sh = np.zeros(10, dtype=np.int32)
    for k in range(10):
        lo, hi = np.percentile(tr[:, :, k], 0.5), np.percentile(tr[:, :, k], 99.5)
        off[k] = int(round((lo + hi) / 2))
        sh[k] = max(0, int(np.ceil(np.log2(max(1.0, (hi - lo) / 2) / 127.0))))
    for sp in ("train", "val", "test"):
        x = np.load(out / f"{sp}_q8.npy").astype(np.int32)
        q = np.clip((x - off[None, None, :]) >> sh[None, None, :], -127, 127).astype(np.int8)
        np.save(out / f"{sp}_x.npy", q[:, None, :, :])
        (out / f"{sp}_q8.npy").unlink()
    json.dump({"geometry": a.geom, "frames": nframes, "ncoef": 10, "digits": DIGITS,
               "blank": 10, "nclass": 11, "maxdig": MAXDIG,
               "clip_samples": CLIP_SAMPLES, "off_q8": off.tolist(), "shift": sh.tolist(),
               "sample_rate_corpus": 16000, "sample_rate_board": 15993.859},
              open(out / "meta.json", "w"), indent=2)
    print("[digits] off", off.tolist(), "shift", sh.tolist())
    print("[digits] wrote", out)


if __name__ == "__main__":
    main()
