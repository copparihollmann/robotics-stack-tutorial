#!/usr/bin/env python3
"""Moonshine Tiny's speech ENCODER, written in a form ModelBlaster's int8 FX path can emit.

WHAT THIS IS.  A second implementation of transformers v4.48.0 `MoonshineEncoder`
(modeling_moonshine.py) that loads the SAME pinned checkpoint
(UsefulSensors/moonshine-tiny @ 390624ed, model.safetensors sha256 867cd221...) and computes
the same function, with every construct replaced by one ModelBlaster can lower to a kernel:

    HF                                      here                          IR op
    Conv1d(1, 288, 127, s64, no bias)       Conv2d (1,127) s(1,64)        conv2d_s8
    F.tanh                                  nn.Tanh                       tanh_s8
    GroupNorm(1, 288, eps 1e-5)             nn.GroupNorm, same            groupnorm_s8
    Conv1d(288, 576, 7, s3) + F.gelu        Conv2d (1,7) s(1,3) + nn.GELU conv2d_s8, gelu_s8
    Conv1d(576, 288, 3, s2) + F.gelu        Conv2d (1,3) s(1,2) + nn.GELU conv2d_s8, gelu_s8
    permute(0, 2, 1)                        permute(0, 2, 3, 1) + reshape permute4_s8, view
    q/k/v_proj(x).view(1,T,8,36)            same                          linear_s8, view
    .transpose(1, 2) then apply_rotary      MbRoPE on [1,T,8,36], then    rope_s8,
                                            permute(0, 2, 1, 3)           permute4_s8
    SDPA(scale 1/sqrt(36), no mask)         F.scaled_dot_product_attention matmul_b_s8,
                                                                          softmax_s8,
                                                                          matmul_b_s8
    transpose(1,2).reshape(1,T,288), o_proj permute + reshape + Linear    permute4_s8, view,
                                                                          linear_s8
    residual +                              operator.add                  add_s8
    LayerNorm(288, bias=False)              same                          layernorm_s8

Conv1d is written as Conv2d with TIME ON W, (1, k) kernels over [N, C, 1, T]: that is the
layout SPEECH_ON_ROCKET.md 11.4 measured at 1.24 cycles/MAC against 20.92 for time-on-H.
build_stem("h") builds the stem alone as (k, 1) kernels over [N, C, T, 1], and
build_stem("w") the same stem as the encoder uses it, so the layout lever can be measured
on Moonshine's own stem (ModelBlaster models moonshine_stem_h / moonshine_stem_w).

MbRoPE is a LEAF module (mb_fx_leaf = True): the FX tracer sees one node for the whole
rotation, so the rotary embedding is one dispatch with its own cycle count rather than the
eight-node mul/neg/stack/flatten/cat subgraph HF traces to.  Its forward is HF's
apply_rotary_pos_emb verbatim in float32 (interleaved rotate_half, 32 of 36 dims), with
cos/sin computed from the model's own inv_freq exactly as MoonshineRotaryEmbedding does,
over positions 0..T-1.

Multi-head attention is NOT a leaf: the permutes are real IR ops and the SDPA call is a
4-D [1, heads, T, head_dim] call, which patches/0100 lowers per head (matmul_b_s8).

THE INPUT WINDOW IS ONE SHAPE PER BUILD: 4.0 s at 16 kHz = 64,000 samples -> 999 -> 331 ->
165 frames by default, and MOONSHINE_WINDOW_S picks another (the shape ladder, ROCC_DECOUPLED.md
s8.15.11).  Every shape below is derived from it.

WEIGHTS ARE NOT COMMITTED.  fetch_moonshine.sh downloads the pinned revision into
$MOONSHINE_DIR (default $IISWC_ROOT/out/moonshine) and checks every sha256.

SPEECH.  hf-internal-testing/librispeech_asr_dummy @ 5be91486 (LibriSpeech dev-clean,
73 utterances, ONE speaker, three chapters), decoded once by fetch_moonshine.sh into
$MOONSHINE_DIR/speech.npz.  The split is fixed and documented in speech_split():
  * EVAL: the 16 utterances that fit a 4 s window whole, so their reference transcript is
    the whole transcript.
  * CALIBRATION: 16 of the other 57, EVENLY SPACED over the id-sorted list (so across all
    three chapters), centre-cropped to 4 s -- never the first N of a sorted set
    (TODO.md, "Calibration frames must be drawn across classes").
  * AGREEMENT: 8 further long utterances, evenly spaced over what calibration did not
    take, centre-cropped; no reference transcript fits, so they are used only to compare
    int8 against float.

Usage:
    python3 moonshine_enc.py --check-hf       # port vs transformers MoonshineEncoder
    (needs transformers 4.48.0 importable: PYTHONPATH=$MOONSHINE_DIR/pylib)
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = pathlib.Path(__file__).resolve().parent
ROOT = pathlib.Path(os.environ.get("IISWC_ROOT", str(HERE.parents[3])))

CKPT_REPO = "UsefulSensors/moonshine-tiny"
CKPT_REV = "390624ed33d594443aa4aa221f5b9f283b545b5a"
SPEECH_REPO = "hf-internal-testing/librispeech_asr_dummy"
SPEECH_REV = "5be91486e11a2d616f4ec5db8d3fd248585ac07a"

SR = 16000
# THE WINDOW IS A PARAMETER, and everything shaped by it is derived below: the three stem
# convolutions' output lengths, T, the rotary table, every attention shape, and window().  A
# ModelBlaster IR is built for ONE shape, so a "shape ladder" (ROCC_DECOUPLED.md s8.15.11) is
# several extractions of this same port at different windows over the SAME weights -- which is
# why this is an environment variable and not an argument: extract_graph imports the port.
#   MOONSHINE_WINDOW_S=3.0 python3 ... -> 48,000 samples -> 749 -> 248 -> 123 frames
# 4.0 is the default and is what every measurement before 2026-09-17 used.
WINDOW_S = float(os.environ.get("MOONSHINE_WINDOW_S", "4.0"))
N_SAMPLES = int(SR * WINDOW_S)
if N_SAMPLES < 8000:
    raise SystemExit("MOONSHINE_WINDOW_S=%g is under 0.5 s: the stem needs 127 samples of kernel "
                     "and three strides, and under about 1 s the per-dispatch cost dominates" % WINDOW_S)

# config.json @ 390624ed
D, FF, HEADS, LAYERS = 288, 1152, 8, 6
HEAD_DIM = D // HEADS                       # 36
ROT = int(HEAD_DIM * 0.9)                   # partial_rotary_factor 0.9 -> 32
THETA = 10000.0
GN_EPS = 1e-5


def conv_out(n: int, k: int, s: int) -> int:
    return (n - k) // s + 1


T1 = conv_out(N_SAMPLES, 127, 64)           # 999
T2 = conv_out(T1, 7, 3)                     # 331
T = conv_out(T2, 3, 2)                      # 165


def moonshine_dir() -> pathlib.Path:
    return pathlib.Path(os.environ.get("MOONSHINE_DIR", str(ROOT / "out" / "moonshine")))


# ======================================================================================
# The leaf rotary embedding.
# ======================================================================================
class MbRoPE(nn.Module):
    """HF's apply_rotary_pos_emb for ONE of q or k, on a [1, T, heads, head_dim] tensor.

    patches/0100 recognises it by `mb_op == "rope_s8"` and lowers it to one rope_s8
    dispatch.  The contract that op implements, element by element in float32:
        pair (2i, 2i+1) for i < rotary_dim/2, angle table index (t, i):
            y[2i]   = x[2i]   * cos + (-x[2i+1]) * sin
            y[2i+1] = x[2i+1] * cos +   x[2i]    * sin
        d >= rotary_dim: y[d] = x[d]
    which is exactly `(q_rot * cos) + (rotate_half(q_rot) * sin)` with HF's interleaved
    rotate_half and `cos[..., :dim//2].repeat_interleave(2)`.
    """

    mb_fx_leaf = True
    mb_op = "rope_s8"
    mb_interleaved = True

    def __init__(self, seq: int, heads: int, head_dim: int, rotary_dim: int, theta: float,
                 table_key: str = "rotary_emb"):
        super().__init__()
        assert rotary_dim % 2 == 0 and rotary_dim <= head_dim
        self.seq, self.heads, self.head_dim, self.rotary_dim = seq, heads, head_dim, rotary_dim
        # All instances share one pair of tables in the IR.
        self.mb_table_key = table_key
        # MoonshineRotaryEmbedding / _compute_default_rope_parameters, op for op.
        inv_freq = 1.0 / (theta ** (torch.arange(0, rotary_dim, 2, dtype=torch.int64).float()
                                    / rotary_dim))
        pos = torch.arange(0, seq).unsqueeze(0)
        inv_freq_expanded = inv_freq[None, :, None].float().expand(1, -1, 1)
        freqs = (inv_freq_expanded.float() @ pos[:, None, :].float()).transpose(1, 2)
        emb = torch.cat((freqs, freqs), dim=-1)
        cos = emb.cos()[0, :, : rotary_dim // 2].contiguous()     # [T, rotary/2]
        sin = emb.sin()[0, :, : rotary_dim // 2].contiguous()
        self.register_buffer("cos_tab", cos, persistent=False)
        self.register_buffer("sin_tab", sin, persistent=False)

    def forward(self, x):                                           # [1, T, H, Dh]
        cos = self.cos_tab.repeat_interleave(2, dim=-1)[None, :, None, :]
        sin = self.sin_tab.repeat_interleave(2, dim=-1)[None, :, None, :]
        r = self.rotary_dim
        x_rot, x_pass = x[..., :r], x[..., r:]
        x1 = x_rot[..., 0::2]
        x2 = x_rot[..., 1::2]
        rot_half = torch.stack((-x2, x1), dim=-1).flatten(-2)
        return torch.cat([(x_rot * cos) + (rot_half * sin), x_pass], dim=-1)


# ======================================================================================
# The encoder.
# ======================================================================================
class MbAttention(nn.Module):
    def __init__(self, seq: int):
        super().__init__()
        self.seq = seq
        self.q_proj = nn.Linear(D, D, bias=False)
        self.k_proj = nn.Linear(D, D, bias=False)
        self.v_proj = nn.Linear(D, D, bias=False)
        self.o_proj = nn.Linear(D, D, bias=False)
        # Two instances so each call is its own FX node and its own IR op name; the tables
        # are shared (mb_table_key).
        self.rope_q = MbRoPE(seq, HEADS, HEAD_DIM, ROT, THETA)
        self.rope_k = MbRoPE(seq, HEADS, HEAD_DIM, ROT, THETA)

    def forward(self, x):                                           # [1, T, D]
        t = self.seq
        q = self.q_proj(x).view(1, t, HEADS, HEAD_DIM)
        k = self.k_proj(x).view(1, t, HEADS, HEAD_DIM)
        v = self.v_proj(x).view(1, t, HEADS, HEAD_DIM)
        q = self.rope_q(q)
        k = self.rope_k(k)
        q = q.permute(0, 2, 1, 3)
        k = k.permute(0, 2, 1, 3)
        v = v.permute(0, 2, 1, 3)
        # default scale 1/sqrt(q.size(-1)) = 1/sqrt(36), HF's `scaling`; no mask
        o = F.scaled_dot_product_attention(q, k, v)
        o = o.permute(0, 2, 1, 3)
        o = o.reshape(1, t, D)
        return self.o_proj(o)


class MbMLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(D, FF)
        self.act = nn.GELU()
        self.fc2 = nn.Linear(FF, D)

    def forward(self, x):
        return self.fc2(self.act(self.fc1(x)))


class MbEncoderLayer(nn.Module):
    def __init__(self, seq: int):
        super().__init__()
        self.input_layernorm = nn.LayerNorm(D, bias=False)
        self.self_attn = MbAttention(seq)
        self.post_attention_layernorm = nn.LayerNorm(D, bias=False)
        self.mlp = MbMLP()

    def forward(self, x):
        r = x
        h = self.input_layernorm(x)
        h = self.self_attn(h)
        x = r + h
        r = x
        h = self.post_attention_layernorm(x)
        h = self.mlp(h)
        return r + h


class MbStem(nn.Module):
    """conv1 -> tanh -> GroupNorm(1) -> conv2 -> GELU -> conv3 -> GELU, as Conv2d.

    layout "w": time on W, input [1, 1, 1, N], kernels (1, k)   (the default)
    layout "h": time on H, input [1, 1, N, 1], kernels (k, 1)
    """

    def __init__(self, layout: str = "w"):
        super().__init__()
        assert layout in ("w", "h")
        self.layout = layout

        def k2(k):
            return (1, k) if layout == "w" else (k, 1)

        self.conv1 = nn.Conv2d(1, D, k2(127), k2(64), bias=False)
        self.tanh = nn.Tanh()
        self.groupnorm = nn.GroupNorm(num_groups=1, num_channels=D, eps=GN_EPS)
        self.conv2 = nn.Conv2d(D, 2 * D, k2(7), k2(3))
        self.gelu2 = nn.GELU()
        self.conv3 = nn.Conv2d(2 * D, D, k2(3), k2(2))
        self.gelu3 = nn.GELU()

    def forward(self, x):
        x = self.tanh(self.conv1(x))
        x = self.groupnorm(x)
        x = self.gelu2(self.conv2(x))
        return self.gelu3(self.conv3(x))


class MoonshineEncoderMb(nn.Module):
    def __init__(self, layers: int = LAYERS):
        super().__init__()
        self.stem = MbStem("w")
        self.layers = nn.ModuleList([MbEncoderLayer(T) for _ in range(layers)])
        self.layer_norm = nn.LayerNorm(D, bias=False)

    def forward(self, x):                                           # [1, 1, 1, 64000]
        h = self.stem(x)                                            # [1, 288, 1, 165]
        h = h.permute(0, 2, 3, 1)                                   # [1, 1, 165, 288]
        h = h.reshape(1, T, D)
        for layer in self.layers:
            h = layer(h)
        return self.layer_norm(h)                                   # [1, 165, 288]


# ======================================================================================
# Weights.
# ======================================================================================
def _load_safetensors() -> dict:
    from safetensors.torch import load_file
    p = moonshine_dir() / "model.safetensors"
    if not p.exists():
        raise SystemExit(f"no checkpoint at {p}: run fpga/pynq-z2/modelblaster/moonshine/"
                         f"fetch_moonshine.sh (MOONSHINE_DIR={moonshine_dir()})")
    return load_file(str(p))


def _stem_state(sd: dict, layout: str) -> dict:
    out = {}
    for c in ("conv1", "conv2", "conv3"):
        w = sd[f"model.encoder.{c}.weight"]                         # [OC, IC, K]
        out[f"stem.{c}.weight"] = w.unsqueeze(2) if layout == "w" else w.unsqueeze(3)
        if f"model.encoder.{c}.bias" in sd:
            out[f"stem.{c}.bias"] = sd[f"model.encoder.{c}.bias"]
    out["stem.groupnorm.weight"] = sd["model.encoder.groupnorm.weight"]
    out["stem.groupnorm.bias"] = sd["model.encoder.groupnorm.bias"]
    return out


def encoder_state_dict(sd: dict) -> dict:
    out = _stem_state(sd, "w")
    for i in range(LAYERS):
        src = f"model.encoder.layers.{i}."
        dst = f"layers.{i}."
        for k in ("input_layernorm.weight", "post_attention_layernorm.weight",
                  "self_attn.q_proj.weight", "self_attn.k_proj.weight",
                  "self_attn.v_proj.weight", "self_attn.o_proj.weight",
                  "mlp.fc1.weight", "mlp.fc1.bias", "mlp.fc2.weight", "mlp.fc2.bias"):
            out[dst + k] = sd[src + k]
    out["layer_norm.weight"] = sd["model.encoder.layer_norm.weight"]
    return out


def build_encoder() -> MoonshineEncoderMb:
    m = MoonshineEncoderMb()
    missing, unexpected = m.load_state_dict(encoder_state_dict(_load_safetensors()), strict=False)
    # The only keys allowed to be absent are the LayerNorm biases that do not exist
    # (bias=False) -- nothing else; the rope tables are non-persistent buffers.
    if missing or unexpected:
        raise RuntimeError(f"state dict mismatch: missing={missing} unexpected={unexpected}")
    return m.eval()


class StemOnly(nn.Module):
    def __init__(self, layout: str):
        super().__init__()
        self.stem = MbStem(layout)

    def forward(self, x):
        return self.stem(x)


def build_stem(layout: str) -> StemOnly:
    m = StemOnly(layout)
    m.load_state_dict(_stem_state(_load_safetensors(), layout), strict=True)
    return m.eval()


# ======================================================================================
# Speech.
# ======================================================================================
def load_speech() -> dict:
    p = moonshine_dir() / "speech.npz"
    if not p.exists():
        raise SystemExit(f"no decoded speech at {p}: run fetch_moonshine.sh")
    z = np.load(p, allow_pickle=False)
    wav = [z[f"wav{i}"] for i in range(int(z["n"]))]
    return {"ids": [str(s) for s in z["ids"]], "texts": [str(s) for s in z["texts"]],
            "wav": wav}


def window(x: np.ndarray, mode: str = "center") -> np.ndarray:
    """A WINDOW_S-second window (4.0 by default; MOONSHINE_WINDOW_S).  Shorter clips are
    zero-padded at the END (the whole utterance is in the window, so its reference transcript
    applies); longer ones are centre-cropped."""
    x = np.asarray(x, dtype=np.float32)
    if len(x) <= N_SAMPLES:
        return np.pad(x, (0, N_SAMPLES - len(x)))
    off = (len(x) - N_SAMPLES) // 2 if mode == "center" else 0
    return x[off:off + N_SAMPLES]


def speech_split(sp: dict | None = None, n_cal: int = 16, n_agree: int = 8) -> dict:
    sp = sp or load_speech()
    n = len(sp["ids"])
    order = sorted(range(n), key=lambda i: sp["ids"][i])
    short = [i for i in order if len(sp["wav"][i]) <= N_SAMPLES]
    long_ = [i for i in order if len(sp["wav"][i]) > N_SAMPLES]
    cal_pos = np.unique(np.round(np.linspace(0, len(long_) - 1, n_cal)).astype(int))
    cal = [long_[j] for j in cal_pos]
    rest = [i for i in long_ if i not in cal]
    ag_pos = np.unique(np.round(np.linspace(0, len(rest) - 1, n_agree)).astype(int))
    agree = [rest[j] for j in ag_pos]
    return {"eval": short, "calibration": cal, "agreement": agree,
            "ids": {k: [sp["ids"][i] for i in v] for k, v in
                    (("eval", short), ("calibration", cal), ("agreement", agree))}}


def input_tensor(x: np.ndarray, layout: str = "w") -> torch.Tensor:
    w = torch.from_numpy(window(x))
    return w.view(1, 1, 1, N_SAMPLES) if layout == "w" else w.view(1, 1, N_SAMPLES, 1)


def calibration_inputs(n: int, layout: str = "w") -> list:
    """Calibration windows for ModelBlaster's int8 extraction.

    MOONSHINE_CAL_SET selects the source:
      "speech"      (default, unchanged) the 16 windows of speech_split()'s calibration list --
                    ONE speaker, three chapters of the hf-internal-testing dummy split.  It is a
                    smoke-test set and it caps every extraction at 16 windows.
      "librispeech" librispeech_sets.cal_set(n): dev-clean utterances longer than 4 s,
                    centre-cropped, evenly spaced over the id-sorted list so they span all 40
                    speakers -- the pinned calibration set ROCC_DECOUPLED.md s8.12 defines, and the
                    one every fidelity number since is reported against.  Supports n up to 64.

    WHY THE DEFAULT IS STILL THE SMOKE SET: changing it changes every existing extraction, so it
    is opt-in.  But it IS a defect -- MOONSHINE_MODEL.md s2.8 and the IR ladder's five rungs
    coming back at 108-198 %, with the 4.0 s control failing too, are the same 16-window
    calibration seen from two directions.
    """
    src = os.environ.get("MOONSHINE_CAL_SET", "speech")
    if src == "npy":
        # LAB B132.  MOONSHINE_CAL_NPY names a float32 [N, N_SAMPLES] array of ALREADY-WINDOWED
        # 4.0 s calibration waveforms, and this branch does nothing to them but pick n evenly
        # spaced rows.  It exists so that a lab can calibrate on windows this module has no
        # business knowing how to build -- microphone captures off a board console, or clean
        # windows pushed through a measured room -- WITHOUT a capture reader landing in the
        # model port that every extraction imports.
        #
        # IT IS NOT A SECOND CALIBRATION PATH.  B132's gate is that the librispeech cal_set(16)
        # windows written to an .npy and read back HERE reproduce out/b111_ls16/ir/graph.json to
        # the md5, which is what makes an arm built this way comparable with one built above.
        p = os.environ.get("MOONSHINE_CAL_NPY", "")
        if not p:
            raise SystemExit("MOONSHINE_CAL_SET=npy needs MOONSHINE_CAL_NPY=<path to a "
                             "float32 [N, %d] array of windowed waveforms>" % N_SAMPLES)
        w = np.load(p)
        if w.ndim != 2 or w.shape[1] != N_SAMPLES:
            raise SystemExit("%s: expected [N, %d] windows, got %s" % (p, N_SAMPLES, w.shape))
        if w.shape[0] < n:
            raise SystemExit("asked for %d calibration windows; %s has %d" % (n, p, w.shape[0]))
        pick = np.unique(np.round(np.linspace(0, w.shape[0] - 1, n)).astype(int))
        return [input_tensor(w[j].astype(np.float32), layout) for j in pick]
    if src == "librispeech":
        import librispeech_sets as _ls
        c, idx = _ls.cal_set(n)
        if len(idx) < n:
            raise SystemExit(f"asked for {n} calibration windows; cal_set has {len(idx)}")
        return [input_tensor(c.wav(i), layout) for i in idx]
    if src != "speech":
        raise SystemExit(f"MOONSHINE_CAL_SET={src!r}: expected 'speech', 'librispeech' or 'npy'")
    sp = load_speech()
    cal = speech_split(sp)["calibration"]
    if n > len(cal):
        raise SystemExit(f"asked for {n} calibration windows; the split has {len(cal)} "
                         f"(MOONSHINE_CAL_SET=librispeech gives the pinned 64)")
    # evenly spaced within the (already evenly spaced) calibration list
    pick = [cal[j] for j in np.unique(np.round(np.linspace(0, len(cal) - 1, n)).astype(int))]
    return [input_tensor(sp["wav"][i], layout) for i in pick]


# ---- the ModelBlaster model-module interface (models/moonshine_enc.py imports these) ---
def get_model(seed: int = 0):
    return build_encoder()


def get_sample_input(seed: int = 1):
    return calibration_inputs(1)[0]


def get_calibration_samples(n: int):
    return calibration_inputs(n)


# ======================================================================================
# Check against transformers.
# ======================================================================================
def check_hf(n_utts: int = 24) -> dict:
    import transformers
    from transformers import MoonshineForConditionalGeneration
    hf = MoonshineForConditionalGeneration.from_pretrained(str(moonshine_dir()))
    hf.eval()
    enc = hf.model.encoder
    mb = build_encoder()
    sp = load_speech()
    split = speech_split(sp)
    idx = (split["eval"] + split["agreement"] + split["calibration"])[:n_utts]
    worst = 0.0
    rows = []
    with torch.no_grad():
        for i in idx:
            x = torch.from_numpy(window(sp["wav"][i]))[None, :]
            a = enc(x).last_hidden_state
            b = mb(x.view(1, 1, 1, N_SAMPLES))
            err = float((a - b).abs().max())
            rel = float((a - b).abs().max() / a.abs().max())
            rows.append({"id": sp["ids"][i], "max_abs_diff": err, "max_rel_diff": rel,
                         "hf_max_abs": float(a.abs().max())})
            worst = max(worst, err)
            print(f"  {sp['ids'][i]}  max|hf - port| = {err:.3e}  (|hf| max {float(a.abs().max()):.2f})")
    n_params = sum(p.numel() for p in hf.parameters())
    return {"transformers": transformers.__version__, "hf_params": n_params,
            "attn_implementation": hf.config._attn_implementation,
            "rows": rows, "max_abs_diff": worst}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check-hf", action="store_true")
    ap.add_argument("--split", action="store_true", help="print the speech split")
    ap.add_argument("--json", default=None)
    a = ap.parse_args()
    out = {}
    if a.split:
        s = speech_split()
        print(json.dumps(s["ids"], indent=1))
        out["split"] = s["ids"]
    if a.check_hf:
        r = check_hf()
        print(f"max |hf - port| over {len(r['rows'])} windows: {r['max_abs_diff']:.3e} "
              f"({r['hf_params']:,} parameters, attn={r['attn_implementation']})")
        out["check_hf"] = r
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
