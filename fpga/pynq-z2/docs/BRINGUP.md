# PYNQ-Z2 bring-up flow

## Short answer: you do not configure the ARM yourself

The PS **does** need configuring — DDR controller init and training, PLLs, the PL clocks,
MIO pinmux — but on this board that is already done for you, by the boot chain on the
stock PYNQ SD image:

```
BootROM (on-chip, immutable)
  └─ reads the boot-mode strap (JP1) and loads BOOT.BIN from SD
      └─ FSBL  ← this is what configures the PS: ps7_init() writes the DDR controller,
      │         PLLs, FCLK dividers and MIO pinmux from the PS7 parameters it was
      │         built with
      └─ U-Boot → Linux (PYNQ image) → your PL bitstream, loaded at runtime
```

The FSBL's `ps7_init` is generated from a PS7 configuration. Ours is derived from the same
TUL board preset the PYNQ image's FSBL was built from, so the DDR geometry we assert in
`tcl/verify_ps7.tcl` is the geometry the running PS has already programmed. **No custom
FSBL, no BOOT.BIN rebuild, no Vitis.**

By the time Linux is up, DDR is initialised and the AFI/HP interfaces are live. Loading a
bitstream afterwards goes through the kernel's FPGA manager, which also handles the PS–PL
level shifters (`SLCR.LVL_SHFTR_EN`) — the step people forget when programming the PL by
hand.

## What is actually on this bitstream

**No Chipyard content whatsoever.** No Rocket, no TACIT encoder, no Gemmini, no Saturn.
The PL contains exactly three things:

| Block | Source | Role |
|---|---|---|
| PS7 hard block | `processing_system7` IP, configured | DDR controller, clocks, M_AXI_GP0, S_AXI_HP0 |
| `axi_ctrl_regs` | `src/axi_ctrl_regs.v` | AXI3 slave on GP0 — control/status registers |
| `axi_dram_selftest` | `src/axi_dram_selftest.v` | AXI3 master on HP0 — write/verify traffic |
| LED heartbeat | `src/pynqz2_top.v` | board self-reports with nothing attached |

301 LUT, 391 FF, **0 BRAM, 0 DSP** of 53,200 / 106,400 / 140 / 220. The zeros are a useful
tell: any real Rocket build uses both, so if a future bitstream reports 0 BRAM you have
built the wrong thing.

That emptiness is the point. Chipyard has no precedent for using a Zynq PS, so the first
bitstream deliberately carries nothing but the untested link — if it fails, the failure is
unambiguous. Rocket goes in once this returns `ERRCNT == 0`.

## Equipment

**Per board:**

| Item | Spec | Note |
|---|---|---|
| microSD card | **≥16 GB**, Class 10 | PYNQ boots from SD; one per board. **8 GB is NOT enough** — see note |
| Micro-USB cable | — | power + UART console, into J8 (PROG) |
| Ethernet cable | — | ssh / Jupyter; or direct to a laptop with a static IP |
| 12 V PSU *(optional)* | 2.1 mm, **centre-positive**, 7–15 VDC | only if USB power proves marginal |

**Shared:** a PC to write the SD images, and a switch or router — or direct Ethernet per
board with static IPs.

On power, the manual is explicit: the micro-USB port *"should provide enough power for most
designs. More demanding applications may require more power than the USB port can
provide."* This bitstream is 301 LUTs and will not strain anything. A Rocket + TACIT build
at ~61 % LUT is a different proposition, so budget for a couple of 12 V supplies before
handing boards to a room.

**Jumpers, per board:** JP1 → **SD** boot, J9 → **USB** (or REG if using the barrel jack).

### Can we avoid an SD card per board?

Not practically. JP1 does offer QSPI and JTAG boot as alternatives, but:

- **QSPI** is 16 MB — nowhere near a PYNQ Linux rootfs.
- **JTAG** boot works and needs no SD, but only gets you bare-metal. You would lose the
  PYNQ image's FSBL, which is precisely what makes "the ARM needs no configuration" true,
  and you would need the XSA/FSBL fork described at the end of this document — plus a JTAG
  connection held open per board.

So: one card per board. They image identically from a single master (`dd` or Etcher), the
bitstream is the same on every board, and cards are a few dollars each — call it the board
price plus roughly $15 of accessories per seat.

## Day-one flow

1. **Write the SD card.** Official PYNQ-Z2 image, **v3.1.1**:
   <https://download.amd.com/opendownload/pynq/pynq_z2_v3.1.1.zip> (1.79 GB download).

   > **≥16 GB card.** The archive expands to `pynq_z2_v3.1.1.img` at **8,337,309,696 bytes
   > = 8.34 GB decimal**, which is *larger* than a nominal 8 GB card (~8.0 GB). PYNQ's own
   > docs still say "8 GB minimum"; that is stale for this release. Verified by
   > `unzip -l` on the downloaded archive.

   Write it with Balena Etcher (only offers removable devices, which is the safe default)
   or `dd`:

   ```bash
   lsblk -o NAME,SIZE,TRAN,RM,MODEL     # confirm TRAN=usb and RM=1 before proceeding
   unzip pynq_z2_v3.1.1.zip
   sudo dd if=pynq_z2_v3.1.1.img of=/dev/sdX bs=4M status=progress conv=fsync && sync
   ```

   Set JP1 to boot from SD and J9 to your power source. Boot it; confirm you can ssh in
   (`xilinx:xilinx`).

### 1b. Key-based SSH and passwordless sudo — do this before any lab

`docs/REPRODUCING.md` sends the reader here for *"flashing the card and getting passwordless
SSH working"*, and until 2026-09-21 this file covered only the first half. Both halves are
mandatory, and neither is optional for stylistic reasons:

* **Every board path in this repo runs `ssh -o BatchMode=yes`** — `scripts/provision_board.sh:31,77`,
  `scripts/lib/board_id.sh:61`, and the `SSH=(...)` array in every lab. `BatchMode=yes`
  **disables password authentication outright**. Someone with the right address and the right
  password still cannot run a single lab until their public key is on the board.
* **The labs run `sudo python3 …` non-interactively**, because `pynq.Bitstream().download()`
  and `/dev/mem` both need root. Without a NOPASSWD rule every board tool stalls on a prompt
  it cannot answer, and the prompt is echoed into the run log.

```bash
# ON YOUR MACHINE -- one key, once.  Skip ssh-keygen if you already have a key.
ssh-keygen -t ed25519 -C iiswc-tutorial            # accept the defaults
ssh-copy-id xilinx@<board>                         # the ONE time a password is typed

# Windows has no ssh-copy-id; PowerShell equivalent, and the rest is identical:
#   type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh xilinx@<board> "mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"

# ON THE BOARD -- passwordless sudo for the lab user.  visudo -c FIRST: a malformed file
# here locks you out of root on a machine whose only other console is a serial cable.
echo 'xilinx ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/90-xilinx-nopasswd
sudo chmod 0440 /etc/sudoers.d/90-xilinx-nopasswd
sudo visudo -c -f /etc/sudoers.d/90-xilinx-nopasswd

# BACK ON YOUR MACHINE -- prove both halves, without touching a lab:
ssh -o BatchMode=yes xilinx@<board> 'sudo -n true && echo "key ok, sudo ok"'
```

Then point the repo at the board once and let `provision_board.sh` commission it:

```bash
cp board.conf.example board.conf        # set PYNQ_HOST=xilinx@<board>
scripts/provision_board.sh              # copies the board-side tools and runs five checks
```

`provision_board.sh` checks exactly the five things that go wrong first: passwordless sudo,
`/dev/ttyPS1` exists, it is readable by `xilinx` (dialout), `mem=256M` is on the kernel
command line, and `import pynq` works inside the venv. If it passes, the labs will run.

**On the password.** A stock PYNQ card ships with a well-known default login, and 44 lab
scripts in this repo still carry it as a literal for the `sudo -S` fallback. With the NOPASSWD
drop-in above, `sudo` never reads stdin and that fallback is never exercised — which is the
reason to install it even on a board you are the only user of. See
`fpga/pynq-z2/docs/BRINGUP_ILLIXR.md` §8 and `docs/SELF_CONTAINED.md` §7.

**And the one that is not yours to leak.** `/boot/REVISION` on every stock PYNQ v3.1.1 image
contains a GitHub personal access token in cleartext. `fpga/pynq-z2/sdcard/per_board_setup.sh`
strips it (`:281-294`) and then sweeps `/boot /home /root /etc` for anything token-shaped,
printing paths only. Run that once on any card you are going to hand to someone else.

2. **Copy two files to the board.**
   ```bash
   scp build/pynqz2_dramtest.bit host/run_dramtest.py xilinx@<board>:~/
   ```

3. **Reserve memory from Linux.** The test writes real DDR. Either append `mem=256M` to
   the kernel command line so the upper 256 MB is not Linux's, or point `--base` at the
   physical address of a `pynq.allocate()` buffer. Skipping this scribbles on the OS.

4. **Run it.**
   ```bash
   sudo python3 run_dramtest.py            # 64 KB at 0x1000_0000
   sudo python3 run_dramtest.py --mb 16    # longer run
   ```

5. **Read the result.** Three checks, in order, so a failure localises itself:

   | Symptom | Meaning |
   |---|---|
   | `MAGIC` ≠ `0x5A5A0001` | PL not programmed, or M_AXI_GP0 not reaching it |
   | TIMEOUT, `beats=0` | HP0 never responded — the PS does not have DDR up |
   | `ERRCNT` > 0 | path works, data wrong — suspect address mapping |
   | `ERRCNT == 0` | **PL → S_AXI_HP0 → PS DDR works** |

   LEDs mirror it with nothing attached: LD0 heartbeat, LD1 busy, LD2 done, LD3 error.
   A dark LD0 means the PL has no clock at all.

## Two details that bite

**`Bitstream`, not `Overlay`.** `pynq.Overlay()` needs a `.hwh` metadata file beside the
`.bit`. This design has no IPI block design, so Vivado cannot export one —
`write_hw_platform` refuses with *"No Hardware definition found as there is no IPI block
design"*. `pynq.Bitstream(path).download()` just programs the PL, which is all that is
needed here; the registers are reached through `/dev/mem` at `0x4000_0000`.

**FCLK0 frequency.** The design is *timed* at 50 MHz (`clk_fpga_0`, 20.000 ns — confirmed
in `build/reports/timing_summary.rpt`). The FSBL programs FCLK0 from whatever the boot
image was built for, and the stock PYNQ image leaves it at 100 MHz. The runner sets it
explicitly via `pynq.ps.Clocks.fclk0_mhz`. The design does also close at 100 MHz — worst
path is about 7.95 ns against a 10 ns period — but that is margin we happened to have, not
a decision, so the runner pins it.

## If you ever want bare-metal instead of PYNQ

Then you *would* build an FSBL, and this flow needs one addition: an XSA export, which
requires the design to be an IPI block design rather than the structural-Verilog top used
here. Not needed for the tutorial, but worth knowing the flow forks there.

## Where Rocket slots in

The self-test master is a stand-in for the SoC's memory port, shaped like Rocket's traffic.
Replacing it needs two things from `docs/STATUS.md`:

- an **AXI4 → AXI3 shim** (4-bit LEN, plus WID generation) — Rocket's 8-beat bursts already
  fit inside AXI3's 16-beat limit, so the fragmenter is a formality, but WID is not
- an **`ExtMem` base inside `0x0010_0000–0x1FFF_FFFF`**, or the fpga-zynq truncation trick
  (`{4'd1, addr[27:0]}`) to fold Chipyard's `0x8000_0000` into the upper 256 MB

Everything else in this project — PS7 config, clocking, reset, constraints, the build
script — carries over unchanged.
