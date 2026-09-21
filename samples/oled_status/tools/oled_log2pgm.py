#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Rebuild PGM images and wire logs from an oled_status console log, hash them, compare.

    oled_log2pgm.py <console.log> <outdir> [--expected expected/oled_status.json] [--update] [--ascii]

The host test prints
    PGMHEX <name> <offset> <hex>      pieces of a binary PGM (P5 128x64)
    WIRE[+] <name> <text>             the SSD1306 model's wire log ("+" continues a line)
This writes <outdir>/<name>.pgm and <outdir>/wire_<name>.txt and prints one sha256 per image.
With --expected it checks every image named under "pgm_sha256" and the "init_wire" lines;
with --update it rewrites those two keys (and nothing else) from this run.
Exit status 0 only if every check passed.
"""
import argparse, collections, hashlib, json, os, re, sys

HDR = b"P5\n128 64\n255\n"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log"); ap.add_argument("outdir")
    ap.add_argument("--expected"); ap.add_argument("--update", action="store_true")
    ap.add_argument("--ascii", action="store_true", help="also print each image as text")
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)

    pieces = collections.defaultdict(dict)
    wire = collections.defaultdict(list)
    for line in open(a.log, errors="replace"):
        line = line.rstrip("\n")
        m = re.match(r"^PGMHEX (\S+) (\d+) ([0-9a-f]+)$", line)
        if m:
            pieces[m.group(1)][int(m.group(2))] = bytes.fromhex(m.group(3))
            continue
        m = re.match(r"^WIRE(\+?) (\S+) (.*)$", line)
        if m:
            if m.group(1) and wire[m.group(2)]:
                wire[m.group(2)][-1] += m.group(3)
            else:
                wire[m.group(2)].append(m.group(3))

    fails = []
    hashes = {}
    for name, parts in sorted(pieces.items()):
        blob, off = b"", 0
        for k in sorted(parts):
            if k != off:
                fails.append(f"{name}: PGM piece missing at offset {off}")
                break
            blob += parts[k]; off += len(parts[k])
        if not blob.startswith(HDR) or len(blob) != len(HDR) + 128 * 64:
            fails.append(f"{name}: malformed PGM ({len(blob)} bytes)")
            continue
        open(os.path.join(a.outdir, f"{name}.pgm"), "wb").write(blob)
        hashes[name] = hashlib.sha256(blob).hexdigest()
        print(f"{hashes[name]}  {name}.pgm")
        if a.ascii:
            px = blob[len(HDR):]
            for y in range(64):
                print("".join("#" if px[y * 128 + x] else "." for x in range(128)))
    for name, lines in wire.items():
        with open(os.path.join(a.outdir, f"wire_{name}.txt"), "w") as f:
            f.write("\n".join(lines) + "\n")

    if a.expected:
        exp = json.load(open(a.expected))
        if a.update:
            exp["pgm_sha256"] = {k: v for k, v in hashes.items() if k in ("status", "pattern")}
            exp["init_wire"] = wire.get("init", [])
            json.dump(exp, open(a.expected, "w"), indent=2)
            open(a.expected, "a").write("\n")
            print(f"updated {a.expected}")
        else:
            for name, want in exp.get("pgm_sha256", {}).items():
                got = hashes.get(name)
                if got != want:
                    fails.append(f"{name}.pgm sha256 {got} != golden {want}")
            if "init_wire" in exp and wire.get("init") is not None and wire["init"] != exp["init_wire"]:
                fails.append("init wire sequence differs from golden")
            for name in exp.get("must_differ_from_status", []):
                if name in hashes and hashes[name] == exp.get("pgm_sha256", {}).get("status"):
                    fails.append(f"{name}.pgm matches the golden but must not (negative control)")
    for f in fails:
        print("FAIL:", f)
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
