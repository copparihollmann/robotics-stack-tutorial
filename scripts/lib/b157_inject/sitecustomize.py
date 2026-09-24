"""B157: `cpsat_warmbest_b157` -- B152c's warm-start CP-SAT, with the search
workers unpinned.

WHY A SECOND INJECTION DIRECTORY.  B152c's
`fpga/pynq-z2/scripts/xpurt_inject/sitecustomize.py` registers `cpsat_warmbest`
and `cpsat_warmbest_repaired`, and this lab does not modify that file any more
than it modifies XPU-RT.  Python imports exactly one `sitecustomize`, so this
one loads B152c's by path first -- both its names stay registered and unchanged
-- and then adds a third.

WHAT IS DIFFERENT, AND ONLY THIS.  `_cpsat_warmbest_repaired` ends with
`kwargs.setdefault("workers", 1)`, and `cpsat_scheduler.cpsat_schedule` passes
that straight into the payload (`workers if workers != 8 else
_default_workers()`), so an explicit 1 shadows XPURT_CPSAT_WORKERS entirely.
One worker is not a neutral default here.  B152c measured it on the adjacent
non-periodic b4/dram cell at a 300 s budget:

    1 worker  -> 4031.77 ms, FEASIBLE, 16 deadline misses
    8 workers -> 3133.40 ms, phases 1-2 OPTIMAL, 0 misses

and scheduler_cpsat.py:653 says the same in its own words: one worker "CRIPPLES
CP-SAT's parallel portfolio search -- the single biggest reason it gets stuck
above greedy's makespan."  This entry point takes the count from
XPURT_CPSAT_WORKERS (default 8) instead, so the budget the lab grants is the
budget CP-SAT can actually spend.

THE COST, STATED.  cpsat_scheduler.py's own docstring: CP-SAT is reproducible
only at workers=1; above that the answer depends on thread interleaving.  So a
cell solved here is reproducible in the sense that the schedule it emits is
valid and is re-checked against the detector windows separately -- not in the
sense that a rerun returns the same milliseconds.  The worker count is recorded
in metadata.solve_env (solve_provenance.TRACKED_ENV carries
XPURT_CPSAT_WORKERS) of every schedule this writes.

EVERYTHING ELSE IS B152c's.  The seed rule (best of the nine heuristics,
lexicographic on (deadline misses, makespan) -- CP-SAT's own phase order), the
hint path (`cpsat_scheduler.cpsat_schedule`, which replays the seed on the
integer microsecond grid and hints start/end/duration/presence together, 2285
of 2285 operations on this workload, against 19.4 % of non-fixed variables on
`--scheduler cpsat`), and the registry registration all come from that file.
Registering rather than driving `--solver cpsat` directly is also what makes
the compaction arm reachable: `schedulers.get_scheduler()` is the only place
`_wrap_with_compaction` is applied, so XPURT_COMPACT=1 is a silent no-op on the
bare `--solver cpsat` path.
"""
import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_B152C = os.path.join(os.path.dirname(_HERE), "xpurt_inject", "sitecustomize.py")


def _load_b152c():
    spec = importlib.util.spec_from_file_location("_b152c_xpurt_inject", _B152C)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)          # registers cpsat_warmbest{,_repaired}
    return mod


try:
    _parent = _load_b152c()

    def _cpsat_warmbest_b157(workload, **kwargs):
        try:
            _w = int(os.environ.get("XPURT_CPSAT_WORKERS", "8"))
        except ValueError:
            _w = 8
        kwargs.setdefault("workers", _w if _w > 0 else 8)
        print(f"  cpsat:warmbest(b157) search workers = {kwargs['workers']}")
        res = _parent._cpsat_warmbest_repaired(workload, **kwargs)
        # THE RETURN ARITY IS NOT COSMETIC, AND IT IS WHY B152c HAS NO SCHEDULE
        # FROM THIS PATH.  `cpsat_scheduler.cpsat_schedule` returns a bare
        # (t, alpha); the registry contract is (t, alpha, fused_workload,
        # fusion_map).  Two things go wrong with the 2-tuple, in this order:
        #   - schedulers._wrap_with_compaction computes the left-shift and then
        #     `return (t2, alpha2, fused, fmap) if len(result) >= 4 else result`
        #     -- it throws the compacted schedule away and returns the original.
        #     XPURT_COMPACT=1 is a silent no-op on a 2-tuple scheduler.
        #   - run_xpurt_schedule.py:651 then does `t, alpha, _, _ = result` and
        #     raises `ValueError: not enough values to unpack (expected 4, got
        #     2)` AFTER the solve has finished.  Every archived
        #     warmbestR_*_cpsat.log in coloc2m_signdet_cpsat/logs/ ends on that
        #     traceback, which is why that lab's warmbest/ directory holds only
        #     the `cpsat_warmbest` (scheduler_cpsat) results: the repaired path
        #     printed an objective and emitted nothing.
        # Padding to 4 here fixes both -- the solve is unchanged, the schedule
        # is written, and the compaction arm becomes reachable.
        if isinstance(res, tuple) and len(res) == 2:
            return res[0], res[1], None, None
        return res

    import schedulers as _sched_mod
    _sched_mod.register("cpsat_warmbest_b157", _cpsat_warmbest_b157)
except Exception as _exc:                  # never break the interpreter
    print(f"[sitecustomize] cpsat_warmbest_b157 not registered: {_exc}",
          file=sys.stderr)
