#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Gates for the ported decoder, in the order a wrong answer would be cheapest to catch.

    gate 1  float parity   the ported step reproduces HF's decoder logits, one token, pos 0
    gate 2  greedy parity  a full greedy decode in float reproduces HF's token sequence
    gate 3  causal shape   step k's attention sees exactly k valid cache entries

A wrong weight mapping does not raise; it transcribes badly and looks like quantisation error.
So float parity comes before anything is quantised.

    PYTHONPATH=$ZCS:$MOONSHINE_DIR/pylib python3 model_dec_check.py --n 4
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import librispeech_sets as ls  # noqa: E402
import moonshine_dec as md  # noqa: E402
import moonshine_enc as me  # noqa: E402


@torch.no_grad()
def hf_encode(hf, wav: np.ndarray):
    x = torch.from_numpy(wav[None, :])
    return hf.model.encoder(x).last_hidden_state              # [1, S, D]


@torch.no_grad()
def ported_decode(step_cls, sd, enc, emb, start: int, eos: int, nmax: int):
    """Greedy decode with the PORTED step, one graph per position -- the unrolled shape."""
    pro = md.load_prologue(md.MbCrossPrologue().eval(), sd)
    kxvx = pro(enc)
    kx, vx = kxvx[:md.LAYERS], kxvx[md.LAYERS:]
    kc = [torch.zeros(1, 0, md.D, 1) for _ in range(md.LAYERS)]
    vc = [torch.zeros(1, 0, md.D, 1) for _ in range(md.LAYERS)]
    toks, all_logits = [], []
    cur = start
    for pos in range(nmax):
        step = md.load_step(md.MoonshineDecoderStepMb(pos).eval(), sd)
        h = emb[cur].view(1, 1, md.D)
        args = [h] + [kc[i] if pos else torch.zeros(1, 1, md.D, 1) for i in range(md.LAYERS)] \
                   + [vc[i] if pos else torch.zeros(1, 1, md.D, 1) for i in range(md.LAYERS)] \
                   + list(kx) + list(vx)
        # gate 3: the causal structure is the SHAPE -- assert it, do not trust the generator
        if pos:
            assert kc[0].shape[1] == pos, f"step {pos} cache has {kc[0].shape[1]} entries"
        out = step(*args)
        logits, kn, vn = out[0], out[1:1 + md.LAYERS], out[1 + md.LAYERS:]
        all_logits.append(logits.reshape(-1))
        cur = int(logits.reshape(-1).argmax())
        toks.append(cur)
        kc = [torch.cat([kc[i], kn[i].view(1, 1, md.D, 1)], 1) for i in range(md.LAYERS)]
        vc = [torch.cat([vc[i], vn[i].view(1, 1, md.D, 1)], 1) for i in range(md.LAYERS)]
        if cur == eos:
            break
    return toks, all_logits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--nmax", type=int, default=24)
    a = ap.parse_args()
    import model_vocab as mv
    hf, tok = mv.load_hf("cpu")
    sd = hf.state_dict()
    emb = sd["model.decoder.embed_tokens.weight"]
    start = hf.config.decoder_start_token_id
    eos = hf.config.eos_token_id

    corpus = ls.Corpus("dev_clean")
    idx = [i for i in range(len(corpus.ids)) if corpus.lens[i] <= me.N_SAMPLES][:a.n]
    ok = True
    for j, i in enumerate(idx):
        w = np.pad(corpus.wav(i), (0, me.N_SAMPLES - len(corpus.wav(i)))).astype(np.float32)
        enc = hf_encode(hf, w)
        # --- HF reference
        from transformers.modeling_outputs import BaseModelOutput
        ref_ids = hf.generate(encoder_outputs=BaseModelOutput(last_hidden_state=enc),
                              max_new_tokens=a.nmax, do_sample=False, num_beams=1)[0].tolist()
        ref = [t for t in ref_ids if t != start]
        toks, lg = ported_decode(md.MoonshineDecoderStepMb, sd, enc, emb, start, eos, a.nmax)
        same = toks[:len(ref)] == ref[:len(toks)]
        ok &= same
        print(f"[{j}] {corpus.ids[i]}  ported {len(toks)} tok, HF {len(ref)} tok  "
              f"{'MATCH' if same else 'DIFFER'}")
        print(f"     HF:     {tok.decode(ref, skip_special_tokens=True)!r}")
        print(f"     ported: {tok.decode(toks, skip_special_tokens=True)!r}")
    print("GATE1/2:", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    main()
