#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Code placement against measured cycles: is a copy loop's speed a function of where it lands?

Lab B26's engine images build the same planar weight image (8.52 MB) in one of THREE cycle
counts -- 222.1, 229.6 or 237.0 M -- and hart 0's conv staging copy in one of two (33.1 or
35.0 M), deterministically per image and independent of the session (ROCC_DECOUPLED.md
s8.15.4).  This script puts each measured image next to where its hot loops sit in its ELF:
function start addresses mod 4 and mod 8, and for every tight backward branch (an inner loop:
target below the branch, within 64 bytes) the loop head's and the branch's address mod 4.

It reads each image's dis.txt (the lab's objdump) and zephyr.elf symbol table from out/, which
is not durable, so the table it writes (placement_modes.json) is the record.

    python3 placement_modes.py --runs out/rocket_moonshine_enc_{roccmoon,smx,smx2,nhwc,nhwc2} \
        --extra out/rocket_moonshine_enc_align4 --json placement_modes.json
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess

HOT = ["mbxr_wimage_build", "mbxr_lin_row", "mbxr_conv_row", "mbxr_convn_row", "kernel_conv2d_s8",
       "kernel_linear_s8", "kernel_softmax_s8", "kernel_layernorm_s8", "kernel_matmul_b_s8",
       "kernel_permute4_s8", "kernel_rope_s8", "kernel_gelu_s8", "kernel_add_s8", "kernel_groupnorm_s8",
       "kernel_tanh_s8", "memset", "memcpy", "mbxr_run", "mbxr_wait"]


def loops(dis: str, funcs) -> dict:
    cur, start = None, {}
    out = {f: [] for f in funcs}
    out.update({f + "@model": [] for f in funcs if f.startswith("kernel_")})
    for line in open(dis, errors="replace"):
        m = re.match(r"^([0-9a-f]+) <([^>]+)>:", line)
        if m:
            cur = m.group(2)
            if cur.endswith("_moonshine_enc") and cur[:-len("_moonshine_enc")] + "@model" in out:
                cur = cur[:-len("_moonshine_enc")] + "@model"      # ModelBlaster's per-model kernel
            start[cur] = int(m.group(1), 16)
            continue
        if cur not in out:
            continue
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]+)\s+(\w+)\s+(.*?)([0-9a-f]+) <", line)
        if m and (m.group(3).startswith("b") or m.group(3) == "j"):
            pc, tgt = int(m.group(1), 16), int(m.group(5), 16)
            if tgt < pc and pc - tgt < 64:
                out[cur].append({"head_off": tgt - start[cur], "len": pc - tgt, "head_mod4": tgt % 4,
                                 "branch_mod4": pc % 4, "branch_bits": len(m.group(2)) * 4})
    return {f: {"start": hex(start[f]), "start_mod4": start[f] % 4, "start_mod8": start[f] % 8, "loops": v}
            for f, v in out.items() if f in start}


def image(run: str, model: str, measured: dict | None) -> dict:
    d = os.path.join(run, model)
    rec = {"run": os.path.basename(run), "model": model, "measured": measured}
    dis = os.path.join(d, "dis.txt")
    if not os.path.exists(dis):
        rec["error"] = "no dis.txt"
        return rec
    rec["kernel_cflags"] = open(os.path.join(d, "kernel_cflags.txt")).read().strip() \
        if os.path.exists(os.path.join(d, "kernel_cflags.txt")) else None
    rec["functions"] = loops(dis, HOT)
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", nargs="+", required=True, help="lab run dirs with run.json")
    ap.add_argument("--extra", nargs="*", default=[], help="built-only run dirs (no run.json needed)")
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    recs = []
    for run in a.runs:
        r = json.load(open(os.path.join(run, "run.json")))
        for m, v in r["models"].items():
            rs = (v.get("roccmoon_stats") or {}).get("total")
            if not rs or not rs.get("image_cycles"):
                continue
            meas = {"image_cycles": rs["image_cycles"], "cycles_stage": rs.get("cycles_stage"),
                    "dispatch_cycles_total": v.get("dispatch_cycles_total"),
                    "steady": v.get("dispatch_cycles_total", 0) - rs["image_cycles"],
                    "per_kind_cycles_per_element": {k: kk.get("cycles_per_element") for k, kk in v["per_kind"].items()}}
            recs.append(image(run, m, meas))
    for run in a.extra:
        for d in sorted(glob.glob(os.path.join(run, "enc_*"))):
            if os.path.exists(os.path.join(d, "dis.txt")):
                recs.append(image(run, os.path.basename(d), None))
    json.dump({"what": __doc__.strip().splitlines()[0], "images": recs}, open(a.json, "w"), indent=1)
    for rec in recs:
        f = rec.get("functions", {})
        wb = f.get("mbxr_wimage_build", {})
        lr = f.get("mbxr_lin_row", {})
        cv = f.get("kernel_conv2d_s8", {})
        hot = lambda fn, n: [(l["head_mod4"], l["branch_mod4"]) for l in f.get(fn, {}).get("loops", [])][:n]
        ms = rec["measured"] or {}
        print(f'{rec["run"][21:]:10s} {rec["model"]:24s} img {ms.get("image_cycles", 0) / 1e6:7.2f} '
              f'stage {(ms.get("cycles_stage") or 0) / 1e6:6.2f}  wimage start%4={wb.get("start_mod4")} '
              f'rowcopy(head,br)%4={hot("mbxr_wimage_build", 3)[2:3]}  lin_row loops={hot("mbxr_lin_row", 2)}  '
              f'conv start%4={cv.get("start_mod4")}  cflags="{(rec.get("kernel_cflags") or "")[-24:]}"')
    print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
