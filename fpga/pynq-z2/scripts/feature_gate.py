#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""THE FEATURE GATE: refuse a lab that exercises hardware its bitstream does not contain.

WHY.  Twice this campaign has spent effort measuring a feature while running silicon that
lacks it.  `b30_lnab_on_run.json` dispatched LayerNorm to a lane on `0x5A5A0028`, which
MAGIC_REGISTRY.md describes as the thing `0x5A5A0029` is "plus the two lanes"; the attention
unit spent three board arms before one established that its bitstream could run a speech
image at all.  In both cases the run record faithfully named its `soc_magic` and its
`bitstream_md5`, and nothing checked that the MAGIC contained the feature being exercised.

FIVE DESIGN RULES, each learned from a specific failure:

 1. FAIL CLOSED.  An md5 with no row in MAGIC_FEATURES.tsv, or a MAGIC with no row in
    MAGIC_REGISTRY.md, has no determinable feature set, and a lab that cannot determine the
    feature set refuses.  Unknown is never permission.

 2. THE GATE IS NOT SATISFIABLE BY THE THING IT CHECKS.  The feature set is keyed on the
    md5 of the file the lab loads -- content, which a lab cannot assert about itself --
    never on `WANT_MAGIC`, which the lab sets.  The MAGIC the PL reads back is checked
    AGAINST the md5's row rather than used as the key.

 3. THE REQUIREMENT IS DERIVED FROM WHAT THE IMAGE WILL ACTUALLY DO, not from what the lab
    says it intends.  `kernel_picks.json` (before the run) and `per_kind[op].kernel` (after
    it) name the kernel selection actually made, and a kernel that issues `lgo` requires a
    lane whatever the lab believed.  This matters concretely: `roccmoon_lane` is registered
    for `layernorm_pc_s8` only, so a per-tensor candidate on the same MAGIC is perfectly
    safe -- the exposure is decided by SELECTION, not by the MAGIC or the candidate.

 4. A DEFINE WHOSE DEFAULT SELECTS HARDWARE IS PART OF THE REQUIREMENT.  `MBXR_LN_LANE`
    defaults to 1, so a build with the tree's default cflags dispatches to the lane; only
    `-DMBXR_LN_LANE=0` makes the arm lane-free.  The safe configuration must be requested
    and the dangerous one is free, which is the wrong polarity -- until it is inverted, the
    gate reads the cflags and treats the default as the requirement it is.

 6. A LEVER MUST BE CONNECTED TO SOMETHING.  Rule 4 reads the cflags and lets `-DX=0` compile
    a requirement away.  That is only true if some source the image compiles actually READS X.
    `MBXR_ATTN_LANE` appeared in this table and in NO .c or .h file in the tree, so
    `-DMBXR_ATTN_LANE=0` bought a pass from this gate and changed nothing about the image:
    b66_enc_gnl_off dispatched `attention_s8` to a lane 0x5A5A0028 does not have, armed a drain
    nothing fed, and every later mbxr_wait spun -- 2,200,229,029 cycles on six dispatches,
    7,716 cycles/element, last_rc -4, calls_fallback 33.  The run audit caught it afterwards
    (rule 5 earning its keep), but the gate had already said yes.  A GATE WHOSE LEVER IS
    CONNECTED TO NOTHING IS WORSE THAN NO GATE, BECAUSE IT IS TRUSTED.  So: before an off-claim
    may drop a requirement, this file resolves the kernel the pick compiles to, walks its
    includes, and REFUSES if the define is not read there; and any `-DMBXR_*LANE` in the cflags
    that no source in the tree reads is a refusal on its own, with no selection needed.  What
    the gate can honestly check is "selection resolved to a lane kernel and nothing in its
    sources removes it", and that is now what it checks.

 5. THE SYMPTOM IS CHECKED INDEPENDENTLY OF ANY DECLARATION.  A lab can forget to declare;
    it cannot forget to be slow.  `last_rc = MBXR_E_TIMEOUT` with a non-zero
    `calls_fallback`, `cyc_busy` an order of magnitude above the engine work that was
    actually measured, and a poll count at the budget are each a stuck engine, and each one
    would have caught b30_lnab_on on its own with nothing declared anywhere.

MODES

  feature_gate.py features <md5|magic>            what a build contains
  feature_gate.py gate --md5 M --magic X --requires "a b" [--picks p.json] [--cflags "..."]
                                                  refuse BEFORE dispatching
  feature_gate.py audit <run.json>...             replay a finished record through the gate

Exit status is 0 only if every check passed; 2 is a refusal, 3 a usage error.
"""
import argparse, json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
TSV = os.path.join(ROOT, "fpga", "pynq-z2", "MAGIC_FEATURES.tsv")
REGISTRY = os.path.join(ROOT, "fpga", "pynq-z2", "MAGIC_REGISTRY.md")

MBXR_E_TIMEOUT = -4
# mbxr_rt.h's MBXR_RT_LANE_POLLS.  A run that reaches it did not complete; it gave up.
DEFAULT_POLL_BUDGET = 20000000
# how far cyc_busy may exceed the engine work the counters actually measured before the
# engine is called stuck rather than slow.  The live reproduction sat at 21x.
BUSY_SLACK = 10.0

# ---------------------------------------------------------------------------------------
# (op, selected algorithm) -> the feature that selection requires, and the define that can
# compile the requirement away.  A `roccmoon_lane` pick for an op that is NOT in this table
# is a REFUSAL, not a pass: a new lane kernel must be priced here before it can run.
# ---------------------------------------------------------------------------------------
KERNEL_FEATURE = {
    ("layernorm_pc_s8", "roccmoon_lane"): ("ln_lane", "MBXR_LN_LANE", 1),
    # the per-tensor form of the same op on the same lane: QATU emits layernorm_s8 where
    # candidate R emits layernorm_pc_s8, and the kernel differs only in deriving the
    # affine table from floats.  Priced here BEFORE the candidate was registered, because
    # an unpriced lane pick is a refusal in this file by design -- which is exactly what
    # refused the LUT lane's first board arm.
    ("layernorm_s8", "roccmoon_lane"): ("ln_lane", "MBXR_LN_LANE", 1),
    # NO SWITCH, and that is the correction.  This entry named `MBXR_ATTN_LANE`, which no
    # source in this tree has ever read: roccmoon_attention_s8_roccmoon_lane.c guards its
    # dispatch with `#ifdef __ZEPHYR__` and a runtime mbxr_rt_available(), and nothing else.
    # An attention_s8 pick on this kernel therefore requires the lane ALWAYS -- there is no
    # cflag that makes the arm lane-free, and a table that claimed there was sold a pass.
    ("attention_s8", "roccmoon_lane"): ("attn_lane", None, None),
    ("gelu_s8", "roccmoon_lut"): ("lut_lane", "MBXR_LUT_LANE", 1),
    ("silu_s8", "roccmoon_lut"): ("lut_lane", "MBXR_LUT_LANE", 1),
    ("tanh_s8", "roccmoon_lut"): ("lut_lane", "MBXR_LUT_LANE", 1),
    # cat2_c1_s8's lane kernel (Lab B44).  Registered here because this table is where a lane
    # kernel declares the silicon it needs, and it refused this kernel's first board arm --
    # the third time today this gate caught a lane kernel that had not declared itself.
    ("cat2_c1_s8", "roccmoon_lut"): ("lut_lane", "MBXR_LUT_LANE", 1),
}
# algorithm -> feature, for kernels whose requirement does not depend on the op
ALGO_FEATURE = {
    "roccmoon_engine": ("rocc_engine", None, None),
}
LANE_ALGOS = ("roccmoon_lane", "roccmoon_lut")
# a cflag that, on its own, requires silicon.  (define, feature, value that means "off")
#
# MBXR_RT_DRAIN_STRIDED is here because its failure mode is SILENCE.  mbxr_rt_pick() reads
# the engine's id word and falls back to the flat drain on a build without the 2-D
# descriptor -- correct behaviour, and indistinguishable in a run record from the control
# arm of the very A/B the flag exists to run.  A measurement that quietly measured nothing
# is the failure this file was created to stop, so the gate refuses it up front.
CFLAG_FEATURE = [("MB_PEXT_HW", "pext", 0),
                 ("MBXR_RT_DRAIN_STRIDED", "drain_2d", 0)]


KERNELS = os.path.join(ROOT, "fpga", "pynq-z2", "modelblaster", "kernels")
SW = os.path.join(ROOT, "fpga", "pynq-z2", "sw")
# a define whose NAME says "lane switch".  Any of these that no source reads is a refusal even
# with no selection in hand, which is what makes this check work at gate time.
LANE_SWITCH = re.compile(r"^MBXR_[A-Z0-9_]*LANE$")
_COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
_TREE = []


def fail(msg):
    print(msg, file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------------------
# IS THE LEVER CONNECTED?  The one question rule 4 never asked.
# ---------------------------------------------------------------------------------------
def _reads(name, paths):
    """The first file in `paths` that READS `name` -- or None.

    Comments are stripped, because a define named only in a comment is not a switch; and the
    define's OWN default guard (`#ifndef X` / `#define X 1`) is removed, because that is a
    definition, not a use.  A header that sets a default and never tests it is exactly as
    disconnected as a name that appears nowhere."""
    pat = re.compile(r"\b%s\b" % re.escape(name))
    guard = re.compile(r"^[ \t]*#[ \t]*(?:ifndef|define)[ \t]+%s\b.*$" % re.escape(name), re.M)
    for p in paths:
        try:
            txt = open(p, errors="replace").read()
        except OSError:
            continue
        if pat.search(guard.sub("", _COMMENT.sub(" ", txt))):
            return p
    return None


def tree_sources():
    """Every .c/.h a lab's image can compile from this tree.  Cached."""
    if _TREE:
        return _TREE
    for base in (KERNELS, SW):
        for d, _, names in os.walk(base):
            for n in sorted(names):
                if n.endswith((".c", ".h")):
                    _TREE.append(os.path.join(d, n))
    return _TREE


def kernel_sources(op, algo):
    """The .c ModelBlaster compiles for this (op, algorithm) pick.

    The curated tree names kernels `<family>/<family>_<op>_<algorithm>.c`, which is the same
    convention the codegen's discovery uses -- so if this finds nothing, the pick does not name
    a kernel in this tree and nothing can be verified about it."""
    if not (op and algo) or not os.path.isdir(KERNELS):
        return []
    want = "_%s_%s.c" % (op, algo)
    hits = []
    for d, _, names in os.walk(KERNELS):
        for n in sorted(names):
            if n.endswith(want):
                hits.append(os.path.join(d, n))
    return hits


def translation_unit(path, seen=None, depth=0):
    """`path` plus every in-tree header it includes, transitively.

    `MBXR_LN_LANE` is not read by roccmoon_layernorm_pc_s8_roccmoon_lane.c at all -- it is read
    by roccmoon/mbxr_ln_driver.h, which that kernel includes.  A check that looked only at the
    kernel file would call a connected lever phantom, which is the same class of wrong."""
    if seen is None:
        seen = set()
    if depth > 6 or not path or path in seen or not os.path.isfile(path):
        return seen
    seen.add(path)
    try:
        txt = open(path, errors="replace").read()
    except OSError:
        return seen
    here = os.path.dirname(path)
    for inc in re.findall(r'^\s*#\s*include\s+"([^"]+)"', txt, re.M):
        for base in (here, SW, KERNELS):
            cand = os.path.join(base, inc)
            if os.path.isfile(cand):
                translation_unit(cand, seen, depth + 1)
                break
    return seen


def lever_check(op, algo, switch):
    """None if `-D<switch>=0` really does compile this pick away; else WHY it does not."""
    srcs = kernel_sources(op, algo)
    if not srcs:
        return ("no kernel named %s_%s.c exists under fpga/pynq-z2/modelblaster/kernels/, so "
                "there is no source in which -D%s=0 could remove anything"
                % (op, algo, switch))
    tu = set()
    for s in srcs:
        translation_unit(s, tu)
    if _reads(switch, sorted(tu)) is None:
        return ("%s is not read by %s or by any header it includes (%d files), so -D%s=0 "
                "changes NOTHING about what this image dispatches to"
                % (switch, os.path.basename(srcs[0]), len(tu), switch))
    return None


def phantom_switches(defs):
    """-D names shaped like a lane switch that NO source in this tree reads.

    This half needs no selection and no picks file, so it holds at gate time before codegen has
    said anything -- which is where b66_enc_gnl_off would have been stopped."""
    return [n for n in sorted(defs) if LANE_SWITCH.match(n) and _reads(n, tree_sources()) is None]


def load_tsv(path=TSV):
    rows = {}
    if not os.path.exists(path):
        fail("feature gate: no %s -- the feature set of every build is undeterminable" % path)
    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 4:
            fail("feature gate: malformed row in %s: %r" % (path, line[:80]))
        rows[f[0].strip().lower()] = {
            "md5": f[0].strip().lower(), "magic": f[1].strip(), "variant": f[2].strip(),
            "features": [x for x in f[3].strip().split(",") if x],
            "note": (f[4].strip() if len(f) > 4 else ""),
        }
    return rows


def registry_magics(path=REGISTRY):
    """Every MAGIC CLAIMED in MAGIC_REGISTRY.md's tables.  A MAGIC absent from this set is
    unregistered, and an unregistered MAGIC is how 0x5A5A000E was taken twice."""
    if not os.path.exists(path):
        fail("feature gate: no %s -- cannot tell a registered MAGIC from an invented one" % path)
    txt = open(path, errors="replace").read()
    return set(m.upper() for m in re.findall(r"^\|\s*`(0x5A5A[0-9A-Fa-f]{4})`\s*\|", txt, re.M))


def defines(cflags):
    """-DFOO=1 / -DFOO -> {"FOO": "1"}.  The last spelling wins, as the compiler has it."""
    out = {}
    for m in re.finditer(r"-D([A-Za-z_][A-Za-z0-9_]*)(?:=(\S+))?", cflags or ""):
        out[m.group(1)] = m.group(2) if m.group(2) is not None else "1"
    return out


def define_on(defs, name, default):
    v = defs.get(name)
    if v is None:
        return default != 0
    try:
        return int(v, 0) != 0
    except ValueError:
        return True


def implied_from_selection(selection, cflags):
    """selection: [(op, algorithm), ...] -> (required features, notes, refusals)."""
    defs = defines(cflags)
    need, why, bad = set(), [], []
    for op, algo in selection:
        if not algo or algo == "reference":
            continue
        ent = KERNEL_FEATURE.get((op, algo)) or ALGO_FEATURE.get(algo)
        if ent is None:
            if algo in LANE_ALGOS:
                bad.append("%s selected %r, which is not priced in feature_gate.py's "
                           "KERNEL_FEATURE table -- a lane kernel must declare the lane it "
                           "needs before it may run" % (op, algo))
            continue
        feat, switch, dflt = ent
        if switch and not define_on(defs, switch, dflt):
            # THE OFF-CLAIM IS THE ONLY PATH THAT DROPS A REQUIREMENT, so it is the only one
            # that has to be earned.  Leaving the requirement in place would be the safe
            # direction but the wrong answer: an operator who believes they built a lane-free
            # control arm and did not has two arms wrong in the same way, on a lane-bearing
            # MAGIC where nothing else would ever notice.
            broken = lever_check(op, algo, switch)
            if broken:
                bad.append("%s selected %r and the arm claims -D%s=0 compiles it away, but "
                           "%s.  THE DEFINE IS NOT A SWITCH: passing it buys a pass from this "
                           "gate and changes nothing about the image." % (op, algo, switch, broken))
                continue
            why.append("%-18s %-16s -> %s NOT required (-D%s=0 compiles it to the fallback)"
                       % (op, algo, feat, switch))
            continue
        need.add(feat)
        why.append("%-18s %-16s -> requires %s%s"
                   % (op, algo, feat,
                      "" if not switch else "  (-D%s defaults to %d)" % (switch, dflt)))
    for n in phantom_switches(defs):
        bad.append("-D%s is passed to this build and NO source in this tree reads it.  A "
                   "define shaped like a lane switch that nothing reads is not a switch: it "
                   "is a name that makes a lane-free arm look requested while the image still "
                   "dispatches to the lane.  Remove it, or make the kernel read it." % n)
    for define, feat, off in CFLAG_FEATURE:
        if define in defs and define_on(defs, define, off):
            need.add(feat)
            why.append("%-18s %-16s -> requires %s" % ("(cflags)", "-D%s" % define, feat))
    return need, why, bad


def selection_from_picks(paths):
    sel = []
    for p in paths:
        d = json.load(open(p))
        for op, v in (d.get("picks") or {}).items():
            sel.append((op, v.get("algorithm")))
    return sel


def lookup(rows, md5, magic, where):
    """The one place a feature set is resolved.  Fails closed, every path."""
    if not md5 or md5 == "not-loaded":
        fail("FEATURE GATE REFUSES %s: no bitstream md5.\n"
             "       This run did not load a bitstream, so what is in the PL is unknown and\n"
             "       so is its feature set.  A lab that cannot determine the feature set\n"
             "       refuses: declare LAB_REQUIRES=none and load nothing, or load a build."
             % where)
    row = rows.get(md5.lower())
    if row is None:
        fail("FEATURE GATE REFUSES %s: bitstream md5 %s has no row in\n"
             "       fpga/pynq-z2/MAGIC_FEATURES.tsv, so NOTHING is known about what it\n"
             "       contains.  Unknown is not permission.  If this is a real build, add a\n"
             "       row from its MAGIC_REGISTRY.md entry -- from the registry, not from what\n"
             "       the lab wishes were true -- and say what silicon is in it." % (where, md5))
    known = registry_magics()
    if row["magic"].upper() not in known:
        fail("FEATURE GATE REFUSES %s: md5 %s claims MAGIC %s, which is NOT claimed in\n"
             "       MAGIC_REGISTRY.md.  An unregistered MAGIC is how 0x5A5A000E was taken\n"
             "       twice; register it there first." % (where, md5[:10], row["magic"]))
    if magic and magic.upper() != row["magic"].upper():
        fail("FEATURE GATE REFUSES %s: the bitstream md5 %s is registered as %s, but this\n"
             "       run says %s.  The md5 is the content and the MAGIC is a label; when they\n"
             "       disagree the label is wrong, and every number taken under it is filed\n"
             "       against the wrong machine." % (where, md5[:10], row["magic"], magic))
    return row


def check(rows, md5, magic, requires, selection, cflags, where):
    """Returns the record of what was checked; raises SystemExit(2) on a refusal."""
    row = lookup(rows, md5, magic, where)
    have = set(row["features"])
    if requires is None:
        fail("FEATURE GATE REFUSES %s: no feature declaration.\n"
             "       Every lab must say which hardware features it requires -- LAB_REQUIRES,\n"
             "       or the run record's \"requires\" field.  Declare `none` if it genuinely\n"
             "       requires none; an omitted declaration is a refusal, because a\n"
             "       declaration a lab can omit is one it will omit." % where)
    declared = set(x for x in requires if x and x != "none")
    need, why, bad = implied_from_selection(selection, cflags)
    if bad:
        fail("FEATURE GATE REFUSES %s:\n       " % where + "\n       ".join(bad))
    missing_declared = sorted(declared - have)
    missing_implied = sorted(need - have)
    if missing_declared or missing_implied:
        providers = {}
        for f in set(missing_declared + missing_implied):
            providers[f] = sorted(set("%s (%s)" % (r["magic"], r["variant"])
                                      for r in rows.values() if f in r["features"]))
        lines = ["FEATURE GATE REFUSES %s" % where,
                 "       bitstream %s = %s (%s)" % (md5[:10], row["magic"], row["variant"]),
                 "       it contains: %s" % (", ".join(sorted(have)) or "(nothing)"),
                 "       %s" % row["note"]]
        if missing_implied:
            lines.append("")
            lines.append("       THE IMAGE WOULD DISPATCH TO HARDWARE THAT IS NOT THERE:")
            for f in missing_implied:
                lines.append("         missing %-10s provided by: %s"
                             % (f, ", ".join(providers[f]) or "no registered build"))
            lines.append("       because kernel selection chose:")
            for w in why:
                lines.append("         %s" % w)
        if missing_declared:
            lines.append("")
            lines.append("       DECLARED BUT NOT PRESENT: %s" % ", ".join(missing_declared))
            for f in missing_declared:
                lines.append("         %-10s provided by: %s"
                             % (f, ", ".join(providers[f]) or "no registered build"))
        lines.append("")
        lines.append("       This is the b30_lnab_on failure: a run that names its soc_magic")
        lines.append("       and its bitstream_md5 and then exercises whatever it likes.  Load")
        lines.append("       a build that contains the feature, or build the arm without it.")
        fail("\n".join(lines))
    return {"md5": md5, "magic": row["magic"], "variant": row["variant"],
            "provides": sorted(have), "declared": sorted(declared),
            "implied_by_selection": sorted(need), "selection_notes": why,
            "verdict": "pass"}


# ---------------------------------------------------------------------------------------
# the symptom checks: true or false without any declaration anywhere
# ---------------------------------------------------------------------------------------
def symptoms(engine, cflags, where):
    out, applied = [], []
    if not engine:
        return out, applied
    rc = engine.get("last_rc")
    fb = engine.get("calls_fallback")
    if rc is not None and fb is not None:
        applied.append("timeout+fallback")
        if rc == MBXR_E_TIMEOUT and fb:
            out.append("%s: last_rc = %d (MBXR_E_TIMEOUT) with calls_fallback = %d.  An arm "
                       "that is supposed to be exercising hardware timed out and fell back; "
                       "its cycle counts are the cost of giving up, not of computing."
                       % (where, rc, fb))
    busy, fill, tseq = engine.get("cyc_busy"), engine.get("cyc_fill"), engine.get("cyc_tseq")
    if busy is not None and fill is not None and tseq is not None:
        applied.append("cyc_busy vs work")
        work = fill + tseq
        if work >= 0 and busy > BUSY_SLACK * max(work, 1):
            out.append("%s: cyc_busy %s is %.1fx the engine work the counters measured "
                       "(cyc_fill %s + cyc_tseq %s).  busy is STUCK, not slow: one armed and "
                       "unfed drain makes every later mbxr_wait spin to its limit, and the "
                       "contamination is not confined to the op under test."
                       % (where, format(busy, ","), busy / float(max(work, 1)),
                          format(fill, ","), format(tseq, ",")))
    polls = engine.get("polls")
    budget = int(defines(cflags).get("MBXR_RT_LANE_POLLS", DEFAULT_POLL_BUDGET))
    if polls is not None:
        applied.append("poll budget")
        if polls >= budget:
            out.append("%s: %d polls against a %d budget -- the loop did not exit, it gave up."
                       % (where, polls, budget))
    return out, applied


def is_board_record(m):
    """A board dispatch record says at least one of: which silicon, or what the engine did.
    A host-side gate record (no MAGIC, no md5, no engine, no per-kind table) is not one, and
    there is nothing in it to gate.  Anything that names ONE of them and omits the md5 IS a
    board record with a hole in it, and that is a refusal -- see b30_lmhead_split_run.json,
    which names 0x5A5A0028 and never records what was loaded."""
    return any(m.get(k) for k in ("soc_magic", "bitstream_md5", "engine", "per_kind"))


def audit_model(rows, name, m, path, strict_requires):
    where = "%s [%s]" % (os.path.basename(path), name)
    if not is_board_record(m):
        return {"md5": "-", "magic": "-", "variant": "not a board dispatch record",
                "provides": [], "declared": [], "implied_by_selection": [],
                "selection_notes": [], "symptoms_applied": [], "symptoms_failed": [],
                "verdict": "skip"}
    cflags = m.get("kernel_cflags") or ""
    # SELECTION FROM rows[] AS WELL AS per_kind.  per_kind keeps ONE kernel per op; rows carry
    # the kernel per DISPATCH.  If a single dispatch of an op resolved to a lane kernel and the
    # summary named another, only the rows say so -- and one dispatch to absent silicon is
    # enough to arm an unfed drain and poison every later wait.
    sel = set()
    for op, v in (m.get("per_kind") or {}).items():
        sel.add((op, (v or {}).get("kernel")))
    for r in (m.get("rows") or []):
        if isinstance(r, dict) and r.get("op"):
            sel.add((r["op"], r.get("kernel")))
    sel = sorted(sel, key=lambda t: (str(t[0]), str(t[1])))
    req = m.get("requires")
    if req is None:
        req = [] if not strict_requires else None
    elif isinstance(req, str):
        req = req.split()
    rec = check(rows, (m.get("bitstream_md5") or ""), m.get("soc_magic"), req, sel, cflags, where)
    bad, applied = symptoms(m.get("engine") or {}, cflags, where)
    rec["symptoms_applied"] = applied
    rec["symptoms_failed"] = bad
    if bad:
        fail("RUN HEALTH REFUSES:\n       " + "\n       ".join(bad))
    return rec



# ---------------------------------------------------------------------------------------
# THE GATE'S OWN PROOF.  "A gate that cannot reject b30_lnab_on is not a gate" -- so the
# rejection is an assertion here rather than something somebody ran once.  Every case names
# the failure it stands for, and half of them are PASSES: a gate that refuses everything
# discriminates nothing, and the b30 pair differ in one define on one bitstream.
# ---------------------------------------------------------------------------------------
BOARD = os.path.join(ROOT, "fpga", "pynq-z2", "modelblaster", "moonshine", "board")
MD5_0028 = "32d10e5d47a4ca1f120f6f6d34e04b4e"
MD5_002A = "1e8ea02d47dc9c2c7590a879de6c1d77"


def _run(argv):
    """-> (exit status, combined output)."""
    import io, contextlib
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            rc = main(argv)
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 1
    return rc, buf.getvalue()


def _tmp(obj):
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f)
    return path


def selftest():
    cases, bad = [], []

    def want(name, argv, expect_rc, must_say=None):
        rc, out = _run(argv)
        ok = (rc == expect_rc) and (must_say is None or must_say in out)
        cases.append((ok, name, rc, out))
        if not ok:
            bad.append("%s: exit %d (wanted %d)%s" % (name, rc, expect_rc,
                       "" if must_say is None or must_say in out
                       else "; output does not mention %r" % must_say))

    on = os.path.join(BOARD, "b30_lnab_on_run.json")
    off = os.path.join(BOARD, "b30_lnab_off_run.json")
    base = os.path.join(BOARD, "b30_q16r_run.json")
    qatu = os.path.join(BOARD, "b34_qatu_lnhoist_run.json")

    # 1. THE CASE THE GATE EXISTS FOR.
    want("b30_lnab_on REFUSED (dispatched a lane on 0x5A5A0028)",
         ["audit", on], 2, "missing ln_lane")
    # 2. and its own control PASSES -- one define apart, same bitstream, same lab.
    want("b30_lnab_off PASSES (-DMBXR_LN_LANE=0 on the same silicon)", ["audit", off], 0)
    # 3. THE LATENT/LIVE PAIR: same candidate, same cflags, selection resolved differently.
    #    Only a gate keyed on SELECTION can tell these two apart.
    want("b30_q16r PASSES (same cflags, selection chose reference)", ["audit", base], 0)
    # 4. the QATU family, which the lane kernel never serves, must not be caught.
    want("b34_qatu_lnhoist PASSES (per-tensor layernorm_s8, never reaches the lane)",
         ["audit", qatu], 0)
    # 5. THE SYMPTOM CHECK, ALONE.  Relabel the bad run onto silicon that HAS the lane: the
    #    feature check now has nothing to say and the run must still be refused.
    d = json.load(open(on))
    d["models"]["enc_q16"]["soc_magic"] = "0x5A5A002A"
    d["models"]["enc_q16"]["bitstream_md5"] = MD5_002A
    want("relabelled onto a lane-bearing MAGIC: still REFUSED by the symptom check alone",
         ["audit", _tmp(d)], 2, "MBXR_E_TIMEOUT")
    # 6. a stuck engine, by the counters alone, with no timeout and no fallbacks
    stuck = {"soc_magic": "0x5A5A002A", "bitstream_md5": MD5_002A, "kernel_cflags": "",
             "engine": {"last_rc": 0, "calls_fallback": 0, "cyc_busy": 1573899818,
                        "cyc_fill": 9963280, "cyc_tseq": 64768064}, "requires": "none"}
    want("cyc_busy 21x the measured engine work: REFUSED as stuck, not slow",
         ["audit", _tmp({"models": {"m": stuck}})], 2, "STUCK")
    # 7. ...and a HEALTHY engine is not caught by it.  The measured healthy run sits ~7 %
    #    BELOW cyc_fill + cyc_tseq because busy is a four-term union; the threshold is 10x,
    #    an order of magnitude clear of that band, and it detects a hang and nothing finer.
    healthy = dict(stuck)
    healthy["engine"] = {"last_rc": 0, "calls_fallback": 0, "cyc_busy": 69371000,
                         "cyc_fill": 9963280, "cyc_tseq": 64768064}
    want("a healthy engine at 0.93x the sum: PASSES",
         ["audit", _tmp({"models": {"m": healthy}})], 0)
    # 8. FAIL CLOSED: an unregistered build says nothing about itself.
    want("an unknown md5 is REFUSED, not assumed",
         ["gate", "--md5", "deadbeef" * 4, "--requires", "none"], 2, "no row in")
    # 9. FAIL CLOSED: the label disagrees with the content.
    want("md5 registered as 0x5A5A0028 but run says 0x5A5A0029: REFUSED",
         ["gate", "--md5", MD5_0028, "--magic", "0x5A5A0029", "--requires", "none"], 2,
         "the label is wrong")
    # 10. FAIL CLOSED: no declaration at all.
    want("an omitted declaration is REFUSED",
         ["gate", "--md5", MD5_002A, "--magic", "0x5A5A002A"], 2, "no feature declaration")
    # 11. FAIL CLOSED: nothing was loaded, so nothing is known.
    want("--no-bitstream is REFUSED (the silicon is unidentified)",
         ["gate", "--md5", "not-loaded", "--requires", "rocc_engine"], 2, "no bitstream md5")
    # 12. FAIL CLOSED: a lane kernel nobody has priced here cannot slip through.
    picks = _tmp({"picks": {"newop_s8": {"algorithm": "roccmoon_lane", "source": "curated"}}})
    want("an unpriced roccmoon_lane pick is REFUSED",
         ["gate", "--md5", MD5_002A, "--magic", "0x5A5A002A", "--requires", "none",
          "--picks", picks], 2, "not priced")
    # 13. the declaration path on its own, with no selection at all
    want("declaring attn_lane on 0x5A5A0028 is REFUSED",
         ["gate", "--md5", MD5_0028, "--magic", "0x5A5A0028", "--requires", "attn_lane"], 2,
         "DECLARED BUT NOT PRESENT")
    # 14. -DMB_PEXT_HW=1 on the lane-development config, which has no P-extension
    want("a P-extension image on 0x5A5A002B is REFUSED",
         ["gate", "--md5", "6145f18bd6b393c4b7db96dc3d5d9dcf", "--magic", "0x5A5A002B",
          "--requires", "none", "--cflags=-DMB_PEXT_HW=1"], 2, "missing pext")
    # 15/16. THE 2-D DRAIN, whose failure mode is silence.  An image built
    # -DMBXR_RT_DRAIN_STRIDED=1 on 0x5A5A002D falls back to the flat drain at run time and
    # produces a record indistinguishable from the control arm.  Refused on 002D, allowed on
    # 002E -- and the second half matters as much as the first: a gate that refuses everything
    # is not a gate.
    want("-DMBXR_RT_DRAIN_STRIDED=1 on 0x5A5A002D is REFUSED (it would silently fall back)",
         ["gate", "--md5", "1bae0310c1e13048b22b4da9c72901ab", "--magic", "0x5A5A002D",
          "--requires", "none", "--cflags=-DMBXR_RT_DRAIN_STRIDED=1"], 2, "missing drain_2d")
    want("-DMBXR_RT_DRAIN_STRIDED=1 on 0x5A5A002E PASSES",
         ["gate", "--md5", "d6112edd73503fd74ca4cab3cbd47492", "--magic", "0x5A5A002E",
          "--requires", "rocc_engine", "--cflags=-DMBXR_RT_DRAIN_STRIDED=1"], 0)

    # 17. THE PHANTOM LEVER, at gate time -- the case this file's rule 6 was written for.
    #     b66_enc_gnl_off passed THIS EXACT CHECK and then spent 2.2 billion cycles in
    #     attention_s8 on a bitstream with no attn_lane.
    attn = _tmp({"picks": {"attention_s8": {"algorithm": "roccmoon_lane", "source": "curated"}}})
    want("-DMBXR_ATTN_LANE=0 no longer buys a pass (b66_enc_gnl_off, pre-dispatch)",
         ["gate", "--md5", MD5_0028, "--magic", "0x5A5A0028", "--requires", "rocc_engine pext",
          "--picks", attn, "--cflags=-DMB_PEXT_HW=1 -DMBXR_ATTN_LANE=0"], 2, "MBXR_ATTN_LANE")
    # 18. THE SAME ARM, REPLAYED FROM ITS OWN RECORD, with the symptoms REMOVED.  Rule 5 caught
    #     this run afterwards; the point of the fix is that the FEATURE check catches it too, so
    #     the two are independent rather than one standing in for the other.
    b66 = os.path.join(BOARD, "b66_enc_gnl_off_run.json")
    if os.path.exists(b66):
        d66 = json.load(open(b66))
        for _m in d66["models"].values():
            _m.pop("engine", None)
        want("b66_enc_gnl_off REFUSED by the FEATURE check alone (engine counters removed)",
             ["audit", _tmp(d66)], 2, "MBXR_ATTN_LANE")
        # ...and it cannot escape by dropping the phantom define either.  The entry carries NO
        # switch now, so an attention_s8 lane pick requires the lane unconditionally -- which is
        # the true statement about a kernel with no compile-time off path.
        for _m in d66["models"].values():
            _m["kernel_cflags"] = (_m.get("kernel_cflags") or "").replace(
                "-DMBXR_ATTN_LANE=0", "").strip()
        want("...and with the phantom define removed it is REFUSED for the lane itself",
             ["audit", _tmp(d66)], 2, "missing attn_lane")
        want("b66_enc_gnl_off REFUSED as recorded, symptoms and all",
             ["audit", b66], 2)
    # 19. NO SELECTION AT ALL, and on silicon that HAS the lane.  A phantom switch is wrong
    #     even where the feature is present: the arm believes it built a lane-free control and
    #     did not, which is two arms wrong in the same way and nothing else would notice.
    want("a lane switch no source reads is REFUSED with no picks and a lane-bearing MAGIC",
         ["gate", "--md5", MD5_002A, "--magic", "0x5A5A002A", "--requires", "none",
          "--cflags=-DMBXR_ATTN_LANE=0"], 2, "NO source in this tree reads it")
    # 20. AND THE CONNECTED LEVER STILL WORKS.  A gate that refuses every off-claim has just
    #     moved the failure: mbxr_ln_driver.h really does read MBXR_LN_LANE, so this pick with
    #     the lane compiled out is lane-free on 0x5A5A0028 and must PASS.
    lnp = _tmp({"picks": {"layernorm_pc_s8": {"algorithm": "roccmoon_lane",
                                              "source": "curated"}}})
    want("-DMBXR_LN_LANE=0 with a lane pick still PASSES on 0x5A5A0028 (the lever is real)",
         ["gate", "--md5", MD5_0028, "--magic", "0x5A5A0028", "--requires", "none",
          "--picks", lnp, "--cflags=-DMBXR_LN_LANE=0"], 0)
    # 21. ...and the same pick WITHOUT the off-claim is still refused, so case 20 is measuring
    #     the define and not some other difference.
    want("the same pick with no off-claim is REFUSED on 0x5A5A0028",
         ["gate", "--md5", MD5_0028, "--magic", "0x5A5A0028", "--requires", "none",
          "--picks", lnp], 2, "missing ln_lane")

    # ---------------------------------------------------------------------------------------
    # THE TABLE AUDIT.  Every lever this file names must be connected TODAY, not on the day it
    # was written.  MBXR_ATTN_LANE was in the table for as long as the table existed and no
    # test would have noticed, because nothing checked the table against the tree.  This runs
    # in every build's gate, so a rename in the kernels surfaces here rather than in a run.
    # ---------------------------------------------------------------------------------------
    disconnected, unbuilt = [], []
    for (op, algo), (feat, switch, dflt) in sorted(KERNEL_FEATURE.items()):
        if not kernel_sources(op, algo):
            # PRICED AHEAD OF THE KERNEL, which this file does on purpose -- the cat2 and
            # per-tensor layernorm entries were both written before their kernels existed,
            # because an unpriced lane pick is a refusal here by design.  Not a failure, but
            # named: a row nobody can reach is also how a stale row survives a rename.
            unbuilt.append("%s/%s" % (op, algo))
        elif switch:
            broken = lever_check(op, algo, switch)
            if broken:
                disconnected.append("KERNEL_FEATURE[%s, %s] lever %s: %s"
                                    % (op, algo, switch, broken))
    for define, feat, off in CFLAG_FEATURE:
        if _reads(define, tree_sources()) is None:
            disconnected.append("CFLAG_FEATURE %s -> %s is read by no source in this tree, so "
                                "this file requires %s on the strength of a name nothing uses"
                                % (define, feat, feat))
    cases.append((not disconnected, "every lever in this file's tables is connected to a source",
                  0, ""))
    if disconnected:
        bad.append("disconnected levers: " + "; ".join(disconnected))
    if unbuilt:
        print("   note  priced here but no kernel file in the tree yet (a pick for one would be "
              "refused as unpriced, not silently allowed): %s" % ", ".join(unbuilt))

    for ok, name, rc, out in cases:
        print("   %-4s %s" % ("ok" if ok else "FAIL", name))
    print("   %d of %d cases as specified" % (sum(1 for c in cases if c[0]), len(cases)))
    if bad:
        for b in bad:
            print("   FAILED: %s" % b, file=sys.stderr)
        return 1
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    sub.add_parser("selftest")
    f = sub.add_parser("features"); f.add_argument("key")
    g = sub.add_parser("gate")
    g.add_argument("--md5", required=True)
    g.add_argument("--magic", default="")
    g.add_argument("--requires", default=None,
                   help="space-separated features, or 'none'.  OMITTING IT IS A REFUSAL.")
    g.add_argument("--picks", action="append", default=[])
    g.add_argument("--cflags", default="")
    g.add_argument("--where", default="this lab")
    g.add_argument("--emit-json", default="")
    a = sub.add_parser("audit")
    a.add_argument("runs", nargs="+")
    a.add_argument("--strict-requires", action="store_true",
                   help="also refuse a record that carries no \"requires\" field")
    a.add_argument("--emit-json", default="")
    args = ap.parse_args(argv)
    if args.mode == "selftest":
        return selftest()
    rows = load_tsv()

    if args.mode == "features":
        k = args.key.lower()
        hits = [r for r in rows.values() if r["md5"].startswith(k) or r["magic"].lower() == k]
        if not hits:
            fail("no build matches %r -- unknown, which is a refusal, not a pass" % args.key)
        for r in sorted(hits, key=lambda r: r["magic"]):
            print("%s  %s  %-15s %s" % (r["md5"][:10], r["magic"], r["variant"],
                                        ",".join(r["features"])))
            if r["note"]:
                print("            %s" % r["note"])
        return 0

    if args.mode == "gate":
        sel = selection_from_picks(args.picks)
        req = None if args.requires is None else args.requires.split()
        rec = check(rows, args.md5, args.magic, req, sel, args.cflags, args.where)
        if args.emit_json:
            json.dump(rec, open(args.emit_json, "w"), indent=1)
        print("    [feature gate] %s = %s (%s) provides %s"
              % (rec["md5"][:10], rec["magic"], rec["variant"], ",".join(rec["provides"])))
        print("    [feature gate] declared %s; selection implies %s -> PASS"
              % (",".join(rec["declared"]) or "none",
                 ",".join(rec["implied_by_selection"]) or "none"))
        for w in rec["selection_notes"]:
            print("                   %s" % w)
        return 0

    recs = []
    for p in args.runs:
        d = json.load(open(p))
        models = d.get("models")
        if isinstance(models, dict) and models:
            for name, m in models.items():
                recs.append(audit_model(rows, name, m, p, args.strict_requires))
        else:
            recs.append(audit_model(rows, d.get("lab", "run"), d, p, args.strict_requires))
    for r in recs:
        if r["verdict"] == "skip":
            print("    [audit] SKIP -- %s" % r["variant"])
            continue
        print("    [audit] %s %s (%s): declared %s, selection implies %s, symptoms checked "
              "[%s] -> PASS" % (r["md5"][:10], r["magic"], r["variant"],
                                ",".join(r["declared"]) or "none",
                                ",".join(r["implied_by_selection"]) or "none",
                                ",".join(r.get("symptoms_applied") or [])))
    if args.emit_json:
        json.dump(recs, open(args.emit_json, "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
