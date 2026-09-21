#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Emit dec_driver.c's `driver_meta.h` FROM the IR.

    python3 emit_driver_meta.py --ir out/decint8/ir/graph.json --out out/decint8/gen_nl/driver_meta.h
    python3 emit_driver_meta.py --selftest --ir out/decint8/ir/graph.json \
                                --against out/decint8/gen_nl/driver_meta.h

WHY THIS EXISTS.  `out/decint8/gen_nl/driver_meta.h` says at the top
`/* @generated from the IR by model_dec_run.py -- do not edit. */` and NOTHING IN THE TREE
GENERATES IT -- it was made once at a shell and has been hand-carried since.  That would be a
harmless untidiness except for what it contains:

    static const int STEP_END[N_STEPS] = {163,351,539,...,4487};

those are DISPATCH INDICES into `MODEL_MOONSHINE_DEC_DISPATCH_FNS[]`.  Any IR rewrite that
changes the dispatch count renumbers them, and `dec_driver.c` would keep walking the old
boundaries: step k would stop in the middle of step k's work, argmax a stale logits buffer,
and produce tokens that are wrong without anything raising.  `fpga/pynq-z2/modelblaster/
ir_cse.py` is exactly such a rewrite (it takes the decoder from 4,488 dispatches to 4,212, and
every step after the first moves by 12), so the file now has a generator and the generator has
a selftest that reproduces the hand-made one byte for byte.

EVERY FIELD COMES FROM THE IR except EOS_ID, which is a tokenizer constant and is a flag:
    N_STEPS   len(output.tensors)
    VOCAB     the last dim of an output tensor
    DHID      the last dim of input h0
    STEP_END  the dispatch_id of the op producing output tensor k
    H_OFF     input.packed_inputs["h<k>"].offset -- where step k's hidden state is written
    H_SCALE   tensors["h<k>"].quant.scale -- the scale to re-quantise the embedding row by
"""
from __future__ import annotations

import argparse
import json
import sys

HEADER = "/* @generated from the IR by emit_driver_meta.py -- do not edit. */"
#: the byte-for-byte line the hand-made file carries, kept so --against can prove equivalence
LEGACY_HEADER = "/* @generated from the IR by model_dec_run.py -- do not edit. */"


def build(ir: dict, eos_id: int = 2) -> dict:
    outs = ir["output"]["tensors"]
    tensors = ir["tensors"]
    n_steps = len(outs)

    step_end: list[int | None] = [None] * n_steps
    for o in ir["ops"]:
        for t in o["outputs"]:
            if t in outs:
                k = outs.index(t)
                if o.get("dispatch_id") is None:
                    raise SystemExit("output %r is produced by a non-dispatched op (%s)"
                                     % (t, o.get("name")))
                if step_end[k] is not None:
                    raise SystemExit("output %r has two producers" % t)
                step_end[k] = o["dispatch_id"]
    if any(e is None for e in step_end):
        raise SystemExit("no producer for output(s) %s"
                         % [outs[i] for i, e in enumerate(step_end) if e is None])
    if step_end != sorted(step_end):
        raise SystemExit("output dispatch ids are not monotonic: %s -- dec_driver.c's "
                         "single forward walk assumes step k ends after step k-1" % step_end)

    packed = {p["name"]: p for p in ir["input"]["packed_inputs"]}
    h_off, h_scale = [], []
    for k in range(n_steps):
        nm = "h%d" % k
        if nm not in packed:
            raise SystemExit("input %r is not in packed_inputs" % nm)
        h_off.append(packed[nm]["offset"])
        h_scale.append(tensors[nm]["quant"]["scale"])

    return {"N_STEPS": n_steps, "VOCAB": tensors[outs[0]]["shape"][-1],
            "DHID": tensors["h0"]["shape"][-1], "EOS_ID": eos_id,
            "STEP_END": step_end, "H_OFF": h_off, "H_SCALE": h_scale}


def render(m: dict, header: str = HEADER) -> str:
    def f32(x: float) -> str:
        # %.9g of the DOUBLE, not of the float32 rounding of it.  Nine significant digits is
        # round-trip exact for binary32, and both spellings parse to the same float here
        # (checked over all 24 scales) -- but this is the spelling the hand-made file used and
        # --against proves equivalence only if the bytes match.
        return "%.9gf" % x

    L = [header, "#pragma once"]
    for k in ("N_STEPS", "VOCAB", "DHID", "EOS_ID"):
        L.append("#define %s %d" % (k, m[k]))
    L.append("static const int STEP_END[N_STEPS] = {%s};"
             % ",".join(str(v) for v in m["STEP_END"]))
    L.append("static const int H_OFF[N_STEPS] = {%s};"
             % ",".join(str(v) for v in m["H_OFF"]))
    L.append("static const float H_SCALE[N_STEPS] = {%s};"
             % ",".join(f32(v) for v in m["H_SCALE"]))
    return "\n".join(L) + "\n"


def selftest(ir_path: str, against: str) -> int:
    """Reproduce an existing driver_meta.h from its IR, byte for byte."""
    m = build(json.load(open(ir_path)))
    got = render(m, LEGACY_HEADER)
    want = open(against).read()
    if got == want:
        print("    selftest: PASS -- regenerated %s byte-identically from %s"
              % (against, ir_path))
        return 0
    print("    selftest: FAIL -- regenerated file differs from %s" % against)
    gl, wl = got.splitlines(), want.splitlines()
    for i in range(max(len(gl), len(wl))):
        a = gl[i] if i < len(gl) else "<missing>"
        b = wl[i] if i < len(wl) else "<missing>"
        if a != b:
            print("      line %d\n        got  %s\n        want %s" % (i + 1, a[:160], b[:160]))
    return 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ir", required=True, help="graph.json")
    ap.add_argument("--out", help="driver_meta.h to write")
    ap.add_argument("--eos-id", type=int, default=2)
    ap.add_argument("--legacy-header", action="store_true",
                    help="emit model_dec_run.py's original header line verbatim")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--against", help="--selftest: the existing driver_meta.h to reproduce")
    a = ap.parse_args(argv)

    if a.selftest:
        if not a.against:
            ap.error("--selftest needs --against <existing driver_meta.h>")
        return selftest(a.ir, a.against)
    if not a.out:
        ap.error("--out is required (or --selftest --against ...)")
    m = build(json.load(open(a.ir)), a.eos_id)
    open(a.out, "w").write(render(m, LEGACY_HEADER if a.legacy_header else HEADER))
    print("driver_meta: %d steps, dispatches 0..%d, STEP_END[0]=%d STEP_END[-1]=%d -> %s"
          % (m["N_STEPS"], m["STEP_END"][-1], m["STEP_END"][0], m["STEP_END"][-1], a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
