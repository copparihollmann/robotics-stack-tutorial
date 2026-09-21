#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fake quantisation of Moonshine's encoder, faithful to what ModelBlaster's int8 IR quantises.

This is the FLOAT SIMULATION the fidelity work uses to find where the int8 encoder breaks
(quant_diag.py) and to rank fixes (quant_fix.py) before anything is built.  Its numbers
are ESTIMATES.  Only the generated int8 C, bit-exact with the board, counts as a
measurement (host_fidelity.py).

What it models, from pipeline/extract_graph.py as extracted by scripts/50
(MB_INT8_GELU_AWARE_RANGES=1, no --per-channel):

  * every FX node output is a symmetric int8 tensor, one scale per tensor:
    scale = range / 127, where range is max|x| over calibration, except for a tensor whose
    only consumers are GELU: max(max(x+), min(max(x-), 8))  (_cal_range, gelu_fed);
  * multi-head SDPA is lowered to three ops with two INTERNAL int8 tensors:
    scores = q k^T / sqrt(d) at a calibrated scale (max over calibration / 127), and
    probs = softmax(scores) at the FIXED scale 1/127;
  * nn.Linear / nn.Conv2d weights are per-tensor symmetric int8, max-abs / 127.

What it does not model: the integer kernels' own arithmetic (LUT GELU/tanh, integer
layer and group norm, integer softmax), the int32 bias grid and round-half-away rounding.
The C pipeline has all of those; host_fidelity.py measures it.

A "config" says, per quantisable tensor, what grid it gets:
    None                   float (not quantised)
    ("pt", bits, range)    per tensor, symmetric, scale = range / (2^(bits-1) - 1)
    ("pc", bits, ranges, dim)  per channel along dim
and per weight: None, ("pt", bits) or ("pc", bits).
"""
from __future__ import annotations

import math
import os
import sys

import numpy as np
import torch
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import moonshine_enc as me  # noqa: E402

GELU_NEG_FLOOR = 8.0
SDPA = F.scaled_dot_product_attention


def device():
    d = os.environ.get("MB_FQ_DEVICE")
    if d:
        return torch.device(d)
    return torch.device("cuda" if torch.cuda.is_available() else "cpu")


def trace(model):
    from modelblaster.pipeline.extract_graph import _mb_symbolic_trace
    return _mb_symbolic_trace(model)


def is_sdpa(n) -> bool:
    return n.op == "call_function" and getattr(n.target, "__name__", "") == "scaled_dot_product_attention"


def channel_dim(shape) -> int:
    """The channel axis the statistics and per-channel grids use: dim 1 for the stem's
    [1, C, 1, T]; the last dim otherwise ([1, T, D], [1, T, H, Dh], [1, H, T, Dh])."""
    if len(shape) == 4 and shape[2] == 1:
        return 1
    return len(shape) - 1


def gelu_fed(gm) -> set:
    out = set()
    for n in gm.graph.nodes:
        if n.op in ("output",) or not n.users:
            continue
        if all(u.op == "call_module" and isinstance(gm.get_submodule(u.target), torch.nn.GELU) for u in n.users):
            out.add(n.name)
    return out


# ---- a log-spaced |x| histogram, pooled over calibration, for percentiles -------------
class Hist:
    LO, HI, NB = 1e-7, 1e6, 4096

    def __init__(self, dev):
        self.c = torch.zeros(self.NB + 2, dtype=torch.float64, device=dev)
        self.n = 0
        self.lmin, self.lmax = math.log(self.LO), math.log(self.HI)

    def add(self, a: torch.Tensor):
        a = a.detach().abs().reshape(-1).float()
        idx = torch.clamp(((torch.log(a.clamp(min=self.LO)) - self.lmin) / (self.lmax - self.lmin) * self.NB).long() + 1,
                          0, self.NB + 1)
        idx[a == 0] = 0
        self.c += torch.bincount(idx, minlength=self.NB + 2).double()
        self.n += a.numel()

    def mse_clip(self, bits: int = 8, rng: float | None = None) -> float:
        """The clipping range c that minimises E[(x - q_c(x))^2] for a symmetric uniform
        quantiser with 2^(bits-1)-1 positive levels, estimated from the histogram: inside
        the range the error is D^2/12 with D = c/qmax; outside it is (|x| - c)^2."""
        qmax = 2 ** (bits - 1) - 1
        edges = torch.exp(torch.linspace(self.lmin, self.lmax, self.NB + 1, dtype=torch.float64,
                                         device=self.c.device))
        mids = torch.cat([torch.zeros(1, dtype=torch.float64, device=self.c.device),
                          torch.sqrt(edges[:-1] * edges[1:]),
                          edges[-1:]])
        cnt = self.c
        hi = rng if rng is not None else float(mids[cnt > 0].max())
        best, best_c = None, hi
        for f in torch.linspace(0.02, 1.0, 197, dtype=torch.float64):
            c = float(f) * hi
            inside = (mids <= c).double()
            e = (cnt * (inside * (c / qmax) ** 2 / 12.0 + (1 - inside) * (mids - c) ** 2)).sum()
            if best is None or float(e) < best:
                best, best_c = float(e), c
        return best_c

    def pct(self, p: float) -> float:
        cum = torch.cumsum(self.c, 0)
        k = int(torch.searchsorted(cum, torch.tensor(p / 100.0 * self.n, dtype=torch.float64, device=cum.device)))
        if k <= 0:
            return 0.0
        return float(math.exp(self.lmin + (min(k, self.NB) / self.NB) * (self.lmax - self.lmin)))


class Stats:
    """Per tensor over calibration: max|x|, max(x+), max(x-), per-channel max|x|, E[x^2],
    and a histogram.  SDPA's internal scores and probs are included as <node>__scores and
    <node>__probs."""

    def __init__(self, dev):
        self.dev = dev
        self.t = {}

    def add(self, name: str, x: torch.Tensor, cdim: int | None = None):
        x = x.detach()
        s = self.t.get(name)
        if s is None:
            s = self.t[name] = {"max_abs": 0.0, "pos": 0.0, "neg": 0.0, "pc": None, "pc_pos": None, "pc_neg": None,
                                "sq": 0.0, "n": 0,
                                "hist": Hist(self.dev), "shape": list(x.shape),
                                "cdim": channel_dim(x.shape) if cdim is None else cdim}
        a = x.abs()
        s["max_abs"] = max(s["max_abs"], float(a.max()))
        s["pos"] = max(s["pos"], float(x.clamp(min=0).max()))
        s["neg"] = max(s["neg"], float((-x).clamp(min=0).max()))
        d = s["cdim"]
        pc = a.transpose(0, d).reshape(a.shape[d], -1).amax(dim=1)
        s["pc"] = pc if s["pc"] is None else torch.maximum(s["pc"], pc)
        xp = x.transpose(0, d).reshape(x.shape[d], -1)
        pp, pn = xp.clamp(min=0).amax(dim=1), (-xp).clamp(min=0).amax(dim=1)
        s["pc_pos"] = pp if s["pc_pos"] is None else torch.maximum(s["pc_pos"], pp)
        s["pc_neg"] = pn if s["pc_neg"] is None else torch.maximum(s["pc_neg"], pn)
        s["sq"] += float((x.double() ** 2).sum())
        s["n"] += x.numel()
        s["hist"].add(x)


def mb_ranges(stats: Stats, gfed: set) -> dict:
    """ModelBlaster's range per tensor (what its int8 scale spans)."""
    r = {}
    for k, s in stats.t.items():
        if k.endswith("__probs"):
            r[k] = 1.0                      # fixed scale 1/127
        elif k in gfed:
            r[k] = max(s["pos"], min(s["neg"], GELU_NEG_FLOOR))
        else:
            r[k] = s["max_abs"]
    return r


def fq_tensor(x: torch.Tensor, spec, lo_zero: bool = False) -> torch.Tensor:
    if spec is None:
        return x
    kind = spec[0]
    bits = spec[1]
    qmax = 2 ** (bits - 1) - 1
    qmin = -qmax - 1
    if kind == "pt":
        s = max(float(spec[2]), 1e-12) / qmax
        return torch.clamp(torch.round(x / s), qmin, qmax) * s
    if kind == "dual":
        # two int8 codes of the same value from two dispatches of the same op: a coarse grid
        # spanning the range and a fine one `ratio` times finer; the fine code is used unless
        # it saturated.  spec = ("dual", 8, range, ratio)
        rng, ratio = float(spec[2]), float(spec[3])
        sc = max(rng, 1e-12) / qmax
        sf = sc / ratio
        zc = torch.clamp(torch.round(x / sc), qmin, qmax) * sc
        zf_raw = torch.round(x / sf)
        zf = torch.clamp(zf_raw, qmin, qmax) * sf
        return torch.where((zf_raw >= qmin) & (zf_raw <= qmax), zf, zc)
    if kind == "multi":
        # several int8 codes of the same value, from dispatches whose multipliers differ by
        # the given ratios; the finest code that did not saturate is used.
        # spec = ("multi", 8, range, (1, r1, r2, ...))
        rng, ratios = float(spec[2]), spec[3]
        sc = max(rng, 1e-12) / qmax
        out = torch.clamp(torch.round(x / sc), qmin, qmax) * sc
        for ratio in sorted(ratios):
            if ratio == 1:
                continue
            sf = sc / ratio
            zr = torch.round(x / sf)
            ok = (zr >= qmin) & (zr <= qmax)
            out = torch.where(ok, zr * sf, out)
        return out
    if kind == "pc":
        ranges, d = spec[2], spec[3]
        shape = [1] * x.dim()
        shape[d] = -1
        s = (ranges.clamp(min=1e-12) / qmax).view(shape).to(x.dtype)
        return torch.clamp(torch.round(x / s), qmin, qmax) * s
    raise ValueError(spec)


class FQInterp(torch.fx.Interpreter):
    """Runs the traced encoder with fake-quantised activations (cfg: tensor name -> spec)
    and an optional per-node transform hook (e.g. a scale migration)."""

    def __init__(self, gm, cfg: dict, stats: Stats | None = None, capture: dict | None = None,
                 pre_div: dict | None = None, post_mul: dict | None = None, pre_clip: dict | None = None):
        """pre_div[name] = (vector, dim): the tensor is divided by it per channel BEFORE it is
        quantised (a producer emitting a migrated tensor).  post_mul[name] = (vector, dim): the
        quantised tensor is multiplied back AFTER (a consumer reading per-channel scales).
        pre_clip[name] = (lo, hi): saturate before quantising (what a clamp in the producer
        would do; statistics see the clipped tensor)."""
        super().__init__(gm)
        self.cfg = cfg
        self.stats = stats
        self.capture = capture
        self.pre_div = pre_div or {}
        self.post_mul = post_mul or {}
        self.pre_clip = pre_clip or {}

    @staticmethod
    def _chan(v, d, x):
        shape = [1] * x.dim()
        shape[d] = -1
        return v.view(shape).to(x.dtype)

    def _post(self, name, r):
        if name in self.pre_clip:
            lo, hi = self.pre_clip[name]
            r = r.clamp(lo, hi)
        if name in self.pre_div:
            v, d = self.pre_div[name]
            r = r / self._chan(v, d, r)
        if self.stats is not None:
            self.stats.add(name, r)
        if self.capture is not None:
            self.capture[name] = r
        q = fq_tensor(r, self.cfg.get(name))
        if name in self.post_mul:
            v, d = self.post_mul[name]
            q = q * self._chan(v, d, q)
        return q

    def run_node(self, n):
        if is_sdpa(n):
            args, kwargs = self.fetch_args_kwargs_from_env(n)
            q, k, v = args[0], args[1], args[2]
            sc = kwargs.get("scale")
            sc = float(sc) if sc is not None else 1.0 / math.sqrt(q.shape[-1])
            scores = (q @ k.transpose(-1, -2)) * sc
            scores = self._post(f"{n.name}__scores", scores)
            probs = torch.softmax(scores, dim=-1)
            probs = self._post(f"{n.name}__probs", probs)
            out = probs @ v
            return self._post(n.name, out)
        r = super().run_node(n)
        if isinstance(r, torch.Tensor) and r.dtype == torch.float32 and n.op != "output":
            return self._post(n.name, r)
        return r


# ---- weights ------------------------------------------------------------------------------
def weight_modules(model) -> dict:
    return {name: mod for name, mod in model.named_modules()
            if isinstance(mod, (torch.nn.Linear, torch.nn.Conv2d))}


class WeightState:
    """Holds the float weights and applies a weight config in place."""

    def __init__(self, model):
        self.mods = weight_modules(model)
        self.fw = {k: m.weight.detach().clone() for k, m in self.mods.items()}
        self.fb = {k: (m.bias.detach().clone() if m.bias is not None else None) for k, m in self.mods.items()}

    def apply(self, wcfg: dict, override: dict | None = None, bias_override: dict | None = None):
        """wcfg: module name -> None | ("pt", bits) | ("pc", bits).  override: module name ->
        a float weight to use instead of the original (a migrated weight); bias_override the
        same for biases (kept float: ModelBlaster's int32 bias grid is fine enough)."""
        with torch.no_grad():
            for k, m in self.mods.items():
                if m.bias is not None:
                    m.bias.copy_(self.fb[k] if not bias_override or k not in bias_override else bias_override[k])
                w = self.fw[k] if not override or k not in override else override[k]
                spec = wcfg.get(k)
                if spec is None:
                    m.weight.copy_(w)
                    continue
                bits = spec[1]
                qmax = 2 ** (bits - 1) - 1
                if spec[0] == "pt":
                    s = w.abs().max().clamp(min=1e-12) / qmax
                    m.weight.copy_(torch.clamp(torch.round(w / s), -qmax, qmax) * s)
                elif spec[0] == "rg":
                    # rows split into G groups of similar row max, one per-tensor scale per
                    # group: what G separate engine dispatches over row subsets would use
                    G = int(spec[2])
                    rmax = w.abs().reshape(w.shape[0], -1).amax(dim=1)
                    order = torch.argsort(rmax)
                    s = torch.empty_like(rmax)
                    for grp in torch.chunk(order, G):
                        s[grp] = rmax[grp].max().clamp(min=1e-12) / qmax
                    s = s.view([-1] + [1] * (w.dim() - 1))
                    m.weight.copy_(torch.clamp(torch.round(w / s), -qmax, qmax) * s)
                else:
                    s = w.abs().reshape(w.shape[0], -1).amax(dim=1).clamp(min=1e-12) / qmax
                    s = s.view([-1] + [1] * (w.dim() - 1))
                    m.weight.copy_(torch.clamp(torch.round(w / s), -qmax, qmax) * s)

    def restore(self):
        self.apply({})


# ---- metrics ------------------------------------------------------------------------------
def sqnr_db(ref: list, got: list) -> float:
    num = sum(float((r.double() ** 2).sum()) for r in ref)
    den = sum(float(((r.double() - g.double()) ** 2).sum()) for r, g in zip(ref, got))
    return 10.0 * math.log10(num / max(den, 1e-30))


def cosine(ref: list, got: list) -> float:
    cs = [float((r.reshape(-1).double() @ g.reshape(-1).double()) /
                (r.double().norm() * g.double().norm() + 1e-30)) for r, g in zip(ref, got)]
    return float(np.mean(cs))


class Decoder:
    """HF's float Moonshine decoder, greedy, batched on the encoder output."""

    def __init__(self, dev, max_new_tokens: int = 40):
        from transformers import MoonshineForConditionalGeneration, PreTrainedTokenizerFast
        self.hf = MoonshineForConditionalGeneration.from_pretrained(str(me.moonshine_dir())).eval().to(dev)
        self.tok = PreTrainedTokenizerFast(tokenizer_file=os.path.join(str(me.moonshine_dir()), "tokenizer.json"))
        self.dev = dev
        self.max_new_tokens = max_new_tokens

    def __call__(self, hs: list, batch: int = 64) -> list:
        from transformers.modeling_outputs import BaseModelOutput
        out = []
        with torch.no_grad():
            for i in range(0, len(hs), batch):
                h = torch.cat([x.reshape(1, me.T, me.D) for x in hs[i:i + batch]], 0).to(self.dev)
                ids = self.hf.generate(encoder_outputs=BaseModelOutput(last_hidden_state=h),
                                       max_new_tokens=self.max_new_tokens, do_sample=False, num_beams=1)
                out += [self.tok.decode(r, skip_special_tokens=True) for r in ids]
        return out


def norm_text(s: str) -> list:
    import re
    s = s.upper()
    s = re.sub(r"[^A-Z' ]+", " ", s)
    return s.split()


def wer(refs: list, hyps: list) -> dict:
    e = n = 0
    for r, h in zip(refs, hyps):
        r, h = norm_text(r), norm_text(h)
        d = list(range(len(h) + 1))
        for i, rw in enumerate(r, 1):
            prev, d[0] = d[0], i
            for j, hw in enumerate(h, 1):
                cur = min(d[j] + 1, d[j - 1] + 1, prev + (rw != hw))
                prev, d[j] = d[j], cur
        e += d[len(h)]
        n += len(r)
    return {"wer": e / max(n, 1), "errors": e, "words": n, "utterances": len(refs)}
