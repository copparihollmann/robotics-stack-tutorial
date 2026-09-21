#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Split `layernorm_s8` into TWO OP KINDS so the two regions of one graph can pick two kernels.

    python3 fpga/pynq-z2/modelblaster/ir_lnsplit.py --selftest
    python3 fpga/pynq-z2/modelblaster/ir_lnsplit.py --ir in/graph.json --weights in/weights.npz \
        --out out/graph.json --out-weights out/weights.npz --prefix e. --report r.json

WHY THIS PASS EXISTS.  One image has ONE kernel pick per OP KIND, and Lab B114 measured what
that costs when two regions of one graph disagree: the encoder's thirteen 165x288 LayerNorms on
`pext_int_rsqrt` cost **+35,906,338 cycles, +0.2244 of RTF_e2e**.  Lab B115 measured the other
direction and it is worse -- **+105,187,369** -- because `roccmoon_lane`'s per-tensor kernel
derives its whole K = 288 affine table in soft-float double on hart 0 **on every call** and
never sees `M`: ~353,000 cycles that the encoder amortises over 47,520 elements and the decoder
pays 456 times over 288.  ***Neither pick is right for both halves, and there is no third pick.***

    op_kind        encoder (13 x 165x288)      decoder (456 x 1x288)
    layernorm_s8   wants roccmoon_lane         wants pext_int_rsqrt

THE MECHANISM IS ALREADY THERE.  `feature_gate.py` keys on `(op_kind, algorithm)` PAIRS, and
`layernorm_pc_s8` is a genuine sibling kind with its own KernelSpec, its own curated kernel, its
own `generate_skeleton` emitter and its own entry in that table.  Nobody has used it to separate
two regions of ONE graph.  So this pass does not invent a kind, does not add a kernel file and
does not touch the codegen: it rewrites the selected `layernorm_s8` ops into `layernorm_pc_s8`
and BAKES the table the per-tensor kernel would have derived.

***AND THAT IS WHY IT IS BIT-EXACT RATHER THAN MERELY CLOSE.***  The two curated kernels are the
same driver under two names:

    kernel_layernorm_s8(...)    { mbxr_ln_derive_pt(gamma, beta, ... -> umul,gmul,badd,eps_q);
                                  mbxr_ln_run(input, umul, gmul, badd, out, M, K, eps_q); }
    kernel_layernorm_pc_s8(...) { mbxr_ln_run(input, umul, gmul, badd, out, M, K, eps_q); }

`mbxr_ln_run` is one copy in `sw/roccmoon/mbxr_ln_driver.h`, included by both.  So if the tables
this pass writes are the tables `mbxr_ln_derive_pt` computes, the lane is handed the same bytes
and answers the same bytes -- on the board AND on the host, where both kernels fall through the
same `mbxr_ln_reference`.  **"If" is a thing to CHECK:** `--verify-c` compiles
`sw/roccmoon/mbxr_ln_derive.h` itself and diffs its output against this file's, element by
element, for every site the pass rewrites.  A derivation reimplemented in Python and never
checked against the C is exactly the failure this repository keeps finding.

THE ARITHMETIC, TERM FOR TERM WITH `mbxr_ln_derive_pt`, AND EVERY CAST IS LOAD-BEARING:

    umul[k] = 2^24                      (constant: "per-tensor" names the ACTIVATION scales)
    gmul[k] = rint((double)(float)gamma[k] / (double)(float)scale_out * 65536.0)
    badd[k] = rint((double)(float)beta[k]  / (double)(float)scale_out * 65536.0)
    eps_q   = rint((double)eps * K * K * s * s),  s = (double)(1<<24) / (double)(float)scale_in
    rint(x) = (int64_t)(x < 0 ? x - 0.5 : x + 0.5)      -- C truncation, NOT numpy's rint

The scalars are read back through float32 first because `generate_skeleton` emits them as float
literals, so the C kernel never sees the float64 the graph stores.  Divide THEN multiply by
65536, in that order, because that is the order the C writes.

WHAT IT REFUSES.  A site the lane could not have taken is left as `layernorm_s8`, not rewritten
into a `layernorm_pc_s8` that would fall back anyway: the eps_q floor (262,144) and the int64
ceiling, the int8-only activation range, and `mbxr_ln_consts_fit`'s field widths.  B115 measured
13 decoder sites that fail the ceiling, so this is not hypothetical.  Refusals are listed in the
report; `--strict` turns any refusal among the SELECTED sites into an error.
"""
from __future__ import annotations
import argparse, copy, json, os, subprocess, sys, tempfile

import numpy as np

F = 24
UMUL = 1 << F
EPS_FLOOR = 262144.0          # mbxr_ln_cfg_ok: c_eps must be STRICTLY greater
EPS_CEIL = 9.2e18             # mbxr_ln_derive_pt's int64 guard
I32_LO, I32_HI = -(2 ** 31), 2 ** 31 - 1
KUMUL_CEIL = 1 << 40


class LnSplitError(Exception):
    pass


def _rint(x):
    """mbxr_ln_rint: add or subtract a half and let the C cast truncate TOWARD ZERO."""
    x = np.asarray(x, dtype=np.float64)
    y = np.where(x < 0.0, x - 0.5, x + 0.5)
    return np.trunc(y).astype(np.int64)


def derive_pt(gamma, beta, K, scale_in, scale_out, eps, amin, amax):
    """mbxr_ln_derive_pt in Python.  Returns (umul, gmul, badd, eps_q) or raises LnSplitError."""
    si = float(np.float32(scale_in))
    so = float(np.float32(scale_out))
    ep = float(np.float32(eps))
    if K <= 0 or so <= 0.0 or si <= 0.0 or ep <= 0.0:
        raise LnSplitError("a non-positive K, scale or eps")
    if (amin, amax) != (-128, 127):
        raise LnSplitError("activation range %s..%s: the lane clamps to int8 and only int8"
                           % (amin, amax))
    if UMUL < 0 or UMUL >= (1 << 25):
        raise LnSplitError("umul out of the lane's 25-bit field")
    if K * UMUL >= KUMUL_CEIL:
        raise LnSplitError("K * umul %d >= 2^40" % (K * UMUL))
    g = np.ones(K, np.float32) if gamma is None else np.asarray(gamma, np.float32).reshape(-1)
    b = np.zeros(K, np.float32) if beta is None else np.asarray(beta, np.float32).reshape(-1)
    if g.size != K or b.size != K:
        raise LnSplitError("gamma/beta are %d/%d long, K is %d" % (g.size, b.size, K))
    gmul = _rint(g.astype(np.float64) / so * 65536.0)
    badd = _rint(b.astype(np.float64) / so * 65536.0)
    for name, v in (("gmul", gmul), ("badd", badd)):
        if v.min() < I32_LO or v.max() > I32_HI:
            raise LnSplitError("%s out of int32 (%d .. %d)" % (name, v.min(), v.max()))
    s = float(UMUL) / si
    E = float(ep) * float(K) * float(K) * s * s
    if not (E > EPS_FLOOR):
        raise LnSplitError("eps_q %.6g <= %d (mbxr_ln_cfg_ok's floor)" % (E, EPS_FLOOR))
    if E >= EPS_CEIL:
        raise LnSplitError("eps_q %.6g >= 9.2e18 (the int64 ceiling)" % E)
    umul = np.full(K, UMUL, np.int32)
    # mbxr_ln_consts_fit, which mbxr_ln_run applies again at dispatch time
    ku = np.int64(K) * umul.astype(np.int64)
    if ku.min() < 0 or ku.max() >= KUMUL_CEIL:
        raise LnSplitError("K * umul out of the lane's 40-bit field")
    return umul, gmul.astype(np.int64), badd.astype(np.int64), int(_rint(E))


def select(o, prefix, min_m, names):
    if o["op"] != "layernorm_s8":
        return False
    if names is not None:
        return o["name"] in names
    if prefix is not None and not o["name"].startswith(prefix):
        return False
    if min_m is not None and int(o.get("shape", {}).get("M", 0)) < min_m:
        return False
    return prefix is not None or min_m is not None


def split(ir: dict, weights: dict, prefix=None, min_m=None, names=None, strict=False):
    ir = copy.deepcopy(ir)
    out_w = dict(weights)
    rewritten, refused, untouched = [], [], []
    for o in ir["ops"]:
        if o["op"] != "layernorm_s8":
            continue
        if not select(o, prefix, min_m, names):
            untouched.append(o["name"])
            continue
        q, sh = o["quant"], o["shape"]
        K = int(sh["K"])
        gam = weights.get(o["weight"]) if o.get("weight") else None
        bet = weights.get(o["bias"]) if o.get("bias") else None
        if o.get("weight") and gam is None:
            raise LnSplitError("%s: gamma %r is not in weights.npz" % (o["name"], o["weight"]))
        try:
            umul, gmul, badd, eps_q = derive_pt(gam, bet, K, q["scale_in"], q["scale_out"],
                                                q["eps"], q["activation_min"],
                                                q["activation_max"])
        except LnSplitError as e:
            refused.append({"name": o["name"], "why": str(e)})
            if strict:
                raise LnSplitError("%s: %s" % (o["name"], e))
            continue
        base = o["name"]
        nu, ng, nb = base + ".umul", base + ".gmul", base + ".badd"
        for n in (nu, ng, nb):
            if n in out_w:
                raise LnSplitError("weight name collision: %r already exists" % n)
        out_w[nu], out_w[ng], out_w[nb] = umul, gmul, badd
        # THE FLOAT gamma/beta ARE DROPPED ONLY IF NOTHING ELSE READS THEM.  A shared gamma
        # (CSE, or a graph that reuses a norm's parameters) would otherwise lose its tensor.
        old_w, old_b = o.get("weight"), o.get("bias")
        o["op"] = "layernorm_pc_s8"
        o["umul"], o["gmul"], o["badd"] = nu, ng, nb
        o.pop("weight", None)
        o.pop("bias", None)
        o["quant"] = {"eps_q": eps_q, "eps": q["eps"]}
        rewritten.append({"name": base, "M": int(sh["M"]), "K": K, "eps_q": eps_q,
                          "gmul_range": [int(gmul.min()), int(gmul.max())],
                          "badd_range": [int(badd.min()), int(badd.max())],
                          "dropped": [x for x in (old_w, old_b) if x]})
    # drop float parameters no surviving op references
    used = set()
    for o in ir["ops"]:
        for k in ("weight", "bias", "umul", "gmul", "badd", "mult", "shift", "amul", "bmul"):
            if o.get(k):
                used.add(o[k])
    dropped = [r["dropped"] for r in rewritten]
    dead = sorted({n for d in dropped for n in d if n not in used})
    for n in dead:
        out_w.pop(n, None)
    rep = {"rewritten": rewritten, "refused": refused, "untouched": untouched,
           "n_rewritten": len(rewritten), "n_refused": len(refused),
           "n_untouched": len(untouched), "weights_dropped": dead,
           "selector": {"prefix": prefix, "min_m": min_m,
                        "names": sorted(names) if names else None},
           "kinds_after": sorted({o["op"] for o in ir["ops"] if "layernorm" in o["op"]})}
    return ir, out_w, rep


# ---------------------------------------------------------------------------------------
# --verify-c: the derivation checked against the C it claims to reproduce, not against itself
# ---------------------------------------------------------------------------------------
_C = r"""
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include "roccmoon/mbxr_ln_derive.h"
int main(int argc, char **argv)
{
    int K = atoi(argv[1]);
    float si = strtof(argv[2], 0), so = strtof(argv[3], 0), ep = strtof(argv[4], 0);
    int amin = atoi(argv[5]), amax = atoi(argv[6]);
    static float g[8192], b[8192];
    static int32_t umul[8192];
    static int64_t gmul[8192], badd[8192], eps_q;
    FILE *f = fopen(argv[7], "rb");
    if (fread(g, sizeof(float), K, f) != (size_t)K) return 3;
    if (fread(b, sizeof(float), K, f) != (size_t)K) return 3;
    fclose(f);
    if (!mbxr_ln_derive_pt(g, b, K, si, so, ep, amin, amax, umul, gmul, badd, &eps_q)) {
        printf("REFUSED\n");
        return 0;
    }
    printf("%lld\n", (long long)eps_q);
    f = fopen(argv[8], "wb");
    fwrite(umul, sizeof(int32_t), K, f);
    fwrite(gmul, sizeof(int64_t), K, f);
    fwrite(badd, sizeof(int64_t), K, f);
    fclose(f);
    return 0;
}
"""


def verify_c(orig_weights, new_weights, rep, work):
    """Compile mbxr_ln_derive.h's own derivation and diff it against derive_pt(), per site.

    `orig_weights` is the PRE-pass map and `new_weights` the post-pass one, and they must be
    two arguments rather than one: the pass DROPS the float gamma/beta it has consumed, so a
    checker handed only the new map silently feeds the C a gamma of all ones and reports a
    disagreement that is its own.  That happened on the first run of this file.
    """
    sw = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sw")
    os.makedirs(work, exist_ok=True)
    src, exe = os.path.join(work, "derive.c"), os.path.join(work, "derive")
    open(src, "w").write(_C)
    subprocess.run([os.environ.get("HOST_CC", "cc"), "-O2", "-w", "-std=gnu11",
                    "-ffp-contract=off", "-I" + os.path.abspath(sw), src, "-o", exe], check=True)
    rows, bad = [], 0
    for r in rep["rewritten"]:
        # the ORIGINAL op's fields, recovered from the report and the PRE-pass weights
        K = r["K"]
        gam = orig_weights.get(r["dropped"][0]) if r["dropped"] else None
        bet = orig_weights.get(r["dropped"][1]) if len(r["dropped"]) > 1 else None
        g = (np.ones(K, np.float32) if gam is None else np.asarray(gam, np.float32).reshape(-1))
        b = (np.zeros(K, np.float32) if bet is None else np.asarray(bet, np.float32).reshape(-1))
        p_in = os.path.join(work, "in.bin")
        p_out = os.path.join(work, "out.bin")
        with open(p_in, "wb") as f:
            f.write(g.astype("<f4").tobytes()); f.write(b.astype("<f4").tobytes())
        q = r["_quant"]
        cp = subprocess.run([exe, str(K), repr(float(np.float32(q["scale_in"]))),
                             repr(float(np.float32(q["scale_out"]))),
                             repr(float(np.float32(q["eps"]))), str(q["activation_min"]),
                             str(q["activation_max"]), p_in, p_out],
                            check=True, capture_output=True, text=True)
        if cp.stdout.strip() == "REFUSED":
            rows.append({"name": r["name"], "c": "REFUSED", "match": False}); bad += 1; continue
        c_eps = int(cp.stdout.strip())
        raw = np.fromfile(p_out, dtype=np.uint8)
        c_u = raw[:4 * K].view("<i4")
        c_g = raw[4 * K:4 * K + 8 * K].view("<i8")
        c_b = raw[4 * K + 8 * K:4 * K + 16 * K].view("<i8")
        py_u, py_g, py_b = (np.asarray(new_weights[r["name"] + s])
                            for s in (".umul", ".gmul", ".badd"))
        ok = (c_eps == r["eps_q"] and np.array_equal(c_u, py_u)
              and np.array_equal(c_g, py_g) and np.array_equal(c_b, py_b))
        bad += not ok
        rows.append({"name": r["name"], "eps_q_c": c_eps, "eps_q_py": r["eps_q"],
                     "umul_equal": bool(np.array_equal(c_u, py_u)),
                     "gmul_equal": bool(np.array_equal(c_g, py_g)),
                     "badd_equal": bool(np.array_equal(c_b, py_b)),
                     "gmul_first_diff": (int(np.argmax(c_g != py_g))
                                         if not np.array_equal(c_g, py_g) else -1),
                     "match": bool(ok)})
    return {"sites": len(rows), "mismatched": bad, "rows": rows,
            "what": "mbxr_ln_derive.h's own mbxr_ln_derive_pt, compiled, against ir_lnsplit's "
                    "Python -- umul, gmul, badd and eps_q, element for element",
            "verdict": "PASS" if not bad else "FAIL"}


def _toy():
    K = 8
    gam = np.array([0.5, -0.25, 1.0, 2.0, -1.5, 0.125, 0.75, -0.0625], np.float32)
    bet = np.array([0.0, 0.1, -0.2, 0.3, -0.4, 0.5, -0.6, 0.7], np.float32)
    q = {"scale_in": 0.0410630913, "scale_out": 0.0234, "eps": 1e-5,
         "activation_min": -128, "activation_max": 127}
    ops = [{"name": "e.ln0", "op": "layernorm_s8", "inputs": ["x"], "outputs": ["a"],
            "weight": "e.ln0.w", "bias": "e.ln0.b", "shape": {"M": 165, "K": K},
            "quant": dict(q), "dispatch_id": 0},
           {"name": "d.ln0", "op": "layernorm_s8", "inputs": ["a"], "outputs": ["y"],
            "weight": "d.ln0.w", "bias": "d.ln0.b", "shape": {"M": 1, "K": K},
            "quant": dict(q), "dispatch_id": 1},
           {"name": "e.tiny", "op": "layernorm_s8", "inputs": ["x"], "outputs": ["z"],
            "weight": "e.ln0.w", "bias": "e.ln0.b", "shape": {"M": 165, "K": K},
            "quant": dict(q, scale_in=1e-9), "dispatch_id": 2}]
    ir = {"name": "toy", "tensors": {}, "ops": ops}
    w = {"e.ln0.w": gam, "e.ln0.b": bet, "d.ln0.w": gam, "d.ln0.b": bet}
    return ir, w


def selftest(work=None):
    bad = 0

    def ck(msg, cond):
        nonlocal bad
        bad += not cond
        print("    %-4s %s" % ("ok" if cond else "FAIL", msg))

    ir, w = _toy()
    out, ow, rep = split(ir, w, prefix="e.")
    ck("the e. sites are rewritten and the decoder's is NOT",
       rep["n_rewritten"] == 1 and "d.ln0" in rep["untouched"])
    ck("both kinds now exist in one graph", rep["kinds_after"] == ["layernorm_pc_s8",
                                                                  "layernorm_s8"])
    e = next(o for o in out["ops"] if o["name"] == "e.ln0")
    d = next(o for o in out["ops"] if o["name"] == "d.ln0")
    ck("the rewritten op carries umul/gmul/badd and an integer eps_q",
       e["op"] == "layernorm_pc_s8" and e["umul"] == "e.ln0.umul"
       and isinstance(e["quant"]["eps_q"], int) and "weight" not in e)
    ck("the untouched op is byte-for-byte what it was",
       json.dumps(d, sort_keys=True) == json.dumps(ir["ops"][1], sort_keys=True))
    ck("umul is the constant 2^24 on every channel",
       list(ow["e.ln0.umul"]) == [1 << 24] * 8 and ow["e.ln0.umul"].dtype == np.int32)
    ck("gmul/badd are int64", ow["e.ln0.gmul"].dtype == np.int64
       and ow["e.ln0.badd"].dtype == np.int64)
    ck("a gamma STILL READ by another op is not dropped", "e.ln0.w" in ow)
    ck("a site whose eps_q overflows int64 is REFUSED, not rewritten",
       rep["n_refused"] == 1 and rep["refused"][0]["name"] == "e.tiny"
       and "9.2e18" in rep["refused"][0]["why"])
    try:
        split(ir, w, prefix="e.", strict=True)
        ck("--strict turns a refusal into an error", False)
    except LnSplitError:
        ck("--strict turns a refusal into an error", True)
    out2, ow2, rep2 = split(ir, w, min_m=2)
    ck("--min-m 2 selects by SHAPE and leaves the one-row site alone",
       rep2["n_rewritten"] == 1 and "d.ln0" in rep2["untouched"])
    ir3, w3, rep3 = split(ir, w)
    ck("with no selector NOTHING is rewritten (a rename must be asked for)",
       rep3["n_rewritten"] == 0)

    # gmul against a hand-computed value, so the formula is checked and not just its stability
    so = float(np.float32(0.0234))
    want = int(np.trunc(float(np.float64(np.float32(0.5)) / so * 65536.0) + 0.5))
    ck("gmul[0] = rint(gamma/scale_out * 65536) = %d" % want, int(ow["e.ln0.gmul"][0]) == want)
    ck("a NEGATIVE gmul truncates toward zero, as the C cast does",
       int(ow["e.ln0.gmul"][1]) == int(np.trunc(float(np.float64(np.float32(-0.25)) / so
                                                      * 65536.0) - 0.5)))

    if work:
        for r in rep["rewritten"]:
            r["_quant"] = dict(ir["ops"][0]["quant"])
        v = verify_c(w, ow, rep, work)
        ck("the C's own mbxr_ln_derive_pt agrees element for element (%d site(s))" % v["sites"],
           v["verdict"] == "PASS")
    print("    %s" % ("selftest: PASS" if not bad else "selftest: %d FAILED" % bad))
    return 1 if bad else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ir"); ap.add_argument("--weights")
    ap.add_argument("--out"); ap.add_argument("--out-weights"); ap.add_argument("--report")
    ap.add_argument("--prefix", default=None,
                    help="rewrite layernorm_s8 ops whose NAME starts with this (e.g. 'e.')")
    ap.add_argument("--min-m", type=int, default=None,
                    help="...and/or whose M is at least this")
    ap.add_argument("--strict", action="store_true",
                    help="a selected site the lane cannot express is an ERROR, not a skip")
    ap.add_argument("--verify-c", default=None, metavar="DIR",
                    help="compile sw/roccmoon/mbxr_ln_derive.h and diff it against this file")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest(a.verify_c)
    if not (a.ir and a.weights and a.out and a.out_weights):
        ap.error("--ir, --weights, --out and --out-weights are required")
    ir = json.load(open(a.ir))
    w = dict(np.load(a.weights))
    out, ow, rep = split(ir, w, a.prefix, a.min_m, None, a.strict)
    if a.verify_c:
        for r in rep["rewritten"]:
            r["_quant"] = next(dict(o["quant"]) for o in ir["ops"] if o["name"] == r["name"])
        rep["verify_c"] = verify_c(w, ow, rep, a.verify_c)
        for r in rep["rewritten"]:
            r.pop("_quant", None)
        if rep["verify_c"]["verdict"] != "PASS":
            print("ir_lnsplit: THE C DISAGREES -- %d of %d sites"
                  % (rep["verify_c"]["mismatched"], rep["verify_c"]["sites"]), file=sys.stderr)
            return 2
    json.dump(out, open(a.out, "w"), indent=1)
    np.savez(a.out_weights, **ow)
    if a.report:
        json.dump(rep, open(a.report, "w"), indent=1)
    print("ir_lnsplit: %d layernorm_s8 -> layernorm_pc_s8, %d refused, %d left as layernorm_s8"
          "%s" % (rep["n_rewritten"], rep["n_refused"], rep["n_untouched"],
                  "  [C agrees on all %d]" % rep["verify_c"]["sites"] if a.verify_c else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
