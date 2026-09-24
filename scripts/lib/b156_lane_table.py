#!/usr/bin/env python3
"""Lab B156 -- the per-lane table that decides whether BOTH lanes are busy.

Prints, per lane: events, distinct function names, and the top-N frames with the FIRST and
LAST timestamp of each.  That last column is the whole point: B153's artefact passed every
gate it had while hart 0's model work stopped at 11.09 s of a 55.04 s window and the rest of
the lane was arch_spin_relax and the UART.  A count of distinct functions cannot see that;
first/last per frame can.

PARSING.  scripts/lib/b153_disambiguate.py rewrites ONLY the lines whose names changed, with
json.dumps' default (spaced) separators, and leaves every other line compact.  So the file
holds two spellings of the same structure and a regex written for one of them silently reads
half of it.  Every line that looks like an object is handed to json.loads.
"""
import argparse
import collections
import json
import sys

# Frames that mean "this lane is NOT running its workload": the tracing harness's own spin,
# the console driver, and the idle thread's scheduler path.  B153's hart 0 spent 44 s of a
# 55 s window inside exactly these, and every gate it had still passed.
IDLE_FRAMES = (
    "arch_spin_relax", "z_impl_k_busy_wait", "sys_clock_cycle_get_32",
    "uart_sifive_poll_out", "char_out", "console_out", "printk", "vprintk",
    "z_smp_current_get", "sys_trace_idle_exit", "arch_cpu_idle", "z_check_stack_sentinel",
    "idle", "z_sched_ipi", "trail_entry",
)

# What "the model ran" means, in BOTH lanes: the ModelBlaster P-extension convolution
# helpers.  The image holds two copies under one name and scripts/lib/b153_disambiguate.py
# tags them [hw @addr] / [sw @addr] from the DISASSEMBLY, so this one substring is the
# detector's arithmetic on hart 0 and the spotter's on hart 1 without either lane being
# assumed.
MODEL_FRAME = "mb_pext_conv"


def self_time(path, nbuckets, span):
    """Per (pid, bucket): how much WALL TIME each frame is on top of the stack.

    WHY NOT COUNT EVENTS.  The first version of this gate ranked frames by B-event count and
    called hart 1 idle in the last second of the window -- while that lane was inside a
    1.30 s convolution.  One `mb_pext_conv_pixel` slice is 1.3 s of timeline and ONE event;
    `z_smp_current_get` is microseconds and thousands of them.  Counting events measures how
    BRANCHY a frame is, which is exactly what the trace RATE measures and exactly not what
    "the lane is busy" means.  Perfetto shows time, so the gate reads time.

    Attribution is to the top of the stack at each instant (self time), and an interval that
    crosses a bucket boundary is split across the buckets it covers.
    """
    import collections as _c
    st = _c.defaultdict(list)          # (pid, tid) -> stack of names
    last = {}                          # pid -> last ts seen on that lane
    bt = _c.defaultdict(lambda: _c.defaultdict(_c.Counter))
    mt = _c.defaultdict(_c.Counter)    # pid -> bucket -> time with a model frame on the stack
    tot = _c.defaultdict(_c.Counter)
    incl = _c.defaultdict(float)       # pid -> time with a MODEL_FRAME anywhere in the stack
    depth_model = _c.defaultdict(int)  # (pid, tid) -> how many model frames are on the stack

    def charge(pid, t0, t1, name, has_model):
        if t1 <= t0:
            return
        tot[pid][name] += t1 - t0
        if has_model:
            incl[pid] += t1 - t0
        b0 = int(t0 * nbuckets / span)
        b1 = int((t1 - 1) * nbuckets / span)
        for b in range(max(0, b0), min(nbuckets - 1, b1) + 1):
            lo = max(t0, b * span / nbuckets)
            hi = min(t1, (b + 1) * span / nbuckets)
            if hi > lo:
                bt[pid][b][name] += hi - lo
                if has_model:
                    mt[pid][b] += hi - lo

    with open(path) as fh:
        for line in fh:
            ln = line.strip().rstrip(",")
            if not ln.startswith("{") or not ln.endswith("}"):
                continue
            e = json.loads(ln)
            if e.get("ph") == "M":
                continue
            ts = e.get("ts")
            pid, tid = e.get("pid"), e.get("tid")
            if ts is None:
                continue
            key = (pid, tid)
            if pid in last:
                top = st[key][-1] if st[key] else "(outside any frame)"
                charge(pid, last[pid], ts, top, depth_model[key] > 0)
            last[pid] = ts
            if e.get("ph") == "B":
                st[key].append(e.get("name"))
                if MODEL_FRAME in (e.get("name") or ""):
                    depth_model[key] += 1
            elif e.get("ph") == "E":
                if st[key]:
                    nm = st[key].pop()
                    if MODEL_FRAME in (nm or ""):
                        depth_model[key] -= 1
    return bt, tot, incl, mt


def scan(path, nbuckets=0, span=None, occ=()):
    buckets = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    occs = collections.defaultdict(list)
    names = {}
    st = collections.defaultdict(lambda: dict(
        events=0, fn=collections.Counter(),
        first=collections.defaultdict(lambda: None),
        last=collections.defaultdict(lambda: None),
        ts_min=None, ts_max=None, first_ev=None, last_ev=None))
    with open(path) as fh:
        for line in fh:
            s = line.strip().rstrip(",")
            if not s.startswith("{") or not s.endswith("}"):
                continue
            e = json.loads(s)
            if e.get("ph") == "M":
                if e.get("name") in ("process_name", "thread_name"):
                    names[e.get("pid")] = e.get("args", {}).get("name", "")
                continue
            pid = e.get("pid")
            s_ = st[pid]
            s_["events"] += 1
            ts = e.get("ts")
            nm = e.get("name")
            if e.get("ph") in ("B", "X"):
                s_["fn"][nm] += 1
                if nbuckets and span and ts is not None:
                    b = min(nbuckets - 1, int(ts * nbuckets / span))
                    buckets[pid][b][nm] += 1
                if (pid, nm) in occ and ts is not None:
                    occs[(pid, nm)].append(ts)
                if ts is not None:
                    if s_["first"][nm] is None:
                        s_["first"][nm] = ts
                    s_["last"][nm] = ts
            elif e.get("ph") == "E" and ts is not None and nm in s_["last"]:
                s_["last"][nm] = ts
            if ts is None:
                continue
            if s_["ts_min"] is None or ts < s_["ts_min"]:
                s_["ts_min"] = ts
                s_["first_ev"] = (ts, nm)
            if s_["ts_max"] is None or ts > s_["ts_max"]:
                s_["ts_max"] = ts
                s_["last_ev"] = (ts, nm)
    return names, st, buckets, occs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--clk-hz", type=float, default=40e6)
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--match", action="append", default=[],
                    help="also report first/last over every frame whose name contains this")
    ap.add_argument("--buckets", type=int, default=0,
                    help="split the window into N equal buckets and print each lane's "
                         "dominant B-frame in each -- this is what catches a lane that is "
                         "busy overall but idle for half the run")
    ap.add_argument("--occurrences", action="append", default=[],
                    help="PID:NAME -- print the B timestamp of every occurrence, so a "
                         "per-unit cadence is read off the artefact rather than assumed")
    ap.add_argument("--gate-busy", action="store_true",
                    help="run B156's two gates: is every part of the window busy on BOTH "
                         "lanes, and does the two lanes' model work end together")
    ap.add_argument("--busy-max-run", type=int, default=1,
                    help="how many CONSECUTIVE buckets may be free of model work, after the "
                         "lane's first model frame, before the lane is called idle")
    ap.add_argument("--gap-pct", type=float, default=0.005,
                    help="a bucket with less than this fraction of its length inside the "
                         "model counts as a gap (default 0.5 %%)")
    ap.add_argument("--leadin-pct", type=float, default=0.25,
                    help="how much of the window the boot lead-in may take (default 25 %%)")
    ap.add_argument("--ends-together-pct", type=float, default=15.0)
    ap.add_argument("--ends-late-pct", type=float, default=20.0)
    ap.add_argument("--json-out")
    a = ap.parse_args()

    occ = set()
    for spec in a.occurrences:
        pid_s, nm = spec.split(":", 1)
        occ.add((int(pid_s), nm))
    span = None
    if a.gate_busy and not a.buckets:
        a.buckets = 13
    if a.buckets:
        _, st0, _, _ = scan(a.trace)
        span = max(v["ts_max"] for v in st0.values()) + 1
    names, st, buckets, occs = scan(a.trace, a.buckets, span, occ)
    hz = a.clk_hz
    R = {"trace": a.trace, "lanes": {}}
    print("=" * 96)
    print("B156  PER-LANE TABLE  --  %s" % a.trace)
    print("=" * 96)
    print("  %-4s %-40s %10s %10s %10s %10s" % ("pid", "lane", "events", "distinct",
                                                "first_s", "last_s"))
    for pid in sorted(st):
        s = st[pid]
        print("  %-4d %-40s %10d %10d %10.2f %10.2f"
              % (pid, (names.get(pid) or "")[:40], s["events"], len(s["fn"]),
                 s["ts_min"] / hz, s["ts_max"] / hz))
        R["lanes"][pid] = dict(name=names.get(pid), events=s["events"],
                               distinct=len(s["fn"]),
                               ts_min=s["ts_min"], ts_max=s["ts_max"],
                               first_ev=s["first_ev"], last_ev=s["last_ev"])
    for pid in sorted(st):
        s = st[pid]
        print("")
        print("  pid %d  %s" % (pid, names.get(pid)))
        print("      first event  %10.3f s  %s" % (s["first_ev"][0] / hz, s["first_ev"][1]))
        print("      last  event  %10.3f s  %s" % (s["last_ev"][0] / hz, s["last_ev"][1]))
        print("      %10s  %10s %10s  %s" % ("B-events", "first_s", "last_s", "frame"))
        top = []
        for nm, c in s["fn"].most_common(a.top):
            print("      %10d  %10.2f %10.2f  %s" % (c, s["first"][nm] / hz,
                                                     s["last"][nm] / hz, nm))
            top.append(dict(name=nm, count=c, first=s["first"][nm], last=s["last"][nm]))
        R["lanes"][pid]["top"] = top
        for pat in a.match:
            hits = [(nm, c) for nm, c in s["fn"].items() if pat in nm]
            if not hits:
                continue
            n = sum(c for _, c in hits)
            f = min(s["first"][nm] for nm, _ in hits)
            l = max(s["last"][nm] for nm, _ in hits)
            print("      %10d  %10.2f %10.2f  [match %r over %d name(s)]"
                  % (n, f / hz, l / hz, pat, len(hits)))
            R["lanes"][pid].setdefault("match", {})[pat] = dict(
                count=n, first=f, last=l, names=len(hits))
    if a.buckets:
        print("")
        print("  DOMINANT FRAME PER %d-BUCKET SLICE OF THE WINDOW (%.2f s each)"
              % (a.buckets, span / hz / a.buckets))
        for pid in sorted(buckets):
            print("    pid %d  %s" % (pid, names.get(pid)))
            for b in range(a.buckets):
                c = buckets[pid][b]
                if not c:
                    print("      [%6.2f-%6.2f s]  (no B events)"
                          % (b * span / a.buckets / hz, (b + 1) * span / a.buckets / hz))
                    continue
                nm, n = c.most_common(1)[0]
                tot = sum(c.values())
                print("      [%6.2f-%6.2f s]  %7d ev  %3d%%  %s"
                      % (b * span / a.buckets / hz, (b + 1) * span / a.buckets / hz,
                         tot, 100 * n // tot, nm))
            R["lanes"].setdefault(pid, {})["buckets"] = [
                dict(b=b, total=sum(buckets[pid][b].values()),
                     top=buckets[pid][b].most_common(1)) for b in range(a.buckets)]
    for (pid, nm), ts in sorted(occs.items()):
        print("")
        print("  pid %d  occurrences of %s: %d" % (pid, nm, len(ts)))
        prev = None
        for i, t in enumerate(ts):
            print("      %4d  %10.3f s   %s" % (i, t / hz,
                  ("+%.3f s" % ((t - prev) / hz)) if prev is not None else ""))
            prev = t
        R.setdefault("occurrences", {})["%d:%s" % (pid, nm)] = ts
    if a.gate_busy:
        fails = []
        bt, tot, incl, mt = self_time(a.trace, a.buckets, span)
        print("")
        print("=" * 96)
        print("B156  DOMINANT FRAME PER BUCKET BY TIME ON THE TIMELINE, NOT BY EVENT COUNT")
        print("-" * 96)
        for pid in sorted(bt):
            print("    pid %d  %s" % (pid, names.get(pid)))
            for b in range(a.buckets):
                c = bt[pid][b]
                if not c:
                    print("      [%6.2f-%6.2f s]  (nothing charged)"
                          % (b * span / a.buckets / hz, (b + 1) * span / a.buckets / hz))
                    continue
                nm, t = c.most_common(1)[0]
                tt = sum(c.values())
                print("      [%6.2f-%6.2f s]  %3d%%  %s"
                      % (b * span / a.buckets / hz, (b + 1) * span / a.buckets / hz,
                         100 * t // tt, nm))
        print("")
        print("  per-lane coverage over the whole window:")
        for pid in sorted(tot):
            idle = sum(v for k, v in tot[pid].items()
                       if any(f == k or f in k for f in IDLE_FRAMES))
            allt = sum(tot[pid].values())
            print("      pid %d   inside %-14s %5.1f%%   top-of-stack is spin/console/idle "
                  "%5.1f%%   (%.2f s charged)"
                  % (pid, MODEL_FRAME, 100.0 * incl[pid] / allt, 100.0 * idle / allt,
                     allt / hz))
            R["lanes"][pid]["model_time_pct"] = 100.0 * incl[pid] / allt
            R["lanes"][pid]["idle_time_pct"] = 100.0 * idle / allt
        print("")
        print("=" * 96)
        print("B156  GATE A  MODEL WORK IN EVERY PART OF THE WINDOW, ON BOTH LANES")
        print("-" * 96)
        print("  measured as TIME with a %s frame on the stack, per bucket.  A bucket with"
              % MODEL_FRAME)
        print("  less than %.1f%% of its length inside the model is a GAP; the gate fails on a"
              % (100 * a.gap_pct))
        print("  run of more than %d consecutive gap buckets AFTER the lane's first model frame."
              % a.busy_max_run)
        print("  The LEAD-IN -- the buckets before that first frame -- is the boot and the")
        print("  sensors coming up, which this trace covers deliberately; it is reported, and")
        print("  failed only if it eats more than %.0f%% of the window." % (100 * a.leadin_pct))
        bw = span / a.buckets
        for pid in sorted(bt):
            gaps = [b for b in range(a.buckets) if mt[pid][b] < a.gap_pct * bw]
            first = next((b for b in range(a.buckets) if mt[pid][b] >= a.gap_pct * bw), None)
            lead = 0
            while lead < a.buckets and mt[pid][lead] < a.gap_pct * bw:
                lead += 1
            runs, cur = [], 0
            for b in range(lead, a.buckets):
                if mt[pid][b] < a.gap_pct * bw:
                    cur += 1
                else:
                    if cur:
                        runs.append((b - cur, cur))
                    cur = 0
            if cur:
                runs.append((a.buckets - cur, cur))
            worst = max((n for _, n in runs), default=0)
            print("    pid %d  lead-in %d bucket(s) (%.2f s, %.0f%%);  gap runs after it: %s;"
                  "  longest %d (%.2f s, %.0f%%)"
                  % (pid, lead, lead * bw / hz, 100.0 * lead / a.buckets,
                     ", ".join("[%.2f-%.2f s]x%d" % (st_ * bw / hz, (st_ + n) * bw / hz, n)
                               for st_, n in runs) or "none",
                     worst, worst * bw / hz, 100.0 * worst / a.buckets))
            print("           model time per bucket: %s"
                  % " ".join("%.0f%%" % (100.0 * mt[pid][b] / bw) for b in range(a.buckets)))
            R["lanes"][pid]["leadin_buckets"] = lead
            R["lanes"][pid]["gap_runs"] = runs
            R["lanes"][pid]["model_pct_per_bucket"] = [100.0 * mt[pid][b] / bw
                                                       for b in range(a.buckets)]
            if worst > a.busy_max_run:
                fails.append("pid %d does no model work for %d consecutive buckets (%.2f s, "
                             "%.0f%% of the window)"
                             % (pid, worst, worst * bw / hz, 100.0 * worst / a.buckets))
            if lead > a.leadin_pct * a.buckets:
                fails.append("pid %d's lead-in is %.2f s (%.0f%% of the window)"
                             % (pid, lead * bw / hz, 100.0 * lead / a.buckets))
        okA = not fails
        print("  => GATE A %s" % ("PASS" if okA else "FAIL"))

        print("")
        print("B156  GATE B  BOTH LANES' MODEL WORK ENDS TOGETHER, AT THE END OF THE WINDOW")
        print("-" * 96)
        last, first = {}, {}
        for pid in sorted(st):
            hits = [nm for nm in st[pid]["fn"] if MODEL_FRAME in nm]
            if not hits:
                fails.append("pid %d has no %s frame at all" % (pid, MODEL_FRAME))
                continue
            first[pid] = min(st[pid]["first"][nm] for nm in hits)
            last[pid] = max(st[pid]["last"][nm] for nm in hits)
            print("    pid %d  %-12s first %8.2f s   last %8.2f s   "
                  "gap to window end %6.2f s (%.0f%%)"
                  % (pid, MODEL_FRAME, first[pid] / hz, last[pid] / hz,
                     (span - last[pid]) / hz, 100.0 * (span - last[pid]) / span))
            R["lanes"][pid]["model_first"] = first[pid]
            R["lanes"][pid]["model_last"] = last[pid]
            if 100.0 * (span - last[pid]) / span > a.ends_late_pct:
                fails.append("pid %d's model work stops %.2f s (%.0f%%) before the window "
                             "closes" % (pid, (span - last[pid]) / hz,
                                         100.0 * (span - last[pid]) / span))
        if len(last) == 2:
            d = abs(last[0] - last[1])
            print("    |last[0] - last[1]| = %.2f s = %.1f%% of the %.2f s window "
                  "(limit %.0f%%)" % (d / hz, 100.0 * d / span, span / hz,
                                      a.ends_together_pct))
            R["ends_together_s"] = d / hz
            R["ends_together_pct"] = 100.0 * d / span
            if 100.0 * d / span > a.ends_together_pct:
                fails.append("the two lanes' model work ends %.2f s apart (%.0f%% of the "
                             "window)" % (d / hz, 100.0 * d / span))
        okB = not [f for f in fails if "model work" in f or "apart" in f or MODEL_FRAME in f]
        print("  => GATE B %s" % ("PASS" if okB else "FAIL"))
        print("=" * 96)
        print("RESULT: %s" % ("BOTH B156 GATES PASS" if not fails else "FAILED"))
        for f in fails:
            print("   FAIL: %s" % f)
        print("=" * 96)
        R["gates"] = dict(busy_ok=okA, ends_together_ok=okB, failures=fails)
        if fails:
            if a.json_out:
                with open(a.json_out, "w") as fh:
                    json.dump(R, fh, indent=2, default=str)
            return 1
    print("")
    if a.json_out:
        with open(a.json_out, "w") as fh:
            json.dump(R, fh, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
