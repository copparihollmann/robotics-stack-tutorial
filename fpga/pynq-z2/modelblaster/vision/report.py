#!/usr/bin/env python3
"""Turn Lab B22's consoles into the tables CAMERA_TASK.md quotes, and into run.json.

    python3 report.py <run dir> "<archs>" "<scalar archs>" <board>

Per-dispatch MACs are computed from the IR's own shape records rather than from the
PyTorch model, so a dispatch's cycles/MAC is derived from the graph that actually ran.
"""
from __future__ import annotations

import json
import os
import re
import sys

CLK = 34482759            # 1000/29 MHz, the built FCLK0 -- see PEXT_BITSTREAM.md
SENSOR_FPS = 59.0         # HM01B0, 8-bit mode, 324x324 (CAMERA_PCB_SPEC.md section 1)
FRAME_BYTES = 324 * 324


def op_macs(o):
    """MACs for one dispatch, from the IR shape record."""
    op, s = o["op"], o.get("shape", {})
    if op.startswith("depthwise_conv2d"):
        return s["OC"] * s["OH"] * s["OW"] * s["KH"] * s["KW"]
    if op.startswith("conv2d"):
        return s["OC"] * s["OH"] * s["OW"] * s["KH"] * s["KW"] * s["IC"]
    if op.startswith("linear"):
        return s["M"] * s["K"] * s["N"]
    return 0


def kv(line):
    return dict(re.findall(r'(\w+)=([-\w.]+)', line or ""))


def main():
    run, archs, scalar_archs, board = (sys.argv[1], sys.argv[2].split(),
                                       sys.argv[3].split(), sys.argv[4])
    out = {"board": board, "clock_hz": CLK, "archs": archs,
           "sensor_fps_324x324": SENSOR_FPS, "per_arch": {}}

    for a in archs:
        d = {}
        irp = os.path.join(run, a, "pext", "ir", "graph.json")
        g = json.load(open(irp)) if os.path.exists(irp) else {"ops": []}
        dispatch = [o for o in g["ops"] if o["op"] != "view"]
        d["macs"] = sum(op_macs(o) for o in dispatch)
        meta_p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "weights", "%s_meta.json" % a)
        meta = json.load(open(meta_p)) if os.path.exists(meta_p) else {}
        d["params"] = meta.get("params", 0)
        d["acc_fp32"] = meta.get("test_acc_fp32", 0)
        d["feed"] = meta.get("feed", "?")
        d["in_shape"] = meta.get("in_shape", [])

        for t in ("pext", "scalar"):
            p = os.path.join(run, a, t, "console.txt")
            txt = open(p).read() if os.path.exists(p) else ""
            if t == "pext":
                r = kv(next((l for l in txt.splitlines()
                             if l.startswith("MB_PEXT_RUN")), ""))
                d["pext_cycles"] = int(r.get("median", 0))
                ops = [kv(l) for l in txt.splitlines() if l.startswith("MB_PEXT_OP ")]
                d["pext_ops"] = ops
                m = re.search(r'^MB_PEXT_OUT\s+(.*)$', txt, re.M)
                d["out"] = [int(x) for x in m.group(1).split()] if m else []
                d["max_abs_err"] = int(kv(next(
                    (l for l in txt.splitlines() if "max_abs_err" in l), "")
                ).get("max_abs_err", -1))
                neg = kv(next((l for l in txt.splitlines()
                               if l.startswith("MB_PEXT_NEG cpu=")), ""))
                d["neg_trapped"] = neg.get("trapped") == "1"
            else:
                ms = [kv(l) for l in txt.splitlines() if l.startswith("MB_HART ")]
                h0 = next((m for m in ms if m.get("mhartid") == "0"), {})
                d["scalar_cycles"] = int(h0.get("median", 0))
        # join the board's per-dispatch cycles to the IR's per-dispatch MACs, in order
        rows = []
        for i, o in enumerate(dispatch):
            c = next((int(x.get("cycles", 0)) for x in d.get("pext_ops", [])
                      if int(x.get("id", -1)) == i), None)
            if c is None and i < len(d.get("pext_ops", [])):
                c = int(d["pext_ops"][i].get("cycles", 0))
            rows.append({"i": i, "op": o["op"], "macs": op_macs(o),
                         "cycles": c or 0,
                         "shape": o.get("shape", {})})
        d["dispatch"] = rows
        out["per_arch"][a] = d

    print("\n-- 1. one inference, measured on hart 0 of this bitstream")
    print("   %-10s %-8s %10s %8s %13s %12s %8s %9s %9s %7s" %
          ("arch", "feed", "MACs", "params", "scalar cyc", "MBP cyc",
           "speedup", "MBP ms", "cyc/MAC", "fps"))
    print("   " + "-" * 104)
    for a in archs:
        d = out["per_arch"][a]
        pc = d.get("pext_cycles", 0)
        sc = d.get("scalar_cycles", 0)
        sp = sc / pc if pc and sc else 0
        cpm = pc / d["macs"] if pc and d["macs"] else 0
        d["cycles_per_mac"] = round(cpm, 4)
        d["macs_per_cycle"] = round(1 / cpm, 4) if cpm else 0
        d["speedup"] = round(sp, 3)
        d["pext_ms"] = round(1000.0 * pc / CLK, 3)
        d["model_fps"] = round(CLK / pc, 3) if pc else 0
        print("   %-10s %-8s %10d %8d %13s %12d %8s %9.3f %9.3f %7.2f" %
              (a, d["feed"], d["macs"], d["params"],
               ("%d" % sc) if sc else "-", pc,
               ("%.2fx" % sp) if sp else "-", d["pext_ms"], cpm, d["model_fps"]))
    print("   (cyc/MAC: dense convolution on this core reaches 1.24-1.30 --")
    print("    SPEECH_ON_ROCKET.md section 11.4. Anything much above that is layout.)")

    print("\n-- 2. per dispatch, MBP build")
    for a in archs:
        d = out["per_arch"][a]
        tot = sum(r["cycles"] for r in d["dispatch"]) or 1
        byop = {}
        for r in d["dispatch"]:
            e = byop.setdefault(r["op"], [0, 0, 0])
            e[0] += r["cycles"]; e[1] += 1; e[2] += r["macs"]
        print("   %s:" % a)
        print("      %-24s %4s %12s %7s %12s %9s" %
              ("op", "x", "cycles", "%", "MACs", "cyc/MAC"))
        for op, (c, n, mm) in sorted(byop.items(), key=lambda kv: -kv[1][0]):
            # Pooling has no multiply-accumulates at all, so a cycles/MAC for it would be
            # a division by zero dressed up as a number.
            print("      %-24s %4d %12d %6.1f%% %12s %9s"
                  % (op, n, c, 100.0 * c / tot,
                     ("%d" % mm) if mm else "-", ("%.3f" % (c / mm)) if mm else "-"))
        d["cycles_by_op"] = {k: {"cycles": v[0], "n": v[1], "macs": v[2],
                                 "cycles_per_mac": round(v[0] / v[2], 4) if v[2] else 0}
                             for k, v in byop.items()}

    print("\n-- 3. the first layer, which is where the sensor's colour lands")
    print("   %-10s %-8s %-14s %3s %10s %12s %9s %10s" %
          ("arch", "feed", "layer-1 out", "IC", "MACs", "cycles", "cyc/MAC", "% of net"))
    print("   " + "-" * 84)
    for a in archs:
        d = out["per_arch"][a]
        if not d["dispatch"]:
            continue
        r = d["dispatch"][0]
        s = r["shape"]
        tot = sum(x["cycles"] for x in d["dispatch"]) or 1
        d["layer1"] = {"ic": s.get("IC"), "macs": r["macs"], "cycles": r["cycles"],
                       "cycles_per_mac": round(r["cycles"] / r["macs"], 4)
                       if r["macs"] else 0,
                       "share": round(100.0 * r["cycles"] / tot, 2)}
        print("   %-10s %-8s %-14s %3s %10d %12d %9.3f %9.1f%%" %
              (a, d["feed"], "%sx%sx%s" % (s.get("OC"), s.get("OH"), s.get("OW")),
               s.get("IC"), r["macs"], r["cycles"],
               d["layer1"]["cycles_per_mac"], d["layer1"]["share"]))

    print("\n-- 4. correctness")
    for a in archs:
        d = out["per_arch"][a]
        print("   %-10s max_abs_err vs the scalar codegen's golden = %s   "
              "hart-1 trap = %s   fp32 test acc = %.2f%%"
              % (a, d.get("max_abs_err"), d.get("neg_trapped"),
                 100 * d.get("acc_fp32", 0)))
    out["all_bit_exact"] = all(out["per_arch"][a].get("max_abs_err") == 0
                               for a in archs)
    out["all_neg_trapped"] = all(out["per_arch"][a].get("neg_trapped")
                                 for a in archs)

    if "cnn" in out["per_arch"] and "mbnet" in out["per_arch"]:
        c, s = out["per_arch"]["cnn"], out["per_arch"]["mbnet"]
        if c.get("pext_cycles") and s.get("pext_cycles"):
            ratio = s["pext_cycles"] / c["pext_cycles"]
            out["mbnet_over_cnn_cycles_x100"] = round(100 * ratio)
            dw = s["cycles_by_op"].get("depthwise_conv2d_s8", {})
            tot = sum(v["cycles"] for v in s["cycles_by_op"].values()) or 1
            totm = sum(v["macs"] for v in s["cycles_by_op"].values()) or 1
            print("\n-- 5. the headline")
            print("   mbnet has %.1f%% of cnn's MACs and takes %.2fx its cycles."
                  % (100.0 * s["macs"] / c["macs"], ratio))
            if dw:
                print("   Its depthwise dispatches are %.1f%% of its MACs and %.1f%% of "
                      "its cycles," % (100.0 * dw["macs"] / totm,
                                       100.0 * dw["cycles"] / tot))
                print("   at %.3f cycles/MAC against %.3f for its own dense "
                      "convolutions."
                      % (dw["cycles_per_mac"],
                         s["cycles_by_op"].get("conv2d_s8", {}).get("cycles_per_mac", 0)))
            print("   MBP.DOT8 reduces along the input-channel axis; a depthwise")
            print("   convolution has none, so the model with fewer operations is the")
            print("   slower one.")

    print("\n-- 6. is the sensor or the model the constraint?")
    print("   HM01B0, 8-bit mode, 324x324: %.0f fps, %d bytes/frame = %.2f MB/s" %
          (SENSOR_FPS, FRAME_BYTES, SENSOR_FPS * FRAME_BYTES / 1e6))
    print("   %-10s %9s %10s %12s" % ("arch", "model fps", "sensor fps", "binding"))
    print("   " + "-" * 48)
    for a in archs:
        d = out["per_arch"][a]
        f = d.get("model_fps", 0)
        print("   %-10s %9.2f %10.0f %12s"
              % (a, f, SENSOR_FPS, "MODEL" if f < SENSOR_FPS else "sensor"))
        d["sensor_over_model"] = round(SENSOR_FPS / f, 2) if f else 0

    # Two derived ratios, so expected/vision_board.json can gate on the FINDINGS rather
    # than on raw cycle counts (which move with any compiler or codegen change and would
    # make a red check say nothing about the hardware). Same discipline as
    # expected/kws_board.json's dscnn_over_cnn_cycles_x100.
    pa = out["per_arch"]
    if "mbnet" in pa:
        # The op NAMES change with the quantisation granularity -- --per-channel emits
        # conv2d_s8_pc -- so look the pair up by role rather than by spelling, or the
        # ratio silently disappears from run.json on exactly the build that ships.
        cbo = pa["mbnet"].get("cycles_by_op", {})
        dw = cbo.get("depthwise_conv2d_s8") or cbo.get("depthwise_conv2d_s8_pc") or {}
        dn = cbo.get("conv2d_s8") or cbo.get("conv2d_s8_pc") or {}
        if dw.get("cycles_per_mac") and dn.get("cycles_per_mac"):
            out["depthwise_over_dense_cycmac_x100"] = round(
                100 * dw["cycles_per_mac"] / dn["cycles_per_mac"])
    if "cnn" in pa and "cnn_bayer" in pa:
        a = pa["cnn"].get("layer1", {}).get("cycles_per_mac")
        b = pa["cnn_bayer"].get("layer1", {}).get("cycles_per_mac")
        if a and b:
            out["layer1_cycmac_mono_over_bayer_x100"] = round(100 * a / b)
    if "cnn" in pa and "cnn_rgb" in pa:
        a = pa["cnn"].get("layer1", {}).get("cycles_per_mac")
        b = pa["cnn_rgb"].get("layer1", {}).get("cycles_per_mac")
        if a and b:
            out["layer1_cycmac_mono_over_rgb_x100"] = round(100 * a / b)
    out["per_channel"] = os.environ.get("MB_PER_CHANNEL", "0") == "1"

    try:
        out["int8_accuracy"] = json.load(open(os.path.join(run, "int8_accuracy.json")))
    except Exception:
        pass
    out["bitstream_md5"] = os.environ.get("BIT_MD5", "unknown")
    out["bitstream_note"] = os.environ.get("BIT_NOTE", "")
    json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
