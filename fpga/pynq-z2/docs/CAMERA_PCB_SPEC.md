# HM01B0 camera PCB for PYNQ-Z2 — design specification

> **Note, 2026-09-17: this is the OLDER PYNQ-Z2 design.  Do not take pins from it.**  The
> board that was built is the PYNQ-**Z1** shield `riskybirdv3_pynq_camera` rev 0.6 on the
> Arduino/chipKIT header (ordered 2026-09-15).  Its pin map is
> `archive/drafts/PINMAP_riskybirdv3_pynq_camera_rev0.6.md`, and the bitstream that uses it is
> `0x5A5A001E` (`docs/CAMERA_Z1.md`, `src/pynqz2_cam.xdc`).  Section 2's RPi-header balls, the
> 40 MHz clock in section 5 and the "6.25 MHz maximum" PCLK figure do not apply to it: the build
> runs at 34.4828 MHz, and the HM01B0-MNA datasheet (preliminary V01, section 1.3) gives MCLK
> 3-36 MHz, PCLK 36 MHz maximum, and 6 MHz for QVGA at 60 fps on the 8-bit interface.
> **Section 7, what the RTL expects, still applies** -- with two additions found in the
> `0x5A5A001E` RTL simulation (`CAMERA_Z1.md` section 5): the line-sized buffer needs a DMA transfer
> already running when a frame starts, and a transfer armed with no PCLK cannot be aborted.

Specification for a Raspberry-Pi-HAT-form-factor board carrying a Himax **HM01B0**
ultra-low-power monochrome image sensor, plus an optional USB-UART bridge.

> Part number: the sensor is the **HM01B0** (there is no HM01B1). The capture RTL already
> in the tree — `generators/chipyard/.../ospi/` — targets HM01B0 8-bit parallel mode.

---

## 1. Why a PCB is required at all

**PYNQ-Z2's PL I/O is 3.3 V and cannot be changed.** The board has exactly two jumpers —
J9 (power source) and JP1 (boot mode). There is no VADJ. Every published constraints file
uses `LVCMOS33` exclusively, the Pmod connectors supply 3.3 V, and the board file marks
every PL pin `LVCMOS33`.

**The HM01B0's IOVDD is 1.8 V (or 2.8 V).** 3.3 V is out of spec either way.

So unlike the Arty-200T — where a bank could in principle be moved to `LVCMOS18` — level
translation here is **mandatory**, and that is the PCB's primary job.

The good news is that the interface is slow. In 8-bit mode the HM01B0's output clock is
**6.25 MHz maximum** (160 ns period), giving ~59 fps at 324×324. Translator propagation
delay and connector parasitics are irrelevant at that rate, which makes this a low-risk
two-layer board.

---

## 2. Connector and pin map

Use the **Raspberry Pi 40-pin header**, which carries 28 PL pins on a single connector, so
the source-synchronous video bus stays together. (Two Pmods would also physically fit but
split the bus for no benefit.)

The whole video interface is placed in **bank 13**, which conveniently has exactly 8
non-clock-capable pins for the data bus and 6 clock-capable pins for the rest. All pin
functions below were read from the Vivado package database, not a datasheet.

### Video interface — all bank 13

| Signal | Dir (FPGA) | Header pin | Zynq ball | Pin function |
|---|---|---|---|---|
| `D0` | in | 37 | W9 | `IO_L16N_T2_13` |
| `D1` | in | 33 | W8 | `IO_L15N_T2_DQS_13` |
| `D2` | in | 23 | W10 | `IO_L16P_T2_13` |
| `D3` | in | 21 | V10 | `IO_L21N_T3_DQS_13` |
| `D4` | in | 19 | V8 | `IO_L15P_T2_DQS_13` |
| `D5` | in | 15 | U8 | `IO_L17N_T2_13` |
| `D6` | in | 7 | V6 | `IO_L22P_T3_13` |
| `D7` | in | 16 | W6 | `IO_L22N_T3_13` |
| **`PCLK`** | in | **31** | **Y7** | **`IO_L13P_T2_MRCC_13`** ← clock-capable |
| `MCLK` | out | 29 | Y6 | `IO_L13N_T2_MRCC_13` |
| `FVLD` | in | 35 | Y8 | `IO_L14N_T2_SRCC_13` |
| `LVLD` | in | 13 | V7 | `IO_L11N_T1_SRCC_13` |
| `TRIG` | out | 11 | U7 | `IO_L11P_T1_SRCC_13` |
| `INT` | in | 40 | Y9 | `IO_L14P_T2_SRCC_13` |

**PCLK on an MRCC pin is the one placement that matters.** It is the capture clock domain
in `HM01B0Capture`, and an MRCC pin can drive a BUFG directly. Putting it on a general pin
would work at 6.25 MHz only with `CLOCK_DEDICATED_ROUTE FALSE` and a warning.

### I²C — bank 34, the standard RPi positions

| Signal | Header pin | Zynq ball | Note |
|---|---|---|---|
| `SDA` | 3 | W18 | standard RPi `SDA1` |
| `SCL` | 5 | W19 | standard RPi `SCL1` |

Sensor slave address **0x24**, 400 kHz max. Driven by Chipyard's `TLI2C`, not by the
capture core.

> **Consequence:** pins 3, 5, 8, 10, 18, 22, 27 and 28 of the RPi header are **shared with
> PMODA**. Using pins 3/5 means PMODA is unavailable while this board is fitted. PMODB is
> unaffected and stays free. Using standard RPi I²C positions is worth that, since it keeps
> off-the-shelf I²C peripherals usable.

### Optional: USB-UART bridge — bank 35

Adding a CP2102 / CH340 / FT231X costs ~$1–2 and gives Rocket a console that works with
**no Linux running** — the one thing the PS-UART1-over-EMIO route cannot do (see
`UART.md`).

| Signal | Dir (FPGA) | Header pin | Zynq ball |
|---|---|---|---|
| `UART_RX` | in | 38 | A20 |
| `UART_TX` | out | 36 | B19 |

These are 3.3 V CMOS straight from the bank — **no level shifting**, since the bridge chips
are 3.3 V parts.

### Pin budget

16 video + I²C, plus 2 optional UART = **18 of 28** PL pins. Ten spare, including four
clock-capable, for a second camera or expansion.

---

## 3. Level translation

| Group | Signals | Direction | Part |
|---|---|---|---|
| Data bus | `D0`–`D7` | 1.8 V → 3.3 V | `SN74AXC8T245` (DIR tied) |
| Sync + interrupt | `PCLK`, `FVLD`, `LVLD`, `INT` | 1.8 V → 3.3 V | `SN74AXC4T245` (DIR tied) |
| Clock + trigger | `MCLK`, `TRIG` | 3.3 V → 1.8 V | `SN74AXC2T245` (DIR tied) |
| I²C | `SCL`, `SDA` | bidirectional, open-drain | **`PCA9306`** or `TXS0102` |

**Use direction-fixed '245 parts, not auto-direction ones.** An auto-sensing translator
(TXB0108 and relatives) has weak output drive and one-shot edge acceleration that misbehaves
on continuous clocks — `PCLK` and `MCLK` are exactly the signals they handle worst. Every
video-bus direction is known and fixed, so tie `DIR` to a rail.

**Never put a '245 on I²C.** It is open-drain and bidirectional; use a dedicated translator.
Pull-ups: 2.2 kΩ to 1.8 V on the sensor side, 2.2 kΩ to 3.3 V on the FPGA side.

The `AXC` family is specified down to 1.65 V on the B side and is fast enough that 6.25 MHz
is not worth analysing.

---

## 4. Power

Source: **3.3 V from RPi header pins 1 and 17**, and GND from pins 6, 9, 14, 20, 25, 30, 34,
39. 5 V is available on pins 2 and 4 if a higher-headroom LDO input is wanted.

| Rail | Voltage | Feeds | Suggested part |
|---|---|---|---|
| `AVDD` | **2.8 V** | sensor analog | any 150 mA LDO, e.g. `TLV70028` |
| `IOVDD` | **1.8 V** | sensor I/O + translator B side | any 150 mA LDO, e.g. `TLV70018` |
| `DVDD` | **1.5 V typ.** | sensor core | ⚠ see below |
| `VCCA` | 3.3 V | translator A side | from the header |

> ⚠ **Confirm DVDD against the datasheet for your exact module.** Some HM01B0 variants
> generate the 1.5 V core rail from an internal LDO off AVDD and expect only a decoupling
> capacitor; others want it supplied. Provision a third LDO footprint with a 0 Ω bypass
> option so either is possible without a respin.

Decoupling, per the datasheet: **0.1 µF plus ≥10 µF on every power rail**, placed at the
sensor.

Current is a non-issue — the HM01B0 is an ultra-low-power part (~1.1 mW at QQVGA 30 fps).
Any small LDO is enormously oversized; choose for footprint and availability.

---

## 5. Clocking

`MCLK` is generated in the FPGA by dividing the PL clock:
`MCLK = PL_clk / (2 × (mclkDiv + 1))`, with `mclkDiv` an 8-bit MMIO field
(`CaptureParams.mclkDivWidth = 8`). At the built PL clock of **40 MHz**, `mclkDiv = 2`
gives 6.67 MHz — a sensible starting point. The sensor derives `PCLK` from `MCLK`
internally; in 8-bit mode `PCLK` tops out at **6.25 MHz**.

No oscillator on the PCB. No PLL. Nothing to tune.

---

## 6. Mechanical

- **Raspberry Pi HAT outline**, 65 × 56.5 mm, with the standard 4 × M2.5 mounting holes.
- 2×20 female header, 2.54 mm, on the underside to mate with the PYNQ-Z2.
- Two layers is sufficient. Ground pour on the bottom; keep `PCLK` and `D0`–`D7` over
  continuous ground.
- Keep the sensor-side (1.8 V) traces short — translators close to the sensor, not the
  connector.
- Provide a sensor-module footprint appropriate to the part you source; HM01B0 breakouts
  vary, so fix that choice before layout.

---

## 7. What the RTL already expects

The capture core exists (`generators/chipyard/src/main/scala/ospi/`) and defines the
contract this board must satisfy:

- **8-bit parallel mode only** — `CaptureParams` asserts `dataWidth == 8`.
- Default window **324 × 244**, max **324 × 324**.
- Encoder MMIO at **`0x10080000`**; DMA sink registers follow.
- `WithOspiCaptureDma` streams frames straight to DDR. **Use it.** The default
  `frameBufferDepth` is `324*324+1`, roughly 1.15 Mb ≈ 32 BRAM36; with the Rocket build
  already at 58 of 140 BRAM, a line-sized buffer plus DMA is the only configuration that
  fits comfortably.
- Bring-up diagnostics are built in: `PCLKCNT`, `FVLDCNT`, `LVLDCNT` read back zero when the
  sensor is not clocking, which distinguishes "no camera clock" from "no frame sync" without
  a scope.

---

## 8. Checklist before fabrication

1. **Confirm `DVDD`** against the datasheet for the exact module sourced (§4).
2. **Confirm the sensor module's footprint and connector** — the one item not pinned here.
3. **Re-derive the pin map against your own Vivado** if the part or speed grade changes:
   `get_package_pins`, checking `BANK` and `PIN_FUNC` for `MRCC`/`SRCC`.
4. **Decide on the UART bridge** (§2). Two pins and ~$2; much easier now than a respin.
5. **Accept losing PMODA**, or move I²C to pins 38/36 and put the UART elsewhere.
6. Sanity-check the HAT outline against the PYNQ-Z2's header position and component
   heights — the board has HDMI and Ethernet connectors near the header.

### Not needed, despite appearances

- **No oscillator** — MCLK comes from the FPGA.
- **No programmer** — the on-board FT2232 channel A is the FPGA's JTAG over the same USB
  cable that powers the board.
- **No PL-side DRAM** — memory is the PS's.

---

## 9. Other sensors worth putting on this board

The selection principle is not "what sensors are cool" but **what makes the tutorial's
thesis visible**. The stack's argument is multi-rate ML + robotics workloads under
real-time constraints on heterogeneous cores. A sensor earns its place if it creates a
*genuinely different rate* for the scheduler to reconcile — and it is close to free if
riskybird and the RoSE co-sim already consume it, because then **one application runs on
three substrates**: PYNQ-Z2 hardware, riskybird silicon, and RoSE virtual sensors.

### Tier 1 — add these, they cost zero extra pins

Both hang off the **I²C bus the camera already needs**, at addresses that do not collide
with the sensor's 0x24.

| Sensor | Bus / addr | Driver | Rate | Pins |
|---|---|---|---|---|
| **BMI088 IMU** (`bosch,bmi08x`) | I²C, accel 0x18/0x19, gyro 0x68/0x69 | **in-tree**, both I²C and SPI bindings | ~1 kHz | **0** (+2 for data-ready INTs) |
| **VL53L1X ToF** (`st,vl53l1x`) | I²C, 0x29 | **in-tree** | ~50 Hz | **0** (+1 INT, +1 XSHUT) |

Why these two specifically:

- Together with the camera they give **three rate tiers on one board** — IMU at 1 kHz,
  ToF at 50 Hz, camera at 30 Hz. That spread *is* the multi-rate scheduling demonstration;
  without it the scheduler is solving a problem the room cannot see.
- They are exactly what the RoSE flight stack consumes (`accel[3]`, `gyro[3]`, `height`,
  `tof_valid`) and what riskybird carries, so the same estimator and TinyMPC code runs
  unchanged across all three substrates.
- **BMI088 is 3.3 V native** (VDD 1.71–3.6 V, VDDIO 1.2–3.6 V) — no level shifting, unlike
  the camera.

**Spend 2 pins on the IMU's data-ready interrupts.** Polling a 1 kHz sensor from a
scheduled task blurs exactly the timing the tutorial is trying to show; an interrupt gives
a crisp periodic tick to schedule against.

### Tier 2 — cheap, and serves the tracing story directly

**Four GPIO "trace marker" pins.** Have the runtime toggle a pin at task boundaries —
sensor read, model dispatch, control output. Put a logic analyser or scope on them and the
schedule becomes physically visible, as an independent ground truth against the TACIT
Perfetto timeline. Costs 4 pins and no parts, and it is the only thing on this list that
directly corroborates the tutorial's central claim about tracing.

**PWM out to a motor driver or LEDs.** `ChipTop` already exposes `pwm_0_gpio_*`. Closes
perception → planning → control → *actuation* without a whole drone.

### Tier 3 — interesting, but each is a project

- **Microphone.** Audio is the most attractive *idea* here: keyword spotting is the
  canonical TinyML workload, the models are small enough to run on Rocket without an
  accelerator, and it is a genuinely different data shape from frames — continuous
  streaming rather than periodic capture, which is a real test of the runtime's I/O paths.
  **But Chipyard has no I²S or PDM peripheral.** Zephyr's in-tree PDM/DMIC bindings are all
  vendor SoC blocks (Ambiq, Nordic, NXP). This needs new RTL — an I²S receiver or a PDM
  decimation filter — plus a driver. Worth doing, not worth assuming.
- **PMW3901 optical flow.** Completes the drone suite and matches RoSE's `flow[2]`, but the
  driver is riskybird-custom rather than in-tree, and SPI costs 4 pins.
- **ADS7128 ADC.** Custom driver; useful for battery and current sensing on riskybird, but
  no model consumes it and it adds no new rate tier.

Environmental sensors (BME280 and friends) are in-tree and cheap, but nothing in the
workload reads them and they add no rate the scheduler cares about. Skip.

### ⚠ Driver-branch caveat

The Zephyr commit currently wired into the build (`4329bf61c4f`) is on branch **`dev`**,
which has `bmi08x`, `vl53l1x` and `vl53l0x` but **not** `vl53l5cx` or `ads7128`. The
multizone ToF and the ADC live on **`rose-2-dev`**, which is what `.gitmodules` names.
Confirm which branch the build actually uses before designing around a driver.

This is also why Tier 1 specifies **VL53L1X** (single-zone, in-tree on both) rather than
the VL53L5CX multizone part riskybird uses.

### Revised pin budget

| Group | Pins |
|---|---|
| Camera video + I²C | 16 |
| UART bridge (optional) | 2 |
| IMU data-ready interrupts | 2 |
| ToF INT + XSHUT | 2 |
| Trace marker pins | 4 |
| **Total** | **26 of 28** |

Fits, with two spare. Drop the trace markers to 2 if PWM is wanted instead.
