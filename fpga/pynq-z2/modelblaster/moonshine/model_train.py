#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The training-based levers of MOONSHINE_MODEL.md section 3, as short pilots on one TITAN RTX.

Every pilot is the same loop: a frozen float moonshine-tiny is the TEACHER, a student is trained
on LibriSpeech train-clean-100 windows (model_trainset.py -- disjoint from dev-clean and
test-clean), and the loss is distillation, not the reference transcript:

    L = KL(student logits || teacher logits) on the teacher's own greedy token sequence
      + alpha * MSE(student encoder output, teacher encoder output) / var(teacher)

so the pilot measures how much of the TEACHER a changed model can recover, which is the question
each lever asks.  WER is then measured the ordinary way, greedy, on dev-clean (selection) and,
once per finalist, on test-clean.

  --lever vocab         lm_head (and, tied, embed_tokens) restricted to the --keep-rows most
                        frequent rows of model_trainset.py --emit, plus the 256 byte-fallback
                        rows and the specials.  The restriction is applied as a HARD LOGIT MASK,
                        which is mathematically the pruned model -- a masked row has zero
                        probability and takes zero gradient -- so the pilot measures exactly what
                        slicing those rows out of the tensor would give.  Section 2.1 measured the
                        cost of doing this WITHOUT training (+0.62 test points at 11,000 rows);
                        this asks how much of that a short fine-tune gives back.
  --lever qat           the student is moonshine-tiny with per-tensor int8 FAKE QUANTISATION on
                        every Linear/Conv weight and on the activations fq.py grids, with a
                        straight-through estimator.  The question of section 8.13: does per-tensor
                        W8A8 become viable WITHOUT the split-dispatch stem, which today computes
                        the stem convolutions four times?
  --lever ffn           encoder and decoder FFN pruned structurally to --ffn width, by the
                        activation-weighted importance of each intermediate unit
  --lever heads         attention heads pruned to --heads, by head output norm
  --lever declayers     decoder layers pruned to --dec-layers, by the output change when dropped

Checkpoints and logs go to $ARCHIVE (archive/model_pilots/<tag>), never to git; the curated
result is the JSON this writes.

    PYTHONPATH=$MOONSHINE_DIR/pylib python3 model_train.py --lever ffn --ffn 768 \\
        --minutes 60 --json model_pilot_ffn768.json
"""
from __future__ import annotations

import argparse
import copy
import json
import math
import os
import shutil
import sys
import time

import numpy as np
import torch
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fq  # noqa: E402
import librispeech_sets as ls  # noqa: E402
import model_trainset as mt  # noqa: E402
import model_vocab as mv  # noqa: E402
import moonshine_enc as me  # noqa: E402
import q16_fidelity as q16f  # noqa: E402

ARCHIVE = os.environ.get("ARCHIVE", os.path.join(
    os.path.abspath(os.path.join(HERE, "..", "..", "..", "..")), "archive"))


# ---------------------------------------------------------------------------------------
# data
# ---------------------------------------------------------------------------------------
class Windows:
    """4 s windows of the training split, random-cropped from longer utterances."""

    def __init__(self, seed=0, stem=mt.STEM):
        self.tr = mt.Train(stem)
        self.rng = np.random.default_rng(seed)

    def batch(self, n: int) -> torch.Tensor:
        xs = np.zeros((n, me.N_SAMPLES), dtype=np.float32)
        for j in range(n):
            i = int(self.rng.integers(0, len(self.tr)))
            w = self.tr.wav(i)
            if len(w) > me.N_SAMPLES:
                o = int(self.rng.integers(0, len(w) - me.N_SAMPLES))
                w = w[o:o + me.N_SAMPLES]
            xs[j, :len(w)] = w
        return torch.from_numpy(xs)


# ---------------------------------------------------------------------------------------
# fake quantisation with a straight-through estimator
# ---------------------------------------------------------------------------------------
def ste_round(x):
    return (torch.round(x) - x).detach() + x


class FQWeight(torch.nn.Module):
    """per-tensor int8 fake quantisation of a weight, differentiable through the rounding"""

    def forward(self, w):
        s = w.detach().abs().max().clamp(min=1e-12) / 127.0
        return torch.clamp(ste_round(w / s), -128, 127) * s


class FQAct(torch.nn.Module):
    """per-tensor int8 fake quantisation of an activation at a FIXED calibrated range"""

    def __init__(self, rng: float):
        super().__init__()
        self.register_buffer("rng", torch.tensor(float(rng)))

    def forward(self, x):
        s = (self.rng / 127.0).clamp(min=1e-12)
        return torch.clamp(ste_round(x / s), -128, 127) * s


def attach_fake_quant(model, ranges: dict):
    """Wrap every Linear/Conv1d weight in per-tensor int8 fake quantisation, and hang an
    activation fake-quant on every module whose output fq.py grids."""
    from torch.nn.utils import parametrize
    n_w = 0
    for name, m in model.named_modules():
        if isinstance(m, (torch.nn.Linear, torch.nn.Conv1d)):
            parametrize.register_parametrization(m, "weight", FQWeight())
            n_w += 1
    n_a = 0
    for name, m in model.named_modules():
        if name in ranges:
            q = FQAct(ranges[name]).to(next(model.parameters()).device)
            m.register_forward_hook(lambda mod, inp, out, q=q:
                                    q(out) if isinstance(out, torch.Tensor) else out)
            n_a += 1
    return n_w, n_a


@torch.no_grad()
def calibrate(model, data: Windows, dev, n_batches=8, batch=8) -> dict:
    """The per-tensor activation range of every Linear/Conv1d/activation output, as the 99.99th
    percentile of |x| over calibration windows -- fq.py's own policy for the ones it grids."""
    acc = {}
    hs = []
    for name, m in model.named_modules():
        if isinstance(m, (torch.nn.Linear, torch.nn.Conv1d, torch.nn.GELU, torch.nn.Tanh,
                          torch.nn.GroupNorm, torch.nn.SiLU)):
            def hook(mod, inp, out, name=name):
                if isinstance(out, torch.Tensor):
                    v = out.detach().abs().float().flatten()
                    k = max(1, int(v.numel() * 1e-4))
                    acc[name] = max(acc.get(name, 0.0), float(v.topk(k).values.min()))
            hs.append(m.register_forward_hook(hook))
    for _ in range(n_batches):
        model.model.encoder(data.batch(batch).to(dev))
    for h in hs:
        h.remove()
    return acc


# ---------------------------------------------------------------------------------------
# restricted re-tokenisation: the vocabulary lever's actual objective
# ---------------------------------------------------------------------------------------
class RestrictedBPE:
    """Segment text into KEPT pieces only, falling back to the <0xNN> byte rows.

    Why this and not a masked teacher.  A masked teacher and a masked student are the SAME
    distribution, so distilling one into the other has zero gradient: the student already sits at
    the teacher's optimum on every prefix the teacher walks.  What the restriction actually costs
    is the words whose pieces are gone, and the only way to get them back is to teach the model
    to SPELL them with the pieces it still has.  That needs a target sequence in the restricted
    vocabulary, which is what this builds: left-to-right longest match over the kept pieces, and
    the UTF-8 bytes as <0xNN> rows when nothing matches.  It is not the optimal segmentation a
    re-trained BPE would find -- it is the one a restricted tokenizer produces without re-fitting
    the merges, which is what shipping this lever would actually do."""

    def __init__(self, vocab: dict, keep: np.ndarray, max_piece: int = 16):
        self.id_of = {p: i for p, i in vocab.items() if keep[i]}
        self.max_piece = max_piece
        self.byte_id = {b: vocab.get(f"<0x{b:02X}>") for b in range(256)}
        self.unk = 0

    def encode_piece(self, t: str) -> list:
        """re-spell ONE removed piece with kept pieces, bytes last"""
        out, i, n = [], 0, len(t)
        while i < n:
            hit = None
            for L in range(min(self.max_piece, n - i), 0, -1):
                j = self.id_of.get(t[i:i + L])
                if j is not None:
                    hit = (j, L)
                    break
            if hit is None:
                for b in t[i].encode("utf-8"):
                    bid = self.byte_id.get(b)
                    out.append(bid if bid is not None else self.unk)
                i += 1
            else:
                out.append(hit[0])
                i += hit[1]
        return out

    def patch(self, ids: list, keep: np.ndarray, inv: dict) -> list:
        """The teacher's OWN token sequence with only the removed pieces re-spelled.  A full
        re-segmentation would fight the model everywhere -- greedy longest match differs from the
        BPE merges even for words that are entirely present -- and a 45-minute pilot cannot teach
        a new segmentation.  Patching only what was removed changes 1-4 % of the targets, which is
        exactly the part the restriction broke."""
        out = []
        for t in ids:
            if t in (1, 2):
                out.append(t)
            elif keep[t]:
                out.append(t)
            else:
                out += self.encode_piece(inv[t])
        return out


def ce_step(student, teacher, tok, rbpe, x, alpha, dev, max_new=24, keep=None, proc=None,
            keep_np=None, inv=None):
    """Cross-entropy of the restricted student against the teacher's transcript, RE-TOKENISED in
    the restricted vocabulary, plus the encoder MSE term."""
    with torch.no_grad():
        te = teacher.model.encoder(x)
        ids = teacher.generate(encoder_outputs=te, max_new_tokens=max_new, do_sample=False,
                               num_beams=1)
        seqs = [rbpe.patch([int(v) for v in r], keep_np, inv)[:max_new + 1] for r in ids]
        L = max(len(q) for q in seqs)
        tgt = torch.full((len(seqs), L), 2, dtype=torch.long, device=dev)
        msk = torch.zeros((len(seqs), L), dtype=torch.bool, device=dev)
        for b, q in enumerate(seqs):
            tgt[b, :len(q)] = torch.tensor(q, device=dev)
            msk[b, :len(q)] = True
    se = student.model.encoder(x)
    sd = student.model.decoder(input_ids=tgt[:, :-1],
                               encoder_hidden_states=se.last_hidden_state).last_hidden_state
    slog = student.proj_out(sd)
    if keep is not None:
        slog = slog.masked_fill(~keep, torch.finfo(slog.dtype).min)
    ce = F.cross_entropy(slog.reshape(-1, slog.shape[-1]), tgt[:, 1:].reshape(-1),
                         reduction="none")
    ce = (ce * msk[:, 1:].reshape(-1).float()).sum() / msk[:, 1:].sum().clamp(min=1)
    mse = ((se.last_hidden_state - te.last_hidden_state) ** 2).mean() / \
        te.last_hidden_state.detach().var().clamp(min=1e-8)
    return ce, float(ce), float(mse)


# ---------------------------------------------------------------------------------------
# structured pruning
# ---------------------------------------------------------------------------------------
@torch.no_grad()
def ffn_importance(model, data: Windows, dev, batch=8, n=6):
    """mean |activation| of each FFN intermediate unit, times the L2 norm of the fc2 column it
    feeds: the standard activation-weighted structured score."""
    acts = {}
    hs = []
    # hook fc1 outputs (the intermediate, pre-activation; the decoder's fc1 is gated 2x)
    for name, m in model.named_modules():
        if name.endswith("mlp.fc1"):
            def hook(mod, inp, out, name=name):
                acts[name] = acts.get(name, 0.0) + out.detach().abs().float().mean(
                    dim=tuple(range(out.dim() - 1)))
            hs.append(m.register_forward_hook(hook))
    for _ in range(n):
        x = data.batch(batch).to(dev)
        enc = model.model.encoder(x)
        ids = model.generate(encoder_outputs=enc, max_new_tokens=24, do_sample=False, num_beams=1)
        model.model.decoder(input_ids=ids[:, :-1], encoder_hidden_states=enc.last_hidden_state)
    for h in hs:
        h.remove()
    return acts


def prune_ffn(model, acts: dict, width: int):
    """Keep `width` intermediate units per FFN.  The decoder's fc1 is GATED (2 x hidden), so its
    two halves are kept together: unit i and unit i + H are one unit."""
    kept = {}
    for name, m in model.named_modules():
        if not name.endswith("mlp"):
            continue
        fc1, fc2 = m.fc1, m.fc2
        a = acts[f"{name}.fc1"]
        gated = fc1.out_features == 2 * fc2.in_features
        H = fc2.in_features
        col = fc2.weight.detach().norm(dim=0)                     # [H]
        score = (a[:H] * a[H:] if gated else a[:H]) * col
        keep = torch.argsort(score, descending=True)[:width].sort().values
        with torch.no_grad():
            if gated:
                idx = torch.cat([keep, keep + H])
                nf1 = torch.nn.Linear(fc1.in_features, 2 * width,
                                      bias=fc1.bias is not None).to(fc1.weight.device)
                nf1.weight.copy_(fc1.weight[idx])
                if fc1.bias is not None:
                    nf1.bias.copy_(fc1.bias[idx])
            else:
                nf1 = torch.nn.Linear(fc1.in_features, width,
                                      bias=fc1.bias is not None).to(fc1.weight.device)
                nf1.weight.copy_(fc1.weight[keep])
                if fc1.bias is not None:
                    nf1.bias.copy_(fc1.bias[keep])
            nf2 = torch.nn.Linear(width, fc2.out_features,
                                  bias=fc2.bias is not None).to(fc2.weight.device)
            nf2.weight.copy_(fc2.weight[:, keep])
            if fc2.bias is not None:
                nf2.bias.copy_(fc2.bias)
        m.fc1, m.fc2 = nf1, nf2
        kept[name] = width
    return kept


@torch.no_grad()
def head_importance(model, data: Windows, dev, batch=8, n=6):
    """Per attention head: the mean |value| of the slice of o_proj's INPUT that head writes,
    times the L2 norm of the o_proj columns that read it.  The same activation-weighted rule the
    FFN uses, applied to a head's whole 36-wide block."""
    acts, hs = {}, []
    for name, m in model.named_modules():
        if name.endswith("attn.o_proj"):
            def hook(mod, inp, out, name=name):
                a = inp[0].detach().abs().float()
                acts[name] = acts.get(name, 0.0) + a.reshape(-1, a.shape[-1]).mean(0)
            hs.append(m.register_forward_hook(hook))
    for _ in range(n):
        x = data.batch(batch).to(dev)
        enc = model.model.encoder(x)
        ids = model.generate(encoder_outputs=enc, max_new_tokens=24, do_sample=False, num_beams=1)
        model.model.decoder(input_ids=ids[:, :-1], encoder_hidden_states=enc.last_hidden_state)
    for h in hs:
        h.remove()
    return acts


def prune_heads(model, acts: dict, keep_heads: int):
    """Keep `keep_heads` heads per attention module.  The hidden width is unchanged; the
    attention INNER width goes from heads x head_dim to keep_heads x head_dim, so q/k/v lose
    output rows and o_proj loses input columns -- which is exactly the shape change
    model_cost.py's `heads` candidate prices."""
    out = {}
    for name, m in model.named_modules():
        if not (name.endswith("self_attn") or name.endswith("encoder_attn")):
            continue
        hd = m.head_dim
        nh = m.q_proj.out_features // hd
        a = acts[f"{name}.o_proj"].reshape(nh, hd).mean(1)
        col = m.o_proj.weight.detach().norm(dim=0).reshape(nh, hd).mean(1)
        keep = torch.argsort(a * col, descending=True)[:keep_heads].sort().values
        sel = torch.cat([torch.arange(int(h) * hd, (int(h) + 1) * hd) for h in keep]).to(
            m.q_proj.weight.device)
        with torch.no_grad():
            for pn in ("q_proj", "k_proj", "v_proj"):
                old = getattr(m, pn)
                new = torch.nn.Linear(old.in_features, len(sel),
                                      bias=old.bias is not None).to(old.weight.device)
                new.weight.copy_(old.weight[sel])
                if old.bias is not None:
                    new.bias.copy_(old.bias[sel])
                setattr(m, pn, new)
            o = m.o_proj
            no = torch.nn.Linear(len(sel), o.out_features, bias=o.bias is not None).to(o.weight.device)
            no.weight.copy_(o.weight[:, sel])
            if o.bias is not None:
                no.bias.copy_(o.bias)
            m.o_proj = no
        m.config.num_attention_heads = keep_heads
        m.config.num_key_value_heads = keep_heads
        m.num_key_value_groups = 1
        out[name] = [int(h) for h in keep]
    return out


@torch.no_grad()
def declayer_importance(model, data: Windows, dev, batch=8, n=4):
    """The change in the decoder's output hidden state when a layer is skipped: the standard
    layer-drop score."""
    layers = model.model.decoder.layers
    score = []
    xs = [data.batch(batch).to(dev) for _ in range(n)]
    encs = [model.model.encoder(x) for x in xs]
    idss = [model.generate(encoder_outputs=e, max_new_tokens=24, do_sample=False, num_beams=1)
            for e in encs]
    base = [model.model.decoder(input_ids=i[:, :-1], encoder_hidden_states=e.last_hidden_state
                                ).last_hidden_state for i, e in zip(idss, encs)]
    for li in range(len(layers)):
        keep = torch.nn.ModuleList([l for j, l in enumerate(layers) if j != li])
        model.model.decoder.layers = keep
        d = 0.0
        for i, e, b in zip(idss, encs, base):
            h = model.model.decoder(input_ids=i[:, :-1],
                                    encoder_hidden_states=e.last_hidden_state).last_hidden_state
            d += float((h - b).norm() / b.norm())
        model.model.decoder.layers = layers
        score.append(d / n)
    return score


# ---------------------------------------------------------------------------------------
# the loop
# ---------------------------------------------------------------------------------------
def kd_step(student, teacher, x, alpha, max_new=24, keep=None, proc=None, on_policy=False):
    """One distillation step.

    on_policy = False: the prefix is the TEACHER's own greedy sequence.  Right when the student
    differs structurally from the teacher (pruned FFN, fewer layers, fake quantisation), because
    the student is far from the teacher everywhere and the teacher's path is a good target.

    on_policy = True: the prefix is the STUDENT's own greedy sequence under its restriction, and
    the teacher -- UNRESTRICTED -- says what to do from there.  Right for the vocabulary lever,
    where the restricted student starts AT the teacher's optimum on the teacher's own path (a
    masked teacher and a masked student are the same distribution, so teacher-prefix KD has no
    gradient at all) and the only thing to learn is how to continue after a token the restriction
    forced it to change.  The target is the teacher's full distribution masked to the kept rows,
    which is the teacher renormalised on what the student can still say."""
    with torch.no_grad():
        te = teacher.model.encoder(x)
        if on_policy:
            se0 = student.model.encoder(x)
            ids = student.generate(encoder_outputs=se0, max_new_tokens=max_new, do_sample=False,
                                   num_beams=1, logits_processor=proc)
        else:
            ids = teacher.generate(encoder_outputs=te, max_new_tokens=max_new, do_sample=False,
                                   num_beams=1, logits_processor=proc)
        td = teacher.model.decoder(input_ids=ids[:, :-1],
                                   encoder_hidden_states=te.last_hidden_state).last_hidden_state
        tlog = teacher.proj_out(td)
        if keep is not None:
            tlog = tlog.masked_fill(~keep, torch.finfo(tlog.dtype).min)
    se = student.model.encoder(x)
    sd = student.model.decoder(input_ids=ids[:, :-1],
                               encoder_hidden_states=se.last_hidden_state).last_hidden_state
    slog = student.proj_out(sd)
    if keep is not None:
        slog = slog.masked_fill(~keep, torch.finfo(slog.dtype).min)
    pad = (ids[:, :-1] == teacher.config.eos_token_id)
    m = (~pad).float().unsqueeze(-1)
    kd = (F.kl_div(F.log_softmax(slog, -1), F.log_softmax(tlog, -1),
                   log_target=True, reduction="none").sum(-1, keepdim=True) * m).sum() / m.sum()
    mse = ((se.last_hidden_state - te.last_hidden_state) ** 2).mean() / \
        te.last_hidden_state.detach().var().clamp(min=1e-8)
    return kd + alpha * mse, float(kd), float(mse)


@torch.no_grad()
def eval_wer(model, tok, dev, sname: str, n: int = 0, keep_mask=None):
    corpus, idx = ls.tune_set() if sname == "dev" else ls.eval_set()
    if n:
        idx = ls.even(idx, n)
    refs = [corpus.texts[i] for i in idx]
    txt, _, _ = mv.decode_set(model, tok, corpus, idx, dev, keep_mask=keep_mask)
    e, nn_ = q16f.utt_errors(refs, txt)
    return {"set": f"{corpus.name} <= 4 s", "utterances": len(idx), "words": int(nn_.sum()),
            "wer": float(e.sum() / nn_.sum())}, e, nn_


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lever", required=True,
                    choices=("qat", "ffn", "heads", "declayers", "vocab", "none"))
    ap.add_argument("--keep-rows", type=int, default=11000)
    ap.add_argument("--max-new-train", type=int, default=24)
    ap.add_argument("--train-counts", default=None)
    ap.add_argument("--ffn", type=int, default=768)
    ap.add_argument("--dec-layers", type=int, default=4)
    ap.add_argument("--heads", type=int, default=6)
    ap.add_argument("--minutes", type=float, default=60.0)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--alpha", type=float, default=1.0)
    ap.add_argument("--eval-n", type=int, default=0)
    ap.add_argument("--test", action="store_true", help="also run test-clean ONCE (a finalist)")
    ap.add_argument("--json", required=True)
    ap.add_argument("--tag", default=None)
    ap.add_argument("--data-stem", default=mt.STEM, choices=sorted(mt.GLOBS),
                    help="train_clean_100 (29 h, the one-hour pilots) or train_big (+ "
                         "train-other-500, the section 3.3.1 long run)")
    ap.add_argument("--eval-every-min", type=float, default=0.0,
                    help="dev WER on a fixed evenly-spaced subset every N minutes; 0 = off")
    ap.add_argument("--eval-subset", type=int, default=256)
    ap.add_argument("--plateau", type=int, default=3,
                    help="stop after this many consecutive evaluations without improvement")
    ap.add_argument("--plateau-delta", type=float, default=0.001,
                    help="improvement threshold in WER (0.001 = 0.10 points)")
    a = ap.parse_args()
    tag = a.tag or (a.lever + str({"ffn": a.ffn, "declayers": a.dec_layers,
                                   "heads": a.heads, "vocab": a.keep_rows}.get(a.lever, "")))
    outdir = os.path.join(ARCHIVE, "model_pilots", tag)
    os.makedirs(outdir, exist_ok=True)
    t0 = time.time()
    dev = fq.device()

    teacher, tok = mv.load_hf(dev)
    for p in teacher.parameters():
        p.requires_grad_(False)
    student, _ = mv.load_hf(dev)
    data = Windows(stem=a.data_stem)

    rec = {"lever": a.lever, "tag": tag, "minutes_budget": a.minutes, "batch": a.batch,
           "lr": a.lr, "alpha": a.alpha, "archive": outdir,
           "train_split": {"source": f"LibriSpeech {a.data_stem}, model_fetch_train.sh shards",
                           "utterances": len(data.tr), "hours": data.tr.hours(),
                           "disjoint_from": "dev-clean and test-clean"},
           "gpu": torch.cuda.get_device_name(0)}

    # ---- build the student ----------------------------------------------------------------
    if a.lever == "qat":
        ranges = calibrate(student, data, dev)
        n_w, n_a = attach_fake_quant(student, ranges)
        rec["fake_quant"] = {"weight_tensors": n_w, "activation_points": n_a,
                             "policy": "per-tensor int8, weights at max|W|, activations at a "
                                       "FIXED calibrated range (p99.99 over 64 train windows), "
                                       "straight-through rounding"}
    elif a.lever == "ffn":
        acts = ffn_importance(student, data, dev)
        rec["prune"] = {"kind": "FFN width", "to": a.ffn, "from": 1152,
                        "score": "mean |fc1 output| (gated halves multiplied) x ||fc2 column||",
                        "kept": prune_ffn(student, acts, a.ffn)}
    elif a.lever == "declayers":
        sc = declayer_importance(student, data, dev)
        drop = sorted(range(len(sc)), key=lambda i: sc[i])[:len(sc) - a.dec_layers]
        keep = [i for i in range(len(sc)) if i not in drop]
        student.model.decoder.layers = torch.nn.ModuleList(
            [student.model.decoder.layers[i] for i in keep])
        student.config.decoder_num_hidden_layers = len(keep)
        rec["prune"] = {"kind": "decoder layers", "to": a.dec_layers, "from": len(sc),
                        "score_per_layer": sc, "dropped": drop, "kept": keep}
    elif a.lever == "vocab":
        cnt = np.load(a.train_counts)
        order = np.argsort(-cnt, kind="stable")
        keep_np = np.zeros(teacher.config.vocab_size, dtype=bool)
        keep_np[order[:a.keep_rows]] = True
        keep_np[list(range(0, 259))] = True            # specials + the 256 <0xNN> byte rows
        keep = torch.from_numpy(keep_np).to(dev)
        import model_cost as mc
        rec["prune"] = {"kind": "lm_head rows (tied: embed_tokens too)",
                        "rows_kept": int(keep_np.sum()), "from": teacher.config.vocab_size,
                        "source": "model_trainset.py --emit counts on train-clean-100",
                        "lm_head_fetched_bytes": mc.lmhead_image(int(keep_np.sum()))["fetched_bytes"],
                        "applied_as": "a hard logit mask, which is the pruned model exactly",
                        "objective": "cross-entropy against the teacher's transcript RE-TOKENISED "
                                     "in the kept vocabulary (RestrictedBPE), not distillation: "
                                     "a masked teacher and a masked student are the same "
                                     "distribution and give zero gradient"}
        tj = json.load(open(os.path.join(str(me.moonshine_dir()), "tokenizer.json")))
        rbpe = RestrictedBPE(tj["model"]["vocab"], keep_np)
        inv = {i: p for p, i in tj["model"]["vocab"].items()}
        for pnm, prm in student.model.encoder.named_parameters():
            prm.requires_grad_(False)       # a vocabulary change is a DECODER change; freezing
        rec["encoder"] = "frozen (a vocabulary lever must not move the measured encoder)"
    elif a.lever == "heads":
        acts = head_importance(student, data, dev)
        rec["prune"] = {"kind": "attention heads", "to": a.heads, "from": 8,
                        "score": "mean |o_proj input| over the head's block x ||o_proj columns||",
                        "kept": prune_heads(student, acts, a.heads),
                        "note": "the hidden width is unchanged; the attention inner width goes "
                                "from heads x 36 to a.heads x 36, which is the shape "
                                "model_cost.py's `heads 8 -> 6` candidate prices"}
    keep = locals().get('keep') if a.lever == 'vocab' else None
    from transformers import LogitsProcessorList, LogitsProcessor
    proc = None
    if keep is not None:
        class KeepOnly(LogitsProcessor):
            def __call__(self, input_ids, scores):
                return scores.masked_fill(~keep, torch.finfo(scores.dtype).min)
        proc = LogitsProcessorList([KeepOnly()])
    student = student.to(dev).train()
    rec["student_params"] = sum(p.numel() for p in student.parameters())
    rec["teacher_params"] = sum(p.numel() for p in teacher.parameters())

    kmask = keep.cpu().numpy() if keep is not None else None
    before, _, _ = eval_wer(student.eval(), tok, dev, "dev", a.eval_n, kmask)
    rec["dev_before_finetune"] = before
    print(f"[{tag}] student {rec['student_params']/1e6:.2f} M params, "
          f"dev WER before fine-tune {before['wer']*100:.2f} %", flush=True)

    # ---- the loop ---------------------------------------------------------------------------
    student.train()
    opt = torch.optim.AdamW([p for p in student.parameters() if p.requires_grad], lr=a.lr,
                            weight_decay=0.01)
    deadline = time.time() + a.minutes * 60
    hist, step = [], 0
    best_wer, best_sd, best_step, best_min, stale, curve = 1e9, None, 0, 0.0, 0, []
    next_eval = time.time() + a.eval_every_min * 60 if a.eval_every_min else float("inf")
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / 200))
    while time.time() < deadline:
        x = data.batch(a.batch).to(dev)
        if a.lever == "vocab":
            loss, kd, mse = ce_step(student, teacher, tok, rbpe, x, a.alpha, dev,
                                    max_new=a.max_new_train, keep=keep, proc=proc,
                                    keep_np=keep_np, inv=inv)
        else:
            loss, kd, mse = kd_step(student, teacher, x, a.alpha, keep=keep, proc=proc,
                                    max_new=a.max_new_train)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(student.parameters(), 1.0)
        opt.step()
        sched.step()
        step += 1
        if a.eval_every_min and time.time() >= next_eval:
            student.eval()
            w, _, _ = eval_wer(student, tok, dev, "dev", a.eval_subset, kmask)
            student.train()
            mins = (time.time() - t0) / 60
            curve.append({"minutes": mins, "step": step, "dev_wer_subset": w["wer"],
                          "utterances": w["utterances"]})
            if w["wer"] < best_wer - a.plateau_delta:
                best_wer, best_step, best_min, stale = w["wer"], step, mins, 0
                best_sd = {k: v.detach().clone() for k, v in student.state_dict().items()}
            else:
                stale += 1
                if w["wer"] < best_wer:
                    best_wer, best_step, best_min = w["wer"], step, mins
                    best_sd = {k: v.detach().clone() for k, v in student.state_dict().items()}
            print(f"  [eval] {mins:.1f} min step {step}: dev-{a.eval_subset} WER "
                  f"{w['wer']*100:.2f} %  best {best_wer*100:.2f} %  stale {stale}/{a.plateau}",
                  flush=True)
            next_eval = time.time() + a.eval_every_min * 60
            if stale >= a.plateau:
                print(f"  [eval] plateau: {stale} evaluations without a "
                      f"{a.plateau_delta*100:.2f}-point improvement; stopping", flush=True)
                rec["stopped_by"] = "plateau"
                break
        if step % 50 == 0:
            hist.append({"step": step, "kd": kd, "enc_mse": mse,
                         "minutes": (time.time() - t0) / 60})
            print(f"  step {step:6d}  kd {kd:.4f}  enc_mse {mse:.5f}  "
                  f"{(time.time()-t0)/60:.1f} min", flush=True)
    rec["steps"] = step
    if best_sd is not None:
        student.load_state_dict(best_sd)
        rec["restored"] = {"from": "best dev checkpoint", "dev_wer_subset": best_wer,
                           "at_step": best_step, "at_minutes": best_min}
    rec["windows_seen"] = step * a.batch
    rec["epochs_equivalent"] = step * a.batch / len(data.tr)
    rec["history"] = hist[-40:]
    rec["dev_curve"] = curve
    rec.setdefault("stopped_by", "wall clock")
    rec["stopping_rule"] = {"wall_clock_min": a.minutes, "eval_every_min": a.eval_every_min,
                            "eval_subset": a.eval_subset, "plateau_evals": a.plateau,
                            "plateau_delta_wer": a.plateau_delta,
                            "reported_checkpoint": "best dev subset, not the last"}

    # ---- evaluate ---------------------------------------------------------------------------
    student.eval()
    after, ea, na = eval_wer(student, tok, dev, "dev", a.eval_n, kmask)
    rec["dev_after_finetune"] = after
    _, eb, nb = eval_wer(teacher, tok, dev, "dev", a.eval_n)
    rec["dev_delta_vs_float_teacher"] = q16f.paired_bootstrap(ea, eb, nb)
    print(f"[{tag}] dev WER after {after['wer']*100:.2f} % "
          f"(delta vs teacher {rec['dev_delta_vs_float_teacher']['delta_wer']*100:+.2f})",
          flush=True)
    if a.test:
        t_after, eta, nta = eval_wer(student, tok, dev, "test", a.eval_n, kmask)
        _, etb, ntb = eval_wer(teacher, tok, dev, "test", a.eval_n)
        rec["test_after_finetune"] = t_after
        rec["test_delta_vs_float_teacher"] = q16f.paired_bootstrap(eta, etb, ntb)
        print(f"[{tag}] test WER {t_after['wer']*100:.2f} %", flush=True)

    # ---- the checkpoint goes to the archive, never to git -----------------------------------
    from safetensors.torch import save_file
    if a.lever == "qat":
        from torch.nn.utils import parametrize
        for m in student.modules():
            if parametrize.is_parametrized(m, "weight"):
                parametrize.remove_parametrizations(m, "weight", leave_parametrized=False)
    sd = {k: v.detach().cpu().contiguous() for k, v in student.state_dict().items()
          if not k.endswith("rotary_emb.inv_freq")}
    sd.pop("proj_out.weight", None)
    save_file(sd, os.path.join(outdir, "model.safetensors"))
    for f in ("config.json", "generation_config.json", "preprocessor_config.json", "tokenizer.json"):
        src = os.path.join(str(me.moonshine_dir()), f)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(outdir, f))
    cfg = json.load(open(os.path.join(outdir, "config.json")))
    if a.lever == "ffn":
        cfg["intermediate_size"] = a.ffn
    if a.lever == "declayers":
        cfg["decoder_num_hidden_layers"] = a.dec_layers
    if a.lever == "heads":
        cfg["encoder_num_attention_heads"] = cfg["decoder_num_attention_heads"] = a.heads
        cfg["encoder_num_key_value_heads"] = cfg["decoder_num_key_value_heads"] = a.heads
    json.dump(cfg, open(os.path.join(outdir, "config.json"), "w"), indent=1)
    rec["checkpoint"] = os.path.join(outdir, "model.safetensors")
    rec["elapsed_min"] = (time.time() - t0) / 60
    json.dump(rec, open(a.json, "w"), indent=1)
    print(f"wrote {a.json}  ({rec['elapsed_min']:.1f} min)")


if __name__ == "__main__":
    main()
