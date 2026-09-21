#!/usr/bin/env python3
"""Moonshine Tiny's speech DECODER, ONE STEP, in a form ModelBlaster's int8 FX path can emit.

The encoder's counterpart is `moonshine_enc.py`; this follows its pattern exactly -- a second
implementation of transformers v4.48.0 `MoonshineDecoder` against the same pinned checkpoint,
with every construct replaced by one ModelBlaster can lower.

WHY ONE STEP AND NOT A LOOP.  `MOONSHINE_MODEL.md` section 5: the generated model exports one
function pointer per dispatch (`MODEL_<MID>_DISPATCH_FNS[]`) and its intermediate buffers are
file-static, so the autoregressive loop, `argmax`, the embedding lookup and the EOS test are
DRIVER work between dispatches.  A single step called N times is ~185 dispatches where an N = 24
unroll is ~4,440, and it keeps early exit as a saving rather than a fixed cost.

THE STATE IS INPUTS, NOT MUTATION.  FX cannot see in-place buffer writes, so every piece of
carried state is an explicit input tensor of fixed shape:

    h        [1, 1, D]            the current token, already embedded by the driver
    kc, vc   [1, L, D] x layers   the self-attention KV cache, slots 0..t-1 valid
    kc, vc   are [1, L, D, 1] NCHW -- see MbDecSelfAttn
    kx, vx   [1, S, D] x layers   the encoder's keys and values, computed ONCE per utterance
                                  by build_cross_prologue() -- not per step
    mask     [1, 1, 1, L + 1]     0 for valid slots, a large negative for the rest; the driver
                                  fills it, which is what keeps every step the same shape

The cache concatenation is on dim 1 with the heads still folded into D ([1, L, 288] rather than
[1, H, L, 36]) SO THAT IT IS A `cat2_c1_s8`: the extractor's cat kinds are channel-dim-1 only.
The head split happens after the concat, as a view, exactly as the encoder does it.
"""
from __future__ import annotations

import os
import sys

import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import moonshine_enc as me  # noqa: E402

D, HEADS, HEAD_DIM = me.D, me.HEADS, me.HEAD_DIM
ROT, THETA = me.ROT, me.THETA
FF_GATED = 2 * 1152          # decoder mlp fc1 is 2304 = 2 x 1152, SiLU-gated
LAYERS = 6
S_ENC = me.T                 # 165 encoder positions at the 4.0 s window
L_CACHE = int(os.environ.get("MOONSHINE_DEC_CACHE", "24"))   # the N cap, section 5.4


class MbDecRoPE(nn.Module):
    """RoPE at ONE FIXED position, baked.

    THE CONSTRAINT THAT SHAPES THIS WHOLE FILE.  `rope_s8`'s lowering takes ONE input and bakes
    cos/sin as a WEIGHT whose shape must be exactly (T, rotary/2), where T is the input's own
    sequence dimension (extract_graph.py, the `mb_op == "rope_s8"` branch).  A decoder step has
    T = 1 and a position that changes every step, so a single step graph with a RUNTIME position
    cannot use it: the table would have to be an input, and it is a weight.

    So the position is a COMPILE-TIME constant and each step gets its own graph -- which is the
    unrolled decoder, and is why unrolling turns out to be necessary after all.  Not for the loop,
    which is driver work (MOONSHINE_MODEL.md section 5.3), but for the rotary.
    """
    mb_fx_leaf = True
    mb_op = "rope_s8"
    mb_interleaved = True

    def __init__(self, pos: int, table_key: str | None = None):
        super().__init__()
        self.rotary_dim = ROT
        self.pos = int(pos)
        if table_key:
            self.mb_table_key = table_key
        r = ROT
        inv = 1.0 / (THETA ** (torch.arange(0, r, 2, dtype=torch.int64).float() / r))
        p = torch.tensor([[float(pos)]])
        f = (inv[None, :, None].float().expand(1, -1, 1) @ p[:, None, :].float()).transpose(1, 2)
        emb = torch.cat((f, f), dim=-1)
        self.register_buffer("cos_tab", emb.cos()[0, :, : r // 2].contiguous(), persistent=False)
        self.register_buffer("sin_tab", emb.sin()[0, :, : r // 2].contiguous(), persistent=False)

    def forward(self, x):                            # x [1, 1, H, Dh]
        cos = self.cos_tab.repeat_interleave(2, dim=-1)[None, :, None, :]
        sin = self.sin_tab.repeat_interleave(2, dim=-1)[None, :, None, :]
        xr, xp = x[..., :ROT], x[..., ROT:]
        x1, x2 = xr[..., 0::2], xr[..., 1::2]
        rot = torch.stack((-x2, x1), dim=-1).flatten(-2)
        return torch.cat([(xr * cos) + (rot * sin), xp], dim=-1)


class MbDecSelfAttn(nn.Module):
    def __init__(self, pos: int):
        super().__init__()
        self.pos = int(pos)
        for n in ("q_proj", "k_proj", "v_proj", "o_proj"):
            setattr(self, n, nn.Linear(D, D, bias=False))
        self.rope_q = MbDecRoPE(pos, f"rope.p{pos}")
        self.rope_k = MbDecRoPE(pos, f"rope.p{pos}")

    def forward(self, x, kc, vc):                    # x [1,1,D]  kc/vc [1,pos,D,1]
        q = self.rope_q(self.q_proj(x).view(1, 1, HEADS, HEAD_DIM))
        kn = self.rope_k(self.k_proj(x).view(1, 1, HEADS, HEAD_DIM)).reshape(1, 1, D)
        vn = self.v_proj(x)
        # The cache is carried as 4D NCHW [1, L, D, 1] because the extractor's cat kinds accept
        # only 2D [N, C] or 4D NCHW -- a 3D [1, L, D] concat is refused.  C is the cache slot, so
        # the concat is still on dim 1 and still lowers to cat2_c1_s8.
        n = self.pos + 1
        k = (kn.view(1, 1, D, 1) if self.pos == 0 else torch.cat([kc, kn.view(1, 1, D, 1)], dim=1))
        v = (vn.view(1, 1, D, 1) if self.pos == 0 else torch.cat([vc, vn.view(1, 1, D, 1)], dim=1))
        k = k.view(1, n, HEADS, HEAD_DIM).permute(0, 2, 1, 3)
        v = v.view(1, n, HEADS, HEAD_DIM).permute(0, 2, 1, 3)
        q = q.permute(0, 2, 1, 3)
        # NO MASK.  extract_graph refuses sdpa with attn_mask and refuses is_causal; at step
        # `pos` the cache holds exactly `pos` past tokens and every one of them is valid, so the
        # causal structure is the SHAPE and no mask is needed.  That is the second independent
        # reason this decoder is unrolled.
        o = F.scaled_dot_product_attention(q, k, v)
        o = o.permute(0, 2, 1, 3).reshape(1, 1, D)
        return self.o_proj(o), kn, vn


class MbDecCrossAttn(nn.Module):
    """Cross-attention. k/v come in as INPUTS: they are the encoder's, computed once per utterance."""

    def __init__(self):
        super().__init__()
        self.q_proj = nn.Linear(D, D, bias=False)
        self.o_proj = nn.Linear(D, D, bias=False)

    def forward(self, x, kx, vx):                    # kx/vx [1, S, D]
        q = self.q_proj(x).view(1, 1, HEADS, HEAD_DIM).permute(0, 2, 1, 3)
        k = kx.view(1, S_ENC, HEADS, HEAD_DIM).permute(0, 2, 1, 3)
        v = vx.view(1, S_ENC, HEADS, HEAD_DIM).permute(0, 2, 1, 3)
        o = F.scaled_dot_product_attention(q, k, v)
        return self.o_proj(o.permute(0, 2, 1, 3).reshape(1, 1, D))


class MbDecMLP(nn.Module):
    """SiLU-gated MLP.  `decoder_hidden_act = silu`.

    HF keeps one `fc1` of 2304 = 2 x 1152 and chunks it.  The extractor supports `chunk(2, dim=1)`
    only, and the chunk here is on the last dim of [1, 1, 2304], so the weight is SPLIT AT LOAD
    TIME into two 1152-row linears instead.  Same arithmetic, same MACs, one fewer op kind to
    support, and `mul_s8` already has a curated kernel (`pext_nl_mul_s8_pext_int_mul.c`).
    """

    def __init__(self):
        super().__init__()
        half = FF_GATED // 2
        self.gate = nn.Linear(D, half)
        self.up = nn.Linear(D, half)
        self.act = nn.SiLU()
        self.fc2 = nn.Linear(half, D)

    def forward(self, x):
        return self.fc2(self.act(self.gate(x)) * self.up(x))


class MbDecoderLayer(nn.Module):
    def __init__(self, pos: int):
        super().__init__()
        self.input_layernorm = nn.LayerNorm(D, bias=False)
        self.self_attn = MbDecSelfAttn(pos)
        self.post_attention_layernorm = nn.LayerNorm(D, bias=False)
        self.encoder_attn = MbDecCrossAttn()
        self.final_layernorm = nn.LayerNorm(D, bias=False)
        self.mlp = MbDecMLP()

    def forward(self, x, kc, vc, kx, vx):
        a, kn, vn = self.self_attn(self.input_layernorm(x), kc, vc)
        x = x + a
        x = x + self.encoder_attn(self.post_attention_layernorm(x), kx, vx)
        x = x + self.mlp(self.final_layernorm(x))
        return x, kn, vn


class MoonshineDecoderStepMb(nn.Module):
    """One decoder step: [1,1,D] in, logits [1,1,V] out, plus this step's k and v per layer."""

    def __init__(self, pos: int, layers: int = LAYERS, vocab: int = 32768):
        super().__init__()
        self.pos = int(pos)
        self.layers = nn.ModuleList([MbDecoderLayer(pos) for _ in range(layers)])
        self.norm = nn.LayerNorm(D, bias=False)
        self.lm_head = nn.Linear(D, vocab, bias=False)

    # FX traces *varargs as ONE placeholder, so the 24 carried-state tensors have to be named
    # parameters.  The signature is generated rather than typed out 24 times, and the ORDER is the
    # contract the driver relies on: h, then kc0..kc5, vc0..vc5, kx0..kx5, vx0..vx5.
    _SIG = (["h"] + [f"kc{i}" for i in range(LAYERS)] + [f"vc{i}" for i in range(LAYERS)]
            + [f"kx{i}" for i in range(LAYERS)] + [f"vx{i}" for i in range(LAYERS)])

    def _body(self, h, kc, vc, kx, vx):
        outk, outv = [], []
        for i, lyr in enumerate(self.layers):
            h, kn, vn = lyr(h, kc[i], vc[i], kx[i], vx[i])
            outk.append(kn)
            outv.append(vn)
        return (self.lm_head(self.norm(h)), *outk, *outv)


_ns: dict = {}
exec(  # noqa: S102 - the signature is built from LAYERS, not from input
    "def _fwd(self, " + ", ".join(MoonshineDecoderStepMb._SIG) + "):\n"
    "    n = " + str(LAYERS) + "\n"
    "    return self._body(h, [" + ", ".join(f"kc{i}" for i in range(LAYERS)) + "], "
    "[" + ", ".join(f"vc{i}" for i in range(LAYERS)) + "], "
    "[" + ", ".join(f"kx{i}" for i in range(LAYERS)) + "], "
    "[" + ", ".join(f"vx{i}" for i in range(LAYERS)) + "])\n", _ns)
MoonshineDecoderStepMb.forward = _ns["_fwd"]


def sample_inputs(pos: int = 3, seed: int = 0):
    g = torch.Generator().manual_seed(seed)
    def r(*sh):
        return torch.randn(*sh, generator=g)
    c = max(pos, 1)
    st = ([r(1, c, D, 1) for _ in range(LAYERS)] + [r(1, c, D, 1) for _ in range(LAYERS)]
          + [r(1, S_ENC, D) for _ in range(LAYERS)] + [r(1, S_ENC, D) for _ in range(LAYERS)])
    return [r(1, 1, D), *st]


def build_step(pos: int = 3):
    return MoonshineDecoderStepMb(pos).eval()


def build_layer(pos: int = 3):
    """The PROBE: one layer, the cheapest thing that answers 'does a decoder trace?'"""
    class One(nn.Module):
        def __init__(self):
            super().__init__()
            self.lyr = MbDecoderLayer(pos)

        def forward(self, h, kc, vc, kx, vx):
            return self.lyr(h, kc, vc, kx, vx)
    return One().eval()


def layer_sample(pos: int = 3, seed: int = 0):
    g = torch.Generator().manual_seed(seed)
    def r(*s):
        return torch.randn(*s, generator=g)
    return [r(1, 1, D), r(1, max(pos, 1), D, 1), r(1, max(pos, 1), D, 1),
            r(1, S_ENC, D), r(1, S_ENC, D)]


# ======================================================================================
# Real weights.
# ======================================================================================
def _hf_state():
    import model_vocab as mv
    m, _ = mv.load_hf("cpu")
    return m, m.state_dict()


def load_step(step: nn.Module, sd: dict) -> nn.Module:
    """Map the pinned checkpoint onto the ported step.

    THE ONE THAT WOULD HAVE BEEN SILENT.  HF's decoder MLP is

        hidden_states, gate = self.fc1(x).chunk(2, dim=-1)
        hidden_states = self.activation_fn(gate) * hidden_states

    so the FIRST half of fc1 is the multiplied path and the SECOND half is the one SiLU sees.
    This port calls them `up` and `gate` respectively, so `gate` takes rows 1152:2304 and `up`
    takes rows 0:1152.  Getting that backwards produces a model that runs, transcribes badly, and
    looks exactly like quantisation error.
    """
    p = "model.decoder."
    half = FF_GATED // 2
    with torch.no_grad():
        for i, lyr in enumerate(step.layers):
            b = f"{p}layers.{i}."
            lyr.input_layernorm.weight.copy_(sd[b + "input_layernorm.weight"])
            lyr.post_attention_layernorm.weight.copy_(sd[b + "post_attention_layernorm.weight"])
            lyr.final_layernorm.weight.copy_(sd[b + "final_layernorm.weight"])
            for n in ("q_proj", "k_proj", "v_proj", "o_proj"):
                getattr(lyr.self_attn, n).weight.copy_(sd[b + f"self_attn.{n}.weight"])
            for n in ("q_proj", "o_proj"):
                getattr(lyr.encoder_attn, n).weight.copy_(sd[b + f"encoder_attn.{n}.weight"])
            w1, b1 = sd[b + "mlp.fc1.weight"], sd[b + "mlp.fc1.bias"]
            lyr.mlp.up.weight.copy_(w1[:half])        # first chunk  -> multiplied
            lyr.mlp.up.bias.copy_(b1[:half])
            lyr.mlp.gate.weight.copy_(w1[half:])      # second chunk -> SiLU
            lyr.mlp.gate.bias.copy_(b1[half:])
            lyr.mlp.fc2.weight.copy_(sd[b + "mlp.fc2.weight"])
            lyr.mlp.fc2.bias.copy_(sd[b + "mlp.fc2.bias"])
        step.norm.weight.copy_(sd[p + "norm.weight"])
        step.lm_head.weight.copy_(sd[p + "embed_tokens.weight"])   # tied
    return step


class MbCrossPrologue(nn.Module):
    """kx/vx for every layer from the encoder's output -- ONCE per utterance, not per step."""

    def __init__(self):
        super().__init__()
        self.k = nn.ModuleList([nn.Linear(D, D, bias=False) for _ in range(LAYERS)])
        self.v = nn.ModuleList([nn.Linear(D, D, bias=False) for _ in range(LAYERS)])

    def forward(self, enc):                          # [1, S, D]
        return [k(enc) for k in self.k] + [v(enc) for v in self.v]


def load_prologue(pro: nn.Module, sd: dict) -> nn.Module:
    with torch.no_grad():
        for i in range(LAYERS):
            pro.k[i].weight.copy_(sd[f"model.decoder.layers.{i}.encoder_attn.k_proj.weight"])
            pro.v[i].weight.copy_(sd[f"model.decoder.layers.{i}.encoder_attn.v_proj.weight"])
    return pro


def build_real(pos: int):
    """(step, prologue, embed_tokens) with the pinned checkpoint loaded."""
    m, sd = _hf_state()
    step = load_step(MoonshineDecoderStepMb(pos).eval(), sd)
    pro = load_prologue(MbCrossPrologue().eval(), sd)
    emb = sd["model.decoder.embed_tokens.weight"].clone()
    return step, pro, emb, m


# ======================================================================================
# The unrolled decoder: ONE graph, N steps, weights shared.
# ======================================================================================
class MoonshineDecoderUnrolledMb(nn.Module):
    """N decoder steps in one graph, sharing one set of weights.

    WHY ONE GRAPH AND NOT N.  Each step's weights are identical -- only the rotary table and the
    cache length differ -- so N separately generated models would bake N copies of 19.39 MB.  At
    N = 24 that is 466 MB of weights against the guest's 256 MB reservation: over budget, and the
    duplication is pure waste.  Traced as one graph the extractor sees one weight per module and
    emits it once.

    THE KV CACHE DISAPPEARS.  Unrolled, step k's keys are just tensors computed earlier in the
    same graph, so there is no cache input, no cache output and nothing for a driver to copy --
    the `cat` chain is internal.  What the driver still owns is the token feedback: `h_k` is an
    INPUT, filled with the embedding of the token argmax'd from step k-1's logits.  That is why
    the logits are per-step outputs and why early exit is a bound on the dispatch table.

    Only the rotary differs per step, and its tables are separate weights keyed by position.
    """

    def __init__(self, n_steps: int, layers: int = LAYERS, vocab: int = 32768):
        super().__init__()
        self.n_steps = int(n_steps)
        # ONE set of layer weights, reused at every position.  The rotary is the only
        # position-dependent part, so each step gets its own rope tables and nothing else.
        self.layers = nn.ModuleList([MbDecoderLayer(0) for _ in range(layers)])
        self.ropes = nn.ModuleList([
            nn.ModuleList([MbDecRoPE(p, f"rope.p{p}") for _ in range(2 * layers)])
            for p in range(self.n_steps)])
        self.norm = nn.LayerNorm(D, bias=False)
        self.lm_head = nn.Linear(D, vocab, bias=False)

    def _step(self, h, kc, vc, kx, vx, pos):
        """One position.  `kc`/`vc` are lists of this layer's previous keys, [1,1,D,1] each."""
        outk, outv = [], []
        for i, lyr in enumerate(self.layers):
            r = lyr.self_attn
            x = lyr.input_layernorm(h)
            rq, rk = self.ropes[pos][2 * i], self.ropes[pos][2 * i + 1]
            q = rq(r.q_proj(x).view(1, 1, HEADS, HEAD_DIM))
            kn = rk(r.k_proj(x).view(1, 1, HEADS, HEAD_DIM)).reshape(1, 1, D)
            vn = r.v_proj(x)
            # The cache accumulates PAIRWISE: `cat` is supported with 2, 3 or 4 inputs, so a
            # list-of-k concat fails at step 4.  Carrying a running tensor makes every cat
            # binary and keeps the graph the same shape at every position.
            kn4, vn4 = kn.view(1, 1, D, 1), vn.view(1, 1, D, 1)
            ks = kn4 if kc[i] is None else torch.cat([kc[i], kn4], dim=1)
            vs = vn4 if vc[i] is None else torch.cat([vc[i], vn4], dim=1)
            n = pos + 1
            k = ks.view(1, n, HEADS, HEAD_DIM).permute(0, 2, 1, 3)
            v = vs.view(1, n, HEADS, HEAD_DIM).permute(0, 2, 1, 3)
            o = F.scaled_dot_product_attention(q.permute(0, 2, 1, 3), k, v)
            h = h + r.o_proj(o.permute(0, 2, 1, 3).reshape(1, 1, D))
            h = h + lyr.encoder_attn(lyr.post_attention_layernorm(h), kx[i], vx[i])
            h = h + lyr.mlp(lyr.final_layernorm(h))
            outk.append(ks)
            outv.append(vs)
        return self.lm_head(self.norm(h)), outk, outv

    def _body(self, hs, kx, vx):
        kc = [None for _ in self.layers]
        vc = [None for _ in self.layers]
        out = []
        for p in range(self.n_steps):
            lg, kc, vc = self._step(hs[p], kc, vc, kx, vx, p)
            out.append(lg)
        return tuple(out)


def make_unrolled(n_steps: int, layers: int = LAYERS):
    """Build the class with an explicit (h_0..h_{N-1}, kx0..,vx0..) signature -- FX needs names."""
    cls = MoonshineDecoderUnrolledMb
    hs = [f"h{p}" for p in range(n_steps)]
    kxs = [f"kx{i}" for i in range(layers)]
    vxs = [f"vx{i}" for i in range(layers)]
    src = ("def _fwd(self, " + ", ".join(hs + kxs + vxs) + "):\n"
           "    return self._body([" + ", ".join(hs) + "], [" + ", ".join(kxs) + "], "
           "[" + ", ".join(vxs) + "])\n")
    ns: dict = {}
    exec(src, ns)  # noqa: S102 - built from n_steps, not from input
    # FX's symbolic_trace looks up `forward` on the CLASS, so a bound instance attribute is
    # invisible to it.  Give each N its own subclass instead.
    sub = type(f"MoonshineDecoderUnrolled{n_steps}Mb", (cls,), {"forward": ns["_fwd"]})
    m = sub(n_steps, layers)
    m._sig = hs + kxs + vxs
    return m.eval()


def unrolled_sample(n_steps: int, layers: int = LAYERS, seed: int = 0):
    g = torch.Generator().manual_seed(seed)
    def r(*s):
        return torch.randn(*s, generator=g)
    return ([r(1, 1, D) for _ in range(n_steps)]
            + [r(1, S_ENC, D) for _ in range(layers)] + [r(1, S_ENC, D) for _ in range(layers)])


def load_unrolled(m: nn.Module, sd: dict) -> nn.Module:
    """Same mapping as load_step -- the layer stack is shared, so it is loaded once."""
    return load_step(m, sd)


# ======================================================================================
# THE PROLOGUE, LOWERED (Lab B112).
#
# Everything above treats `kx`/`vx` as INPUTS: the host runs MbCrossPrologue in float and
# packs twelve [1, 165, 288] tensors into the board's input, 570,240 of the 577,152 packed
# bytes.  The two classes below are the same arithmetic with the prologue INSIDE the graph,
# so `kx`/`vx` are intermediate tensors the board computes and the packed input is the
# encoder's ONE hidden state -- 47,520 B -- plus the 24 `h` slots.
#
# WHY THE PROLOGUE IS A PREPENDED REGION OF THE DECODER AND NOT ITS OWN MODEL.
# samples/modelblaster_pext takes ONE -DMODEL_DIR and walks ONE dispatch table; a second
# model needs a second MODEL_DIR, a second weight arena and a second dispatch table, which
# is the work item nobody has started.  And the 16.73 MB saving is not the prologue's
# ARITHMETIC moving to the board -- it is `kx`/`vx` never crossing the packed-input
# boundary, which happens only if they are internal tensors of the decoder's own graph.
# As a separate model the driver would have to copy twelve [165, 288] outputs back into the
# decoder's packed input every utterance and the bytes would still be there.
#
# `MbCrossPrologueMb` is the SAME twelve ops on their own, for measurement only: a probe
# whose IR ops, weights and scales are identical to the twelve inside the decoder graph, so
# a board arm can price them without 4,488 other dispatches in the way.
#
# THE NAMES ARE THE CONTRACT.  `pk`/`pv` rather than `k`/`v` so that FX's node names
# (`pk_0`..`pk_5`, `pv_0`..`pv_5`) cannot collide with anything the decoder already emits,
# and every other node in the traced graph keeps the name it has in the banked IR -- which
# is what lets the banked decoder's activation scales be pinned onto this graph by name and
# the two IRs be diffed tensor for tensor.
# ======================================================================================
def load_prologue_into(pk: nn.ModuleList, pv: nn.ModuleList, sd: dict) -> None:
    """load_prologue's mapping, onto a `pk`/`pv` pair held by another module."""
    with torch.no_grad():
        for i in range(len(pk)):
            b = f"model.decoder.layers.{i}.encoder_attn."
            pk[i].weight.copy_(sd[b + "k_proj.weight"])
            pv[i].weight.copy_(sd[b + "v_proj.weight"])


class MbCrossPrologueMb(nn.Module):
    """The twelve cross-attention projections ALONE, as an extractable graph.

    MbCrossPrologue returns a Python list, which is what the unrolled decoder wants and what
    FX cannot make an output tuple of shapes out of.  This returns the tuple, and uses the
    `pk`/`pv` names so its twelve ops carry the same tensor names they carry inside the
    decoder graph.
    """

    def __init__(self, layers: int = LAYERS):
        super().__init__()
        self.pk = nn.ModuleList([nn.Linear(D, D, bias=False) for _ in range(layers)])
        self.pv = nn.ModuleList([nn.Linear(D, D, bias=False) for _ in range(layers)])

    def forward(self, enc):                          # [1, S, D] -> 12 x [1, S, D]
        return (*[m(enc) for m in self.pk], *[m(enc) for m in self.pv])


class MoonshineDecoderUnrolledProMb(MoonshineDecoderUnrolledMb):
    """The unrolled decoder with the cross-attention prologue prepended.

    Signature `(enc, h_0 .. h_{N-1})`.  The layer stack, the rotary tables, the final norm
    and the tied head are the base class's, untouched and loaded by the same `load_step`
    mapping, so a graph extracted from this differs from one extracted from the base class
    by exactly twelve `linear_s8` ops and by which tensors are inputs.
    """

    def __init__(self, n_steps: int, layers: int = LAYERS, vocab: int = 32768):
        super().__init__(n_steps, layers, vocab)
        self.pk = nn.ModuleList([nn.Linear(D, D, bias=False) for _ in range(layers)])
        self.pv = nn.ModuleList([nn.Linear(D, D, bias=False) for _ in range(layers)])

    def _body_pro(self, enc, hs):
        return self._body(hs, [m(enc) for m in self.pk], [m(enc) for m in self.pv])


def make_unrolled_pro(n_steps: int, layers: int = LAYERS):
    """make_unrolled's trick, with `enc` in front of the h's -- FX needs the names."""
    hs = [f"h{p}" for p in range(n_steps)]
    src = ("def _fwd(self, enc, " + ", ".join(hs) + "):\n"
           "    return self._body_pro(enc, [" + ", ".join(hs) + "])\n")
    ns: dict = {}
    exec(src, ns)  # noqa: S102 - built from n_steps, not from input
    sub = type(f"MoonshineDecoderUnrolledPro{n_steps}Mb",
               (MoonshineDecoderUnrolledProMb,), {"forward": ns["_fwd"]})
    m = sub(n_steps, layers)
    m._sig = ["enc"] + hs
    return m.eval()


def load_unrolled_pro(m: nn.Module, sd: dict) -> nn.Module:
    load_step(m, sd)
    load_prologue_into(m.pk, m.pv, sd)
    return m


def unrolled_pro_sample(n_steps: int, layers: int = LAYERS, seed: int = 0):
    g = torch.Generator().manual_seed(seed)
    def r(*s):
        return torch.randn(*s, generator=g)
    return [r(1, S_ENC, D)] + [r(1, 1, D) for _ in range(n_steps)]
