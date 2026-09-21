# A 0.96" SSD1306 OLED on the camera shield's I²C bus

**Status (2026-09-17 17:10 PDT): working on hardware. A 0.96" SSD1306 was fitted to the
shield's J4 and the status screen ran on the board twice, both times confirmed by a person
looking at the glass (§7.7). The host tests, the TLI2C RTL test and the full-SoC TestHarness
run all pass, both committed predictions are confirmed, and one Zephyr defect is proven with
its fix applied (`patches/0120`, §8). One correction is recorded here rather than buried: the
second live run was scored FAIL by a defect in the lab's own arithmetic while the display was
working in front of a witness (§7.7.1).** No bitstream on the board has I²C today. The camera
build `0x5A5A001E` (camera agent) will be the first one that does; it is elaborated
(`04d69e9`) but not built. This document covers four things:
- what the SoC side must provide for the OLED (§2);
- what I²C would cost on the builds without a camera (§3);
- whether any RTL beyond the TLI2C is worth having (§4);
- the Zephyr side (§5).

§6 holds predictions committed before any simulation, and §7 will hold the results.

Scope, per the user: "hardware changes" means the FPGA RTL, top level and XDC. The shield
(`riskybirdv3_pynq_camera` rev 0.6) is finished, and this document proposes no board changes.

| | |
|---|---|
| The part | 0.96" 128×64 module, SSD1306, I²C only, 7-bit address 0x3C (0x3D on some modules). **Fitted and working on the bench board, 2026-09-17, seen by a person twice (§7.7)** |
| The bus | PL `SDA` = P15, `SCL` = P16, LVCMOS33. The Z1 has 2.2 kΩ pull-ups (R49/R50). The camera (HM01B0, 0x24) sits behind a PCA9306 on the 1.8 V side; J4 is on the 3.3 V side |
| SoC block | Chipyard `WithI2C`: rocket-chip-blocks `TLI2C`, an OpenCores `i2c_master` transcription at `0x1004_0000` |
| Driver | Zephyr `drivers/i2c/i2c_sifive.c` (polled) + `drivers/display/ssd1306.c` + CFB |
| RTL beyond the TLI2C? | **Not needed**: measured 3.06 M hart cycles per refresh, 8.9 % of one hart at 1 Hz, out of idle time (§4, §7.5) |
| I²C in the base bitstream? | **No separate I²C-only variant.** The reserved `0x5A5A001F` (camera on micrgb) already carries it (§3) |
| One correction on the record | run 2 was scored **FAIL while the display was working**, by the lab's own arithmetic; both defects behind it are fixed and the runs re-score PASS (§7.7.1) |

---

## 0. Findings and their status

Each finding is a hypothesis until a test settles it. The I²C stack is proven: the same TLI2C
and this Zephyr fork's `i2c_sifive.c` have driven the HM01B0 and other sensors on the Arty-200T
configs. So a finding here is only called a defect once a test on our stack shows it failing,
and once it explains why the 200T stack never hit it.

| # | Finding (hypothesis) | Status | Evidence / how it will be settled |
|---|---|---|---|
| F1 | `i2c_sifive` sends START + address for every `i2c_msg`, so `i2c_burst_write` (used by `ssd1306.c` for every command and data block) puts a repeated START between the control byte and the payload | **CONFIRMED BY TEST** on the generated TLI2C with the unmodified driver (§7.2). Fix drafted, not applied (§8) | Reading of `i2c_sifive_write_msg`. The code found for the 200T sensors never calls `i2c_burst_write`: the riskybird samples and the in-tree BMI08x/VL53L1X drivers use single-buffer `i2c_write`/`i2c_write_read`. So the path was probably never exercised there |
| F2 | `i2c_sifive` has no bus lock, and its TIP busy-wait has no timeout | **rule, not patch.** The unbounded wait is real (§7.4: the driver never returns while SCL is held low) but nothing on this bus holds SCL | Only matters with more than one bus user. The demo has two (camera AE, OLED), so the sample serialises them at application level (§5.4). A lock in the driver is not proposed |
| F3 | The top level must wire the TLI2C open-drain: pad driven low only when `oe`, released otherwise | **refuted as a finding — it is the proven wiring** | `WithArty200TI2C` (`riskybird_chipyard/fpga/src/main/scala/arty200t/HarnessBinders.scala`): `UIntToAnalog(port.io.scl.out, pin, port.io.scl.oe)`. §2 lists it as a check on the camera build's Verilog top |
| F4 | Zephyr needs `clock-frequency` on the I²C node, and the generated DTS lacks it | **refuted** | `dts/riscv/chipyard/chipyard-riscv.dtsi` already has `i2c0: i2c@10040000` with `clock-frequency = <100000>`, disabled. Zephyr never reads Chipyard's generated DTS |
| F5 | The generated TLI2C inverts the polarity of OpenCores' `scl_sync` and `slave_wait`, so SCL runs faster than `f/(5·(prescale+1))` and clock stretching is not honoured | **CONFIRMED BY MEASUREMENT, and harmless here** (§7.3): 112.7 kHz at the 100 kHz setting, inside every limit of both parts on this bus; a target that stretches for more than ~7 µs wedges the controller until software reconfigures it, and neither part stretches | `TLI2C.sv`: `_GEN_3 = cnt == 0 \| ~control_coreEn \| dSCL & ~sSCL & ~sclOen`. To be dropped unless the sim measures SCL out of spec (§6 P1) |
| F6 | Adding `WithI2C` renumbers the PLIC: the I²C takes source 1, the UART moves 1 → 2 and the micrgb GPIO 2..7 → 3..8 | **CONFIRMED** by `0x5A5A001E`'s generated DTS (I²C 1, UART 2, GPIO 3..8, ospi 9, `riscv,ndev` 9), per camera agent. Its board `chipyard_pynqz1_cam` carries the renumbering | `DigitalTop` mixes in `HasPeripheryI2C` before `HasPeripheryUART` and `HasPeripheryGPIO`. `PynqZ2RocketTacitCamConfig`'s generated DTS has `i2c@10040000 interrupts = <1>` and `serial@10020000 interrupts = <2>`. The camera agent confirms it against `0x5A5A001E`'s generated DTS |

---

## 1. Electrical facts the RTL and driver depend on

Only the numbers that set the bus speed and the driver configuration are listed here.

**Addresses.** SSD1306 at 0x3C (write byte 0x78), or 0x3D (0x7A) on modules strapped that way.
The HM01B0 is 0x24 (0x48). No collision. The pin map and the Z1 schematic summary list nothing
else on these nets: the PCA9306 is not addressable, and the Z1 adds only R49/R50. The sample
declares both 0x3C and 0x3D and uses whichever ACKs (§5.3).

**Pull-ups and rise time.** Many modules carry their own 4.7 kΩ or 10 kΩ pull-ups, in
parallel with the Z1's 2.2 kΩ. The table gives the 30→70 % rise time, 0.8473·R·C<sub>b</sub>. The bus
capacitance C<sub>b</sub> is **estimated** at 50 pF (FPGA pad, Z1 and shield traces, PCA9306, module)
and at a pessimistic 100 pF:

| Pull-up seen by the bus | 50 pF | 100 pF | Fast-mode limit |
|---|---|---|---|
| 2.2 kΩ (module without pull-ups) | 93 ns | 186 ns | 300 ns |
| 2.2 ‖ 10 kΩ = 1.80 kΩ | 76 ns | 153 ns | 300 ns |
| 2.2 ‖ 4.7 kΩ = 1.50 kΩ | 64 ns | 127 ns | 300 ns |

All are inside the 400 kHz limit, so the pull-ups do not constrain the bus speed. The worst
case sink current is 1.50 kΩ at V<sub>OL</sub> = 0.4 V: 1.94 mA from the 3.3 V side, plus 0.64 mA
through the PCA9306 from the 1.8 V side's 2.2 kΩ. That totals 2.57 mA, within the 3 mA the
spec sizes pull-ups for.

The one consequence for software is on the target side. If the module's SDA driver cannot
pull that load below the FPGA's V<sub>IL</sub>, its ACK is lost and a fitted module reads as "not
fitted". The board lab reports absence with that caveat (§7).

**Rise time never reaches the TLI2C's timing.** The master only reacts to *falling* SCL edges
(P1), and 127 ns is 4.4 cycles at 29 ns. It does eat into t<sub>HIGH</sub> at the target.

**Bus speed.** The polled driver computes `prescale = f_sys / (5 · f_bus) − 1`. Here
`f_sys = SIFIVE_PERIPHERAL_CLOCK_FREQUENCY = CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC ×
CONFIG_RTC_CLOCK_DIVIDER_VALUE = 34483 × 1000`, and `f_bus` is the DTS `clock-frequency`:

| DTS `clock-frequency` | prescale | OpenCores formula at 34,482,761 Hz | P1 prediction | **measured in RTL (§7.3)** |
|---|---|---|---|---|
| 100000 (board DTS and dtsi) | 67 | 340 cycles → 101.42 kHz | 306 cycles → 112.69 kHz | **306 cycles exactly → 112.69 kHz** |
| 400000 | 16 | 85 cycles → 405.68 kHz | 80 cycles → 431.03 kHz | **79–81, mean 80.08 → 430.6 kHz** |

Anything else is not selectable: `i2c_map_dt_bitrate()` quantises `clock-frequency` to the
standard classes, so a request for 344,830 Hz comes out as Standard mode (verified in §7.3).
**Use `clock-frequency = <100000>`**, which is what the camera board already sets: the bus has
one controller and therefore one prescaler for both devices.

---

## 2. The I²C path in the camera build (`0x5A5A001E`)

The camera agent owns the config, the top level and the XDC. This section is the checklist its
generated collateral is reviewed against. Items marked *stock* follow from the generator source
and the older `PynqZ2RocketTacitCamConfig` elaboration
(`riskybird_chipyard/sims/verilator/generated-src/chipyard.harness.TestHarness.PynqZ2RocketTacitCamConfig/`).
**Result: every item checks out**, from the camera agent's report on the elaborated
`PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig` (`04d69e9`) and from that
elaboration's own collateral. The generated `TLI2C.sv` there is byte-identical to the one
this document's RTL test drove, except for the monitor's instance name (`TLMonitor_71` against
`TLMonitor_59`), so every measurement in §7.3 applies to `0x5A5A001E` as built.

| Check | Expected | Source |
|---|---|---|
| TLI2C present, MMIO | `i2c@10040000`, `reg = <0x10040000 0x1000>`, `compatible = "sifive,i2c0"` | stock `WithI2C(address = 0x10040000)` |
| Clocking | synchronous on the pbus clock. `WithI2C` puts `AsynchronousCrossing` into `I2CParams`, but `I2CAttachParams` has its own `controlXType = NoCrossing` and ignores those fields. The elaboration shows `i2cClockDomainWrapper` clocked from `pbus_auto_fixedClockNode` and an `IntSyncSyncCrossingSink`. No new clock port | stock |
| Interrupt | PLIC source **1**, with the UART moved to 2 (F6). The polled Zephyr driver never connects it; the UART's number is what matters | stock trait order — **confirmed**: I²C 1, UART 2, GPIO 3..8, ospi 9, `riscv,ndev` 9, and the new board `chipyard_pynqz1_cam` carries it |
| Prescaler | 16-bit register, reset 0xFFFF; the core is disabled at reset (`control = 0`) | `TLI2C.sv` |
| Ports | `i2c_0_{scl,sda}_{in,out,oe}` via `WithI2CPunchthrough`, which `AbstractConfig` already includes, as it does `WithI2CTiedOff`. `*_out` is the constant 0 | stock |
| Top level | one `IOBUF` per line: `.I(1'b0)` (or `i2c_0_*_out`), `.T(~i2c_0_*_oe)`, `.O(i2c_0_*_in)`. **SCL open-drain like SDA** — the same as `WithArty200TI2C`. The failure to look for is `.T(oe)`, which holds both lines low while idle | proven 200T wiring — **confirmed**: `IOBUF (.I(i2c_*_out), .T(~i2c_*_oe), .O(i2c_*_in))` |
| XDC | `PACKAGE_PIN P15` → SDA and `P16` → SCL, `IOSTANDARD LVCMOS33`. An internal `PULLUP` is optional (the Z1 has 2.2 kΩ). The inputs are asynchronous and sampled by the TLI2C's filter; the 200T used no extra synchroniser either | pin map — **confirmed**: P15/P16 LVCMOS33 with `PULLUP TRUE` and false paths |
| Reset state and a second target | At reset `sclOen = sdaOen = 1`, so both lines are released and nothing is driven until software enables the core. A second target on the bus needs nothing from the RTL | `TLI2C.sv` |
| Camera driver's use of the bus | single-buffer `i2c_write` and `i2c_write_read`, main thread only, no `i2c_configure` — so it never triggers F1, and the prescaler stays at the board DTS's 100 kHz for both devices. The OLED must take the application bus lock (§5.4) because the camera writes from another thread in the combined demo | camera agent |

---

## 3. The OLED on builds without the camera

**What adding I²C alone to micrgb (`0x5A5A0006`) or the roccmoon family takes.** These are
proposals only: no new MAGIC, no build.

```scala
// PynqZ2Configs.scala -- proposal, not applied
class PynqZ2RocketBigLittlePextTacitMicRgbI2cConfig extends Config(
  new chipyard.config.WithI2C(address = 0x10040000L) ++   // punchthrough + tie-off already in AbstractConfig
  new PynqZ2RocketBigLittlePextTacitMicRgbConfig)
```

```verilog
// pynqz2_rocket_top.v -- proposal, not applied
`ifdef PYNQZ2_HAS_I2C
  inout  wire i2c_scl,   // P16
  inout  wire i2c_sda,   // P15
`endif
...
`ifdef PYNQZ2_HAS_I2C
  wire i2c_scl_i, i2c_scl_oe, i2c_sda_i, i2c_sda_oe;
  IOBUF u_i2c_scl (.IO(i2c_scl), .I(1'b0), .T(~i2c_scl_oe), .O(i2c_scl_i));
  IOBUF u_i2c_sda (.IO(i2c_sda), .I(1'b0), .T(~i2c_sda_oe), .O(i2c_sda_i));
`endif
// ChipTop: .i2c_0_scl_in(i2c_scl_i), .i2c_0_scl_out(), .i2c_0_scl_oe(i2c_scl_oe),
//          .i2c_0_sda_in(i2c_sda_i), .i2c_0_sda_out(), .i2c_0_sda_oe(i2c_sda_oe),
```

```tcl
# src/pynqz2_i2c.xdc -- proposal, added only for variants that define PYNQZ2_HAS_I2C
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports i2c_scl]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports i2c_sda]
set_false_path -from [get_ports {i2c_scl i2c_sda}]
set_false_path -to   [get_ports {i2c_scl i2c_sda}]
```

Changes needed outside the RTL:
- a board DTS variant with the UART's interrupt renumbered (F6);
- `&i2c0 { status = "okay"; }`;
- `MEM_PORT_CONTRACT` stays untouched, since no memory port changes.

**LUT cost.**

| | LUT | FF | Kind |
|---|---|---|---|
| `TLI2C` itself | 116–117 | 119 | **measured**, hierarchical, in two Arty-200T riskybird builds (`rb_utilization_hier*.txt`, xc7a200t, same 7-series fabric) |
| pbus coupler to it (fragmenter + buffer) | 69–72 | 33 | **measured**, same reports |
| In-context delta on micrgb | **~350–700** | ~180–250 | **estimate**, by analogy with the RGB GPIO: 30 LUT hierarchical but **+634** in context, because the crossbar port and PLIC growth dominate (`RGB_LEDS.md` §7). The I²C adds 1 interrupt rather than 6 and has no chopper, so the low end is more likely. Also +2 IOB, 0 DSP, 0 BRAM |

Headroom: micrgb has 17,842 LUT free (**2.0–3.9 %** of that) and roccmoon 14,367 (**2.4–4.9 %**).
Timing risk is low: the TLI2C is a small synchronous block on the pbus clock.

**Recommendation: do not add I²C to the base tutorial bitstream as its own variant.**
- The LUT cost is small. The real cost is a new MAGIC, which triggers the md5 re-validation of
  every lab that gates on micrgb (`bitstream_id.sh` `BIT_ACCEPTED`), plus a PLIC renumbering
  that touches every board DTS those labs use.
- `0x5A5A001F` is already reserved for the camera on micrgb, and its I²C is identical. So the
  OLED gets a non-roccmoon home at no extra cost, and it works whether or not a camera is
  plugged into the FPC (the shield powers the PCA9306 from 3V3 either way).
- Revisit only if a base lab that must run without the shield needs I²C.

---

## 4. Does any RTL beyond the TLI2C help?

Quantified first. All numbers here are **estimates**; the RTL sim will replace the per-byte
cost with simulated cycles (§7).

One full refresh through `ssd1306.c` + CFB is one command write of 8 bytes (column and page
window, addressing mode) and one GDDRAM write of 128×64/8 = **1,024 bytes**. With the control
bytes and address bytes that is 1,036 bytes on the wire, each 9 SCL periods. On top of that come
START/STOP and a per-byte software gap: the driver polls TIP, then writes TX and CMD, then the
bit FSM waits for its next clock-enable. That gap is estimated at 100–400 cycles.

| Setting | Cycles per byte (P1 + gap) | One refresh | Max refresh rate | Hart cost at 1 Hz | at 5 Hz |
|---|---|---|---|---|---|
| 100 kHz (prescale 67) | 9·306 + ~150 ≈ 2,900 | ≈ 3.0 M cycles ≈ **87 ms** | ≈ 11 /s | 8.7 % | 44 % |
| 400 kHz (prescale 16) | 9·80 + ~170 ≈ 890 | ≈ 0.92 M cycles ≈ **27 ms** | ≈ 37 /s | 2.7 % | 13 % |

**Measured in RTL** (§7.3, the window command plus the 1,024-byte write, with an 8-cycle
cost per MMIO access): **2,924,884 cycles = 84.8 ms** at prescale 67 and **785,133 cycles =
22.8 ms** at prescale 16. The estimates above were 3 % and 16 % high. At the recommended
1 Hz and 100 kHz the screen costs **8.5 % of one hart**, taken from idle time.

"Hart cost" is 100 % of one hart for the duration of a refresh, because the driver busy-polls.

**Recommendation: not needed.** The status screen needs about 1–2 refreshes per second. The
refresh runs from a preemptible thread at the lowest application priority (§5.4). On Zephyr's
preemptive scheduler, busy-polling at that priority consumes idle time, not inference time:
inference threads preempt it at the next tick or interrupt.

Capture is unaffected either way, because the frame path is DMA. The only coupling left is the
bus itself. A camera AE write that arrives mid-refresh waits for at most one refresh (87 / 27 ms),
and priority inheritance on the application's bus mutex bounds that wait to exactly one transfer.

**What a streamer would cost.** An "I²C DMA" (TL master or 1 KB buffer + FSM that clocks a
frame out and interrupts once) would remove the busy-poll. It would also bring a new crossbar
port, an interrupt, a driver, a MAGIC and a re-validation, for an estimated ~400–800 LUT by the
same analogy as §3.

The cheaper software levers come first:
- a lower refresh rate;
- 400 kHz if the P1 measurement allows it;
- partial page updates: a counter-only change is 1 page of 8, 128 bytes, 8× less. That would
  need rendering outside CFB, because `cfb_framebuffer_finalize()` always writes the whole buffer.

An interrupt-driven `i2c_sifive` would not pay off at 400 kHz either: at an estimated
~1,000–3,000 cycles, the per-byte interrupt and context switch is as long as the ~890-cycle byte.

---

## 5. The Zephyr side

### 5.1 Drivers, bindings, Kconfig — what fits as-is

- **`sifive,i2c0`** (`dts/bindings/i2c/sifive,i2c0.yaml`): `reg` required, `clock-frequency` from
  `i2c-controller.yaml`. The node exists, disabled, in `chipyard-riscv.dtsi`. That file is
  included by every `boards/chipyard/pynqz1*` DTS through `chipyard-riscv64.dtsi`. Its
  `interrupts = <52 1>` is wrong for these SoCs but is never connected by the polled driver.
  `CONFIG_I2C_SIFIVE` is default-y once the node is okay.
- **`solomon,ssd1306fb`** (`solomon,ssd1306fb-{common,i2c}.yaml`): the required properties for a
  128×64 panel are width 128, height 64, `segment-offset` 0, `page-offset` 0, `display-offset` 0,
  `multiplex-ratio` 63, `prechargep` 0x22, plus `segment-remap` and `com-invdir` for the usual
  module orientation. There is no `reset-gpios` (the module has no RES pin). `CONFIG_SSD1306`
  is default-y from the node and selects `I2C`.
- **CFB** (`CONFIG_CHARACTER_FRAMEBUFFER`): the smallest stock font is 10×16, which gives 4 rows
  of 12 characters. That is too few for five status lines, so the sample ships a 6×8 font
  converted from X11 `misc-fixed` 5x7, which is public domain. It turns the stock fonts off
  (`CONFIG_CHARACTER_FRAMEBUFFER_USE_DEFAULT_FONTS=n`, which saves their ~13.8 KB of glyphs).

### 5.2 The init sequence against the datasheet (to be asserted by the host test)

`ssd1306_init_device()` sends, all under `0x00` (commands):

| # | Bytes | Meaning | Datasheet |
|---|---|---|---|
| 1 | `AE` | display off | init flow starts with the panel off |
| 2 | `D5 80 D9 22 DB 20` | clock div/osc = 0x80; precharge = 0x22; VCOMH deselect = 0x20 | reset values / recommended |
| 3 | `40 D3 00 DA 12 A8 3F` | start line 0; offset 0; COM pins *alternative* (0x12, correct for 128×64); mux 64 | recommended flow (the flow chart shows `DA 02`; 0x12 is the 128×64 panel value) |
| 4 | `A1 C8` | segment remap; COM scan flipped | module orientation |
| 5 | `8D 14 33` | **charge pump enable**, then `33` | **`8D 14` before `AF`** (app note: charge pump must be enabled before display on). `33` is the SH1106 "pump voltage 9.0 V" code and unassigned in the SSD1306 command table; harmless if ignored — to be watched on the real module |
| 6 | `A4 A6` | resume from RAM; normal (non-inverted) | |
| 7 | `81 80` | contrast = `CONFIG_SSD1306_DEFAULT_CONTRAST` (128) | |
| 8 | `AF` | **display on, last** | |

The addressing mode is not set at init. Every `display_write()` sends
`20 00 21 x0 x1 22 p0 p1` first: horizontal addressing mode, column window, page window. The
data write then follows under `0x40`.

### 5.3 Graceful degradation

The sample marks both candidate nodes (0x3C and 0x3D) `zephyr,deferred-init`. The OLED is
therefore never probed in the boot path. With the stock driver's unbounded TIP wait (F2), a
wedged bus during `POST_KERNEL` would hang boot before `main()`.

A lowest-priority thread probes each address with one NOP command (`00 E3`). It calls
`device_init()` on the one that ACKs and logs "not fitted" once if neither does. It never
touches the bus again after a failure.

### 5.4 Bus sharing rule

`i2c_sifive` has no lock, so **every user of `i2c0` in one image takes the application's bus
mutex around each transfer.** `samples/oled_status` exposes it as `oled_status_bus_lock()` and
`oled_status_bus_unlock()`, and the camera code in the same image must use the same pair.

A `k_mutex` gives priority inheritance. It also puts an upper bound on a camera write's wait:
one OLED transfer (§4).

---

## 6. Predictions (committed before any simulation or run)

### P1 — SCL timing of the generated TLI2C (finding F5)

**Reading of the RTL.** In OpenCores `i2c_master_bit_ctrl.v`, `scl_oen = 1` means "released".
The generated `TLI2C.sv` has `port.scl.oe = ~sclOen`, and uses `oe` where OpenCores used `oen`:

```verilog
_GEN_3   = cnt == 16'h0 | ~control_coreEn | dSCL & ~sSCL & ~sclOen;   // OpenCores: dSCL & ~sSCL &  scl_oen
slaveWait <= ~sclOen & ~dSCLOen & ~sSCL | slaveWait & ~sSCL;          // OpenCores: scl_oen & ~dscl_oen & ~sSCL | ...
dSCLOen  <= ~sclOen;                                                   // OpenCores: dscl_oen <= scl_oen
```

So the clock-synchronisation reload fires on **every falling SCL edge the master makes
itself**, once the edge has passed the input filter. The filter samples every `F =
(prescale >> 2) + 1` cycles and takes a majority of 3. The reload then starts the next
clock-enable period early. A bit still has 5 phases of `prescale + 1` cycles (idle, a: low,
b: high, c: high, d: low). The phase after d, however, is cut to `d₀ + F + 4` cycles, where
`d₀` is the filter phase. `d₀` is the same for every bit after the first:
`d₀ = (−4 − 4·(prescale+1)) mod F`.

Separately, `slaveWait` only asserts when the master *starts* pulling SCL low while SCL is
already low. A target that stretches the clock is not waited for, and a bus held low from
outside freezes the FSM with TIP set.

**Prediction, simulated with a zero-delay pad model** (the target model computes
`scl_in = ~scl_oe & ~target_holds_scl`). Numbers are for bits 2–9 of each byte; bit 1 carries
the software gap.

| `clock-frequency` | prescale | F | d₀ | SCL period | t<sub>HIGH</sub> | t<sub>LOW</sub> | at 34,482,761 Hz |
|---|---|---|---|---|---|---|---|
| 100000 | 67 | 17 | 13 | **306 cycles** | 136 | 170 | **112.69 kHz**; t<sub>HIGH</sub> 3.944 µs, t<sub>LOW</sub> 4.930 µs |
| 400000 | 16 | 5 | 3 | **80 cycles** | 34 | 46 | **431.03 kHz**; t<sub>HIGH</sub> 0.986 µs, t<sub>LOW</sub> 1.334 µs |

- **Exact in a zero-delay simulation.** Falsified if the within-byte period differs by more
  than 1 cycle. In particular, `5·(prescale+1)` = 340 / 85 cycles would mean the OpenCores
  behaviour and a wrong reading.
- **On hardware**, every cycle of delay between the pad and `i2c_0_scl_in` adds one cycle to
  t<sub>LOW</sub> and the period, for example a synchroniser. SCL rise time does not, since only falling
  edges reload.
- **If confirmed, against the I²C spec.**
  - 100 kHz setting: f = 112.7 kHz exceeds Standard-mode's 100 kHz; t<sub>HIGH</sub> 3.944 µs is just
    under the 4.0 µs minimum; t<sub>LOW</sub> 4.93 µs is over 4.7 µs.
  - 400 kHz setting: 431 kHz exceeds Fast-mode's 400 kHz by 7.8 %; t<sub>LOW</sub> 1.334 µs ≥ 1.3 µs;
    t<sub>HIGH</sub> 0.986 µs ≥ 0.6 µs.
  - Why the 200T would not have noticed: every per-phase minimum a target samples against is
    met or missed by ≤ 1.4 %, and none of those sensors stretches the clock.
  - Per the coordinator, F5 is dropped unless the measured frequency is really out of spec.
    If it is, the report gives the measured period against prescale and whether a
    software-chosen prescale brings 100 / 400 kHz back inside every limit.
- **Clock stretching** (secondary): a target model that holds SCL low for 5 ms after the
  master releases it during a data bit. Predicted: the master does not wait, and the byte is
  corrupted as seen by the target.

### P2 — how `i2c_burst_write` looks on the wire with the stock driver (finding F1)

`i2c_burst_write(i2c0, 0x3C, 0x00, {AE}, 1)`, as `ssd1306_suspend()` issues it, is predicted to
appear as **`S 78 A 00 A Sr 78 A AE A P`**: two address phases, with the payload separated
from its control byte by a repeated START.

The SSD1306 model therefore takes the first byte after each Sr as a control byte, and the
init sequence and every GDDRAM write are misparsed. The rendered framebuffer is predicted
**not** to match the host golden of §7.

Falsified if the simulation shows one START followed by the contiguous bytes `78 00 AE P`. In
that case F1 is refuted, whatever the source reading says.

### P3 — the host golden

Rendered through the same `oled_status` code, a screen gives the same 128×64 image in two
places: the host emulation, whose I²C controller honours the API contract, and the RTL
simulation, whose PGM comes from its SSD1306 model. This holds provided P2 is falsified, or a
stack that sends one transfer is used. The golden is the sha256 of the PGM, committed in
`expected/oled_status.json`; the image itself is not committed.

---

## 7. Verification and results

Every number here is **simulated** (Verilator, cycle-accurate) or **derived** from a
simulated one. Nothing has run on the board.

### 7.1 Host tests — `scripts/54_oled_host_tests.sh`

`samples/oled_status/tests/host` on `native_sim/native/64`: the stock `ssd1306.c` and CFB
plus `src/oled_status.c`, over Zephyr's I²C emulator, into `model/ssd1306_model.c`
(a behavioural SSD1306: control-byte framing, the command set, GDDRAM with all three
addressing modes). **6 of 6 pass, and 1 of 1 in the "not fitted" build.**

- **The init sequence is byte-exact** against the list in §5.2, and against the datasheet
  ordering asserted separately: `8D 14` before `AF`, `AF` last, the panel off first, COM
  pins 0x12, mux 63, no control byte with stray bits, exactly one unassigned code (the
  `33` after the charge-pump pair). The whole wire log is the golden `init_wire` in
  `expected/oled_status.json`.
- **The screens render to committed hashes.** `status.pgm` and `pattern.pgm` (128×64 PGM of
  the model's GDDRAM) are hashed against `expected/oled_status.json`; the images live in
  `out/oled_host/`, not in git.
- **The addressing-mode window** `20 00 21 00 7F 22 00 07` precedes exactly 1,024 data bytes.
- **The bar helper** is checked at 0 %, 25 %, 100 % and over-range, for outline, 1-pixel
  gap, fill width and nothing drawn outside it.
- **Posting never blocks:** 1,000 `oled_status_post()` calls while the test holds the bus
  lock take 0 ticks.
- **Not fitted:** with neither address ACKing, the thread logs once, ends in `ABSENT`, and
  the bus sees exactly two probe transfers and nothing after them.
- **Negative control:** the same screen pushed through a wire model of the stock
  `i2c_sifive` reading does **not** hash to the golden, so the golden can detect that
  failure.

**Footprint on `chipyard_pynqz1_micrgb`** (from the linker map; these boards run from DDR,
so "image" is what `zephyr.bin` carries):

| component | code+const | bss | image | memory |
|---|---|---|---|---|
| `i2c_sifive` | 927 | 0 | 939 | 939 |
| `ssd1306.c` | 2,209 | 8 | 2,209 | 2,217 |
| CFB | 3,176 | 48 | 3,176 | 3,224 |
| `oled_status.c` (+2 KB thread stack) | 2,886 | 2,435 | 2,886 | 5,321 |
| 5×8 font | 491 | 0 | 491 | 491 |
| heap (CFB's 1 KB buffer needs `k_malloc`) | 1,192 | 2,072 | 1,192 | 3,264 |
| demo `main.c` | 2,363 | 0 | 2,363 | 2,363 |
| **whole image against `hello_world`** | **+13,672** | **+2,523** | **+13,684** | **+16,207** |

`zephyr.bin` 52,072 bytes against 38,820. The display stack without the demo is **10.9 KB of
code and 4.6 KB of RAM**; on the camera image, which already links `i2c_sifive`, the OLED
adds about **10.0 KB of code**. Turning the stock CFB fonts off saves their ~13.8 KB, which
is why the 5×8 font is generated (`tools/gen_font5x8.py`, X11 misc-fixed, public domain).

### 7.2 P2 — what `i2c_burst_write()` puts on the wire: **CONFIRMED**

`scripts/55_oled_rtl_sim.sh --tli2c` verilates a **copy** of the generated `TLI2C.sv`
(plus `TLMonitor`, the interrupt crossing and `plusarg_reader`) and drives it with Zephyr's
`drivers/i2c/i2c_sifive.c` **compiled unmodified** (md5 `d811ec54`, fork commit `d79a7fcccb1`)
against host stubs, one TileLink-UL register access per `sys_read8`/`sys_write8`. A
bit-level target (`sim/i2c_target.c`) feeds the same SSD1306 model as the host test, so the
framebuffer is comparable with the host golden. Nothing is written into the Chipyard tree.

A whole screen — the probe, the init bursts of §5.2, the window, 1,024 GDDRAM bytes — sent
the way `ssd1306.c` sends it, against the same bytes sent one message per transfer:

| shape | STARTs | repeated STARTs | control bytes misparsed | GDDRAM bytes | rc | image |
|---|---|---|---|---|---|---|
| `i2c_burst_write` (what `ssd1306.c` does) | 11 | **10** | **11** | **9 of 1,024** | all 0 | **≠ golden** |
| one message per transfer | 11 | 0 | 0 | 1,024 | all 0 | **= golden** |

The first transfers on the wire say it plainly:
`S 78+ 00+ E3+ P | S 78+ 00+ Sr 78+ AE+ P | S 78+ 00+ Sr 78+ D5+ 80+ ... P`.
Every byte is ACKed and every call returns 0, so **this failure is silent**: a screen of
noise, no error anywhere. Identical at 100 kHz and 400 kHz.

With the fix of §8 in, the same `i2c_burst_write` path gives 11 STARTs, **0** repeated
STARTs, 1,024 GDDRAM bytes and **= golden** at both speeds. That was first measured on a
candidate file and then re-measured with the patch applied to the tree
(`i2c_sifive.c` md5 `b5e0725a`), where the wire now reads
`S 78+ 00+ E3+ P | S 78+ 00+ AE+ P | S 78+ 00+ D5+ 80+ D9+ 22+ DB+ 20+ P`.

Why the 200T stack never hit it: no I²C code there calls a burst API — the riskybird
samples, the in-tree BMI08x and VL53L1X drivers and the camera agent's HM01B0 driver all use
single-buffer `i2c_write()`/`i2c_write_read()`, which this driver already handles correctly.

### 7.3 P1 — SCL timing: **CONFIRMED**, and what it means

Within-byte SCL periods (8,632 samples per phase, zero-delay pad model):

| `clock-frequency` | prescale | predicted | **measured** | t<sub>HIGH</sub> | t<sub>LOW</sub> | SCL |
|---|---|---|---|---|---|---|
| 100000 | 67 | 306 | **306..306, mean 306.000** | 136 (3.944 µs) | 170 (4.930 µs) | **112.69 kHz** |
| 400000 | 16 | 80 | **79..81, mean 80.08** | 34 (0.986 µs) | 45..47 (1.305..1.363 µs) | **430.6 kHz** |

The OpenCores formula's 340 and 85 cycles are **falsified**. The ±1-cycle tolerance of the
prediction holds at both settings; the stronger "exact in a zero-delay simulation" claim
holds at prescale 67 and **not** at prescale 16, where the filter phase does not settle to
one value (79/80/81, mode 80).

**Independently confirmed, twice.** The camera agent's full-SoC simulation of `0x5A5A001E`
measured the same **306 SoC cycles** in-byte at prescale 67, from a different testbench and a
different I²C model. And this test was re-run against `0x5A5A001E`'s **own** generated
collateral (`scripts/55_oled_rtl_sim.sh --tli2c --gensrc …RoccMoonCamConfig/gen-collateral`):
every number is identical, which is what the two files being byte-identical but for the
monitor's instance name implies.

**Which part of the mechanism is confirmed.** The predicted period is
`4·(prescale+1) + F + 4 + d₀`, where `F = (prescale>>2)+1` is the input filter's sampling
period: the master reloads its own clock divider early because `scl_sync` fires on the
master's *own* falling edge (the inverted reading), and the filter's delay sets *how* early.
The camera agent reads the shortfall as the filter alone. Two measurements separate them.

*1. The shortfall scales with the prescale.* The divider was programmed directly (the driver
offers only two values) and one byte sent at each setting:

| prescale | OpenCores `5·(p+1)` | early-reload model | **measured** | shortfall |
|---|---|---|---|---|
| 8 | 45 | 45 | **45..45, mean 45.00** | 0.00 (0 %) |
| 16 | 85 | 80 | **79..81, mean 80.03** | 4.97 (5.8 %) |
| 32 | 165 | 153 | **147..153, mean 152.44** | 12.56 (7.6 %) |
| 67 | 340 | 306 | **306..306, mean 306.00** | 34.00 (10.0 %) |
| 100 | 505 | 442 | **442..445, mean 442.28** | 62.72 (12.4 %) |
| 200 | 1005 | 867 | **867..867, mean 867.00** | 138.00 (13.7 %) |

The model predicts all six points inside the ±1-cycle jitter. A filter that only delayed the
master's *view* of SCL, with the divider free-running, would leave the period at `5·(p+1)`
at every prescale — a shortfall of 0, which is what prescale 8 happens to give and no other
setting does. So **the early reload is confirmed, and the filter delay is the term that sets
its size.** The shortfall fraction is not a constant 13 %: it is 5.8 % at prescale 16 and
10.0 % at prescale 67, which is why the 400 kHz setting measures 430.6 kHz and not ~450.

*2. Clock stretching is not honoured.* With the target holding SCL low from the falling edge
that ends a bit, the master does not wait for the release: it truncates its own high phase by
exactly the overlap (t<sub>HIGH</sub> normally 136 cycles):

| hold | 130 | 140 | 200 | 250 | 300 | ≥ 350 |
|---|---|---|---|---|---|---|
| shortest t<sub>HIGH</sub> seen | 136 | 136 | **105** | **55** | **5** | wedged |
| data decoded | ok | ok | ok | ok | — | — |

A compliant master would have waited and still produced a full t<sub>HIGH</sub>. From a hold of
300 cycles (8.7 µs) the controller wedges, which is the same inverted pair seen from the
`slave_wait` side: the master starts driving SCL low while SCL is *already* low, latches
`slaveWait`, and then holds the line low itself forever. §7.4 has the recovery.

Against the specs, and why this is not a defect to fix:

- 112.69 kHz exceeds Standard mode's 100 kHz, and t<sub>HIGH</sub> 3.944 µs is 1.4 % under the 4.0 µs
  minimum. Both parts on this bus are rated to 400 kHz (SSD1306 t<sub>cycle</sub> ≥ 2.5 µs; HM01B0
  400 kHz), so **every device limit is met with wide margin** at the 100 kHz setting.
- 430.6 kHz exceeds Fast mode's 400 kHz by 7.6 %. t<sub>LOW</sub>'s smallest sample, 1.305 µs, clears
  the 1.3 µs minimum by 0.4 % — no margin worth having.
- There is no intermediate setting: `i2c_map_dt_bitrate()` quantises, and a request for
  344,830 Hz was measured coming out as prescale 67.

**Recommendation: leave `clock-frequency = <100000>`** — the value `chipyard_pynqz1_cam`
already sets. It is one prescaler for both devices, it keeps every part inside its own
limits, and §4's refresh budget is met (84.8 ms per screen, 8.5 % of a hart at 1 Hz, against
a 1 Hz status screen). Landing inside Fast mode would need a driver change (a prescale
computed for this RTL, or an explicit prescale property), not an RTL change, and 400 kHz
would buy only 62 ms per refresh that nothing needs.

### 7.4 The other RTL cases

- **No ACK.** A write to 0x3D with nothing there returns −EIO. The controller is left with
  **SCL driven low** and SDA released (no STOP after a NACK), and the next transfer to 0x3C
  succeeds. So probing costs nothing but leaves the bus clamped until the next START.
- **Clock stretching** (100 kHz, the target holds SCL low from the falling edge that ends
  bit 4 of a byte): holds up to **250 cycles (7.2 µs)** are absorbed and the data still
  arrives correctly; from **300 cycles (8.7 µs)** the controller **wedges** — TIP stays set,
  SCL stays driven low, and the driver never returns (50 ms budget, tested to 1 ms of hold).
  `i2c_sifive_configure()` — control = 0, prescale, control = EN — **recovers it**: the next
  transfer then works. Neither the SSD1306 nor the HM01B0 stretches, so nothing on this bus
  can trigger it; a future stretching target on this bus would need the driver to time out
  and reconfigure.
- **SCL held low from outside for 50 ms:** the driver spins through 191,570 register polls
  and never returns; after release, reconfigure plus a transfer works. This is F2's
  unbounded wait, and the reason the OLED nodes are `zephyr,deferred-init` (§5.3): on a
  wedged bus the stock driver would otherwise hang `POST_KERNEL`, before `main()`.

### 7.5 The Zephyr sample in `0x5A5A001E`'s TestHarness

`scripts/55_oled_rtl_sim.sh --soc` runs the whole thing: **the Zephyr sample**, on the camera
build's own SoC, with this SSD1306 model beside the camera's sensor model.

- The elaboration is **copied** into `out/oled_soc_sim/gensrc` and the copy's file lists are
  rewritten to point into it; the Chipyard tree is only read, and the camera agent's
  `hm01b0_sim_model.v` and its harness are not touched.
- `TestHarness.sv` is patched **in the copy**: `sim/soc/oled_i2c_target.sv` (a Verilog shell
  over `sim/i2c_target.c` and `model/ssd1306_model.c` through DPI, clocked on the SoC clock)
  is instantiated on the I²C lines, and what ChipTop sees becomes the camera model's drive
  ANDed with this target's — the wired-AND the two pull-ups give on the board. No harness
  binder was needed, so none was proposed.
- The guest is `samples/oled_status` for `chipyard_pynqz1_cam` with `oled.overlay`, built with
  `CONFIG_OLED_DEMO_GOLDEN=y` so it draws exactly the screen §7.1 hashed, and with
  `sim/soc/htif_console.overlay`: the harness's UART adapter is clocked for the generated
  DTS's 500 MHz peripheral bus while the guest computes its divisor from the board's
  34.483 MHz, so HTIF is the simulator's console.
- Two runs: one with the model answering at 0x3C, one with `OLED_SIM_PRESENT=0` where nothing
  answers — the "not fitted" path, end to end, in the real SoC.
- Two things in the guest are simulation-shaped, and both are guarded: golden mode polls every
  1 ms rather than 10, and ends the simulation through HTIF's `tohost` the way the bare-metal
  samples do. The refresh rate limit is set to 1 ms for the run as well. A second of guest
  time is 500 M simulated cycles, so the board's 1 s refresh period would take hours here.

**Result: PASS.** The guest booted, probed, initialised the panel, drew the status screen and
then the test pattern, and what the model received matches the host goldens exactly.

| | |
|---|---|
| console | `OLED_DEMO: start`, `oled: ready at 0x3c`, `OLED_GOLDEN: status screen drawn=1`, `pattern drawn=2`, `state=READY addr=0x3c drawn=2 late_max_ms=0`, `done` |
| on the wire | 13 STARTs, **0 repeated STARTs**, 13 STOPs, 41 command bytes, **2,048 GDDRAM bytes**, 0 misparsed control bytes, 1 unassigned command (the `33`) |
| init sequence | **byte-identical** to `expected/oled_status.json`'s `init_wire` |
| panel state | display on, charge pump on, horizontal addressing |
| **images** | the model's framebuffer hashes to the **pattern** golden; replaying the wire log's first data transfer gives the **status** golden, `310205095ce3…` — both exactly as the host test rendered them |
| SCL, within a byte | **306..306 cycles, mean 306.000** (16,920 samples), t<sub>HIGH</sub> 136, t<sub>LOW</sub> 170 — the same as §7.3 and as the camera agent's own run, now with the real driver on the real SoC |
| one refresh on the wire | **2,910,434 SoC cycles** (84.4 ms at 34.4828 MHz) |
| **hart 0's cost of a refresh** | render **102,279** cycles (status screen; 50,815 for the pattern), I²C transfer **2,956,821** cycles |

The hart figures are the measured counterpart to §4's estimate: **3.06 M cycles per status
refresh, of which 96.7 % is the driver's busy-poll** and 3.3 % is CFB drawing the screen. At
one refresh a second that is 8.9 % of one hart, taken out of idle time at the lowest
application priority — and the loop that posts the values was never late (`late_max_ms=0`).
Only the busy-poll part is what an I²C DMA (§4) could remove.

**Not fitted, in the same SoC:** with nothing answering, the two probes NACK (0 address ACKs,
2 NACKs), the guest logs "not fitted" once, draws nothing, touches the bus no more (0 data
bytes) and runs on to `OLED_DEMO: done` with `state=ABSENT`. The probe pair also shows §7.4's
NACK behaviour from the other side: no STOP after a NACK, so the second probe arrives as a
repeated START.

Two practical notes for whoever runs this next. The guest's `tohost` write does end the
bare-metal samples' simulations but did not end this one, so the model dumps its framebuffer
after every completed frame and on SIGTERM; and DRAMSim2 is off by default here
(`SIM_DRAMSIM=1` turns it on), since this test is about the I²C bus.

### 7.6 On the board, first: Lab B28 with no display fitted

Run 2026-09-17 12:55 PDT on the bench PYNQ-Z1, one session through `scripts/with_board.sh`:
the lab, `archive/tools/archive_run.py rocket_oled`, then the Lab 35 health check, in that
order. Bitstream `0x5A5A001E`, md5 `659c6db6`, the build Lab B27 already accepted; FCLK0 read
back at 34.4828 MHz; the guest is `samples/oled_status` on `chipyard_pynqz1_cam` with
`clock-frequency = 100000` and `patches/0120` in the image (the lab refuses without either).

```
OLED_DEMO: start
oled: no ACK at 0x3c/0x3d, not fitted (addr 0x00, err -5) -- display disabled, capture and inference unaffected
OLED_DEMO: state=ABSENT addr=0x00 frames=450 drawn=0 late_max_ms=0 render_cycles=0 xfer_cycles=0
OLED_DEMO: done
```

**Verdict PASS**, and what that is worth is narrow, so it is worth stating plainly:

- **What this proves.** On real silicon, with a real TLI2C on P15/P16 and no target on the bus,
  the probe NACKs, `oled_status` logs it **once**, ends in `ABSENT`, draws nothing and touches
  the bus no more; the 450-frame 30 fps loop ran with `late_max_ms = 0`; the guest reached
  `done`; and the lab's absent path — including its verdict logic, `run.json`, the snapshot and
  the Lab 35 health check afterwards — works end to end. The Lab 35 check reproduced its golden
  run, so the board was left healthy.
- **What it cannot prove.** Nothing about a working display. The module plugs into the shield's
  J4 and **the shield has not arrived** (ordered 2026-09-15), so no ACK was possible and no
  pixel was drawn. Every claim about the image rests on §7.1, §7.2 and §7.5 — the host golden,
  the TLI2C RTL test and the full-SoC run — not on this session.
- `out/rocket_oled/run.json` → `archive/runs/rocket_oled/`.

Then the module arrived. §7.7.

### 7.7 On the board, with the display fitted — it works

A 0.96" SSD1306 was fitted to the shield's J4 and Lab B28 ran twice on 2026-09-17, on
`0x5A5A001E` md5 `659c6db6`, FCLK0 34.4828 MHz, `clock-frequency = 100000`, `patches/0120` in
the image.

| | run 1, 14:08 | run 2, 14:24 |
|---|---|---|
| demo | 450 frames, 5,000 ms pattern, 1 s refresh | 3,600 frames, **30,000 ms** pattern, 1 s refresh |
| console | `oled: ready at 0x3c`, `state=READY` | `oled: ready at 0x3c`, `state=READY` |
| screens drawn | 16 | 111 |
| `late_max_ms` | **0** | **0** |
| render / transfer cycles | 166,759 / 2,942,127 | 87,800 / 2,930,786 |
| verdict as scored then | PASS | **FAIL — wrong, see §7.7.1** |
| verdict re-scored | PASS | **PASS** |
| **what a person saw** | the text and the bars half filled; the frame counter reaching 450 and fps pinned at 30.30. The full animation was **not** seen — which is why run 2 was made with a longer pattern | the landing page, then the bars and the classifications: **"looks good"** |

**The human observation is the primary evidence here**, exactly as for the RGB LEDs
(`RGB_LEDS.md` §6): no readback exists for glass. What the machine can add, and did, is that
every byte was ACKed (any NACK ends the sample with one line and `state=FAILED`), that the
screens were drawn, and that the 30 fps loop was never late in either run — the display cost
the loop nothing.

Two separate claims live here, and they are worth keeping apart:

- **Simulation against silicon.** The transfer cost measured on the board, 2.93–2.94 M cycles,
  is within 1 % of the 2,956,821 cycles the full-SoC simulation predicted (§7.5). That is a
  cross-check of **the model and the hardware against each other**, and a good one. The render
  cost differs between the two runs only because the screens differ — a longer label and a
  fuller bar draw more pixels.
- **The lab's verdict.** Nothing above bears on it. Run 2's `FAIL` was wrong for reasons
  entirely inside the scorer (§7.7.1), and no amount of agreement between the simulation and
  the silicon upstream of it would have caught that. A verdict is only as good as the
  arithmetic in the harness that computes it.

Raw runs: `archive/runs/rocket_oled@20260917T1409/`, `archive/runs/rocket_oled@20260917T1427/`.

#### 7.7.1 The FAIL that was a number shaped like a result

Run 2's `run.json` says `verdict FAIL`. **The display was working while it said so**, in front
of a witness. Two defects in `scripts/56_rocket_oled_board.sh` produced it, and the second is
worse than the first:

1. **The expected-screens arithmetic ignored the pattern window and the cost of a refresh.**
   It demanded `frames × 33 / period − 1` screens — 117 — from a run that spent its first
   30 s showing the test pattern (during which no status screen is posted) and whose refresh
   cycle is `period + ~88 ms`, not `period`. The window can hold **109**; 111 were drawn. Any
   run with a long `--pattern-ms` failed by construction. Fixed: the floor is now computed
   from the frame-loop duration and **this run's own measured refresh cost**, with a 20 %
   margin, and `refresh_ms_measured` and `screens_ideal` are recorded in `run.json`.
2. **On FAIL the script exited before its own snapshot.** `lib/common.sh` sets `-e` and
   `pipefail`, so the failing scorer pipeline killed the script at step 4 — before
   `archive_run.py` and before the Lab 35 health check. **The runs most worth keeping were
   exactly the ones that kept no evidence.** Run 2 survived only because nothing had rerun the
   lab in the two and a half hours before the coordinator copied `out/rocket_oled/` out by
   hand. Fixed: the snapshot and the health check are now unconditional and run before the
   exit status is used; the scorer is written to the run directory as `score.py` and archived
   with the run, so how a verdict was computed travels with the evidence.

Re-scored with the corrected arithmetic (`run_rescored_20260917T1710.json` beside each run,
originals untouched): run 1 expects ≥ 10 against 13.6 ideal and drew 16; run 2 expects ≥ 87
against 109.2 ideal and drew 111. **Both PASS.**

**Both fixes are exercised, including the half that only runs when something fails.** The
arithmetic fix is exercised against the two real runs (re-scored above). The
unconditional-snapshot fix only executes on a failing path, so `scripts/56_rocket_oled_board.sh
--selftest fail` runs steps 4–6 offline against the 14:27 run's own console with the snapshot
and health check stubbed, forces the verdict to FAIL, and asserts that both still ran and that
the run directory is complete; `--selftest pass` does the same for the passing path. An
untested scorer is what produced this in the first place.

The reason this is written down at length, rather than quietly fixed: a stored `FAIL` reads to
every later reader as a property of the hardware. "The long-pattern case does not work on the
board" was one lab run away from being the record, and the only thing standing against it was a
sentence in a chat log. A verdict is a claim about the harness as much as about the thing it
measures, and evidence collection must never be conditional on it — which is now a rule for
every lab here, not just this one (`docs/EXPERIMENT_LOG_RULES.md`).


---

## 8. The Zephyr fix, and what was not done

1. **`patches/0120-zephyr-i2c-sifive-msg-concat.patch` — APPLIED** (coordinator's approval,
   2026-09-17). One address phase per transfer instead of one per message: emitted on the
   first message, after a STOP, on `I2C_MSG_RESTART`, or on a change of direction — the rule
   `drivers/i2c/i2c_bitbang.c` and `drivers/i2c/i2c_dw.c` implement. The read path's
   last-byte NACK moves with it, so a read continued by a following fragment is still
   acknowledged. `scripts/06_patch_zephyr.sh` applies it (with a marker of its own) and
   `scripts/02_verify_patches.sh` covers it: the zephyr tree reconstructs exactly as
   base + 0003 + 0011 + 0120.
   **Effect on the camera:** none. Single-buffer `i2c_write()` and `i2c_write_read()` — the
   only two shapes `sw/cam/ospi_cam.c` uses — take the same path as before, because the
   first message always gets an address phase and a following read always differs in
   direction. The camera agent re-runs its I²C simulation checks against that prediction.

2. **The fallback, if 0120 ever has to be dropped.** Give the sample its own small display
   driver (~200 lines, `compatible = "iiswc,ssd1306-i2c"`) that writes one page per
   transfer: a 129-byte buffer with the `0x40` control byte prepended, so every transfer is
   a single message and the stock `i2c_sifive` handles it correctly. CFB and the panel
   properties stay as they are, only the `compatible` in the overlay changes. It costs a
   driver we own instead of one Zephyr maintains, and it has one advantage: writing a page
   at a time also makes **partial updates** possible (a changed counter is 1 page of 8,
   §4), which `cfb_framebuffer_finalize()` cannot do.

3. **I²C on the builds without a camera** — §3: config fragment, `PYNQZ2_HAS_I2C` top-level
   block, `src/pynqz2_i2c.xdc`. **Proposals only, nothing applied**; the recommendation is
   not to add a separate variant.

4. **No new RTL block** — §4.

### 8.1 Note for upstream (not filed)

`drivers/i2c/i2c_sifive.c` violates the `i2c_msg` contract in `include/zephyr/drivers/i2c.h`:
"Some drivers will merge adjacent fragments into a single transaction using this flag"
(`I2C_MSG_RESTART`) — this driver instead emits START + address for **every** message, so
fragments that were meant to be one transaction become several, with a repeated START
between them.

- **Affected:** every user of `i2c_burst_write()`, `i2c_burst_read()`, `i2c_reg_write_byte()`
  and friends on a SiFive/OpenCores I²C controller. `drivers/display/ssd1306.c` is the one
  we hit: every command block and every framebuffer write goes out as two messages.
- **Symptom:** silent corruption. Each byte is ACKed and each call returns 0, but a target
  that parses its first byte after a START — an SSD1306's control byte, an EEPROM's address
  pointer — sees payload where that byte should be.
- **Reproduction without hardware:** `scripts/55_oled_rtl_sim.sh --tli2c` in this repo
  verilates the generated `TLI2C` (rocket-chip-blocks, the OpenCores `i2c_master`
  transcription) and drives it with the unmodified driver through host stubs. A 128×64
  SSD1306 screen sent with `i2c_burst_write()` puts 10 repeated STARTs on the wire and lands
  9 of 1,024 bytes in the GDDRAM, while every call returns 0. The same bytes as one message
  per transfer land all 1,024.
- **Fix:** `patches/0120-zephyr-i2c-sifive-msg-concat.patch` here, which follows
  `i2c_bitbang.c`'s rule. It is written against Zephyr 4.2.99 (`4329bf61c4f` in this fork)
  and touches only `i2c_sifive.c`.
- **Also worth reporting, and not fixed here:** the same driver's TIP wait has no timeout
  (`while (i2c_sifive_busy(dev)) {}`), so a target or a fault that holds SCL low hangs the
  calling thread for ever — measured in §7.4.

---

## 9. Fitting and running it, and what each failure means

**This has been done: the module was fitted to J4 and the screen ran on the board twice on
2026-09-17, both confirmed by eye (§7.7).** The section stays as a runbook because the next
person to fit one — a second board, a second module, the tutorial room — starts where we
started. §9.1's warning is not historical: it is the step that can still destroy a module.

### 9.1 Fit it to J4 — the one step that can destroy the module

0.96" SSD1306 boards ship in **two pin orders**: `GND VCC SCL SDA` and `VCC GND SCL SDA`. They
are the same four pins in a different order, and **a reversed supply kills the module**. There
is no way to tell by looking at the header alone.

The shield's own J4 order is **not recorded anywhere this repo can reach**. The pin map
(`archive/drafts/PINMAP_riskybirdv3_pynq_camera_rev0.6.md`) says only that the PL-side `SDA`
"also feeds the OLED row J4"; the shield's KiCad/schematic sources are not on this machine
(searched: every checkout on the build host and their git history). A module
that ACKed at 0x3C on this board on 2026-09-17 says the order on **that** J4 and **that**
module matched — it says nothing about the next module you pick up. So
**establish J4's order on the bench, with the board unpowered**, before plugging anything in:

1. Read the silkscreen next to J4, and read the module's own silkscreen. If they agree pin for
   pin, you are done.
2. If either is unlabelled, use a continuity meter from each J4 pin:
   - **GND** — continuity to any ground on the shield (J8's GND pins).
   - **VCC** — continuity to the shield's 3V3 net (J8's 3V3 pin). It must **not** be 5 V:
     nothing on this shield is, the Z1 is not 5 V tolerant on these pins, and the module's own
     regulator and charge pump run happily from 3.3 V.
   - **SCL** — continuity to the header's `SCL` pin (ball P16).
   - **SDA** — continuity to the header's `SDA` pin (ball P15).
3. If the two orders disagree, **use four jumper wires**, not the header. It costs nothing and
   it is the difference between a working module and a dead one.

Then fit the shield itself the way `PINMAP…rev0.6.md` describes (component side up, `A5` at the
corner nearest `IO0`'s row), and check it is not shifted by one position: the row that would sit
under `IO2` is `PUDC_B`, tied to 3V3.

### 9.2 Run the lab

```
scripts/with_board.sh ./scripts/56_rocket_oled_board.sh
```

It builds the guest for `chipyard_pynqz1_cam`, gates on MAGIC `0x5A5A001E` **and** the md5,
loads the PL, runs the demo, writes `out/rocket_oled/run.json`, snapshots the run with
`archive/tools/archive_run.py` and finishes with the Lab 35 health check in the same board
session. Useful flags: `--pattern-ms` (5,000 by default), `--frames` (450 at 33 ms), and
`--period-ms` (1,000 — the refresh rate limit).

### 9.3 First power-on: three things, in this order

All three were seen on 2026-09-17 (§7.7); this is the order to work through them in.

1. **The right machine.** MAGIC `0x5A5A001E`, the md5 gate passing, FCLK0 read back at
   34.4828 MHz. The lab refuses otherwise. A silent console is the **board definition**, not the
   display: this SoC's UART is PLIC source 2, not 1 (§2, F6).
2. **The bus answers.** `oled: ready at 0x3c` on the console — or `0x3d` if the module is
   strapped that way; the sample probes both and uses whichever ACKs. `oled: no ACK at
   0x3c/0x3d, not fitted` with a module plugged in means wiring, supply or address, and §9.5
   says which.
3. **The screen lights.** The test pattern comes first, for `--pattern-ms`; then the status
   screen, refreshed once a second.

### 9.4 What a good first screen looks like

If you want a longer look at the pattern than the default 5 s, pass `--pattern-ms 30000`: the
first live run was too quick for a person to take in the animation, which is why the second one
lengthened it.

The pattern: a one-pixel border all the way round, a checkerboard of 8×8 tiles in the right
third, `OLED TEST` and `128x64` at the top left, `ABCabc 0123` below them, and a half-filled bar.

Then the status screen — this is exactly the image the host test and both simulations hash
(§7.1, §7.5), with the demo's own numbers in place of the golden ones, and it is what the
person watching on 2026-09-17 described as the landing page followed by the bars and the
classifications:

```
0x5A5A001E roccmoon
frame 123456
fps   29.97
person               87%
[============        ]      <- confidence bar, 87 %
RTF   4.350
[========            ]      <- RTF bar, full scale 8.000
RTF bar 0..8
```

and on the console:

```
oled: ready at 0x3c
OLED_DEMO: state=READY addr=0x3c frames=450 drawn=14 late_max_ms=0 render_cycles=102279 xfer_cycles=2956821
OLED_DEMO: done
```

`late_max_ms=0` is the part worth reading: the 30 fps loop was never late, so the display cost
nothing it needed. Both live runs read 0. `render_cycles` and `xfer_cycles` should land within
a few per cent of the simulated 102,279 and 2,956,821 (§7.5) — on silicon they were 166,759 /
2,942,127 and 87,800 / 2,930,786, the transfer within 1 % both times. The transfer figure
scales with the bus rate, so a much larger number means the prescaler is not what the DTS asked
for; the render figure tracks how much ink the screen has, and moves legitimately between runs.

**If the screens look right but the lab says FAIL, read §7.7.1 before believing it.** A verdict
is a claim about the harness too, and this one has been wrong once already. The run is archived
either way — that is now unconditional.

### 9.5 What each failure means

| What you see | What it means | What to do |
|---|---|---|
| `no ACK at 0x3c/0x3d, not fitted`, module plugged in | the module never pulled SDA low for its address | Check J4's order again (§9.1), then that SDA/SCL are not swapped, then 3.3 V at the module's VCC pin, then the address strap — some boards are 0x3D, and the sample probes both, so a third address means a non-SSD1306 part. A module whose SDA driver cannot pull this 1.5–2.2 kΩ bus below the FPGA's V<sub>IL</sub> also reads as absent (§1) |
| `ready at 0x3c`, `drawn` climbing, **screen dark** | the panel is being driven but not lit | The init enables the charge pump (`8D 14`) before `AF` (§5.2), so suspect the module: a board missing its boost capacitor, or a 1.3" **SH1106** (132×64) sold as an SSD1306. For SH1106 change the overlay's `compatible` to `sinowealth,sh1106` and set `segment-offset = <2>` |
| image **shifted by two columns**, or a 2-pixel band at one edge | SH1106 again, or a wrong `segment-offset` | as above |
| **every other row blank**, or the image squashed into half the height | COM pin configuration | the overlay omits `com-sequential`, which sends `DA 12` (alternative), right for 128×64. A 128×32 panel wants `DA 02` and `multiplex-ratio = <31>` |
| image **mirrored or upside down** | the module is mounted the other way round | flip `segment-remap` and/or `com-invdir` in the overlay; nothing else changes |
| screen updates for a while, then **freezes**, console shows one `oled:` line | the display thread stopped on purpose: `refresh failed` or `ACKed but init failed`, logged once (§5.3) | that line carries the errno. `-EIO` mid-run is a NACK on the wire: a loose header, or two I²C users without the application lock (§5.4). The rest of the program is unaffected by design — that is what the line means |
| screen fine, but the demo's `late_max_ms` grows | something is driving the display from a hot path | the sample never does: `oled_status_post()` only copies numbers, and the refresh runs in its own lowest-priority thread (§9.6) |
| garbled text but a correct border and bars | the wrong font, or a CFB/driver mismatch | re-run `scripts/54_oled_host_tests.sh`; it renders the same screen and hashes it, so a difference there localises the fault to software before you touch the board |

### 9.6 Do not wire it into a hot path

Measured (§7.5): **one refresh is 3.06 M hart cycles** — 102 k of CFB rendering and 2.96 M of
busy-poll inside `i2c_sifive` — and **84 ms of bus time** at the DTS's 100 kHz. The sample keeps
that out of everything else's way, and anything that reuses `oled_status.c` must keep the same
three rules:

- refresh at most once per `CONFIG_OLED_STATUS_PERIOD_MS` (1 s by default);
- draw from a thread at `K_LOWEST_APPLICATION_THREAD_PRIO`, never from an ISR, a work queue
  shared with capture, or the inference path;
- take `oled_status_bus_lock()` around **every** transfer on this bus, the camera's exposure
  writes included. A camera write can then wait up to one refresh, and no longer.
