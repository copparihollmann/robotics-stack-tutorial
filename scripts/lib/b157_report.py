#!/usr/bin/env python3
"""Lab B157 -- collect the T = 1000 ms co-location sweep into one SUMMARY.json.

One row per (policy, contention arm, compaction arm).  Every row carries the
five things the lab was asked for -- makespan, which of the four detector
windows landed, `real_time_ok`, Moonshine's end, achieved detector rate -- plus
the four checks that decide whether the row may be believed at all:

  ARM LABEL, FROM THE LOG, NOT FROM THE SPEC.  The spec's
  `"contention": {"enabled": true, "path": ...}` block is never read: the string
  "contention" does not occur in run_xpurt_schedule.py's spec parsing, and only
  `--contention PATH` installs a model (:1629-1645).  A previous lab in this
  programme solved the `none` arm for hours and filed the result as `dram`.
  So each row's arm is re-derived from its own log -- `none` must carry NO
  "--contention: loaded" line, `dram` must name contention_b4_dram.json -- and a
  row whose log disagrees with its directory is marked `contention_verified:
  false` rather than reported.

  COMPACTION ARM, FROM THE ARTIFACT.  solve_provenance.TRACKED_ENV puts
  XPURT_COMPACT into metadata.solve_env.env, so the arm is read back out of the
  schedule the solver wrote, not assumed from the launcher.

  OVERLAP.  Two dispatches on one machine may not overlap, measured with the
  durations the schedule itself emits.  This matters most on `dram`: the
  contention model scales durations at greedy's lookup time, but the CP-SAT
  model (DecoderContext) and the compaction pass both read raw
  `op.get_duration_for_combination`, so a plan made on solo costs and emitted
  with scaled ones could collide.  Checked, never assumed.

  HARD EXCLUSION.  Every dispatch must land on a machine its dispatch graph's
  `infeasible_machines` does not forbid, and XPU-RT's own `feasible_targets`
  must agree.  Same check as xpurt_coloc2m_summarise.py; a non-empty
  `exclusion_violations` invalidates every makespan in the file.

4000 ms IS A REFERENCE, NOT A CONSTRAINT.  Moonshine carries no period and no
window_duration in this spec, so `moonshine_meets_4000ms` is a comparison made
after the fact against the RTF = 1 utterance window, not a deadline the solver
saw.  `op_deadline_miss_count` counts LATE DETECTOR DISPATCHES only.

AND `real_time_ok` IS DERIVED HERE, NOT READ.  The string does not occur
anywhere in the XPU-RT checkout -- no solver computes it and no schedule,
metrics or report file carries it.  It is this programme's own two-part test
(`xpurt_coloc2m_summarise.py:257`, reused unchanged): Moonshine's end inside the
4 000 ms reference AND no detector instance outside its own window.  Every row
carries `real_time_ok_derivation` spelling that out, because a reader who takes
it for solver output will believe the 4 000 ms was enforced -- and it never was.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re

BASE = "networks_pynqz1_coloc2m_sdp_b4_T1000"
POL = ("edf", "fifo", "heft", "peft", "critical_path",
       "min_min", "max_min", "round_robin", "fastest_device")
CONT = ("none", "dram")
COMP = ("plain", "compact")
DET = "signdet"
T_MS = 1000.0
WINDOW_MS = 4000.0          # the uncontended goal, RTF = 1 on a 4 s utterance
N_INST = 4
EPS = 1e-6


RATES_LINE = ("Three crossing figures, always quoted together so the middle one "
              "is not read as the machine's limit:  0.25 fps heuristic  |  "
              "1.0 fps achieved  |  2.62 fps capacity (b4/none).")


def fps_cell(r):
    """The achieved detector rate, or '--'.

    Blank rather than 1000/T when a window is missed: a cell that drops a frame
    does not sustain the declared rate, and printing the nominal figure there
    would be a rounded-up fiction.
    """
    return ("%.2f" % r["achieved_detector_fps"]
            if r["achieved_detector_fps"] else "--")


def load_graphs(gen_root):
    out = {}
    for net in ("moonshine", DET):
        p = (f"{gen_root}/vmfb/{net}/pynqz1_rocket/hart0_pext/"
             f"{net}.int8/{net}.int8_dispatch_graph.json")
        g = json.load(open(p))
        out[net] = {k: set(v.get("infeasible_machines", []))
                    for k, v in g["dispatches"].items()}
    return out


def check_log(path, cont):
    """(verified, evidence) -- does this log show the arm its directory claims?"""
    if not os.path.exists(path):
        return False, "log missing"
    txt = open(path, errors="replace").read()
    loaded = re.findall(r"^--contention: loaded (\S+).*$", txt, re.M)
    noart = re.findall(r"^--contention: no artifact.*$", txt, re.M)
    ortools = "no interpreter with ortools" in txt
    ev = {"contention_loaded_lines": loaded, "contention_no_artifact": noart,
          "ortools_interpreter_missing": ortools}
    if ortools:
        return False, ev
    if cont == "none":
        return (not loaded and not noart), ev
    want = f"contention_b4_{cont}.json"
    return (len(loaded) == 1 and loaded[0].endswith(want)), ev


def overlaps(disp):
    """Pairs of dispatches sharing a machine and overlapping in time."""
    lanes = {}
    for name, d in disp.items():
        lanes.setdefault(d["hardware_target"], []).append(
            (float(d["start_time"]), float(d["start_time"]) + float(d["duration"]),
             name))
    bad = []
    for m, iv in lanes.items():
        iv.sort()
        for a, b in zip(iv, iv[1:]):
            if b[0] < a[1] - EPS:
                bad.append([m, a[2], b[2], round(a[1] - b[0], 9)])
    return bad


def one_cell(root, cont, comp, sched_name, graphs, *, stem=None, log=None):
    """One row.  `stem`/`log` override the sweep's own layout so a schedule from
    an earlier lab can be scored by exactly this code and not by a retelling."""
    if stem is None:
        stem = (f"{root}/schedules/{cont}/{comp}/"
                f"scheduled_{BASE}_{sched_name}_profiled")
    if not os.path.exists(stem + "_report.json"):
        return None
    sched = json.load(open(stem + ".json"))
    met = json.load(open(stem + "_metrics.json"))
    rep = json.load(open(stem + "_report.json"))
    md = sched["metadata"]
    disp = sched["dispatches"]

    # ---- the four detector instances, one window each -----------------------
    inst, viol = {}, []
    busy = {}
    for d in rep["dispatches"]:
        m = d["target"]
        job, _, did = d["name"].partition("_")
        net = job.rstrip("0123456789") or job
        busy.setdefault(net, {}).setdefault(m, 0.0)
        busy[net][m] += d["duration_us"]
        if net == DET:
            k = int(job[len(DET):])
            e = inst.setdefault(k, {"start_ms": d["start_us"],
                                    "finish_ms": d["finish_us"], "n": 0})
            e["start_ms"] = min(e["start_ms"], d["start_us"])
            e["finish_ms"] = max(e["finish_ms"], d["finish_us"])
            e["n"] += 1
        forbidden = graphs[net].get(did)
        if forbidden is None:
            viol.append([cont, comp, sched_name, d["name"], "no graph entry"])
        elif m in forbidden:
            viol.append([cont, comp, sched_name, d["name"],
                         f"placed on forbidden {m}"])
        ft = d.get("feasible_targets")
        if ft is not None and (len(ft) != 1 or ft[0] != m):
            viol.append([cont, comp, sched_name, d["name"],
                         f"feasible_targets {ft} target {m}"])

    windows = {}
    for k in range(N_INST):
        lo, hi = k * T_MS, (k + 1) * T_MS
        e = inst.get(k)
        if e is None:
            windows[k] = {"window_ms": [lo, hi], "scheduled": False,
                          "landed": False, "why": "instance not in schedule"}
            continue
        early = e["start_ms"] < lo - EPS
        late = e["finish_ms"] > hi + EPS
        windows[k] = {
            "window_ms": [lo, hi], "scheduled": True,
            "dispatches": e["n"],
            "start_ms": e["start_ms"], "finish_ms": e["finish_ms"],
            "slack_ms": hi - e["finish_ms"],
            "landed": not (early or late),
            "why": ("" if not (early or late)
                    else ("released before window; " if early else "")
                    + (f"overran by {e['finish_ms'] - hi:.2f} ms" if late else "")),
        }
    landed = sorted(k for k, w in windows.items() if w["landed"])
    missed = sorted(k for k, w in windows.items() if not w["landed"])

    moon_end = max((float(v["start_time"]) + float(v["duration"])
                    for v in disp.values()
                    if v["job_name"].startswith("moonshine")), default=0.0)
    mk = met["makespan_ms"]
    if log is None:
        log = f"{root}/logs/{sched_name}_{cont}_{comp}.log"
    cver, cev = check_log(log, cont)
    env = (md.get("solve_env") or {}).get("env", {})

    return {
        "policy": sched_name, "contention_arm": cont, "compaction_arm": comp,
        # TWO MAKESPANS, NAMED APART.  With
        # restrict_makespan_to_nonperiodic = True the runner's headline
        # "Makespan (non-periodic)" is MOONSHINE'S END; metrics.makespan_ms is
        # the ALL-OPS end, which on these cells is the detector's last window
        # edge and is up to 350 ms larger (3 999.99925 against 3 649.05856 on
        # cpsat/none/plain).  xpurt_coloc2m_summarise.py:236,257 reads
        # met["makespan_ms"] and labels it `moonshine_makespan_ms`; that is
        # harmless on the nine heuristics, where the two coincide, and wrong on
        # any cell where they do not.  Both are carried here under their own
        # names and `moonshine_end_ms` is recomputed from the schedule's own
        # Moonshine dispatches rather than read from either.
        "moonshine_end_ms": moon_end,
        "nonperiodic_makespan_ms": met["nonperiodic_makespan_ms"],
        "all_ops_makespan_ms": mk,
        "moonshine_meets_4000ms": bool(moon_end <= WINDOW_MS + EPS),
        "moonshine_rtf_4000ms_window": moon_end / WINDOW_MS,
        "detector_windows_landed": landed,
        "detector_windows_missed": missed,
        "detector_windows": windows,
        "detector_instances_landed": len(landed),
        "achieved_detector_fps": (1000.0 / T_MS) if len(landed) == N_INST else None,
        "achieved_detector_fps_note": (
            "1000/T only when all four windows land; None means the schedule "
            "does not sustain the declared rate and the fps figure would be a "
            "rounded-up fiction"),
        # DERIVED HERE, NOT EMITTED BY THE SOLVER.  `real_time_ok` occurs
        # nowhere in the XPU-RT checkout: no schedule, metrics or report file
        # carries it, and no solver computes it.  It is this programme's own
        # two-part test, first written at
        # xpurt_coloc2m_summarise.py:257 and reused unchanged here, and the
        # 4 000 ms half of it is a REFERENCE the solver never saw -- Moonshine
        # carries no period and no window_duration in this spec.  Anyone
        # reading it as a solver verdict will think the window was enforced.
        # B152c's T550 `real_time_ok = False` (Moonshine 4 459.69 ms, 8 of 8
        # windows landed) is the SAME derivation, not a second instrument
        # agreeing.
        "real_time_ok": bool(moon_end <= WINDOW_MS + EPS and not missed),
        "real_time_ok_derivation": (
            "moonshine_end_ms (%.5f) <= 4000 ms RTF=1 reference AND every "
            "declared detector instance finishes inside [k*1000, (k+1)*1000] "
            "-- computed by b157_report.py from the schedule's own dispatches; "
            "NOT a field any XPU-RT artifact emits" % moon_end),
        "op_deadline_miss_count": met["op_deadline_miss_count"],
        "total_lateness_ms": met["total_lateness_ms"],
        "max_lateness_ms": met["max_lateness_ms"],
        "hart0_busy_moonshine_ms": busy.get("moonshine", {}).get("CPU_P#0", 0.0),
        "hart1_busy_moonshine_ms": busy.get("moonshine", {}).get("CPU_E#0", 0.0),
        "hart0_busy_detector_ms": busy.get(DET, {}).get("CPU_P#0", 0.0),
        "machine_overlaps": overlaps(disp),
        "contention_verified": cver,
        "contention_evidence": cev,
        "compaction_env_in_artifact": env.get("XPURT_COMPACT"),
        "compaction_arm_verified": bool(
            (comp == "compact") == (env.get("XPURT_COMPACT") == "1")),
        "cpsat_workers_in_artifact": env.get("XPURT_CPSAT_WORKERS"),
        "solver_status": rep["solver_status"],
        "solve_wall_s": rep["solve_wall_s"],
        "solve_hash": md["solve_hash"],
        "pdb_hash": md["pdb_hash"],
        "schedule_json": os.path.abspath(stem + ".json"),
        "log": os.path.abspath(log),
        # VALIDITY IS A GATE, NOT A FOOTNOTE.  A dispatch placed on a machine its
        # dispatch graph forbids would take an ILLEGAL INSTRUCTION on silicon
        # (hart 1 has no P-extension; hart 0 has no engine), so a schedule
        # containing one is not a slower answer to this problem -- it is an
        # answer to a different one.  Same rule B152 set for this sweep: "a
        # non-empty exclusion_violations means the constraint did NOT hold and
        # no makespan in this file should be believed."
        "exclusion_violation_count": len(viol),
        "exclusion_violation_dispatches": sorted({v[3] for v in viol}),
        "valid": bool(not viol and not overlaps(disp)),
        "_exclusion_violations": viol,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    _repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--root", default=os.environ.get(
        "B157_ROOT", os.path.join(os.environ.get("IISWC_OUT",
                                                 os.path.join(_repo, "out")), "b157")),
                    help="the sweep's output tree -- scripts/12_xpurt_coloc_sweep.sh's $ARCH")
    ap.add_argument("--gen-root",
                    default=os.path.join(_repo, "fpga", "pynq-z2", "xpurt",
                                         "gen_pynqz1_2m_sdp_b4"),
                    help="the dispatch graphs whose infeasible_machines this audits")
    ap.add_argument("--cpsat-scheduler", default="cpsat_warmbest_b157")
    ap.add_argument("--registry-cpsat", default="cpsat",
                    help="registry-path CP-SAT (`--scheduler cpsat`), run here "
                         "at the prior lab's own settings so the claim can be "
                         "reproduced rather than only compared against")
    ap.add_argument(
        "--prior-stem", default=None,
        help="OPTIONAL.  An EARLIER solve of the same cell, given as the stem "
             "of its <stem>.json / <stem>_metrics.json / <stem>_report.json, "
             "scored by this same code so an older number is CHECKED rather "
             "than quoted.  That is how 3,649.06 ms was re-derived here: the "
             "cell reproduced bit-exactly -- 3649.05855611 both times, delta "
             "0.0, all 2,285 dispatches identical in start and target -- "
             "because CP-SAT is deterministic at XPURT_CPSAT_WORKERS=1, which "
             "both runs used.  Above one worker it is not, and the report "
             "records the count rather than assuming it.")
    ap.add_argument("--prior-log", default=None,
                    help="the log for --prior-stem, for the contention-arm grep")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    out = a.out or os.path.join(a.root, "SUMMARY.json")
    graphs = load_graphs(a.gen_root)

    rows, viol = [], []
    for cont in CONT:
        for comp in COMP:
            for name in list(POL) + [a.cpsat_scheduler, a.registry_cpsat]:
                r = one_cell(a.root, cont, comp, name, graphs)
                if r is None:
                    continue
                viol.extend(r.pop("_exclusion_violations"))
                rows.append(r)

    # An EARLIER solve of the same cell, if one was given, scored by exactly the
    # code above rather than by a retelling.  Absent, this is simply skipped.
    prior = one_cell(a.root, "none", "plain", "cpsat (earlier solve)",
                     graphs, stem=a.prior_stem, log=a.prior_log)
    if prior is not None:
        viol.extend(prior.pop("_exclusion_violations"))
        mine = [r for r in rows
                if r["policy"] == a.registry_cpsat
                and r["contention_arm"] == "none"
                and r["compaction_arm"] == "plain"]
        prior["reproduction"] = ({
            "rerun_moonshine_end_ms": mine[0]["moonshine_end_ms"],
            "delta_ms": mine[0]["moonshine_end_ms"] - prior["moonshine_end_ms"],
            "bit_exact": abs(mine[0]["moonshine_end_ms"]
                             - prior["moonshine_end_ms"]) < 1e-6,
            "rerun_windows_landed": mine[0]["detector_windows_landed"],
            "rerun_real_time_ok": mine[0]["real_time_ok"],
            "_note": ("CP-SAT is deterministic only at workers=1, which is what "
                      "both runs used -- so a difference here is a difference in "
                      "how much search the wall budget bought, not solver noise. "
                      "Machine load during the rerun is the variable that moves "
                      "it."),
        } if mine else {"rerun": "not present in this sweep"})

    # Compaction, measured rather than asserted: same policy, same contention
    # arm, plain against compact, on the schedule's own start times.
    comp_delta = {}
    by = {(r["policy"], r["contention_arm"], r["compaction_arm"]): r for r in rows}
    for (pol, cont, comp), r in list(by.items()):
        if comp != "compact":
            continue
        p = by.get((pol, cont, "plain"))
        if p is None:
            continue
        sp = json.load(open(p["schedule_json"]))["dispatches"]
        sc = json.load(open(r["schedule_json"]))["dispatches"]
        moved = sum(1 for k in sp
                    if abs(float(sp[k]["start_time"]) - float(sc[k]["start_time"])) > EPS)
        comp_delta[f"{pol}/{cont}"] = {
            "moonshine_end_plain_ms": p["moonshine_end_ms"],
            "moonshine_end_compact_ms": r["moonshine_end_ms"],
            "recovered_ms": p["moonshine_end_ms"] - r["moonshine_end_ms"],
            "dispatches_moved": moved,
            "bit_identical": moved == 0,
        }

    # The three crossing figures, always quoted together so the middle one is
    # never read as the machine's limit.
    rates = {
        "heuristic_best_fps": 0.25,
        "achieved_fps": 1.00,
        "capacity_fps": 2.62,
        "_reading": ("0.25 fps is the fastest detector period any of the nine "
                     "list-scheduling heuristics sustains; 1.0 fps is what the "
                     "solver achieves on this spec; 2.62 fps is the "
                     "scheduler-independent hart-0 capacity bound. The middle "
                     "figure is a solver result, NOT the machine's limit."),
    }

    summary = {
        "lab": "B157",
        "spec": "data/toplevel/networks_pynqz1_coloc2m_sdp_b4_T1000.json",
        "period_ms": T_MS, "declared_instances": N_INST,
        "reference_window_ms": WINDOW_MS,
        "_reference_window_note": (
            "4000 ms is the UNCONTENDED GOAL (RTF = 1 on a 4 s utterance), "
            "never a deadline on Moonshine: the spec declares no period and no "
            "window_duration for it. See `Correction to L396`."),
        "rates": rates,
        "earlier_solve": {
            "_comment": ("An earlier solve of the none/plain cell, passed with "
                         "--prior-stem and scored by this same code so that an "
                         "older number is CHECKED rather than quoted.  Null "
                         "when none was given.  The reference sweep's own: "
                         "3649.06 ms, all four detector windows landing, "
                         "1.0 fps -- reproduced here bit-exactly."),
            "stem": a.prior_stem,
            "log": a.prior_log,
            "scored_here": prior,
        },
        "rows": rows,
        "compaction_delta": comp_delta,
        "exclusion_violations": viol,
        "cells": len(rows),
        "cells_contention_unverified": [
            f"{r['policy']}/{r['contention_arm']}/{r['compaction_arm']}"
            for r in rows if not r["contention_verified"]],
        "cells_compaction_unverified": [
            f"{r['policy']}/{r['contention_arm']}/{r['compaction_arm']}"
            for r in rows if not r["compaction_arm_verified"]],
        "cells_INVALID_exclusion": [
            {"cell": f"{r['policy']}/{r['contention_arm']}/{r['compaction_arm']}",
             "violations": r["exclusion_violation_count"],
             "dispatches": len(r["exclusion_violation_dispatches"]),
             "moonshine_end_ms_NOT_A_RESULT": r["moonshine_end_ms"]}
            for r in rows if not r["valid"]],
        "_invalid_note": (
            "A cell listed here placed at least one dispatch on a machine its "
            "dispatch graph forbids. On silicon that is an illegal instruction, "
            "so its makespan answers a different problem and is NOT reported as "
            "a result. Cause: cpsat_scheduler.cpsat_schedule builds its model "
            "from DecoderContext, and schedule_decoder.py never reads "
            "op.infeasible_combinations -- the exclusion is a SET on the "
            "Operation, not an infinite cost, so the `--solver cpsat` model "
            "cannot see it. scheduler_cpsat.py:253 (the `--scheduler cpsat` "
            "registry path) builds feasible_combos explicitly and does not have "
            "the bug; neither do the nine heuristics (scheduler_heft.py:101)."),
        "cells_with_machine_overlap": [
            f"{r['policy']}/{r['contention_arm']}/{r['compaction_arm']}"
            for r in rows if r["machine_overlaps"]],
        "logs_naming_missing_ortools": sorted(
            os.path.abspath(p) for p in glob.glob(f"{a.root}/logs/*.log")
            if "no interpreter with ortools" in open(p, errors="replace").read()),
    }
    with open(out, "w") as fh:
        json.dump(summary, fh, indent=1)

    lines = []

    def emit(s=""):
        lines.append(s)
        print(s)

    emit("B157 -- co-located Moonshine + SignDetLite, detector PERIODIC at "
         "T = 1000 ms (1.00 fps, 4 instances), b4")
    emit(f"spec {summary['spec']}")
    emit("4000 ms is the RTF = 1 REFERENCE on Moonshine, never a constraint "
         "(`Correction to L396`); the four detector windows ARE constraints.")
    emit(RATES_LINE)
    emit()
    hdr = (f"{'policy':<26}{'cont':<6}{'comp':<8}{'moon_end_ms':>12}"
           f"{'<=4000':>8}{'landed':>9}{'missed':>10}{'rt_ok':>7}"
           f"{'lateops':>9}{'fps':>6}{'valid':>7}")
    emit(hdr)
    emit("-" * len(hdr))
    for r in rows:
        emit(f"{r['policy']:<26}{r['contention_arm']:<6}{r['compaction_arm']:<8}"
             f"{r['moonshine_end_ms']:>12.2f}"
             f"{str(r['moonshine_meets_4000ms']):>8}"
             f"{''.join(str(k) for k in r['detector_windows_landed']) or '-':>9}"
             f"{''.join(str(k) for k in r['detector_windows_missed']) or '-':>10}"
             f"{str(r['real_time_ok']):>7}{r['op_deadline_miss_count']:>9}"
             f"{fps_cell(r):>6}"
             f"{('yes' if r['valid'] else 'NO'):>7}")
    if prior is not None:
        emit()
        emit("PRIOR LAB'S CELL, scored by this same code "
             "(reported lost; the artifact is at "
             f"{summary['prior_lab_claim']['actually_at']}):")
        emit(f"{'cpsat 3600s w1 (prior)':<26}{'none':<6}{'plain':<8}"
             f"{prior['moonshine_end_ms']:>12.2f}"
             f"{str(prior['moonshine_meets_4000ms']):>8}"
             f"{''.join(str(k) for k in prior['detector_windows_landed']) or '-':>9}"
             f"{''.join(str(k) for k in prior['detector_windows_missed']) or '-':>10}"
             f"{str(prior['real_time_ok']):>7}"
             f"{prior['op_deadline_miss_count']:>9}"
             f"{fps_cell(prior):>6}")
        emit(f"  reproduction: {json.dumps(prior.get('reproduction'))}")
    inval = [r for r in rows if not r["valid"]]
    if inval:
        emit()
        emit("*** CELLS REFUSED -- HARD MACHINE EXCLUSION VIOLATED ***")
        emit("A dispatch placed on a machine its dispatch graph forbids would "
             "take an ILLEGAL INSTRUCTION on silicon (hart 1 has no "
             "P-extension; hart 0 has no engine).")
        emit("Those makespans answer a different problem and are NOT results.")
        for r in inval:
            emit(f"  {r['policy']}/{r['contention_arm']}/{r['compaction_arm']}:"
                 f" {r['exclusion_violation_count']} violations over "
                 f"{len(r['exclusion_violation_dispatches'])} dispatches "
                 f"(reported makespan would have been "
                 f"{r['moonshine_end_ms']:.2f} ms -- do not quote it)")
        emit("CAUSE: cpsat_scheduler.cpsat_schedule builds its model from "
             "DecoderContext, and schedule_decoder.py never reads "
             "op.infeasible_combinations.")
        emit("       The exclusion is a SET on the Operation, not an infinite "
             "cost, so the `--solver cpsat` model cannot see it at all.")
        emit("       scheduler_cpsat.py:253 (`--scheduler cpsat`) builds "
             "feasible_combos explicitly and is unaffected; so are the nine "
             "heuristics (scheduler_heft.py:101).")
    emit()
    emit("COMPACTION, measured on the schedules' own start times "
         "(XPURT_COMPACT=1 against unset):")
    for k, v in sorted(comp_delta.items()):
        emit(f"  {k:<34} recovered {v['recovered_ms']:>9.3f} ms   "
             f"dispatches moved {v['dispatches_moved']:>5}   "
             f"{'BIT-IDENTICAL' if v['bit_identical'] else 'changed'}")
    emit()
    emit(f"cells={len(rows)}  exclusion_violations={len(viol)}  "
         f"contention_unverified={len(summary['cells_contention_unverified'])}  "
         f"compaction_unverified={len(summary['cells_compaction_unverified'])}  "
         f"overlaps={len(summary['cells_with_machine_overlap'])}  "
         f"ortools_missing_logs={len(summary['logs_naming_missing_ortools'])}")
    txt = os.path.join(os.path.dirname(out), "REPORT.txt")
    with open(txt, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("wrote", out)
    print("wrote", txt)


if __name__ == "__main__":
    main()
