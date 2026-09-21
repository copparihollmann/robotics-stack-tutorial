# wlanetb — the private W lane on two clocks, and the gate for `0x5A5A0013`

Three benches over the same idea: drive a weight lane's generated RTL against a behavioural AXI4 memory standing in for
`S_AXI_HP2`, on two unrelated clocks, and check the AXI contract, the abort-drain and the resume at the pins.
MEMORY_BANDWIDTH.md §9.9 is the record; this file says how to re-run one.

| | what it drives | when it was used |
|---|---|---|
| `gen_top.py`, `build.sh`, `run_all.sh`, `csrc/main.cpp` | the **probe**: `BwBypass` (one lane) on the W channel, standing in for the engine before it existed | the probe-level, pre-rev2b gate |
| `gen_top_rev2b.py`, `build_rev2b.sh`, `run_rev2b.sh`, `csrc/main_rev2b.cpp` | the **engine**: `RoccMoonEngine2b` (`mbxr_engine_core`) and `wlaneClockSinkDomain` (`RoccMoonWHalf` → `TLBuffer` → `TLToAXI4` → `AXI4IdIndexer` → `AXI4UserYanker`), with `mbxr_wquiet` and `WLaneResetHold` on the lane's pins, driven through the engine's own RoCC command interface | the W-lane gate |
| `BENCH=mm2b ./build_rev2b.sh`, `csrc/main_mm2b.cpp` → `obj_mm2b/Vmm2b` | the **two-clock MM bench**: the same generated design, but driven by the REAL DRIVER (`sw/roccmoon/mbxr.c`, compiled in unchanged) doing whole dispatches — an MM reading the weight banks on the engine clock while the lane writes them on the lane clock, double buffer switching underneath — with a TileLink responder on client A and the AXI memory on the lane, checked against `kernel_linear_s8` | §9.14: the configuration nothing had driven, after `0x5A5A0013` returned wrong bytes on silicon |

**No shared tree is read.** Each bench builds from a copy of one elaboration under `archive/rtl_study/wlanetb/`, taken
inside the chipyard-lock session that produced it, together with the rev2 Verilog of the commit it was elaborated
against. `archive/` is not in git; it is on the bench machine.

| run | RTL copy | what it was |
|---|---|---|
| probe-level | `archive/rtl_study/wlanetb/gensrc/` | `BwWLaneProbeConfig`, before rev2b existed |
| gate, P4 at `433898d` | `archive/rtl_study/wlanetb/gate_rev2b/` | found finding (a): a short reset stalls the next load |
| validation, `0029629` + the reset hold | `archive/rtl_study/wlanetb/gate_rev2b_v2/` | (a) fixed; superseded |
| **build gate, `7b5d215` + the reset hold** | `archive/rtl_study/wlanetb/gate_rev2b_v3/` | **the gate for `0x5A5A0013`**, fence bit 41 enforced |
| **build gate, the engine's two crossing fixes** | `archive/rtl_study/wlanetb/gate_rev2b_v4/` | **the gate for `0x5A5A0013` as rebuilt** (`0a3737e5`); its `gensrc/` is v3's, reused because all nine engine files' module port declarations are byte-identical between the two commits, so the generated wrapper cannot differ (see its `PROVENANCE`) |

Each copy holds `gensrc/` (the generated RTL, with a `.provenance` naming the commit, the patches and the config),
`rtl_<commit>/` (the engine Verilog), the lock-session script and its output, and `runs/<stamp>/` with `SUMMARY.txt`,
one log per run, and the testbench sources as they were.

## Re-running the current gate

```bash
cd fpga/pynq-z2/rtl_study/wlanetb
READY_BIT=1 ./run_rev2b.sh          # builds all four variants and runs the matrix
```

It picks the newest `archive/rtl_study/wlanetb/gate_rev2b*` copy on its own; `GATE_ARC=<path>` pins an older one, and
`WLANETB2B_ROOT` / `WLANETB2B_CFG` / `WLANETB2B_RTL` point at any other copy (a private elaboration, say). The summary
header prints that path and the md5 of two generated files, so a run can never quote RTL it did not build — the first
attempt at the build gate did exactly that, and this is the guard against it.

* `READY_BIT=1` drives the engine the way `mbxr_dev.lane_wait` does: fence bit 41 before every weight load.
* `SKIP_BUILD=1` reuses the four binaries: `obj2b` (generated TileLink monitors on, fatal), `obj2b_synth`
  (`SYNTHESIS`: the logic as Vivado builds it), `obj2b_nowindow_synth` and `obj2b_holdfromquiet_synth` (mutants),
  `obj2b_nostop` (monitors report and the run continues, for diagnosis).
* Logs land in `results/run2b_<stamp>/` and are copied into the archive copy's `runs/`.

A single case, for a bisect:

```bash
./obj2b_synth/Vwlanetb2b_top --lat 60 --reset-cycles 10 --ready-bit abort     # finding (a)
./obj2b_synth/Vwlanetb2b_top --lat 60 --reset-cycles 10 --ready-bit stuck     # liveness: an RLAST that never arrives
./obj2b_synth/Vwlanetb2b_top --lat 20 --ready-bit window                      # finding (b)
```

`--noresethold`, `--noquiet`, `--rdrop` and `--rfirst` are the runtime mutants; `MUTANT=nowindow` and
`MUTANT=holdfromquiet` are the two build-time ones. Every run checks, in every lane cycle, that the AR contract holds,
that `quiet` equals the pins' AR/RLAST balance, and that the lane's reset never rises outside a SoC reset.

## Producing a new RTL copy

One chipyard-lock session, as §9.9 records: apply `patches/0110`, install the engine's Chisel from the commit under
test, append the check config to the donor copy of `PynqZ2Configs.scala`, elaborate, copy `gen-collateral` and the
rev2 Verilog into a new `gate_rev2b_*` directory with a `.provenance`, then revert everything and finish with
`scripts/02_verify_patches.sh --strict-optional`, which fails if `0110` is still applied.

## The two-clock MM bench

```bash
BENCH=mm2b ./build_rev2b.sh                       # -> obj_mm2b/Vmm2b
./obj_mm2b/Vmm2b --cases 30 --jitter 37           # 30 dispatches, bursts completing out of order
./obj_mm2b/Vmm2b --cases 30 --p1 9000 --lat 45 --alat 60   # a different lane period and latencies
```

Each case builds a weight image with the driver's own `mbxr_wimage_build`, runs `mbxr_run`, and compares every output
byte against `kernel_linear_s8`. `--debug` prints the first client-A Gets and weight-bank writes.

**The bench's own first bug is worth knowing about:** TileLink holds `address` constant across the beats of a
multibeat message (rocket-chip's `TLMonitor.legalizeMultibeatA` checks it), so a Put's beat offset comes from the beat
COUNT, not from the address field. Writing every beat at the address field keeps only the last beat of each 64-byte
block, and the symptom is a result that looks like bias-only arithmetic with a period of four. That was the bench,
not the design.
