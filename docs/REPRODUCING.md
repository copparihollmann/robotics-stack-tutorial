# Reproducing this repo from nothing

The standard this document holds itself to: **someone with this repo, a Vivado licence and
a PYNQ-Z1 can get from nothing to a running traced workload without access to any other
directory on the machine it was developed on.**

Everything below was run, not asserted. Where something cannot be reproduced in isolation,
it says so and says what it would take.

---

## 1. What is and is not containerised

| | Containerised | Why |
|---|---|---|
| Zephyr toolchain (conda, SDK, west modules) | yes | installed into the checkout by `scripts/00_bootstrap.sh` |
| TACIT spike + decoder | yes | built from pinned submodules + `patches/` |
| Lab A — trace, decode, golden check | yes | **bit-exact**, needs no hardware |
| Verilator RTL gates | yes | Verilator 5.020 from the distro |
| Zephyr builds for `chipyard_pynqz1` | yes | produces a `zephyr.bin`; loading it needs the board |
| Chipyard generated Verilog | yes | **vendored**, see §5 |
| Bitstream build (Vivado) | **no** | licensed, ~100 GB, cannot be redistributed — §6 |
| Anything touching the PYNQ board | **no** | needs the hardware on the bench — §7 |
| Chipyard *elaboration* (changing the SoC config) | **no** | hours and tens of GB; not needed to build a bitstream — §5 |

The container is the reference environment. A host-native install works the same way and
runs the same scripts; the container just fixes the distro, the compilers and Verilator so
"works here" means something.

---

## 2. Prerequisites

**Container route** — Docker, ~25 GB of free disk (measured: 18.2 GiB in the checkout
plus a 1.53 GB image), and network access to github.com, pypi.org, conda-forge and
crates.io. Nothing else.

**Host-native route** — a Linux x86-64 box with:

```
build-essential autoconf automake libtool pkg-config
cmake (<4) ninja-build
python3
device-tree-compiler                 # spike's configure looks for dtc
libboost-dev libboost-regex-dev libboost-system-dev   # spike
verilator >= 5.0                     # the sim gates use --binary --timing
rust/cargo (>= 1.80; 1.97.1 is what the container pins)
git, curl, wget, tar, xz-utils
```

That list is the `Dockerfile`'s apt line; it is the authoritative version.

**For bitstreams**, additionally: Vivado 2023.1 and its PYNQ-Z1/Z2 board files. **For
hardware**, additionally: a PYNQ-Z1, the v3.1.1 SD image, and passwordless SSH to it.

---

## 3. From nothing to a traced workload

```bash
git clone <this repo> && cd iiswc-tutorial
```

Do **not** pass `--recurse-submodules`. `zephyr-chipyard-sw` carries a dozen submodules of
its own, only a few of which are wanted, and one (`modelblaster`) is declared with an SSH
URL. `scripts/00_bootstrap.sh` checks out the right ones and rewrites that URL to https —
see §8.

### Container

```bash
scripts/docker/build.sh                             # ~2 min, 1.53 GB image
scripts/docker/run.sh scripts/00_bootstrap.sh       # the long one
scripts/docker/run.sh scripts/05_build_tacit_tools.sh
scripts/docker/run.sh scripts/01_doctor.sh
scripts/docker/run.sh scripts/10_tacit_hello.sh
```

`scripts/docker/run.sh` bind-mounts the checkout **at its own absolute path** and runs as
your uid, so the multi-GB install lands in your checkout, survives the container, and is
owned by you. Run the same commands without the wrapper for a host-native install.

The same-path mount is not cosmetic. `00_bootstrap.sh` installs a conda env into the
checkout, and conda bakes absolute prefixes into every entry point:

```
$ head -1 zephyr-chipyard-sw/tools/miniforge3/envs/zephyr/bin/west
#!/work/zephyr-chipyard-sw/tools/miniforge3/envs/zephyr/bin/python3.12
$ zephyr-chipyard-sw/tools/miniforge3/envs/zephyr/bin/west --version
cannot execute: required file not found
```

That is what mounting at `/work` produces, and it means an env bootstrapped in the
container is unusable on the host and vice versa. Mounted at its own path, one bootstrap
serves both routes — verified: after a container-only bootstrap, the host runs
`.../envs/zephyr/bin/west --version` and gets `West version: v1.5.0`. Set `IISWC_MOUNT` if
you want a deliberately path-independent mount anyway.

### What each stage costs, and how to tell it worked

| Stage | Wall time | Disk added | Success looks like |
|---|---|---|---|
| `docker/build.sh` | 2 min | 1.53 GB (image) | `docker image inspect iiswc-tutorial:latest` |
| `00_bootstrap.sh` | 5 min 39 s | +15.2 GiB | ends with `==> Bootstrap done` |
| `05_build_tacit_tools.sh` | 48 s | +2.7 GB | `third_party/riscv-isa-sim/build/spike` and `third_party/tacit-decoder/target/release/ltrace-decoder` exist |
| `01_doctor.sh` | <1 s | — | `All checks passed.` |
| `10_tacit_hello.sh` | 11 s | 138 MB under `out/` | `PASS  reproduces the golden run` |
| three sim gates | 15 s for all three | — | `ALL CHECKS PASSED` |
| `west build -b chipyard_pynqz1` | 6 s | small | `out/.../zephyr/zephyr.bin` (47,696 bytes) |
| `scripts/08_gensrc.sh` | 2 s | 31 MB under `out/` | `--list` prints both configs and their provenance |

**Those times are from a 48-core machine on a fast network and are a floor, not a
promise.** The ratios are the useful part: the bootstrap dominates, and it is dominated in
turn by downloads. Spike builds at `-j$(nproc)` — 35 s here, tens of minutes on a laptop.

### The strongest check in the repo

`scripts/10_tacit_hello.sh` is bit-exact and needs no hardware. It must print:

```
    ok    instructions_traced      expected     541930   got     541930
    ok    tacit_out_bytes          expected     258319   got     258319
    ok    decoded_txt_lines        expected     793201   got     793201
    ok    perfetto_begin_slices    expected       2372   got       2372
    PASS  reproduces the golden run
```

Four numbers derived from a Zephyr kernel built by a pinned SDK, executed by a patched
Spike, and decoded by a patched decoder. If all four match, the entire software half of the
tutorial is reproduced exactly. If any differ, one of the pins in `deps.lock` or one of the
patches in `patches/` did not take.

---

## 4. Disk and time, measured

One uninterrupted run, fresh `git clone` to `zephyr.bin`, in the container:

```
TIME_TOTAL   = 421 s   (7 minutes)
disk before  = 335 MiB (the clone)
disk after   = 18.2 GiB
image        = 1.53 GB (separate, in Docker's storage)
```

Where the 18.2 GiB goes:

| | Size | What |
|---|---:|---|
| `zephyr-chipyard-sw/tools/miniforge3` | 6.9 GB | conda, and the `zephyr` env (6.2 GB of it) |
| `zephyr-chipyard-sw/tools-manual` | 4.1 GB | Zephyr SDK 1.0.0-beta1: riscv64 GNU, LLVM, host tools |
| `zephyr-chipyard-sw/zephyr_ws` | 3.0 GB | the kernel plus every west module |
| `third_party` | 2.7 GB | spike and decoder source *and* build trees |
| `.git` | 2.2 GB | this repo plus every submodule's object store |
| `out` | 138 MB | Lab A artifacts + the unpacked Chipyard collateral |
| `fpga` | 9.9 MB | including 2.0 MB of vendored Chipyard Verilog and 19 MB of tracked bitstreams |

**5.3 GB of that is CUDA nobody here uses** — 3.2 GB `nvidia/`, 1.2 GB `torch/`, 897 MB
`triton/`, dragged in by `pip install -e ./tools/gym-pybullet-drones` inside upstream's
`install_submodules.sh`. See §9.

Add ~118 MB for `--modelblaster` (measured; clones in under 2 s over https).

To start over: `rm -rf zephyr-chipyard-sw/tools zephyr-chipyard-sw/tools-manual
zephyr-chipyard-sw/zephyr_ws third_party/*/build third_party/*/target out` and re-run the
bootstrap. Everything it installs lives inside the checkout, which is the whole point.

---

## 5. The Chipyard story

**A bitstream build needs generated Verilog, not Chipyard.** Those are separable, and this
repo separates them:

```
build a bitstream from a pinned config  ->  fpga/pynq-z2/chipyard/gensrc/  (~1 MB/config)
change the SoC config and re-elaborate  ->  a real Chipyard install (hours, tens of GB)
```

### Vendored collateral

```bash
scripts/08_gensrc.sh          # unpack every vendored config into out/gensrc/
scripts/08_gensrc.sh --list   # what is vendored, and where it came from
```

Each bundle carries only what Vivado reads — the files listed in `<CONFIG>.top.f` plus the
`*.top.mems.v` SRAM macros the mem-gen pass emits — which is ~14 MB of SystemVerilog and
~1 MB compressed, against ~70 MB for a whole elaboration directory.

`tcl/build_rocket.tcl` resolves the sources in this order:

1. `$CHIPYARD_GENSRC` — explicit override
2. `$CHIPYARD_DIR`'s elaboration for the config — so someone who just re-elaborated gets
   what they just built
3. the vendored bundle unpacked under `$CHIPYARD_GENSRC_ROOT` (default `out/gensrc/`)

and errors with the command to run if none resolve. There is no hard-coded path into
anyone's scratch directory any more — that was the single biggest reproducibility hole in
this repo and it is closed.

### "Chipyard at revision X plus patches"

A bare revision is not enough. The tree these were elaborated from carries dozens of
uncommitted edits, so each bundle ships a `PROVENANCE` file recording the Chipyard
revision, the rocket-chip revision, which `patches/*-rocketchip-*.patch` were present
(measured by reverse-applying each one, not by grepping for a marker), and the tree's
uncommitted delta.

Patch state is read at *pack* time, so a bundle packed long after it was elaborated says so:

```
patch: 0004-rocketchip-mcycle-free-run.patch  applied_at_pack_time=yes  <-- STALE: patch file is newer than this elaboration
```

That marker earned its keep within the hour. `PynqZ2RocketTacitConfig` was first vendored
from an elaboration that predated `patches/0004`, the provenance said so in as many words,
and the single-core bitstream was re-elaborated and re-packed against the patched tree in
response — so `rdcycle` now means the same thing on both bitstreams. The acceptance
evidence: **1 of 406 generated files changed** (`CSRFile.sv`), and **no golden moved** —
Labs B2 and B4 produced byte-identical traces before and after, which incidentally proves
neither traced window contains a `wfi`.

Both bundles are clean now, and `scripts/08_gensrc.sh --list` — not this paragraph — is
where you check that.

**Re-pack immediately after re-elaborating** and the ambiguity never arises:

```bash
export CHIPYARD_DIR=/path/to/chipyard
scripts/07_patch_rocketchip.sh                            # apply our edits
cd "$CHIPYARD_DIR" && source env.sh
make -C sims/verilator CONFIG=PynqZ2RocketBigLittleTacitConfig verilog
cd - && scripts/08_gensrc.sh --pack PynqZ2RocketBigLittleTacitConfig
```

`fpga/pynq-z2/chipyard/README.md` has the full procedure.

#### What the foreign delta actually does to the Verilog

`PROVENANCE` names the dirty rocket-chip files. It does not say what is *in* them, and
the answer matters: the donor tree is a working tree for the riskybird vector project, so
alongside `patches/0004` and `patches/0008` it carries in-flight Saturn/V-extension work
that nobody here wrote. Two of those hunks survive elaboration into every bundle:

```
Rocket.sv:468  reg [2:0] vec_sresp_outstanding;
Rocket.sv:469  wire id_take_interrupt = _csr_io_interrupt
                 & {mem_reg_valid & mem_ctrl_vec & mem_ctrl_wxd
                  | wb_reg_valid  & wb_ctrl_vec  & wb_ctrl_wxd, vec_sresp_outstanding} == 4'h0;
```

So the vendored RTL is **not** byte-reproducible from a clean rocket-chip plus our two
patches, and a from-scratch elaboration will differ. That is a real gap in the claim this
document makes, and it is stated here rather than discovered later.

It is also, in this configuration, **inert**. The evidence, from the generated Verilog
rather than from the Scala:

- `id_ctrl_vec` does not exist in `Rocket.sv` (0 occurrences). Our configs instantiate no
  vector unit, so the decode table has no `vec` output to drive the pipeline registers.
- `mem_ctrl_vec`'s only assignment is `mem_ctrl_vec <= _GEN_16 & mem_ctrl_vec` — a
  self-AND with no external driver, where every sibling register gets `ex_ctrl_*`. On the
  FPGA its flop initialises to 0 from the bitstream, so it is 0 forever.
- Therefore `wb_ctrl_vec` is 0 forever, `vec_sresp_outstanding` never increments off its
  reset value, the concatenation is always `4'h0`, and `id_take_interrupt` reduces to
  `_csr_io_interrupt` — exactly the upstream expression it replaced.

Vivado trims the constant-0 flop, which is why this never showed up as area. The
consequence is that **no measured number in this repo is affected**: the interrupt path
is bit-identical in behaviour, and the dead register costs nothing after synthesis. The
CSR.scala half of the foreign delta does not appear at all — it lives inside
`io.vector.map { vio => ... }`, which elaborates to nothing without a vector unit
(`grep -c vstart` over any bundle returns 0).

The correct fix is to re-elaborate from a clean rocket-chip at `rocketchip_rev` with only
`patches/0004` and `patches/0008` applied, and re-pack. Until that is done, this section
*is* the disclosure, and `scripts/02_verify_patches.sh` is what will flag the donor tree
the moment `CHIPYARD_DIR` is set.

**Known deltas between vendored bundles and the current tree:**

- committed gensrc bundles for 0006/0010 predate 0061/0091/0092; current elaboration differs only in the source-line numbers inside `ifndef SYNTHESIS` assertion messages in `MSHR.sv`, `TLCacheCork.sv` and one `TLMonitor` (all three patches are opt-in and default off), verified equivalent 2026-09-17 (`fpga/pynq-z2/docs/MEMORY_BANDWIDTH.md` §9.8)

---

## 6. Vivado: what has to happen on a host that has it

Vivado is licensed and roughly 100 GB installed. It cannot go in a redistributable image,
and there is no honest way around that. The bitstream steps therefore run on a host — or a
container with the installation and a licence server bind-mounted in.

```bash
# on a machine with Vivado 2023.1
source /path/to/Vivado/2023.1/settings64.sh
export XILINXD_LICENSE_FILE=<port>@<server>       # or a local .lic

scripts/08_gensrc.sh                               # unpack the vendored Verilog
fpga/pynq-z2/scripts/build_all_z1.sh               # single-core + DRAM test
fpga/pynq-z2/scripts/build_smp_z1.sh               # dual-core
```

Those scripts gate on the Verilator testbenches first — seconds, no licence — because
three hardware bugs reached the board through RTL that had never been simulated. **Run the
sim gates in the container even if the bitstream build happens elsewhere.**

Inside the tutorial container the build scripts fail at the first `vivado` invocation with
`vivado: command not found`, which is the truthful answer. The `.bit` files for both Z1
bitstreams are tracked in this repo precisely so that the hardware labs can be run without
a Vivado licence at all.

**To containerise the Vivado steps anyway**, mount the installation read-only and pass the
licence through:

```bash
IISWC_DOCKER_ARGS="-v /opt/Xilinx:/opt/Xilinx:ro -e XILINXD_LICENSE_FILE" \
  scripts/docker/run.sh bash -lc 'source /opt/Xilinx/Vivado/2023.1/settings64.sh && fpga/pynq-z2/scripts/build_all_z1.sh'
```

That is a *mount*, not a redistribution. It is the same claim as "you need a licence" — it
just avoids a second machine. Nothing in this repo has been validated that way, because the
licence is not ours to exercise from a container.

---

## 7. The board

Nothing on the host reaches the board except over SSH, and every board script goes through
`scripts/with_board.sh`, which takes a `flock` on `.board.lock` so two people cannot drive
one PYNQ at once.

The board's own software — `/usr/local/share/pynq-venv`, XRT — is part of the PYNQ v3.1.1
SD image, not a host dependency. `fpga/pynq-z2/docs/BRINGUP.md` covers flashing the card
and getting passwordless SSH working.

Labs A and the Verilator gates need none of this.

---

## 8. Things that were borrowed, and what replaced them

This repo used to depend on directories outside itself. Each is listed with what it was and
what it is now.

| Was | Now |
|---|---|
| `zephyr-chipyard-sw/tools/miniforge3` → a directory outside the checkout | installed into the checkout by the full `00_bootstrap.sh` |
| `zephyr-chipyard-sw/tools-manual` (the Zephyr SDK) → ditto | ditto |
| `zephyr_ws/{modules,tools,bootloader}` → ditto | `west update` into the checkout |
| `CHIPYARD_ROOT` hard-coded to one developer's Chipyard checkout | vendored collateral, §5; `CHIPYARD_DIR` has no default |
| `build_rocket.tcl`'s hard-coded `CHIPYARD_GENSRC` | three-step resolution, §5 |
| `zephyr-chipyard-sw` submodule over SSH | https |
| `modelblaster` submodule over SSH | URL rewritten to https by `00_bootstrap.sh`; opt-in with `--modelblaster` |

`scripts/00_bootstrap.sh --reuse PATH` still exists and still creates those symlinks. It is
a developer convenience for a machine that already has a built workspace, it is fast, and
the result is explicitly **not** self-contained. The shipping path is the full install.

### ModelBlaster and SSH

`zephyr-chipyard-sw/.gitmodules` declares `modelblaster` as
`git@github.com:ucb-bar/ModelBlaster.git`. A container has no SSH key. The repository is
public over https, so `scripts/00_bootstrap.sh` rewrites the URL in the local clone's
config — not in upstream's `.gitmodules`, which is not ours to edit.

Only Lab B5 (`scripts/24_rocket_modelblaster.sh`) needs it, so the checkout stays opt-in:

```bash
scripts/00_bootstrap.sh --modelblaster
# or later:
git -C zephyr-chipyard-sw submodule update --init modelblaster
```

The container image also carries a system-wide
`url."https://github.com/".insteadOf "git@github.com:"`, so any other SSH-declared
submodule that turns up clones anyway. If you need a genuinely private repository instead,
mount an agent socket: `IISWC_DOCKER_ARGS="-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent"`.

---

## 9. Known rough edges

**Two bugs were sitting in the from-scratch path, because nobody had ever taken it.** Both
are fixed; they are recorded here because they are the shape of thing this exercise exists
to catch.

1. `zephyr-chipyard-sw/scripts/install_conda.sh` line 6 is the literal text
   `scripts/install_conda.sh#` — a comment that lost its `#` upstream. Bash runs it as a
   command and the installer exits 127 having downloaded nothing. Carried as
   `patches/0005-zcs-install-conda-stray-line.patch`.
2. `scripts/06_patch_zephyr.sh` tested `[ -d "$ZEPHYR/.git" ]`. The full bootstrap gets the
   kernel with `git submodule update --init`, and a submodule's `.git` is a **file**
   holding a `gitdir:` pointer. The directory test rejected a perfectly good checkout. It
   asks `git rev-parse --git-dir` now.

Neither could show up under `--reuse`, which clones the kernel standalone and never runs
the upstream installer at all. That is the whole argument for validating the shipping path.

**The bootstrap pulls ~5.3 GB of CUDA it does not need.** `install_submodules.sh` does
`pip install -e ./tools/gym-pybullet-drones`, which drags in `torch`, `triton` and the full
`nvidia-*` wheel set: measured 3.2 GB of `nvidia/`, 1.2 GB of `torch/` and 897 MB of
`triton/` in the conda env, out of 6.2 GB total — for a drone flight simulator that no lab
in this repo uses. Upstream already marks the install optional and tolerates its failure;
making it opt-in is a one-line change to a script this repo does not own, so it has been
left alone and measured instead. If you are tight on disk, that is where a quarter of the
install went.

**`--reuse` still creates symlinks that leave the repo.** That is what it is for. A tree
bootstrapped that way is fast and is not self-contained; `find . -type l -xtype d` will
show you where it points. The full install is the one that has been validated end to end.

**Conda envs are not relocatable.** Covered above: `scripts/docker/run.sh` mounts the
checkout at its own path for exactly this reason. If you move a bootstrapped checkout to a
different path, re-run `scripts/00_bootstrap.sh` — it is idempotent, but conda will need
its env rebuilt, so expect to delete `zephyr-chipyard-sw/tools/miniforge3` first.

**The container image bakes in the building user's uid.** `scripts/docker/build.sh` passes
your `id -u`/`id -g` so bind-mounted writes are owned by you. Two users on one machine
sharing the tag `iiswc-tutorial:latest` will fight over it — set `IISWC_IMAGE` to something
per-user if that comes up.

**Verilator versions differ between the container and the machine the RTL work was done
on** — 5.020 from Ubuntu 24.04 against 5.022 from Chipyard's conda env. All three sim gates
pass identically on both. The gates check assertions, not timing, so this is not expected to
matter; it is recorded because it has not been checked against any other version.

**Hardware goldens cannot be checked without hardware.** `expected/tacit.json` (Lab A) is
the only one the container can verify. `expected/{hello_world,tacit_dma,tacit_boot,smp_hart_proof,modelblaster_*,membench,tacit_smp}.json`
all need the board, and `scripts/with_board.sh` serialises access to the single PYNQ on the
bench.

---

## 10. What was actually run, and when

Every number and every claim above came from executing the flow in the container against a
fresh `git clone` of this repo — not the development tree — on 2026-09-16.

```
git clone --no-hardlinks <this repo> repo      # 335 MiB, submodules NOT checked out
docker run -v $PWD/repo:/work  ...  ./scripts/00_bootstrap.sh
docker run -v $PWD/repo:/work  ...  <05, 01, 10, sim gates, west build, build_smp_z1.sh>
```

| Stage | Result |
|---|---|
| `git submodule update --init` (from `00_bootstrap.sh`) | 3 submodules over https, no SSH key present |
| `00_bootstrap.sh` full install | rc=0, `==> Bootstrap done` |
| `05_build_tacit_tools.sh` | rc=0, spike + `ltrace-decoder` built from the pins and `patches/` |
| `01_doctor.sh` | `All checks passed.` |
| `10_tacit_hello.sh` | **PASS** — 541930 / 258319 / 793201 / 2372, exactly `expected/tacit.json` |
| `sim/run_ctrl_sim.sh` | `ALL CHECKS PASSED`, 34 checks |
| `sim/run_soc_ctrl_sim.sh` | `ALL CHECKS PASSED`, 44 checks |
| `sim/run_dram_sim.sh` | `ALL CHECKS PASSED`, 16 checks |
| `west build -b chipyard_pynqz1 samples/tacit_dma` | rc=0, `zephyr.bin` 47,696 bytes |
| `scripts/08_gensrc.sh` | both configs unpacked, 833 source files total |
| `build_smp_z1.sh synth` (no Vivado) | sim gates pass, then exits 1 with the message in §6 |
| `git -C zephyr-chipyard-sw submodule update --init modelblaster` | rc=0 over https with no `~/.ssh` at all |
| symlinks leaving the checkout, after a full bootstrap | **0** (`find . -type l -lname '/*'` — all 543 hits point back inside the checkout) |
| the container has no `/scratch2` and no `~/.ssh` | confirmed in the run log; it could not borrow if it tried |

The flow was run three times over: twice mounted at `/work`, and once more through
`scripts/docker/run.sh` as shipped (mounted at the checkout's own path, 505 s). All three
produced the same four numbers.

### The one number that proves it

`elf_bytes` differs every time, because the build path is embedded in the ELF and the three
runs used three different path lengths. Every *checked* number is identical:

```
                     container    container    dev host    expected
                       (/work)   (own path)
elf_bytes               274560       282112      278896    not checked
instructions_traced     541930       541930      541930        541930
tacit_out_bytes         258319       258319      258319        258319
decoded_txt_lines       793201       793201      793201        793201
perfetto_begin_slices     2372         2372        2372          2372
```

Three filesystem layouts, two distributions' worth of host toolchain, and a
541,930-instruction trace that agrees to the byte. That is what `expected/tacit.json`
deliberately not checking `elf_bytes` is for.

### What this run did NOT prove

* No bitstream was built. Vivado is not in the image (§6). The tracked `.bit` files were
  built on this host before any of this work and are unchanged by it.
* No board was touched. Every `expected/*.json` other than `tacit.json` needs the PYNQ.
* Chipyard was not installed or elaborated. The vendored collateral was *packed from* the
  shared tree on the development host and *unpacked* in the container; the round trip was
  verified (833 files, every path in every `top.f` present), but re-deriving it from
  Chipyard was not attempted and would take hours.
