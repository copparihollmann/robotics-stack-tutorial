#!/usr/bin/env python3
"""Predict a run's weight-image counters from its IR, before the run exists.

A host-only reimplementation of mbxr_wimage_plan_bits (fpga/pynq-z2/sw/roccmoon/mbxr.c:100)
plus the image cache's keying (mbxr_rt.h:501).  It exists so an arm can be GATED on
`bytes_wgt`, `loads_wgt` and `image_bytes` before anyone reads a cycle count -- the two
NCH = 8 failures of 2026-09-19 (a hang, then a silent wrong answer) were both invisible to
cycle numbers and both would have been caught here.

THREE INPUTS, AND ALL THREE ARE REQUIRED -- B101's own gate missed on every one of them:

  graph.json   the SHAPES.  Candidate R has 24 conv2d_s8 dispatches and ATTNFUSE has 3;
               a gate derived on one does not apply to the other.
  --nch        4 or 8.  The engine's width (MBXR_NCH).
  --strided    the DRAIN MODE (MBXR_RT_DRAIN_STRIDED), which the ELF carries as
               MBXR_ABI:v2:strided=<0|1>.  `if (strided) Q &= ~1` costs +12 tiles and
               +393,216 bytes at NCH = 4 on the encoder's 1152x288 and 288x1152 layers,
               and is a NO-OP at NCH = 8 on every shape either encoder graph contains.

AND THE THREE COUNTERS ARE NOT INTERCHANGEABLE:
  bytes_wgt / loads_wgt   PER DISPATCH -- every image the engine loads, re-loads included.
  image_bytes             DEDUPED by the cache key (weight tensor, N, Kp): a weight tensor
                          used by two dispatches is built ONCE.
On the ATTNFUSE encoder no layer shares a weight tensor, so all three coincide -- which is
exactly what let B101 gate `image_bytes` with a per-dispatch total and not notice.  On
candidate R they differ by 3.67 MB.

VALIDATED against silicon, on runs it was not fitted to (8 of 8 exact):
  b86f_comp_on   ATTNFUSE NCH=4 strided=1   8,912,896 B / 272 tiles   (bytes_wgt==image_bytes)
  b98_enc_ctl_0032_f40  R NCH=4 strided=0  14,024,704 / 428, image 10,354,688
  b98_enc_trt_0034_f40  R NCH=8 strided=0  15,466,496 / 240, image 11,665,408

WHAT IT DOES NOT MODEL, stated so nobody reads a fill projection out of it: transfer SHAPE.
On the candidate-R pair `cyc_fill` FELL 37.8 % while `bytes_wgt` ROSE 10.28 % -- fewer,
larger sequential transfers beat more bytes.  Both B98's +0.61 % and B101's corrected
+0.118 % fill penalties had the wrong SIGN.  This tool predicts bytes and tiles.  It says
nothing about cycles.
"""
import argparse, json, sys

BUF_WORDS = 1024          # MBXR_BUF_WORDS


def _lg2ceil(x):
    n = 0
    while (1 << n) < x:
        n += 1
    return n


def plan_bits(N, K, nch, strided_build, wbits=8):
    """mbxr_wimage_plan_bits, returning (bytes, tiles) or None where it refuses."""
    if N <= 0 or K <= 0 or K % 8 or wbits not in (6, 8):
        return None
    if (K * wbits) % 64:
        return None
    Kw = K * wbits // 8
    G = Kw // 8
    if G + 1 > BUF_WORDS or K // 8 + 1 > BUF_WORDS:
        return None
    quads = (N + nch - 1) // nch
    Q = BUF_WORDS // (G + 1)
    if Q > quads:
        Q = quads
    if strided_build and N % 8 == 0 and Q >= 2:
        Q &= ~1
    lgpw = max(3, _lg2ceil(Q * (G + 1)))
    tiles = (quads + Q - 1) // Q
    return tiles * nch * (8 << lgpw), tiles


def layers(graph):
    """(weight_tensor, N, Kp) per engine dispatch, in dispatch order."""
    for o in graph["ops"]:
        s = o.get("shape") or {}
        if o.get("op") == "conv2d_s8":
            N, K = s["OC"], s["IC"] * s["KW"]
        elif o.get("op") == "linear_s8":
            N, K = s["N"], s["K"]
        else:
            continue
        yield o.get("weight"), N, (K + 7) & ~7


def predict(graph, nch, strided, wbits=8):
    seen, out = set(), {"bytes_wgt": 0, "loads_wgt": 0, "image_bytes": 0, "image_tiles": 0,
                        "refused": []}
    for w, N, Kp in layers(graph):
        p = plan_bits(N, Kp, nch, strided, wbits)
        if p is None:
            out["refused"].append((w, N, Kp))
            continue
        out["bytes_wgt"] += p[0]
        out["loads_wgt"] += p[1]
        if (w, N, Kp) in seen:
            continue
        seen.add((w, N, Kp))
        out["image_bytes"] += p[0]
        out["image_tiles"] += p[1]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("graph", help="path to the run's ir/graph.json")
    ap.add_argument("--nch", type=int, required=True, choices=(4, 8))
    ap.add_argument("--strided", type=int, required=True, choices=(0, 1),
                    help="MBXR_RT_DRAIN_STRIDED; the ELF carries MBXR_ABI:v2:strided=<n>")
    ap.add_argument("--wbits", type=int, default=8, choices=(6, 8))
    ap.add_argument("--check", metavar="RUN_JSON",
                    help="compare against a run.json's measured engine counters")
    a = ap.parse_args()

    g = json.load(open(a.graph))
    r = predict(g, a.nch, a.strided, a.wbits)
    print("NCH=%d strided=%d wbits=%d  %s" % (a.nch, a.strided, a.wbits, a.graph))
    print("  bytes_wgt   %12d   (per dispatch)" % r["bytes_wgt"])
    print("  loads_wgt   %12d   (per dispatch)" % r["loads_wgt"])
    print("  image_bytes %12d   (deduped by weight tensor; %d tiles built)"
          % (r["image_bytes"], r["image_tiles"]))
    if r["refused"]:
        print("  planner REFUSED %d layer(s): %s" % (len(r["refused"]), r["refused"][:4]))
    if not a.check:
        return 0
    d = json.load(open(a.check))["models"]
    m = next(v for k, v in d.items() if isinstance(v, dict) and "engine" in v)["engine"]
    bad = 0
    for k in ("bytes_wgt", "loads_wgt", "image_bytes"):
        ok = r[k] == m.get(k)
        bad += not ok
        print("  %-12s predicted %12d   measured %12d   %s"
              % (k, r[k], m.get(k, -1), "MATCH" if ok else "*** MISMATCH ***"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
