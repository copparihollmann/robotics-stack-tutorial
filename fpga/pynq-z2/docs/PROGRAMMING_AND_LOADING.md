# Getting bitstreams and binaries into a PYNQ-Z2 — with no external FTDI

A normal Chipyard FPGA deployment uses **two** FTDI channels: one for FPGA configuration,
one driving the SoC's RISC-V debug module via OpenOCD. On PYNQ-Z2 you need **neither
external probe**, because the PS does both jobs. One micro-USB cable, or none at all once
the design is in flash.

---

## 1. What the on-board FT2232 actually gives you

| Channel | Signals | Connects to | Useful for |
|---|---|---|---|
| **A** | `TCK`, `TDI`, `TDO`, `TMS` | the **Zynq JTAG chain** (ARM DAP + PL TAP) | FPGA configuration from Vivado |
| **B** | `UART_TXD_IN`/`RXD_OUT` | **PS_MIO14/15** → PS UART0 | the Linux console |

Channel A programs the PL. It does **not** reach Rocket's debug module — that is a separate
TAP living in PL fabric, not on the Zynq chain (see §4).

---

## 2. Loading bitstreams — four mechanisms, ranked

### (a) From Linux at runtime — the default

```python
from pynq import Bitstream
Bitstream("pynqz2_rocket_tacit.bit").download()
```

Goes through the PS's PCAP/FPGA-manager, which also handles the PS–PL level shifters. No
JTAG, no Vivado, no cable beyond whatever you use to reach the board. This is what
`host/run_rocket.py` does.

### (b) Baked into `BOOT.BIN` on the SD card — "pre-set the HW config"  ← **what you asked about**

The FSBL programs the PL *before* U-Boot and Linux, so the SoC is configured at every
power-on with nothing to run by hand:

```
boot.bif:
  the_ROM_image:
  {
    [bootloader] fsbl.elf
    pynqz2_rocket_tacit.bit
    u-boot.elf
  }
```
```bash
bootgen -image boot.bif -arch zynq -o BOOT.BIN -w on
```

**You do not need a custom FSBL or an XSA for this.** The FSBL simply DMAs the bitstream
partition to the PCAP; it does not need to understand the PL design. What it *does* need to
match is the **board** — DDR geometry, clocks, MIO — and the stock PYNQ FSBL already does,
because it was built for this board. So reuse the FSBL from the PYNQ image's existing
`BOOT.BIN` and just add your `.bit` to the BIF.

One caveat: PYNQ's Linux may load its own default overlay afterwards and overwrite the PL.
Disable that, or accept that (a) is then the source of truth.

### (c) QSPI flash — no SD card at all

PYNQ-Z2 has **16 MB of QSPI**. A `BOOT.BIN` of FSBL + bitstream is roughly 4–5 MB, so it
fits with room to spare. Set JP1 → **QSPI** and the board comes up with the PL configured
and no card inserted.

This is the genuinely useful worst-case fallback: **the hardware config survives an SD card
going missing or corrupt.** It will not hold a Linux rootfs, so it suits a bare-metal or
PS-minimal setup — but for "the FPGA image is always there", it is exactly right.

### (d) JTAG from Vivado — the debug path

`program_hw_devices` over FT2232 channel A. Fine for bring-up iteration, needs a host with
Vivado, and does not persist across power cycles.

**Recommendation:** (a) during development, (b) or (c) before the tutorial so every board
powers up already configured.

---

## 3. Getting binaries into the SoC — the real question

Two routes. Chipyard supports both; on this board one is nearly free and the other is not.

### Route 1 — JTAG to the debug module ✗ needs hardware you are trying to avoid

`ChipTop` exposes `jtag_TCK/TMS/TDI/TDO` (currently tied off in `pynqz2_rocket_top.v`).
Driving them means either:

- **An external probe on PL pins** — that is precisely the second FTDI you want to drop; or
- **BSCANE2 tunnelling** onto the Zynq JTAG chain so channel A reaches the RISC-V DTM.
  This works in principle and riscv-openocd supports BSCAN tunnels, but **Chipyard has no
  BSCAN support for Rocket**. The only `BSCANE2`/`JtagTunnel` code in the tree is under
  `generators/vexiiriscv/.../SpinalHDL`, a different core's ecosystem. You would be
  instantiating the primitive and wiring the DTM yourself.

### Route 2 — UART-TSI ✓ recommended here

`testchipip`'s serial program loader, and **already the mechanism your Arty200T flow uses**
— its own config comment says disabling it leaves "JTAG as the only way in".

On PYNQ-Z2 this costs **zero extra hardware and zero package pins**: PS UART1 routes to
EMIO (verified — `PCW_UART1_UART1_IO` accepts `EMIO`), so the link is internal to the chip.
The host tool runs on the ARM:

```bash
# on the board, once
gcc -O2 -o uart_tsi testchip_uart_tsi.cc ...      # generators/testchipip/uart_tsi/
sudo ./uart_tsi +tty=/dev/ttyPS1 +baudrate=115200 hello.riscv
```

It loads the ELF over TSI **and** carries the console on the same link — see §4.1 for why
that is not a separate UART at all.

### Route 3 — DMI over M_AXI_GP0, the Zynq-native upgrade

Chipyard has `WithDMIDTM`, which exposes the debug module's DMI directly instead of wrapping
it in JTAG. A small GP0-attached shim would let the ARM drive the debug module at AXI speed
— no serial link, no probe. More work than route 2; the natural follow-on once the board is
proven.

---

## 4. What UART-TSI instantiates in hardware

**Yes, it is additional IP — but all of it is in-tree `testchipip` RTL.** Nothing to buy,
nothing to write. `WithUARTTSIClient` adds (see
`testchipip/src/main/scala/tsi/PeripheryUARTTSI.scala`):

| Block | What it is |
|---|---|
| `UARTToSerial` | a raw UART SerDes — **not** the sifive UART peripheral. No MMIO registers; it just turns the wire into a byte stream. |
| `SerialWidthAdapter` | 8-bit UART bytes ↔ TSI phit width |
| `TSIToTileLink` | a TileLink **master** (`TLClientNode`), coupled in with `tlbus.coupleFrom("uart_tsi")` |

`TSIToTileLink` is the part that matters architecturally: the loader is a **bus master**, so
it writes program images into DRAM directly, with the core still in reset. That is why it
can load before boot rather than needing a cooperating monitor on the target.

It also means UART-TSI wants **its own UART**, separate from the console. On a carrier with
one spare UART that is the binding constraint — and it is why the Arty config makes it a
knob. On PYNQ-Z2 there is no conflict: PS UART0 (MIO) is the Linux console and PS UART1
(EMIO) is free for TSI, with the TSI host providing the SoC console over the same link.

### 4.1 The console rides the same link — no second UART needed

**TSI *is* HTIF.** `testchip_tsi_t : public tsi_t, public testchip_htif_t`, and fesvr's
`tsi_t` derives from `htif_t`. So the console is not a UART peripheral: it is the HTIF
syscall proxy. The target writes `tohost`, the host services it and writes `fromhost`. The
host tool's main loop is literally:

```cpp
while (!tsi.done()) { tsi.switch_to_host(); }   // services tohost/fromhost, incl. console
```

**Zephyr already has the target side**, and it is already in use: `drivers/serial/uart_htif.c`,
devicetree binding `ucb,htif-uart`, `CONFIG_UART_HTIF`. It is exactly what the Spike flow
uses — `uart_htif_poll_out` and `htif_wait_for_ready` appear by name in the decoded TACIT
flamegraph in `STATUS.md`.

So the SoC needs **only** the UART-TSI port. Consequences:

- **Drop the sifive UART peripheral entirely.** No `uart_0`, no console crossover in the
  top level. Fewer ports, a little less area.
- **The baud-matching problem disappears.** There is no second UART to keep in step with
  Rocket's divisor — one link, one rate, set by `WithUARTTSIClient(initBaudRate)`.
- One EMIO UART is sufficient, which is exactly what PS UART1 provides.

#### Throughput, honestly

Every HTIF poll is a TSI memory access over the serial link, so character-at-a-time console
would be painful at 115200 baud. Three things already in the tree fix it:

**For initial bring-up, leave all three off.** Plain char-at-a-time HTIF is slow but has
the fewest moving parts, and on a board nobody has run yet that is worth more than
throughput. In particular `CONFIG_UART_HTIF_USE_YIELD_SLEEP` has a history of being flaky
and should not be in the picture while you are still establishing whether the link works at
all. Turn these on afterwards, one at a time, once there is a known-good baseline to
compare against.

| Knob | Effect | Initial bring-up |
|---|---|---|
| `CONFIG_UART_HTIF_BUFFERED_OUTPUT` | buffers until newline or 64 B, flushes in one syscall | **off** — add first once stable |
| `CONFIG_UART_HTIF_SYSCALL_PRINT` | sends a string pointer instead of characters; its own help says "if the host-side FESVR supports it" | **off** — verify against `uart_tsi` before trusting |
| `CONFIG_UART_HTIF_USE_YIELD_SLEEP` | yields in the poll loop | **off** — known to be buggy; tight polling is the safe default |

Raising `initBaudRate` above 115200 is the lower-risk way to get throughput later; both the
Zynq UART and the SerDes go considerably higher, and it changes no target-side logic.

### Measured cost

Out-of-context `ChipTop` synthesis on `xc7z020clg400-1`, against the same baseline:

| Config | LUTs | Δ | FFs | BRAM |
|---|---|---|---|---|
| Rocket + TACIT (baseline) | 31,994 | — | 20,081 | 58 |
| **+ UART-TSI** | 33,059 | **+1,065** (+2.0 % of device) | +343 | **+0** |
| + HM01B0 camera + I²C | 33,607 | +1,613 (+3.0 %) | +1,295 | +0.5 |

Both together is roughly +2,700 LUT over baseline — against the built design's 28,009 that
lands near **58 %** of the device. Comfortable.

`ChipTop` also brings out two diagnostics worth wiring to LEDs: `uart_tsi_dropped` and
`uart_tsi_tsi2tl_state[3:0]`, which make loader failures visible without a debugger.

---

## 5. Recommended setup

| Job | Mechanism | External hardware |
|---|---|---|
| Bitstream, development | `pynq.Bitstream().download()` | none |
| Bitstream, deployment | `BOOT.BIN` on SD, or QSPI for card-independence | none |
| Program load into SoC | **UART-TSI** over PS UART1 (EMIO) | **none** |
| SoC console | **same link, via HTIF syscalls** — no second UART | none |
| Linux console | FT2232 ch B → `/dev/ttyPS0` | the one USB cable |
| Vivado JTAG debug | FT2232 ch A | the same cable |

**Zero external FTDIs. One cable — and none at all once the bitstream is in QSPI and you
reach the board over Ethernet.**

The cost is one config change (`WithUARTTSIClient` + `WithUARTTSIPunchthrough`), ~1,065
LUTs, and wiring `uart_tsi_uart_*` to PS UART1's EMIO port in the top. Note this **replaces**
the plain console crossover rather than adding to it — with an HTIF console the sifive UART
peripheral can be dropped from the config altogether.
