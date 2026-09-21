#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""moonshine-base as an accuracy ceiling, and what it would cost on this SoC.

The brief's question: is the larger official checkpoint worth characterising?  This fetches it
(pinned by revision and sha256, the way fetch_moonshine.sh pins tiny), measures its float WER on
the same pinned sets, and prices it on the measured cost model -- every shape through
engine_traffic's own planar-image planner, every cycle rate from the MEASURED tiny dispatches, so
the RTF is derived from board measurements rather than guessed.

    python3 model_base.py --fetch
    PYTHONPATH=$MOONSHINE_DIR/pylib python3 model_base.py --wer --price --json model_base.json

moonshine-base @ 7a73d8d5: hidden 416, 8 + 8 layers, 8 heads of 52, FFN 1664 (decoder gated
3328), vocab 32768, partial rotary 0.62.  Weights go to $MOONSHINE_DIR/base (git-ignored).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import engine_traffic as et  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import model_cost as mc  # noqa: E402
import moonshine_enc as me  # noqa: E402

REPO = "UsefulSensors/moonshine-base"
REV = "7a73d8d55ac0ba2ef3ae761593f6784b51f96dcf"
SHA = {"model.safetensors": "e020c79d0a979a7ec099f718ff1cd2f19e92aead230d69654bca5975a8e1b862"}
FILES = ("config.json", "generation_config.json", "preprocessor_config.json", "tokenizer.json",
         "model.safetensors")

B = dict(D=416, FF=1664, FF_DEC=3328, HEADS=8, HD=52, LAYERS=8, VOCAB=32768)


def basedir():
    return me.moonshine_dir() / "base"


def fetch():
    d = basedir()
    d.mkdir(parents=True, exist_ok=True)
    for f in FILES:
        p = d / f
        if p.exists() and (f not in SHA or _sha(p) == SHA[f]):
            print(f"  ok      {f}")
            continue
        url = f"https://huggingface.co/{REPO}/resolve/{REV}/{f}"
        subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(p) + ".part", url], check=True)
        if f in SHA and _sha(p.with_suffix(p.suffix + ".part")) != SHA[f]:
            raise SystemExit(f"SHA256 MISMATCH for {f}")
        os.replace(str(p) + ".part", str(p))
        print(f"  ok      {f}")


def _sha(p):
    import hashlib
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def price(tokens: int = 11) -> dict:
    """What moonshine-base would cost on THIS SoC.  Two layers, kept apart on purpose.

    EXACT (planner): every weight image and activation plan is engine_traffic's own
    wimage_plan/run_plan on base's shapes, so the byte and MAC ratios against tiny are arithmetic,
    not estimates.

    DERIVED (scaled): the time.  Each MEASURED component of tiny (section 8.9's token split and
    amdahl_hart0.json's hart-0 parts) is scaled by the element count that drives it -- fill by
    filled bytes, array steps by MACs, placement by drained bytes, per-dispatch commands by the
    dispatch count, and each hart-0 kernel by its own element law (softmax by layers, attention
    matmul by layers x head_dim, LayerNorm by norms x hidden, the rest by layers x hidden).  No
    single fudge factor: each part carries its own.  It is a price, not a measurement."""
    base = mc.per_dispatch(mc.traffic())
    T = 165
    p1 = (me.N_SAMPLES - 127) // 64 + 1
    p2 = (p1 - 7) // 3 + 1

    def shapes(D, FF, L, V):
        enc = [("stem", D, 128, p1, 8, 1), ("stem", 2 * D, D * 7, p2, D * 7 // 8, 1),
               ("stem", D, 2 * D * 3, T, 2 * D * 3 // 8, 1),
               ("enc_attn_proj", D, D, T, D // 8, 4 * L),
               ("enc_ffn", FF, D, T, D // 8, L), ("enc_ffn", D, FF, T, FF // 8, L)]
        dec = [("dec_self_attn_proj", D, D, 1, D // 8, 4 * L),
               ("dec_cross_attn_proj", D, D, 1, D // 8, 2 * L),
               ("dec_ffn", 2 * FF, D, 1, D // 8, L), ("dec_ffn", D, FF, 1, FF // 8, L),
               ("lm_head", V, D, 1, D // 8, 1)]
        return enc, dec

    def roll(spec):
        g = {}
        tot = dict(bytes_w=0, bytes_a=0, out_bytes=0, macs=0, dispatches=0)
        for name, N, K, npix, astride, count in spec:
            pl = et.run_plan(et.wimage_plan(N, K), npix, astride)
            d = dict(bytes_w=count * pl["bytes_w"], bytes_a=count * pl["bytes_a"],
                     out_bytes=count * pl["out_bytes"], macs=count * npix * N * K,
                     dispatches=count)
            a = g.setdefault(name, dict(bytes_w=0, bytes_a=0, out_bytes=0, macs=0, dispatches=0))
            for k in d:
                a[k] += d[k]
                tot[k] += d[k]
        g["TOTAL"] = tot
        return g

    Bd, Bf, Bl, Bv = B["D"], B["FF"], B["LAYERS"], B["VOCAB"]
    enc_b, dec_b = (roll(x) for x in shapes(Bd, Bf, Bl, Bv))
    enc_t, dec_t = (roll(x) for x in shapes(288, 1152, 6, 32768))

    # the planner reproduces the MEASURED tiny totals: that is the check on the exact half
    check = {"encoder_bytes_w": [enc_t["TOTAL"]["bytes_w"], 8519680],
             "decoder_token_bytes_w": [dec_t["TOTAL"]["bytes_w"], 19988480],
             "decoder_token_out_bytes": [dec_t["TOTAL"]["out_bytes"], 60032]}

    ratio = {k: enc_b["TOTAL"][k] / enc_t["TOTAL"][k] for k in ("bytes_w", "bytes_a", "macs")}
    ratio_tok = {k: dec_b["TOTAL"][k] / dec_t["TOTAL"][k]
                 for k in ("bytes_w", "bytes_a", "out_bytes", "macs", "dispatches")}

    # ---- the decoder token, part by part (section 8.9 / amdahl_hart0.json decoder_amdahl) -----
    am = json.load(open(os.path.join(HERE, "amdahl_hart0.json")))
    dam = {r["part"]: r["ms_per_token"] for r in am["decoder_amdahl"]["rows"]}
    L_ratio = Bl / 6.0
    D_ratio = Bd / 288.0
    HD_ratio = B["HD"] / 36.0
    drv = {
        "engine GEMMs: fill (port)": (ratio_tok["bytes_w"] + ratio_tok["bytes_a"]) / 2
        if False else ratio_tok["bytes_w"],
        "engine GEMMs: array steps": ratio_tok["macs"],
        "engine GEMMs: result placement (hart 1)": ratio_tok["out_bytes"],
        "engine GEMMs: commands and hand-off": ratio_tok["dispatches"],
        "softmax (6 self, 6 cross)": L_ratio,
        "attention matmuls": L_ratio * HD_ratio,
        "LayerNorm": L_ratio * D_ratio,
        "rotary": L_ratio * HD_ratio,
        "SiLU": L_ratio * D_ratio,
        "gate multiply": L_ratio * D_ratio,
        "residual adds": L_ratio * D_ratio,
    }
    tok = {s: sum(v[s] * drv[k] for k, v in dam.items())
           for s in ("today", "T1", "T2", "T3", "T4")}
    tok_tiny = {s: sum(v[s] for v in dam.values()) for s in tok}

    # ---- the encoder, part by part (amdahl_hart0.json rows, T1 software levers applied) -------
    erow = {r["part"]: (r.get("software_seconds_after") if r.get("software_seconds_after")
                        is not None else r["seconds_today"]) for r in am["rows"]}
    erow["NCHW<->NHWC staging (stem)"] = 0.0
    edrv = {"softmax": L_ratio, "attention scores q.k (matmul_b)": L_ratio * HD_ratio,
            "attention weighted sum p.v (matmul_b)": L_ratio * HD_ratio,
            "LayerNorm": L_ratio * D_ratio, "permute (24 attention + 1 stem)": L_ratio * D_ratio,
            "rotary (q, k)": L_ratio * HD_ratio, "NCHW<->NHWC staging (stem)": D_ratio,
            "GELU LUT (stem 2 + MLP 6)": L_ratio * D_ratio, "GroupNorm (stem)": D_ratio,
            "residual adds": L_ratio * D_ratio, "tanh LUT (stem)": D_ratio,
            "engine dispatches: linears (hart-0 wall)": (enc_b["enc_attn_proj"]["macs"]
                                                         + enc_b["enc_ffn"]["macs"])
            / (enc_t["enc_attn_proj"]["macs"] + enc_t["enc_ffn"]["macs"]),
            "engine dispatches: stem convs (hart-0 wall, no staging)":
                enc_b["stem"]["macs"] / enc_t["stem"]["macs"]}
    enc_tiny_s = sum(erow[k] for k in edrv)
    enc_base_s = sum(erow[k] * edrv[k] for k in edrv)
    k_anchor = 4.134 / (enc_tiny_s / 4.0)          # tiny's T1 total -> the MEASURED 4.134

    return {
        "config": B,
        "exact_from_the_planner": {
            "check_against_measured_tiny": check,
            "encoder_window": enc_b, "decoder_token": dec_b,
            "encoder_window_tiny": enc_t, "decoder_token_tiny": dec_t,
            "ratio_encoder_vs_tiny": ratio, "ratio_token_vs_tiny": ratio_tok},
        "derived_time": {
            "encoder_seconds_tiny_T1": enc_tiny_s, "encoder_seconds_base_T1": enc_base_s,
            "encoder_rtf_tiny_measured": 4.134,
            "encoder_rtf_base_est": enc_base_s / 4.0 * k_anchor,
            "encoder_ratio": enc_base_s / enc_tiny_s,
            "token_ms_tiny": tok_tiny, "token_ms_base_est": tok,
            "token_ratio": {s: tok[s] / tok_tiny[s] for s in tok},
            "decoder_rtf_base_est": {s: (dec_b["dec_cross_attn_proj"]["macs"]
                                         / dec_t["dec_cross_attn_proj"]["macs"] * 415.9
                                         + tokens * tok[s]) / 4000.0 for s in tok},
            "tokens_assumed": tokens},
        "label": "the byte and MAC ratios are EXACT (engine_traffic's planner on base's shapes, "
                 "checked against tiny's measured totals); the times are DERIVED by scaling each "
                 "measured component of tiny by its own element law.",
        "warning": "moonshine-base has never been extracted by ModelBlaster, quantised, or run. "
                   "This is a price, and it assumes its int8 graph transcribes at all, which "
                   "section 8.12 showed is not automatic -- tiny's did not.",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--wer", action="store_true")
    ap.add_argument("--price", action="store_true")
    ap.add_argument("--json", default="model_base.json")
    ap.add_argument("--n", type=int, default=0)
    a = ap.parse_args()
    out = {"what": __doc__.split("\n")[0], "repo": REPO, "revision": REV, "sha256": SHA}
    if a.fetch:
        fetch()
    if a.price:
        out["price"] = price()
        p = out["price"]
        ex, dv = p["exact_from_the_planner"], p["derived_time"]
        print("planner check against measured tiny (modelled, measured):",
              json.dumps(ex["check_against_measured_tiny"]))
        print(f"base vs tiny, EXACT: encoder bytes {ex['ratio_encoder_vs_tiny']['bytes_w']:.3f}x, "
              f"MACs {ex['ratio_encoder_vs_tiny']['macs']:.3f}x; "
              f"token bytes {ex['ratio_token_vs_tiny']['bytes_w']:.3f}x, "
              f"MACs {ex['ratio_token_vs_tiny']['macs']:.3f}x")
        print(f"base DERIVED: encoder RTF {dv['encoder_rtf_base_est']:.2f} (tiny measured 4.134), "
              f"token {dv['token_ms_base_est']['today']:.0f} ms today / "
              f"{dv['token_ms_base_est']['T4']:.0f} ms at T4 "
              f"(tiny {dv['token_ms_tiny']['today']:.0f} / {dv['token_ms_tiny']['T4']:.0f}), "
              f"decoder RTF {dv['decoder_rtf_base_est']['today']:.2f}")
    if a.wer:
        import torch
        import fq
        import model_vocab as mv
        import q16_fidelity as q16f
        from transformers import MoonshineForConditionalGeneration, PreTrainedTokenizerFast
        torch.set_grad_enabled(False)
        dev = fq.device()
        t0 = time.time()
        model = MoonshineForConditionalGeneration.from_pretrained(str(basedir())).eval().to(dev)
        tok = PreTrainedTokenizerFast(tokenizer_file=str(basedir() / "tokenizer.json"))
        tiny, ttok = mv.load_hf(dev)
        out["wer"] = {}
        for sname in ("dev", "test"):
            corpus, idx = ls.tune_set() if sname == "dev" else ls.eval_set()
            if a.n:
                idx = ls.even(idx, a.n)
            refs = [corpus.texts[i] for i in idx]
            tb, idsb, _ = mv.decode_set(model, tok, corpus, idx, dev)
            tt, idst, _ = mv.decode_set(tiny, ttok, corpus, idx, dev)
            eb, nb = q16f.utt_errors(refs, tb)
            ete, nte = q16f.utt_errors(refs, tt)
            out["wer"][sname] = {
                "set": f"{corpus.name} <= 4 s", "utterances": len(idx), "words": int(nb.sum()),
                "base_wer": float(eb.sum() / nb.sum()), "tiny_wer": float(ete.sum() / nte.sum()),
                "delta_base_minus_tiny": q16f.paired_bootstrap(eb, ete, nb),
                "base_tokens_per_utterance": float(np.mean(
                    [sum(1 for t in r if t not in mv.SPECIAL) for r in idsb])),
                "base_distinct_rows_emitted": len({t for r in idsb for t in r if t not in mv.SPECIAL})}
            print(f"[{sname}] base {out['wer'][sname]['base_wer']*100:.2f} % vs tiny "
                  f"{out['wer'][sname]['tiny_wer']*100:.2f} % "
                  f"(delta {out['wer'][sname]['delta_base_minus_tiny']['delta_wer']*100:+.2f} "
                  f"[{out['wer'][sname]['delta_base_minus_tiny']['ci95'][0]*100:+.2f},"
                  f"{out['wer'][sname]['delta_base_minus_tiny']['ci95'][1]*100:+.2f}])")
        out["wer_elapsed_s"] = time.time() - t0
    json.dump(out, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
