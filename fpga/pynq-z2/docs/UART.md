# Console on PYNQ-Z2: what the on-board FTDI can and cannot do

## What is actually on the board

There **is** an FTDI — an **FT2232HL**, dual channel — and it is wired like this (traced in
the TUL R12 schematic):

| FT2232 channel | Signals | Goes to |
|---|---|---|
| **A** (ADBUS0–3) | `FT2232_TCK`, `FT2232_TDI`, `FT2232_TDO`, `FT2232_TMS` | **FPGA JTAG** |
| **B** | `FT2232H_UART_TX` → `UART_TXD_IN`<br>`FT2232H_UART_RX` → `UART_RXD_OUT` | **`PS_MIO14` (C5)**<br>**`PS_MIO15` (C8)** |

Two consequences, one good and one annoying:

**Good: you do not need a programmer.** Channel A is the FPGA's JTAG. Vivado programs the
PL over the same micro-USB cable that powers the board. No external programmer, no
separate pod, nothing to order.

**Annoying: the UART belongs to the ARM, not the PL.** Channel B lands on PS MIO14/15,
which the PS7 configuration confirms is `PCW_UART0_UART0_IO = MIO 14 .. 15` — the PS's own
UART0, i.e. the Linux console you get on `/dev/ttyPS0`. MIO pins are hard silicon owned by
the PS; the PL cannot reach them. **A Rocket UART in the PL cannot drive the on-board
FTDI.**

(The same two signals are also brought out on `J13`, a 2-pin 2.54 mm header — but they are
still the same PS MIO nets, so that does not help the PL either.)

## Four ways to give Rocket a console

> **Superseded in part — see `PROGRAMMING_AND_LOADING.md` §4.1.** Option A below crosses
> PS UART1 to a *sifive UART peripheral* in the SoC. The better arrangement wires PS UART1
> to the **UART-TSI** port instead: TSI is HTIF, so the console arrives as syscalls on the
> same link that loads programs, Zephyr's existing `uart_htif` driver is the target side,
> and the SoC needs no UART peripheral at all. The physical path below — and the answer to
> "can I read it over the existing USB" — is unchanged.

### A. PS UART1 over EMIO — recommended, zero extra hardware

**Short answer to "can I just read it over the USB cable that is already there?" — yes,
with no extra hardware, but you reach it *through* the board's Linux rather than as a
second serial port on your laptop.**

```
  your laptop
      │  USB  (the one cable that already powers the board)
      ▼
  FT2232 channel B ──▶ PS_MIO14/15 ──▶ PS UART0 ──▶ /dev/ttyPS0  = LINUX console
                                                         │
                                          you are now logged into the board
                                                         │
                                            $ screen /dev/ttyPS1 115200
                                                         │
                                                         ▼
                                    PS UART1 ──EMIO──▶ (inside the PL) ──▶ Rocket UART
```

So one USB cable gets you both consoles, nested: the outer one is Linux on the ARM, and
from there you attach to `/dev/ttyPS1`, which is Rocket. Over ssh is the same thing and
more comfortable — no cable needed at all once the board is on the network.

What you do **not** get this way is Rocket appearing as its own `/dev/ttyUSB1` on your
laptop, independent of Linux. If that is what you want, it is option B or C below.


The PS has a *second* UART controller, UART1, unused on this board because nothing is wired
to it. Route it to **EMIO** and its TX/RX appear as signals inside the PL, where they can be
cross-connected to Rocket's UART:

```
  rocket uart_0_txd  ───────────────▶  UART1_RX_i   (PS receives what Rocket sends)
  rocket uart_0_rxd  ◀───────────────  UART1_TX_o   (Rocket receives what PS sends)
```

Rocket's console then appears on the board's Linux as **`/dev/ttyPS1`** — reachable over
ssh, no cable, no PCB change, and **zero package pins consumed** (EMIO signals are internal
to the PS7 block, not balls).

Verified configurable: `CONFIG.PCW_UART1_UART1_IO` accepts `EMIO` and
`PCW_UART1_PERIPHERAL_ENABLE` takes `1` on this board's preset.

Only real constraint: both ends must agree on baud. Set PS UART1 to 115200 and pick
Rocket's UART divisor for the 50 MHz PL clock.

### B. A USB-UART bridge on the Raspberry Pi GPIO PCB — worth doing anyway

Since a PCB is being spun for the camera regardless, adding a CP2102, CH340 or FT231X costs
roughly **$1–2 in parts** and two RPi-header pins. It gives a console that works with no
Linux running at all, which is the one thing option A cannot do — useful if the PS ever
hangs, or for bare-metal bring-up.

Pin budget is not a problem: the camera needs 14 signals of the header's 28, so UART fits
with room left over.

### C. A USB-TTL cable on two header pins — no PCB change

A $5 CP2102/FT232 cable on two RPi GPIO pins. Fine for one or two boards; a cable per seat
is unattractive if boards go into attendees' hands.

### D. No UART at all — PS as host over M_AXI_GP0

The `ucb-bar/fpga-zynq` model: the ARM runs the front-end server and talks to the SoC over
AXI, so there is no UART in the picture. Chipyard's equivalent is its serial-TL / TSI link
brought out to a GP0-attached shim. Most implementation work of the four, but the payoff is
loading binaries at AXI speed rather than 115200 baud, which matters once models get large.

## Recommendation

**A now, B on the PCB.** Option A costs nothing and gets a console working the day boards
arrive. Option B is nearly free given the PCB already exists, and buys independence from the
PS being healthy. C is a stopgap. D is the right end state for loading real workloads and is
worth doing after the board is proven — it is the same path the tutorial's larger models
will eventually need.

## Nothing to order

| Function | Provided by | Need to buy? |
|---|---|---|
| Programming the PL | FT2232 channel A, over micro-USB | **no** |
| Linux console (PS) | FT2232 channel B → PS MIO14/15 | **no** |
| Rocket console | PS UART1 via EMIO (option A) | **no** |
| Rocket console, PS-independent | bridge on the camera PCB (option B) | ~$1–2 of parts |
