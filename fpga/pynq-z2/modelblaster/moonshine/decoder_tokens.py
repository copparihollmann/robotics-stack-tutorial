#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""How many tokens a decoder actually emits per utterance, for a model that has been MEASURED.

WHY.  ROCC_DECOUPLED.md s8.15.14 turns the standing goal (RTF_e2e < 1.0) into a decoder budget --
a token of <= 146.1 ms -- and that number is (0.50 * 4 s - cross-attention once) / TOKENS.  The
token count it uses, 11.06, is MOONSHINE_MODEL.md's measurement of the FLOAT model.  Every int8
candidate decodes with the same float decoder but on its own encoder output, so its count can
differ, and the budget moves with it.

METHOD, and it is the rung gate's: the candidate's generated C is built for the host, run on each
utterance's window, dequantised with the IR's output scale, and decoded greedily by HF's decoder
(max_new_tokens=40, the same cap q16_fidelity uses).  The number reported is the count of GENERATED
ids -- decoder steps -- excluding the start token, since that is what a decoder pays per utterance.

PROVE IT ON A KNOWN ANSWER: --float runs the float encoder through the same path, and must
reproduce MOONSHINE_MODEL.md's 10.89 on dev.  If it does not, the convention differs and no
candidate number from this file is comparable with the budget.

    PYTHONPATH=$ZCS:$MOONSHINE_DIR/pylib python3 decoder_tokens.py --set dev \
        --model R:out/q16/R/ir:out/q16/R/gen_nl --float --json decoder_tokens_dev.json
"""
from __future__ import annotations

import argparse, json, os, sys, time
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq                      # noqa: E402
import hostrun                 # noqa: E402
import librispeech_sets as ls  # noqa: E402
import model_rung_gate as rg   # noqa: E402
import model_vocab as mv       # noqa: E402
import moonshine_enc as me     # noqa: E402
import q16_fidelity as q16f    # noqa: E402


@torch.no_grad()
def count_hs(model, tok, hs, dev, T, D, batch=32, max_new=40):
    """Generated ids per utterance (decoder steps), and whether the cap was hit.

    COUNT TO THE FIRST EOS, NOT TO THE END OF THE ROW.  `generate` right-pads every row in a batch
    to the longest one in it, and this model's pad token IS its eos token, so `len(row) - 1` is the
    BATCH's length and not the utterance's.  Counted that way the float control reads 19.50 tokens
    against MOONSHINE_MODEL.md's 10.89 -- which is how this was caught, before any number from here
    reached a budget."""
    from transformers.modeling_outputs import BaseModelOutput
    eos = model.generation_config.eos_token_id
    if isinstance(eos, (list, tuple)):
        eos = eos[0]
    n, capped = [], 0
    for i in range(0, len(hs), batch):
        h = torch.cat([x.reshape(1, T, D) for x in hs[i:i + batch]], 0).to(dev)
        ids = model.generate(encoder_outputs=BaseModelOutput(last_hidden_state=h),
                             max_new_tokens=max_new, do_sample=False, num_beams=1)
        for row in ids:
            g = row[1:]                                   # drop the decoder start token
            hit = (g == eos).nonzero()
            if hit.numel():
                n.append(int(hit[0]) + 1)                 # the EOS step counts: the decoder ran it
            else:
                n.append(int(g.shape[0])); capped += 1
    return np.array(n), capped


def stats(n):
    s = np.sort(n)
    return {"utterances": int(s.size), "mean": float(s.mean()), "p50": float(np.median(s)),
            "p90": float(s[int(0.9 * (s.size - 1))]), "max": int(s.max())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", choices=("dev", "test"), default="dev")
    ap.add_argument("--model", action="append", default=[], help="label:IR_DIR:GEN_DIR")
    ap.add_argument("--float", action="store_true", help="the known-answer control")
    ap.add_argument("--workdir", default=os.path.join(HERE, "..", "..", "..", "out", "dectok"))
    ap.add_argument("--json", required=True)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 4))
    a = ap.parse_args()
    t0 = time.time()
    torch.set_grad_enabled(False)
    dev = fq.device()
    model, tok = mv.load_hf(dev)
    corpus = ls.Corpus("dev_clean" if a.set == "dev" else "test_clean")
    idx = [i for i in range(len(corpus.ids)) if corpus.lens[i] <= me.N_SAMPLES]
    x = np.stack([rg.window(corpus.wav(i), me.N_SAMPLES) for i in idx]).astype(np.float32)
    out = {"what": __doc__.split("\n")[0], "set": corpus.name, "window_s": me.WINDOW_S,
           "max_new_tokens": 40, "utterances": len(idx), "models": {}}

    if a.float:
        hs = [model.model.encoder(torch.from_numpy(xi[None, :]).to(dev)).last_hidden_state
              .reshape(-1).cpu() for xi in x]
        n, capped = count_hs(model, tok, hs, dev, me.T, me.D)
        out["models"]["float"] = {**stats(n), "hit_the_cap": int(capped), "basis": "float encoder"}
        print("[float] %s" % out["models"]["float"])

    for spec in a.model:
        label, ir_dir, gen = spec.split(":")
        ir = json.load(open(os.path.join(os.path.abspath(ir_dir), "graph.json")))
        n_s, T, D = rg.rung_shape(ir)
        meta = ir["tensors"][ir["input"]["tensor"]]
        s_in = meta["quant"]["scale"]
        if meta["dtype"] == "i16":
            xq = np.clip(np.rint(x.astype(np.float64) / s_in), -32768, 32767).astype(np.int16)
        else:
            xq = torch.round(torch.from_numpy(x) / s_in).clamp(-127, 127).to(torch.int8).numpy()
        s_out = ir["tensors"][ir["output"]["tensors"][0]]["quant"]["scale"]
        wd = os.path.abspath(os.path.join(a.workdir, label))
        exe = hostrun.build(os.path.abspath(gen), wd)
        yq = q16f.run_parallel(exe, xq, T * D, os.path.join(wd, "batch"), a.jobs)
        hs = [torch.from_numpy(y.astype(np.float32) * np.float32(s_out)) for y in yq]
        n, capped = count_hs(model, tok, hs, dev, T, D)
        out["models"][label] = {**stats(n), "hit_the_cap": int(capped),
                                "basis": "generated C on the host, IR %s" % ir_dir}
        print("[%s] %s" % (label, out["models"][label]))
    out["host_seconds"] = round(time.time() - t0, 1)
    json.dump(out, open(a.json, "w"), indent=1)
    print("wrote %s" % a.json)


if __name__ == "__main__":
    main()
