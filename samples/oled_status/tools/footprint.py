#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Footprint of the OLED stack in a Zephyr image, from the linker map (no anytree needed).

    footprint.py <build-dir> [--baseline <build-dir>] [--json out.json]

Counts every input section that survived --gc-sections, by the object it came from, and
splits it into code+const (text/rodata/init tables), data and bss/noinit. These boards run
from DDR (CONFIG_XIP=n), so "image" = code+const+data is what zephyr.bin carries and
"memory" = image + bss/noinit is what the program occupies.
With --baseline, also prints the whole-image delta against another build (hello_world).
"""
import argparse, json, re, sys

GROUPS = [
    ("i2c_sifive (TLI2C driver)", r"i2c_sifive\.c\.obj"),
    ("i2c core helpers", r"/(i2c_common|i2c_rtio_default)\.c\.obj"),
    ("ssd1306 display driver", r"ssd1306\.c\.obj"),
    ("CFB (character framebuffer)", r"\(cfb\.c\.obj\)"),
    ("oled_status library", r"oled_status\.c\.obj"),
    ("5x8 font", r"font5x8\.c\.obj"),
    ("demo main", r"app/libapp\.a\(main\.c\.obj\)"),
    ("heap / k_malloc", r"(mempool|heap|malloc)\.c\.obj"),
]
SKIP_OUT = re.compile(r"^(\.debug|\.comment|\.stab|\.rel|\.plt|\.iplt|\.gnu|\.note|\.last_ram_section|\.riscv\.attributes|\.line|/DISCARD/)")
NOBITS = re.compile(r"(bss|noinit)")

def parse(mapfile):
    txt = open(mapfile).read()
    start = txt.find("Linker script and memory map")
    lines = txt[start:].splitlines()
    out_sec = ""
    pending = None
    rows = []  # (out_sec, in_sec, size, obj)
    for ln in lines:
        m = re.match(r"^([A-Za-z_.][^\s]*)(\s+0x[0-9a-f]+\s+0x[0-9a-f]+)?", ln)
        if m and not ln.startswith(" "):
            out_sec = m.group(1)
            pending = None
            continue
        m = re.match(r"^ (\S+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S.*)$", ln)
        if m:
            rows.append((out_sec, m.group(1), int(m.group(3), 16), m.group(4)))
            pending = None
            continue
        m = re.match(r"^ (\.\S+|[A-Za-z_]\S*)\s*$", ln)
        if m and not ln.startswith("  "):
            pending = m.group(1)
            continue
        m = re.match(r"^\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S.*)$", ln)
        if m and pending:
            rows.append((out_sec, pending, int(m.group(2), 16), m.group(3)))
            pending = None
    return rows

def classify(out_sec, in_sec):
    if NOBITS.search(out_sec) or NOBITS.search(in_sec):
        return "bss"
    if re.fullmatch(r"\.?s?datas?", out_sec) or re.match(r"\.s?data", in_sec):
        return "data"
    return "code"

def totals(rows, pattern=None):
    t = {"code": 0, "data": 0, "bss": 0}
    for out_sec, in_sec, size, obj in rows:
        if SKIP_OUT.match(out_sec) or size == 0:
            continue
        if pattern and not re.search(pattern, obj):
            continue
        t[classify(out_sec, in_sec)] += size
    t["image"] = t["code"] + t["data"]
    t["memory"] = t["image"] + t["bss"]
    return t

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build"); ap.add_argument("--baseline"); ap.add_argument("--json")
    a = ap.parse_args()
    rows = parse(f"{a.build}/zephyr/zephyr.map")
    res = {"components": {}, "whole": totals(rows)}
    print(f"{'component':32s} {'code+const':>10s} {'data':>6s} {'bss':>6s} {'image':>7s} {'memory':>7s}")
    s = {"code": 0, "data": 0, "bss": 0, "image": 0, "memory": 0}
    for name, pat in GROUPS:
        t = totals(rows, pat)
        res["components"][name] = t
        for k in s:
            s[k] += t[k]
        print(f"{name:32s} {t['code']:10d} {t['data']:6d} {t['bss']:6d} {t['image']:7d} {t['memory']:7d}")
    print(f"{'sum of the above':32s} {s['code']:10d} {s['data']:6d} {s['bss']:6d} {s['image']:7d} {s['memory']:7d}")
    res["sum"] = s
    w = res["whole"]
    print(f"{'whole image':32s} {w['code']:10d} {w['data']:6d} {w['bss']:6d} {w['image']:7d} {w['memory']:7d}")
    if a.baseline:
        b = totals(parse(f"{a.baseline}/zephyr/zephyr.map"))
        d = {k: w[k] - b[k] for k in w}
        res["baseline_whole"] = b
        res["delta_vs_baseline"] = d
        print(f"{'baseline (hello_world)':32s} {b['code']:10d} {b['data']:6d} {b['bss']:6d} {b['image']:7d} {b['memory']:7d}")
        print(f"{'delta vs baseline':32s} {d['code']:10d} {d['data']:6d} {d['bss']:6d} {d['image']:7d} {d['memory']:7d}")
    if a.json:
        json.dump(res, open(a.json, "w"), indent=2)

if __name__ == "__main__":
    sys.exit(main())
