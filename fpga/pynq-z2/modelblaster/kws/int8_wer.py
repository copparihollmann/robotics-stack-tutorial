#!/usr/bin/env python3
"""Word error rate for the connected-digit CTC model, in ModelBlaster's int8 arithmetic.

Same gate as int8_accuracy.py: the numpy simulator must first reproduce the codegen's own
baked golden BIT-EXACTLY, so what is scored below is the arithmetic the board executes
and not a second opinion about it.

The score is edit distance over reference length -- insertions, deletions and
substitutions -- because the model emits a variable-length string and can get its length
wrong. That is the difference between this and Labs B17/B18, and it is why the number is
a WER rather than an accuracy.
"""
from __future__ import annotations

import argparse, json, pathlib, sys
import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from int8_accuracy import run_graph   # noqa: E402


def edit(a, b):
    if not a:
        return len(b)
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def decode(lg, nclass, T, blank):
    """lg is the flat [C, T] the generated model writes; greedy CTC, no softmax."""
    m = lg.reshape(nclass, T)
    best = m.argmax(0)
    out, prev = [], -1
    for b in best:
        if b != prev and b != blank:
            out.append(int(b))
        prev = int(b)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ir", required=True)
    ap.add_argument("--gen", required=True)
    ap.add_argument("--feat", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--limit", type=int, default=1500)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    ir, gen, feat = pathlib.Path(a.ir), pathlib.Path(a.gen), pathlib.Path(a.feat)
    meta = json.load(open(a.meta))
    nclass, blank = meta["nclass"], meta["blank"]
    T = meta["out_frames"]

    gin = np.fromfile(gen / "test_input.bin", dtype=np.int8)
    gold = np.fromfile(gen / "test_golden.bin", dtype=np.int8)
    shp = ((1, 1, meta["ncoef"], meta["frames"]) if meta.get("transposed")
           else (1, 1, meta["frames"], meta["ncoef"]))
    got = run_graph(ir, gin.reshape(shp))
    err = int(np.abs(got.astype(int) - gold.astype(int)).max())
    print("  simulator vs baked golden: max_abs_err = %d  %s"
          % (err, "OK" if err == 0 else "MISMATCH -- the WER below is NOT valid"))
    if err:
        sys.exit(1)

    x = np.load(feat / "test_x.npy").astype(np.int8)
    if meta.get("transposed"):
        # [N, 1, T, C] -> [N, 1, C, T]. The model wants time on the width axis; the
        # corpus is stored in the trainer's layout. Same arithmetic either way -- see
        # SPEECH_ON_ROCKET.md section 11.4 for why the layout is worth 4x anyway.
        x = np.ascontiguousarray(x.transpose(0, 1, 3, 2))
    y = np.load(feat / "test_y.npy")
    l = np.load(feat / "test_l.npy")
    n = min(a.limit, len(x))
    e = tot = exact = 0
    for i in range(n):
        ref = [int(v) for v in y[i][:l[i]]]
        hyp = decode(run_graph(ir, x[i:i + 1]), nclass, T, blank)
        d = edit(ref, hyp)
        e += d; tot += len(ref); exact += (d == 0)
        if i % 250 == 0:
            print("    %d/%d" % (i, n), flush=True)
    wer, ex = e / max(tot, 1), exact / n
    print("  int8 WER %.2f%%   exact-utterance %.2f%%   over %d held-out utterances "
          "(%d reference digits)" % (wer * 100, ex * 100, n, tot))
    if a.out:
        json.dump({"int8_wer": wer, "int8_exact": ex, "n_utterances": n,
                   "n_digits": tot, "simulator_matches_golden": True},
                  open(a.out, "w"), indent=2)


if __name__ == "__main__":
    main()
