#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Is the trainer's fake quantisation the same function as ModelBlaster's int8 arithmetic?

MOONSHINE_MODEL.md section 3.3.8.  QAT (model_train.py) trains against torch fake quantisation --
float arithmetic with rounding inserted at 40 module outputs -- while deployment runs int8 x int8
-> int32 with a Q0.31 requantise, round-half-to-even and saturation, over 155 quantised tensors,
with LUT and memo-table nonlinearities.  Nobody had compared them: `fake_quant` appears in exactly
one file, the trainer.

BOTH PATHS ARE EXERCISED THE WAY THE MODEL EXERCISES THEM, which is the point.  Same checkpoint,
same 4.0 s window, same utterances, same 165 x 288 output -- and the fake-quant path carries THE
IR'S OWN RANGES, not the trainer's, so the only difference left is the arithmetic.  Running it at
the trainer's ranges instead would re-measure section 3.3.5's dead range lever and call it this one.
(The lesson is the attention workstream's: a benchmark inherits the coverage of its arguments.)

    PYTHONPATH=$ZCS:$MOONSHINE_DIR/pylib python3 model_fqcheck.py \
        --ir out/qatu_long/ir --gen out/qatu_long/gen_nl --n 24 --json model_fqcheck.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import hostrun  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import model_train as mt  # noqa: E402
import model_vocab as mv  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402


def ir_ranges(ir: dict) -> dict:
    """The IR's own activation ranges, keyed by MODULE name.

    IR tensors are named with underscores where the module path has dots (`stem_conv1` for
    `stem.conv1`), so the mapping is by that normalisation and is checked, not assumed: the
    caller reports how many of the trainer's hook points were matched.
    """
    out = {}
    for name, t in ir["tensors"].items():
        q = t.get("quant")
        if not q or "scale" not in q:
            continue
        bits = 8 if t.get("dtype", "i8") == "i8" else 16
        lim = 127.0 if bits == 8 else 32767.0
        out[name] = float(q["scale"]) * lim
    return out


def match_modules(model, rng_by_tensor: dict) -> dict:
    """module name -> range, for every module the trainer would hook that the IR also grids"""
    want = {}
    for name, m in model.named_modules():
        if not isinstance(m, (torch.nn.Linear, torch.nn.Conv1d, torch.nn.GELU,
                              torch.nn.Tanh, torch.nn.GroupNorm, torch.nn.SiLU)):
            continue
        for key in (name, name.replace(".", "_")):
            if key in rng_by_tensor:
                want[name] = rng_by_tensor[key]
                break
    return want


@torch.no_grad()
def encoder_out(model, x: np.ndarray, dev) -> list:
    out = []
    for xi in x:
        # the PORTED encoder, which is the graph ModelBlaster extracts -- shape [1,1,1,N] in,
        # [1,T,D] out.  Using HF's own encoder here would compare against a different module.
        h = model(torch.from_numpy(xi.reshape(1, 1, 1, -1)).to(dev))
        out.append(h.reshape(-1).float().cpu())
    return out


def stats(a: list, b: list) -> dict:
    A = torch.cat(a).double()
    B = torch.cat(b).double()
    d = A - B
    return {"sqnr_db": float(10 * torch.log10((A * A).sum() / (d * d).sum().clamp(min=1e-30))),
            "cosine": float((A * B).sum() / (A.norm() * B.norm())),
            "max_abs_diff": float(d.abs().max()),
            "rms_ref": float((A * A).mean().sqrt()), "rms_diff": float((d * d).mean().sqrt())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ir", required=True)
    ap.add_argument("--gen", required=True)
    ap.add_argument("--n", type=int, default=24)
    ap.add_argument("--wer", action="store_true",
                    help="also decode and score all three paths on the whole set (P20)")
    ap.add_argument("--workdir", default=os.path.join(HERE, "..", "..", "..", "..", "out", "fqcheck"))
    ap.add_argument("--json", default=os.path.join(HERE, "model_fqcheck.json"))
    a = ap.parse_args()
    t0 = time.time()
    dev = "cpu"
    ir = json.load(open(os.path.join(a.ir, "graph.json")))
    n_samp = int(ir["tensors"][ir["input"]["tensor"]]["shape"][-1])
    T, D = [int(v) for v in ir["tensors"][ir["output"]["tensors"][0]]["shape"][-2:]]

    corpus = ls.Corpus("dev_clean")
    idx = [i for i in range(len(corpus.ids)) if corpus.lens[i] <= n_samp][:a.n]
    x = np.stack([np.pad(corpus.wav(i), (0, n_samp - len(corpus.wav(i)))) for i in idx]).astype(np.float32)
    refs = [corpus.texts[i] for i in idx]

    # ---- path 0: float, the common reference
    mdl = me.get_model().to(dev).eval()
    h_float = encoder_out(mdl, x, dev)

    # ---- path 1: the TRAINER's fake quantisation, at the IR's ranges
    rng_t = ir_ranges(ir)
    fqm = me.get_model().to(dev).eval()
    want = match_modules(fqm, rng_t)
    n_w, n_a = mt.attach_fake_quant(fqm, want)
    h_fq = encoder_out(fqm, x, dev)

    # ---- path 2: ModelBlaster's generated C, the deployed arithmetic
    meta = ir["tensors"][ir["input"]["tensor"]]
    s_in = meta["quant"]["scale"]
    if meta["dtype"] == "i16":
        xq = np.clip(np.rint(x.astype(np.float64) / s_in), -32768, 32767).astype(np.int16)
    else:
        xq = torch.round(torch.from_numpy(x) / s_in).clamp(-127, 127).to(torch.int8).numpy()
    s_out = ir["tensors"][ir["output"]["tensors"][0]]["quant"]["scale"]
    wd = os.path.abspath(a.workdir)
    exe = hostrun.build(os.path.abspath(a.gen), wd)
    yq = q16f.run_parallel(exe, xq, T * D, os.path.join(wd, "batch"), 8)
    h_c = [torch.from_numpy(y.astype(np.float64) * s_out).float() for y in yq]

    rec = {"what": __doc__.strip().splitlines()[0],
           "ir": os.path.abspath(a.ir), "gen": os.path.abspath(a.gen),
           "checkpoint": os.environ.get("MOONSHINE_DIR"),
           "utterances": len(idx), "window_samples": n_samp, "frames": T, "hidden": D,
           "ranges_source": "the IR's own quant grids (identical for both paths)",
           "fake_quant": {"weight_tensors": n_w, "activation_points": n_a,
                          "trainer_hook_points_matched_to_ir": len(want)},
           "ir_quantised_tensors": sum(1 for t in ir["tensors"].values() if "quant" in t),
           "vs_float": {"fake_quant": stats(h_float, h_fq), "generated_C": stats(h_float, h_c)},
           "fake_quant_vs_generated_C": stats(h_c, h_fq)}
    print(f"trainer hook points matched to IR grids: {len(want)} "
          f"(weights {n_w}, activation hooks {n_a}); IR quantises {rec['ir_quantised_tensors']} tensors")
    for k, v in (("fake-quant vs float", rec["vs_float"]["fake_quant"]),
                 ("generated C vs float", rec["vs_float"]["generated_C"]),
                 ("fake-quant vs generated C", rec["fake_quant_vs_generated_C"])):
        print(f"  {k:28s} SQNR {v['sqnr_db']:7.2f} dB   cosine {v['cosine']:.5f}   "
              f"max|d| {v['max_abs_diff']:.4f}")
    if a.wer:
        # P20: the same three paths, decoded by HF's float decoder, greedy, 40 tokens, scored with
        # fq.py's normalisation -- the identical recipe q16_fidelity uses, so the numbers compose
        # with 3.3.4's.  The whole served set, not the --n subset.
        full = [i for i in range(len(corpus.ids)) if corpus.lens[i] <= n_samp]
        xf = np.stack([np.pad(corpus.wav(i), (0, n_samp - len(corpus.wav(i)))) for i in full]).astype(np.float32)
        rf = [corpus.texts[i] for i in full]
        hf_model, tok = mv.load_hf(dev)
        import model_rung_gate as rg
        wer = {}
        for lab, mdl_ in (("float", mdl), ("fake_quant", fqm)):
            h = encoder_out(mdl_, xf, dev)
            txt = rg.decode_hs(hf_model, tok, h, dev, T, D)
            e, nw = q16f.utt_errors(rf, txt)
            wer[lab] = {"wer": float(e.sum() / nw.sum()), "errors": int(e.sum()),
                        "words": int(nw.sum()), "utterances": len(full)}
            print(f"  {lab:12s} WER {wer[lab]['wer']*100:6.2f} %  ({wer[lab]['errors']} / {wer[lab]['words']})")
        rec["wer"] = wer
        rec["wer"]["note"] = ("generated C on the same set is model_qatu_long_c_dev.json; "
                              "all three share checkpoint, window, ranges, decoder and scoring")
    rec["elapsed_s"] = round(time.time() - t0, 1)
    json.dump(rec, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({rec['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
