#!/usr/bin/env python3
"""Turn Lab B24's consoles into the front-end and end-to-end tables, and into run.json."""
from __future__ import annotations

import json
import os
import re
import sys

CLK = 34482759
SENSOR_FPS = 59.0
FRAME_BYTES = 324 * 324
PIX = 288 * 288        # the pixels the front end actually touches


def kv(line):
    return dict(re.findall(r'(\w+)=([-\w.]+)', line or ""))


def main():
    run, archs, board = sys.argv[1], sys.argv[2].split(), sys.argv[3]
    out = {"board": board, "clock_hz": CLK, "archs": archs,
           "sensor_fps_324x324": SENSOR_FPS, "frame_bytes": FRAME_BYTES,
           "per_arch": {}}

    for a in archs:
        p = os.path.join(run, a, "console.txt")
        txt = open(p).read() if os.path.exists(p) else ""
        env = kv(next((l for l in txt.splitlines() if l.startswith("VR_ENV")), ""))
        med = kv(next((l for l in txt.splitlines() if l.startswith("VR_MEDIAN")), ""))
        acc = kv(next((l for l in txt.splitlines() if l.startswith("VR_ACC")), ""))
        hdr = kv(next((l for l in txt.splitlines()
                       if l.startswith("VISION_REPLAY arch=")), ""))
        frames = [kv(l) for l in txt.splitlines() if l.startswith("VR_FRAME ")]
        d = {"feed": hdr.get("feed", "?"),
             "selftest": int(env.get("selftest", -1)) if env else None,
             "golden_max_abs_err": int(env.get("golden_max_abs_err", -1)) if env else None,
             "feat_max_abs_err": max([int(f.get("feat_max_abs_err", -1))
                                      for f in frames] or [-1]),
             "n_frames": len(frames),
             "correct": int(acc.get("correct", -1)) if acc else None,
             "of": int(acc.get("of", -1)) if acc else None,
             "pass": "VISION_REPLAY: PASS" in txt}
        for k, src in (("fe_mono", "fe_mono"), ("fe_rgb", "fe_rgb"),
                       ("fe_bayer", "fe_bayer"), ("model", "model"),
                       ("end_to_end", "end_to_end")):
            d[k + "_cycles"] = int(med.get(src, 0)) if med else 0
        out["per_arch"][a] = d

    ref = next((out["per_arch"][a] for a in archs
                if out["per_arch"][a]["fe_mono_cycles"]), None)

    print("\n-- 1. the front end: what the sensor's colour costs on this core")
    if ref:
        print("   Every row reads the SAME 104,976-byte frame. A colour HM01B0 sends")
        print("   exactly as many bytes as a monochrome one; the colour is in the")
        print("   filter array, so the DMA is held constant and this is all software.")
        print("   %-22s %10s %9s %10s %12s %10s" %
              ("front end", "cycles", "ms", "out elems", "cyc/in-pixel", "vs mono"))
        print("   " + "-" * 80)
        rows = [("frame_fe_mono96", "fe_mono_cycles", 1 * 96 * 96),
                ("frame_fe_rgb96 (demosaic)", "fe_rgb_cycles", 3 * 96 * 96),
                ("frame_fe_bayer4_48", "fe_bayer_cycles", 4 * 48 * 48)]
        base = ref["fe_mono_cycles"]
        for name, key, elems in rows:
            c = ref[key]
            print("   %-22s %10d %9.3f %10d %12.3f %9.2fx"
                  % (name, c, 1000.0 * c / CLK, elems, c / PIX,
                     c / base if base else 0))
        out["frontend"] = {n: {"cycles": ref[k], "ms": round(1000.0 * ref[k] / CLK, 3),
                               "cycles_per_input_pixel": round(ref[k] / PIX, 4),
                               "vs_mono": round(ref[k] / base, 3) if base else 0}
                           for n, k, _ in rows}

    print("\n-- 2. end to end, per frame")
    print("   %-11s %-8s %11s %11s %13s %9s %9s" %
          ("arch", "feed", "front end", "model", "end to end", "ms", "fps"))
    print("   " + "-" * 78)
    for a in archs:
        d = out["per_arch"][a]
        fe = {"mono": d["fe_mono_cycles"], "rgb": d["fe_rgb_cycles"],
              "bayer4": d["fe_bayer_cycles"]}.get(d["feed"], 0)
        e2e = d["end_to_end_cycles"] or (fe + d["model_cycles"])
        d["fps"] = round(CLK / e2e, 3) if e2e else 0
        d["ms"] = round(1000.0 * e2e / CLK, 3)
        d["frontend_share"] = round(100.0 * fe / e2e, 2) if e2e else 0
        print("   %-11s %-8s %11d %11d %13d %9.3f %9.2f"
              % (a, d["feed"], fe, d["model_cycles"], e2e, d["ms"], d["fps"]))
    print("   (front end is the one this architecture's feed needs; the other two were")
    print("    timed on the same frames and are in table 1.)")

    print("\n-- 3. is the sensor or the model the constraint?")
    print("   HM01B0, 8-bit mode, 324x324, PCLK 6.25 MHz: %.0f fps, %.2f MB/s of DMA,"
          % (SENSOR_FPS, SENSOR_FPS * FRAME_BYTES / 1e6))
    print("   against the 53.6 MB/s this memory path measures (MEMORY_HIERARCHY.md).")
    print("   %-11s %9s %11s %10s %12s" %
          ("arch", "fps", "sensor fps", "binding", "sensor/model"))
    print("   " + "-" * 60)
    for a in archs:
        d = out["per_arch"][a]
        r = SENSOR_FPS / d["fps"] if d["fps"] else 0
        d["sensor_over_model"] = round(r, 2)
        print("   %-11s %9.2f %11.0f %10s %11.1fx"
              % (a, d["fps"], SENSOR_FPS, "COMPUTE" if r > 1 else "sensor", r))

    print("\n-- 4. correctness")
    for a in archs:
        d = out["per_arch"][a]
        print("   %-11s frame_fe_selftest=%s   feature vs host front end: "
              "max_abs_err=%s   model vs baked golden: max_abs_err=%s   %s"
              % (a, d["selftest"], d["feat_max_abs_err"], d["golden_max_abs_err"],
                 "PASS" if d["pass"] else "FAIL"))
        print("   %-11s replayed held-out frames classified correctly: %s of %s"
              % ("", d["correct"], d["of"]))
    out["all_pass"] = all(out["per_arch"][a]["pass"] for a in archs)
    out["all_feature_bit_exact"] = all(out["per_arch"][a]["feat_max_abs_err"] == 0
                                       for a in archs)
    # The two ratios expected/vision_replay.json gates on. Ratios rather than cycle
    # counts, for the reason that file states: the counts move with any compiler change
    # and the ratios are properties of three algorithms against one core.
    if ref and ref.get("fe_mono_cycles"):
        b = ref["fe_mono_cycles"]
        out["frontend_rgb_over_mono_x100"] = round(100 * ref["fe_rgb_cycles"] / b)
        out["frontend_bayer_over_mono_x100"] = round(100 * ref["fe_bayer_cycles"] / b)
    out["per_channel"] = os.environ.get("MB_PER_CHANNEL", "1") == "1"
    out["bitstream_md5"] = os.environ.get("BIT_MD5", "unknown")
    out["bitstream_note"] = os.environ.get("BIT_NOTE", "")
    json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
