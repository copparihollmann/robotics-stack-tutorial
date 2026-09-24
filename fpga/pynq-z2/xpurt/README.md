# What the co-location solve reads

`scripts/12_xpurt_coloc_sweep.sh` schedules two networks across the two harts of the Rocket
SoC: **Moonshine Tiny**, the speech transformer, as a non-periodic job that has to finish,
and **SignDetLite**, the colour localising sign detector, as a real-time periodic task at
T = 1000 ms that must not miss a frame. The scheduler is
[XPU-RT](https://github.com/ucb-bar/XPU-RT), which is **not vendored here** — clone it and
point `XPURT_ROOT` at it.

Everything the solve *reads* is in this directory, laid out under exactly the relative paths
the spec names, so a cell can resolve them from its own working directory and your XPU-RT
checkout is never written to.

| | |
|---|---|
| `networks_pynqz1_coloc2m_sdp_b4_T1000.json` | the spec: two machines, two networks, the periodic declaration, and the scheduler options. 22 kB. |
| `gen_pynqz1_2m_sdp_b4/vmfb/**/*_dispatch_graph.json` | the dispatch graphs. These carry `infeasible_machines`, which is what makes the hard machine exclusion checkable. |
| `gen_pynqz1_2m_sdp_b4/profile/**/results.csv` | **the board measurements.** One per-dispatch cost table per (machine, network): 2,285 Moonshine dispatches and 8 SignDetLite ones, per hart. 1.3 MB of CSV, and the entire empirical content of the lab. |
| `artifacts/pynqz1_coloc/contention_b4_dram.json` | the measured DRAM contention model — plateau aggregate 0.924. The `none` arm passes no `--contention` at all. |

## The two machines are not interchangeable, and that is the whole problem

`CPU_P` is **hart 0**: the big core, with the MBP packed-SIMD P-extension on `custom-0` and
no accelerator. `CPU_E` is **hart 1**: the little core, with the RoccMoon engine on
`custom-1` and no P-extension. A kernel curated for one traps on the other — *illegal
instruction*, on silicon, not a slowdown — and that is why every dispatch carries an
`infeasible_machines` set and why `scripts/lib/b157_report.py` refuses a whole schedule
rather than annotating it when one is violated. See `expected/xpurt_coloc2m_b157.json`.

## Where the numbers came from, and what they are not

The per-dispatch costs are measured on real silicon at 40.000 MHz — Moonshine's on
`0x5A5A0035`, SignDetLite's on `0x5A5A0038`. Both bitstreams carry the same md5-pinned nch=8
RoccMoon engine snapshot on hart 1 and the same MBP datapath on hart 0, and
`RocketALU.sv` / `RoccMoonEngine.sv` / `RoccMoonShim.sv` are byte-identical between the two
elaborations; the cross-bitstream note is stated in the spec's own `_comment` because it is
load-bearing. The co-location needs the engine, so it targets `0x5A5A0038` — `0x5A5A0039`
has TACIT and no engine, which is where SignDetLite could run but Moonshine could not.

**The placement is predicted, not measured.** The durations come off a board; where the
solver puts each dispatch does not, and the runtime does not execute this plan. The
`_caveats` list in the golden says so in more detail, and it is the first thing to read
before quoting a millisecond from here.
