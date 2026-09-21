#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Lab B57 -- score the first on-board transcription.

The question is a comparison, not a measurement: did the board, choosing its own tokens by its
own argmax and stopping on its own EOS test, emit the SAME sequence the host driver emits from
the same input?  So this file's job is to fail loudly on every way the comparison could be
vacuous, which is the failure mode this repository keeps meeting:

  * fewer utterances on the console than were baked into the image  -> FAIL, not a partial pass
  * a `.vals` sidecar that does not cover a step the board reported -> FAIL, not a skip
  * zero steps compared                                             -> FAIL ("0 of 0 differ")

`mean_steps` is REPORTED, never substituted.  Every composition in this tree uses 11.976 from
decoder_tokens_dev.json (765 utterances); the one time a run record's own mean_steps was used it
was 17.07 from a broken driver and would have inflated the decoder term ~40 %.  This run's mean
is over N utterances and is a different estimator of the same quantity -- so the record carries
both and the delta, and no composition.
"""
import glob
import json
import os
import re
import sys

import numpy as np

# THE CLOCK EVERY CYCLE COUNT HERE IS DIVIDED BY, READ FROM THE RUN DIRECTORY.
#
# It was the literal `CLK = 34482759.0` until 2026-09-18 (Lab B81), and it is the one constant
# in this file that CANNOT FAIL LOUDLY.  model_rtf_e2e.py takes `clock_hz` out of the record and
# only checks that the two halves AGREE -- and two halves at the same WRONG clock agree
# perfectly.  So a run on 0x5A5A0030 (FCLK0 40.0000 MHz) scored against a stale 34482759 does
# not error: it reports the OLD RTF at the NEW clock, and nothing downstream refuses it.
#
# The lab writes the clock it asked the board for into clock_hz.txt beside this file, fclk.py
# reads the SLCR back to confirm the board agrees, and the guest's own
# CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC is checked against the same number before the board is
# taken.  Three statements of one fact, and this reads the archived one.  The old constant
# survives ONLY as the fallback for a run directory written before the file existed -- which is
# exactly the set of runs it was the right number for.
def _clock_hz(run_dir, default=34482759.0):
    p = os.path.join(run_dir, "clock_hz.txt")
    if os.path.exists(p):
        return float(open(p).read().split()[0])
    return default


CLK = _clock_hz(sys.argv[1] if len(sys.argv) > 1 else ".")
#: decoder_tokens_dev.json models.R.mean -- dev_clean <= 4 s, 765 utterances.  The number every
#: RTF_e2e in this tree composes with.
MEAN_STEPS_REFERENCE = 11.976
MEAN_STEPS_REFERENCE_SRC = "decoder_tokens_dev.json models.R.mean (765 utterances)"


def _board_name():
    """WHICH PHYSICAL BOARD produced this run.  Never raises, never touches the board: a run
    that cannot name its board records None, and `pynq_host` beside it tells an unregistered
    host from a broken resolver."""
    b = os.environ.get("IISWC_BOARD")
    if b:
        return b
    host = (os.environ.get("PYNQ_HOST") or "").strip()
    if not host:
        return None
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(6):
        csv = os.path.join(d, "fpga", "pynq-z2", "bwlab", "boards.csv")
        if os.path.exists(csv):
            for line in open(csv):
                if line.startswith("#") or "," not in line:
                    continue
                f = line.split(",")
                if len(f) > 1 and f[1].strip() == host:
                    return f[0].strip()
            return None
        nd = os.path.dirname(d)
        if nd == d:
            break
        d = nd
    return None


def parse_console(path):
    """{utt: {...}} from the board's own lines, plus the per-dispatch rows."""
    utts, steps, toks, rows, eng, build = {}, {}, {}, [], [], {}
    if not os.path.exists(path):
        return utts, steps, toks, rows, eng, build
    for line in open(path, errors="replace"):
        if line.startswith("MB_DEC_BUILD "):
            build = dict(re.findall(r"(\w+)=(-?\w+)", line[len("MB_DEC_BUILD "):]))
        elif line.startswith("MB_DEC_UTT "):
            f = dict(re.findall(r"(\w+)=(-?\d+)", line))
            utts[int(f["u"])] = {k: int(v) for k, v in f.items()}
        elif line.startswith("MB_DEC_STEP "):
            f = {k: int(v) for k, v in re.findall(r"(\w+)=(-?\d+)", line)}
            steps.setdefault(f["u"], []).append(f)
        elif line.startswith("MB_DEC_TOKS "):
            m = re.match(r"MB_DEC_TOKS u=(\d+) n=(\d+) ids=(.*)$", line.strip())
            if m:
                ids = [int(x) for x in m.group(3).split(",") if x != ""]
                toks[int(m.group(1))] = ids
        elif line.startswith("MB_PEXT_OP "):
            f = dict(re.findall(r"(\w+)=(\S+)", line[len("MB_PEXT_OP "):]))
            rows.append({"dispatch": int(f["id"]), "name": f["name"], "op": f["op"],
                         "shape": f["shape"], "cycles": int(f["cycles"]),
                         "step": int(f["step"]) if "step" in f else None,
                         "utt": int(f["utt"]) if "utt" in f else None})
        elif line.startswith("MB_ROCCMOON "):
            eng.append(dict(re.findall(r"(\w+)=(-?\w+)", line[len("MB_ROCCMOON "):])))
    return utts, steps, toks, rows, eng, build


def main():
    run = sys.argv[1]
    ar = os.path.join(run, "ar")
    href = os.path.join(run, "hostref")
    fail = []

    meta = open(os.path.join(run, "driver_meta.h")).read()
    md = {k: v for k, v in re.findall(r"#define (\w+)\s+(\d+)", meta)}
    n_steps, vocab, eos = int(md["N_STEPS"]), int(md["VOCAB"]), int(md["EOS_ID"])

    # ---- every batch's console, merged into ONE global utterance index -------------------
    # Tier 2 needs 765 utterances and no single image can carry them (441 MB of packed inputs
    # against ram0's 256 MB), so the set is decoded in batches.  Each batch's console numbers
    # its utterances from 0; batch_bN.json carries the offset that makes them global.  A batch
    # whose console and whose offset record disagree about how many utterances there were is a
    # FAILURE -- silently renumbering would compare board tokens against the wrong host ones.
    # b10 must not sort before b2: the glob is ordered by the batch NUMBER, not by its name.
    consoles = sorted(glob.glob(os.path.join(ar, "console_b*.txt")),
                      key=lambda q: int(re.search(r"console_b(\d+)\.txt$", q).group(1)))
    if not consoles and os.path.exists(os.path.join(ar, "console.txt")):
        consoles = [os.path.join(ar, "console.txt")]
    utts, steps, btoks, rows, eng, build = {}, {}, {}, [], [], {}
    batches, per_batch = [], []
    for c in consoles:
        m = re.search(r"console_b(\d+)\.txt$", c)
        off, id_map = 0, None
        # THE RECORD IS `batch_bN.json` WHEN BATCHED AND `batch.json` WHEN NOT, and the
        # un-batched one was never read here.  That is not cosmetic: --batch-decode reorders
        # utterances (length-sorted grouping) in a SINGLE image, so the console's u is a
        # position in the image and NOT a global id, while this loop assumed `u + off` with
        # off = 0.  B99's B=2 arm decoded all 32 sequences correctly and scored 1/32 for
        # exactly that reason.  `ids` is authoritative wherever it exists; the positional
        # arithmetic is the fallback for records written before the field.
        bj = (os.path.join(ar, "batch_b%s.json" % m.group(1)) if m
              else os.path.join(ar, "batch.json"))
        if m and not os.path.exists(bj):
            fail.append("%s has no batch_b%s.json -- the offset that makes its utterance "
                        "numbers global is unknown, so nothing may be compared" %
                        (os.path.basename(c), m.group(1)))
            continue
        if os.path.exists(bj):
            b = json.load(open(bj))
            id_map = b.get("ids")
            if m:
                off, batches = b["offset"], batches + [b]
            if id_map is not None:
                if len(set(id_map)) != len(id_map):
                    fail.append("%s lists a repeated utterance id" % os.path.basename(bj))
                    continue
        u2, s2, t2, r2, e2, b2 = parse_console(c)
        if m and len(t2) != b["count"]:
            fail.append("batch %s carried %d utterances and its console reports %d -- an "
                        "incomplete batch is not a partial pass" %
                        (m.group(1), b["count"], len(t2)))
        def _gid(k):
            """image position -> global utterance id"""
            if id_map is None:
                return k + off
            if not (0 <= k < len(id_map)):
                fail.append("console reports utterance %d, outside the %d this image was "
                            "baked with" % (k, len(id_map)))
                return None
            return id_map[k]
        for d, src in ((utts, u2), (steps, s2), (btoks, t2)):
            for k, v in src.items():
                g = _gid(k)
                if g is None:
                    continue
                if g in d:
                    fail.append("utterance %d appears in more than one batch" % g)
                d[g] = v
        rows += r2 if not rows else []
        eng += e2
        build = build or b2

        # THE ENGINE COUNTERS OF *THIS* BATCH.  The check below used to read the FIRST
        # phase=total line in the merged list, which under batching is batch 0's -- so a
        # batch whose counters were never captured, or captured as zeros, would be waved
        # through by batch 0's good ones.  That is Lab B57's defect 1 coming back wearing a
        # batch number: `calls_fallback = 0` out of 0 calls counted, and a scorer that passed
        # it.  Every batch is checked, and a batch with no counters is a FAILURE.
        lbl = ("b%s" % m.group(1)) if m else "single"
        et = next((e for e in e2 if e.get("phase") == "total"), {})
        ew = next((e for e in e2 if e.get("phase") == "warm"), {})
        ce = int(et.get("calls_engine", "0") or 0)
        fb = int(et.get("calls_fallback", "0") or 0)
        per_batch.append({
            "batch": lbl, "console": os.path.basename(c), "offset": off,
            "count": (b["count"] if m else len(t2)), "utterances_on_console": len(t2),
            "console_bytes": os.path.getsize(c),
            "calls_engine": ce, "calls_fallback": fb,
            "engine_total": et, "engine_warm": ew, "build_banner": b2})
        if not et:
            fail.append("batch %s has no MB_ROCCMOON phase=total line -- its engine counters "
                        "were never captured, so nothing can say whether the engine ran for "
                        "ITS utterances.  Another batch's counters do not cover it." % lbl)
        elif ce == 0:
            fail.append("batch %s reports calls_engine = 0 while linear_s8 is dispatched to "
                        "roccmoon_engine: either its counters were not captured or the engine "
                        "never ran.  'calls_fallback = 0' over 0 calls counted is not a pass."
                        % lbl)
        elif fb:
            fail.append("batch %s fell back %d times -- this is not the engine's arithmetic"
                        % (lbl, fb))

    n_want = int(os.environ.get("N_UTT", "0"))
    # A SET DECODED IN BATCHES IS ONLY THE WHOLE SET IF EVERY BATCH CAME BACK.  The
    # single-image path refuses a console that reports fewer utterances than were baked; the
    # batched path had no equivalent, so a batch that was never run -- or whose board step
    # died -- would quietly shrink the claim from 765 to whatever came back, with every
    # returned utterance matching and the verdict PASS.
    if batches and n_want:
        covered = set()
        for b in batches:
            covered |= set(range(b["offset"], b["offset"] + b["count"]))
        missing = sorted(set(range(n_want)) - covered)
        if missing:
            fail.append("the batches cover %d of the %d utterances this run claims: %d are "
                        "MISSING (first: %s).  An incomplete set is not a partial pass -- "
                        "either run the missing batches or state the smaller set."
                        % (len(covered), n_want, len(missing), missing[:6]))

    # ---- the host reference -------------------------------------------------------------
    raw = np.fromfile(os.path.join(href, "tok.bin"), dtype=np.int32).reshape(-1, n_steps + 1)
    htoks = {j: [int(x) for x in raw[j, 1:1 + int(raw[j, 0])]] for j in range(raw.shape[0])}
    hvals = {}
    for line in open(os.path.join(href, "tok.bin.vals")):
        u, k, t, v = (int(x) for x in line.split())
        hvals.setdefault(u, []).append((k, t, v))

    # ---- the comparison, with every vacuity as a failure ---------------------------------
    n_host_all = None
    if n_want and not batches and len(btoks) != n_want:
        fail.append("the image carried %d utterances and the console reports %d -- "
                    "an incomplete run is not a partial pass" % (n_want, len(btoks)))
    if not btoks:
        fail.append("the board emitted no tokens at all")

    per = []
    steps_compared = 0
    for u in sorted(btoks):
        b = btoks[u]
        h = htoks.get(u)
        bs = steps.get(u, [])
        hv = hvals.get(u, [])
        rec = {"utt": u,
               "tokens_emitted": len(b), "steps_taken": utts.get(u, {}).get("steps_taken"),
               "board_tokens": b, "host_tokens": h,
               "eos_on_board": bool(utts.get(u, {}).get("eos")),
               "dispatches": utts.get(u, {}).get("dispatches"),
               "cycles": utts.get(u, {}).get("cycles"),
               "step_cycles": [s["cycles"] for s in sorted(bs, key=lambda s: s["k"])],
               "tokens_match": None, "values_match": None, "first_divergence": None}
        if h is None:
            rec["tokens_match"] = False
            fail.append("utterance %d has no host reference" % u)
        else:
            rec["tokens_match"] = (b == h)
            if not rec["tokens_match"]:
                for i in range(min(len(b), len(h))):
                    if b[i] != h[i]:
                        rec["first_divergence"] = {"step": i, "board": b[i], "host": h[i]}
                        break
                if rec["first_divergence"] is None:
                    rec["first_divergence"] = {"step": min(len(b), len(h)),
                                               "board_len": len(b), "host_len": len(h)}
        # the argmax VALUES: a token match that is not also a value match is coincidence
        bv = {s["k"]: (s["tok"], s["val"]) for s in bs}
        hvm = {k: (t, v) for k, t, v in hv}
        common = sorted(set(bv) & set(hvm))
        if not common:
            rec["values_match"] = False
            fail.append("utterance %d: no step was compared on VALUES -- the sidecar and the "
                        "console do not overlap, so nothing was checked" % u)
        else:
            rec["values_match"] = all(bv[k] == hvm[k] for k in common)
            rec["values_compared"] = len(common)
            steps_compared += len(common)
            if not rec["values_match"]:
                k = next(k for k in common if bv[k] != hvm[k])
                rec["first_value_divergence"] = {"step": k, "board": bv[k], "host": hvm[k]}
        per.append(rec)

    if steps_compared == 0:
        fail.append("0 steps were compared on values -- '0 of 0 differ' is not a pass")

    n_match = sum(1 for r in per if r["tokens_match"])
    n_vmatch = sum(1 for r in per if r["values_match"])
    b_mean = float(np.mean([r["tokens_emitted"] for r in per])) if per else None
    h_mean = float(np.mean([len(htoks[u]) for u in sorted(btoks) if u in htoks])) if per else None

    # ---- the rows, with the phase field TODO item 22 asks for ---------------------------
    # The float cross-attention prologue runs OFF BOARD, so no row here is `prologue` in that
    # sense.  What IS once-per-utterance inside the graph is the CSE'd permute of the cross
    # attention kx/vx, which the rewrite collapsed into step 0; those rows are marked
    # `shared_kv` so a chart does not read them as step-0 work that recurs.
    step0 = [r for r in rows if r.get("step") == 0]
    later = {r["name"] for r in rows if r.get("step") not in (0, None)}
    for r in rows:
        if r.get("step") == 0 and r["name"] not in later and r["op"].startswith("permute"):
            r["phase"] = "shared_kv"
        else:
            r["phase"] = "step"
    rows_by_step = {}
    for r in rows:
        rows_by_step.setdefault(r.get("step"), {"dispatches": 0, "cycles": 0})
        rows_by_step[r["step"]]["dispatches"] += 1
        rows_by_step[r["step"]]["cycles"] += r["cycles"]

    per_kind = {}
    for r in rows:
        k = per_kind.setdefault(r["op"], {"dispatches": 0, "cycles": 0})
        k["dispatches"] += 1
        k["cycles"] += r["cycles"]

    # WHAT THE DRIVER ITSELF COSTS, measured rather than assumed -- and nothing in this tree
    # has ever been able to measure it, because nothing on the board has ever run the driver.
    # Per step, for the utterance whose rows were dumped: the wall cycles of the step minus the
    # cycles of every dispatch inside it.  The remainder is the argmax over 32,768 int8 codes
    # plus the embedding row lookup and its DHID soft-float divides.
    driver = None
    ru = int(os.environ.get("ROWS_UTT", "0"))
    rrec = next((r for r in per if r["utt"] == ru), None)
    if rows and rrec and rrec["step_cycles"]:
        ds = []
        for k, sc in enumerate(rrec["step_cycles"]):
            g = rows_by_step.get(k, {}).get("cycles")
            ds.append({"step": k, "step_cycles": sc, "dispatch_cycles": g,
                       "driver_cycles": (sc - g) if g is not None else None})
        tot = sum(d["driver_cycles"] for d in ds if d["driver_cycles"] is not None)
        allc = sum(d["step_cycles"] for d in ds)
        driver = {"utterance": ru, "per_step": ds, "driver_cycles_total": tot,
                  "step_cycles_total": allc,
                  "driver_share_of_step_cycles": (tot / allc) if allc else None,
                  "what_it_is": "argmax over %d int8 logits + the embedding row lookup and "
                                "its %s soft-float divides, per step" % (vocab, md.get("DHID")),
                  "caveat": "the dispatch cycles are rdcycle deltas taken INSIDE each dispatch, "
                            "so the remainder also carries the per-dispatch call and profile-"
                            "record overhead, not the driver alone. It is an UPPER BOUND."}

    # THE ENGINE, AND THE CHECK THAT `calls_fallback = 0` IS NOT 0 OUT OF 0 COUNTED.
    # linear_s8 is dispatched to roccmoon_engine in this image's picks, so a run in which the
    # engine was called ZERO times is a run whose arithmetic came from somewhere else -- and
    # the FIRST run of this lab reported exactly that, because the AR worker never copied
    # mbxr_rt_stats.  A missing or zeroed counter block is therefore a FAILURE, not a skip.
    # The per-BATCH counters are checked in the merge loop above -- every batch, not only the
    # first.  What is left here is the whole-run view: the union across batches, and the guard
    # for a run that produced no counter line at all.
    eng_total = next((e for e in eng if e.get("phase") == "total"), {})
    eng_warm = next((e for e in eng if e.get("phase") == "warm"), {})
    if not eng_total:
        fail.append("no MB_ROCCMOON phase=total line -- the engine counters were not captured, "
                    "so nothing here can say whether the engine ran")
    engine_all = {
        "calls_engine": sum(pb["calls_engine"] for pb in per_batch),
        "calls_fallback": sum(pb["calls_fallback"] for pb in per_batch),
        "batches_counted": len(per_batch),
        "NOTE": "summed over every batch.  `engine` below is the FIRST batch's block and is "
                "kept for comparability with the single-image runs; the per-batch blocks are "
                "in engine_per_batch.",
    }

    # WHERE A DISCREPANCY SITS.  A run that is 765 utterances in 7 images can fail in a way a
    # single-image run cannot: one batch wrong and the rest clean is the BATCHING, not the
    # model, and it is exactly the shape that reads like an accuracy result and is not.  So
    # the agreement is reported per batch as well as in total.
    for pb in per_batch:
        lo, hi = pb["offset"], pb["offset"] + pb["count"]
        rs = [r for r in per if lo <= r["utt"] < hi]
        pb["utterances_compared"] = len(rs)
        pb["tokens_match"] = sum(1 for r in rs if r["tokens_match"])
        pb["values_match"] = sum(1 for r in rs if r["values_match"])
        pb["steps_compared"] = sum(r.get("values_compared", 0) for r in rs)
        pb["mean_steps_board"] = (float(np.mean([r["tokens_emitted"] for r in rs]))
                                  if rs else None)
        pb["first_divergent_utt"] = next(
            (r["utt"] for r in rs if not (r["tokens_match"] and r["values_match"])), None)

    verdict = "PASS" if not fail and n_match == len(per) and n_vmatch == len(per) and per \
        else "FAIL"
    if verdict == "FAIL" and not fail:
        fail.append("%d of %d utterances matched the host token-for-token, %d on values"
                    % (n_match, len(per), n_vmatch))

    hostrun = {}
    p = os.path.join(href, "host_dec_run.json")
    if os.path.exists(p):
        hostrun = json.load(open(p))
    # The footprint of the image that ran.  With batches there is one per batch and they differ
    # only in the input slice, so the LAST is taken and the count of utterances it carried is
    # what distinguishes it -- never silently merged with another batch's.
    fp = {}
    cands = sorted(glob.glob(os.path.join(ar, "footprint_b*.json"))) \
        or [os.path.join(ar, "footprint.json")]
    for pth in cands:
        if os.path.exists(pth):
            fp = json.load(open(pth))
    bw = {}
    p = os.path.join(run, "board_wer.json")
    if os.path.exists(p):
        bw = json.load(open(p))

    out = {
        # The lab this run belongs to, not the lab that wrote this file.  It was the literal
        # "B57 ..." until 2026-09-19: board records carry the lab as a STRING and are evidence
        # (LAB_REGISTRY.md), so a later lab scored by this scorer was stamping B57 on its own
        # record.  $MB_LAB overrides; the default is the run this file was written for.
        "lab": os.environ.get("MB_LAB", "B57 on-board autoregressive decode"),
        "what": "the board chooses its own tokens: argmax, EOS test, embedding lookup and "
                "early exit all on hart 0",
        "board": _board_name(), "pynq_host": os.environ.get("PYNQ_HOST"),
        "soc_magic": os.environ.get("WANT_MAGIC"),
        "bitstream_md5": os.environ.get("BIT_MD5"),
        "clock_hz": CLK, "window_s": float(os.environ.get("MB_WINDOW_S", "4.0")),
        "n_steps_unrolled": n_steps, "vocab": vocab, "eos_id": eos,
        "utterances": len(per),
        "tokens_match": n_match, "values_match": n_vmatch,
        "steps_compared_on_values": steps_compared,
        "mean_steps": {
            "board_measured": b_mean,
            "host_driver_same_utterances": h_mean,
            "reference_used_by_every_composition": MEAN_STEPS_REFERENCE,
            "reference_source": MEAN_STEPS_REFERENCE_SRC,
            "delta_board_minus_reference":
                (b_mean - MEAN_STEPS_REFERENCE) if b_mean is not None else None,
            "NOTE": "REPORTED, NOT SUBSTITUTED.  This is a %d-utterance mean; the reference "
                    "is a 765-utterance one.  They are two estimators of the same quantity "
                    "and the difference here is sampling, not a correction -- no composition "
                    "in this tree may take this number without saying so." % len(per),
        },
        # WHAT THE HOST STILL DOES, READ OUT OF THE RUN'S OWN RECORD RATHER THAN ASSERTED.
        # This list said "the FLOAT cross-attention prologue: kx/vx are packed into the
        # board's input" unconditionally, and from Lab B112 that is false for any arm whose
        # graph computes the prologue itself -- the sort of caveat that outlives the thing it
        # describes and is then quoted as if it had been checked.  model_dec_run.py writes a
        # `prologue` block when --pro-int8 packed `enc` instead of twelve kx/vx tensors.
        "fed_from_the_host": [
            "the encoder (%s)" % (hostrun.get("encoder") or "unknown"),
            ("the FLOAT cross-attention prologue: kx/vx are packed into the board's input"
             if not hostrun.get("prologue") else
             "NOT the cross-attention prologue -- it is IN THE GRAPH (%s); the host packs one "
             "encoder hidden state, %s B per utterance"
             % (hostrun["prologue"].get("weights", "int8"),
                hostrun["prologue"].get("packed_bytes_per_utterance"))),
            "detokenisation of ids to text",
        ],
        **({"prologue": hostrun["prologue"]} if hostrun.get("prologue") else {}),
        "chosen_on_the_board": [
            "argmax over each step's %d logits" % vocab,
            "the EOS test (id %d)" % eos,
            "the embedding-row lookup and its requantisation into the next step's input",
            "early exit -- a break out of the unrolled dispatch sequence",
        ],
        "max_abs_err": None,
        "max_abs_err_meaning":
            "NOT MEASURED AND NOT CLAIMED: the trajectory is data-dependent, so there is no "
            "baked golden.  Correctness here is the token sequence and the per-step argmax "
            "value, both checked against dec_driver.c.",
        "per_utterance": per,
        "per_step_rows": {"utterance": int(os.environ.get("ROWS_UTT", "0")),
                          "n_rows": len(rows), "by_step": rows_by_step},
        "per_kind": per_kind,
        "driver_cost": driver,
        "engine": eng_total,
        "engine_all_batches": engine_all,
        "engine_per_batch": [{k: v for k, v in pb.items() if k != "engine_warm"}
                             for pb in per_batch],
        "batches": batches,
        "engine_after_first_utterance": eng_warm,
        "engine_phase_meaning":
            "AR mode: `warm` is after utterance 0 -- the utterance that pays the one-time "
            "engine weight-image build -- and `total` after all of them.  The console labels "
            "are the replay path's and mean something else there.",
        "footprint": fp,
        "build_banner": build,
        "host_reference": hostrun.get("provenance", {}),
        "board_wer": bw,
        "host_wer": {"int8_decoder": hostrun.get("wer_int8_decoder"),
                     "float_decoder": hostrun.get("wer_float_decoder"),
                     "NOTE": "host-side, over these %d utterances only -- NOT the 13.392 %% "
                             "control, which is 765 utterances "
                             "(archive/runs/b49_dec_wer/decrun_ctrl.log)" % len(per)},
        "rows": rows,
        "failures": fail,
        "verdict": verdict,
    }
    json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)

    L = ["Lab %s  --  the board chooses its own tokens  (%s on %s, md5 %s)"
         % (out["lab"], out["board"], out["soc_magic"],
            (out["bitstream_md5"] or "?")[:10]),
         "",
         "%d utterances: %d matched the host driver TOKEN FOR TOKEN, %d also on the argmax "
         "VALUE at every step (%d steps compared)"
         % (len(per), n_match, n_vmatch, steps_compared),
         ""]
    # Print the first eight and EVERY divergence.  A 765-utterance run must not bury a
    # mismatch under 3,000 lines of agreement, and it must not hide one by truncating either.
    shown = [r for r in per[:8]]
    shown += [r for r in per[8:] if not (r["tokens_match"] and r["values_match"])]
    if len(shown) < len(per):
        L.append("  (showing the first %d and every divergence; all %d are in run.json)"
                 % (min(8, len(per)), len(per)))
    for r in shown:
        L.append("  utt %d  n=%2d  eos=%s  %s" % (r["utt"], r["tokens_emitted"],
                 "yes" if r["eos_on_board"] else "NO",
                 "MATCH" if r["tokens_match"] else "DIFFERS"))
        L.append("      board %s" % r["board_tokens"])
        L.append("      host  %s" % r["host_tokens"])
        if r.get("first_divergence"):
            L.append("      first divergence: %s" % r["first_divergence"])
        if r.get("first_value_divergence"):
            L.append("      first VALUE divergence: %s" % r["first_value_divergence"])
    L += ["",
          "mean_steps  board %.3f   host driver (same %d) %.3f   reference %.3f (%s)"
          % (b_mean or 0, len(per), h_mean or 0, MEAN_STEPS_REFERENCE, MEAN_STEPS_REFERENCE_SRC),
          "            REPORTED, NOT SUBSTITUTED -- see run.json mean_steps.NOTE",
          ""]
    if fp:
        L.append("footprint: image %.2f MB (embedding %.2f MB + inputs %.2f MB + weights), "
                 "guest RAM %.2f MB of ram0's 256.00 MB (%.2f %%) -- ram0 is 256 MB, not the "
                 "card's 512"
                 % (fp.get("image_bytes", 0) / 1e6, fp.get("emb_bytes", 0) / 1e6,
                    fp.get("inputs_bytes", 0) / 1e6, fp.get("ram_used_bytes", 0) / 1e6,
                    fp.get("ram_used_pct", 0.0)))
    if rows:
        L.append("rows: %d per-dispatch rows for utterance %s, carrying `step`"
                 % (len(rows), out["per_step_rows"]["utterance"]))
    if driver and driver["driver_share_of_step_cycles"] is not None:
        L.append("driver cost (utt %d): %d of %d step cycles = %.2f %% -- argmax + embedding "
                 "lookup; an UPPER BOUND, it carries per-dispatch call overhead too"
                 % (driver["utterance"], driver["driver_cycles_total"],
                    driver["step_cycles_total"],
                    100.0 * driver["driver_share_of_step_cycles"]))
    if eng_total:
        L.append("engine: calls_engine=%s calls_fallback=%s last_rc=%s  (first batch)"
                 % (eng_total.get("calls_engine"), eng_total.get("calls_fallback"),
                    eng_total.get("last_rc")))
    if len(per_batch) > 1:
        L += ["",
              "PER BATCH -- a discrepancy confined to one image is the BATCHING, not the model:",
              "  batch  utts  tok  val   steps  mean  calls_engine  fallback  console B"]
        for pb in per_batch:
            L.append("  %-5s  %4d  %3d  %3d  %6d  %5.2f  %12d  %8d  %9d%s"
                     % (pb["batch"], pb["utterances_compared"], pb["tokens_match"],
                        pb["values_match"], pb["steps_compared"],
                        pb["mean_steps_board"] or 0.0, pb["calls_engine"],
                        pb["calls_fallback"], pb["console_bytes"],
                        "" if pb["first_divergent_utt"] is None
                        else "  <-- first divergence at utt %d" % pb["first_divergent_utt"]))
        L.append("  engine over every batch: calls_engine=%d calls_fallback=%d"
                 % (engine_all["calls_engine"], engine_all["calls_fallback"]))
    if bw:
        L += ["",
              "WER FROM THE TOKENS THE BOARD CHOSE: %.3f %%   host driver, same %d utterances: "
              "%.3f %%   delta %+.3f [%+.3f, %+.3f]"
              % (bw["wer_board_tokens"] * 100, bw["set"]["utterances"],
                 bw["wer_host_driver_same_set"] * 100,
                 bw["board_minus_host"]["delta_wer"] * 100,
                 bw["board_minus_host"]["ci95"][0] * 100,
                 bw["board_minus_host"]["ci95"][1] * 100),
              "    %d of %d sequences identical; %d words, %d speakers; complete served set: %s"
              % (bw["sequences_identical"], bw["of"], bw["set"]["words"],
                 bw["set"]["speakers"], bw["set"]["complete_served_set"]),
              "    mean_steps board %.4f, host %.4f; %d of %d ran to the %d-step unroll limit"
              % (bw["mean_steps_board"], bw["mean_steps_host"],
                 bw["ran_to_the_unroll_limit"], bw["of"], bw["n_steps_unrolled"]),
              "    " + bw["control_note"].replace("\n", " ")]
    L += ["", "FED FROM THE HOST (named, not folded into a total):"]
    L += ["  - " + x for x in out["fed_from_the_host"]]
    if fail:
        L += ["", "FAILURES:"] + ["  - " + f for f in fail]
    L += ["", "verdict: " + verdict]
    txt = "\n".join(L) + "\n"
    open(os.path.join(run, "report.txt"), "w").write(txt)
    open(os.path.join(run, "verdict.txt"), "w").write(verdict + "\n")
    print(txt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
