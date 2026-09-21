#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""What the FIXED 4 s window costs, and what a variable-length one would cost instead.

Moonshine has no fixed input length: the stem is three strided convolutions (64 x 3 x 2 = 384
samples per frame) and the attention has no mask, so an utterance of any length runs.  The
board's pipeline pads every clip to 4.0 s (moonshine_enc.window) because ModelBlaster's IR is
built for one shape.  This file prices the alternative, two ways:

  COST   an encoder cost model in T (frames), built by scaling each MEASURED part of
         amdahl_hart0.json by its own element law -- softmax and the two attention matmuls go
         as T^2, everything else on hart 0 as T -- and by RE-PLANNING every engine dispatch at
         the new npix with engine_traffic's own tile planner, so the tiling granularity and the
         per-dispatch fixed cost are not smoothed over.  DERIVED from measured parts.
  WER    the float model decoded on its own length against the same model decoded on the padded
         4 s window, on the pinned sets.  MEASURED (host, float).

Also: the token count per utterance, which decode_compose.py has to assume (it composes 15),
and the decoding policy -- greedy against beam, the EOS step, and the max-token cap.

    PYTHONPATH=$MOONSHINE_DIR/pylib python3 model_len.py --sets dev test --json model_len.json
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
import engine_traffic as et  # noqa: E402
import fq  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import model_vocab as mv  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402

CLK = et.CLK
D, FF, LAYERS, HEADS, HD = 288, 1152, 6, 8, 36

# parts of the encoder that go as T^2 (the attention triangle), by amdahl_hart0.json's names
QUADRATIC = ("softmax", "attention scores q.k (matmul_b)", "attention weighted sum p.v (matmul_b)")


def frames(n_samples: int) -> int:
    """the stem's three strided convolutions, as moonshine_enc builds them"""
    p1 = (n_samples - 127) // 64 + 1
    p2 = (p1 - 7) // 3 + 1
    return (p2 - 3) // 2 + 1


def samples_for(T: int) -> int:
    n = 384 * T
    while frames(n) < T:
        n += 64
    while frames(n - 64) >= T:
        n -= 64
    return n


def npix_chain(n_samples: int) -> tuple:
    p1 = (n_samples - 127) // 64 + 1
    p2 = (p1 - 7) // 3 + 1
    return p1, p2, (p2 - 3) // 2 + 1


def unit_rates(base: dict) -> dict:
    """Cycles per filled byte, per MAC and per drained byte, and the per-dispatch residue, from
    the three MEASURED encoder linear shapes (B25 run 8), averaged by their own weight."""
    f = s = p = rest = b = m = o = 0.0
    for name, count in (("enc_qkvo", 24), ("enc_fc1", 6), ("enc_fc2", 6)):
        d = base[name]
        f += d["cyc_fill"]; s += d["steps"]; p += d["cyc_place"]
        rest += d["cyc_h0"] - d["cyc_fill"] - d["cyc_place"]
        b += d["bytes_w"] + d["bytes_a"]; m += d["npix"] * d["N"] * d["K"]; o += d["out_bytes"]
    return {"cyc_per_filled_byte": f / b, "cyc_per_mac": s / m, "cyc_per_out_byte": p / o,
            "residue_per_dispatch": rest / 3.0}


def engine_cycles(T: int, base: dict) -> float:
    """Total hart-0 wall cycles of the encoder's engine dispatches at T frames.  The tile plan is
    re-run at the new npix with engine_traffic's own planner; the measured unit rates then price
    fill (per filled byte), array steps (per MAC), result placement (per drained byte) and the
    per-dispatch residue (commands, planning, hand-off), which does NOT scale with T."""
    p1, p2, _ = npix_chain(samples_for(T))
    r = unit_rates(base)
    shapes = [(288, 128, p1, 8, 1), (576, 2016, p2, 108, 1), (288, 1728, T, 144, 1),
              (288, 288, T, 36, 24), (1152, 288, T, 36, 6), (288, 1152, T, 144, 6)]
    tot = 0.0
    for N, K, npix, astride, count in shapes:
        plan = et.run_plan(et.wimage_plan(N, K), npix, astride)
        tot += count * (r["cyc_per_filled_byte"] * (plan["bytes_w"] + plan["bytes_a"])
                        + r["cyc_per_mac"] * npix * N * K
                        + r["cyc_per_out_byte"] * plan["out_bytes"]
                        + r["residue_per_dispatch"])
    return tot


def encoder_seconds(T: int, rows: list, scenario: str, base: dict) -> dict:
    """seconds at T frames, by part.  `scenario` picks seconds_today or the T1 software lever."""
    T0 = 165
    parts, tot = {}, 0.0
    for r in rows:
        name = r["part"]
        if name.startswith("engine dispatches"):
            continue
        s0 = r["seconds_today"]
        if scenario == "T1" and r.get("software_seconds_after") is not None:
            s0 = r["software_seconds_after"]
        if scenario == "T1" and name == "NCHW<->NHWC staging (stem)":
            s0 = 0.0
        scale = (T / T0) ** 2 if name in QUADRATIC else (T / T0)
        parts[name] = s0 * scale
        tot += parts[name]
    eng = engine_cycles(T, base) / CLK
    if scenario == "T1":
        eng *= 0.62      # incremental placement, measured on 0x5A5A0012 (section 8.15)
    parts["engine dispatches"] = eng
    tot += eng
    return {"T": T, "seconds": tot, "parts": parts}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", nargs="+", default=["dev", "test"], choices=("dev", "test"))
    ap.add_argument("--json", required=True)
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--skip-wer", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)

    am = json.load(open(os.path.join(HERE, "amdahl_hart0.json")))
    import model_cost as mc
    base = mc.per_dispatch(mc.traffic())

    out = {"what": __doc__.split("\n")[0],
           "anchors": {
               "measured_encoder_rtf_today_as_extracted": am["rtf_today"],
               "measured_encoder_rtf_best_0x5A5A0012": 4.134,
               "amdahl_T1_rtf": am["scenarios"][1]["rtf"],
               "note": "the cost model below is normalised so that T = 165 reproduces these"},
           "length_model": {}}

    # ---- encoder cost against window length ------------------------------------------------
    for scen, anchor in (("today", am["rtf_today"]), ("T1", 4.134)):
        rowsT = []
        s165 = encoder_seconds(165, am["rows"], scen, base)["seconds"]
        dur165 = samples_for(165) / me.SR
        for secs in (0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0, 8.0):
            T = frames(int(round(secs * me.SR)))
            r = encoder_seconds(T, am["rows"], scen, base)
            dur = samples_for(T) / me.SR
            rowsT.append({"seconds_requested": secs, "T": T, "window_s": dur,
                          "model_seconds": r["seconds"],
                          "rtf": (r["seconds"] / dur) / (s165 / dur165) * anchor,
                          "rtf_vs_4s": (r["seconds"] / dur) / (s165 / dur165),
                          "quadratic_share": sum(v for kk, v in r["parts"].items()
                                                 if kk in QUADRATIC) / r["seconds"]})
        out["length_model"][scen] = rowsT
        print(f"[{scen}] encoder RTF vs window: " +
              "  ".join(f"{r['window_s']:.2f}s={r['rtf']:.2f}" for r in rowsT))

    # ---- what the sets actually contain, and the token count -------------------------------
    if not a.skip_wer:
        dev = fq.device()
        model, tok = mv.load_hf(dev)
        out["sets"] = {}
        for sname in a.sets:
            corpus, idx = ls.tune_set() if sname == "dev" else ls.eval_set()
            if a.n:
                idx = ls.even(idx, a.n)
            refs = [corpus.texts[i] for i in idx]
            durs = np.array([corpus.lens[i] / me.SR for i in idx])
            txt4, ids4, _ = mv.decode_set(model, tok, corpus, idx, dev)
            e4, n4 = q16f.utt_errors(refs, txt4)
            ntok4 = np.array([sum(1 for t in r if t not in mv.SPECIAL) for r in ids4])

            # the same utterances on their OWN length, one at a time (variable shape)
            txtv, ntokv = [], []
            for i in idx:
                w = corpus.wav(i).astype(np.float32)
                nz = max(int(np.ceil(len(w) / 384.0) * 384), 8000)
                w = np.pad(w, (0, max(0, nz - len(w))))[:nz]
                xv = torch.from_numpy(w[None, :]).to(dev)
                enc = model.model.encoder(xv)
                gen = model.generate(encoder_outputs=enc, max_new_tokens=mv.MAX_NEW,
                                     do_sample=False, num_beams=1)
                txtv.append(tok.decode(gen[0], skip_special_tokens=True))
                ntokv.append(sum(1 for t in gen[0].tolist() if t not in mv.SPECIAL))
            ev, nv = q16f.utt_errors(refs, txtv)

            rec = {"name": f"{corpus.name} <= 4 s", "utterances": len(idx),
                   "speakers": len({corpus.speakers[i] for i in idx}),
                   "words": int(n4.sum()),
                   "audio_s": {"mean": float(durs.mean()), "p10": float(np.percentile(durs, 10)),
                               "p50": float(np.percentile(durs, 50)),
                               "p90": float(np.percentile(durs, 90)), "max": float(durs.max())},
                   "frames_own_length": {"mean": float(np.mean([frames(int(d * me.SR)) for d in durs])),
                                         "p50": float(np.percentile([frames(int(d * me.SR)) for d in durs], 50))},
                   "tokens_per_utterance_4s": {"mean": float(ntok4.mean()),
                                               "p50": float(np.percentile(ntok4, 50)),
                                               "p90": float(np.percentile(ntok4, 90)),
                                               "max": int(ntok4.max()),
                                               "hit_the_40_token_cap": int((ntok4 >= mv.MAX_NEW).sum())},
                   "wer_4s_window": float(e4.sum() / n4.sum()),
                   "wer_own_length_window": float(ev.sum() / nv.sum()),
                   "delta_own_minus_4s": q16f.paired_bootstrap(ev, e4, n4),
                   "tokens_per_utterance_own_length_mean": float(np.mean(ntokv))}
            out["sets"][sname] = rec
            print(f"[{sname}] {len(idx)} utt, audio p50 {rec['audio_s']['p50']:.2f} s, "
                  f"tokens/utt mean {rec['tokens_per_utterance_4s']['mean']:.1f}, "
                  f"WER 4 s {rec['wer_4s_window']*100:.2f} % vs own length "
                  f"{rec['wer_own_length_window']*100:.2f} % "
                  f"(delta {rec['delta_own_minus_4s']['delta_wer']*100:+.2f})")

        # ---- decoding policy: greedy vs beam, and the token cap ---------------------------
        out["decoding_policy"] = {}
        for sname in a.sets:
            corpus, idx = ls.tune_set() if sname == "dev" else ls.eval_set()
            if a.n:
                idx = ls.even(idx, a.n)
            refs = [corpus.texts[i] for i in idx]
            base_txt, base_ids, _ = mv.decode_set(model, tok, corpus, idx, dev)
            eb, nb = q16f.utt_errors(refs, base_txt)
            pol = {"greedy_40": {"wer": float(eb.sum() / nb.sum()),
                                 "tokens_per_utterance": float(np.mean(
                                     [sum(1 for t in r if t not in mv.SPECIAL) for r in base_ids])),
                                 "decoder_passes_per_token": 1}}
            for nb_ in (2, 5):
                bt, bids, _ = mv.decode_set(model, tok, corpus, idx, dev, num_beams=nb_, batch=16)
                e, n = q16f.utt_errors(refs, bt)
                pol[f"beam_{nb_}"] = {
                    "wer": float(e.sum() / n.sum()),
                    "delta_vs_greedy": q16f.paired_bootstrap(e, eb, nb),
                    "tokens_per_utterance": float(np.mean(
                        [sum(1 for t in r if t not in mv.SPECIAL) for r in bids])),
                    "decoder_passes_per_token": nb_,
                    "note": "every pass is a whole decoder token: 19.99 MB of weights, 343.4 ms"}
            for cap in (8, 12, 16, 20, 24, 32):
                t2, _, _ = mv.decode_set(model, tok, corpus, idx, dev, max_new=cap)
                e, n = q16f.utt_errors(refs, t2)
                pol[f"cap_{cap}"] = {"wer": float(e.sum() / n.sum()),
                                     "delta_vs_greedy40": q16f.paired_bootstrap(e, eb, nb)}
            out["decoding_policy"][sname] = pol
            print(f"[{sname}] policy: " + "  ".join(
                f"{k} {v['wer']*100:.2f} %" for k, v in pol.items() if "wer" in v))

    out["elapsed_s"] = time.time() - t0
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({out['elapsed_s']:.0f} s)")


if __name__ == "__main__":
    main()
