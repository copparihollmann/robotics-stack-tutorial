# Microphone audio on the PYNQ-Z1

**Status: working. The microphone is real and confirmed, the decimator is designed,
costed and simulated, it is inside the SoC on the periphery bus, and a Zephyr application
captures from it through the standard DMIC API on the routed silicon.**

Short version, all measured:

| | |
|---|---|
| The part | Knowles **SPK0833LM4H-B** MEMS microphone, PDM output, on **F17** (clock out) and **G18** (data in), both PL pins |
| Is it really there? | **Yes** — recorded from it, on this board, over Ethernet. Textbook sigma-delta noise shaping: −78.6 dB in 8–50 kHz rising to −23 dB at 1 MHz |
| PL cost of the decimator | **448 LUT, 477 FF, 1 DSP48E1, 3 BRAM18** out of 13,296 / 179 / 76 free — **3.4% of the spare LUT** |
| PL timing | worst path **9.881 ns** against a 28.999 ns period, OOC routed. The design's own critical path is 27.873 ns, so this cannot become it |
| Audio quality, simulated | passband ripple **0.0064 dB**, stopband **−81.7 dB**, CIC alias rejection **−94.2 dB**, DC gain exactly 32768 |
| Sample rate | **15993.859 Hz** *on the 34.4828 MHz builds this document was written for*. See §3.2 — and **§0 below: on `0x5A5A0035` at 40 MHz it is 18,552.875 Hz, measured**, and the `RATE` register still reports 15993.859 |
| Zephyr | standard `<zephyr/audio/dmic.h>`, no DMA. Driver + board + sample, and 15/15 golden checks on hardware |
| Bitstream | **+657 LUT, +1 DSP, +1.5 BRAM36 in context; WNS +1.153 ns, up 0.027 from the P-ext design.** §4.2, §10.1 |
| On the board | 2 s captured through the DMIC API. Against the same microphone read minutes later through PYNQ's own IP: **overall level within 0.2 dB, band-profile correlation 0.962**, same fan harmonics at 437/328/656/1000 Hz. §10.4 |
| SoC integration | a `TLRegisterNode` on the periphery bus at 0x1009_0000, `pdm_mic_core` as a BlackBox, two pins punched out to F17/G18. §8 |
| Effect on the existing config | **506 generated files byte-identical** once FIRRTL's line-number comments are stripped. §9 |

---

## 0. THE RATE IN THIS DOCUMENT IS THE RATE OF A 34.4828 MHz BUILD (added 2026-09-20, Lab B110)

**Everything below was written and measured on FCLK0 = 34.4828 MHz. The shipping bitstream is now
`0x5A5A0035` at FCLK0 = 40.000000 MHz, and the microphone's sample rate moved with the clock.**

`RATE` (0x28) is **not** measured by the hardware: it is the Verilog parameter `RATE_MHZ`, a
compile-time constant, and `PynqZ2Configs.scala` instantiates `WithPdmMic(address = 0x10090000L)` —
every `PdmMicParams` default, `rateMilliHz = 15993859` included. The rate the chain actually
produces is `FCLK0 / (2·PDM_HALF · CIC_R · FIR_DECIM) = FCLK0/2156` and nothing else.

| | FCLK0 | real `f_pcm` | `RATE` reads |
|---|---:|---:|---:|
| this document's builds | 34,482,758.6 Hz | 15,993.859 Hz | 15,993.859 Hz ✓ |
| **`0x5A5A0035`** | **40,000,000 Hz** | ***18,552.8757 Hz*** | 15,993.859 Hz ✗ **+16.000 % stale** |

**Measured on silicon, board garden, 2026-09-20:** `18,552.875 Hz` over a 64,000-sample window
(`−0.00004 %` from `FCLK0/2156`), corroborated by the `LEVEL` slope and by the settle timer
(131,072 PDM bits in 45.875 ms → PDM clock 2.857143 MHz = 40 MHz/14). `ID` `0x504D4331`, `DEPTH`
1024, blocker on mean `−0.409`, blocker bypassed mean `1321.562`. `scripts/76_rocket_mic_probe.sh`,
`archive/runs/b110_mic_probe_0035@20260920T1355`, TODO.md B110.

**Consequences for anyone building the audio path.** 64,000 samples is **3.4496 s**, not 4.0016 s.
`dmic_pdm_mmio.c` negotiates from `RATE` with a 10-permille tolerance and will **refuse** this
microphone — correctly. Reaching exactly 16 kHz needs new decimation parameters *and a new
bitstream*; unlike §3.2's conclusion at 34.4828 MHz, **at 40 MHz exactly 16,000.000 Hz is reachable**
(`40e6/16000 = 2500`, e.g. `PDM_HALF=10, CIC_R=25, FIR_DECIM=5`). Resampling in software instead is
`539/625`, a 539-phase polyphase — not the cheap option.

**One more correction B110 found:** §3.6 and `pdm_mic_core.v`'s own header say `CTRL[3] clear_sticky`
clears "overrun + saturated". **It clears only `saturated`** — `fifo_overrun` lives in
`pdm_mic_fifo.v` and is cleared only by `rst || fifo_reset`. `dmic_pdm_mmio.c` writes
`FIFO_RESET|CLR_STICKY` together, so it never sees the difference.

---

## 1. What the hardware actually is, and how we know

### 1.1 The trap in our own tree

`fpga/pynq-z2/boards/` carries two Digilent board files. `boards/pynq-z2/A.0/board.xml`
declares `audio_i2s`, `audio_i2c` and `audio_clock`; that is the **PYNQ-Z2's ADAU1761
codec**, and we do not have a PYNQ-Z2. Our builds use `boards/arty-z7-20/A.0`
(`tcl/board.tcl`, `PYNQ_BOARD=z1` → `digilentinc.com:arty-z7-20:part0:1.1`), whose
`board.xml` declares **no audio interface at all** — `grep -i "audio|mic|pdm|pwm|codec|i2s"`
over `boards/arty-z7-20/A.0/part0_pins.xml` returns nothing.

Neither board file describes our microphone, and the reason is not an omission:

> "Arty Z7-20 shares the exact same SoC with the PYNQ-Z1. Feature-wise, **Arty Z7-20 is
> missing the microphone input**, but adds a Power-on Reset button. Software written for
> PYNQ-Z1 should run unchanged with the exception of microphone input, whose FPGA pin is
> left unconnected."
>
> — Digilent, *Arty Z7 Reference Manual*, §Feature comparison

So the two boards are **not** the same board under two names. They are the same Zynq part
on two closely related PCBs, and the microphone is exactly the thing that differs.
Digilent's `vivado-boards` repository has no `pynq-z1` entry at all — only `arty-z7-20` —
which is why our build uses the Arty file and why the Arty file has no microphone in it.
Digilent's `digilent-xdc/Arty-Z7-20-Master.xdc` agrees: it has an `## Audio Out` section
with `AUD_PWM` on R18 and `AUD_SD` on T17, and nothing else.

**Conclusion: the board file is the wrong place to look. It is right about the Arty Z7-20
and we are not running one.**

### 1.2 What the PYNQ-Z1 reference manual says

From the *PYNQ-Z1 Reference Manual* (digilent.com, read through an Internet Archive
snapshot because digilent.com serves a Cloudflare challenge to anything but a browser —
that is a sourcing caveat, not a content one; the text below is verbatim):

> **§13 Microphone.** "The PYNQ-Z1 includes an omnidirectional MEMS microphone. The
> microphone uses a **Knowles SPK0833LM4H-B** chip which has a high signal to noise ratio
> (SNR) of 63dBA and high sensitivity of -26 dBFS. The digitized audio is output in the
> **pulse density modulated (PDM)** format."

> **§13.2 Microphone Digital Interface Timing.** "The clock input of the microphone can
> range from **1 MHz to 3.3 MHz** based on the sampling rate and data precision requirement
> of the applications. The L/R Select signal must be set to a valid level, depending on
> which edge of the clock the data bit will be read. A low level on L/RSEL makes data
> available on the **rising edge** of the clock... Note that on the PYNQ-Z1, the **L/RSEL
> signal is permanently tied low**, so data is always made available on the rising edge."
> "The typical value of the clock frequency is 2.4 MHz."

> **§14 Mono Audio Output.** "The on-board audio jack (J13) is driven by a Sallen-Key
> Butterworth Low-pass 4th Order Filter that provides mono audio output. The input of the
> filter (**AUD_PWM**) is connected to the Zynq PL pin **R18**... The Audio shut-down
> signal (**AUD_SD**)... is connected to Zynq PL pin **T17**."

So: **PDM microphone, not a codec. No I²S, no I²C, no configuration interface. Two wires,
one of them an output we generate. L/R select is not a pin we have to drive.** This is a
completely different arrangement from the Z2's ADAU1761, and a much simpler one to build
for — at the cost of having to do the decimation ourselves.

### 1.3 The pin numbers

The reference manual gives R18/T17 for the audio *output* in body text but puts the
microphone pinout in a figure, which does not survive the archive snapshot. The
authoritative machine-readable source is Xilinx's own PYNQ base overlay for this board,
`Xilinx/PYNQ`, `boards/Pynq-Z1/base/vivado/constraints/base.xdc`:

```tcl
## Audio
set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports {pdm_m_clk[0]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports pdm_m_data_i]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {pwm_audio_o[0]}]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {pdm_audio_shutdown[0]}]
```

R18 and T17 match the reference manual's prose exactly, which is the cross-check that
makes F17/G18 trustworthy. And §2 below turns that from trustworthy into **measured**: we
ran that bitstream on this board and recorded live audio through those pins.

| signal | PL pin | direction | note |
|---|---|---|---|
| `pdm_m_clk` | **F17** | PL → mic | we generate it, 1–3.3 MHz |
| `pdm_m_data` | **G18** | mic → PL | 1 bit, valid on the rising edge of `pdm_m_clk` |
| `AUD_PWM` | R18 | PL → jack | mono PWM out, not used here |
| `AUD_SD` | T17 | PL → jack | drive high to un-mute the output amp |
| L/R SELECT | — | — | **tied low on the board**, no pin |

All PL I/O on this board is LVCMOS33: there is no VADJ jumper (only J9 power and JP1 boot
mode), as `src/pynqz2_rocket.xdc` already records.

---

## 2. Proof that the part is alive, before designing anything for it

Reading a datasheet is not evidence that a specific board's microphone works. Before
writing a line of RTL we recorded from it, using PYNQ's own base overlay — which already
contains Digilent's `audio_direct` IP wired to F17/G18 — through
`fpga/pynq-z2/host/record_pdm.py`:

```
scripts/with_board.sh ssh $PYNQ_HOST 'sudo python3 record_pdm.py --seconds 1.0'
  audio IP at 0x43c00000
  words        192000
  pdm bits     3072000
  density      0.516384
  word rate    195120.3 Hz   (measured by the polling loop)
```

> **This overwrites the PL.** Loading `base.bit` replaces whatever bitstream is there,
> Rocket included. Hold `scripts/with_board.sh` across it and reload afterwards. We did,
> and `29_rocket_pext_run.sh` / `30_rocket_mb_lenet_pext_board.sh` were re-run afterwards
> — see §9.

1,000,000 µs of the board's own microphone, 3,072,000 PDM bits. Two things in that output
already settle the question:

**Density 0.516384.** A PDM microphone idles at a density near 0.5 — the modulator is
always running and always dithering. A floating pin reads as a constant or as coupled
junk; a tied pin reads as exactly 0.0 or 1.0. 0.5164 is what a live part in a quiet room
looks like.

**Noise shaping.** This is the one that cannot be faked. Taking the FFT of the raw
bitstream:

| band | mean level (dB rel. peak) |
|---|---|
| 0 – 8 kHz | −29.9 |
| 8 – 50 kHz | **−78.6** |
| 50 – 200 kHz | −43.5 |
| 200 – 400 kHz | −34.2 |
| 400 – 600 kHz | −28.4 |
| 600 – 800 kHz | −25.0 |
| 800 kHz – 1.0 MHz | **−23.4** |

A quiet audio band, then a floor that climbs ~55 dB on its way to Nyquist. That is a
sigma-delta modulator's noise transfer function and nothing else produces it. **The
Knowles part is on this board, it is clocked, and it is talking.**

(PYNQ's `audio_direct` clocks the part at 100 MHz / 32 = 3.125 MHz — `C_SYS_CLK_FREQ_MHZ
= 100, C_PDM_FREQ_MHZ = 3` in `pdm_rxtx.vhd`. The measured 195,120 words/s × 16 bits =
3.122 MHz agrees. That rate matters in §6.)

---

## 3. The design

### 3.1 Shape

```
  F17  pdm_m_clk   <-- counter on the 34.4828 MHz system clock, /14 -> 2.463054 MHz
  G18  pdm_m_data  --> 2-FF sync --> CIC (4 stages, /22) --> FIR (289 taps, /7)
                                         111.957 kHz          15993.859 Hz
                                     --> DC blocker (1-pole, 19.9 Hz) --> FIFO (1024)
                                     --> 8 MMIO registers
```

Files: `src/pdm_cic4.v`, `src/pdm_fir_mac.v`, `src/pdm_dcblock.v`, `src/pdm_mic_fifo.v`,
`src/pdm_mic_capture.v`, `src/pdm_mic_core.v`, and the generated coefficient table
`src/pdm_fir_coeffs.vh` (from `rtl_study/pdm/gen_fir.py`).

**There is one clock.** `pdm_m_clk` is an output *signal* produced by a counter, not a
clock the fabric runs on, and every register in the block is on the system clock with an
enable. That is a deliberate choice in a design already at 75% LUT and +1.126 ns of WNS:
a second clock region would mean CDC, a second BUFG, and a second set of timing
constraints, for a datapath whose fastest register toggles at 2.5 MHz.

**The sample point.** The part presents its bit on the rising edge of the clock (L/RSEL
tied low, §1.2), so we sample six system clocks later — 174 ns — which is just before the
falling edge. The round trip is IOB-out + the part's data delay + IOB-in, tens of ns, so
the sample point sits in the middle of a 203 ns-wide eye.

### 3.2 Why the sample rate is 15993.859 Hz and not 16000

FCLK0 on this bitstream is 1000 MHz / 29 = 34,482,758.6 Hz — the PS7 can only divide the
1 GHz IO PLL by integers, which is also why "35 MHz" is 34.4828 (see
`PEXT_FEASIBILITY.md`). For the chain to produce exactly 16 kHz the total division
34,482,758.6 / 16,000 = **2155.17** would have to be an integer. It is not, and no choice
of PDM divider, CIC ratio and FIR ratio can make it one.

The chain divides by 2×7 (PDM clock) × 22 (CIC) × 7 (FIR) = 2156, giving **15993.859 Hz,
0.038% low**. Of the integer divisors near 2155, 2156 is the closest that also leaves the
PDM clock inside the part's 1–3.3 MHz range.

0.038% is 6 Hz at 16 kHz. For speech it is inaudible; for a keyword-spotting model trained
at 16 kHz it is far inside the variation the model already sees from room acoustics. The
hardware reports its true rate in millihertz in a register and the driver hands that back
through `struct pcm_stream_cfg`, so **nothing downstream has to guess**.

### 3.3 Why two decimation stages, and why R=22 rather than R=154

The obvious design — one CIC decimating by the whole 154 — is the one to avoid, and the
reason is the microphone's own noise shaping (the table in §2). Decimation folds
everything above the new Nyquist back into the band, so the CIC's attenuation at the
folding bands is what protects the audio from the modulator's out-of-band noise.

| split | CIC output rate | worst CIC alias rejection into 0–7 kHz, 4 stages | CIC accumulator width |
|---|---|---|---|
| CIC /154, no FIR | 15.99 kHz | **−47.0 dB** | 33 bits |
| CIC /77 + FIR /2 | 31.99 kHz | **−47.0 dB** | 28 bits |
| **CIC /22 + FIR /7** | 111.96 kHz | **−94.2 dB** | **20 bits** |

The last row is better on every axis at once. The reason is not subtle: a CIC's nulls sit
at multiples of its *output* rate, so the further out its output rate is, the deeper the
folding bands fall on the skirt. Pushing the CIC's job out to 112 kHz costs nothing (its
integrators run at the PDM rate either way) and leaves a decimate-by-7 that a single
time-multiplexed MAC handles with 1800 clocks to spare.

It also shrinks the CIC. With R=22 the register-growth bound is
4·log₂(22) + 2 = 19.84 bits, so 20-bit wrapping accumulators are exact; with R=154 it
would be 33.

The same choice makes the passband droop almost disappear: **−0.223 dB at 7 kHz**, against
several dB for a /154 CIC. The FIR inverts even that (§3.4).

### 3.4 The FIR

289 taps, symmetric, decimating by 7, designed by `rtl_study/pdm/gen_fir.py` (least
squares, desired response = 1/CIC-droop in 0–7 kHz and 0 from 8993 Hz — 8993 Hz being
`f_pcm − 7000`, the first frequency that would fold onto the passband edge).

The coefficients carry three jobs at once, which is why the generator must not be
second-guessed by hand:

1. the anti-alias lowpass for the decimate-by-7,
2. the inverse of the CIC droop,
3. the scale factor that makes the **whole** chain's DC gain exactly 32768, so PDM
   density ±1 maps to ±full scale. (Quantised: `sum(h) = 586717`, `2^22` output shift →
   32768.72.)

Measured from the quantised 18-bit coefficients:

| | |
|---|---|
| FIR passband ripple, 0–7 kHz | 0.2205 dB (this is the droop correction, on purpose) |
| CIC droop at 7 kHz | −0.2232 dB |
| **CIC × FIR passband ripple** | **0.0064 dB** |
| FIR stopband, ≥ 8993 Hz | −81.31 dB |
| chain stopband | −81.67 dB |
| worst CIC alias rejection | −94.19 dB |
| max |coefficient| | 83,897 — fits 18 bits signed (±131,071) |
| Σ|coefficient| × max CIC output | 2^38.0 — fits the DSP48E1's 48-bit P |

**One MAC, not 289.** At 34.4828 MHz there are 34,482,759 / 15,993.86 = **2156 system
clocks per output sample** and the filter needs 289 of them. In sample-rate terms this is
an extraordinarily slow filter; the serial structure is not a compromise, it is the right
shape. The history buffer and the coefficient table are block RAMs, which is free here
(76 BRAM36 spare) and saves the ~300 LUTs that 512×20 and 512×18 of distributed RAM would
cost.

The MAC is written as the canonical inferrable pattern rather than an explicit DSP48E1.
The Vivado 2023.1 segfault documented in `PEXT_FEASIBILITY.md` is specific to *several*
inferred multipliers feeding an adder tree; one multiplier feeding an accumulator is the
pattern inference is built around. **`ooc_pdm.tcl` reports the DSP count rather than
assuming it**, so a silent fall back to LUT multipliers would show up as a number here
and not as a surprise on the board. It reports 1. (If it ever stops doing so,
`rtl_study/pext/pext_pdot8_dsp48.v` is the worked example of the explicit form.)

### 3.5 The DC blocker

A one-pole high-pass at the PCM rate, `y[n] = x[n] − x[n−1] + (1 − 2⁻⁷)·y[n−1]`, corner
15993.86 / (2π·128) = **19.9 Hz**, implemented on an extended-precision accumulator so the
pole costs a shift and a subtract instead of a multiplier.

This is not cosmetic. The board's own microphone measured a density of **0.516384** with
no deliberate sound, and the ±1 mapping turns that into **1074 counts** of permanent DC —
3.3% of the 16-bit headroom, before any signal arrives. The simulation checks both halves
of that (§5, check 7): bypassed it reproduces 1073.8 counts, enabled it leaves −0.2.

### 3.6 Register map, and why it is a FIFO and not a DMA

The brief suggested an MMIO FIFO as the simple option and a DMA to DRAM as the scalable
one. **At this data rate the FIFO is not the compromise.** 16 kHz × 2 bytes is 32 kB/s;
one MMIO load per sample on a 34.48 MHz hart is well under 2% of one core even counting a
`LEVEL` read per block. A DMA would add a bus master, an address generator, a descriptor
interface, cache-coherence questions that this SoC does not answer (§8.1), and several
hundred LUTs, to save 2% of one hart. It would be the right answer for a camera; it is the
wrong answer for a microphone.

`src/pdm_mic_core.v`, 32-bit registers. **The byte stride is eight, not four**, because
the Verilog core has a single shared `reg_addr` port and the periphery bus is 64 bits wide:
two fields in one bus word would both be selected by an 8-byte access and the address mux
would be ambiguous. One register per bus word removes the question, and a 4 KB page holds
eight of them with room to spare.

| offset | idx | name | access | meaning |
|---|---|---|---|---|
| 0x00 | 0 | `ID` | R | `0x504D4331` ("PMC1") |
| 0x08 | 1 | `CTRL` | RW | [0] enable, [1] fifo_reset (self-clearing), [2] dc_bypass, [3] clear_sticky |
| 0x10 | 2 | `STATUS` | R | [0] settling, [1] empty, [2] full, [3] overrun, [4] saturated |
| 0x18 | 3 | `LEVEL` | R | samples available |
| 0x20 | 4 | `DATA` | R | pops one sample, sign-extended. 0 when empty |
| 0x28 | 5 | `RATE` | R | PCM rate in **millihertz** — 15993859 |
| 0x30 | 6 | `DEPTH` | R | FIFO depth, 1024 |
| 0x38 | 7 | `WMARK` | RW | interrupt watermark (`irq` is level-sensitive above it) |

The FIFO is 1024 samples = **64 ms**, one BRAM18, first-word-fall-through so a register
read that pops returns the sample in the same bus cycle. 64 ms is the amount of lateness
the software gets: a whole 32 ms DMIC block plus an inference pass. Past that, `overrun`
is sticky and the driver says so rather than letting the audio glitch silently.

`SETTLE` (default 131072 PDM bits = **53 ms**) holds the chain in reset after `enable`
rises, covering the part's wake-up from standby and the CIC's fill. `STATUS.settling`
reports it and no sample escapes before it clears.

---

## 4. Area and timing — measured

Method is `rtl_study/pext`'s, unchanged: each block is wrapped in a harness that registers
every port, then **synthesised and placed and routed** out of context on
`xc7z020clg400-1` at the real target period of 28.999 ns, and the worst
register-to-register path is reported (`rtl_study/pdm/ooc_pdm.tcl`,
`rtl_study/pdm/ooc_out/summary.tsv`). Read `logic ns` and `levels`, not `route ns`: an OOC
block alone on an empty part is placed with no pressure.

```
label    lut  lut_logic  ff   dsp  bram36  bram18  slack_ns  datapath_ns  logic_ns  route_ns  levels
cic      163  163        269  0    0       0       25.940     2.770        0.716     2.054     1
fir       79   78         92  1    0       2       21.292     7.700        3.701     3.999    13
dcblock   82   82        100  0    0       0       18.153    10.791        4.614     6.177    14
fifo      38   38         54  0    0       1       23.406     5.066        1.594     3.472     5
capture  345  345        418  1    0       2       18.971     9.976        4.304     5.672    11
core     448  448        477  1    0       3       19.063     9.881        4.350     5.531    11
```

`core` is the whole peripheral: capture chain + FIFO + register file. `capture` is the
same minus those. The harnesses contribute flip-flops and no LUTs, so the LUT column is
the block's own cost.

### 4.1 Against the budget

The current P-ext bitstream, from `PEXT_FEASIBILITY.md`: 39,904 / 53,200 LUT (75.01%),
24,130 FF, 64 / 140 BRAM36, 41 / 220 DSP, WNS **+1.126 ns** at 28.999 ns, critical path in
the L2 MSHR scheduler.

| resource | free | `pdm_mic_core` | fraction of free |
|---|---|---|---|
| LUT | 13,296 | **448** | **3.4%** |
| FF | — | 477 | — |
| DSP48E1 | 179 | **1** | 0.6% |
| BRAM36 | 76 | **1.5** (3 × BRAM18) | 2.0% |

It fits with room to spare, and it fits in the cheap resources: one of the 179 spare DSPs
does the entire filter.

### 4.2 And what it actually cost, in context

The OOC numbers above are a prediction. The routed bitstream is the answer.
`build_rocket_mic_z1/reports/post_route_util.rpt` against
`build_rocket_pext_z1/reports/post_route_util.rpt` — the same design without the
microphone, same clock, same part:

| | P-ext | P-ext + microphone | delta | OOC predicted |
|---|---|---|---|---|
| Slice LUTs | 39,904 (75.01%) | **40,561 (76.24%)** | **+657** | +448 |
| Slice Registers | 24,130 | 24,645 | +515 | +477 |
| BRAM36 | 64 | 65.5 | +1.5 | +1.5 (3 × BRAM18) |
| DSP48E1 | 41 | **42** | **+1** | +1 |
| WNS | +1.126 ns | **+1.153 ns** | **+0.027** | — |
| WHS | +0.007 ns | +0.006 ns | −0.001 | — |

DSP and BRAM landed exactly. The LUT delta is 657 against a predicted 448, and the
difference is not the decimator: it is the **TileLink attachment** — the fragmenter, the
buffer, the extra crossbar port, and the register glue that the OOC harness did not
contain. So the block itself transferred essentially 1:1 and the bus cost about 209 LUT,
which is worth knowing the next time someone prices a peripheral from an OOC number.

**Timing did not move.** WNS went *up* by 0.027 ns, which is placement noise; the critical
path is still the L2 MSHR scheduler, and 0 endpoints fail. The DRC report is clean.

### 4.3 Will it close timing? — what was argued beforehand



The block's worst OOC routed path is **9.881 ns**. The design's own critical path is
28.999 − 1.126 = **27.873 ns**. For the microphone to become the critical path, its path
would have to degrade by 2.8× in context.

The one measured OOC→in-context transfer factor in this repo is **0.88×** — the P-ext ALU
cone's +9.38 ns OOC delta became +8.294 ns in a 75%-full device
(`PEXT_FEASIBILITY.md` §2.6, which also says in bold: *one data point, do not make it a
rule*). Even taking the pessimistic 1.5× that document considered and rejected, 9.881 ns
becomes 14.8 ns, 13 ns clear of the critical path.

The honest statement: **the microphone cannot plausibly set the clock, and the risk to WNS
is that the extra 448 LUT and 3 BRAM make the placer's life 1% harder somewhere else.**
That risk is real but it is a placement risk, not a path risk, and it is the same risk any
448-LUT addition carries. It is not measurable without building the bitstream.

The one constraint the block does need is on `pdm_m_data`. It is source-synchronous
through the board and its round trip is a large fraction of a 29 ns period, but the
protocol guarantees it stable for ~200 ns either side of the sample point. The 2-FF
synchroniser is there to hang the exception on:

```tcl
set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports pdm_m_clk]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports pdm_m_data]
# The microphone launches its bit on the rising edge of a clock WE generate and we sample
# it 6 cycles later, so this is not a path the timing engine can or should budget: it is a
# protocol with 200 ns of margin on both sides, crossing into a 2-FF synchroniser.
set_false_path -from [get_ports pdm_m_data]
```

---

## 5. Simulation — `sim/run_pdm_sim.sh`

A PDM decimator is one of the few blocks where the *answer* can be checked and not just
the handshakes, so the testbench drives a real second-order sigma-delta modulator — the
same thing the Knowles part contains — and checks the PCM that comes out. It is written in
the same style as the three existing build gates (`  pass  `, `ALL CHECKS PASSED`, a
watchdog) so it can be added to the build script's `run_sim` list unchanged.

```
$ VERILATOR=... fpga/pynq-z2/sim/run_pdm_sim.sh
PDM microphone peripheral -- f_pdm 2463054.2 Hz, f_cic 111957.01 Hz, f_pcm 15993.8584 Hz

-- 1. register file, quiescent --
  pass  ID reads 0x504D4331 (got 0x504d4331)
  pass  RATE reads 15993859 mHz (got 15993859)
  pass  DEPTH reads 1024 (got 1024)
  pass  LEVEL is 0 before enable (got 0)
  pass  STATUS.empty set, settling clear before enable (got 0x02)
  pass  unmapped register reads 0xDEADBEEF (got 0xdeadbeef)

-- 2. settling holds the chain off --
  pass  STATUS.settling set right after enable
  pass  no sample produced while settling (LEVEL 0)
  pass  STATUS.settling clears after SETTLE PDM bits
  pass  PDM clock ran at one bit per 14 system clocks

-- 3. sample rate --
  pass  consecutive samples are 2156 system clocks apart, expected 2156

-- 4. end-to-end DC gain (DC blocker bypassed) --
  pass  u=+0.5 -> 16384.0 counts, expected 16384 +-250
  pass  u=-0.5 -> -16384.0 counts, expected -16384 +-250
  pass  u=0 -> 0.0 counts, expected 0 +-120

-- 5/6. tone at 999.6 Hz, and the 9996.2 Hz alias that must not appear --
   f1 = 999.62 Hz (bin 64), f2 = 9996.16 Hz (bin 640, folds onto bin 384 = 5997.70 Hz)
   bin 64 (signal)        8192.50 counts
   bin 384 (alias)          0.0484 counts  = -104.6 dB below signal
   bin 200 (empty)          0.0144 counts
  pass  999.6 Hz tone at 8192.5 counts, expected 8192 +-410 (0.25 x 32768)
  pass  9996.2 Hz alias is 104.6 dB down, needs >= 60
  pass  empty bin is quiet (0.01 counts, needs < 1% of signal)

-- 7. DC blocker --
  pass  bypassed, the real board's 0.5164 density gives 1073.8 counts (expect ~1074)
  pass  with the DC blocker on the same offset gives -0.2 counts (expect |m| < 40)

-- 8. FIFO: LEVEL never promises a sample DATA cannot return --
  pass  LEVEL and STATUS.empty agreed on every one of 2158 cycles
  pass  the FIFO did fill during the watch (otherwise the check above is vacuous)
  pass  no overrun after all of the above
  pass  fifo_reset empties the FIFO (LEVEL 0)
  pass  STATUS.settling clear while disabled

24 checks, 0 failures
ALL CHECKS PASSED
```

Four of those are worth reading twice.

**The DC gain lands on 16384.0, exactly.** A modulator driven at u = +0.5 comes out at
half of 32768 with no error at the printed precision. That is the entire fixed-point
chain — the ±1 mapping, the CIC's R⁴ = 234,256 gain, the quantised coefficient sum, and
the 2²² output shift — agreeing to five figures.

**The 999.6 Hz tone comes out at 8192.5 counts** against a predicted 8192.0 (0.25 ×
32768): 0.006% amplitude error.

**The 9996.2 Hz tone is 104.6 dB down at the bin it would have aliased to.** Without the
FIR it would have landed on 5997.7 Hz at full amplitude. This is the single check that the
CIC order and the FIR stopband are real and not just plotted.

**The DC blocker reproduces the board's own offset.** Driven with the density this board's
microphone actually has, it gives 1073.8 counts bypassed and −0.2 enabled.

The testbench presents its bits the way the part does: it waits for the DUT's *own*
`pdm_m_clk` to rise and drives the data pin 20 ns later. A wrong sampling edge in
`pdm_mic_capture.v` would fail here.

---

## 6. The board's own audio, through this RTL

The strongest evidence available short of a bitstream: take the 1.5 M PDM bits recorded
from this board's microphone in §2, replay them through the actual Verilog under
Verilator (`rtl_study/pdm/tb_pdm_replay.sv`), and look at what comes out.

```
$ rtl_study/pdm/tb_pdm_replay ... +bits=board_pdm.txt +pcm=board_pcm.txt
PDM_REPLAY_DONE bits=1500000 samples=9726
```

A rate note, because it would otherwise be a lie by omission: PYNQ clocks the part at
3.125 MHz and this decimator clocks it at 2.463054 MHz. Replaying the same bit sequence
more slowly scales the whole spectrum by 2.463054/3.125 = 0.7882, so the output has to be
read at 15993.86 × 3.125/2.463054 = **20291.6 Hz** to recover the original frequencies.
That is a property of replaying a recording, not of the decimator.

Against the naive thing a first attempt does — a boxcar (sinc¹) average of 192 bits, which
is what "just count the ones" means — **on the same bits**:

| | boxcar /192 | CIC⁴/22 + 289-tap FIR |
|---|---|---|
| 100 – 1000 Hz | −63.9 dBFS | −64.6 dBFS |
| 1000 – 3000 Hz | −56.7 dBFS | −70.9 dBFS |
| 3000 – 6000 Hz | −49.8 dBFS | −78.7 dBFS |
| 6000 – 8000 Hz | −50.0 dBFS | **−88.3 dBFS** |
| overall rms | −46.3 dBFS | −62.7 dBFS |
| DC | 1082.5 counts | **0.4 counts** |

The two agree to 0.7 dB where there is real acoustic content (100–1000 Hz) and diverge by
**38 dB** at 6–8 kHz, which is entirely the microphone's shaped quantisation noise that
the boxcar leaves in and the designed chain removes. The naive version's "audio" is 16 dB
of noise; its apparent brightness is the modulator, not the room.

And what the room actually sounds like, from the designed chain:

```
   20-   50 Hz    -76.7 dBFS      strongest bin: 436 Hz
   50-  100 Hz    -78.2 dBFS      8 loudest peaks (Hz):
  100-  200 Hz    -75.1 dBFS        30, 89, 198, 268, 327, 436, 495, 684
  200-  400 Hz    -68.2 dBFS
  400-  800 Hz    -67.9 dBFS      rms  -51.2 dBFS
  800- 1600 Hz    -73.6 dBFS      peak -29.0 dBFS
 1600- 3150 Hz    -73.7 dBFS
 3150- 6300 Hz    -79.0 dBFS
 6300-10000 Hz    -88.4 dBFS
```

A broadband floor peaking in the 200–800 Hz octaves with a harmonic family of discrete
tones — which is what cooling fans on a lab bench sound like — rolling off above the
filter's (rate-corrected) 8.9 kHz cutoff. **This is real audio from this board, decimated
by the RTL in this repo.**

---

## 7. The Zephyr side

Zephyr's DMIC API (`include/zephyr/audio/dmic.h`) wants three operations —
`configure`/`trigger`/`read` — and hands buffers back out of an application-provided
`k_mem_slab`. **Nothing in it requires DMA.** `dmic_read()` is defined as "give me a block
of PCM"; whether the driver got that PCM from a DMA descriptor or from a FIFO in a loop is
the driver's business. So the API fits a FIFO exactly.

`patches/0011-zephyr-dmic-pdm-mmio.patch` adds, to the local Zephyr clone:

- `drivers/audio/dmic_pdm_mmio.c` — the driver
- `drivers/audio/Kconfig.dmic_pdm_mmio` — `CONFIG_AUDIO_DMIC_PDM_MMIO`, default-y once
  the devicetree node is enabled
- `dts/bindings/audio/iiswc,pdm-mic.yaml` — the binding
- two one-line hooks in `drivers/audio/{Kconfig,CMakeLists.txt}`

`zephyr_ws/modules` is a symlink into a shared donor tree and is untouched.

Three things the driver does that are worth stating:

**It negotiates the rate rather than pretending.** `dmic_configure()` reads the hardware's
`RATE` register (millihertz), accepts a request within 1%, and **writes the real value back
into `cfg.streams[0].pcm_rate`**. An application that asks for 16000 is told it got 15994 (15993.859 Hz rounded to the nearest hertz; the exact figure is in the RATE register in millihertz).
That is what the field is for, and it means nothing downstream has to hard-code the
0.038%.

**It refuses stereo instead of faking it.** One microphone. A caller asking for two
channels gets `-EINVAL` and a log line, rather than a silent right channel and a lost
afternoon.

**It reports overrun once.** `STATUS.overrun` is sticky; the driver warns on the first
block that sees it, because after that point the audio is discontinuous and an ML
front-end has no way to know.

`scripts/06_patch_zephyr.sh` had to change: its idempotence marker was a single symbol
from `patches/0003`, so on a tree that already had 0003 it reported "already patched" and
silently skipped any patch added later. It now checks one marker per patch and uses
`git apply --reverse --check` per file, so a partially-patched tree converges.

### 7.1 Board and sample

`boards/chipyard/pynqz1_mic/` is `pynqz1_pext` plus the microphone node and three Kconfig
lines; no existing board definition was touched. The DTS places the peripheral at
**0x1009_0000**, on the periphery bus alongside the UART at 0x1002_0000 and clear of
everything else in this SoC's map (and of 0x1008_0000, which `CAMERA_PCB_SPEC.md` reserves
for the camera core). No PLIC interrupt: this PLIC has exactly one source
(`riscv,ndev = <1>`, the UART), and at 32 kB/s with a 64 ms FIFO there is nothing for an
interrupt to buy.

`samples/dmic_capture/` uses `<zephyr/audio/dmic.h>` and nothing board-specific. It prints,
per block, the DC, rms, peak, zero-crossing count and an 8-band integer Goertzel — enough
for a reader at the serial console to tell live audio from a stuck pin without any host-side
tooling. (Integer Goertzel because this SoC has no FPU: `riscv,isa` has no `f`.)

It also parks the PCM in DRAM, because **16 kHz of 16-bit audio does not fit down a 115200
baud console**. Rocket 0x8C00_0000 is PS physical 0x1C00_0000 through the top's
`{4'd1, addr[27:0]}` fold, clear of the image at the bottom of RAM and of
`samples/tacit_dma`'s buffer at 0x8800_0000. `scripts/34_rocket_mic_capture.sh` pulls it
back with `host/read_mem.py` and writes a WAV.

**The L2 flush before it prints the address is not optional.** Those are ordinary stores,
so they sit in Rocket's L1 and the inclusive L2, and the PS reads DRAM. Without the flush
the host gets whatever was there before — which, on a second run, is the *previous* run's
audio, and looks entirely plausible. Same register and the same reasoning as
`samples/tacit_dma` uses for the trace buffer:

```c
#define L2_FLUSH64 (0x2010000UL + 0x200)   /* write a phys addr -> flush that block */
```

### 7.2 What the lab checks

`scripts/34_rocket_mic_capture.sh` (`expected/dmic_capture.json`) does not check that it
did not crash. **A disconnected pin produces a perfectly well-formed stream of zeros and
every API call succeeds.** So:

| check | why it is not trivially true |
|---|---|
| `rate_hz == 15994` | not 16000, and the driver had to negotiate it from the RATE register |
| `not_silent` | rms above a floor and more than 20 distinct values — a dead or tied pin gives 0 and 1 |
| `dc_removed` | the hardware DC blocker; this microphone's 0.5164 density is 1074 counts without it |
| `spectral_tilt_ok` | 3150–6300 Hz at least 6 dB below 100–1000 Hz. **This is the check that the decimator works.** A sigma-delta microphone's noise rises steeply with frequency, so a naive average of the bitstream comes out *brighter* at the top of the band — measured at −14 dB of tilt, the wrong sign, against +14.5 dB for the real chain (§6) |
| `fingerprint_ok` | the eight-band profile correlates (>0.6) with the same microphone recorded through PYNQ's base overlay and decimated by this RTL under Verilator — an independent path with no Rocket, no Zephyr and no bitstream in it. Correlation rather than level, so a quieter day does not break it |

The analysis was validated before the board ever ran it: fed the reference data it compares
against, it returns **corr = 0.982** and **tilt = 14.5 dB**, so the gates at 0.6 and 6 dB
are floors rather than guesses.

---

## 8. Getting it to Rocket: the part that was actually hard

### 8.1 Rocket cannot see a PL peripheral in any bitstream this repo shipped

This is the finding that decided everything after it, and it is checkable in one command.
The generated `ChipTop.sv` for `PynqZ2RocketBigLittlePextTacitConfig` has exactly these
top-level ports:

```
clock_uncore, clock_tap, reset_io, custom_boot,
uart_0_txd, uart_0_rxd, jtag_*, serial_tl_0_*,
axi4_mem_0_*        <- the memory MASTER, 40-odd signals
```

`grep -icE "mmio|slave|_s_axi|front"` over that port list returns **0**. There is no AXI or
TileLink *slave* port on ChipTop. A block sitting next to it in the PL has no path to
Rocket at all — `soc_ctrl_regs` at 0x4000_0000 is mastered by the **PS**, not by Rocket
(`docs/TACIT_ON_FPGA.md`: "`M_AXI_GP0` reaches exactly one thing").

Three cheaper routes were considered and all three fail:

- **Put the registers on GP0 next to `soc_ctrl_regs`.** Works, and gives the *ARM* the
  microphone. Zephyr on Rocket still cannot reach it.
- **Have the PL block master HP0 and write PCM into a DRAM ring buffer** (the
  `TraceSinkDMA` shape). The PL write lands in DDR behind Rocket's L1 and L2, which have
  no coherence with an external master and no software-visible invalidate — Zicbom is not
  enabled and the DRAM window is cacheable in the address map. Rocket would read stale
  lines. Making it work would mean relying on cache pressure to evict, which is a
  statistical argument, not a design.
- **Decode a hole in Rocket's own DRAM window in the PL top** (e.g. steal 0x8FFF_F000 out
  of the `axi4_mem_0` path). Same problem, worse: 0x8000_0000 is cacheable, so a FIFO
  register read would be served from a cache line.

**So the peripheral has to be inside the SoC, on the periphery bus, as
`PynqZ2RocketTacitCamConfig` does it for the camera.** That is not the tidy option; it is
the only one.

### 8.2 The Chisel peripheral

`patches/0012-chipyard-pdm-mic.patch`, applied by `scripts/04_patch_chipyard_mic.sh`,
adds four files to the Chipyard generator and nothing else:

| file | what |
|---|---|
| `generators/chipyard/.../pdmmic/PdmMic.scala` | **new** — `PdmMicParams`/`PdmMicKey`, a `TLRegisterNode` wrapper around the `pdm_mic_core` BlackBox, `CanHavePeripheryPdmMic`, and the `WithPdmMic` fragment |
| `.../DigitalTop.scala` | one line: mix in `pdmmic.CanHavePeripheryPdmMic` |
| `.../iobinders/Ports.scala` | three lines: `case class PdmMicPort` |
| `.../iobinders/IOBinders.scala` | `WithPdmMicPunchthrough`, modelled line for line on `WithOspiPunchthrough` |

plus, in this repo, `PynqZ2RocketBigLittlePextTacitMicConfig` and its harness tie-off in
`chipyard/PynqZ2Configs.scala`.

**The Verilog is not in the patch.** `pdm_mic_core` is a plain `BlackBox` — a FIRRTL
extmodule — so Chipyard emits the instantiation and not the module. The generated
`extern_modules.sv` contains exactly `// external module pdm_mic_core` and nothing else,
which is the check that this is what happened. The module stays in `src/`, where
`sim/run_pdm_sim.sh` already tests it and where `tcl/build_rocket.tcl` adds it to the
Vivado project alongside `pynqz2_rocket_top.v` and `soc_ctrl_regs.v`. Copying it into the
generator's resources would have made three copies free to drift.

**No interrupt node.** This SoC's PLIC has exactly one source — the UART, with
`riscv,ndev = <1>` — which `boards/chipyard/pynqz1_pext`'s devicetree transcribes as
`interrupts = <1 1>`. Adding a second source changes `ndev` and the generated DTS. At
32 kB/s with a 64 ms FIFO an interrupt buys nothing, so the core's `irq` output is left
unread and the driver polls. The generated DTS confirms `riscv,ndev = <1>` is unchanged.

#### Two things the elaborator taught me

**`RegReadFn`'s two-argument overload needs `concurrency > 0`.** Writing the read function
as `(ivalid, oready) => (iready, ovalid, data)` sets `combinational = false`, and
`RegMapper` then fails elaboration with

```
requirement failed: Register-based device with request/response handshaking needs concurrency > 0
```

Raising `concurrency` would satisfy it and be wrong for this peripheral: it inserts a queue
between request and response, so the address driven at request time is gone by the cycle
the data is sampled, and the read would have to be latched. The **combinational** overloads
are both simpler and correct. Their single argument is `RegMapper`'s
`roready(i) && romask`, which — with every `f_rovalid` a literal `true` — reduces to "this
field's access is completing in this cycle", and `out.bits.data` is only sampled then
(`out.valid` is itself gated on it). Driving the shared address mux from it is safe and
there is no combinational loop, because that signal depends on `out.ready` and on the
literal valids, never on the data.

**The registers sit eight bytes apart, not four.** The Verilog core has one shared
`reg_addr` port and the periphery bus is 64 bits wide (`PeripheryBusParams.beatBytes = 8`).
Two 32-bit fields in one bus word would both be selected by an 8-byte access, and the
address mux would be ambiguous. One register per bus word removes the question for any
access size and costs nothing in a 4 KB page.

The emitted Verilog says both decisions took. From `ClockSinkDomain_1.sv`:

```verilog
  pdm_mic_core #(.CIC_R(22), .FIFO_ALOG2(10), .FIR_DECIM(7), .FIR_SHIFT(22),
                 .FIR_TAPS(289), .PDM_HALF(7), .RATE_MHZ(15993859), .SETTLE(131072))
  core (
    .clk(auto_clock_in_clock), .rst(auto_clock_in_reset),
    .pdm_m_clk(io_pdm_clk), .pdm_m_data(io_pdm_data),
    .reg_addr (out_f_roready_7 ? 4'h4 : out_f_roready_6 ? 4'h3 : ... : 4'h0),
    .reg_wr   (out_f_woready_5 | out_f_woready_2),
    .reg_rd   (out_f_roready_7 | out_f_roready_6 | ... ),
    .reg_rdata(_core_reg_rdata), .irq(/* unused */));
```

and `PMAChecker.sv`'s `legal_address` grew one term, `io_paddr[28:12] ^ 17'h10090` — the
address really is in the map, and as MMIO rather than as memory.

### 8.3 Out to the pins

`src/pynqz2_rocket_top.v` gains two ports and two connections inside `` `ifdef
PYNQZ2_HAS_MIC ``. A preprocessor conditional rather than a generate block, because for the
three builds without a microphone the lines then vanish entirely: their RTL is textually
unchanged and `u_soc` keeps its hierarchy path, and therefore its placement. Three working
bitstreams should not move because a fourth was added.

**The constraints are their own file, and that cost a build to learn.** The first attempt
guarded them inside the shared `pynqz2_rocket.xdc` with `foreach` and `if`, so the other
variants would skip them. Vivado 2023.1 parses anything in `constrs_1` as XDC — a
restricted subset, not Tcl — and answers with

```
CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not supported in the xdc constraint file
CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in the xdc constraint file
```

and then **runs neither branch**. The design placed anyway, because unconstrained I/O is
auto-placed, so what was heading for the board was a bitstream with the microphone wired to
two arbitrary balls. It was caught by noticing that the `MIC_PIN:` line the constraint file
was supposed to print never appeared.

`src/pynqz2_mic.xdc` is now a separate file, added to `constrs_1` only for the `mic`
variant, containing plain constraints and no control flow. And `tcl/build_rocket.tcl`
checks the result rather than hoping — in real Tcl, after synthesis, where `if` works:

```tcl
foreach port {mic_pdm_clk mic_pdm_data} {
  set obj [get_ports -quiet $port]
  if {[llength $obj] == 0} { error "... PYNQZ2_HAS_MIC did not reach the top" }
  set pin [get_property PACKAGE_PIN $obj]
  if {$pin eq ""} { error "... src/pynqz2_mic.xdc did not apply" }
  puts "MIC_PIN: $port -> $pin"
}
```

Both halves of that have now failed once each, silently, and neither would have been an
error on its own.

## 9. Evidence that the SoC change is contained

The Chipyard tree is shared, and other people's working bitstreams are built from it. The
question "does adding this peripheral disturb the configs that do not use it?" is answered
by measurement, not by construction.

### 9.1 The recipe

```bash
# before: snapshot the existing elaboration of the config on the board
cp -a $CHIPYARD_DIR/sims/verilator/generated-src/chipyard.harness.TestHarness.\
PynqZ2RocketBigLittlePextTacitConfig/gen-collateral  before/

scripts/04_patch_chipyard_mic.sh                       # apply the patch
make -C $CHIPYARD_DIR/sims/verilator CONFIG=PynqZ2RocketBigLittlePextTacitConfig verilog

# after: strip FIRRTL's source-location comments, which carry line numbers, and diff
for f in before/*;          do sed 's|\s*// @\[.*\]$||' "$f" > A/$(basename $f); done
for f in .../gen-collateral/*; do sed 's|\s*// @\[.*\]$||' "$f" > B/$(basename $f); done
diff -rq A B
```

### 9.2 The result

**All 506 generated files are byte-identical.** The only difference before stripping is in
the `@[...]` provenance comments:

```
<   output  axi4_mem_0_clock,  // @[.../iobinders/IOBinders.scala:432:22]
>   output  axi4_mem_0_clock,  // @[.../iobinders/IOBinders.scala:447:22]
```

432 → 447 is exactly the fifteen lines `WithPdmMicPunchthrough` inserts above the AXI
binder. Nothing else in the P-ext config moved.

### 9.3 And what the microphone actually adds

Mic config against P-ext config, same treatment. 516 files against 505, and 124 of the
common files differ — but **105 of those 124 differ only because `TLMonitor_49` became
`TLMonitor_50`**. TileLink monitors are simulation-only assertion modules; adding a bus
port renumbers every one of them, so a diff of `TLMonitor_50.sv` against `TLMonitor_50.sv`
is comparing two different monitors. The substantive list is short:

| file | what changed |
|---|---|
| `ChipTop.sv` | +2 ports, +2 connections. Nothing else |
| `DigitalTop.sv` | the peripheral, its crossbar port and its two pins |
| `PeripheryBus_pbus.sv` | the pbus crossbar grows from 2 outputs to 3 |
| `PMAChecker.sv`, `PMAChecker_3.sv` | one address range added to `legal_address` — one per hart |
| `TLROM.sv` | the bootrom's embedded DTB gains the node |
| `SBToTL.sv`, `TLBuffer_a29d64s7k1z3u.sv`, three `TLXbar`/`TLAtomicAutomata` | address decode widths |
| `RocketTile.sv`, `RocketTile_1.sv`, `PTW.sv`, `MemoryBus.sv`, `FixedClockBroadcast_3.sv`, `TestHarness.sv` | monitor renumbering only |
| `extern_modules.sv` | `// external module pdm_mic_core` |
| `filelist.f` | the new files |

New files: `TLInterconnectCoupler_pbus_to_pdmmic.sv`, `ClockSinkDomain_1.sv` (the
peripheral itself), a `TLFragmenter`, a `TLBuffer`, two `Queue2_TLBundle*` with their
`ram_2x121` / `ram_2x85` macros, and four monitors.

### 9.4 The address map, from the generated DTS

```dts
L34: pdm-mic@10090000 {
        compatible = "iiswc,pdm-mic";
        reg = <0x10090000 0x1000>;
        reg-names = "control";
};
...
riscv,ndev = <1>;          /* unchanged: the UART is still the only PLIC source */
```

and the generated register map JSON lists eight 32-bit fields at byte offsets 0x00, 0x08,
0x10, 0x18, 0x20, 0x28, 0x30, 0x38 — which is what the driver uses. That file is the
ground truth `boards/chipyard/pynqz1_mic/chipyard_pynqz1_mic.dts` is transcribed from.

## 10. On hardware

```
scripts/with_board.sh ./scripts/34_rocket_mic_capture.sh
```

### 10.1 The bitstream

`fpga/pynq-z2/scripts/build_mic_z1.sh`, five gates then Vivado 2023.1:

```
=== [0/5]  GP0 register file (DRAM self-test)   34 checks passed
=== [0b/5] GP0 register file (Rocket/SoC)       44 checks passed
=== [0c/5] datapath integration                 16 checks passed
=== [0d/5] PDM microphone decimator             24 checks passed
=== [0e/5] MBP RTL selftest                     SKIPPED (CHIPYARD_DIR unset)
MIC_PIN: mic_pdm_clk -> F17
MIC_PIN: mic_pdm_data -> G18
ACHIEVED_FCLK_HZ: 34482761
TIMING_WNS: 1.153
TIMING_WHS: 0.006
BITSTREAM_OK: build_rocket_mic_z1/pynqz1_rocket_mic.bit
```

Built from the **vendored** generated Verilog with `CHIPYARD_DIR` unset, so the bundle in
`chipyard/gensrc/` is demonstrably sufficient: no Chipyard install is needed to reproduce
this bitstream. Area and timing against the P-ext design are in §4.2 — **+657 LUT, +1 DSP,
+1.5 BRAM36, and WNS that did not move.**

### 10.2 What the board did

```
I: PDM microphone at 0x10090000: 15994 Hz, FIFO 1024 samples
MIC: rate 15994 Hz  channels 1  block 512 samples
MIC: blk  0 dc   494 rms   753 peak  2263 zc   31 | 125:-22 250:-41 500:-50 ...
MIC: blk  8 dc    -4 rms    33 peak   113 zc   71 | 125:-63 250:-51 500:-86 ...
MIC: blk 16 dc    -2 rms    29 peak    91 zc   99 | 125:-62 250:-81 500:-64 ...
MIC: captured 62 blocks of 512 samples at 15994 Hz
MIC: pcm_buf 0x8c000000 samples 31744 bytes 63488 rate 15994
MIC: DONE
```

The first line is the driver's probe: it read `ID` back as `0x504D4331` and `RATE` as
15993859 mHz, out of a peripheral it reached through a TileLink register node at
0x1009_0000. **`blk 0` is the startup transient** — dc 494, rms 753 against a steady state
of dc −2, rms 29 — which is the FIR's 289-entry history filling from zero and the DC
blocker's 19.9 Hz pole settling, about 50 ms. It is why the host analysis skips the first
100 ms, and it is visible rather than hidden.

### 10.3 Is it audio?

```
  31744 samples at 15994.0 Hz  (1.985 s); statistics skip the first 1599 (100 ms)
  mean    -2.09   rms    29.60 (-60.9 dBFS)   peak    131   distinct   224   zc   5847
  band levels, dBFS      this run   PYNQ base overlay (s6)
       20-   50 Hz          -77.2                -76.7
       50-  100 Hz          -76.6                -78.2
      100-  200 Hz          -74.8                -75.1
      200-  400 Hz          -66.9                -68.2
      400-  800 Hz          -66.9                -67.9
      800- 1600 Hz          -70.3                -73.6
     1600- 3150 Hz          -68.8                -73.7
     3150- 6300 Hz          -71.7                -79.0
  spectral tilt 100-1000 Hz over 3150-6300 Hz: 8.4 dB  (needs > 6)
  fingerprint correlation with the base-overlay profile: 0.803  (needs > 0.6)
  loudest peaks: 437, 328, 250, 203, 1000, 640, 62, 94 Hz
```

All 15 golden checks pass. Two runs, for repeatability: corr 0.859 / 0.803, tilt
9.2 / 8.4 dB, rms −60.9 dBFS both times.

### 10.4 The cross-check that makes it conclusive

The reference profile in §6 was measured hours earlier. So it was measured **again, minutes
after the Zephyr capture, in the same room**: PYNQ's base overlay was loaded over the mic
bitstream, one second of PDM was recorded through Xilinx's `audio_direct` IP, and those
bits were replayed through this repo's RTL under Verilator on the workstation. Two paths to
the same microphone with almost nothing in common — different capture IP, different
decimation host, no Rocket, no Zephyr, no bitstream on one side:

| band | **Zephyr on the silicon** | **PYNQ overlay + Verilator** |
|---|---|---|
| 20–50 Hz | −75.6 | −78.0 |
| 50–100 Hz | −74.1 | −75.6 |
| 100–200 Hz | −74.8 | −73.9 |
| 200–400 Hz | −66.8 | −66.8 |
| 400–800 Hz | −67.0 | −67.6 |
| 800–1600 Hz | −70.7 | −70.5 |
| 1600–3150 Hz | −69.4 | −68.6 |
| 3150–6300 Hz | −72.5 | −72.0 |
| **overall rms** | **−60.9 dBFS** | **−61.1 dBFS** |
| correlation | | **0.962** |

Loudest peaks, silicon: 62, 219, 266, 328, **437**, 625, 656, 1000 Hz.
Loudest peaks, overlay: 238, **337**, **436**, 594, **654**, 991, 1645, 1982 Hz.

437/436, 328/337, 656/654 and 1000/991 are the same tones — a harmonic family from the
bench's cooling fans, which is what a lab sounds like. **Overall level agrees to 0.2 dB.**

`out/rocket_mic/mic.wav` is the recording, at 15994 Hz, and it plays back as room noise.

### 10.5 What this does not show

- **No acoustic reference.** There is no speaker on this bench, so nothing establishes
  absolute sensitivity or the passband shape against a known source. What is established is
  that two independent paths to the same part agree, and that the spectrum has the tilt a
  working decimator produces and the opposite of the one a broken one produces.
- **Nobody has spoken into it.** The sample prints a live eight-band Goertzel per block
  precisely so that a person at the console can whistle and watch the 2 kHz band move; that
  was not done here.
- **The 53 ms settle time is still an inference**, not a datasheet number (§1, §12).

## 11. Regressions

Recording through PYNQ's base overlay (§2, §10.4) **overwrites the PL**, and so does the
mic bitstream, so all three were re-run at the end and all three pass:

| lab | result |
|---|---|
| `10_tacit_hello.sh` | PASS — 541,930 instructions traced, 258,319 trace bytes, 793,201 decoded lines, 2,372 Perfetto slices, all four golden values exact |
| `29_rocket_pext_run.sh` | PASS — 13/13, hart 0 computed all four MBP ops and hart 1 raised four illegal-instruction traps |
| `30_rocket_mb_lenet_pext_board.sh` | PASS — `max_abs_err 0` on both harts, little/big ratio 207, spread 0.079% of median |

The board is left with the P-ext bitstream loaded.

Three things could have disturbed an existing build, and all three were contained:

- **The Chipyard generator.** Re-elaborating `PynqZ2RocketBigLittlePextTacitConfig` with
  `patches/0012` applied gives 506 files byte-identical to the pre-patch bundle once
  FIRRTL's line-number comments are stripped (§9.2). The vendored P-ext bundle was not
  re-packed, so the bitstream the other labs use is literally the same file.
- **The structural top and the XDC**, which all four Rocket variants share. The
  microphone's ports and constraints are behind `` `ifdef PYNQZ2_HAS_MIC `` and in a
  separate constraint file respectively, so for the other three the preprocessed RTL is
  textually unchanged and no extra constraint is read (§8.3).
- **`tcl/build_rocket.tcl`**, also shared. The new `mic` arm and the two `if {$has_mic}`
  blocks are inert when `has_mic` is 0, which it is by default for the other three.

`scripts/06_patch_zephyr.sh` did change behaviour, and only for the case it previously got
wrong: a tree already carrying `patches/0003` reported "already patched" and silently
skipped any patch added later.

---

## 12. Sources

Hardware claims, in decreasing order of directness:

| claim | source | kind |
|---|---|---|
| the part is on the board and running | recorded from it — density 0.5164, shaped noise floor | **measured, this board** |
| F17 / G18 carry it | `Xilinx/PYNQ` `boards/Pynq-Z1/base/vivado/constraints/base.xdc`, and §2 recorded through that very bitstream | **measured + vendor source** |
| Knowles SPK0833LM4H-B, PDM, 1–3.3 MHz, L/RSEL tied low, data on the rising edge | Digilent *PYNQ-Z1 Reference Manual* §13, §13.2 (via an Internet Archive snapshot; digilent.com serves a Cloudflare challenge) | **datasheet** |
| AUD_PWM R18, AUD_SD T17 | same, §14 — and they match `base.xdc` | **datasheet + vendor source** |
| the Arty Z7-20 has no microphone | Digilent *Arty Z7 Reference Manual*, feature comparison; `Digilent/digilent-xdc` `Arty-Z7-20-Master.xdc` has `## Audio Out` only | **datasheet + vendor source** |
| there is no `pynq-z1` Digilent board file | `Digilent/vivado-boards` `new/board_files/` listing | **vendor source** |
| PYNQ clocks the part at 3.125 MHz | `Xilinx/PYNQ` `boards/ip/audio_direct_1.1/src/pdm_rxtx.vhd` generics, and the measured 195,120 words/s | **vendor source + measured** |
| the part's wake-up time | **not established** — Knowles' site 404s the datasheet. §3.6's 53 ms is an inference | **inferred** |
| ChipTop has no MMIO slave port | `grep` over the generated `ChipTop.sv` in `out/gensrc/...PextTacitConfig/` | **measured, this build** |

Area, timing and filter numbers are all from the runs quoted in §4, §5 and §6; the raw
reports are in `rtl_study/pdm/ooc_out/` and the filter design in
`rtl_study/pdm/fir_design.json`.
