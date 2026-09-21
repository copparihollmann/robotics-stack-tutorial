# Chipyard for the PYNQ-Z1/Z2 targets

The FPGA build consumes **generated Verilog**, not Chipyard. Those are separable, and
separating them is what makes this repo buildable without a Chipyard install:

| You want to… | You need | Cost |
|---|---|---|
| build a bitstream for a pinned config | the vendored collateral in `gensrc/` | ~1 MB, seconds |
| change the SoC config and re-elaborate | a real Chipyard tree | hours, tens of GB |

## Building a bitstream (no Chipyard)

```bash
scripts/08_gensrc.sh            # unpack every vendored config into out/gensrc/
scripts/08_gensrc.sh --list     # what is vendored, and where it came from
```

`tcl/build_rocket.tcl`, `tcl/ooc_area.tcl` and `rtl_study/pext/ooc_pext.tcl` find it
automatically. Override with `CHIPYARD_GENSRC=<dir>`.

### What is in a bundle

Only what Vivado reads: every path listed in `<CONFIG>.top.f`, plus the SRAM macro file
`gen-collateral/*.top.mems.v` that the mem-gen pass emits and `top.f` does not list. That
is ~14 MB of SystemVerilog, ~1 MB compressed. The other ~55 MB of an elaboration directory
— FIRRTL, annotation JSON, the chisel/firtool logs, the simulation-only `TestHarness` — is
not an input to any flow here and is not carried.

`top.f` is written with **absolute** paths into whichever tree elaborated it, so the bundle
stores bare filenames and `scripts/08_gensrc.sh` regenerates the list against the unpack
location. Every consumer then works unchanged.

### Provenance

Each bundle ships a `PROVENANCE` file, also copied out to `gensrc/<CONFIG>.provenance`:
the Chipyard revision, the rocket-chip revision, which of `patches/*-rocketchip-*.patch`
were in the tree (measured by reverse-applying each one), and the tree's uncommitted delta.

That last field is the point. The shared tree these were elaborated from carries dozens of
uncommitted edits, so **"Chipyard at revision X" is not on its own a reproducible
statement** — which is exactly why the collateral is vendored rather than re-derived.

Note that patch state is read at *pack* time, not at elaboration time. When a patch file is
newer than the elaboration, the provenance says so explicitly:

```
patch: 0004-rocketchip-mcycle-free-run.patch  applied_at_pack_time=yes  <-- STALE: patch file is newer than this elaboration
```

`PynqZ2RocketTacitConfig` carried that marker until the single-core bitstream was rebuilt
for the mcycle patch: its bundle was elaborated before the patch landed, and matched the
pre-patch bitstream on the bench. **Both bundles are now clean** — each records
`0004-rocketchip-mcycle-free-run.patch  applied_at_pack_time=yes` with no STALE note, and
each matches the tracked bitstream built from it. The marker did its job: it was true when
it appeared, and re-packing immediately after re-elaborating is what cleared it. See
[`../docs/TACIT_MULTICORE.md`](../docs/TACIT_MULTICORE.md) §8.

`patches/0008-rocket-pext-alu.patch` landed in the shared tree *after* the two non-P-ext
bundles were packed, so their `PROVENANCE` files do not list it and they have deliberately
**not** been re-packed. That is sound, not an oversight: `scripts/09_patch_rocket_pext.sh
--verify` measured the patch to be inert for a config that does not set `usePExt` — 500 of
505 generated files byte-identical, the other five differing only in firtool source-locator
comments and one simulation-only `$error` string. Re-elaborating either bundle today would
produce the same bitstream. Only `PynqZ2RocketBigLittlePextTacitConfig` records it, because
only that config depends on it.

## Changing the config (Chipyard required)

`PynqZ2Configs.scala` is the target definition. It must live inside a Chipyard tree to
elaborate — copy it to:

```
$CHIPYARD_DIR/generators/chipyard/src/main/scala/config/PynqZ2Configs.scala
```

then elaborate (the conda hooks reference unset variables, so do not `set -u`):

```bash
export CHIPYARD_DIR=/path/to/chipyard
cd "$CHIPYARD_DIR" && source env.sh
make -C sims/verilator CONFIG=PynqZ2RocketTacitConfig verilog
```

Output lands in
`sims/verilator/generated-src/chipyard.harness.TestHarness.PynqZ2RocketTacitConfig/gen-collateral/`.
The FPGA build consumes `ChipTop.sv` and its submodules from there and ignores
`TestHarness.sv`, which is simulation-only.

If this repo needs a change *inside* Chipyard, it goes in `patches/` and is applied by a
script — never edited in place, because the tree is shared. There are two such scripts, and
they are deliberately separate:

| script | patch | what it changes |
|---|---|---|
| `scripts/07_patch_rocketchip.sh` | `patches/*-rocketchip-*.patch` | `rocket/CSR.scala` — `mcycle` free-runs through `wfi` |
| `scripts/09_patch_rocket_pext.sh` | `patches/*-rocket-*.patch` | MBP packed SIMD: `tile/Core.scala`, `rocket/{ALU,IDecode,RocketCore}.scala` |

Note the filenames: 07 globs `*-rocketchip-*.patch` and exits early on its own marker, so the
P-ext patch is named `*-rocket-*` to stay out of that glob. The two are independent and
either can be applied without the other. Each keeps its own `.bak` and has `--check` and
`--revert`.

`scripts/09_patch_rocket_pext.sh --verify` is the **acceptance test for the patch itself**:
it elaborates `PynqZ2RocketBigLittleTacitConfig` — the config two tracked bitstreams are
built from, and which does *not* set `usePExt` — with the patch reverted and again with it
applied, and diffs every generated file. Measured: 500 of 505 files byte-identical; the five
that differ carry only firtool source-locator comments whose line numbers moved, plus one
simulation-only `$error` string inside an `` `ifndef SYNTHESIS `` block that quotes an
assertion's own source line. Stripped of comments all five are identical. That check exists
because an earlier generator patch was declared "layout-identical by construction" when it
had silently dropped a register's write path.

Then re-vendor, immediately, so the provenance is unambiguous:

```bash
scripts/08_gensrc.sh --pack PynqZ2RocketTacitConfig
```

## The configs

| Config | What it is |
|---|---|
| `PynqZ2RocketTacitConfig` | single-core Rocket + TACIT — the single-core bitstream |
| `PynqZ2RocketBigLittleTacitConfig` | dual-core big.LITTLE Rocket + TACIT — the SMP bitstream |
| `PynqZ2RocketBigLittlePextTacitConfig` | the same pair with **MBP packed SIMD on hart 0 only** — four custom-0 ops inside Rocket's ALU. Needs `patches/0008-rocket-pext-alu.patch`, applied by `scripts/09_patch_rocket_pext.sh`. Hart 1's `RocketALU_1` is byte-identical to the stock `RocketALU`; hart 1 traps on the encodings, which is the point. See `../docs/PEXT_SPEC.md`. |
| `PynqZ2RocketConfig` | the same without TACIT, so the encoder's area on *this* device is a measurement rather than a number carried over from the Arty-200T builds |

Only the two that a tracked bitstream is built from are vendored. Add another with
`scripts/08_gensrc.sh --pack <CONFIG>` after elaborating it.
