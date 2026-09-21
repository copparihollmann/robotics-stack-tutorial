#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""WER of the GENERATED C of a quantised Moonshine encoder, on the LibriSpeech fidelity sets.

The measurement ROCC_DECOUPLED.md section 8.13 asks for: quant_fix.py's candidates were chosen
in float simulation (fq.py), and only the generated integer C counts.  For each utterance of a
set (librispeech_sets.py: dev-clean or test-clean, every utterance that fits 4.0 s whole):

  float   the port's float32 encoder (fq.FQInterp with no grids, exactly quant_fix.py's float
          baseline) -> HF's float decoder, greedy, 40 new tokens, batched (fq.Decoder)
  C       ModelBlaster's generated C for one build, compiled for the host (hostrun.py:
          -O2 -ffp-contract=off, MBP as pext.h's software model), on the input the device
          would see -- the window on the IR's input grid, int8 or int16 -- dequantised with
          the IR's output scale -> the same decoder

WER against the LibriSpeech reference and against the float encoder's own transcripts, with
fq.py's text normalisation and word-level Levenshtein, so the numbers are directly comparable
with quant_fix.py's float-simulation records on the same utterances.

    PYTHONPATH=zephyr-chipyard-sw:$MOONSHINE_DIR/pylib python3 q16_fidelity.py --set dev \\
        --variant R_ref:IR_DIR:GEN_DIR [--variant ...] --workdir WD --json out.json
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import hostrun  # noqa: E402
import q16_plan  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import moonshine_enc as me  # noqa: E402


def utt_errors(refs: list, hyps: list) -> tuple:
    """per-utterance (word edits, reference words), fq.wer's normalisation and distance"""
    e, n = [], []
    for r, h in zip(refs, hyps):
        w = fq.wer([r], [h])
        e.append(w["errors"])
        n.append(w["words"])
    return np.asarray(e, dtype=np.int64), np.asarray(n, dtype=np.int64)


def paired_bootstrap(e_a, e_b, n, reps: int = 2000, seed: int = 7) -> dict:
    """WER(a) - WER(b) over the same utterances, and a 95 % interval from resampling
    utterances (paired: both systems keep the same resample)."""
    rng = np.random.default_rng(seed)
    d = float(e_a.sum() - e_b.sum()) / float(n.sum())
    idx = rng.integers(0, len(n), size=(reps, len(n)))
    ds = (e_a[idx].sum(1) - e_b[idx].sum(1)) / n[idx].sum(1)
    return {"delta_wer": d, "ci95": [float(np.percentile(ds, 2.5)), float(np.percentile(ds, 97.5))],
            "resamples": reps, "unit": "utterance"}


def run_parallel(exe: str, xq: np.ndarray, out_len: int, wd: str, jobs: int) -> np.ndarray:
    """xq [B, input_len] int8/int16 -> [B, out_len] int8, `jobs` host processes."""
    os.makedirs(wd, exist_ok=True)
    B = xq.shape[0]
    bounds = np.linspace(0, B, min(jobs, B) + 1).astype(int)
    procs = []
    for j in range(len(bounds) - 1):
        ip, op = os.path.join(wd, f"in{j}.bin"), os.path.join(wd, f"out{j}.bin")
        np.ascontiguousarray(xq[bounds[j]:bounds[j + 1]]).tofile(ip)
        procs.append((subprocess.Popen([exe, "batch", ip, op]), op, bounds[j + 1] - bounds[j]))
    outs = []
    for p, op, n in procs:
        if p.wait() != 0:
            raise SystemExit(f"{exe} batch failed ({p.returncode})")
        y = np.fromfile(op, dtype=np.int8)
        if y.size != n * out_len:
            raise SystemExit(f"{op}: {y.size} bytes, expected {n * out_len}")
        outs.append(y.reshape(n, out_len))
    return np.concatenate(outs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", choices=("dev", "test"), required=True)
    ap.add_argument("--variant", action="append", required=True, help="label:IR_DIR:GEN_DIR")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 4))
    ap.add_argument("--n", type=int, default=0, help="evenly spaced subset (0 = the whole set)")
    ap.add_argument("--float-sim", default=None, choices=sorted(q16_plan.CANDIDATES),
                    help="also run the candidate's quant_fix.py float simulation on the same utterances, "
                         "and compare every C variant with it utterance by utterance")
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = fq.device()
    corpus, idx = ls.tune_set() if a.set == "dev" else ls.eval_set()
    if a.n:
        idx = ls.even(idx, a.n)
    refs = [corpus.texts[i] for i in idx]
    x = np.stack([me.window(corpus.wav(i)) for i in idx]).astype(np.float32)          # [B, 64000]

    if a.float_sim:
        import quant_fix as qf  # noqa: PLC0415
        M = qf.Model(dev, 64)
        gm = M.gm
    else:
        gm = fq.trace(me.build_encoder().to(dev)).to(dev)
    xt = [torch.from_numpy(xi).view(1, 1, 1, -1).to(dev) for xi in x]
    fl = [fq.FQInterp(gm, {}).run(t).reshape(-1).cpu() for t in xt]
    dec = fq.Decoder(dev, 40)
    fl_txt = dec(fl)
    out = {"what": "WER of ModelBlaster's GENERATED C (host build, bit-exact with the device by the "
                   "host gates) for Moonshine Tiny's encoder, HF float decoder, greedy, 40 tokens",
           "set": {"name": f"{corpus.name} <= 4 s", "utterances": len(idx),
                   "speakers": len({corpus.speakers[i] for i in idx}),
                   "words": fq.wer(refs, refs)["words"], "subset_of_n": a.n or None},
           "float": {"wer_vs_reference": fq.wer(refs, fl_txt)},
           "decoder": {"max_new_tokens": 40, "greedy": True, "checkpoint": f"{me.CKPT_REPO}@{me.CKPT_REV}"},
           "variants": {}}
    print(f"[fidelity] {out['set']}  float WER {out['float']['wer_vs_reference']['wer']:.4f} "
          f"({time.time() - t0:.0f} s)", flush=True)
    e_float, n_words = utt_errors(refs, fl_txt)
    e_sim = None
    if a.float_sim:
        rec, key = q16_plan.CANDIDATES[a.float_sim]
        knobs = json.load(open(os.path.join(HERE, rec)))["candidates"][key]["knobs"]
        cfg, wcfg, wover, bover, pre_div, post_mul, _ = qf.build(M, knobs)
        M.ws.apply(wcfg, wover, bover)
        sim = [fq.FQInterp(gm, cfg, pre_div=pre_div, post_mul=post_mul).run(t).reshape(-1).cpu() for t in xt]
        M.ws.restore()
        sim_txt = dec(sim)
        e_sim, _ = utt_errors(refs, sim_txt)
        out["float_sim"] = {"candidate": a.float_sim, "quant_fix_key": key, "record": rec,
                            "what": "fq.py float simulation (ESTIMATE), rerun here on the same utterances",
                            "wer_vs_reference": fq.wer(refs, sim_txt), "wer_vs_float": fq.wer(fl_txt, sim_txt),
                            "sqnr_db": fq.sqnr_db(fl, sim)}
        print(f"[fidelity] float sim {a.float_sim}: WER vs ref {out['float_sim']['wer_vs_reference']['wer']:.4f}  "
              f"vs float {out['float_sim']['wer_vs_float']['wer']:.4f}", flush=True)

    for spec in a.variant:
        label, ir_dir, gen = spec.split(":")
        ir = json.load(open(os.path.join(ir_dir, "graph.json")))
        in_t = ir["input"]["tensor"]
        meta = ir["tensors"][in_t]
        s_in = meta["quant"]["scale"]
        if meta["dtype"] == "i16":
            xq = np.clip(np.rint(x.astype(np.float64) / s_in), -32768, 32767).astype(np.int16)
        else:     # extract_graph's own int8 input quantiser
            xq = torch.round(torch.from_numpy(x) / s_in).clamp(-127, 127).to(torch.int8).numpy()
        out_t = ir["output"]["tensors"][0]
        s_out = ir["tensors"][out_t]["quant"]["scale"]
        wd = os.path.join(a.workdir, label)
        exe = hostrun.build(gen, wd)
        t1 = time.time()
        yq = run_parallel(exe, xq, me.T * me.D, os.path.join(wd, "batch"), a.jobs)
        t_c = time.time() - t1
        hs = [torch.from_numpy(y.astype(np.float32) * np.float32(s_out)) for y in yq]
        txt = dec(hs)
        v = {"ir": ir_dir, "gen": gen, "q16_plan": ir.get("q16_plan"), "input_dtype": meta["dtype"],
             "input_scale": s_in, "output_scale": s_out,
             "kernel_picks": {k: (vv.get("algorithm") or vv.get("source"))
                              for k, vv in json.load(open(os.path.join(gen, "kernel_picks.json")))["picks"].items()},
             "wer_vs_reference": fq.wer(refs, txt), "wer_vs_float": fq.wer(fl_txt, txt),
             "sqnr_db": fq.sqnr_db(fl, hs), "cosine": fq.cosine(fl, hs),
             "identical_to_float_transcript": int(sum(fq.norm_text(p) == fq.norm_text(q)
                                                      for p, q in zip(fl_txt, txt))),
             "host_seconds": round(t_c, 1)}
        e_c, _ = utt_errors(refs, txt)
        v["minus_float"] = paired_bootstrap(e_c, e_float, n_words)
        if e_sim is not None:
            v["minus_float_sim"] = paired_bootstrap(e_c, e_sim, n_words)
        diff = [{"id": corpus.ids[i], "reference": corpus.texts[i], "float": fl_txt[j], "c": txt[j]}
                for j, i in enumerate(idx) if fq.norm_text(txt[j]) != fq.norm_text(fl_txt[j])]
        v["differs_from_float"] = len(diff)
        v["examples_differing"] = diff[:: max(1, len(diff) // 12)][:12]
        out["variants"][label] = v
        tr = os.path.join(wd, f"transcripts_{a.set}.json")
        json.dump([{"id": corpus.ids[i], "reference": corpus.texts[i], "float": fl_txt[j], "c": txt[j]}
                   for j, i in enumerate(idx)], open(tr, "w"), indent=0)
        gap = v.get("minus_float_sim")
        print(f"[fidelity] {label:16s} WER vs ref {v['wer_vs_reference']['wer']:.4f}  vs float "
              f"{v['wer_vs_float']['wer']:.4f}  C - float sim "
              f"{(gap['delta_wer'] if gap else float('nan')):+.4f} "
              f"{([round(c, 4) for c in gap['ci95']] if gap else '')}  SQNR {v['sqnr_db']:.2f} dB  identical "
              f"{v['identical_to_float_transcript']}/{len(idx)}  (host {t_c:.0f} s, {time.time() - t0:.0f} s)",
              flush=True)
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
