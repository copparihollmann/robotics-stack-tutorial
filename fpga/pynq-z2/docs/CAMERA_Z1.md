# The HM01B0 camera on the PYNQ-Z1 shield: bitstream 0x5A5A001E

**Status, 2026-09-17: built (`659c6db6`), simulated (53 checks, 0 failures), and PASSED on the board without the shield (Lab B27, §9.2).** The config elaborates, and the top level,
constraints, driver, Zephyr board, sample and lab are written. The camera, DMA and I²C pass in
this SoC's own RTL in Verilator against a model sensor (§5). The predictions below (§7) are
committed before any Vivado run. The build waits for the coordinator's go. **No board results
yet** (§9).

| | |
|---|---|
| Config | `PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig` = `0x5A5A0010` + `ospi.WithOspiCaptureDma(frameBufferDepth = 512)` + `WithOspiPunchthrough` + `chipyard.config.WithI2C` + `WithHM01B0SimModel` (harness only) |
| MAGIC | `0x5A5A001E` (`MAGIC_REGISTRY.md`, claimed with the tcl variant in `dac9056`) |
| tcl variant | `roccmooncam`: `tcl/build_rocket_roccmooncam.tcl`, `scripts/build_roccmooncam_z1.sh` |
| Shield | `riskybirdv3_pynq_camera` rev 0.6 on the Z1's chipKIT header. Pin map `archive/drafts/PINMAP_riskybirdv3_pynq_camera_rev0.6.md`. **Not** `CAMERA_PCB_SPEC.md`, which is the older PYNQ-Z2 design |
| New MMIO | TLI2C `0x1004_0000` (PLIC 1), ospi `0x1008_0000` (PLIC 9) |
| **PLIC renumbered** | UART **1 → 2**, GPIO **2..7 → 3..8**, `riscv,ndev` 7 → 9. Needs its own Zephyr board, `chipyard_pynqz1_cam` (§8) |
| DMA path | ospi master → fbus → sbus → **L2 (InclusiveCache)** → mbus → ExtMem → `S_AXI_HP0`. Coherent with both harts' caches (§1.3) |
| Engine RTL | **revision 1, snapshot** `src/cam_engine_rev1/` (the files `0x5A5A0010` was built from, md5-checked by the tcl) (§6) |
| Other variants | Preprocessed top **byte-identical** for all 25 other variants (§3.4) |
| Simulation | `scripts/65_cam_rtl_sim.sh`: **53 passes, 0 failures** (§5) |
| Built | **md5 `659c6db6`**, 41,080 LUT (77.2 %), 86.0 BRAM, 90 DSP; `clk_fpga_0` WNS **+1.126** / WHS **+0.037**; `cam_pclk` WHS **+0.083**, WNS −1.566 at the 36 MHz datasheet maximum and **+13.5 at 17.24 MHz**, the fastest PCLK this RTL can produce (§7.5) |

---

## 1. The SoC

### 1.1 What is added, and what is not

The camera follows `PynqZ2RocketTacitCamConfig`'s shape (single core, never built on this board).
It goes on top of `0x5A5A0010` and nothing else:

- **`ospi.WithOspiCaptureDma(frameBufferDepth = 512)`** adds the capture core, a 1024-deep CDC
  FIFO, a **line-sized** 512-beat frame buffer, and the DMA engine with its TileLink client.
  - A whole-frame buffer is 324 × 324 + 1 beats. The 200T measured it at **44 RAMB36**
    (a separate Artix-7 implementation run's `rb_impl_utilization_hier.txt`, `frameBuffer`), which is
    a third of this part's 140.
  - The price of the small buffer is a software rule (§5.3): a DMA transfer must already be running
    when a frame starts.
- **`chipyard.iobinders.WithOspiPunchthrough`** exposes the `ospi_sensor_*` ChipTop ports.
- **`chipyard.config.WithI2C`** adds the TLI2C at `0x1004_0000`, with `i2c_0_*` exposed by
  AbstractConfig's `WithI2CPunchthrough`.
  - The fragment asks for `AsynchronousCrossing`, but the generated Verilog has no crossing for it.
    The elaboration adds `TLI2C`, its coupler, a `ClockSinkDomain` and no AsyncQueue module, so the
    TLI2C is synchronous on the pbus clock.
- **`WithHM01B0SimModel`** binds a model sensor in the TestHarness in place of a tie-off (§5.1).
  ChipTop is unaffected.
  - `*.top.f`, which is all Vivado reads, does not list the model.
  - The model's Verilog is given only to Verilator.

ChipTop gains exactly `i2c_0_{scl,sda}_{in,out,oe}` and `ospi_sensor_{pclk,fvld,lvld,d[7:0],intr,mclk,trig}`
(diff of the two ChipTop headers).

The rest of the elaboration changes only address-decode constants, the PLIC and the fbus crossbar:
- Address decode: the PMA checker and PTW in both tiles, the sbus/cbus crossbars, the fragmenters.
- The PLIC grows from 7 to 9 sources.
- The fbus crossbar goes from 2 to 3 inputs.
- `InclusiveCache.sv` differs only in a monitor instance's name, and no TileLink source-ID width
  changes.

### 1.2 Address map (generated, `…RoccMoonCamConfig.dts`)

| Region | Device | Note |
|---|---|---|
| `0x0000_3000` | error device | where the DMA's error path was tested (§5) |
| `0x0200_0000` | CLINT | |
| `0x0201_0000` | L2 control | |
| `0x0300_0000`, `0x0300_1000` | TACIT encoders | |
| `0x0301_0000`, `0x0301_1000` | TACIT DMA sinks | |
| `0x0800_0000` | 64 KiB mbus scratchpad | |
| `0x0C00_0000` | PLIC | `ndev` 9 |
| `0x1001_0000` | GPIO (RGB LEDs) | PLIC 3..8 |
| `0x1002_0000` | UART | PLIC **2** |
| **`0x1004_0000`** | **TLI2C** | PLIC **1** |
| **`0x1008_0000`** | **ospi** | PLIC **9** |
| `0x1009_0000` | PDM microphone | no interrupt |
| `0x8000_0000`–`0x8FFF_FFFF` | ExtMem (PS DDR `0x1000_0000`+) | |

No collisions:
- The RoCC engine has no MMIO: it is custom-1 plus two sbus clients.
- `BwProbe` (`0x100A_0000`) is not in this config.
- `0x1004_0000` and `0x1008_0000` were both free in `0x5A5A0010`.

**Why the UART moved.** DigitalTop mixes in `HasPeripheryI2C` before `HasPeripheryUART`, so the
I²C controller's interrupt is numbered first.

### 1.3 The DMA path, and what it may be pointed at

The generated `DigitalTop.sv` shows the path hop by hop:
- `ospiLM.auto_ospi_dma_crossing_out` → `fbus.auto_coupler_from_ospi_dma…`;
- `fbus.auto_bus_xing_out` → `sbus.auto_coupler_from_bus_named_fbus…`;
- `sbus.auto_coupler_to_bus_named_coh_widget` → `coh_wrapper` (the InclusiveCache) → `mbus` → ExtMem.

This is TACIT's `TraceSinkDMA` path. **A frame the DMA writes therefore goes through the L2, which
revokes any L1 copy, and both harts read it coherently.** §5 checks this on both harts.

Restrictions, from the RTL (`OspiChipyard.scala`) and the generated edge (`a32d64s1`: 32-bit
address, 64-bit data, one source):

1. **The address is 32 bits.** `DMA_ADDR_HI` is stored but truncated away.
2. **The address must be 8-byte aligned.** Every beat is an 8-byte `PutFullData`, or a masked
   `PutPartialData` for the tail, at `addr + bytesWritten`.
3. **The whole transfer must land in a mapped, writable slave.**
   - The client's visibility is the whole address space: it can write MMIO, including its own
     registers.
   - A write to the error device (`0x3000`) returns DENIED and sets `DMA_STATUS.error` (§5).
   - A write to an unmapped hole is a TileLink protocol violation: a monitor assertion in
     simulation, and a hang on the board.
   - For frames the only sensible target is ExtMem, `0x8000_0000`–`0x8FFF_FFFF`, outside the
     guest's image. The 64 KiB scratchpad at `0x0800_0000` is too small for a frame.
4. **The destination must hold the sensor's frame, not the expected one.** A `DMA_LEN = 0` transfer
   runs to the EOF whatever `GEOM` says; `DMA_LEN` caps it.
5. **There is no abort.** A transfer armed while PCLK is absent stays BUSY in COLLECT until data
   arrives or the SoC is reset (§5).

---

## 2. Pins

The pin map is the netlist of the shield. Every ball, bank and pin function below was re-checked
against Vivado's own `report_io` of the routed `0x5A5A0010`
(`build_rocket_micrgb_roccmoon_z1/reports/post_route_io.rpt`), where all of them are unused
User IO. No existing XDC (`src/*.xdc`, `src/axiceil/*.xdc`) assigns any of them.

| Port | Ball | Pin function | Bank | Shield | Series R on the Z1 |
|---|---|---|---|---|---|
| `cam_d[0]` | T14 | IO_L5P_T0_34 | 34 | IO0 | 200 Ω |
| `cam_d[1]` | U12 | IO_L2N_T0_34 | 34 | IO1 | 200 Ω |
| `cam_d[2]` | V13 | IO_L3N_T0_DQS_34 | 34 | IO3 | 200 Ω |
| `cam_d[3]` | V15 | IO_L10P_T1_34 | 34 | IO4 | 200 Ω |
| `cam_d[4]` | T15 | IO_L5N_T0_34 | 34 | IO5 | 200 Ω |
| `cam_d[5]` | R16 | IO_L19P_T3_34 | 34 | IO6 | 200 Ω |
| `cam_d[6]` | U17 | IO_L9N_T1_DQS_34 | 34 | IO7 | 200 Ω |
| `cam_d[7]` | V17 | IO_L21P_T3_DQS_34 | 34 | IO8 | 200 Ω |
| `cam_mclk` (out) | V18 | IO_L21N_T3_DQS_34 | 34 | IO9 | 200 Ω |
| `cam_trig` (out) | T16 | IO_L9P_T1_DQS_34 | 34 | IO10 | 200 Ω |
| `cam_sda` (inout) | P15 | IO_L24P_T3_34 | 34 | SDA | none, 2.2 kΩ pull-up |
| `cam_scl` (inout) | P16 | IO_L24N_T3_34 | 34 | SCL | none, 2.2 kΩ pull-up |
| `cam_fvld` | W11 | IO_L18P_T2_13 | 13 | A2 | none |
| `cam_lvld` | V11 | IO_L21P_T3_DQS_13 | 13 | A3 | none |
| `cam_int` | T5 | IO_L19P_T3_13 | 13 | A4 | none |
| `cam_pclk` | **U10** | **IO_L12N_T1_MRCC_13** | 13 | A5 | none |

All pins are LVCMOS33.

**U13 (shield IO2) is `IO_L3P_T0_DQS_PUDC_B_34`, tied to 3V3 on the shield.** No port may be on it.
`build_rocket.tcl` checks after route that it carries none, and the build script checks
`report_io`.

**U10 is the N side of its clock-capable pair.** The P side is T9 (`IO_L12P_T1_MRCC_13`, also from
`report_io`), and T9 is not on the shield. On 7-series only the P side has a dedicated route from a
single-ended clock input to a BUFG. The pin map calls U10 "the only clock-capable pin", which is
true, but it is not a dedicated clock route. So the XDC sets `CLOCK_DEDICATED_ROUTE FALSE` (§4.1).
Without it the placer stops.

**Out of scope, unassigned, a possible follow-up.** The shield also carries an FT2232H:
- its channel B is a PL UART, on A0/A1 = Y11 (RX), Y12 (TX);
- its channel A is JTAG, on IO11/12/13 = R17 (TCK), P18 (TMS), N17 (TDI) and IO42 = Y13 (TDO).

A PL console independent of PS Linux would matter for the tutorial. It is not built here. TCK
would need `CLOCK_DEDICATED_ROUTE FALSE` too: R17 is not clock-capable.

---

## 3. The top level (`src/pynqz2_rocket_top.v`, behind `PYNQZ2_CAM`)

### 3.1 I²C: the Arty-200T binder's function, as IOBUFs

`WithArty200TI2C` (`riskybird_chipyard/fpga/src/main/scala/arty200t/HarnessBinders.scala`) does:
- `UIntToAnalog(port.io.scl.out, pin, port.io.scl.oe)`. Its inline Verilog is
  `assign a = b_en ? b : 1'bz`.
- `port.io.scl.in := AnalogToUInt(pin)`, i.e. `assign b = a`.
- LVCMOS33 with `PULLUP`.

Here each line is `IOBUF u_cam_scl (.I(i2c_scl_out), .T(~i2c_scl_oe), .O(i2c_scl_in), .IO(cam_scl))`.
An IOBUF drives `IO = I` when `T = 0`, floats it when `T = 1`, and `O = IO`, which is the same
function. The TLI2C holds `*_out` at 0 (open drain), so the pin is pulled low when `oe` is set and
released otherwise. The XDC sets `PULLUP TRUE`, as the 200T did, in parallel with the Z1's 2.2 kΩ.

Simulation exercises both states (§5): an ACK from the model at 0x24, and a released bus
(a NACK) at 0x3C.

### 3.2 MCLK: an ODDR on FCLK0

- **The divider.** ChipTop's `ospi_sensor_mclk` is a toggle flop on the uncore clock (FCLK0):
  `MCLK = FCLK0 / (2·(mclkDiv+1))`.
- **The ODDR.** The top re-launches it from `ODDR #(.DDR_CLK_EDGE("SAME_EDGE"))` with
  `D1 = D2 = mclk` on FCLK0.
  - The last flop is therefore the IOB's. The edge the sensor sees is set by FCLK0 and one OLOGIC,
    not by a fabric route to V18, and the duty cycle is the toggle flop's 50 %.
  - The path from the toggle flop is full-cycle, and MCLK lags by one FCLK0 cycle, which nothing
    cares about.
- **Why not forward FCLK0 itself.** 34.48 MHz is inside the sensor's 3–36 MHz, but the RTL's divider
  is what software controls.

| `MCLKDIV` | MCLK at 34.4828 MHz | HM01B0 MCLK range 3–36 MHz, duty 45–55 % |
|---|---|---|
| 0 (reset) | 17.241 MHz | in range |
| 1 | 8.621 MHz | in range |
| **2** | **5.747 MHz** | in range. **The lab's default:** the datasheet's 8-bit QVGA@60 fps point is "@ 6MHz" |
| 3 | 4.310 MHz | in range |
| 4 | 3.448 MHz | in range |
| ≥ 5 | ≤ 2.874 MHz | **below 3 MHz, out of spec** |

Source: HM01B0-MNA-01FT870 datasheet, preliminary V01 (Oct 2019), Table 1.3 "Master Clock (MCLK)
timing": input frequency min 3, max 36 MHz, duty cycle 45–55 %. Section 1.3 gives "Frame Rate
(Max.) (8-bit interface) 8-bit, QVGA 60FPS @ 6MHz" and "Pixel Clock (PCLK) (MAX.) 36MHz".

The toggle flop gives exactly 50 % duty, with FCLK0's jitter.

### 3.3 PCLK

An explicit `IBUF` → `BUFG` feeds `ospi_sensor_pclk`, so the XDC's `CLOCK_DEDICATED_ROUTE` names a
real net: `get_nets -of_objects [get_pins u_cam_pclk_bufg/I]`.

TRIG is a plain output. INT, FVLD, LVLD and D are plain inputs, and the capture core registers them.

### 3.4 Every other variant's top is byte-identical

For each variant, the defines come from `build_rocket.tcl`'s own switch
(`scripts/check_mem_contract.py`'s `tcl_variants()`). The top was run through `verilator -E -P`
before and after the edit. Every variant except `roccmooncam` is **IDENTICAL**:

| variant | MAGIC | md5 of the preprocessed top, before = after |
|---|---|---|
| `roccmoon` | **0x5A5A0010** | `52a6cc3f6695…` = `52a6cc3f6695…` |
| `micrgb` | **0x5A5A0006** | `52a6cc3f6695…` = `52a6cc3f6695…` |
| `roccmoonmul`, `roccmoon2a`, `bw`, `bwl2cap`, `bwl2cork`, `bwl2mshr`, `bwl2skip`, `bwwide`, `bwwide256` | 0011, 0012, 0007, 000C, 000E, 000B, 001A, 000A, 000F | `52a6cc3f6695…` (same define set) |
| `tacit`, `smp`, `pext` | 0002, 0003, 0004 | `667f779115bf…` |
| `mic` | 0005 | `4e984e2cfa79…` |
| `bwfast`, `bwl2wsf`, `bwl2wsmf` | 0008, 0018, 0019 | `6fd28ae1ae52…` |
| `bwports` | 0009 | `fe43b301d397…` |
| `bwbypassl2` | 0014 | `ba8fa759cbac…` |
| `bwbypass` | 0015 | `41eeb8d8be5f…` |
| `bwbypass01` | 0016 | `63dae347d08d…` |
| `bwbypass4`, `bwwin` | 0017, 001C | `34774042b726…` |
| `bwl2fast` | 000D | `ae08202e8f52…` |
| `roccmooncam` | 0x5A5A001E | `52a6cc3f6695…` → `d2a7ef169404…` |

The diff from `roccmoon` to `roccmooncam` is the nine port declarations, the pad block (IBUF, BUFG,
ODDR, two IOBUFs, one assign), and 13 ChipTop connections.

Two further checks:
- **ChipTop connections.** Every one of ChipTop's 131 ports is connected, and no connection names a
  port ChipTop lacks. This is a script over the generated header and the preprocessed top.
- **Memory-port contract.** `check_mem_contract.py --variant roccmooncam` → `MEM_PORT_CONTRACT_OK`,
  unchanged: the camera adds no AXI port.

Before/after files: `archive/sims/cam_z1/top_preproc/{before_vpp,after_vpp}/`.

---

## 4. Constraints (`src/pynqz2_cam.xdc`)

### 4.1 PCLK

The constraints mirror the 200T's `WithArty200TOspi`, which used `addClock("ospi_pclk", pclkIO, 36)`,
`set_input_jitter 0.5`, an async group and `clockDedicatedRouteFalse`:

- `create_clock -name cam_pclk -period 27.778 [get_ports cam_pclk]`, with `set_input_jitter cam_pclk 0.5`.
  - 36 MHz is the datasheet's "Pixel Clock (PCLK) (MAX.)" and the 200T's constraint.
  - This RTL's fastest MCLK is 17.24 MHz, and the 8-bit QVGA@60 fps point is 6 MHz. So every
    PCLK-domain path is timed against at least twice the clock it can see.
- `set_clock_groups -asynchronous` between `cam_pclk` and the PS clocks, selected by their
  `PS7_i/FCLKCLK*` pins as `pynqz2_memclk.xdc` does.
  - Every crossing in `HM01B0Capture` is Gray-coded behind 3-flop synchronisers: the AsyncFifo
    pointers, `crossCount`, and `syncPclk`.
  - `report_cdc` is written for every build.
- `CLOCK_DEDICATED_ROUTE FALSE` on the IBUF → BUFG net (§2).

### 4.2 D, FVLD, LVLD: source-synchronous, with stated assumptions

| Term | min | max | Basis |
|---|---|---|---|
| Launch edge | PCLK **falling** | | The capture core samples on the rising edge, so the sensor must launch on the falling one. **Assumed:** the datasheet has no output AC table |
| Sensor clock-to-out | 0 ns | +8 ns | **Assumed** (no datasheet number) |
| U1 (AXC8T245) vs U2 (AXC4T245) skew | −3 ns | +3 ns | Different packages and channels. **Assumed** |
| Z1 200 Ω into ~5–20 pF, on D only | +0.5 ns | +4 ns | RC to the 50 % point. The pin map estimates "roughly 4 ns into ~20 pF" |
| **`set_input_delay -clock_fall`** | **−2.5 ns** | **+15.0 ns** | FVLD/LVLD have no 200 Ω (A2/A3) but get the same budget: pessimistic for them |

**Setup** is budgeted at the 27.778 ns constraint. Half a period is 13.889 ns. The +15.0 ns
maximum is recovered by the PCLK insertion delay: IBUF, a non-dedicated route to the BUFG, then
the tree.
- The predicted slack is in §7.
- **Rule, fixed now:** if the input paths show negative setup slack at 36 MHz, the build is judged
  at the fastest PCLK this RTL can produce, 17.24 MHz (half-period 29.0 ns, i.e. +15.1 ns more
  slack). The constraint file is not changed after the fact.

**Hold** is checked against the rising edge half a period before the launch, so it has ~13.9 ns of
margin before insertion delays.

### 4.3 MCLK, TRIG, INT, I²C

- `create_generated_clock -name cam_mclk -source [get_pins u_cam_mclk_oddr/C] -divide_by 2 [get_ports cam_mclk]`.
  - It describes the reset value, `mclkDiv = 0`, the fastest case. `mclkDiv` changes at run time,
    so no single ratio is always true.
  - Nothing in the PL is clocked by it, and the sensor returns PCLK rather than sampling anything
    against MCLK, so it has no output delay.
- `set_false_path` to TRIG (a software pulse), from INT (synchronised in RTL), and both ways on
  SCL/SDA. At ≤ 400 kHz the TLI2C's own input registers oversample the bus.

---

## 5. Simulation (`scripts/65_cam_rtl_sim.sh`)

### 5.1 The model

`fpga/pynq-z2/sim/hm01b0_sim_model.v` is a BlackBox bound by `WithHM01B0SimModel`. One instance
serves both port groups. No HM01B0 stimulus existed in the 200T tree: a full search of this machine
found only the Scala RTL and shells, no camera software, no model, and no `hardware/ospi` README.

- **I²C slave at 0x24.** 16-bit register addresses and auto-increment.
  - `MODEL_ID` 0x0000/0x0001 = 0x01/0xB0.
  - `MODE_SELECT` 0x0100: bit 0 streams.
  - Other addresses ACK. Other slave addresses get a released bus, i.e. a NACK.
  - It oversamples SCL/SDA on the harness clock.
  - **Model-only** registers 0xFF00–0xFF07 report TRIG edges, "MCLK seen", frames, writes, SCL
    edges and the shortest SCL period in MCLK periods. None is an HM01B0 register.
- **Video.** PCLK = MCLK/2, only while streaming; in standby PCLK is held low.
  - 32 × 24 frames.
  - D/FVLD/LVLD change on PCLK's falling edge.
  - FVLD falls 12 PCLKs after the last pixel of the frame. The CaptureFrontend needs FVLD to fall
    after LVLD, or the EOF marker takes the last pixel's beat.
  - Pixel (x, y) of frame f is `(7x) ^ (13y) ^ f`.
- **The software** (`samples/cam_rtl_sim/main.c`) runs on both harts.
  - It uses `sw/cam/ospi_cam.c`, the driver the board sample uses.
  - It includes a register-level TLI2C loop that issues exactly the commands Zephyr's
    `i2c_sifive.c` issues for `i2c_write()`/`i2c_write_read()`.
  - The engine BlackBoxes come from the `src/cam_engine_rev1` snapshot.

### 5.2 Results

Simulated in Verilator on `…RoccMoonCamConfig`'s own TestHarness, with DRAMSim behind ExtMem.
Logs are in `archive/sims/cam_z1/` (`elab.log`, `sim_run1.log`, `run2.log`/`sim_run2.log`).

**Run 1, 2026-09-17 ~10:52–11:10: 51 passes, 1 failure.**
- The failure was a test bug: "TRIG held low in continuous mode" set CONTINUOUS and TRIG in one
  write (§5.3 item 4).
- The test was fixed and run 2 was started. Run 2 also adds the model's in-byte SCL period.

| Section | What | Result (simulated) |
|---|---|---|
| A | reset values | CAPACITY 512, GEOM `0x00F40144` (324×244), CTRL/MCLKDIV/DMA_CTRL 0, FRAMECNT/FLAGS/DMA_STATUS/DMA_BYTES 0, **PCLKCNT = FVLDCNT = LVLDCNT = 0** in standby; MCLKDIV reads back |
| B | I²C, Zephyr `i2c_sifive` command sequence, prescale 67 | **0x3C: NACK (−EIO), released bus. 0x24: MODEL_ID = 0x01B0.** A NACK with no STOP, then 0x24 answers again. A 3-byte register write ACKed and seen by the sensor. MCLK and TRIG reach the model's pins. SCL toggles |
| C | idle diagnostics after I²C traffic | 0 / 0 / 0 |
| D | DMA armed, no PCLK | **DMA_STATUS `0x11`** (busy, state COLLECT), DMA_BYTES 0, PCLKCNT 0. `ospi_dma_capture_frame` refuses (−1) |
| E | MODE_SELECT = 1 | the armed transfer completes: **DMA_STATUS `0x0A`** (done, sawEof, no error), **DMA_BYTES 768**, **FRAMECNT 1**, LASTWIDTH 32, LASTHEIGHT 24, no geomErr, irqPending set (then cleared by CTRL.clear). **Frame 0: 0 bad bytes on hart 0, 0 on hart 1, sums equal (95,424)**; the bytes after the frame untouched |
| F | `ospi_dma_capture_frame` ×3 | three whole frames (model frames 2, 144, 192), each 1 attempt, 768 bytes, DMA_STATUS `0x0A`, **0 bad bytes on both harts**, trailing sentinel intact. PCLKCNT 343,901, FVLDCNT 239, LVLDCNT 5,731 (24/frame, 1,440 PCLK/frame) |
| G | DMA_LEN = 13 | done, DMA_BYTES 13, **bytes 13..63 untouched** (PutPartialData mask) |
| H | DMA at the error device `0x3000` | **DMA_STATUS `0x06`** (done + error); DMA_CTRL.clear drops both |
| I | MMIO DATA path, DMA disabled | DATA `0x80000177` (valid, sof, 0x77). Overflow and frameBufferFull set when nothing drains. **Overflow needed 4 CTRL.clear pulses to clear** (§5.3 item 3) |
| J | MODE_SELECT = 0 | PCLKCNT holds at 468,285 |

"Cores read it back through the L2": the frame arrays are ordinary `.bss` in ExtMem. Hart 0 reads
them through its own L1 and the L2; hart 1 is a separate core whose L1 has never held those
blocks. Both compare every byte against the pattern.

**Run 2:** **53 passes, 0 failures**, 2026-09-17 11:12–11:40 (`archive/sims/cam_z1/sim_run2.log`). Same
results as run 1 in every section, plus the two additions:

- **"TRIG is held low in continuous mode" passes** once CONTINUOUS is set in its own write.
- **The SCL bit period, measured at the model's pin inside a byte** (where the TLI2C clocks nine
  bits with no software in between): **153 MCLK periods ≈ 306 SoC clock cycles**, i.e. **112.7 kHz
  at 34.4828 MHz for a requested 100 kHz**, with prescale 67.
  - `5·(prescale+1)` = 340 cycles (101.4 kHz), the OpenCores formula Zephyr's driver inverts.
  - `4·(prescale+1)` = 272 cycles (126.8 kHz), four phases per bit with no stretching.
  - The measurement sits between them: the bit is four phases plus the controller's own input
    filter and synchroniser delay before it sees SCL rise again. **SCL runs ~13 % fast against the
    requested rate**, which is the direction the OLED agent predicted, though the size is
    consistent with the filter rather than with an inverted `slave_wait` (an inverted one would
    not add delay).
  - It is well inside the HM01B0's 400 kHz maximum.
  - Resolution is ±1 MCLK period (±2 SoC cycles); MCLKDIV was 0, so one MCLK period is two SoC
    cycles.
- Overflow took **5** CTRL.clear pulses in run 2 and 4 in run 1 (§5.3 item 3): it depends on where
  the one-cycle pulse falls against PCLK, which is what the finding says.
- Frames: model frames 0, 2, 144 and 191, each 768 bytes, 1 attempt, 0 bad bytes on both harts.

**Run 3, after `patches/0120` (Zephyr `i2c_sifive`: one address phase per transfer): 53 passes, 0
failures** (`archive/sims/cam_z1/sim_run3.log`). The patch cannot change this driver's traffic, and
that is from the code rather than from the claim: the new rule sends an address phase when
`i == 0`, on `I2C_MSG_RESTART`, after a `STOP`, or on a direction change. `i2c_write()` is a single
message (`I2C_MSG_WRITE | I2C_MSG_STOP`), so it takes one at `i == 0` as before; `i2c_write_read()`
is a write then `I2C_MSG_RESTART | I2C_MSG_READ | I2C_MSG_STOP`, so the read takes one by RESTART
*and* by direction change, and its last byte still gets NACK + STOP. `samples/cam_capture` also
rebuilds clean against the patched tree, with the devicetree check (UART 2 / I²C 1 / ospi 9)
passing.

### 5.3 Findings

1. **A transfer must already be running when the frame starts (line-sized buffer).**
   - If capture is enabled mid-frame, the first transfer ends at that frame's EOF with a partial
     frame and sets the sticky geomErr.
   - `ospi_dma_capture_frame` therefore issues two start pulses before enabling capture. The second
     lands while the first is busy and sets the engine's `pendingStart`, so the second transfer
     begins on the cycle the first finishes, at a frame boundary, with no software latency.
   - It then waits for DMA done and not busy with FRAMECNT ≥ start + 2, and checks bytes, measured
     geometry and sawEof. It repeats up to 3 times.
   - In simulation, 4 of 4 captures took 1 attempt.
   - A software restart between transfers would lose data on the board: the slack is 512 + 1024
     beats, ~0.3 ms of a 5.7 MHz PCLK.
2. **There is no DMA abort.** A transfer armed with no PCLK stays BUSY in COLLECT indefinitely
   (`0x11`). `DMA_CTRL.enable = 0` does not return it to IDLE; it only re-routes the read port.
   Only sensor data or a SoC reset ends it. The board lab's no-shield path reports this and leaves
   it armed.
3. **The overflow clear is a one-cycle SoC-clock pulse resampled on PCLK** (`AsyncFifo.clearOverflow`
   through `syncInto`). It can be missed when PCLK is slower than the SoC clock: 4 pulses in
   simulation at PCLK = sysclk/4. The driver therefore does not treat a sticky overflow as a
   failure. A dropped beat still shows up as a short byte count or wrong geometry, because the EOF
   marker travels in the same FIFO.
4. **`continuous` suppresses TRIG from the cycle after the write that sets it.** A single write of
   `CONTINUOUS | TRIG` still pulses TRIG. Set CONTINUOUS first.
5. **The DMA's address restrictions** (§1.3), checked on the RTL.
   - The error device gives done + error and the transfer still finishes.
   - A 13-byte cap writes exactly 13 bytes through PutPartialData's mask.
   - Frames written through the L2 are byte-exact on both harts.
6. **I²C.** Zephyr's exact command sequence works against a slave: ACK, NACK with a released bus,
   repeated-start reads, a 3-byte write, and recovery after a NACK without STOP.
   - The average SCL edge spacing over two MODEL_ID reads was 582 (run 1) / 583 (run 2) SoC cycles.
     That average includes software time between bytes and is not the bit period.
   - **Run 2 measured the bit period inside a byte: 306 SoC cycles, 112.7 kHz for a requested
     100 kHz** (§5.2). Software that needs a bus rate must measure it, not compute it from the
     prescaler.

---

## 6. Engine RTL: revision 1, pinned by snapshot

`rtl_study/roccmoon/*.v` and `rtl_study/rocc/*.v` move to revision 2a after `0x5A5A0011`. This
variant does not follow them.

- **The snapshot.** `src/cam_engine_rev1/` holds the seven files the `roccmoon` variant reads, with
  `MD5SUMS`:

  ```
  b1ce32ee541a50dab4b6a1e420800358  mbxr_engine.v
  8596f212d1e9b05e6bad4d2ce8911929  mbxr_tseq.v
  6c6aa1b8375528fd20f0aa18dddc6e30  mbxr_datapath.v
  281164a71f2514011ff1d5be52b51696  mbxr_st.v
  c474e28d50a44b75671e18850e299b06  mbxd_dma.v
  e8ecb06d533d4a43f25e95bab47b2aaa  mbxd_spad.v
  22d9b90333c7293d0496f3b93f7103a4  mbx_mac.v
  ```

- **They are the files `0x5A5A0010` (md5 `7475c1b2`) was synthesised from.**
  - Each file is byte-identical to its blob in `f69acfb`, and no later commit touches them.
  - Every mtime (21:24–21:28 and earlier) predates that build's project creation at 21:54:57 on
    2026-09-16.
  - The 0010 `.xpr` lists exactly these seven files.
- **Enforcement.** `build_rocket.tcl` reads the snapshot for this variant only, and refuses to build
  if any md5 differs. `build_roccmooncam_z1.sh` checks the same list before Vivado.
- **Commit.** Committed in `dac9056`, which unblocked the rev2a swap.

### 6.1 What the build's inputs are, and what they are not

- **The generated Verilog is vendored**, not taken from the donor Chipyard tree:
  `fpga/pynq-z2/chipyard/gensrc/PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig.tar.gz`
  (504 source files plus the SRAM macros), packed from the 2026-09-17 10:38 elaboration with its
  `PROVENANCE` (chipyard `8dd1b34c`, rocket-chip `5f666271`, patches 0004, 0061, 0091, 0008 and
  0101 applied at pack time -- the tree state `0x5A5A0011` was packed from).
- **The build runs with `CHIPYARD_DIR` unset**, so `tcl/build_rocket.tcl` resolves the unpacked
  bundle and a later re-elaboration in the shared tree cannot change what this bitstream is
  built from.
- **The known reproducibility gap is the donor tree's, not this build's.**
  `scripts/02_verify_patches.sh` reports rocket-chip drift in `CSR.scala` and `RocketCore.scala`:
  in-flight Saturn/V-extension work from the riskybird project, dated before this workstream
  (2026-09-15 22:07 and 2026-09-16 21:50) and present in every recent bundle, `0x5A5A0010`'s
  included. `docs/REPRODUCING.md` §5 documents it and shows from the generated Verilog that it is
  inert in configs with no vector unit. Nothing here acts on it.

---

## 7. Predictions, committed before building

Written 2026-09-17, before any Vivado run of this variant. Base: `0x5A5A0010` as routed
(md5 `7475c1b2`, `build_rocket_micrgb_roccmoon_z1/reports/`).
- **0010 as routed:** 38,833 LUT (2,951 LUTRAM), 22,343 FF, 85.5 BRAM tiles, 90 DSP, 12 IOB,
  1 BUFGCTRL.
- **0010 timing:** WNS +0.458 ns, WHS +0.011 ns, both on `clk_fpga_0` at 28.999 ns.

Two bodies of evidence set the numbers.
- **Measured camera cost.** The 200T's routed, hierarchical cost of the same capture core
  (that same Artix-7 utilization report, xc7a200t, same 7-series
  primitives):
  - `ospiLM` without DMA and with the whole-frame buffer: 1,302 LUT (472 LUTRAM), 1,116 FF,
    44 RAMB36. Of that, `capture` is 575 LUT / 745 FF (its AsyncFifo 362 LUT, 256 of them LUTRAM),
    and `frameBuffer` is 188 LUT / 68 FF / 44 RAMB36.
  - `TLI2C` 116 LUT / 119 FF; its coupler 72 LUT / 33 FF; the ospi coupler 46 LUT / 43 FF.
- **Build-to-build spread at 28.999 ns.** Every archived build (`archive/builds/*/reports/timing_summary.rpt`):
  - WHS ranges **+0.007 to +0.049 ns**, never negative, even at 48.5k LUT (91 %).
  - WNS ranges −0.002 to +1.754 ns; the six builds between 40.2k and 40.5k LUT measured +0.499 to
    +1.754.

### 7.1 Area

| | 0010 | predicted Δ (80 % interval) | predicted total | basis |
|---|---:|---:|---:|---|
| Slice LUTs | 38,833 | **+1,800** (+1,350 … +2,300) | **40,630** (76.4 %) | 200T `ospiLM` 1,302, less ~130 for a 512-beat buffer's counters, plus ~350 for the DMA engine, its six registers, its TLBuffer crossing and the fbus crossbar's third input; TLI2C and couplers 234; PLIC +2 sources ~40 |
| of which LUTRAM | 2,951 | **+300** (+250 … +420) | 3,250 | AsyncFifo 1024×11 async-read (256 on the 200T), `capturePipe` 8, 2-entry TileLink queues |
| Slice Registers | 22,343 | **+1,600** (+1,200 … +2,100) | 23,940 | 200T `ospiLM` 1,116 less ~40 for the buffer, plus ~210 DMA state and registers, ~100 buffers, TLI2C and couplers 195, PLIC ~20 |
| Block RAM tiles | 85.5 | **+0.5** (0 … +1.0) | **86.0** | `Queue512_PixelFlit` (512×11, synchronous read) → one RAMB18. 0 if Vivado maps it to LUTRAM (then ~+90 LUT) |
| DSP48E1 | 90 | **0** | 90 | nothing multiplies |
| Bonded IOB | 12 | **+16** | 28 | the shield's pins |
| BUFGCTRL | 1 | **+1** | 2 | PCLK |

Falsified if LUT lands outside +1,350 … +2,300, BRAM is not 85.5 or 86.0, or DSP is not 90.

### 7.2 Timing

| Clock / paths | predicted | 80 % interval | P(< 0) | basis |
|---|---:|---:|---:|---|
| `clk_fpga_0` **WNS** | **+0.35 ns** | −0.05 … +1.0 | ~10 % | 0010 +0.458 and 0011 +0.273 at ~38.7k LUT. The added logic is pbus/fbus peripheral, away from the critical path (L2 MSHR scheduler / P-ext), but +4.6 % LUT moves placement |
| `clk_fpga_0` **WHS** | **+0.020 ns** | +0.005 … +0.050 | ~3 % | the spread above: the router fixes hold to a few tens of ps and has never left it negative on this part |
| `cam_pclk` **WNS** (setup) | **+1.2 ns** | −0.5 … +3.0 | ~15 % | set by the input ports: 13.889 (half-period) − 15.0 (max input delay) + 4–7 (PCLK insertion: IBUF, non-dedicated route, BUFG, tree) − 2.5–4 (data IBUF and route) − ~0.3 (setup, uncertainty). PCLK-domain register-to-register paths (Gray counters, FIFO pointers) ≥ +20 ns |
| `cam_pclk` **WHS** | **+0.03 ns** | +0.005 … +0.30 | ~3 % | internal paths, hold-fixed like FCLK0's. The input ports have ~+9 ns (§4.2: capture edge half a period before launch) |
| `cam_mclk` | no timed paths | | | nothing is clocked by it, and there is no output delay |
| inter-clock | not timed | | | asynchronous groups; `report_cdc` is the check |

The ODDR path from the toggle flop to the IOB is an FCLK0 full-cycle path (setup ≥ +20 ns, hold
positive by routing distance).

### 7.3 If WHS goes negative (the baseline is +0.011 ns)

Fixed now, before the result:

1. **The bitstream is not loaded and its md5 is not registered.** Nothing is measured on it.
2. **Locate, without rebuilding.** Use the `TIMING_CLOCK` lines the tcl prints per clock, then
   `report_timing -hold -max_paths 50` on `post_route.dcp`: which clock, which endpoints, how many.
3. **`clk_fpga_0`, a few endpoints within 0.1 ns** (the likely shape at +0.011):
   - Re-route from `post_route.dcp` with a temporary extra hold margin: an opt-in
     `ROCKET_HOLD_MARGIN_PS`, applying `set_clock_uncertainty -hold` on `clk_fpga_0` for
     `route_design` only, removed before the final `report_timing_summary`.
   - Every other variant's flow stays unchanged.
   - If still negative, re-place with `place_design -directive ExtraNetDelay_high` (opt-in the
     same way).
4. **`cam_pclk` register-to-register:** the same route-time margin on `cam_pclk`.
5. **A `cam_d`/`cam_fvld`/`cam_lvld` input:** these have ~+9 ns of hold by construction, so a
   negative value means the constraint was not applied as written (e.g. `-clock_fall` not
   honoured). Fix the XDC, not the RTL, and re-route.
6. **The MCLK ODDR path:** replace the ODDR with a plain output of the toggle flop (a top-level
   change behind `PYNQZ2_CAM` only) and rebuild.
7. **Record.** The failing build's numbers go in §9 and the experiment log as a data point, with
   the fix, before any board session.

**Setup, for completeness.**
- `clk_fpga_0` WNS < 0: the existing opt-in `ROCKET_POSTROUTE_PHYSOPT=1` pass (added for `001C`)
  on a rebuild.
- `cam_pclk` WNS < 0 **only on input ports**: judged at 17.24 MHz per §4.2's rule. Accepted if
  every such path has slack + 15.1 ns > 0; the constraint is not edited.
- Anything else negative: not accepted.


### 7.4 Scored, 2026-09-17 11:33 (build `659c6db6`)

Predictions from §7.1 and §7.2, committed in `04d69e9` at 11:07, against the routed design.
**Seven of eleven inside their interval, four outside; two of the misses are in the design's
favour and one is not.**

| | 0010 | predicted (80 %) | **measured** | verdict |
|---|---:|---:|---:|---|
| Slice LUTs | 38,833 | +1,800 (+1,350…+2,300) | **41,080 (+2,247)** | **in**, near the top |
| Slice Registers | 22,343 | +1,600 (+1,200…+2,100) | **23,630 (+1,287)** | **in**, near the bottom |
| LUT as Memory | 2,951 | +300 (+250…+420) | **3,499 (+548)** | **OUTSIDE, high** |
| Block RAM tiles | 85.5 | +0.5 (0…+1.0) | **86.0 (+0.5)** | **in**, exactly |
| DSP48E1 | 90 | +0 | **90 (+0)** | **in** |
| Bonded IOB | 12 | +16 | **28 (+16)** | **in** |
| BUFGCTRL | 1 | +1 | **2 (+1)** | **in** |
| `clk_fpga_0` WNS | +0.458 | +0.35 (−0.05…+1.0) | **+1.126** | **OUTSIDE, high** (better than predicted) |
| `clk_fpga_0` WHS | +0.011 | +0.020 (+0.005…+0.050) | **+0.037** | **in** |
| `cam_pclk` WNS | — | +1.2 (−0.5…+3.0) | **−1.566** | **OUTSIDE, low** (worse) |
| `cam_pclk` WHS | — | +0.03 (+0.005…+0.30) | **+0.083** | **in** |

**The LUTRAM miss (+548 against +250…+420).** The 200T reference had the AsyncFifo's 1024×11
memory at 256 LUTRAM and I added ~50 for the small queues. Measured, `ospiLM` holds 470 LUTRAM:
the AsyncFifo's memory is distributed RAM as expected, but so are the DMA crossing's two TileLink
queues — `ram_2x121` (the A channel) alone is 279 LUT of which 72 are LUTRAM, and the pbus
buffer's `ram_2x85` another 56. I costed those as flops. It is inside the LUT total, which is why
that one still landed.

**The `clk_fpga_0` WNS miss is upward: +1.126 against a predicted +0.35, and against 0010's own
+0.458.** Adding 2,247 LUT made the worst path *better*, so this is placement variance, not an
effect of the camera: the critical path is the same L2 MSHR scheduler endpoint
(`tile_prci_domain/buffer/…` → `coh_wrapper/l2/…/mshrs_5/w_grant_reg`) that sets it on every build
of this family, and the archived spread for it at this size is +0.499…+1.754. **Nothing about the
camera is on it**, which is what the prediction should have said instead of a point near 0010's
value.

**The `cam_pclk` WNS miss is the real one, and §4.2's rule decides it (below).** I predicted the
input-port paths would land at +1.2 ns by assuming the sensor pins reach a flop in 2.5–4 ns. They
do not: they reach **seven levels of logic first** (the worst path is `cam_fvld` → IBUF → LUT4,
LUT5, LUT6 and three CARRY4 → the AsyncFifo's `wfullReg`), 5.582 ns of data path. The
CaptureFrontend's `lastOfLine`/`frameEnd` look-ahead and the FIFO's full/empty comparison are
combinational from the pins by construction. The clock side came out as expected (+5.529 ns of
insertion delay through the non-dedicated route, which is what pays for the 15.0 ns input delay).

### 7.5 The `cam_pclk` result, judged by §4.2's rule

The rule fixed before the build: *if the input paths show negative setup slack at 36 MHz, the build
is judged at the fastest PCLK this RTL can produce, 17.24 MHz; the constraint file is not changed
after the fact.* Measured on the routed checkpoint, analysis only
(`archive/builds/cam_z1_build_logs/timing_check.log`):

| | `cam_pclk` WNS | failing endpoints | `cam_pclk` WHS |
|---|---:|---:|---:|
| as built, 36 MHz (the datasheet maximum) | **−1.566 ns** | **387 of 2,286** | +0.083 ns |
| at 17.241 MHz (MCLKDIV = 0, the fastest MCLK this RTL makes) | **+13.544 ns** | **0** | +0.083 ns |
| at 5.747 MHz (MCLKDIV = 2, the lab's setting) | **+71.542 ns** | 0 | +0.083 ns |

**Every one of the 387 failing endpoints is on a path launched by a camera input port**: Vivado
reports 387 failing paths from `cam_d[*]`, `cam_fvld` and `cam_lvld`, and 387 failing in the domain
altogether, so no register-to-register path inside the PCLK domain fails. `clk_fpga_0` is
unaffected (+1.126 / +0.037).

So the build **meets timing at every PCLK the sensor can be driven at through this RTL**, and fails
only against a 36 MHz constraint that no configuration of this design can reach — the RTL's MCLK
tops out at 17.24 MHz and the HM01B0's 8-bit mode runs at about 6 MHz. It is accepted on that
basis, and the honest headline is: **`TIMING_WNS: -1.566` in the build log is the camera's input
budget at 36 MHz, not a path the hardware will ever exercise.**

What a future build should do instead of carrying a failing constraint: constrain `cam_pclk` at
57.998 ns (17.241 MHz) with the same input delays, which is the real bound, and keep 36 MHz only
as a documented what-if. That is a change to `src/pynqz2_cam.xdc` for the *next* build, not a
retrofit to this one.

---

## 8. Software

- **Zephyr board `chipyard_pynqz1_cam`** (`boards/chipyard/pynqz1_cam/`).
  - It is `chipyard_pynqz1_micrgb` with the PLIC numbers of this SoC: UART `<2 1>`, GPIO `<3 1>..<8 1>`.
  - It adds `&i2c0 { status = "okay"; interrupts = <1 1>; clock-frequency = <100000>; }`. The node
    itself is `dts/riscv/chipyard/chipyard-riscv.dtsi`'s, where it is disabled.
  - It adds an `ospi@10080000` node, with the binding and the `ucbbar` vendor prefix in the board's
    own `dts/bindings`.
  - The defconfig is micrgb's plus `CONFIG_I2C=y`. `CONFIG_I2C_SIFIVE` is default-y on the node, and
    its prescaler is `34483000 / (5·100000) − 1 = 67`.
  - A new board rather than an overlay: micrgb's UART line is the I²C controller's interrupt here.
- **The driver** is `fpga/pynq-z2/sw/cam/ospi_cam.{h,c}`: the register map, HM01B0 register
  helpers over two I²C callbacks, and `ospi_dma_capture_frame()` (§5.3).
- **The sample** is `samples/cam_capture`. It uses Zephyr's stock `i2c_sifive` through `i2c_write()`
  and `i2c_write_read()`, from the main thread only, and never calls `i2c_configure` (the driver
  configures from the DTS at init).
  - **Without the shield:** registers, idle diagnostics, a MODEL_ID read that must NACK, and an
    armed DMA that must stay BUSY for a second.
  - **With the shield:** MODEL_ID, MCLKDIV, `MODE_SELECT = 1`, PCLK Hz and fps from the counters, one
    whole frame via DMA, and an ASCII preview.
- **The lab** is `scripts/66_rocket_cam.sh` (Lab B27), modelled on Lab B25.
  - Gates: MAGIC `0x5A5A001E` plus the md5 gate (`CAM_ACCEPTED`, empty until the build is
    registered in `scripts/lib/bitstream_id.sh`), and `fclk.py --expect FCLK0=34.4828`.
  - It records the workstation and board clocks.
  - It checks that the built devicetree carries UART 2 / I²C 1 / ospi 9.
  - It refuses to treat 0 console bytes or PS_HOLDS as anything but a stop.
  - With a frame, it reads the bytes back over `/dev/mem` from the PS, compares the guest's
    checksum and writes `frame.pgm`.
  - A board without the shield is a PASS of the no-shield checks.
  - The HM01B0 init sequence the 200T used is not on this machine, so the sample writes only
    `MODE_SELECT`.

---

## 9. Board results

### 9.1 The build (2026-09-17 11:24–11:33, `659c6db6ecdbe091a7ff4494881f4e2e`)

Built from the vendored bundle with `CHIPYARD_DIR` unset, under `scripts/lib/with_lock.sh vivado`.
Gates before Vivado, all passing: the four PL simulations (34 + 44 + 16 + 24 checks), the engine
snapshot against `MD5SUMS` (7 of 7), and the camera RTL simulation log (§5).

- **Pins.** All 6 RGB and all **16 camera pins verified in the routed design** (`CAM_PIN:` lines
  from `get_package_pins -of_objects`, cross-checked against `report_io` by the build script), and
  **U13 (PUDC_B) carries no port**.
- **Area.** 41,080 LUT (77.2 %), 3,499 LUTRAM, 23,630 FF, 86.0 BRAM tiles, 90 DSP, 28 IOB, 2 BUFG.
  Per block, from `post_route_util_hier.rpt`: `ospiLM` **1,127 LUT (470 LUTRAM), 1,067 FF**, of
  which the DMA's two TileLink buffers are 480 LUT; `TLI2C` **116 LUT, 119 FF**.
- **Timing.** `clk_fpga_0` WNS **+1.126**, WHS **+0.037**; `cam_pclk` WNS **−1.566** (the input
  budget at 36 MHz, §7.5), WHS **+0.083**; `cam_mclk` has no timed paths. **WHS is positive on
  every clock**, so §7.3's plan was not needed.
- **CDC.** `report_cdc` flags the capture core's own crossings, and they are the expected ones:
  the AsyncFifo's distributed-RAM data path from the PCLK write side to the system read side
  (CDC-1 "unknown" ×95, CDC-13 ×11, CDC-15 ×85), and Gray/level synchronisers **without
  `ASYNC_REG`** (CDC-2, CDC-5, CDC-8) — `wgray`/`rgray`, the three diagnostic counters, `enableReg`,
  `overflow`, `sensorInt` and `busy`. The protocol is what makes them safe (Gray codes, 3-flop
  chains, data written before its pointer crosses), not the tool's analysis. **Follow-up:** the
  synchroniser flops carry no `ASYNC_REG`, so nothing forces the placer to keep each chain in one
  slice. That is a property of the `ospi` RTL, which this workstream does not edit; it can be fixed
  from the XDC (`set_property ASYNC_REG TRUE` on those cells) in the next build if wanted. At
  5.75 MHz PCLK against 34.48 MHz with three stages the MTBF is not a practical concern.
- **Reports:** `archive/builds/build_rocket_micrgb_roccmooncam_z1/reports/`, build logs
  `archive/builds/cam_z1_build_logs/`.

### 9.2 On the board, without the shield (Lab B27, 2026-09-17 11:45 workstation time)

**PASS.** One board session under `scripts/with_board.sh`: Lab B27, `archive_run.py rocket_cam`,
then the Lab 35 health check. The shield was not fitted (ordered 2026-09-15), which is the case
this run was for. `out/rocket_cam/run.json`, archived at `archive/runs/rocket_cam/`.

- **Identity.** MAGIC `0x5A5A001E` read back over GP0, bitstream md5 `659c6db6` gated by
  `bitstream_identify`/`bitstream_gate`. FCLK0 read back from the SLCR at **34.4828 MHz**
  (IO PLL 1000 MHz / 29). Board clock −43,228,347 s against the workstation, recorded in
  `clocks.json`; times here are the workstation's.
- **The console works, which is the first result.** The PLIC renumbering (§1.2) means the UART is
  source 2 on this SoC; the `chipyard_pynqz1_cam` board carries that, and the guest's output came
  back intact. A wrong number here would have looked like a hang.
- **Registers:** `CAM_REGS_CHECK ok=1`, CAPACITY 512, GEOM `0x00f40144`, DMA idle.
- **Bring-up diagnostics: `PCLKCNT = FVLDCNT = LVLDCNT = 0`, twice, 500 ms apart.** With no shield
  there is no MCLK load, no sensor and no PCLK: exactly the "no camera clock" signature the counters
  exist for, and the same values the simulation showed in standby.
- **I²C: a MODEL_ID read at 0x24 returned `-EIO` in 9 ms** — the NACK expected with nothing on the
  bus, the Z1's own 2.2 kΩ pull-ups holding the lines. The bus did not hang.
- **The DMA arm/timeout path reported cleanly:** armed with no PCLK, after 1,001 ms and 91 polls
  `DMA_STATUS = 0x11` (busy, state COLLECT), `DMA_BYTES = 0`, `PCLKCNT = 0`. **Identical to the
  simulation's section D.**
- **What it leaves behind:** `CAM_LEFT_ARMED transfer=busy cleared_by=soc_reset|pl_reload
  next_lab_action=none`. The transfer cannot be aborted (§5.3), and nothing downstream has to care:
  every program load resets the SoC through `soc_ctrl`, and loading any bitstream clears it.
- **Health check:** `scripts/35_rocket_rgb_leds.sh` at its defaults, in the same session,
  **reproduces its golden run** (0 bad readbacks, every mask distinct, host and guest agree).
  Archived at `archive/runs/rocket_rgb/`. An earlier attempt in the same session was run at
  `--cycles 1 --step-ms 400` and failed its golden on those two parameters alone, with every
  substantive check passing; it was re-run as specified.
- **One defect in this lab, fixed after the run:** `run.json`'s `post_route.whs` is empty. The
  parser looked for a line starting `WHS(ns)`, and Vivado's design summary puts WNS, TNS and WHS on
  one row under a single header, so WHS is column 5 of the WNS row. The value is **+0.037 ns**, from
  the build's own `timing_summary.rpt`. The row is left as recorded and corrected here rather than
  rewritten. (`scripts/51_rocket_roccmoon.sh` has the same parser; not this workstream's to change.)

### 9.3 With the shield: a runbook

**Not run — the shield was ordered 2026-09-15 and is not on the board.** This section is
self-contained: work from it alone. You need the repo, a host with Vivado for step 2, and the board.

**1. Fit the board.** The shield goes on the Z1's Arduino/chipKIT headers, component side up, with
`A5` at the corner nearest `IO0`'s row (`archive/drafts/PINMAP_riskybirdv3_pynq_camera_rev0.6.md`
has the orientation test). It takes 3V3 and ground from the power row and nothing else; the Z1 is
**not 5 V tolerant** on these pins. Check before power that the shield is not shifted by one
position — the row that would be under `IO2` is `PUDC_B`, tied to 3V3, and the PL never drives it.

**2. Rebuild first. TODO 16(b) is a precondition, and it is a decision to put to the coordinator
before building, with numbers: the LUT and timing cost of the change, and whether 16(a) goes into
the same build (it should — one rebuild, not two).**
`report_cdc` on the current build shows the capture core's Gray and level synchronisers carry no
`ASYNC_REG`, so nothing forces each chain into one slice (§9.1). With no shield PCLK never toggles
and it cannot matter; with a sensor attached it can. Add `ASYNC_REG` from `src/pynqz2_cam.xdc`
(`set_property ASYNC_REG TRUE` on the chains named in §9.1) or as a proposed change to the `ospi`
RTL, and report its LUT and timing cost. While rebuilding, take 16(a) as well: constrain `cam_pclk`
at **57.998 ns** (17.241 MHz, the fastest PCLK this design's MCLK can make) instead of 27.778 ns, so
the build's `TIMING_WNS` stops carrying an input budget at a frequency nothing can reach (§7.5).
Rebuild with `fpga/pynq-z2/scripts/build_roccmooncam_z1.sh`, and register the new md5 in
`scripts/lib/bitstream_id.sh` and in Lab B27's `CAM_ACCEPTED`. **The old md5 is not valid for a
shield run.**

**3. Run the lab.** `scripts/with_board.sh ./scripts/66_rocket_cam.sh`, then
`archive/tools/archive_run.py rocket_cam`, then `scripts/35_rocket_rgb_leds.sh` at its defaults, all
in the same session. `--mclkdiv 2` is the default and gives MCLK 5.747 MHz, the datasheet's 8-bit
QVGA-at-60-fps point (§3.2); `--mclkdiv 1` is 8.62 MHz if you want the sensor faster.

**4. First power-on: three things, in this order, before expecting a picture.**
1. **The right machine:** MAGIC `0x5A5A001E`, the md5 gate passing, FCLK0 read back at 34.4828 MHz.
   The lab refuses otherwise; if the console is silent, suspect the board definition, not the
   camera — this SoC's UART is PLIC source 2 (§1.2).
2. **The sensor answers:** `CAM_I2C_PROBE` returns `rc=0` and `CAM_SENSOR model_id=0x01b0`. A
   NACK (`rc=-5`) here means no shield, no power or no SDA/SCL — nothing downstream will work.
3. **The sensor clocks:** `PCLKCNT` is non-zero after `MODE_SELECT = 1`. It stays zero until MCLK
   reaches the sensor and the sensor leaves standby.

Only then is a frame worth looking at.

**5. What a working run looks like.** The line that changes first is `CAM_SHIELD present=1`,
because `CAM_I2C_PROBE` now returns `rc=0 model_id_h=0x01`. Then:

```
CAM_SENSOR   rc=0 model_id=0x01b0 ok=1
CAM_MCLK     mclkdiv=2 readback=2 hz=5747126
CAM_STREAM   mode_select=1 pclk_hz≈5-6 M  fps_x1000≈50000-60000  lines_per_frame≈244 or 324
CAM_FRAME    ok=1 bytes=width*height  attempts=1  dma_status=0x0a  min<max  mean_x100 plausible
CAM_PREVIEW  54 columns of ASCII that change when you put a hand over the lens
```

and the lab writes `out/rocket_cam/frame.pgm` after reading the same bytes back over `/dev/mem`
from the PS; `run.json`'s `ps_readback.matches_guest_sum` must be `true`. `dma_status = 0x0a` is
done + sawEof with no error. **Point the lens at something with contrast** — `min` and `max` a few
counts apart is a lens cap or a dark room, not a failure of the path.

**6. When it does not work, the counters say which half.** Read them from `CAM_DIAG` (before
streaming) and `CAM_STREAM` (after `MODE_SELECT = 1`):

| reading | what it means | where to look |
|---|---|---|
| `PCLKCNT` still **0** after `MODE_SELECT=1` | the sensor is not clocking: no MCLK reaching it, no power, or the sensor never left standby | check `CAM_MCLK` was written, then the shield's 3V3 and the MCLK path (U3, R2); `0xFF01` in simulation is the model's equivalent |
| `PCLKCNT` rises, **`FVLDCNT` 0** | pixel clock but no frame sync: the sensor is clocking and not reading out | the sensor's mode registers — this build writes only `MODE_SELECT`, so its window/format are reset defaults (§10 follow-ups) |
| `FVLDCNT` rises, **`LVLDCNT` 0** | frames but no lines: LVLD is not reaching the PL | A3/V11 and translator U2 |
| both rise, **`lines_per_frame`** not 244 or 324 | the sensor is in a window this build does not expect | read it back over I²C before trusting a frame; `GEOM` only feeds `geomErr` |
| `CAM_FRAME rc=-1` | the DMA never finished: it is armed and waiting for data | check `PCLKCNT` is still rising; the transfer cannot be aborted, so reset the SoC (any program load does) — §5.3 |
| `CAM_FRAME rc=-3` | frames arrive but the byte count or geometry disagrees with `GEOM` three times | the sensor's geometry is not what was asked for; use the `LASTWIDTH`/`LASTHEIGHT` the RTL measured |
| `CAM_FRAME rc=-2` | a Put was denied: the DMA target is not writable memory | the buffer must be in ExtMem and 8-byte aligned (§1.3) |
| `FLAGS` bit 1 (`overflow`) set | beats were dropped, or it is stale from an earlier session | it clears only when a one-cycle pulse lands across the PCLK crossing; re-issue `CTRL.clear`, and trust the byte count instead (§5.3) |
| I²C still NACKs at 0x24 | the sensor is not answering: power, or SDA/SCL | the Z1's own 2.2 kΩ pull-ups are on P15/P16; a scope on SCL should show ~112 kHz (§5.2), not 100 |

**7. What is still unknown, and what to try.** **The sensor runs from its reset defaults plus
`MODE_SELECT = 1`.** The HM01B0 init sequence the Arty-200T used is not on this machine (a full
search found the RTL and the FPGA shells, no camera software), so nothing here sets exposure, gain,
window, bit depth or `OSC_CLK_DIV`. Expect to have to set them. In order:
- read `LASTWIDTH`/`LASTHEIGHT` back and see what window the sensor actually sends — `CAM_STREAM`
  prints `lines_per_frame` for the same reason;
- if the image is black or saturated, the exposure and analogue gain registers (`0x0201`–`0x0205`
  in the HM01B0 map) are the first to set, over the same `hm01b0_write()`;
- `CAMERA_TASK.md`'s workload wants **324 × 324 raw Bayer**, which is the full frame, not the
  324 × 244 QVGA window this build's `GEOM` defaults to. `GEOM` only feeds `geomErr`; the capture
  core measures whatever arrives, so set `GEOM` to match the sensor rather than the other way
  round;
- if the 200T's init sequence turns up, prefer it to anything invented here, and put it in
  `fpga/pynq-z2/sw/cam/` so the RTL test and the board share it.

**8. What has never run.** *(Superseded 2026-09-21 by §9.5: frames have now been captured from
real silicon on both `0x5A5A001E` and `0x5A5A0038`. The paragraph is left as written, because
the runbook above is what the first capture was done from, and because two of its guesses were
wrong in ways worth keeping: the geometry is 326 x 324 bytes, not 324 x 244, and the first thing
to do when pixels look wrong is NOT to lower MCLK -- it is to read the sensor's own
FRAME_LENGTH_LINES, LINE_LENGTH_PCK and GRP_HOLD, which §9.5 does.)*

No frame has been captured from real silicon: everything in §5 is the
RTL against a model sensor, and §9.2 is a board with no shield. The first real capture is also the
first test of the shield, of the HM01B0's reset defaults, and of the 200 Ω series resistors on the
data bus at whatever PCLK the sensor picks — §4.2's input-delay budget is assumptions, not
measurements, and the first thing to do if pixels arrive corrupted is to lower MCLK
(`--mclkdiv 3`, 4.31 MHz) and see whether they clean up.


### 9.4 First contact with a sensor, and the prediction for the second run

**2026-09-21, garden (`xilinx@<board-ip>`), `0x5A5A001E`, md5 `659c6db6`,
`out/cam_bringup_garden.log`.** The sensor answered and streamed, and then the guest went
silent:

```
CAM_I2C_PROBE addr=0x24 rc=0 nack=0 model_id_h=0x01 ms=0      <- a sensor is on the bus
CAM_SENSOR    rc=0 model_id=0x01b0 ok=1
CAM_MCLK      mclkdiv=2 readback=2 hz=5747126
CAM_STREAM    ms=1001 pclk=2836159 fvld=13 lvld=4397 pclk_hz=2833325 fps_x1000=12987
              lines_per_frame=338 flags=0x08
<nothing more, for 40 s, and no CAM_RESULT>
```

So: **`MODEL_ID = 0x01B0`, `PCLK = MCLK / 2 = 2.833 MHz`, 13 frames/s, 338 LVLD pulses per
FVLD pulse, and `645.0` PCLK per LVLD pulse** (that last ratio is the precise one -- both
counts are large, where `fvld = 13` carries ±7.7 % quantisation).

**The diagnosis, from the code and the map file rather than from the board.**
`samples/cam_capture` called `ospi_dma_capture_frame(..., w = 324, h = 324, ...)`, and that
function armed the DMA with **`DMA_LEN = 0`, which the RTL reads as "run to the EOF marker"**
(`ClockSinkDomain_3.sv`: `lenReached = (|dmaLenReg) & bytesWritten + collectCount >= dmaLenReg`
-- with `dmaLenReg` zero there is no cap at all). The buffer was `324*324 + 64 = 105,040`
bytes. From that image's own `zephyr_final.map`:

```
.bss.frame  0x8000b780  0x19a50      <- ends at 0x800251d0
.bss.lock   0x800251d0  0x10         <- printk's spinlock, SIXTEEN BYTES PAST THE BUFFER
            0x80027070               <- z_main_stack, 7,840 bytes past it
```

If the sensor sends more than 104,976 bytes in a frame -- and 338 lines at 324 bytes would be
109,512 -- the DMA overwrites the console's lock and then kernel `.bss`, while the thread that
would report it is asleep in the poll loop. **Silence is the predicted symptom, not a
surprise.** The 40 s console window is not the cause: `CONFIG_SYS_CLOCK_TICKS_PER_SEC = 1000`
and the loop is 5,000 polls of `k_msleep(1)`, so a live guest would have printed `CAM_FRAME`
with `rc = -1` after about 5 s.

**Fixed, before the next run:** `ospi_dma_capture_frame()` and the new
`ospi_dma_capture_raw()` program `DMA_LEN = cap`, so the hardware stops at the end of the
caller's array whatever the sensor does; the sample's buffer is 256 KiB, sized from a bound
the sensor cannot exceed (one byte per PCLK, and PCLK/frame is measured); and nothing asserts
a geometry before `CAM_PROBE` has measured one.

**PREDICTIONS, committed before the run that tests them.**

1. **The blocker is the overrun.** `CAM_PROBE` will report `saweof=1` with
   `bytes > 104,976`. *Falsified if* `bytes <= 104,976` with `saweof=1`: the original call
   would then have fitted, and something else killed the guest.
2. **It is ONE byte per pixel, not two.** The coordinator's hypothesis -- that the colour
   part emits two bytes per pixel where the core expects one -- is predicted **false**.
   `CaptureFrontend` enqueues exactly one byte per PCLK while FVLD and LVLD are both high
   (`pixelValid = fvR & lvR & enable`), `CaptureParams` *requires* `dataWidth == 8`, and this
   repo's own workload study says a Bayer CFA costs no bytes on the wire
   (`CAMERA_TASK.md`: "a colour sensor in this class ... emits one byte per pixel, exactly as
   a monochrome part emits one byte of luminance"). The 645 PCLK per line is therefore
   predicted to be the **line period including horizontal blanking**, with LVLD high for only
   part of it. Quantitatively: `bytes/frame` will be **close to half of PCLK/frame**
   (218,167), i.e. `bytes_per_pclk` near 0.50, and `bytes / lines` will be near **324**.
   *Falsified if* `bytes/frame` approaches 218,000 (`bytes_per_pclk` near 1.0) with
   `bytes / lines` near 645 -- which would be the signature the two-bytes-per-pixel reading
   predicts, and would mean this build's RTL cannot capture this part without a mode change.
3. **The part is the colour variant.** The four Bayer-site means (even/odd row x even/odd
   column) will differ from each other by more than the frame's own noise, and the mean
   absolute difference between neighbours at lag 1 will EXCEED the one at lag 2, along rows
   and down columns -- the signature of a mosaic on a locally smooth image. *Falsified if*
   the four means agree and lag 1 < lag 2, which is what a monochrome part gives.
4. **The sensor's registers, not arithmetic, settle the geometry.** `CAM_SREG` will report
   `FRAME_LEN` (0x0340/1) and `LINE_LEN` (0x0342/3) at their reset defaults, since nothing in
   this repo has ever written them -- a full search of this machine found no HM01B0 init
   sequence at all.


### 9.5 Three frames out of real silicon, on two bitstreams, and what blocked the first one

**2026-09-21, garden (`xilinx@<board-ip>`), three sessions under `scripts/with_board.sh`.**
`archive/runs/rocket_cam@20260921T1421`, `rocket_cam@20260921T1427`,
`rocket_cam@20260921T1431`, `rocket_cam_all_f40`. Predictions in §9.4, commit `67085c2`.

#### What blocked the DMA, and the evidence

**`ospi_dma_capture_frame()` armed the DMA with `DMA_LEN = 0`, which this RTL reads as "run to
the EOF marker", into a buffer smaller than the frame.** Measured, three times on two
bitstreams: **the frame is 105,624 bytes.** The buffer was `324*324 + 64 = 105,040`. The
transfer therefore ran **584 bytes past the end of the array**, and in that image's own
`zephyr_final.map` the sixteen bytes after `frame` are `printk`'s spinlock:

```
.bss.frame  0x8000b780  0x19a50   -> ends 0x800251d0
.bss.lock   0x800251d0  0x10      <- printk's spinlock
            0x80027070            <- z_main_stack
```

So the console's own lock is destroyed while the thread that would report it is asleep in the
poll loop. Silence is the predicted symptom.

Three things rule out the alternatives:

- **It was not the 40 s console window.** `CONFIG_SYS_CLOCK_TICKS_PER_SEC = 1000` and
  `CONFIG_TICKLESS_KERNEL = y`, so the 5,000-poll loop with `k_msleep(1)` bounds at about
  5 s. A live guest would have printed `CAM_FRAME rc=-1` with 35 s to spare.
- **It was not a stalled or lost transfer.** With the length cap in, the same call completes
  in **61–74 polls** (about 70 ms), one attempt, `DMA_STATUS 0x0a` (done + sawEof, no error),
  `FLAGS.overflow` clear.
- **The dead guest left its fingerprint on the sensor.** The next session's `CAM_DIAG` read
  `pclkcnt0 = 717,269`, `fvldcnt0 = 4` *before writing anything*, and `MODE_SELECT` read back
  `0x01`: the previous run never reached its `MODE_SELECT = 0`, so the sensor had been
  free-running ever since.

Fixed in `fpga/pynq-z2/sw/cam/ospi_cam.c`: both capture entry points now program
`DMA_LEN = cap`. The hardware compares `bytesWritten + collectCount >= DMA_LEN`, so a
transfer cannot leave the caller's array; a frame that does not fit ends on the cap without
`sawEof` and is reported rather than written.

#### The sensor's real geometry, read from the sensor

`CAM_SREG`, over I²C, before anything was written to the part:

| register | value | |
|---|---|---|
| `MODEL_ID` 0x0000/1 | `0x01B0` | |
| `SILICON_REV` 0x0002 | `0x03` | |
| **`FRAME_LENGTH_LINES` 0x0340/1** | **`0x0232` = 562** | rows per frame, active + blanking |
| **`LINE_LENGTH_PCK` 0x0342/3** | **`0x0172` = 370** | PCLK per row |
| `X_ODD_INC` / `Y_ODD_INC` 0x0383/0x0387 | `0x01` / `0x01` | no sub-sampling |
| `BINNING_MODE` 0x0390 | `0x00` | no binning |
| **`BIT_CONTROL` 0x3059** | **`0x02`** | already 8-bit parallel; no mode change needed |
| `OSC_CLK_DIV` 0x3060 | `0x0A` | |
| `BLC2_TGT` 0x1003 | `0x20` = 32 | black level |
| `AE_CTRL` 0x2100 / `AE_TARGET` 0x2101 | `0x01` / `0x3C` = 60 | auto-exposure ON, target mean 60 |
| **`GRP_HOLD` 0x0104** | **`0x01`** | grouped parameter hold ENGAGED — see below |

And what the hardware measured, with no geometry asserted:

| | 0x5A5A001E, MCLKDIV 2 | 0x5A5A0038, MCLKDIV 3 |
|---|---|---|
| MCLK | 5.747 MHz | 5.000 MHz |
| PCLK | 2,833,318 Hz = MCLK/2 | 2,500,003 Hz = MCLK/2 |
| `DMA_BYTES` to EOF | **105,624** | **105,624** |
| `LASTHEIGHT` (LVLD pulses/frame) | **324** | **324** |
| `LASTWIDTH` (bytes in the last line) | **326** | **326** |
| PCLK per LVLD pulse | 635.9 | 640.0 |
| frames/s | 13.0 (±1 count) | **11.988** |

**Everything closes on the registers.** 562 rows × 370 PCLK = **207,940 PCLK per frame**; at
2,500,003 Hz that is **12.023 fps against 11.988 measured, 0.3 %**. Spread over the 324 rows
that carry LVLD it is **641.8 PCLK per LVLD pulse against 640.0 measured**. And
324 × 326 = **105,624 = `DMA_BYTES` exactly**.

**The first two bytes of every line are padding, not pixels.** Columns 0 and 1 have means of
**3.17 and 2.97** against a body mean of 49.9, with 9–11 distinct codes each — far below the
sensor's own black level of 32. So the pixel array is **324 × 324**, which is exactly the raw
Bayer frame `CAMERA_TASK.md` asks for, delivered on a **326-byte stride**.

#### Bytes per pixel: ONE. The two-bytes-per-pixel hypothesis is wrong

`105,624 bytes / (324 rows × 326 bytes) = 1.000`. The ratio that suggested two — ~645 PCLK per
LVLD pulse against a 324-pixel width — is the **frame period spread over the active rows**,
not the pixel rate: 238 of the 562 rows are vertical blanking and carry PCLK with no LVLD.
`bytes_per_pclk` is **0.508**, not 1.0.

This also could not have been otherwise. `CaptureFrontend` enqueues one byte per PCLK while
FVLD and LVLD are both high (`pixelValid = fvR & lvR & enable`), `CaptureParams` *requires*
`dataWidth == 8`, the part's own `BIT_CONTROL` already reads `0x02` (8-bit parallel), and this
repo's own workload study says a Bayer CFA costs nothing on the wire: "a colour sensor in this
class … emits one byte per pixel, exactly as a monochrome part emits one byte of luminance"
(`CAMERA_TASK.md`). **The camera was never sending two bytes per pixel and this build needs no
sensor mode change to capture it.**

#### Is it an image, or is it a bus?

The checksum gate passes — the PS reads the same 105,624 bytes back over `/dev/mem` and the
sums agree — but a checksum cannot tell a picture from a stuck bus. Four independent things
say it is a picture, and they are computed on the PS from the bytes the ARM read, not from the
guest's arithmetic:

1. **The console shows one.** `CAM_PREVIEW`'s 54 × 27 ASCII rendering has a dark left field, a
   bright structured right field and horizontal bands. It is not noise and it is not a fill.
2. **Neighbour statistics say MOSAIC.** Mean |difference| at lag 1 exceeds lag 2 in *both*
   directions, on both bitstreams: `001E` 4.65 > 3.53 along rows and 5.26 > 4.27 down columns;
   `0038` 8.29 > 4.39 and 8.36 > 5.25. Uniform noise gives lag 1 = lag 2 = 85.3; a constant or
   a stuck bus gives 0; a smooth non-mosaic image gives lag 1 *below* lag 2. Only a
   two-pixel-period pattern on a locally smooth image gives this.
3. **The 2 × 2 difference is MULTIPLICATIVE, which is a colour filter array and not an
   offset.** The four Bayer-site means, measured per image quadrant, spread by an amount that
   tracks how bright that quadrant is. On `0038`: spread **2.20** at a quadrant mean of 38.7,
   **17.78** at 81.5, **1.53** at 39.4, **24.58** at 94.2. Fitting `spread = k·(mean − B)`
   gives **B = 32.7** and k = 0.364 — and the sensor's own `BLC2_TGT` register reads
   **0x20 = 32**. The same fit on `001E` gives B = 32.5, k = 0.36. A fixed readout offset
   would give the same spread in every quadrant. The (even row, even column) site is the odd
   one out in every region, which is a CFA position, not a column artefact.
4. **The statistics move when the sensor is told to change.** With auto-exposure off and the
   analogue gain swept `0x00 → 0x10 → 0x20 → 0x30 → 0x00` on `0x5A5A0038`:

   | `ANA_GAIN` | 0x00 | 0x10 | 0x20 | 0x30 | 0x00 again |
   |---|---:|---:|---:|---:|---:|
   | frame mean | 63.46 | 77.44 | 82.02 | 88.77 | 65.01 |
   | saturated pixels | 3,501 | 6,495 | 12,023 | 17,511 | 3,765 |

   Strictly monotone, and it comes back. On `0x5A5A001E` the same sweep drove the saturated
   count **2,137 → 3,716 → 4,927 → 8,325** and back to 2,137, with the mean less clean because
   clipping compresses it.
5. **And one that was free.** In the very first frame, auto-exposure was still ON with
   `AE_TARGET = 0x3C = 60`, and the measured frame mean was **59.909** — the sensor's own
   control loop holding the picture at the number in its register, to 0.15 %.

**Nobody was at the bench.** The lens was not covered, uncovered or moved, and no illumination
was changed. Everything above is a change made over I²C or read out of the sensor's own
registers.

#### Two things that did not work, stated plainly

- **`IMAGE_ORIENTATION` (0x0101) does not flip the readout on this part.** The write is ACKed
  and the register reads back `0x03`, but the frame that follows correlates **+0.787** with
  the baseline as-is and **−0.279** with the baseline rotated 180° (`0x5A5A0038`; `001E`
  gives +0.577 / −0.117). So the geometric proof that the bytes follow the sensor's readout
  ORDER is **not** obtained. Either 0x0101 is not image orientation on this silicon, or it
  needs more than a grouped-hold release. The gain sweep carries the "it follows the sensor"
  claim instead.
- **Grouped parameter hold was found ENGAGED (`0x0104 = 0x01`) and nothing in this repo had
  ever written it.** That is why the first attempt's `IMAGE_ORIENTATION` and `ANALOG_GAIN`
  writes were ACKed and changed nothing — they sat pending in the part — and why the *next*
  session's first hold-release applied them in the middle of an unrelated test, moving the
  frame mean 59.96 → 112.11. **Any sequence that writes this sensor must release the hold and
  must not assume the part starts where the last session left it.** `samples/cam_capture` now
  normalises AE, gain, integration and orientation before it measures anything.

#### The PS does not see the frame until the L2 lets go of it

The capture DMA is a TileLink master on the front bus, so its Puts land in the **L2
InclusiveCache** (§1.3). That is what makes both harts coherent and is exactly why the ARM is
not: the PS reads physical DRAM from outside that cache. Run 1's **second** frame came back
from `/dev/mem` differing from the guest's checksum by **21,906 counts over 105,624 bytes**,
while the first matched — because by then three later captures had evicted the first. There is
no cache-control node in this SoC's devicetree, so `samples/cam_capture` now reads 4 MiB at
`0x8800_0000` before it finishes, and both frames have matched in every run since. **Any lab
that DMAs into DDR and then reads it from the PS needs this.**

#### Scored against §9.4

| prediction | outcome |
|---|---|
| 1. the blocker is the overrun: `saweof=1` with `bytes > 104,976` | **HELD.** 105,624 with `saweof=1`, 584 bytes past the old buffer |
| 2. one byte per pixel, `bytes_per_pclk` near 0.50, `bytes/lines` near 324 | **HELD.** 0.508, and 326 bytes per line of which 324 are pixels |
| 3. colour: the four Bayer sites differ, lag 1 > lag 2 both ways | **HELD**, and strengthened — the site spread is multiplicative above a fitted black level of 32.7 against the part's own `BLC2_TGT` of 32 |
| 4. `FRAME_LEN` and `LINE_LEN` at reset defaults, no init sequence anywhere | **HELD.** 562 and 370, never written by anything here |

#### What is proven, and on what

**Four combinations, two boards, two bitstreams, all PASS.** `PYNQ_HOST` set explicitly on every
one, and `run.json` now carries `board` and `pynq_host` so a row cannot silently cross boards.

| | `0x5A5A001E` `659c6db6` | `0x5A5A0038` `ced0aab0` |
|---|---|---|
| Zephyr board | `chipyard_pynqz1_cam` | `chipyard_pynqz1_all_f40` |
| FCLK0 | 34.4828 MHz | 40.0000 MHz |
| ospi PLIC source | 9 | 13 |
| MCLK / PCLK | 5.747 / 2.833 MHz | 5.000 / 2.500 MHz |
| board A | frame, `sawEof`, checksum match | frame, `sawEof`, checksum match |
| board B | frame, `sawEof`, checksum match | frame, `sawEof`, checksum match |
| geometry, every run | `DMA_BYTES` 105,624 = 326 x 324 | `DMA_BYTES` 105,624 = 326 x 324 |
| mosaic statistics (lag1 > lag2 both ways) | yes on both boards | yes on both boards |
| gain sweep monotone | garden: saturated count only; illixr: **both** | **mean and saturated count**, both boards |
| Lab 35 health check, same session | reproduces its golden run | reproduces its golden run |

Frame means differ by board because the two cameras look at different scenes -- garden's frame
has 9-11 distinct codes in its first image columns against illixr's 97-108 -- which is itself a
small piece of evidence that these are pictures of two rooms and not an artefact of the path.

**Still unproven:** the readout-order flip; anything needing somebody at the bench (the lens was
never covered, uncovered or moved, and no illumination was changed); the Bayer PHASE, because
`PIXEL_ORDER` (0x0004) reads `0xFF`, so which site is R and which is B is not established --
only that the four differ multiplicatively; and any use of the frame, since `frame_fe.h`'s front
ends want a packed 324 x 324 array and what arrives has a 326-byte stride.

---

## 10. Follow-ups

- The shield's PL UART (Y11/Y12) and PL JTAG (R17/P18/N17/Y13) (§2).
- `0x5A5A001F`, the same camera on the plain micrgb SoC: reserved, and built only if asked.
- The 200T's HM01B0 init sequence and Zephyr driver, when located. Until then the sensor runs from
  its reset defaults plus `MODE_SELECT`. A full search of this machine on 2026-09-21 found no
  HM01B0 register table of any kind, in any tree; §9.5's normalisation (grouped-hold release, AE
  off, a known gain, integration and orientation) is the nearest thing that exists.
- **`IMAGE_ORIENTATION` (0x0101) does not flip the readout** (§9.5). It ACKs and reads back, and
  the picture does not move. Worth settling against the datasheet, because a workload that wants
  a particular Bayer phase will care.
- **The capture core's `pixCol`/`rowCnt`/`LASTWIDTH`/`LASTHEIGHT` are nine bits**
  (`CaptureParams.pixCountWidth = log2Ceil(maxWidth + 1)` with `maxWidth = 324`). The part sends
  **326** bytes per line, so `LASTWIDTH` is already only 2 short of wrapping, and anything wider
  than 511 would read back modulo 512. `DMA_BYTES` is 32 bits and is the number to trust. A next
  build should widen those counters.
- **Nothing has yet used the frame.** `frame_fe.h`'s front ends want a 324x324 array; what
  arrives is 324x324 pixels on a **326-byte stride** with two padding bytes at the start of every
  line, and no caller of `frame_fe_*` knows that yet.
