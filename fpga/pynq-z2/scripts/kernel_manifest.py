#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""THE PER-OP KERNEL MANIFEST: which kernel every op resolved to, and one digest over the lot.

WHY.  On 2026-09-18 two decoder arms matched on `soc_magic`, on `bitstream_md5` AND on
`roccmoon_md5` -- and on their `kernel_cflags`, character for character -- and still differed in
a kernel worth 18 % of the decoder:

    b65_dec_flat    silu_s8 -> pext_memo_lut   369.27 cyc/el   steady 347,085,038
    b65b_dec_flat   silu_s8 -> pext_int_lut     47.20 cyc/el   steady 285,290,973

7.82x apart on one op, 53.4 M cycles, and the conclusion drafted off the pair -- "0x5A5A002E is
slower for the decoder" -- was about the silu kernel and not about the bitstream.  It took an
op-by-op diff of two archived runs to find, after the wrong conclusion had been written down.

    matched:    soc_magic . bitstream_md5 . roccmoon_md5 . kernel_cflags
    unmatched:  the kernel set the codegen actually selected

AND THE SELECTION MACHINERY WAS NOT AT FAULT.  scripts/58 asserts its own `silu_s8` pick in both
directions and BOTH ASSERTIONS PASSED: each arm was correctly confirmed to be the configuration
it asked for.  The wrong one was asked for, because `--silu-int` was opt-in.  An assertion
checks ONE arm against its own intent; nothing compared the two arms against EACH OTHER.  That
is the gap this file closes.

WHAT IT IS.  op -> kernel for every dispatched op, and a 12-hex digest over that mapping, so two
records can be compared at a glance instead of by diffing their `rows[]`.  scripts/57 and
scripts/58 record it in run.json (`models[*].kernel_manifest`, digest repeated at the top level
beside `roccmoon_md5`); this file derives the same mapping from ANY run record, including the
ones already in archive/runs/ that predate the field.

    kernel_manifest.py show <run.json>...              what each record selected
    kernel_manifest.py compare <a.json> <b.json>       REFUSES (exit 2) if they differ
    kernel_manifest.py compare --shared-only <a> <b>   only the ops both records have

TWO DIFFERENT COMPARISONS, AND USING THE WRONG ONE IS ITS OWN ERROR.

  * TWO ARMS OF ONE MODEL (an A/B).  The kernel set must be identical or the arms are not a
    controlled comparison.  Plain `compare` refuses any difference -- that is the b65/b65b case.
  * THE TWO HALVES OF ONE MODEL (encoder + decoder, as model_rtf_e2e.py composes them).  These
    are different graphs and a different kernel for a shared op is LEGITIMATE: the encoder's
    `layernorm_s8` runs 165x288 and wins on the lane, the decoder's runs 1x288 and does not.
    `--shared-only` still names every difference, but a caller composing two halves should
    RECORD the two manifests, not refuse on them.

THE RECORDED DIGEST IS RE-DERIVED, NEVER TRUSTED.  scripts/57 and scripts/58 carry their own
copy of the derivation (their report.py is written into the run directory and archived with it,
so it may not import from this tree).  Two copies drift.  Every mode here re-derives the mapping
from the record's own `rows[]` and refuses if the recorded digest disagrees with the derived one
-- which is the only way a reader finds out that the two implementations have parted.

Exit status: 0 all checks passed, 2 a refusal, 3 a usage error.
"""
import argparse, hashlib, json, os, sys


class Refuse(Exception):
    pass


def digest_of(mapping):
    """The digest scripts/57 and scripts/58 record.  Keep these three in step."""
    line = ";".join("%s=%s" % (op, mapping[op]) for op in sorted(mapping))
    return hashlib.md5(line.encode()).hexdigest()[:12]


def derive(model):
    """op -> kernel, from the record's own rows; per_kind only if there are no rows.

    rows[] carries the kernel per DISPATCH and is the authoritative record: per_kind keeps one
    kernel per op and would hide a graph whose dispatches of one op did not agree.  Such an op
    is recorded here as "a+b", which MOVES the digest instead of picking a winner.  An op with
    no pick is "-", so a reference -> curated change moves it too."""
    seen = {}
    for r in (model.get("rows") or []):
        if r.get("op"):
            seen.setdefault(r["op"], set()).add(r.get("kernel") or "-")
    src = "rows"
    if not seen:
        src = "per_kind"
        for op, k in (model.get("per_kind") or {}).items():
            if op:
                seen[op] = {(k or {}).get("kernel") or "-"}
    if not seen:
        return None
    m = {op: ("+".join(sorted(v)) if len(v) > 1 else sorted(v)[0]) for op, v in seen.items()}
    return {"ops": m, "n_ops": len(m), "digest": digest_of(m),
            "mixed": sorted(op for op, v in seen.items() if len(v) > 1), "source": src}


def models_of(path):
    """-> [(label, model dict)].  Both labs write {"models": {name: record}}."""
    d = json.load(open(path))
    ms = d.get("models")
    if isinstance(ms, dict) and ms:
        return [("%s[%s]" % (os.path.basename(os.path.dirname(os.path.abspath(path))), n), m)
                for n, m in sorted(ms.items())]
    return [(os.path.basename(path), d)]


def manifest_of(path, label, model):
    """The derived manifest, with the RECORDED one checked against it rather than trusted."""
    got = derive(model)
    if got is None:
        raise Refuse("%s: %s carries neither rows[] nor per_kind -- there is no record of "
                     "which kernel anything resolved to, so this record cannot be compared "
                     "with any other" % (label, path))
    rec = model.get("kernel_manifest")
    if isinstance(rec, dict) and rec.get("digest"):
        got["recorded_digest"] = rec["digest"]
        if rec["digest"] != got["digest"]:
            raise Refuse(
                "%s: the recorded kernel manifest digest %s does NOT match the digest %s "
                "derived from this record's own rows.\n"
                "       Either the record was edited after it was written, or the copy of the\n"
                "       derivation in its report.py has drifted from this file's.  A digest\n"
                "       nobody re-derives is a digest that can go quietly wrong."
                % (label, rec["digest"], got["digest"]))
        if rec.get("ops") and rec["ops"] != got["ops"]:
            raise Refuse("%s: the recorded manifest and the derived one hash alike and differ "
                         "in their op tables -- that cannot happen; treat this record as "
                         "corrupt" % label)
    else:
        got["recorded_digest"] = None
    return got


def show(paths):
    for p in paths:
        for label, m in models_of(p):
            man = manifest_of(p, label, m)
            print("%s  digest %s over %d ops  (from %s%s)"
                  % (label, man["digest"], man["n_ops"], man["source"],
                     ", recorded" if man["recorded_digest"] else ", NOT recorded in run.json"))
            for op in sorted(man["ops"]):
                print("    %-22s %s" % (op, man["ops"][op]))
            if man["mixed"]:
                print("    MIXED (dispatches of one op did not agree): %s"
                      % ", ".join(man["mixed"]))
    return 0


def compare(a, b, shared_only):
    ma, mb = models_of(a), models_of(b)
    if len(ma) != 1 or len(mb) != 1:
        raise Refuse("compare takes one model per record; got %d and %d" % (len(ma), len(mb)))
    (la, A), (lb, B) = ma[0], mb[0]
    X, Y = manifest_of(a, la, A), manifest_of(b, lb, B)
    print("  %-38s digest %s over %d ops" % (la, X["digest"], X["n_ops"]))
    print("  %-38s digest %s over %d ops" % (lb, Y["digest"], Y["n_ops"]))
    ops = (set(X["ops"]) & set(Y["ops"])) if shared_only else (set(X["ops"]) | set(Y["ops"]))
    diff = [(op, X["ops"].get(op, "(not in this record)"), Y["ops"].get(op, "(not in this record)"))
            for op in sorted(ops) if X["ops"].get(op) != Y["ops"].get(op)]
    if not diff:
        print("  the two records selected the SAME kernel for every%s op"
              % (" shared" if shared_only else ""))
        return 0
    lines = ["KERNEL MANIFEST REFUSES: these two records did not run the same kernels.",
             "       %s" % la, "       %s" % lb, ""]
    for op, x, y in diff:
        lines.append("       %-22s %-20s vs %-20s" % (op, x, y))
    lines += ["",
              "       This is the b65/b65b failure: soc_magic, bitstream_md5, roccmoon_md5 and",
              "       kernel_cflags all matched and silu_s8 still differed by 7.82x, which is",
              "       18 % of the decoder.  Two arms that do not run the same kernels are not",
              "       a controlled comparison, and the difference between them is not the",
              "       thing the A/B was set up to measure.",
              "       If these are the two HALVES of one model rather than two arms of one",
              "       half, --shared-only is still the wrong check: record both manifests."]
    sys.stdout.flush()          # so the refusal lands AFTER the two digests in a log
    raise Refuse("\n".join(lines))


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("show"); s.add_argument("runs", nargs="+")
    c = sub.add_parser("compare")
    c.add_argument("a"); c.add_argument("b")
    c.add_argument("--shared-only", action="store_true",
                   help="compare only the ops both records carry (two DIFFERENT graphs)")
    a = ap.parse_args(argv)
    if a.mode == "show":
        return show(a.runs)
    return compare(a.a, a.b, a.shared_only)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refuse as e:
        print(str(e) if str(e).startswith("KERNEL MANIFEST") else "KERNEL MANIFEST REFUSES: %s" % e,
              file=sys.stderr)
        sys.exit(2)
