#!/usr/bin/env python3
"""Lab B157 -- the Gantt charts for the T = 1000 ms co-location cell.

CONVENTIONS ARE B155's, DELIBERATELY UNCHANGED.  Same primitive
(`plot_k1_evolution.draw_gantt_axis`, which is what
`scripts/plot_scheduled_json.py` itself calls), same figstyle sizes and
Okabe-Ito palette, same lane order and lane notes, same rule about which
vertical lines are constraints and which are references.  A chart that used a
different visual language from B155's would have to be re-read from scratch.

  fig 1  THE CELL.  Whichever solved cell lands all four detector windows with
         the earliest Moonshine end, on the two machines this SoC has, with the
         four detector windows drawn as the bands they are.
  fig 2  WHAT THE SOLVER BUYS.  The best of the nine list-scheduling heuristics
         that lands all four windows, against CP-SAT, on one x-axis.  The
         CP-SAT panel is the REGISTRY path (`--scheduler cpsat`): it is the only
         CP-SAT in this sweep whose schedules pass the hard-exclusion audit.

WHICH LINES ARE CONSTRAINTS AND WHICH ARE NOT -- the distinction B155 makes and
this lab must not blur:
  1000 / 2000 / 3000 / 4000 ms   CONSTRAINTS, and on the DETECTOR ONLY.
        SignDetLite is periodic at 1000 ms with window_duration 1000 ms and
        4 declared instances, so instance i must fit inside [i*1000, (i+1)*1000].
  4000 ms for MOONSHINE           A REFERENCE.  RTF = 1 on a 4 s utterance, the
        uncontended goal the answer is compared against AFTER the fact.  The
        spec gives Moonshine no period and no window_duration, so the solver
        never saw it.  See `Correction to L396` in docs/EXPERIMENT_LOG.md.

PREDICTED, NOT MEASURED.  The per-dispatch durations are board-measured
(Moonshine on 0x5A5A0035, SignDetLite on 0x5A5A0038, both 40.000 MHz); the
PLACEMENT is XPU-RT's and the runtime does not execute this plan.  B152d
demonstrated two-hart overlap at ONE interleave point on silicon and nothing
wider -- see `Correction to B152d`.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

# The figures are drawn with XPU-RT's OWN figure style and Gantt renderer, so that a
# plot from this lab and a plot from XPU-RT are the same plot.  That makes the checkout
# a hard requirement here, unlike b157_report.py, which needs nothing but the artifacts.
XPURT = os.environ.get("XPURT_ROOT", "")
if not XPURT or not os.path.isdir(os.path.join(XPURT, "scripts")):
    sys.exit("XPURT_ROOT is not set to an XPU-RT checkout -- these figures import its "
             "figstyle, plot_k1_evolution and schedule_trace so that they match its own. "
             "The numbers do not need it: scripts/lib/b157_report.py reads only the "
             "artifacts the sweep wrote.")
sys.path.insert(0, os.path.join(XPURT, "scripts"))
sys.path.insert(0, os.path.join(XPURT, "xpu-rt"))

import matplotlib                                              # noqa: E402
matplotlib.use("Agg")
import matplotlib.pyplot as plt                                # noqa: E402
from matplotlib.patches import Patch                           # noqa: E402

import figstyle                                                # noqa: E402
import plot_k1_evolution as gantt                              # noqa: E402
import schedule_trace                                          # noqa: E402

figstyle.use()
MM = figstyle.MM
DOUBLE = figstyle.DOUBLE_COL

_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ARCH = os.environ.get("B157_ROOT",
                      os.path.join(os.environ.get("IISWC_OUT",
                                                  os.path.join(_REPO, "out")), "b157"))
SPEC_NAME = "data/toplevel/networks_pynqz1_coloc2m_sdp_b4_T1000.json"
XLABEL = "Predicted time from PYNQ-Z1 Rocket board profiles (ms), 40.000 MHz"
INK = "#22252A"
MUTED = "#6B7280"
REFLINE = "#2F6FB0"            # a REFERENCE the answer is compared against
C_DDL = figstyle.C_DEADLINE    # a CONSTRAINT the solver had to satisfy
C_WIN = "#DCE9F5"              # detector window band
T_MS = 1000.0
N_INST = 4
GOAL_MS = 4000.0

LANES = ["CPU_E#0", "CPU_P#0"]
LANE_NOTE = {"CPU_P#0": "hart 0  (MBP P-extension, custom-0)",
             "CPU_E#0": "hart 1  (RoccMoon engine + lanes, custom-1)"}


# ---------------------------------------------------------------- helpers
def load(path):
    with open(path) as f:
        return json.load(f)


def lane_labels(ax, *, gutter_hi=1.3, gutter_lo=1.3):
    """Native lane labels plus drawn-in gutters for annotation.

    `draw_gantt_axis` sizes the y-axis to the lanes exactly, leaving no room for
    a caption; the gutters are whitespace, not extra lanes -- `set_yticks` still
    names only the two machines.  Same helper as B155's.
    """
    ax.set_yticks(range(len(LANES)))
    ax.set_yticklabels([LANE_NOTE[c] for c in LANES], fontsize=4.6)
    ax.set_ylim(len(LANES) - 1 + gutter_lo, -gutter_hi)   # stays inverted


def gutter(ax, x, y, text, *, color=INK, ha="left", va="top", size=4.4,
           box=False):
    ax.text(x, y, text, fontsize=size, color=color, ha=ha, va=va, zorder=8,
            bbox=(dict(facecolor="white", edgecolor="none", alpha=0.85, pad=1.2)
                  if box else None))


def span(ax, x0, x1, y, text, *, color=INK, dy=0.10, va="top", ha="center"):
    ax.annotate("", xy=(x0, y), xytext=(x1, y),
                arrowprops=dict(arrowstyle="<->", color=color, lw=0.6))
    ax.text((x0 + x1) / 2 if ha == "center" else (x1 if ha == "right" else x0),
            y + dy, text, fontsize=4.4, color=color, ha=ha, va=va, zorder=8)


def refline(ax, x, text, *, color, ls, y, ha="left", dx=6.0, size=4.4,
            box=False):
    ax.axvline(x, color=color, lw=0.7, ls=ls, zorder=6)
    ax.text(x + (dx if ha == "left" else -dx), y, text, fontsize=size,
            color=color, ha=ha, va="top", zorder=7,
            bbox=(dict(facecolor="white", edgecolor="none", alpha=0.85, pad=1.2)
                  if box else None))


def windows(ax, *, label_y=None):
    """The four detector windows: bands, boundaries, and nothing implied about
    Moonshine.  These ARE constraints -- on SignDetLite only."""
    for k in range(N_INST):
        if k % 2 == 0:
            ax.axvspan(k * T_MS, (k + 1) * T_MS, color=C_WIN, alpha=0.55,
                       lw=0, zorder=0)
        ax.axvline(k * T_MS, color=C_DDL, lw=0.5, ls=(0, (2, 2)), zorder=5)
        if label_y is not None:
            ax.text(k * T_MS + 8, label_y, f"window {k}", fontsize=4.0,
                    color=C_DDL, ha="left", va="top", zorder=7)


def footer(fig, text, y=-0.05):
    fig.text(0.005, y, text, fontsize=4.2, color=MUTED, va="top")


def save(fig, stem):
    os.makedirs(os.path.dirname(stem), exist_ok=True)
    fig.savefig(stem + ".pdf", bbox_inches="tight", pad_inches=0.03)
    fig.savefig(stem + ".png", dpi=300, bbox_inches="tight", pad_inches=0.03)
    plt.close(fig)
    print("wrote", stem + ".png  and  " + stem + ".pdf")
    return stem + ".png", stem + ".pdf"


def cell_row(summary, policy, cont, comp):
    for r in summary["rows"]:
        if (r["policy"] == policy and r["contention_arm"] == cont
                and r["compaction_arm"] == comp):
            return r
    raise SystemExit(f"b157_plots: no cell {policy}/{cont}/{comp} in SUMMARY.json")


def pick(summary, cont, comp, *, cpsat=None, exclude_cpsat=False):
    """Earliest Moonshine end among VALID cells that land all four windows.

    `valid` is the hard-exclusion gate, and it has to be applied here and not
    only in the table: the four `cpsat_warmbest_b157` cells have the shortest
    Moonshine ends in the whole sweep AND land every detector window, so a
    chart that ranked on makespan alone would put an illegal schedule on the
    page as the headline.  They place dispatches on machines their dispatch
    graph forbids -- an illegal instruction on silicon.
    """
    best = None
    for r in summary["rows"]:
        if r["contention_arm"] != cont or r["compaction_arm"] != comp:
            continue
        if not r.get("valid", True):
            continue
        if exclude_cpsat and r["policy"] == cpsat:
            continue
        if cpsat is not None and not exclude_cpsat and r["policy"] != cpsat:
            continue
        if len(r["detector_windows_landed"]) != N_INST:
            continue
        if best is None or r["moonshine_end_ms"] < best["moonshine_end_ms"]:
            best = r
    return best


def panel(ax, row, window_ms, colours=None, *, gutter_hi=1.45, gutter_lo=1.25,
          label_y=None):
    sched = load(row["schedule_json"])
    disp = sched["dispatches"]
    rows = schedule_trace.trace_rows_from_schedule(sched)
    if colours is None:
        colours = gantt.model_colours({gantt.model_of(r["job_name"])
                                       for r in rows})
    windows(ax, label_y=label_y)
    gantt.draw_gantt_axis(ax, rows, disp, cores=LANES, window_ms=window_ms,
                          colours=colours, periods={})
    lane_labels(ax, gutter_hi=gutter_hi, gutter_lo=gutter_lo)
    return disp, colours


def landed_phrase(row):
    lo = row["detector_windows_landed"]
    mi = row["detector_windows_missed"]
    if not mi:
        return "all four detector windows land (%s)" % ", ".join(map(str, lo))
    return ("windows %s land, %s MISSED"
            % (", ".join(map(str, lo)) or "none", ", ".join(map(str, mi))))


def fps_phrase(row):
    return ("1.00 fps sustained" if row["achieved_detector_fps"]
            else "rate NOT sustained -- no fps figure is quotable for this cell")


RATES = ("Three crossing figures, always together so the middle one is not read "
         "as the machine's limit:  0.25 fps heuristic · 1.0 fps achieved "
         "· 2.62 fps capacity.")


# ---------------------------------------------------------------- figure 1
def fig1(summary, out, cont, comp, cpsat_name):
    row = pick(summary, cont, comp) or pick(summary, cont, comp)
    if row is None:
        # Nothing landed all four windows -- say so on the panel rather than
        # quietly drawing the shortest makespan as if it were the answer.
        cands = [r for r in summary["rows"]
                 if r["contention_arm"] == cont and r["compaction_arm"] == comp]
        row = min(cands, key=lambda r: r["moonshine_end_ms"])
    all_end = 0.0
    sched = load(row["schedule_json"])
    for v in sched["dispatches"].values():
        all_end = max(all_end, float(v["start_time"]) + float(v["duration"]))
    window = max(GOAL_MS, all_end) * 1.06

    fig, ax = plt.subplots(figsize=(DOUBLE, 60 * MM))
    disp, colours = panel(ax, row, window, gutter_hi=1.62, gutter_lo=2.55,
                          label_y=-1.52)
    ax.set_xlabel(XLABEL, labelpad=3)

    mk = row["moonshine_end_ms"]
    # When the gap to the reference is small the double-headed arrow below is
    # shorter than its own label and lands on top of the end marker (7.70 ms on
    # the dram/compact cell).  Carry the figure in the end label instead and
    # draw the arrow only when there is room for it to be read.
    gap = GOAL_MS - mk
    tiny = abs(gap) < 0.04 * window
    refline(ax, mk,
            ("Moonshine ends %.2f ms" % mk) if not tiny else
            ("Moonshine ends %.2f ms\n%s the 4 000 ms reference by %.2f ms"
             " (RTF %.4f)"
             % (mk, "inside" if gap >= 0 else "OVER", abs(gap), mk / GOAL_MS)),
            color=INK, ls="-",
            y=-1.05, ha=("right" if mk > window * 0.7 else "left"), box=True)
    # The reference caption goes on whichever side of the 4 000 ms line has
    # room.  Forced left on a short axis it lands on top of the result box in
    # the same gutter, which is how the first render of this figure read.
    ref_right = (window - GOAL_MS) > 0.26 * window
    refline(ax, GOAL_MS,
            "4 000 ms -- a REFERENCE, never a constraint on Moonshine:\n"
            "RTF = 1 on a 4 s utterance.  This spec gives Moonshine no period\n"
            "and no window_duration, so the solver never saw it.",
            color=REFLINE, ls=(0, (4, 2)), y=1.74,
            ha=("left" if ref_right else "right"), dx=8.0, box=True)
    if tiny:
        pass
    elif mk <= GOAL_MS:
        span(ax, mk, GOAL_MS, -1.42,
             "%.2f ms of headroom   (RTF %.4f)" % (GOAL_MS - mk, mk / GOAL_MS),
             color=REFLINE, dy=-0.06, va="bottom")
    else:
        span(ax, GOAL_MS, mk, -1.42,
             "OVER the reference by %.2f ms   (RTF %.4f)"
             % (mk - GOAL_MS, mk / GOAL_MS),
             color="#B3261E", dy=-0.06, va="bottom")

    # THE REAL-TIME TEST IS DERIVED, AND THE PANEL HAS TO SAY SO.  `real_time_ok`
    # occurs nowhere in XPU-RT: no solver computes it, no artifact carries it.
    # It is this programme's own test (xpurt_coloc2m_summarise.py:257), and its
    # 4 000 ms half is a reference the solver never saw.  Printing the field
    # name on the chart would read as a solver verdict and imply the window was
    # enforced.
    gutter(ax, 12.0, 1.22,
           "%s   —   %s\nreal-time test %s — DERIVED, not solver output: "
           "Moonshine’s end ≤ the 4 000 ms reference AND every detector "
           "instance inside its own window"
           % (landed_phrase(row), fps_phrase(row),
              "PASSES" if row["real_time_ok"] else "FAILS"),
           color=(INK if row["real_time_ok"] else "#B3261E"), size=5.0,
           box=True)

    ax.legend(handles=[
        Patch(facecolor=colours.get("moonshine"),
              label="Moonshine (ASR, 12 decoder steps, NON-periodic)"),
        Patch(facecolor=colours.get("signdet"),
              label="SignDetLite (detector, PERIODIC 1 000 ms × 4)"),
        Patch(facecolor=C_WIN, alpha=0.55,
              label="detector window [k·1 000, (k+1)·1 000] ms"),
        plt.Line2D([], [], color=C_DDL, lw=0.6, ls=(0, (2, 2)),
                   label="detector period boundary (a real constraint)"),
        plt.Line2D([], [], color=REFLINE, lw=0.7, ls=(0, (4, 2)),
                   label="4 000 ms RTF = 1 reference (NOT a constraint)"),
    ], ncol=3, frameon=False, loc="lower left", bbox_to_anchor=(0, 1.22),
        fontsize=4.8)
    ax.set_title(
        "Co-located Moonshine + SignDetLite, detector PERIODIC at T = 1 000 ms "
        "(1.00 fps, 4 instances)  —  policy `%s`, b4 / contention arm `%s` "
        "/ compaction `%s`\nspec  %s   (SignDetLite period = window_duration = "
        "1 000 ms, num_instances = 4; Moonshine NON-periodic, "
        "restrict_makespan_to_nonperiodic = True)"
        % (row["policy"], cont, comp, SPEC_NAME),
        loc="left", pad=4, fontsize=5.6)
    footer(fig,
           "Lab B157.  PREDICTED, not measured: the per-dispatch durations are "
           "board-measured (Moonshine 0x5A5A0035, SignDetLite 0x5A5A0038, both "
           "40.000 MHz), the PLACEMENT is XPU-RT's.  The runtime does not "
           "execute this plan -- B152d demonstrated two-hart overlap at ONE "
           "interleave point on silicon and nothing wider (`Correction to "
           "B152d`).\nThe 1 000 / 2 000 / 3 000 / 4 000 ms boundaries are "
           "constraints on SignDetLite ONLY.  Moonshine carries no deadline in "
           "this spec, so its 4 000 ms is the RTF = 1 reference and nothing "
           "more (`Correction to L396`).  The real-time test on this panel is "
           "DERIVED by b157_report.py from the schedule's own dispatches -- "
           "`real_time_ok` is emitted by no XPU-RT artifact and by no solver; "
           "it is xpurt_coloc2m_summarise.py:257's two-part test, and B152c's "
           "T550 `False` is the same derivation, not a second instrument.\n%s\n"
           "Solver %s, status %s, %.1f s "
           "wall.  solve_hash %s.  Rendered with XPU-RT "
           "scripts/plot_k1_evolution.draw_gantt_axis, the primitive "
           "scripts/plot_scheduled_json.py calls."
           % (RATES, row["policy"], row["solver_status"], row["solve_wall_s"],
              row["solve_hash"][:16]))
    return save(fig, os.path.join(out, "b157_fig1_T1000_cell_gantt"))


# ---------------------------------------------------------------- figure 2
def fig2(summary, out, cont, comp, cpsat_name):
    heur = pick(summary, cont, comp, cpsat=cpsat_name, exclude_cpsat=True)
    solv = cell_row(summary, cpsat_name, cont, comp)
    if heur is None:
        print("fig2: no heuristic lands all four windows; skipping")
        return None
    ends = []
    for r in (heur, solv):
        s = load(r["schedule_json"])
        ends.append(max(float(v["start_time"]) + float(v["duration"])
                        for v in s["dispatches"].values()))
    window = max(GOAL_MS, max(ends)) * 1.06

    fig, axes = plt.subplots(2, 1, figsize=(DOUBLE, 100 * MM), sharex=True)
    colours = None
    titles = [
        "a   best of the NINE list-scheduling heuristics that lands every "
        "detector window: `%s`" % heur["policy"],
        # NOT "warm-started from that seed": `--scheduler cpsat` seeds itself
        # from HEFT internally and that hint is inert (19.4 %% of non-fixed
        # variables; HEFT and fifo seeds give bit-identical output).  The path
        # that does keep a best-of-nine seed is excluded from this figure for
        # violating the machine exclusion, so claiming the warm start here
        # would be claiming it for the wrong solver.
        "b   CP-SAT (`--scheduler %s`, registry path, lexicographic objective: "
        "window misses, then lateness, then makespan)" % cpsat_name,
    ]
    for ax, r, title in zip(axes, (heur, solv), titles):
        _, colours = panel(ax, r, window, colours,
                           gutter_hi=1.15, gutter_lo=1.15, label_y=-1.05)
        ax.set_title(title, loc="left", pad=3, fontsize=5.4)
        refline(ax, r["moonshine_end_ms"],
                "Moonshine ends\n%.2f ms" % r["moonshine_end_ms"],
                color=INK, ls="-", y=-0.55,
                ha=("right" if r["moonshine_end_ms"] > window * 0.7 else "left"),
                box=True)
        ax.axvline(GOAL_MS, color=REFLINE, lw=0.7, ls=(0, (4, 2)), zorder=6)
        gutter(ax, 12.0, 1.40,
               "%s   —   real-time test (derived, not solver output) %s"
               % (landed_phrase(r),
                  "PASSES" if r["real_time_ok"] else "FAILS"),
               color=(INK if r["real_time_ok"] else "#B3261E"), size=4.8,
               box=True)

    axes[1].set_xlabel(XLABEL, labelpad=3)
    d = heur["moonshine_end_ms"] - solv["moonshine_end_ms"]
    span(axes[1], min(heur["moonshine_end_ms"], solv["moonshine_end_ms"]),
         max(heur["moonshine_end_ms"], solv["moonshine_end_ms"]), 1.62,
         "%s %.2f ms" % ("CP-SAT recovers" if d > 0 else "CP-SAT LOSES",
                         abs(d)),
         color=(REFLINE if d > 0 else "#B3261E"), dy=0.08, va="top")

    axes[0].legend(handles=[
        Patch(facecolor=colours.get("moonshine"),
              label="Moonshine (ASR, NON-periodic)"),
        Patch(facecolor=colours.get("signdet"),
              label="SignDetLite (PERIODIC 1 000 ms × 4)"),
        Patch(facecolor=C_WIN, alpha=0.55, label="detector window"),
        plt.Line2D([], [], color=REFLINE, lw=0.7, ls=(0, (4, 2)),
                   label="4 000 ms RTF = 1 reference (NOT a constraint)"),
    ], ncol=4, frameon=False, loc="lower left", bbox_to_anchor=(0, 1.16),
        fontsize=4.8)
    fig.suptitle(
        "What the solver buys at T = 1 000 ms  —  b4 / contention arm `%s` "
        "/ compaction `%s`\nspec  %s   (both panels, same spec, same "
        "board-measured per-dispatch costs, same pdb_hash %s)"
        % (cont, comp, SPEC_NAME, heur["pdb_hash"][:16]),
        x=0.005, ha="left", y=1.065, fontsize=5.8)
    footer(fig,
           "PREDICTED, not measured -- placement is XPU-RT's; the runtime does "
           "not execute this plan (`Correction to B152d`).  The 4 000 ms line "
           "is the RTF = 1 REFERENCE on Moonshine, never a constraint; the "
           "detector window boundaries are the constraints "
           "(`Correction to L396`).\nCP-SAT here is `--scheduler cpsat`, the "
           "REGISTRY path.  The warm-start-honouring path "
           "(`--solver cpsat` / cpsat_scheduler.py, hinted 2 285 of 2 285 "
           "operations against 19.4 %% of non-fixed variables here) is NOT "
           "drawn: its model is built from DecoderContext, which never reads "
           "op.infeasible_combinations, so all four of its cells place "
           "dispatches on a machine the dispatch graph forbids -- 74 violations "
           "over 37 dispatches, an illegal instruction on silicon.  A shorter "
           "makespan that breaks the machine model is not a better "
           "answer.\n%s\nLab B157." % RATES)
    return save(fig, os.path.join(out, "b157_fig2_T1000_heuristic_vs_cpsat"))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--summary", default=os.path.join(ARCH, "SUMMARY.json"))
    ap.add_argument("--out", default=os.path.join(ARCH, "plots"))
    ap.add_argument("--contention", default="none")
    ap.add_argument("--compaction", default="plain")
    # THE REGISTRY PATH, because it is the only CP-SAT here whose schedules pass
    # the hard-exclusion audit.  `cpsat_warmbest_b157` keeps the warm start but
    # its model cannot see op.infeasible_combinations, so all four of its cells
    # place dispatches on machines that would take an illegal instruction.
    ap.add_argument("--cpsat-scheduler", default="cpsat")
    ap.add_argument("--only", choices=("1", "2"), default=None)
    a = ap.parse_args()
    summary = load(a.summary)
    os.makedirs(a.out, exist_ok=True)
    if a.only in (None, "1"):
        fig1(summary, a.out, a.contention, a.compaction, a.cpsat_scheduler)
    if a.only in (None, "2"):
        fig2(summary, a.out, a.contention, a.compaction, a.cpsat_scheduler)


if __name__ == "__main__":
    main()
