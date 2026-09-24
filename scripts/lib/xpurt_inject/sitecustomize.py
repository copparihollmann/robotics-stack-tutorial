"""B152c: register `cpsat_warmbest` into XPU-RT's scheduler registry.

WHY A sitecustomize AND NOT A PATCH.  XPU-RT is a shared checkout; this lab
does not modify it.  Python imports `sitecustomize` automatically at startup,
before scripts/run_xpurt_schedule.py parses --scheduler, so the new name is in
available_schedulers() by the time argparse validates it.  Put this directory
on PYTHONPATH to arm it; remove it and XPU-RT is exactly as shipped.

WHAT IT IS.  `cpsat:warmbest` is NAMED in two docstrings in this checkout --
qnn_models/octo/schmoo/fig_schmoo.py:4 and the e2e/figures copy, which say the
grid_warm.json figure was produced with "solver cpsat:warmbest" -- and is
DEFINED NOWHERE.  The name predates the code.  What does exist is the one-seed
precedent, scripts/solver_study/wl_sweep_bench.py:66:

    "cpsat:warm": lambda w: cpsat_schedule(w, time_limit=cpsat_time,
                                           warm_start=mh.heft_edf_schedule(w))

so this is that, with best-of-the-cheap-heuristics in place of the fixed
heft_edf seed.

THE SELECTION RULE MATCHES CP-SAT'S OWN OBJECTIVE, or the seed is picked on the
wrong metric: LEXICOGRAPHIC -- deadline misses first, then makespan.  On a
periodic cell a fifo schedule with a shorter makespan but a dropped frame is
NOT the better seed; on a non-periodic cell there are no windows and the rule
reduces to makespan.

WHAT TO EXPECT, from this repo's own README.md:217 on the analogous
milp_native: "Warm-started from HEFT by default.  Better than `milp` cold
(90.9 vs 112.3 ms on a 242-op instance) but its best result only ties the
heuristic that seeded it."  A tie reproduces documented behaviour and is a
result, not a failed run.
"""
import os
import sys

# The XPU-RT checkout.  Normally already importable -- this runs INSIDE a cell
# directory that is a symlink farm of it -- so XPURT_ROOT only has to be right
# when it is not.
_X = os.environ.get("XPURT_ROOT", "")
for _p in (os.path.join(_X, "xpu-rt"), os.path.join(_X, "scripts")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

_SEED_CANDIDATES = ("heft", "heft_edf", "fifo", "edf", "peft", "critical_path",
                    "min_min", "max_min", "round_robin", "fastest_device")


def _lex_score(workload, t, alpha):
    """(deadline_misses, makespan) -- CP-SAT's own phase order."""
    import numpy as np
    combos = workload.get_machine_combinations()
    misses, mk = 0, 0.0
    for i, op in enumerate(workload.operations):
        k = int(np.argmax(alpha[i]))
        dur = op.get_duration_for_combination(k, combos, workload.machines)
        fin = float(t[i]) + float(dur)
        mk = max(mk, fin)
        mx = getattr(op, "max_end_t", None)
        if mx is not None and fin > float(mx) + 1e-6:
            misses += 1
    return misses, mk


def _cpsat_warmbest(workload, **kwargs):
    from scheduler_cpsat import cpsat_schedule
    import schedulers as _S
    best = None
    tried = []
    for name in _SEED_CANDIDATES:
        try:
            fn = _S.get_scheduler(name)
            res = fn(workload)
            t, alpha = res[0], res[1]
            if t is None or alpha is None:
                continue
            score = _lex_score(workload, t, alpha)
        except Exception as exc:                      # a seed that fails is skipped
            tried.append((name, f"FAILED {type(exc).__name__}"))
            continue
        tried.append((name, score))
        if best is None or score < best[0]:
            best = (score, t, alpha, name)
    if best is not None:
        kwargs["warm_start"] = (best[1], best[2])
        print("  cpsat:warmbest seed candidates (misses, makespan_ms):")
        for name, s in tried:
            mark = "->" if name == best[3] else "  "
            print(f"    {mark} {name:16s} {s}")
        print(f"  cpsat:warmbest SEEDED FROM {best[3]} "
              f"misses={best[0][0]} makespan={best[0][1]:.2f} ms")
    else:
        print("  cpsat:warmbest: NO usable seed; solving cold")
    return cpsat_schedule(workload, **kwargs)



def _cpsat_warmbest_repaired(workload, **kwargs):
    """The SAME best-of-nine seed, but through xpu-rt/cpsat_scheduler.py.

    WHY A SECOND ENTRY POINT.  There are two CP-SAT implementations in this
    checkout and they treat a hint differently:

      scheduler_cpsat.cpsat_schedule   what `--scheduler cpsat` reaches.  Hints
          only `presence` and `chosen_start` (AddHint at :633-634) -- MEASURED
          here at 4,522 of 23,329 non-fixed variables, 19.4 %.  CP-SAT accepts
          the partial hint (the search log tags solution #1 `[hint]`) and
          COMPLETES it itself, and that completion is worse than the seed: a
          fifo seed with 0 deadline misses came back as an incumbent with 16.
          Seeding it from fifo and from HEFT gives BIT-IDENTICAL answers, so on
          this path the warm start is inert.
      cpsat_scheduler.cpsat_schedule   what `--solver cpsat` reaches.  Replays
          the seed on CP-SAT's integer grid first (`_integerize`, :55) and
          hints start, end, duration and presence together, or says "warm start
          does not fit the integer model; solving cold" (:168) rather than
          hinting something inconsistent.

    So this is `cpsat:warmbest` as the docstrings meant it: best-of-nine seed
    handed to the implementation that can actually keep it.  Needs
    XPURT_CPSAT_PYTHON, since this one shells out to a separate interpreter.
    """
    import cpsat_scheduler as _cs
    import schedulers as _S
    best, tried = None, []
    for name in _SEED_CANDIDATES:
        try:
            res = _S.get_scheduler(name)(workload)
            t, alpha = res[0], res[1]
            if t is None or alpha is None:
                continue
            score = _lex_score(workload, t, alpha)
        except Exception as exc:
            tried.append((name, f"FAILED {type(exc).__name__}")); continue
        tried.append((name, score))
        if best is None or score < best[0]:
            best = (score, t, alpha, name)
    print("  cpsat:warmbest(repaired) seed candidates (misses, makespan_ms):")
    for name, s in tried:
        print(f"    {'->' if best and name == best[3] else '  '} {name:16s} {s}")
    if best is not None:
        print(f"  SEEDED FROM {best[3]} misses={best[0][0]} "
              f"makespan={best[0][1]:.2f} ms")
        kwargs["warm_start"] = (best[1], best[2])
    kwargs.setdefault("verbose", True)
    kwargs.setdefault("workers", 1)
    for _k in ("prune_cross_period_constraints", "cvxpy_solver", "objective_mode",
               "critical_models", "heavy_model", "objective_stop_after",
               "solver_verbosity"):
        kwargs.pop(_k, None)
    if "restrict_makespan_to_nonperiodic" in kwargs:
        kwargs["restrict_to_nonperiodic"] = kwargs.pop(
            "restrict_makespan_to_nonperiodic")
    return _cs.cpsat_schedule(workload, **kwargs)


try:
    import schedulers as _sched_mod
    _sched_mod.register("cpsat_warmbest", _cpsat_warmbest)
    _sched_mod.register("cpsat_warmbest_repaired", _cpsat_warmbest_repaired)
except Exception as _exc:                              # never break the interpreter
    print(f"[sitecustomize] cpsat_warmbest not registered: {_exc}", file=sys.stderr)
