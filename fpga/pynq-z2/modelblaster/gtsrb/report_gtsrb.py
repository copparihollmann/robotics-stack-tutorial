"""Lab B121 -- turn one GTSRB board console into the numbers the lab exists for.

    steady cycles, MAC/cycle achieved, calls_engine / calls_fallback, max_abs_err.

WHY IT IS NOT yolo/report_yolo.py.  That one counts MACs for top-level conv2d_s8 only.
This lab's AS-SHIPPED graph has NO top-level conv2d_s8: its BatchNorm was not folded, so
every convolution lives inside a conv2d_batchnorm2d_s8 COMPOSITE and report_yolo would
report the whole backbone as 0 MAC.  The two differences from it are:

  * op_macs / op_elements DESCEND INTO sub_ops, so the folded and unfolded arms are
    counted the same way and their MAC totals are comparable;
  * linear_s8 MACs are counted (M*K*N).  YOLOv8n has no linear layer; this lab's only
    engine-ELIGIBLE op in the pick is the linear, and its MACs are what decide whether
    that eligibility is worth anything.

COLD vs WARM, STATED RATHER THAN AVERAGED.  With MB_WARMUP=0 and --iters 2 the FIRST
inference carries the one-time weight-image build and the second does not, so `max` is the
cold pass and `min` is the steady one.  The per-dispatch MB_PEXT_OP rows are emitted for
the cold pass, so summing them does NOT give a steady figure and this reporter never
quotes one from them -- it prints the row sum next to the COLD wall it belongs to, and
takes steady from `min` alone.  min == max means only ONE inference ran and the reporter
says so, because a control that runs once cannot see a defect that needs two runs.

MAC/cycle IS QUOTED TWO WAYS, as in B106: over the convolution's own cycles, and over the
whole steady inference.  The first flatters the accelerator, the second is the honest
end-to-end figure, and both are printed.
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter

#: every kind this lab's two graphs can contain.
KNOWN = {"conv2d_s8", "conv2d_batchnorm2d_s8", "maxpool2d_s8", "avgpool2d_s8",
         "linear_s8", "softmax_s8"}
#: kinds with NO curated kernel anywhere in the roccmoon -> pext_nl -> pext lineage.
#: verified against generate_kernels' own probe, not against filenames.
UNCURATED = {"conv2d_batchnorm2d_s8", "avgpool2d_s8"}
WHY = {
    "conv2d_batchnorm2d_s8":
        "reference C: the COMPOSITE has no curated kernel, so the engine is not even linked",
    "avgpool2d_s8":
        "reference C: curated only for rvv, and this is a 6x6 global pool (cheap)",
}


def _subs(o: dict) -> list:
    """The convolutions a kind contains: itself, or its sub_ops for a composite."""
    return o["sub_ops"] if o.get("sub_ops") else [o]


def op_macs(o: dict) -> int:
    n = 0
    for s in _subs(o):
        k, sh = s["op"], s.get("shape") or {}
        if k == "conv2d_s8":
            n += sh["OC"] * sh["OH"] * sh["OW"] * sh["IC"] * sh["KH"] * sh["KW"]
        elif k == "linear_s8":
            n += sh["M"] * sh["K"] * sh["N"]
    return n


def op_elements(o: dict) -> int:
    k, s = o["op"], o.get("shape") or {}
    if k == "conv2d_s8":
        return s["OC"] * s["OH"] * s["OW"] * s.get("N", 1)
    if k == "conv2d_batchnorm2d_s8":
        c = _subs(o)[0]["shape"]
        return c["OC"] * c["OH"] * c["OW"] * c.get("N", 1)
    if k in ("maxpool2d_s8", "avgpool2d_s8"):
        return s["C"] * s["OH"] * s["OW"] * s.get("N", 1)
    if k == "linear_s8":
        return s["M"] * s["N"]
    if k == "softmax_s8":
        return s["M"] * s["K"]
    return s.get("n", 0)


def main() -> None:
    console, graph_p, sel_p, cf_p, out_p = sys.argv[1:6]
    txt = open(console, errors="replace").read()
    g = json.load(open(graph_p))
    clk = int(os.environ.get("CLK_HZ", "40000000"))
    ref = float(os.environ.get("ENGINE_REF_MACC", "44.409"))

    run = re.search(r"^MB_PEXT_RUN .*?median=(\d+) min=(\d+) max=(\d+) warm=(\d+).*?"
                    r"max_abs_err=(-?\d+)", txt, re.M)
    if not run:
        sys.exit("no MB_PEXT_RUN line in the console")
    median, cmin, cmax, warm, aerr = (int(run.group(i)) for i in range(1, 6))
    two_ran = cmin != cmax
    steady = cmin                      # the warm pass; see the module docstring

    cyc = {}
    for m in re.finditer(r"^MB_PEXT_OP id=(\d+) name=(\S+) op=(\S+) shape=\S* cycles=(\d+)",
                         txt, re.M):
        cyc[int(m.group(1))] = (m.group(3), int(m.group(4)))

    by_id = {o["dispatch_id"]: o for o in g["ops"] if o.get("dispatch_id") is not None}
    unknown = sorted({o["op"] for o in g["ops"]} - KNOWN - {"view"})
    if unknown:
        sys.exit(f"unknown kind(s) in the graph: {unknown} -- this reporter would drop them")

    kc, kn, ke, km = Counter(), Counter(), Counter(), Counter()
    profiled = 0
    for i, (kind, c) in cyc.items():
        o = by_id.get(i)
        if o is None:
            sys.exit(f"dispatch {i} is on the console but not in the graph")
        if o["op"] != kind:
            sys.exit(f"dispatch {i}: console says {kind}, graph says {o['op']}")
        kc[kind] += c; kn[kind] += 1; ke[kind] += op_elements(o); km[kind] += op_macs(o)
        profiled += 1

    n_graph = sum(1 for o in g["ops"] if o["op"] != "view")
    rows_cyc = sum(kc.values())
    mac = sum(op_macs(o) for o in g["ops"])
    conv_cyc = kc.get("conv2d_s8", 0) + kc.get("conv2d_batchnorm2d_s8", 0)
    n_conv = sum(1 for o in g["ops"]
                 if o["op"] in ("conv2d_s8", "conv2d_batchnorm2d_s8"))
    backbone = ("conv2d_s8 (FOLDED)" if any(o["op"] == "conv2d_s8" for o in g["ops"])
                else "conv2d_batchnorm2d_s8 (AS-SHIPPED, BatchNorm NOT folded)")

    tot = re.findall(r"^MB_ROCCMOON phase=total (.*)$", txt, re.M)
    R = dict(kv.split("=", 1) for kv in tot[-1].split()) if tot else {}
    gi = lambda k: int(R.get(k, -1))

    out = []
    P = out.append
    P(f"Lab B121  GTSRB int8 sign classifier on roccmoon  {os.environ.get('NAME','')}  "
      f"{os.environ.get('WANT_MAGIC','')} ({os.environ.get('BIT_MD5','')})")
    P(f"backbone: {backbone}")
    _sel = dict(l.split("=", 1) for l in open(sel_p).read().split() if "=" in l)
    P(f"board: {_sel.get('board', 'NOT RECORDED')}  ({_sel.get('pynq_host', '?')})")
    P(f"{run.group(0)}")
    P("")
    # NOTE, corrected after the first five arms: on Moonshine the cold pass is cold because
    # it builds the engine's weight image, and min/max differ by ~2x.  NOTHING here reaches
    # the engine, so image_bytes is 0 and no weight image is ever built -- the two passes
    # differ only by cache warmth, ~0.01 %.  min != max is still the two-inference check
    # (the timer really saw two distinct inferences) but it is NOT evidence of a weight
    # image, and this line must not claim one.
    P(f"TWO INFERENCES?  min {cmin:,}  max {cmax:,}  -> "
      + (f"YES, min != max by {100*(cmax-cmin)/cmax:.3f} %" if two_ran
         else "*** NO: min == max, ONE inference ran. A control that runs once cannot see "
              "a defect that needs two. ***"))
    P(f"max_abs_err {aerr}   "
      + ("(0: bit-exact against the image's own host-C golden)" if aerr == 0
         else "*** NON-ZERO ***"))
    P("")
    P(f"steady (warm) inference   {steady:>14,} cycles  = {steady/clk*1000:9.2f} ms  "
      f"= {clk/steady:7.3f} fps at {clk/1e6:g} MHz")
    P(f"cold inference            {cmax:>14,} cycles  = {cmax/clk*1000:9.2f} ms   "
      f"(image_bytes {R.get('image_bytes','?')}: no engine weight image is built when "
      f"calls_engine is 0)")
    P(f"per-dispatch row sum      {rows_cyc:>14,} cycles  "
      f"({100*rows_cyc/cmax:.2f} % of the COLD wall -- the rows are the cold pass; "
      f"they are NOT a steady figure)")
    P(f"dispatches: {profiled} of {n_graph} profiled   (view is elided: it is a zero-cost reshape)")
    P("")
    P(f"MAC in this graph                {mac:>16,}")
    P(f"MAC/cycle over convolution rows  {mac/conv_cyc if conv_cyc else 0:>16.4f}"
      f"   against the engine's {ref} on Moonshine  "
      f"({(mac/conv_cyc)/ref*100 if conv_cyc else 0:.3f} %)")
    P(f"MAC/cycle over the steady frame  {mac/steady:>16.4f}"
      f"   ({(mac/steady)/ref*100:.3f} % of the engine)")
    P("")
    P("THE ENGINE'S OWN COUNTERS (MB_ROCCMOON phase=total)")
    P(f"  calls_engine   {gi('calls_engine'):>10}      calls_fallback {gi('calls_fallback'):>10}")
    P(f"  bytes_wgt      {gi('bytes_wgt'):>10}      image_bytes    {gi('image_bytes'):>10}")
    P(f"  cyc_tseq       {gi('cyc_tseq'):>10}      last_rc        {gi('last_rc'):>10}")
    if gi("calls_engine") == 0:
        P("  *** calls_engine = 0: NOTHING in this network reached the accelerator. ***")
        if "conv2d_s8" in kc:
            P(f"      The {n_conv} convolutions DID reach the engine KERNEL (it is linked and")
            P("      calls_fallback counts them): consulted, and declined on "
              "IH==1 && KH==1 && PH==0.")
        else:
            P(f"      The {n_conv} convolutions did not even reach the engine KERNEL: the")
            P("      conv2d_batchnorm2d_s8 composite has no curated kernel, so the engine")
            P("      convolution is not linked for them and calls_fallback CANNOT see them.")
            P("      Read calls_fallback here as 'the linear declined', not as 'all is well'.")
    P("")
    P(f"{'kind':<24}{'n':>3}{'cycles':>13}{'share%':>8}{'elements':>10}{'cyc/el':>9}"
      f"{'MAC/cyc':>9}   note")
    for k in sorted(kc, key=lambda x: -kc[x]):
        note = "UNCURATED -- " + WHY[k] if k in UNCURATED else "curated"
        P(f"{k:<24}{kn[k]:>3}{kc[k]:>13,}{100*kc[k]/rows_cyc:>8.2f}{ke[k]:>10,}"
          f"{kc[k]/ke[k] if ke[k] else 0:>9.2f}"
          f"{(km[k]/kc[k]) if km[k] else 0:>9.3f}   {note}")
    unc = sum(kc[k] for k in kc if k in UNCURATED)
    P(f"\nuncurated kinds (reference C): {unc:,} cycles = {100*unc/rows_cyc:.2f} % of the rows")

    rec = {
        "lab": "B121 gtsrb_signclf_roccmoon", "name": os.environ.get("NAME", ""),
        "board": _sel.get("board"), "pynq_host": _sel.get("pynq_host"),
        "backbone": backbone,
        "soc_magic": os.environ.get("WANT_MAGIC", ""),
        "bitstream_md5": os.environ.get("BIT_MD5", ""),
        "clk_hz": clk,
        "steady_cycles": steady, "cold_cycles": cmax, "median_cycles": median,
        "min_cycles": cmin, "max_cycles": cmax, "warm_cycles": warm,
        "two_inferences_ran": two_ran,
        "rows_cycles_cold": rows_cyc, "max_abs_err": aerr,
        "ms_per_frame_steady": steady / clk * 1000, "fps_steady": clk / steady,
        "mac": mac,
        "mac_per_cycle_conv": (mac / conv_cyc) if conv_cyc else 0.0,
        "mac_per_cycle_steady": mac / steady,
        "engine_ref_mac_per_cycle": ref,
        "dispatches_profiled": profiled, "dispatches_graph": n_graph,
        "roccmoon": {k: R.get(k) for k in
                     ("calls_engine", "calls_fallback", "bytes_wgt", "bytes_act",
                      "image_bytes", "cyc_tseq", "cyc_fill", "last_rc")},
        "by_kind": {k: {"n": kn[k], "cycles_cold": kc[k], "elements": ke[k],
                        "mac": km[k], "curated": k not in UNCURATED} for k in kc},
        "selectors": dict(l.split("=", 1) for l in open(sel_p).read().split()
                          if "=" in l),
        "kernel_cflags": open(cf_p).read().strip(),
    }
    json.dump(rec, open(out_p, "w"), indent=1)
    print("\n".join(out))


if __name__ == "__main__":
    main()
