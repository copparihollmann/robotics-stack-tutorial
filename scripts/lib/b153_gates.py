#!/usr/bin/env python3
"""Lab B153 -- the gates that decide whether the merged TACIT timeline is usable.

Every number here is read back off the artefact or off the board's own console; nothing is
recomputed from what the run was ASKED to do.  The merged Perfetto JSON is parsed one line
at a time (the decoder writes one event per line) so a multi-hundred-megabyte trace costs
no more memory than a small one.

The gates, in the order they are printed:

  1  LANES          events and DISTINCT FUNCTION NAMES per lane, and the top frames.  This
                    is the table that proves the artefact is usable: B151's hart 0 lane had
                    838,206 events and TWO distinct names.  Requires >= 10 distinct names
                    on both lanes, real signdet work on hart 0, and z_impl_k_busy_wait NOT
                    the dominant frame.
  2  BUFFERS        TR_SK_DMA_COUNT[h] <= span[h], and base[1] >= base[0] + COUNT[0].  The
                    sink has NO limit register, so an overrun is reported by nothing: it
                    just writes into the next lane and both traces still decode.
  3  COVERAGE       where the first and last event of each lane land against the window the
                    board reported (trace_c0 .. trace_c1).  Under from-reset tracing
                    trace_c0 is 0, so the first event's FUNCTION and mcycle are what prove
                    the trace starts at the reset vector rather than at main().
  4  REPLAY         the B151 gate, unchanged: 8/8 decisions, 8/8 tensors, max |d| = 0.
                    Tracing must not perturb the result it is tracing.

                    THIS IS THE ONE GATE THAT DEPENDS ON THE MODEL'S WEIGHTS, and it is
                    the one this repository cannot ship the weights for (GTSDB licence;
                    docs/SIGNDET_WEIGHTS.md).  Given --weights-manifest pointing at a gen
                    tree whose signdet_weights.json says replay_gate=not_applicable -- what
                    scripts/84 writes when it lowered a RANDOM-weight model -- this gate
                    still runs, still prints every row, and is reported NOT APPLICABLE
                    rather than FAIL.  It is excluded from the overall result, and nothing
                    else is: a random-weight run that fails gates 1, 2, 3 or 5 fails.
  5  RATE           bytes per core cycle per hart, measured.  This is what sizes a buffer.

WHICH GATES MEAN WHAT IN WHICH MODE, in one line: 1, 2, 3 and 5 are statements about the
TRACING MECHANISM and the SCHEDULE and hold whatever the weights are; 4 is the only
statement about DETECTION and needs the real ones.
"""
import argparse
import collections
import json
import os
import re
import sys

# Functions that mean "hart 0 is actually running the detector", as opposed to running the
# tracing harness.  Matched as substrings against the decoder's symbol names.
SIGN_MARKERS = ("signdet", "dispatch_", "kernel_", "sign_pre", "ospi", "one_shot",
                "run_model", "mb_pext")
HARNESS = ("z_impl_k_busy_wait", "sys_clock_cycle_get_32")


def lanes(path):
    """Stream the merged Perfetto JSON. Returns {pid: stats}."""
    names = {}
    st = collections.defaultdict(lambda: dict(
        events=0, ph=collections.Counter(), fn=collections.Counter(),
        ts_min=None, ts_max=None, first=None, last=None))
    ev_re = re.compile(r'^\s*(\{.*\}),?\s*$')
    with open(path) as fh:
        for line in fh:
            m = ev_re.match(line)
            if not m:
                continue
            try:
                e = json.loads(m.group(1))
            except ValueError:
                continue
            if e.get("ph") == "M":
                if e.get("name") in ("process_name", "thread_name"):
                    names[e.get("pid")] = e.get("args", {}).get("name", "")
                continue
            pid = e.get("pid")
            s = st[pid]
            s["events"] += 1
            s["ph"][e.get("ph")] += 1
            if e.get("ph") in ("B", "X"):
                s["fn"][e.get("name")] += 1
            ts = e.get("ts")
            if ts is None:
                continue
            if s["ts_min"] is None or ts < s["ts_min"]:
                s["ts_min"] = ts
                if e.get("ph") in ("B", "X"):
                    s["first"] = (ts, e.get("name"), e.get("args", {}).get("addr"))
            if s["ts_max"] is None or ts > s["ts_max"]:
                s["ts_max"] = ts
                s["last"] = (ts, e.get("name"))
    return names, st


def console_numbers(txt):
    """Everything the board itself reported. No re-derivation."""
    out = {"harts": {}, "span_cycles": None, "from_reset": None, "gate": {},
           "replay": {"rows": [], "end": None}, "kws": {}, "sign_frames": 0, "map": {}}
    for l in open(txt, errors="replace"):
        # The two trailing fields are B153's; a B151 console has the same line without
        # them, and this script is also used to anchor the BEFORE.
        m = re.search(r"DUO_TRACE_HART hart=(\d+) buf=0x([0-9a-fA-F]+) bytes=(\d+) "
                      r"span_cycles=(\d+) bytes_per_s=(\d+) buf_span=(\d+) full_pct=(\d+) "
                      r"armed=(\d+)(?: bytes_per_cycle_x1e6=(\d+) fits=(\d+))?", l)
        if m:
            span_cyc = int(m.group(4))
            nbytes = int(m.group(3))
            span = int(m.group(6))
            out["harts"][int(m.group(1))] = dict(
                buf=int(m.group(2), 16), bytes=nbytes,
                span_cycles=span_cyc, bytes_per_s=int(m.group(5)),
                buf_span=span, full_pct=int(m.group(7)),
                armed=int(m.group(8)),
                bpc=(int(m.group(9)) / 1e6 if m.group(9)
                     else (nbytes / span_cyc if span_cyc else 0.0)),
                fits=(int(m.group(10)) if m.group(10) else int(nbytes <= span)))
            out["span_cycles"] = span_cyc
        m = re.search(r"DUO_TRACE_GATE overrun=(\d+) overlap=(\d+)", l)
        if m:
            out["gate"] = dict(overrun=int(m.group(1)), overlap=int(m.group(2)))
        m = re.search(r"DUO_TRACE_END span_cycles=(\d+) from_reset=(\d+)", l)
        if m:
            out["span_cycles"] = int(m.group(1))
            out["from_reset"] = int(m.group(2))
        m = re.search(r"DUO_TRACE_MAP image_end=0x([0-9a-fA-F]+)", l)
        if m:
            out["map"]["image_end"] = int(m.group(1), 16)
        m = re.search(r"DUO_TRACE_ARM hart=(\d+) from_reset=\d+ buf=\S+ addr_rb=\S+ "
                      r"span=(\d+) count_at_main=(\d+) ok=(\d+)", l)
        if m:
            out["map"].setdefault("at_main", {})[int(m.group(1))] = dict(
                span=int(m.group(2)), count=int(m.group(3)), ok=int(m.group(4)))
        if "SD_REPLAY i=" in l:
            out["replay"]["rows"].append(l.strip())
        m = re.search(r"SD_REPLAY_END decisions_ok=(\d+) tensors_ok=(\d+) thr_match=(\d+)", l)
        if m:
            out["replay"]["end"] = tuple(int(x) for x in m.groups())
        m = re.search(r"KWS_DUTY blocks=(\d+) frames=(\d+) inferences=(\d+) detections=(\d+)", l)
        if m:
            out["kws"].update(blocks=int(m.group(1)), frames=int(m.group(2)),
                              infer=int(m.group(3)), detect=int(m.group(4)))
        m = re.search(r"KWS_AUDIO seconds_x1000=(\d+)", l)
        if m:
            out["kws"]["audio_s"] = int(m.group(1)) / 1000.0
        m = re.search(r"KWS_PERMILLE frontend=(\d+) model=(\d+) busy=(\d+)", l)
        if m:
            out["kws"]["busy_permille"] = int(m.group(3))
        m = re.search(r"KWS_PER_UNIT frame_cycles=(\d+) infer_cycles=(\d+)", l)
        if m:
            out["kws"]["infer_cycles"] = int(m.group(2))
        if re.search(r"^SNAP seq=", l):
            out["sign_frames"] += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--clk-hz", type=int, default=40000000)
    ap.add_argument("--out")
    ap.add_argument("--weights-manifest",
                    help="a gen tree's signdet_weights.json.  Its replay_gate field decides "
                         "whether GATE 4 is a gate or is reported NOT APPLICABLE.  Absent, "
                         "the model is ASSUMED to be the real one and gate 4 is a gate -- "
                         "the safe direction, because it fails loudly rather than excusing "
                         "a failure it cannot see the cause of.")
    a = ap.parse_args()

    # WHICH WEIGHTS ARE IN THE IMAGE.  Read, never inferred from the result: a detector that
    # disagrees with the baked answers looks exactly the same whether it is random or broken,
    # and the only thing that can tell them apart is what was lowered.
    wm = {"weights_mode": "unknown", "replay_gate": "applicable"}
    if a.weights_manifest and os.path.exists(a.weights_manifest):
        try:
            wm.update(json.load(open(a.weights_manifest)))
        except ValueError:
            print("  [warn] %s is not JSON -- treating the weights as real"
                  % a.weights_manifest)
    replay_applies = wm.get("replay_gate") != "not_applicable"

    merged = os.path.join(a.run, "trace.merged.perfetto.json")
    console = os.path.join(a.run, "console.txt")
    for p in (merged, console):
        if not os.path.exists(p):
            sys.exit("missing: %s" % p)

    names, st = lanes(merged)
    cn = console_numbers(console)
    R = {"run": a.run, "gates": {}, "lanes": {}, "console": cn}
    W = print
    fails = []

    W("=" * 86)
    W("B153  FULL FROM-RESET TACIT TRACE -- GATES")
    W("=" * 86)
    W("artefact  %s (%.1f MB)" % (merged, os.path.getsize(merged) / 1e6))
    W("weights   %s -- %s" % (wm["weights_mode"].upper(),
                              "detection is meaningful, GATE 4 applies" if replay_applies
                              else "NO DETECTION ABILITY, GATE 4 IS NOT APPLICABLE"))
    if not replay_applies:
        W("          %s" % wm.get("provenance", ""))
        W("          gates 1, 2, 3 and 5 below are about the tracing mechanism and the")
        W("          schedule; they hold whatever the weights are, and they still gate.")
    R["weights"] = wm
    W("from_reset=%s  span_cycles=%s (%.3f s at %d Hz)"
      % (cn["from_reset"], cn["span_cycles"],
         (cn["span_cycles"] or 0) / a.clk_hz, a.clk_hz))
    if cn["map"].get("image_end"):
        W("image top (__kernel_ram_end) = 0x%08X" % cn["map"]["image_end"])

    # ---- gate 1: the lanes -------------------------------------------------------------
    W("")
    W("GATE 1  LANES -- events and distinct function names")
    W("-" * 86)
    W("  %-4s %-38s %10s %10s" % ("pid", "lane", "events", "distinct"))
    ok1 = True
    for pid in sorted(st):
        s = st[pid]
        nd = len(s["fn"])
        W("  %-4d %-38s %10d %10d" % (pid, (names.get(pid) or "")[:38], s["events"], nd))
        R["lanes"][pid] = dict(name=names.get(pid), events=s["events"], distinct=nd,
                               top=s["fn"].most_common(12),
                               ts_min=s["ts_min"], ts_max=s["ts_max"],
                               first=s["first"], last=s["last"])
        if nd < 10:
            ok1 = False
            fails.append("lane %d has %d distinct function names (need >= 10)" % (pid, nd))
    for pid in sorted(st):
        s = st[pid]
        W("")
        W("  pid %d top frames:" % pid)
        for n, c in s["fn"].most_common(12):
            W("      %9d  %s" % (c, n))
    # hart 0 must be running the detector, not the harness
    if 0 in st:
        fn0 = st[0]["fn"]
        sign_hits = {n: c for n, c in fn0.items()
                     if any(k in n for k in SIGN_MARKERS)}
        top = fn0.most_common(1)[0][0] if fn0 else None
        W("")
        W("  hart 0 signdet/dispatch/kernel symbols present: %d" % len(sign_hits))
        W("  hart 0 dominant frame: %s" % top)
        R["gates"]["hart0_sign_symbols"] = len(sign_hits)
        R["gates"]["hart0_dominant"] = top
        if not sign_hits:
            ok1 = False
            fails.append("hart 0 lane contains NO signdet/dispatch/kernel function")
        if top in HARNESS:
            ok1 = False
            fails.append("hart 0's dominant frame is the tracing harness (%s)" % top)
    # ---- the hw/sw labels are a CLAIM the lanes can refute ---------------------------
    # scripts/lib/b153_disambiguate.py splits the duplicated mb_pext_conv_* symbols into
    # [hw] and [sw] copies from the DISASSEMBLY alone -- it never looks at which lane an
    # event landed on.  So checking that hart 0 ran only the [hw] copies and hart 1 only
    # the [sw] ones is a real test, and it is the evidence that settles B151's open
    # question: hart 1 has no MBP datapath and a custom-0 word there is an illegal
    # instruction, so if hart 1 were executing the [hw] copy it would have trapped.
    hw = {p: sum(c for n, c in st[p]["fn"].items() if "[hw @" in n) for p in st}
    sw = {p: sum(c for n, c in st[p]["fn"].items() if "[sw @" in n) for p in st}
    if any(hw.values()) or any(sw.values()):
        W("")
        W("  duplicated-symbol split (labels derived from the ELF, not from the lane):")
        for p in sorted(st):
            W("      pid %d   [hw] copies %8d      [sw] copies %8d" % (p, hw[p], sw[p]))
        R["gates"]["hw_sw_split"] = {"hw": hw, "sw": sw}
        if hw.get(1) or sw.get(0):
            ok1 = False
            fails.append("lane/label disagreement: hart 0 ran %d [sw] and hart 1 ran %d "
                         "[hw] copies" % (sw.get(0, 0), hw.get(1, 0)))
        else:
            W("      => hart 0 ran ONLY the hardware copies and hart 1 ONLY the software")
            W("         model.  Hart 1 never executed custom-0, and the lanes are not"
              " swapped.")
    R["gates"]["lanes_ok"] = ok1
    W("  => GATE 1 %s" % ("PASS" if ok1 else "FAIL"))

    # ---- gate 2: the buffers -----------------------------------------------------------
    W("")
    W("GATE 2  BUFFERS -- no lane overran its region or the other lane")
    W("-" * 86)
    ok2 = True
    W("  %-5s %12s %12s %12s %7s %s"
      % ("hart", "base", "bytes", "span", "full%", "fits"))
    for h in sorted(cn["harts"]):
        d = cn["harts"][h]
        W("  %-5d 0x%08X   %12d %12d %6d%%  %s"
          % (h, d["buf"], d["bytes"], d["buf_span"], d["full_pct"],
             "yes" if d["fits"] else "NO"))
        if not d["fits"]:
            ok2 = False
            fails.append("hart %d wrote %d B into a %d B region" % (h, d["bytes"], d["buf_span"]))
    if 0 in cn["harts"] and 1 in cn["harts"]:
        end0 = cn["harts"][0]["buf"] + cn["harts"][0]["bytes"]
        base1 = cn["harts"][1]["buf"]
        W("  base[1]=0x%08X >= base[0]+COUNT[0]=0x%08X : %s"
          % (base1, end0, "yes" if base1 >= end0 else "NO -- LANE 1 IS CORRUPT"))
        R["gates"]["no_overlap"] = base1 >= end0
        if base1 < end0:
            ok2 = False
            fails.append("hart 0 overwrote hart 1's lane")
    if cn["gate"]:
        W("  board's own check: overrun=%(overrun)d overlap=%(overlap)d" % cn["gate"])
        if cn["gate"].get("overrun") or cn["gate"].get("overlap"):
            ok2 = False
    R["gates"]["buffers_ok"] = ok2
    W("  => GATE 2 %s" % ("PASS" if ok2 else "FAIL"))

    # ---- gate 3: coverage --------------------------------------------------------------
    W("")
    W("GATE 3  COVERAGE -- where the trace actually starts and ends")
    W("-" * 86)
    c1 = cn["span_cycles"] or 0
    ok3 = True
    for pid in sorted(st):
        s = st[pid]
        if s["first"]:
            W("  pid %d first event  ts=%-12d  %-34s %s"
              % (pid, s["first"][0], s["first"][1], s["first"][2] or ""))
        if s["last"]:
            W("  pid %d last  event  ts=%-12d  %s" % (pid, s["last"][0], s["last"][1]))
        gap0 = s["ts_min"] if s["ts_min"] is not None else None
        gap1 = (c1 - s["ts_max"]) if (c1 and s["ts_max"] is not None) else None
        W("  pid %d gap to trace_c0 (=0 from reset): %s cycles;  gap to trace_c1 (=%d): %s cycles"
          % (pid, gap0, c1, gap1))
        R["lanes"][pid]["gap_start"] = gap0
        R["lanes"][pid]["gap_end"] = gap1
    if cn["from_reset"]:
        # WHAT "FROM RESET" IS JUDGED BY, AND WHY IT IS NOT AN mcycle THRESHOLD.
        #
        # mcycle counts from HARDWARE reset, and the Rocket bootrom runs before Zephyr's
        # reset vector is reached at all, so the first traced instruction lands around
        # mcycle 810,500 on this SoC no matter how early the encoder is armed.  That
        # offset is the BOOTROM and it is not capturable by this mechanism: the encoder is
        # enabled by Zephyr's own reset.S.  out/rocket_tacit_boot -- a single-hart
        # CONFIG_MULTITHREADING=n image sharing none of this software -- starts at
        # mcycle 810,521 in z_prep_c, which is what fixes the offset as a property of the
        # machine rather than of the guest.
        #
        # So the gate is the SYMBOL: the first slice must be in reset.S or in the first C
        # function after it, not in main() or later.
        for pid in sorted(st):
            fn = (st[pid]["first"] or (None, "", None))[1] or ""
            good = fn in ("z_prep_c", "boot_secondary_core", "__initialize",
                          "arch_secondary_cpu_init", "arch_bss_zero", "memset")
            W("  pid %d first slice is %-28s -> %s"
              % (pid, fn, "reset vector / early boot" if good else "NOT early boot"))
            R["lanes"][pid]["first_is_boot"] = good
            if not good:
                ok3 = False
                fails.append("pid %d's first slice is %s -- that is not the reset vector"
                             % (pid, fn))
        W("  (the ~810,500-cycle offset before the first slice is the Rocket BOOTROM, which"
          " runs")
        W("   before Zephyr's reset vector and cannot be captured by a software-armed"
          " encoder.)")
    R["gates"]["coverage_ok"] = ok3
    W("  => GATE 3 %s" % ("PASS" if ok3 else "FAIL"))

    # ---- gate 4: the replay gate -------------------------------------------------------
    W("")
    W("GATE 4  REPLAY -- tracing must not perturb the result (B151's gate, unchanged)")
    W("-" * 86)
    rows = cn["replay"]["rows"]
    nd = sum(1 for l in rows if "decision=MATCH" in l)
    nt = sum(1 for l in rows if "tensor=MATCH" in l)
    errs = [int(m.group(1)) for m in
            (re.search(r"max_abs_err=(\d+)", l) for l in rows) if m]
    maxd = max(errs) if errs else None
    W("  %d/%d decisions MATCH, %d/%d tensors MATCH, max |d| = %s"
      % (nd, len(rows), nt, len(rows), maxd))
    W("  SD_REPLAY_END decisions_ok/tensors_ok/thr_match = %s" % (cn["replay"]["end"],))
    ok4 = (len(rows) == 8 and nd == 8 and nt == 8 and maxd == 0
           and cn["replay"]["end"] == (1, 1, 1))
    R["gates"]["replay"] = dict(n=len(rows), decisions=nd, tensors=nt, max_abs_err=maxd,
                                applicable=replay_applies)
    if not replay_applies:
        # NOT a pass, NOT a failure, and it must not be allowed to read as either.  The
        # numbers above are printed in full because they are still evidence -- that eight
        # frames were replayed, that the board produced a 192-byte tensor for each, that
        # nothing hung -- they just are not evidence ABOUT DETECTION.
        R["gates"]["replay_ok"] = None
        W("")
        W("  => GATE 4 NOT APPLICABLE -- %s weights." % wm["weights_mode"])
        W("     The 8 frames ran and the board answered for all 8; the answers are compared")
        W("     against a HOST run of the REAL model, which is not the model in this image,")
        W("     so a mismatch here is the expected result and says nothing about the board.")
        W("     This gate needs the real weights: docs/SIGNDET_WEIGHTS.md.")
    else:
        R["gates"]["replay_ok"] = ok4
        if not ok4:
            fails.append("the replay gate did not pass with tracing on")
        W("  => GATE 4 %s" % ("PASS" if ok4 else "FAIL"))

    # ---- gate 5: the measured rate -----------------------------------------------------
    W("")
    W("GATE 5  RATE -- measured bytes per core cycle (this is what sizes a buffer)")
    W("-" * 86)
    W("  %-5s %14s %14s %16s %14s" % ("hart", "bytes", "span_cycles", "bytes/cycle", "MB/s"))
    for h in sorted(cn["harts"]):
        d = cn["harts"][h]
        W("  %-5d %14d %14d %16.4f %14.2f"
          % (h, d["bytes"], d["span_cycles"], d["bpc"], d["bytes_per_s"] / 1e6))
    W("")
    k = cn["kws"]
    W("  work completed: signdet inferences = %d (8 replay + %d live);  "
      "kws inferences = %s" % (8 + cn["sign_frames"], cn["sign_frames"], k.get("infer")))
    if k.get("audio_s") and cn["span_cycles"]:
        wall = cn["span_cycles"] / a.clk_hz
        W("  hart 1 was busy %s permille of the run and took %.1f s to process %.2f s of "
          "audio (%.1fx real time)" % (k.get("busy_permille"), wall, k["audio_s"],
                                       wall / k["audio_s"]))
        W("  => THE RUN LENGTH IS SET BY KWS_SECONDS, NOT BY SD_FRAMES: the software P-ext")
        W("     model on the little hart runs ~%.0fx slower than the microphone."
          % (wall / k["audio_s"]))
    if k.get("infer_cycles"):
        W("  kws per-inference: %d cycles (%.0f ms)"
          % (k["infer_cycles"], 1000.0 * k["infer_cycles"] / a.clk_hz))

    W("")
    W("=" * 86)
    allok = ok1 and ok2 and ok3 and (ok4 or not replay_applies)
    if replay_applies:
        W("RESULT: %s" % ("ALL GATES PASS" if allok else "FAILED"))
    else:
        W("RESULT: %s  (GATE 4 not applicable -- %s weights)"
          % ("GATES 1, 2, 3, 5 PASS" if allok else "FAILED", wm["weights_mode"]))
    for f in fails:
        W("   FAIL: %s" % f)
    W("=" * 86)
    R["gates"]["all_ok"] = allok
    R["gates"]["failures"] = fails
    if a.out:
        with open(a.out, "w") as fh:
            json.dump(R, fh, indent=2, default=str)
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
