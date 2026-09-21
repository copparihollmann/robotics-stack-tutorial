#!/usr/bin/env python3
"""Which dispatches actually got a curated MBP kernel, read out of the generated C.

    python3 curated_report.py kernels.c graph.json <arch>

ATTRIBUTED BY TEXT REGION, not by the `/* algorithm: ... */` comments and not by the
exported function's own body.  The comments are per curated FILE, so a reference kernel
emitted after one inherits it to any reader doing nearest-preceding matching; and the
curated kernels put their MBP instructions in static helpers that the exported function
calls, so its own body contains none.  Each kernel therefore owns the text from the end
of the previous kernel's body to the end of its own -- helpers included.

For `mbnet` this is the whole point of Lab B22: depthwise_conv2d_s8's region is an
ordinary `acc += iv*wv` loop with no MBP instruction anywhere in it, while conv2d_s8's
region is full of them, and the cycle table is the consequence.  Lifted verbatim from the
inline version in scripts/37_rocket_kws_board.sh so the two labs report the same thing
the same way.
"""
import collections
import json
import re
import sys


def body_end(t, i):
    d = 0
    while i < len(t):
        d += (t[i] == "{") - (t[i] == "}")
        if d == 0:
            return i
        i += 1
    return len(t)


def main():
    src, irp, arch = sys.argv[1], sys.argv[2], sys.argv[3]
    t = open(src).read()
    g = json.load(open(irp))
    n = collections.Counter(o["op"] for o in g["ops"] if o["op"] != "view")

    defs = []
    for op in n:
        m = re.search(r"\bkernel_" + re.escape(op) + r"[a-z0-9_]*\s*\([^;{]*\{", t)
        if m:
            defs.append((m.start(), body_end(t, m.end() - 1), op))
    defs.sort()
    prev = 0
    for start, end, op in defs:
        region = t[prev:end]
        prev = end
        calls = collections.Counter(re.findall(r"mb_pext_(dot8|max8|qmul|clip8)\s*\(",
                                               region))
        print("%s %-24s dispatches=%-3d MBP=%-3s %s"
              % (arch, op, n[op], "yes" if calls else "NO",
                 " ".join("%s=%d" % kv for kv in sorted(calls.items()))
                 or "(scalar reference)"))
    for op in sorted(n):
        if op not in [d[2] for d in defs]:
            print("%s %-24s dispatches=%-3d NO DEFINITION" % (arch, op, n[op]))


if __name__ == "__main__":
    main()
