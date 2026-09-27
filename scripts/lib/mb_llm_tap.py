#!/usr/bin/env python3
"""Run ModelBlaster's generate_kernels with every LLM call recorded and capped.

    python3 scripts/lib/mb_llm_tap.py --transcript T.jsonl --max-calls N [--log FILE] -- <generate_kernels args>

With --log, generate_kernels' own output goes to FILE, and the terminal shows one line per LLM
call and a summary of the round (the kernel ModelBlaster picked, and the spike cycles before
and after optimizing).

ModelBlaster is a pinned input ($ZCS), so this wrapper adds four things at run time:

  * A target guide for the MBP. ModelBlaster describes each hardware target to the model through
    its Backend entry: `optimization_guide` names a file in pipeline/prompts/ that fills the
    TARGET GUIDE block of every system prompt, and `kernel_includes` lists headers prepended to
    every kernel (RVV: <riscv_vector.h>). Its `pext` backend has both from 60a0784 (the pin);
    an older build (99b9e84) has neither and sends the scalar guide. --target-guide and
    --target-include set both for the --target being generated, exactly as a Backend entry
    would (the lab passes fpga/pynq-z2/modelblaster/prompts/optimization_guide_pext.md, the
    same file 60a0784 ships, and "pext.h"), so the lab works with either.
  * A transcript. ModelBlaster keeps no copy of the prompts or responses, and
    BEDROCK_CALLS_LOG records only token counts. This appends one JSON line per call with
    the phase, system prompt, user prompt, response, token counts and latency. The bearer
    token is not recorded.
  * A call cap. ModelBlaster's MODELBLASTER_MAX_USD prices calls from pricing.yaml, which
    before 60a0784 has no entry for the model the tutorial key can reach, so its budget
    tracker reports $0. Past --max-calls, a call raises before reaching Bedrock; ModelBlaster treats that as
    a failed call and keeps the best kernel that already verified.
  * Extra text at the end of every system prompt (--system-append). This lab uses it for
    mb_ops/idea_line.md, which asks the model to state each candidate's idea in a comment;
    and, with --board-loop, for hardware in the loop feedback: the cycles measured on the
    FPGA for each round's best kernel, added to the next round's prompt
    (after/board_feedback.md). Each file is reread on every call.

ModelBlaster's BedrockClient.converse is patched at class level before generate_kernels is
imported, so every client ModelBlaster creates later is covered. Each call prints a flushed
progress line to stderr, since a Bedrock call produces no output until the model answers.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path


class CallCapReached(RuntimeError):
    pass


def isolate_host_verify(gk) -> None:
    """Run ModelBlaster's host verify for each candidate in a forked child.

    ModelBlaster's verify_kernel.verify loads the candidate .so with ctypes in the generator
    process, so a candidate that writes out of bounds kills the whole round with SIGSEGV. In a
    child the crash is one failed attempt, and its diagnostic goes back to the LLM like any
    other. generate_kernels looks the function up by its global name in the module,
    host_verify, so that is the name replaced here.
    """
    import multiprocessing as mp
    from modelblaster.pipeline.verify_kernel import VerifyResult

    inner = gk.host_verify

    def child(q, args, kw):
        r = inner(*args, **kw)
        q.put((r.ok, r.message, r.failing_shape, r.max_abs_err, r.max_rel_err))

    def safe(*args, **kw):
        ctx = mp.get_context("fork")
        q = ctx.Queue()
        p = ctx.Process(target=child, args=(q, args, kw))
        p.start()
        p.join()
        if p.exitcode != 0:
            why = {-4: "an MB_PEXT_LD8/MB_PEXT_ST8 at an address that is not 8-byte aligned, which traps "
                       "on the target (SIGILL)",
                   -11: "an access out of bounds (SIGSEGV)"}.get(p.exitcode, f"exit {p.exitcode}")
            return VerifyResult(False, f"the candidate crashed the verifier: {why}")
        ok, msg, fs, a, r = q.get()
        return VerifyResult(ok, msg, fs, a, r)

    gk.host_verify = safe


# The host that verifies candidates (x86) loads 8 bytes from any address, but the target's core
# raises a misaligned-address exception, so a kernel with a misaligned MB_PEXT_LD8/ST8 passed host
# verify and then hung on spike, which ends ModelBlaster's round. On the host, these two macros trap
# like the core does; the verifier (isolated in a child by isolate_host_verify) reports the crash
# as a failed attempt, and ModelBlaster sends that back to the LLM like any other verify failure.
HOST_ALIGNMENT_TRAP = """#undef MB_PEXT_LD8
#undef MB_PEXT_ST8
#define MB_PEXT_LD8(p) (MB_PEXT_ALIGNED8(p) ? *(const mb_pext_i64a *)(const void *)(p) : (__builtin_trap(), (int64_t)0))
#define MB_PEXT_ST8(p, v) (MB_PEXT_ALIGNED8(p) ? (void)(*(mb_pext_i64a *)(void *)(p) = (int64_t)(v)) : __builtin_trap())
"""


def set_target(gk, gk_args, guide, includes) -> None:
    """Give the --target in gk_args an optimization guide and kernel includes, as its Backend
    entry in modelblaster/pipeline/backends.py would. Backend is a frozen dataclass kept in the
    BACKENDS registry, which generate_kernels reads through backends.get(); the registry entry is
    replaced with a copy that has the two fields set. The guide is read through
    generate_kernels._load_backend_guide, so that function returns the file for this target."""
    import dataclasses
    from modelblaster.pipeline import backends

    name = gk_args[gk_args.index("--target") + 1]
    b = backends.BACKENDS[name]
    # A ModelBlaster whose pext backend already has these (iiswc-pext-target-guide) is left as it is.
    changes = {"kernel_includes": tuple(dict.fromkeys(tuple(b.kernel_includes) + tuple(includes)))} if includes else {}
    if guide:
        changes["optimization_guide"] = os.path.abspath(guide)
    backends.BACKENDS[name] = dataclasses.replace(b, **changes)
    if guide:
        load = gk._load_backend_guide
        text = Path(guide).read_text()
        gk._load_backend_guide = lambda backend: text if backend.name == name else load(backend)


def host_includes(gk_args, includes) -> None:
    """Give ModelBlaster's host verify (verify_kernel.host_compile) the target's includes, which a
    99b9e84 build does not prepend there, and for pext the alignment trap, with any --guide."""
    from modelblaster.pipeline import verify_kernel

    if not includes and gk_args[gk_args.index("--target") + 1] == "pext":
        includes = ('"pext.h"',)
    if includes:
        compile_ = verify_kernel.host_compile
        lines = "".join(f"#include {h}\n" for h in includes)
        if '"pext.h"' in includes:
            lines += HOST_ALIGNMENT_TRAP

        def host_compile(c_source, label, workdir, *args, **kw):
            if "#include" not in c_source:
                c_source = verify_kernel._HOST_PROLOGUE + lines + c_source
            elif not all(h in c_source for h in includes):
                c_source = lines + c_source
            return compile_(c_source, label, workdir, *args, **kw)
        verify_kernel.host_compile = host_compile


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--transcript", required=True, help="JSONL file to append calls to")
    ap.add_argument("--max-calls", type=int, default=12,
                    help="calls THIS invocation may make")
    ap.add_argument("--call-offset", type=int, default=None,
                    help="calls already made by earlier rounds, so numbering continues "
                    "(default: the number of calls already in --transcript)")
    ap.add_argument("--log", help="write generate_kernels' output to this file and show only "
                    "the LLM calls and a summary")
    ap.add_argument("--round", type=int, default=1)
    ap.add_argument("--system-append", action="append", default=[],
                    help="a file whose text is appended to every system prompt (the idea line rule; "
                    "and, with --board-loop, what the FPGA measured).  Repeatable; each file is "
                    "reread on every call, so a file rewritten between calls takes effect")
    ap.add_argument("--target-guide",
                    help="the optimization guide for the --target being generated, used where "
                    "ModelBlaster's Backend.optimization_guide would be (its TARGET GUIDE block)")
    ap.add_argument("--target-include", action="append", default=[],
                    help='a header prepended to every kernel of the --target, like '
                    'Backend.kernel_includes (e.g. \'"pext.h"\').  Repeatable')
    ap.add_argument("--status", help="the run's status.json, updated per call for mb on the board")
    ap.add_argument("rest", nargs=argparse.REMAINDER,
                    help="-- followed by generate_kernels arguments")
    a = ap.parse_args()
    if os.environ.get("MB_CMD_LOG"):          # record this invocation in the lab's commands.sh
        import shlex
        with open(os.environ["MB_CMD_LOG"], "a") as fh:
            fh.write(f"cd {shlex.quote(os.getcwd())} && python -u {' '.join(shlex.quote(x) for x in sys.argv)}\n")
    rest = a.rest[1:] if a.rest[:1] == ["--"] else a.rest

    from modelblaster.pipeline import bedrock_client

    transcript = Path(a.transcript)
    transcript.parent.mkdir(parents=True, exist_ok=True)
    if a.call_offset is None:
        a.call_offset = sum(1 for _ in open(transcript)) if transcript.exists() else 0
    out = sys.stderr                           # where the line for each call goes
    if a.log:
        # Keep a handle on the terminal, then send everything else (generate_kernels, and the
        # compilers and spike it starts) to the log.
        out = os.fdopen(os.dup(2), "w", buffering=1)
        Path(a.log).parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(a.log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        sys.stdout.flush()
        sys.stderr.flush()
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.close(fd)
    orig = bedrock_client.BedrockClient.converse
    state = {"n": 0}

    def live(step: str) -> None:
        """Say what is happening in status.json, which `mb` on the board follows."""
        if not a.status:
            return
        try:
            st = json.loads(Path(a.status).read_text())
        except (OSError, ValueError):
            st = {}
        st.update(state="running", step=step, t=int(time.time()))
        tmp = Path(a.status).with_name(".status.json.tmp")   # atomic: the viewer may be reading it
        tmp.write_text(json.dumps(st) + "\n")
        os.replace(tmp, a.status)

    def extra_text():
        return "\n\n".join(Path(f).read_text() for f in a.system_append if Path(f).exists())

    def converse(self, user, system=None, *args, **kw):
        phase = kw.get("phase")
        extra = extra_text()
        if extra:
            system = (system or "") + "\n\n" + extra
        if state["n"] >= a.max_calls:
            print(f"[tap] call cap {a.max_calls} reached; refusing {phase}",
                  file=out, flush=True)
            raise CallCapReached(f"mb_llm_tap: --max-calls {a.max_calls} reached")
        state["n"] += 1
        n = a.call_offset + state["n"]
        total = a.call_offset + a.max_calls
        print(f"[tap] call {n}/{total} {phase or '?'}: waiting for "
              f"{self.model_id} ...", file=out, flush=True)
        live(f"round {a.round}: LLM call {n} ({phase or '?'}) waiting for {self.model_id}")
        t0 = time.monotonic()
        err = None
        res = None
        try:
            res = orig(self, user, system, *args, **kw)
            return res
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
            raise
        finally:
            dt = time.monotonic() - t0
            rec = {
                "n": n, "round": a.round, "phase": phase, "model": self.model_id,
                "latency_s": round(dt, 2),
                "system": system, "user": user,
                "response": res.text if res is not None else None,
                "input_tokens": res.input_tokens if res is not None else 0,
                "output_tokens": res.output_tokens if res is not None else 0,
                "stop_reason": res.stop_reason if res is not None else None,
                "request_id": res.request_id if res is not None else None,
                "error": err,
            }
            with open(transcript, "a") as f:
                f.write(json.dumps(rec) + "\n")
            live(f"round {a.round}: LLM call {n} answered in {dt:.0f} s; building + verifying")
            if res is not None:
                print(f"[tap] call {n}/{total} {phase or '?'}: {dt:.0f} s, "
                      f"{res.input_tokens} in / {res.output_tokens} out tokens",
                      file=out, flush=True)
            else:
                print(f"[tap] call {n}/{total} {phase or '?'}: failed after "
                      f"{dt:.0f} s: {err}", file=out, flush=True)

    bedrock_client.BedrockClient.converse = converse

    from modelblaster.pipeline import generate_kernels
    if a.target_guide or a.target_include:
        set_target(generate_kernels, rest, a.target_guide, a.target_include)
    host_includes(rest, a.target_include)
    isolate_host_verify(generate_kernels)
    sys.argv = ["generate_kernels", *rest]
    rc = generate_kernels.main()
    rc = rc if isinstance(rc, int) else 0
    if a.log:
        summarize(rest, out, a.log)
    return rc


def summarize(args, out, log) -> None:
    """One line per op: the kernel generate_kernels picked, and what --optimize did on spike."""
    def arg(name):
        return args[args.index(name) + 1] if name in args else None
    gen = Path(arg("--out-dir") or ".")
    try:
        picks = json.loads((gen / "kernel_picks.json").read_text())["picks"]
    except (OSError, ValueError, KeyError):
        print(f"[tap] no kernel_picks.json in {gen}: see {log}", file=out, flush=True)
        return
    try:
        opt = json.loads((gen / "optimize_summary.json").read_text())
    except (OSError, ValueError):
        opt = {}
    for op, p in picks.items():
        line = f"[tap] {op}: {p['source']} kernel, algorithm {p['algorithm']}"
        if op in opt:
            b, x = opt[op]["baseline"], opt[op]["best"]
            line += f"; spike cycles {b:,} -> {x:,} ({b / x:.2f}x from --optimize)"
        print(line, file=out, flush=True)
    print(f"[tap] full output: {log}", file=out, flush=True)


if __name__ == "__main__":
    sys.exit(main())
