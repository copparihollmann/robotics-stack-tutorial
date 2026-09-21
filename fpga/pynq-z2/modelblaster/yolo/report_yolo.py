"""Lab B106 -- turn one YOLOv8n board console into the four numbers the lab exists for.

    cycles, MAC/cycle achieved, the weight-streaming bytes, and calls_fallback.

WHY IT IS NOT scripts/57's report.py.  That one raises on a kind it does not know, on
purpose -- its job is to refuse to silently drop a Moonshine op.  YOLOv8n's kinds are a
different set, and three of them (cat3_c1_s8, cat4_c1_s8, upsample_nearest_s8) have NO
curated kernel on any backend.  Those rows are the point here, not an error, so this
reporter knows the YOLO set, refuses an unknown kind the same way, and labels the
uncurated rows in the table rather than hiding them.

MAC/cycle IS QUOTED TWO WAYS AND BOTH ARE PRINTED.
  * over conv2d_s8 cycles only  -- what the CONVOLUTION achieved, comparable to the
    engine's 44.409 on Moonshine and to the curated MBP kernel's 0.588-0.767 dense;
  * over the whole inference   -- what the NETWORK achieved, which is the honest
    end-to-end figure and is always the smaller of the two.
Quoting only the first would flatter the accelerator; only the second would hide where
the cycles went.
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter

KNOWN = {"conv2d_s8", "silu_s8", "add_s8", "maxpool2d_s8", "cat2_c1_s8",
         "cat3_c1_s8", "cat4_c1_s8", "upsample_nearest_s8"}
#: ops with no curated kernel anywhere in the roccmoon -> pext_nl -> pext lineage.
UNCURATED = {"cat3_c1_s8", "cat4_c1_s8", "upsample_nearest_s8"}
#: and WHY each is expensive, which is not the same as "it has no kernel".
WHY = {"cat3_c1_s8": "reference C, FLOAT requantise on an FPU-less core",
       "cat4_c1_s8": "reference C, FLOAT requantise on an FPU-less core",
       "upsample_nearest_s8": "reference C, int8 copy (cheap)"}


def op_macs(o: dict) -> int:
    s = o["shape"]
    if o["op"] != "conv2d_s8":
        return 0
    return s["OC"] * s["OH"] * s["OW"] * s["IC"] * s["KH"] * s["KW"]


def op_elements(o: dict) -> int:
    s, k = o["shape"], o["op"]
    if k == "conv2d_s8":
        return s["OC"] * s["OH"] * s["OW"]
    if k.startswith("cat"):
        return s["C_total"] * s["H"] * s["W"] * s.get("N", 1)
    if k == "upsample_nearest_s8":
        return s["C"] * s["IH"] * s["scale"] * s["IW"] * s["scale"] * s.get("N", 1)
    if k == "maxpool2d_s8":
        return s["C"] * s["OH"] * s["OW"] * s.get("N", 1)
    return s.get("n", 0)


def main() -> None:
    console, graph_p, sel_p, cf_p, out_p = sys.argv[1:6]
    txt = open(console, errors="replace").read()
    g = json.load(open(graph_p))
    clk = int(os.environ.get("CLK_HZ", "40000000"))
    ref = float(os.environ.get("ENGINE_REF_MACC", "44.409"))

    run = re.search(r"^MB_PEXT_RUN .*?median=(\d+).*?max_abs_err=(-?\d+)", txt, re.M)
    if not run:
        sys.exit("no MB_PEXT_RUN line in the console")
    total, aerr = int(run.group(1)), int(run.group(2))

    cyc = {}
    for m in re.finditer(r"^MB_PEXT_OP id=(\d+) name=(\S+) op=(\S+) shape=\S* cycles=(\d+)", txt, re.M):
        cyc[int(m.group(1))] = (m.group(3), int(m.group(4)))

    by_id = {o["dispatch_id"]: o for o in g["ops"] if "dispatch_id" in o}
    unknown = sorted({o["op"] for o in g["ops"]} - KNOWN - {"chunk2_c1"})
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

    n_graph = sum(1 for o in g["ops"] if o["op"] != "chunk2_c1")
    rows_cyc = sum(kc.values())
    mac = sum(km.values())
    conv_cyc = kc.get("conv2d_s8", 0)

    # MB_ROCCMOON phase=total -- the engine's own counters.
    tot = re.findall(r"^MB_ROCCMOON phase=total (.*)$", txt, re.M)
    R = dict(kv.split("=", 1) for kv in tot[-1].split()) if tot else {}
    gi = lambda k: int(R.get(k, -1))

    out = []
    P = out.append
    P(f"Lab B106  YOLOv8n on roccmoon  {os.environ.get('NAME','')}  "
      f"{os.environ.get('WANT_MAGIC','')} ({os.environ.get('BIT_MD5','')})")
    P(f"{run.group(0)}")
    P(f"dispatches: {profiled} of {n_graph} profiled   (chunk2_c1 is a view and is elided)")
    P(f"total dispatch cycles {rows_cyc:,}  wall {total:,}  "
      f"({rows_cyc/total*100:.2f} % of wall)  max_abs_err {aerr}")
    P(f"one frame = {total/clk*1000:.1f} ms at {clk/1e6:g} MHz  =  {clk/total:.4f} fps")
    P("")
    P(f"MAC in this graph                {mac:>16,}")
    P(f"MAC/cycle over conv2d_s8 cycles  {mac/conv_cyc if conv_cyc else 0:>16.4f}"
      f"   against the engine's {ref} on Moonshine  ({(mac/conv_cyc)/ref*100 if conv_cyc else 0:.2f} %)")
    P(f"MAC/cycle over the whole frame   {mac/total:>16.4f}")
    P("")
    P("THE ENGINE'S OWN COUNTERS (MB_ROCCMOON phase=total)")
    P(f"  calls_engine   {gi('calls_engine'):>10}      calls_fallback {gi('calls_fallback'):>10}"
      f"   of {sum(1 for o in g['ops'] if o['op']=='conv2d_s8')} conv2d_s8 dispatches")
    P(f"  bytes_wgt      {gi('bytes_wgt'):>10}      image_bytes    {gi('image_bytes'):>10}")
    P(f"  bytes_act      {gi('bytes_act'):>10}      cyc_tseq       {gi('cyc_tseq'):>10}")
    P(f"  cyc_fill       {gi('cyc_fill'):>10}      last_rc        {gi('last_rc'):>10}")
    P(f"  lut_lane       {gi('lut_lane'):>10}      lut_fallback   {gi('lut_fallback'):>10}"
      f"   lut_els_lane {gi('lut_els_lane')}")
    if gi("calls_engine") == 0:
        P("  *** calls_engine = 0: NOT ONE convolution satisfied the engine's guard. Every")
        P("      conv2d_s8 ran the curated MBP kernel on hart 0. The engine was consulted")
        P("      (the kernel is linked and calls_fallback counts it) and declined.")
    P("")
    P(f"{'kind':<22}{'n':>4}{'cycles':>14}{'share%':>8}{'elements':>12}{'cyc/el':>10}"
      f"{'MAC/cyc':>10}   note")
    for k in sorted(kc, key=lambda x: -kc[x]):
        note = "UNCURATED -- " + WHY[k] if k in UNCURATED else ""
        P(f"{k:<22}{kn[k]:>4}{kc[k]:>14,}{100*kc[k]/rows_cyc:>8.2f}{ke[k]:>12,}"
          f"{kc[k]/ke[k] if ke[k] else 0:>10.2f}"
          f"{(km[k]/kc[k]) if km[k] else 0:>10.3f}   {note}")
    unc = sum(kc[k] for k in kc if k in UNCURATED)
    P(f"\nuncurated kinds (reference C): {unc:,} cycles = {100*unc/rows_cyc:.2f} % of the total")

    rec = {
        "lab": "B106 yolov8n_roccmoon", "name": os.environ.get("NAME", ""),
        "soc_magic": os.environ.get("WANT_MAGIC", ""), "bitstream_md5": os.environ.get("BIT_MD5", ""),
        "clk_hz": clk, "wall_cycles": total, "rows_cycles": rows_cyc, "max_abs_err": aerr,
        "ms_per_frame": total / clk * 1000, "fps": clk / total,
        "mac": mac, "mac_per_cycle_conv": (mac / conv_cyc) if conv_cyc else 0.0,
        "mac_per_cycle_frame": mac / total, "engine_ref_mac_per_cycle": ref,
        "dispatches_profiled": profiled, "dispatches_graph": n_graph,
        "roccmoon": {k: R.get(k) for k in
                     ("calls_engine", "calls_fallback", "bytes_wgt", "bytes_act",
                      "image_bytes", "cyc_tseq", "cyc_fill", "last_rc",
                      "lut_lane", "lut_fallback", "lut_els_lane")},
        "by_kind": {k: {"n": kn[k], "cycles": kc[k], "elements": ke[k], "mac": km[k],
                        "curated": k not in UNCURATED} for k in kc},
        "selectors": dict(l.split("=", 1) for l in open(sel_p).read().split()
                          if "=" in l),
        "kernel_cflags": open(cf_p).read().strip(),
    }
    json.dump(rec, open(out_p, "w"), indent=1)
    print("\n".join(out))


if __name__ == "__main__":
    main()
