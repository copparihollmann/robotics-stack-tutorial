#!/usr/bin/env python3
"""Did the other workstream's MBP_B84 addition change B83's COMPILED matmul_b_s8?

kernel_delta_is_inert.py proves the SOURCE change is additive and entirely under `#if MBP_B84`.
This proves the consequence on the actual image: the mnemonic sequence of every `pmmb*` symbol
in B83's decoder control must equal B82's, function for function.  Addresses and absolute
operands are dropped (the two images are different builds and relocate differently); what is
compared is the instruction sequence, which is what codegen decides.

    python3 archive/runs/b83_all_levers/dis_matmul_b_identical.py \
        out/b82_dec_unr_on/dec_q16/dis.txt out/b83_dec_ctl/dec_q16/dis.txt
"""
import re
import sys

SYM = re.compile(r"^[0-9a-f]{16} <([^>]+)>:")
INSN = re.compile(r"^\s+[0-9a-f]+:\s+[0-9a-f ]+\t([a-z0-9._]+)")


def funcs(path, want):
    out, cur = {}, None
    with open(path, errors="replace") as f:
        for line in f:
            m = SYM.match(line)
            if m:
                cur = m.group(1) if want(m.group(1)) else None
                if cur:
                    out[cur] = []
                continue
            if cur:
                m = INSN.match(line)
                if m:
                    out[cur].append(m.group(1))
    return out


def main():
    a, b = sys.argv[1], sys.argv[2]
    want = lambda s: s.startswith("pmmb") or "matmul_b" in s
    A, B = funcs(a, want), funcs(b, want)
    print("symbols: %s has %d, %s has %d" % (a, len(A), b, len(B)))
    only_a, only_b = sorted(set(A) - set(B)), sorted(set(B) - set(A))
    if only_a:
        print("  ONLY IN %s: %s" % (a, only_a))
    if only_b:
        print("  ONLY IN %s: %s" % (b, only_b))
    bad = list(only_a) + list(only_b)
    for s in sorted(set(A) & set(B)):
        same = A[s] == B[s]
        print("  %-42s %5d insns  %s" % (s, len(A[s]), "IDENTICAL" if same else
                                         "**DIFFERS** (%d vs %d)" % (len(A[s]), len(B[s]))))
        if not same:
            bad.append(s)
    print()
    print("VERDICT: %s" % ("the compiled matmul_b_s8 is the same code in both images"
                           if not bad else "*** %d symbol(s) differ: %s ***" % (len(bad), bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
