package chipyard

import chisel3._
import org.chipsalliance.cde.config.Config

// PYNQ-Z2 (XC7Z020) target: Rocket + TACIT, memory served by the Zynq PS over S_AXI_HP0.
//
// Shape of the target, and why:
//
//   * NO FPU. The device has 53,200 LUTs. Measured on the Arty-200T builds, Rocket's FPU
//     is 13,878 LUTs on its own -- dropping it is what takes the design from ~87% to a
//     routable ~61%. Soft-float is fine for a trace demo.
//
//   * ExtMem 256 MB at the Chipyard-default 0x8000_0000. The PS DDR window is
//     0x0010_0000-0x1FFF_FFFF, so the FPGA top folds 0x8000_0000 into the upper 256 MB
//     with the ucb-bar/fpga-zynq truncation, {4'd1, addr[27:0]}. Keeping the SoC-side base
//     at Chipyard's default avoids colliding with the bootrom/CLINT/PLIC/TACIT MMIO that
//     live low in the map.
//
//   * ExtMem id bits <= 6. S_AXI_HP0's AWID/ARID/WID are 6 bits wide; anything wider gets
//     silently truncated at the port and returns responses to the wrong master.
//
//   * L2 shrunk to 64 KB. MEASURED: the Chipyard default L2 puts this design at
//     140/140 BRAM36 -- 100%, i.e. unroutable -- and 86.4% LUT. 630 KB of block RAM is
//     simply not enough for a default-sized inclusive cache plus L1s -- WithInclusiveCache
//     defaults to capacityKB = 512, which is ~114 BRAM36 of data alone. 64 KB / 4 ways is
//     the largest that leaves headroom for the L1s and TACIT.
//     (WithNBanks(0) to delete L2 outright does NOT work here: it removes the memory bus
//     with it and elaboration dies with "key not found: Location(mbus)", because both the
//     AXI4 mem punchthrough and TACIT's TraceSinkDMA master attach there. That route needs
//     WithIncoherentBusTopology as well.)
//
//   * TACIT encoder + DMA sink. WithTacitEncoder maps over every tile (one encoder at
//     0x3000000 + tileId*0x1000); WithTraceSinkDMA gives each a TL master that writes the
//     encoded trace into DDR, which on this board means into PS DRAM over the same HP0
//     port the core uses.
class PynqZ2RocketTacitConfig extends Config(
  new tacit.WithTraceSinkDMA(1) ++
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 4, capacityKB = 64) ++
  new chipyard.WithTacitEncoder ++
  new chipyard.config.WithExtMemIdBits(4) ++
  new freechips.rocketchip.subsystem.WithExtMemSize(BigInt(0x10000000L)) ++   // 256 MB
  new freechips.rocketchip.rocket.WithoutFPU ++
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new chipyard.config.AbstractConfig)

// Same, without TACIT -- the area baseline, so the encoder's cost on this device is a
// measurement rather than a carry-over from the Arty numbers.
class PynqZ2RocketConfig extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 4, capacityKB = 64) ++
  new chipyard.config.WithExtMemIdBits(4) ++
  new freechips.rocketchip.subsystem.WithExtMemSize(BigInt(0x10000000L)) ++
  new freechips.rocketchip.rocket.WithoutFPU ++
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new chipyard.config.AbstractConfig)

// Rocket + TACIT + HM01B0 camera. The question this answers is whether the structural-top
// approach scales to a peripheral with real sensor pins, or whether it only worked because
// the first build's only PL-facing signals were UART.
//
// It scales, and the reason is that Chipyard already separates the two concerns:
//   * WithOspiPunchthrough is an OverrideIOBinder -- it punches the capture core's
//     SensorIO out as ChipTop ports (`ospi_sensor_*`), exactly as WithUARTIOCells does for
//     the UART. It is NOT in AbstractConfig, so it has to be named explicitly.
//   * WithI2C adds the TLI2C the sensor's 0x24 control interface needs; the capture core
//     deliberately does not do I2C itself.
// Neither needs an fpga-shells shell, and neither needs the harness. The structural top
// wires ospi_sensor_* to package pins through the XDC like any other port.
//
// frameBufferDepth is line-sized, not frame-sized, on purpose: the default 324*324+1 is
// ~1.15 Mb (~32 BRAM36), and the Rocket build already sits at 58 of this device's 140.
// With enableDma the frame streams to DDR, so a line of buffering is all that is wanted.
// Tie the sensor inputs off in the simulation TestHarness. This is NOT a structural-top
// concern -- the FPGA top drives these from package pins -- but Chipyard's generator always
// elaborates the TestHarness alongside ChipTop, and Chisel refuses to finish with an
// uninitialised sink:
//   error: sink "chiptop0.ospi_sensor_pclk" not fully initialized in "TestHarness"
// Same shape as the stock chipyard.harness.WithI2CTiedOff.
class WithOspiTiedOff extends chipyard.harness.HarnessBinder({
  case (th: chipyard.harness.HasHarnessInstantiators, port: chipyard.iobinders.OspiPort, chipId: Int) => {
    port.getIO() <> DontCare
  }
})

class PynqZ2RocketTacitCamConfig extends Config(
  new WithOspiTiedOff ++
  new chipyard.iobinders.WithOspiPunchthrough ++
  new ospi.WithOspiCaptureDma(frameBufferDepth = 512) ++
  new chipyard.config.WithI2C ++
  new PynqZ2RocketTacitConfig)

// Rocket + TACIT + UART-TSI program loader.
//
// ANSWERING "do we need additional IP for UART-TSI?": yes, but all of it is in-tree
// testchipip RTL -- nothing to buy, nothing to write. WithUARTTSIClient instantiates
// (see testchipip/src/main/scala/tsi/PeripheryUARTTSI.scala):
//
//   * UARTToSerial      -- a raw UART SerDes, NOT the full sifive UART peripheral. It has
//                          no MMIO registers; it just turns the wire into a byte stream.
//   * SerialWidthAdapter -- 8-bit UART bytes to TSI's phit width.
//   * TSIToTileLink     -- a TileLink MASTER (TLClientNode) coupled into a bus with
//                          `tlbus.coupleFrom("uart_tsi")`. This is the part that matters:
//                          the loader writes memory directly as a bus master, which is how
//                          it can place a program in DRAM with the core still in reset.
//
// So it is a second, dedicated UART plus a bus master -- it does not share the console
// UART, and on a carrier with only one spare UART that is the binding constraint. On
// PYNQ-Z2 that is fine: PS UART1 over EMIO is the spare, and the TSI host on the ARM gets
// both program loading and console over the one link.
class PynqZ2RocketTacitTsiConfig extends Config(
  new chipyard.iobinders.WithUARTTSIPunchthrough ++
  new testchipip.tsi.WithUARTTSIClient ++
  new PynqZ2RocketTacitConfig)

// ---------------------------------------------------------------------------------------
// Dual-core big.LITTLE, RV64, for the PYNQ-Z1 (xc7z020clg400-1).
//
// Why Rocket-on-Rocket rather than Rocket+VexiiRiscv or an RV32 pair (the two options
// docs/ACCELERATOR_FIT.md recommends): both alternatives buy a few points of LUT at a
// software cost this tutorial cannot absorb.
//
//   * RV32 big+little measured 65.7 % in-context, but moves the ABI to ilp32 -- a new
//     Zephyr SoC/board pair and a rebuild of every ModelBlaster backend.
//   * VexiiRiscv is RV64 but a different core family; Zephyr SMP across Rocket+Vexii is
//     unverified, and the two harts would not share a microarchitecture-independent
//     privilege setup.
//
// WithNBigCores + WithNSmallCores is the same core family, the same ISA and the same
// M-mode setup, so ONE Zephyr SMP image covers both harts and the existing
// `rocketchip_virt_riscv64` SoC layer needs no change beyond CONFIG_MP_MAX_NUM_CPUS.
//
// TILE ORDER MATTERS. CDE applies the RIGHTMOST fragment first, and each of these
// fragments prepends its tiles with `tileId = i + up(NumTiles)`. So with
// `WithNSmallCores(1) ++ WithNBigCores(1)`:
//
//   WithNBigCores(1)   runs first -> big   gets tileId 0
//   WithNSmallCores(1) runs next  -> small gets tileId 1
//
// hart 0 is therefore the BIG core. That is what we want: the bootrom releases hart 0
// first (CustomBootPin writes hart 0's MSIP and hart 0 then wakes the rest), and Zephyr's
// CONFIG_RV_BOOT_HART defaults to 0 -- so the primary CPU running main() is the big core
// and the little core is the one brought up by arch_cpu_start().
//
// The LITTLE core (WithNSmallCores) is: useVM = false, no FPU, no BTB, 1-way 64-set L1I
// and L1D with a 1-set/4-way TLB. It is the same RV64IMAC ISA as the big core minus
// supervisor mode, which Zephyr does not use here (it runs in M-mode, CONFIG_RISCV_PMP=n).
//
// Everything else is held identical to PynqZ2RocketTacitConfig: WithoutFPU (the FPU is
// 13,878 LUT on its own), the 64 KB/4-way L2 (the default 512 KB L2 is 140/140 BRAM36 and
// unroutable), 256 MB ExtMem and 4-bit ExtMem IDs for the AXI3 bridge.
class PynqZ2RocketBigLittleTacitConfig extends Config(
  new tacit.WithTraceSinkDMA(1) ++
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 4, capacityKB = 64) ++
  new chipyard.WithTacitEncoder ++
  new chipyard.config.WithExtMemIdBits(4) ++
  new freechips.rocketchip.subsystem.WithExtMemSize(BigInt(0x10000000L)) ++   // 256 MB
  new freechips.rocketchip.rocket.WithoutFPU ++
  new freechips.rocketchip.rocket.WithNSmallCores(1) ++    // hart 1 -- LITTLE
  new freechips.rocketchip.rocket.WithNBigCores(1) ++      // hart 0 -- big, boot hart
  new chipyard.config.AbstractConfig)

// Same pair without TACIT. WithTacitEncoder maps over EVERY tile, so a second core also
// buys a second encoder (1024-entry branch predictor each) and a second DMA sink. This is
// the fallback if the pair with TACIT does not fit, and the measurement that prices it.
class PynqZ2RocketBigLittleConfig extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 4, capacityKB = 64) ++
  new chipyard.config.WithExtMemIdBits(4) ++
  new freechips.rocketchip.subsystem.WithExtMemSize(BigInt(0x10000000L)) ++
  new freechips.rocketchip.rocket.WithoutFPU ++
  new freechips.rocketchip.rocket.WithNSmallCores(1) ++
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new chipyard.config.AbstractConfig)

// MBP-PEXT-CONFIG-BEGIN
// Everything below this line needs patches/0008-rocket-pext-alu.patch in the rocket-chip
// generator: it names RocketCoreParams.usePExt, which does not exist without it. The
// sentinel above is not decoration -- scripts/09_patch_rocket_pext.sh --verify truncates
// this file here while it elaborates the PRE-patch baseline, because a tree with the patch
// reverted and this block still present does not compile.
// ---------------------------------------------------------------------------------------
// MBP packed SIMD on the BIG hart only.
//
// Four R-type ops in custom-0 (DOT8, MAX8, QMUL, CLIP8), integrated into Rocket's ALU as
// single-cycle two-read instructions rather than bolted on as a RoCC accelerator. The
// contract is fpga/pynq-z2/sw/pext.h; the specification and the evidence are
// fpga/pynq-z2/docs/PEXT_SPEC.md; the cost menu is PEXT_FEASIBILITY.md.
//
// WHY ALU-INTEGRATED AND NOT RoCC. Measured (PEXT_FEASIBILITY.md section 3): RoCC's
// cmd.valid only fires at WB, so a result is three cycles late, it is scoreboarded and
// cannot be bypassed, and the plumbing is ~984 LUT before any datapath exists. For an op
// whose whole purpose is to sit in the middle of a MAC loop, that is the wrong attachment.
//
// WHY ONLY TILE 0. TileAttachConfig.atTileIds(0) keeps the modification when
// tileIdOpt.contains(tp.tileParams.tileId) and passes every other tile through unchanged,
// so hart 1's Rocket has no PExtDecode table and no SIMD datapath. Executing one of these
// on hart 1 raises an illegal-instruction exception -- that is the INTENDED behaviour and
// the heterogeneity mechanism, not a degradation path. samples/pext_rtl_selftest proves
// both halves in Verilator.
//
// TWO TRAPS, BOTH LOAD-BEARING:
//
//   * atTileIds(0) is correct ONLY because tile 0 is the big core, and tile 0 is the big
//     core only because CDE applies the RIGHTMOST fragment first: in
//     PynqZ2RocketBigLittleTacitConfig, WithNBigCores(1) runs before WithNSmallCores(1) and
//     so takes tileId 0. Flip those two lines and the LITTLE hart silently gets the SIMD
//     unit -- and it will still elaborate, build and boot.
//
//   * An EMPTY tileIdOpt means "every tile" (see TileAttachConfig's partialFn), so
//     dropping the .atTileIds(0) does not disable the fragment, it applies it everywhere.
//
// THE CLOCK. Depth-3 DOT8 is single-cycle at 28.571 ns (35 MHz) and is not at 25 ns
// (40 MHz). This config is meant to be built at 35 MHz; see PEXT_FEASIBILITY.md section 2
// and the measurements in fpga/pynq-z2/rtl_study/pext/ooc_out/.
class WithPExtOnTiles(ids: Int*) extends Config(
  new freechips.rocketchip.subsystem.TileAttachConfig[freechips.rocketchip.subsystem.RocketTileAttachParams](
    tp => tp.copy(tileParams = tp.tileParams.copy(core = tp.tileParams.core.copy(usePExt = true)))
  ).atTileIds(ids: _*))

class PynqZ2RocketBigLittlePextTacitConfig extends Config(
  new WithPExtOnTiles(0) ++                   // hart 0 -- the big core -- only
  new PynqZ2RocketBigLittleTacitConfig)

// ---------------------------------------------------------------------------------------
// ... and the same thing with the board's PDM microphone attached.
//
// WHY THIS IS THE CONFIG WORTH BUILDING, and not a microphone-only variant: the workload
// audio exists for on this SoC is keyword spotting, and that wants MBP on hart 0. So the
// microphone is added to the P-ext config rather than beside it. (MBP claims custom-0 and
// RocketCore.scala refuses usePExt together with RoCC -- irrelevant here, because a
// periphery-bus peripheral is not a RoCC accelerator, but worth knowing before anyone
// tries to make it one.)
//
// THE SHAPE IS PynqZ2RocketTacitCamConfig's, deliberately, and for the same three reasons:
//   * WithPdmMicPunchthrough is an OverrideIOBinder -- it punches the peripheral's two
//     pins out as ChipTop ports (`mic_pdm_clk`, `mic_pdm_data`). It is NOT in
//     AbstractConfig, so it has to be named explicitly.
//   * WithPdmMic hangs a TLRegisterNode off the periphery bus at 0x1009_0000. That address
//     is clear of the bootrom (0x1_0000), CLINT (0x200_0000), the L2 control port
//     (0x201_0000), TACIT (0x300_0000 / 0x301_0000), the PLIC (0xC00_0000), the UART
//     (0x1002_0000), DRAM (0x8000_0000) -- and of 0x1008_0000, which the camera uses.
//   * WithPdmMicTiedOff is the harness tie-off, below, and is not optional.
//
// WHAT IT DOES NOT ADD is an interrupt. pdmmic.PdmMic deliberately has no IntSourceNode:
// this SoC's PLIC has exactly one source and `riscv,ndev = <1>`, which is transcribed into
// boards/chipyard/pynqz1_pext's devicetree as `interrupts = <1 1>` on the UART. Adding a
// second source changes ndev, changes the generated DTS, and buys nothing at 32 kB/s with
// a 64 ms FIFO. The driver polls. See fpga/pynq-z2/docs/MICROPHONE.md.

// Tie the microphone's data pin off in the simulation TestHarness. Same reason as
// WithOspiTiedOff above: the FPGA top drives it from a package pin, but Chipyard always
// elaborates the TestHarness alongside ChipTop and Chisel refuses to finish with an
// uninitialised sink --
//   error: sink "chiptop0.mic_pdm_data" not fully initialized in "TestHarness"
class WithPdmMicTiedOff extends chipyard.harness.HarnessBinder({
  case (th: chipyard.harness.HasHarnessInstantiators, port: chipyard.iobinders.PdmMicPort, chipId: Int) => {
    port.getIO() <> DontCare
  }
})

class PynqZ2RocketBigLittlePextTacitMicConfig extends Config(
  new WithPdmMicTiedOff ++
  new chipyard.iobinders.WithPdmMicPunchthrough ++
  new pdmmic.WithPdmMic(address = 0x10090000L) ++
  new PynqZ2RocketBigLittlePextTacitConfig)

// ---------------------------------------------------------------------------------------
// ... and the same thing again with the board's two RGB LEDs reachable from software.
//
// THERE IS NO NEW HARDWARE HERE AND THAT IS THE POINT.  Every piece of this is stock
// Chipyard, which is why it costs a fraction of what the microphone did:
//
//   chipyard.config.WithGPIO            the sifive GPIO controller (rocket-chip-blocks
//                                       generators/rocket-chip-blocks/.../devices/gpio),
//                                       a TLRegisterNode on the periphery bus. Already
//                                       mixed into DigitalTop as HasPeripheryGPIO.
//   chipyard.iobinders.WithGPIOPunchthrough
//                                       brings the GPIOPortIO bundle straight out of
//                                       ChipTop with no IOCells -- the same shape as
//                                       WithPdmMicPunchthrough. It is an OverrideIOBinder,
//                                       so it REPLACES AbstractConfig's WithGPIOCells
//                                       (which would have made six Analog inout pads and
//                                       an IOBUF apiece).
//   chipyard.harness.WithGPIOPinsTiedOff
//                                       already in AbstractConfig. No tie-off fragment is
//                                       needed here, unlike WithPdmMicTiedOff above.
//
// So this config adds no patch to the Chipyard generator at all.  Contrast
// patches/0012-chipyard-pdm-mic.patch, which had to add four files, because a PDM
// decimator is not a device Chipyard ships and a GPIO controller is.
//
// SIX PINS, IN THE VENDOR'S BIT ORDER.  width = 6, and bits 0..5 are wired in
// fpga/pynq-z2/src/pynqz2_rocket_top.v to L15/G17/N15/G14/L14/M15 -- which is
// LD4{B,G,R}, LD5{B,G,R}.  That order is not ours: it is the order Digilent's
// Arty-Z7-20-Master.xdc gives (Sch=LED4_B .. Sch=LED5_R) and the order Xilinx's own PYNQ
// RGBLED class assumes (RGB_BLUE=1, RGB_GREEN=2, RGB_RED=4, three bits per LED, LD4
// first).  Two independent vendor sources, and they agree.  See
// fpga/pynq-z2/docs/RGB_LEDS.md section 1.
//
// 0x1001_0000 is Chipyard's own default GPIO address and is clear of everything in this
// SoC: bootrom 0x1_0000, CLINT 0x200_0000, L2 control 0x201_0000, TACIT 0x300_0000 /
// 0x301_0000, PLIC 0xC00_0000, UART 0x1002_0000, the microphone 0x1009_0000, the address
// CAMERA_PCB_SPEC.md reserves at 0x1008_0000, and DRAM 0x8000_0000.
//
// WHAT THIS DOES ADD, unlike the microphone, IS INTERRUPTS.  sifive's GPIO declares
// nInterrupts = width and GPIOAttachParams.attachTo binds them unconditionally, so the
// PLIC grows from riscv,ndev = <1> to <7>.  That is not optional and there is no fragment
// to turn it off.
//
// MEASURED, from the generated DTS rather than assumed -- and it is the reassuring answer:
//
//     serial@10020000   interrupts = <1>              <- UNCHANGED
//     gpio@10010000     interrupts = <2 3 4 5 6 7>
//     interrupt-controller@c000000   riscv,ndev = <7>
//
// The UART keeps PLIC source 1, so boards/chipyard/pynqz1_micrgb's `interrupts = <1 1>`
// is pynqz1_mic's line verbatim and the console cannot have been disturbed.  The six GPIO
// sources are appended ABOVE it.  It still needs its own board definition, because the
// GPIO node and riscv,ndev are new -- and its own MAGIC, because an image built for
// pynqz1_mic boots here perfectly and finds nothing at 0x1001_0000.
class PynqZ2RocketBigLittlePextTacitMicRgbConfig extends Config(
  new chipyard.iobinders.WithGPIOPunchthrough ++
  new chipyard.config.WithGPIO(address = 0x10010000L, width = 6) ++
  new PynqZ2RocketBigLittlePextTacitMicConfig)

// ---------------------------------------------------------------------------------------
// The full-feature SoC plus a TileLink BANDWIDTH INSTRUMENT on the system bus.
//
// WHY IT IS ON TOP OF THE FULL-FEATURE CONFIG rather than a stripped one: the numbers
// only transfer to the workloads if the memory system is the one the workloads run on --
// the same 64 KB inclusive L2, the same AXI4-to-AXI3 shim, the same PS DDR window and
// the same two harts competing for it.  A minimal SoC would measure a different machine
// and the comparison with MEMORY_HIERARCHY.md's 1.34 B/cycle would be an argument rather
// than a measurement.
//
// WHAT IT ADDS, AND WHAT IT DOES NOT.  chipyard.bwprobe.WithBwProbe attaches through a
// testchipip SubsystemInjector, so it needs NO change to DigitalTop, no IOBinder, no
// punched-out pin and no XDC edit.  The delta against
// PynqZ2RocketBigLittlePextTacitMicRgbConfig is one TLClientNode on the sbus, one
// TLRegisterNode on the pbus at 0x100A_0000, and the mbxd_dma.v BlackBox between them.
// Nothing else in the SoC moves.
//
// SOC_MAGIC for this configuration is 0x5A5A0007 (tcl/build_rocket.tcl).
class PynqZ2RocketBigLittlePextTacitMicRgbBwConfig extends Config(
  new chipyard.bwprobe.WithBwProbe(address = 0x100a0000L, depth = 8) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbConfig)

// ---------------------------------------------------------------------------------------
// LEVER 2: give the MEMORY BUS its own clock, so the AXI path is not held to the core's.
//
// THE WHOLE PL RUNS AT 34.4828 MHz BECAUSE OF THE P-EXTENSION'S CRITICAL PATH.  PEXT
// FEASIBILITY.md section 2.6 and PEXT_BITSTREAM.md record that: QMUL's DSP cascade is the
// extension's worst path, and the design's own worst path is the L2 MSHR scheduler.
// Neither of those is in the AXI4-to-AXI3 shim, the mbus crossbar or the TLToAXI4
// converter -- they inherit the ceiling for no reason of their own, and
// MEMORY_BANDWIDTH.md section 2 measured the consequence: the L2 path saturates its
// 64-bit link at EXACTLY 8.00 B/cycle, so its ceiling IS the clock.
//
// THREE THINGS HAVE TO HAPPEN TOGETHER AND ONLY ONE OF THEM IS OBVIOUS.
//
//   1. WithMemoryBusFrequency ONLY SETS dtsFrequency.  It does not create a crossing and
//      it does not, on its own, give the mbus a different clock.  Believing otherwise is
//      the whole risk in this lever.
//   2. The crossing is SbusToMbusXTypeKey, which BusTopology.scala:53 defaults to
//      NoCrossing.  It has to become AsynchronousCrossing() or the two domains are wired
//      together through a plain wire and the design is simply wrong.
//   3. AbstractConfig's WithClockGroupsCombinedByName puts "mbus" in the SAME group as
//      sbus, pbus, cbus, fbus, obus and implicit -- which is exactly why ChipTop has one
//      clock port, `clock_uncore`.  WithPassthroughClockGenerator emits ONE PORT PER GROUP
//      MEMBER, so splitting mbus into its own group is what creates `clock_mem`.  It is
//      not something that has to be hand-wired, and hand-wiring it would be the mistake.
//
// ClockGroupCombiner refuses to group sinks with DIFFERENT requested frequencies and
// refuses a group that matches nothing, so both halves of the split are checked at
// elaboration rather than discovered in a timing report.
class WithMemoryBusOnItsOwnClock(freqMHz: Double) extends Config(
  new chipyard.config.WithMemoryBusFrequency(freqMHz) ++
  new chipyard.config.WithSbusToMbusCrossingType(freechips.rocketchip.prci.AsynchronousCrossing()) ++
  new chipyard.clocking.WithClockGroupsCombinedByName(
    ("uncore", Seq("sbus", "pbus", "fbus", "cbus", "obus", "implicit", "clock_tap"),
               Seq("tile")),
    ("mem",    Seq("mbus"), Nil)))

// The bandwidth instrument, with the memory bus on FCLK1 at 100 MHz.
//
// SOC_MAGIC 0x5A5A0008.  It needs its own because it is register-compatible with
// 0x5A5A0007 for everything software can see and is a different machine underneath: a lab
// that ran against the wrong one would report a perfectly well-formed bytes-per-cycle
// figure for the other clock.
class PynqZ2RocketBigLittlePextTacitMicRgbBwFastConfig extends Config(
  new WithMemoryBusOnItsOwnClock(100.0) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ---------------------------------------------------------------------------------------
// LEVER 3: TWO memory channels, so the SoC masters two of the Zynq's four S_AXI_HP ports.
//
// WithNMemoryChannels(n) sets ExtMem.nMemoryChannels, and Ports.scala's
// `Seq.tabulate(nMemoryChannels)` over memAXI4Node makes that N INDEPENDENT AXI4 masters
// rather than one wider one -- each of which gets its own axi4_to_axi3 shim and its own
// HP port in pynqz2_rocket_top.v.  HP ports are PS7-internal, so this needs no package
// pins and no XDC change.
//
// THIS IS BUILT TO TEST AN ATTRIBUTION, NOT BECAUSE IT IS EXPECTED TO HELP.
// MEMORY_BANDWIDTH.md section 3.5 concludes from lever 2's null result that the DRAM
// ceiling is the L2's miss pipeline, which sits IN FRONT of the memory channels -- and if
// that is right, two ports behind it change nothing.  A prediction derived from a
// negative result is exactly the kind that deserves one measurement rather than a
// paragraph, and this is the bitstream that settles it.
//
// Built on the lever-1 config and NOT on lever 2, so the comparison isolates ports at one
// clock.  SOC_MAGIC 0x5A5A0009.
class PynqZ2RocketBigLittlePextTacitMicRgbBwPortsConfig extends Config(
  new freechips.rocketchip.subsystem.WithNMemoryChannels(2) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ---------------------------------------------------------------------------------------
// LEVER 4: a WIDER TILELINK SYSTEM BUS -- as a fragment that stacks on any config above.
//
// WHAT IT CAN RAISE, AND WHAT IT CANNOT.  MEMORY_BANDWIDTH.md section 3.5 measured the
// L2-HIT path at exactly 8.00 B/cycle: one 64-bit beat per cycle at 34.4828 MHz, i.e. the
// system bus's own beat.  A 128-bit sbus raises that ceiling to 16 B/cycle for every
// master IN FRONT OF the L2 -- both tiles, TraceSinkDMA, an SBUS-attached accelerator,
// BwProbe.  It does nothing for a master on the MBUS (TODO.md item 13's fusion), and it
// does not widen the memory bus, ExtMem or S_AXI_HP, which stay 64-bit: an HP port cannot
// be wider.
//
// WHERE THE 128 -> 64 CONVERSION HAPPENS.  Not in a TLWidthWidget.  The coherent bus
// topology puts the L2 between SBUS and MBUS; InclusiveCache declares its inner
// (client-facing) beatBytes = sbus.beatBytes (inclusivecache/Configs.scala) and takes the
// mbus's 8 on its outer edge, and BankedStore is written for innerBytes != outerBytes.
// So the L2 IS the width adapter: hits leave in 16-byte beats, refills arrive in 8-byte
// beats.  The TLWidthWidgets TLBusWrapperConnection inserts on that path -- 16 on
// SBUS->L2 and 8 on L2->MBUS -- are both identities.
//
// THREE THINGS WIDEN SILENTLY.  THIS FRAGMENT PINS TWO AND REPORTS THE THIRD.
//
//   1. BOTH HARTS' L1 CACHES.  WithNBigCores and WithNSmallCores set DCacheParams and
//      ICacheParams rowBits = site(SystemBusKey).beatBits, so a 128-bit sbus would rebuild
//      both harts' L1 geometry -- area, timing, possibly the P-extension's critical path
//      that pins the PL at 34.4828 MHz -- and the core half of the calibration gate would
//      stop measuring the machine Lab B6 measured.  WithCacheRowBits(64) puts it back.
//      That elaborates because rocket-chip already puts TLWidthWidget(rowBits/8) between
//      each cache and the tile's master crossbar (HellaCache.scala, Frontend.scala) and
//      cacheDataBits IS rowBits (L1Cache.scala): the L1s stay 64-bit and only the tile's
//      master port widens.
//
//   2. THE L2's HANDLER COUNT.  InclusiveCacheParameters.out_mshrs is
//      max(2, ceil(memCycles / blockBeats)), and blockBeats = 64 / innerBeatBytes: 5 + 2 =
//      7 MSHRs on a 64-bit sbus, but 10 + 2 = 12 on a 128-bit one.  Section 3.5 attributes
//      the DRAM cap to exactly that structure, so a wide sbus that also grew it would test
//      two things at once.  WithL2HandlersHeldAcrossBusWidth scales memCycles by
//      8/beatBytes, which holds the count at 7 for any width (required below, and visible
//      in the DTS as sifive,mshr-count).  memCycles sizes nothing else but the
//      secondary-request queue (33 -> 13 entries) and the Put buffer (40 -> 20 lists); a
//      read sweep has at most 8 instrument requests plus hart 0's two caches outstanding.
//
//   3. NOT PINNED: the L2's BankedStore sub-banking.  rowBytes = portFactor * max(inner,
//      outer), so at 128 bits the store is 8 SRAMs of 1,024 x 64 bits instead of 4 of
//      2,048 x 64 -- the same bits, and the SAME 1/4 of the store an inner read locks
//      against a refill write, which is what throughput sees.  Holding portFactor = 2
//      would keep the SRAM shapes and double that contention; that is the worse isolation.
//
// COMPOSABLE BY CONSTRUCTION.  Nothing here touches clocks, crossings, memory channels or
// the top level: the sbus is internal to ChipTop and the AXI memory port is the mbus's.
// So `new WithWideSystemBus(128) ++ new ...BwFastConfig` or `++ new ...BwPortsConfig`
// is the whole of a fusion, and tcl/build_rocket.tcl needs a variant name, not a new
// top-level switch.
class WithL2HandlersHeldAcrossBusWidth extends Config((site, here, up) => {
  case freechips.rocketchip.subsystem.InclusiveCacheKey => {
    val c   = up(freechips.rocketchip.subsystem.InclusiveCacheKey, site)
    val bb  = site(freechips.rocketchip.subsystem.SystemBusKey).beatBytes
    val blk = site(freechips.rocketchip.subsystem.CacheBlockBytes)
    require((c.memCycles * 8) % bb == 0,
      s"cannot hold the L2 handler count: memCycles ${c.memCycles} * 8 is not a multiple of $bb")
    val mc = c.memCycles * 8 / bb
    // freechips.rocketchip...InclusiveCacheParameters.out_mshrs, restated so the check
    // fails at elaboration with a sentence rather than in a timing report.
    def outMshrs(memCycles: Int, beatBytes: Int): Int = {
      val beats = blk / beatBytes
      math.max(2, (memCycles + beats - 1) / beats)
    }
    require(outMshrs(mc, bb) == outMshrs(c.memCycles, 8),
      s"L2 handlers would change: ${outMshrs(c.memCycles, 8)} on a 64-bit sbus, " +
      s"${outMshrs(mc, bb)} at $bb bytes with memCycles $mc")
    c.copy(memCycles = mc)
  }
})

class WithWideSystemBus(bits: Int) extends Config(
  new WithL2HandlersHeldAcrossBusWidth ++
  new freechips.rocketchip.rocket.WithCacheRowBits(64) ++
  new chipyard.config.WithSystemBusWidth(bits))

// The bandwidth instrument on a 128-bit system bus.  SOC_MAGIC 0x5A5A000A.
//
// Built on the lever-1 config and on nothing else, so the comparison with 0x5A5A0007 is
// the bus width at one clock and one HP port.  BwProbe.scala instantiates mbxd_dma.v at
// LGBEATS = 2 on this bus, so its 64-byte Gets are four 16-byte beats, and it adds the
// DBEATS and BEAT_BYTES registers that show it.
class PynqZ2RocketBigLittlePextTacitMicRgbBwWideConfig extends Config(
  new WithWideSystemBus(128) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ---------------------------------------------------------------------------------------
// THE L2 MISS PATH (MEMORY_BANDWIDTH.md section 6).  Three orthogonal fragments, each of
// which stacks on any config that already has WithInclusiveCache -- including lever 2's
// WithMemoryBusOnItsOwnClock and lever 3's WithNMemoryChannels -- and three configs that
// apply exactly one of them to the lever-1 instrument build.
//
// WHAT SETS THE NUMBER OF MISS HANDLERS, READ OUT OF THE GENERATOR RATHER THAN ASSUMED.
// sifive-blocks' InclusiveCacheParameters:
//
//     out_mshrs = max(2, ceil(memCycles / blockBeats))        blockBeats = 64/8 = 8
//     all_mshrs = 2 + out_mshrs                               (+1 for B+C, +1 for C)
//
// and memCycles is WithInclusiveCache's `outerLatencyCycles`, default 40:
// 2 + max(2, 5) = 7, which is what MEMORY_BANDWIDTH.md section 3.5 counted and what the
// generated InclusiveCacheBankScheduler.sv instantiates.  BUT ONLY FIVE OF THE SEVEN SERVE
// A-CHANNEL REQUESTS.  Scheduler.scala's prioFilter is Cat(prio(2), !prio(0), ones(mshrs-2)):
// the last MSHR is reserved for C-channel requests and the one before it for B/C, so a Get
// miss can only ever be allocated one of mshrs-2.
//
// The knob is therefore outerLatencyCycles.  It also sizes the put buffers
// (putLists = putBeats = memCycles) and the secondary request list, which only Puts and
// same-set collisions use -- a Get stream of distinct sets touches neither.
class WithL2MissHandlers(outerLatencyCycles: Int) extends Config((site, here, up) => {
  case freechips.rocketchip.subsystem.InclusiveCacheKey =>
    up(freechips.rocketchip.subsystem.InclusiveCacheKey, site).copy(memCycles = outerLatencyCycles)
})

// L2 CAPACITY, separately from its handlers, because they predict different things: more
// capacity moves where the L2-resident plateau ends and cannot change a working set that
// is 16x the cache either way; more handlers can only change the miss path.
//
// sets is recomputed exactly as WithInclusiveCache computes it, and has to be a power of
// two (InclusiveCacheParameters requires it): 256 KB / (64 B x 4 ways) = 1024.
class WithL2Capacity(capacityKB: Int, nWays: Int) extends Config((site, here, up) => {
  case freechips.rocketchip.subsystem.InclusiveCacheKey =>
    up(freechips.rocketchip.subsystem.InclusiveCacheKey, site).copy(
      ways = nWays,
      sets = (capacityKB * 1024) / (site(freechips.rocketchip.subsystem.CacheBlockBytes) * nWays *
             up(freechips.rocketchip.subsystem.SubsystemBankedCoherenceKey, site).nBanks))
})

// THE TILES ON THEIR OWN CLOCK, so that everything else -- sbus, the L2, mbus, pbus, cbus,
// and the instrument -- can run faster than the P-extension's critical path allows.
//
// The mechanism is rocket-chip's, not a hand-rolled one:
//   * rocket.WithAsynchronousCDCs(8, 3) sets every Rocket tile's crossingType to
//     AsynchronousCrossing.  HasTiles.connectPRC then gives each tile a ClockGroup of its
//     own from allClockGroupsNode (instead of the sbus's fixedClockNode), the master and
//     slave TileLink ports cross through TLAsyncCrossingSource/Sink, and the CLINT/PLIC
//     interrupts through IntSyncAsyncCrossingSink.  TACIT is already safe: its encoder and
//     TraceSinkDMA live INSIDE the tile, TraceSinkDMA reaches the sbus through its own
//     sbus.crossOut(..., AsynchronousCrossing()), and both register nodes hang off the
//     tile's (now crossed) slave port.
//   * AbstractConfig's "uncore" group already EXCLUDES clock names containing "tile", so
//     the two tile clocks (rockettile_0, rockettile_1) are left ungrouped.  WithTileClockGroup
//     APPENDS a "tile" group rather than restating the combiner, which is what lets it stack
//     on lever 2's WithMemoryBusOnItsOwnClock (uncore + mem + tile = three clock ports).
//   * WithTileFrequency is needed because ClockGroupCombiner refuses a group with no
//     requested frequency.  Like every bus frequency in this file it is a DTS value; the
//     real clocks are the PS7's FCLKs.
//
// BwProbe must stay in ONE domain with the sbus and the pbus: its TLClientNode is coupled to
// the sbus and its TLRegisterNode to the pbus with no crossing, and its module takes the
// subsystem's implicit clock.  That is why the whole uncore moves together and only the
// tiles are split off.
class WithTileClockGroup extends Config((site, here, up) => {
  case chipyard.clocking.ClockGroupCombinerKey => up(chipyard.clocking.ClockGroupCombinerKey, site) :+
    (("tile", (m: freechips.rocketchip.prci.ClockSinkParameters) => m.name.get.contains("tile")))
})

class WithTilesOnTheirOwnClock(tileMHz: Double) extends Config(
  new chipyard.config.WithTileFrequency(tileMHz) ++
  new WithTileClockGroup ++
  new freechips.rocketchip.rocket.WithAsynchronousCDCs(depth = 8, sync = 3))

// (a) handlers.  outerLatencyCycles 40 -> 80: 7 -> 12 MSHRs, 5 -> 10 of them for Gets --
// more than the instrument's eight source IDs can occupy.  SOC_MAGIC 0x5A5A000B.
class PynqZ2RocketBigLittlePextTacitMicRgbBwL2Mshr12Config extends Config(
  new WithL2MissHandlers(80) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// (a) capacity.  64 KB -> 256 KB at the same 4 ways and the same 7 MSHRs.  Chipyard's
// 512 KB default measured 140/140 BRAM36 (DUAL_CORE.md section 2); the lever-1 build uses
// 65.5.  SOC_MAGIC 0x5A5A000C.
class PynqZ2RocketBigLittlePextTacitMicRgbBwL2Cap256Config extends Config(
  new WithL2Capacity(capacityKB = 256, nWays = 4) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// (b) the L2 on a faster clock.  Tiles on clock_tile (FCLK0, 34.4828 MHz, the P-extension's
// clock); the sbus, the L2, the instrument and the rest of the uncore on clock_uncore
// (FCLK1, swept).  SOC_MAGIC 0x5A5A000D; each FCLK1 is a different build of this one config
// and is told apart by md5.
class PynqZ2RocketBigLittlePextTacitMicRgbBwL2FastConfig extends Config(
  new WithTilesOnTheirOwnClock(34.4828) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ... and one more point at 256 bits.  SOC_MAGIC 0x5A5A000F (first built as 000E, which
// collided with the L2 miss path's cork config; bwlab/errata.csv).
//
// WHY IT IS BUILT.  At 128 bits the L2-hit path measured 16.00 B/cycle -- one 16-byte beat
// per cycle, the D channel exactly (MEMORY_BANDWIDTH.md section 5.4) -- so the bus binds
// again and one more doubling is a question with an answer.
//
// WHY IT IS THE LAST.  The L2's Directory is one single-port SRAM whose writes wait for
// reads, and a hit costs a read at allocation and a writeback, so the L2 serves at most
// 0.5 Gets per cycle: 32 B/cycle for 64-byte Gets whatever the bus width, which is exactly
// a 256-bit D channel.  512 bits cannot pay for 64-byte Gets, measured or not.
class PynqZ2RocketBigLittlePextTacitMicRgbBwWide256Config extends Config(
  new WithWideSystemBus(256) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ---------------------------------------------------------------------------------------
// THE DECOUPLED ACCELERATOR, as a RoCC on hart 1 (ROCC_DECOUPLED.md section 8).
//
// The full-feature SoC plus rtl_study/roccmoon/mbxr_engine.v: the measured 64-byte fill
// engine (rtl_study/rocc/mbxd_dma.v, byte-identical), a planar BRAM scratchpad, a 32
// MAC/cycle DSP array and a result drain.  Built on PynqZ2RocketBigLittlePextTacitMicRgbConfig
// and NOT on the bandwidth instrument's, so the delta against the shipped 0x5A5A0006 is the
// accelerator and nothing else.
//
// Two fragments besides the engine, and neither is optional:
//   * WithMultiRoCC -- BuildRoCC is a global key; without per-tile evaluation tile 0 sees the
//     RoCC and patches/0008's require(!(usePExt && usingRoCC)) fires.
//   * WithRoccMoon sets RoCCDecodeOpcodes to custom-1 (patches/0101), so hart 1 still TRAPS on
//     MBP's custom-0 instead of hanging on it.
//
// The weight client is on SBUS here.  `weightBus = MBUS` is TODO.md item 13's bypass and is a
// configuration change, not a redesign (RoccMoon.scala).
//
// SOC_MAGIC 0x5A5A0010.
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonConfig extends Config(
  new chipyard.roccmoon.WithRoccMoon(hart = 1) ++
  new chipyard.config.WithMultiRoCC ++
  new PynqZ2RocketBigLittlePextTacitMicRgbConfig)

// THE FAST MULTIPLIER on the big core (ROCC_DECOUPLED.md section 8.15.3).
//
// WithNBigCores gives hart 0 MulDivParams(mulUnroll = 8, mulEarlyOut = true, divEarlyOut = true).
// That is an iterative multiplier, and on Lab B26's encoder images hart 0 executes 9.5-22 M
// M-extension instructions per inference, spike-counted.  RocketCore instantiates
// PipelinedMultiplier(xLen, 2) exactly when mulUnroll == xLen: two register stages, with the
// product landing in WB.  The divider stays the iterative MulDiv, elaborated with
// mulUnroll = 0.  This fragment changes ONLY mulUnroll; divUnroll, mulEarlyOut, divEarlyOut and
// divEarlyOutGranularity keep their values.
//
// Tile 0 only.  The LITTLE core (hart 1, WithNSmallCores: MulDivParams(mulUnroll = 8)) keeps its
// MulDiv unchanged.  Its software is the engine's control loop, which does not multiply in
// quantity, and leaving it alone keeps the delta against 0x5A5A0010 to one block.  patches/0008's
// MBP decode (DOT8/MAX8/QMUL/CLIP8) is in the ALU and does not depend on MulDiv, so P-ext is
// unaffected.
class WithPipelinedMulOnTiles(ids: Int*) extends Config(
  new freechips.rocketchip.subsystem.TileAttachConfig[freechips.rocketchip.subsystem.RocketTileAttachParams](
    tp => tp.copy(tileParams = tp.tileParams.copy(core = tp.tileParams.core.copy(
      mulDiv = tp.tileParams.core.mulDiv.map(_.copy(mulUnroll = tp.tileParams.core.xLen)))))
  ).atTileIds(ids: _*))

// SOC_MAGIC 0x5A5A0011.
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonMulConfig extends Config(
  new WithPipelinedMulOnTiles(0) ++           // hart 0 -- the big P-ext core -- only
  new PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonConfig)

// EVERY MEASURED LEVER IN ONE BUILD.  SOC_MAGIC 0x5A5A0028 (ROCC_DECOUPLED.md 8.15.9): the engine
// (revision 2a in rtl_study/, so incremental placement has its acknowledged watermark), the big
// core's pipelined multiplier (0x5A5A0011, measured -8.7 % on the encoder) and 0092's skipped clean
// Release (0x5A5A001A, the sbus path 6.10 -> 8.00 B/cycle on the instrument).  The Field is the only
// elaboration difference against 0x5A5A0011's bundle, so this config is elaborated on its own.
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig extends Config(
  new WithL2SkipCleanRelease ++
  new PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonMulConfig)


// ---------------------------------------------------------------------------------------
// THE LANE DEVELOPMENT CONFIG (fpga/pynq-z2/docs/LAYERNORM_LANE.md section 20).  SOC_MAGIC 0x5A5A002B.
//
// 0x5A5A0029/002A's SoC with everything a LANE does not touch removed, so that lane FUNCTION can
// be iterated without place-and-route fighting a 95 %-full device.  It keeps exactly what the
// verification bar needs: both harts (the RoCC is on hart 1 and must stay), the same 64 KB
// 4-way inclusive L2 with 0092's skipped clean Release, DDR and the console.
//
// WHAT IS DROPPED, and what each cost in 0x5A5A002A measured post-route:
//   TACIT trace   2,202 LUT (5.0 %)  -- TacitEncoder x2 1,826, TracePacketizer x2 177,
//                                       TraceSinkDMA x2 197, controllers 2.  Irrelevant to lanes.
//   PDM mic         549 LUT (1.2 %)  -- and its build-time simulation gate.
//   RGB GPIO         89 LUT (0.2 %)
//   MBP P-ext       265 LUT (0.6 %)  -- measured in DUAL_CORE.md/ROCC_STUDY.md; nearly free in
//                                       AREA, but its RTL selftest is 6 min 38 s of a 21-minute
//                                       build, which is the real saving.
//   pipelined mul                    -- hart 0's mulUnroll = 64; hart 0 does no lane work here.
//
// WHAT IS NOT DROPPED, and why -- this is the line that keeps it useful:
//   * BOTH HARTS.  The engine's command path is a RoCC in hart 1's tile, so hart 1 is not
//     optional.  Hart 0 is 14,049 LUT (31.7 %), by far the largest cut available, and dropping
//     it would need single-hart images that this workstream does not own.  Named, not taken.
//   * THE L2, unchanged.  The engine's client Puts through it to stay coherent with both L1s;
//     shrinking it would change what the lane sees.  The same argument the bandwidth configs
//     make above: "a minimal SoC would measure a different machine".
//
// WHAT THIS CANNOT TELL YOU.  It is a DIFFERENT MACHINE.  It answers "does the lane compute the
// right bytes, does the dispatch protocol work, does it refuse what it should" and it tells you
// ESSENTIALLY NOTHING ABOUT FIT OR TIMING: a lane that closes with slack at ~77 % occupancy is
// not evidence about 95 %.  Budget against the full config, verify function here, and NAME THE
// CONFIG beside every utilisation or WNS number -- the same discipline as naming the model, the
// clock and cold-or-steady.
//
// ONE CONSEQUENCE FOR IMAGES.  With no P-extension, hart 0 traps on custom-0, so an image for
// this config must use kernels that emit none.  Checked in q16_gates_R.json's b3_objects:
// layernorm_pc_s8 -> reference and groupnorm_s16 -> pext_int_memo are both custom0 = 0, so
// T3's lane-off baseline is unaffected.  The DOT8 kernels (matmul_b_s8 -> pext_dot8_exact,
// linear_s8 -> pext_row_dot8) are NOT available here, so T2's A/B must fall back to reference
// kernels -- which still verifies function, being the definition the curated kernels are
// checked against, but is not the deployed kernel mix.
class PynqZ2RocketBigLittleRoccMoonLanesDevConfig extends Config(
  new WithL2SkipCleanRelease ++
  new chipyard.roccmoon.WithRoccMoon(hart = 1) ++
  new chipyard.config.WithMultiRoCC ++
  new PynqZ2RocketBigLittleConfig)

// ---------------------------------------------------------------------------------------
// THE HM01B0 CAMERA ON THE PYNQ-Z1 SHIELD (fpga/pynq-z2/docs/CAMERA_Z1.md).  SOC_MAGIC 0x5A5A001E.
//
// 0x5A5A0010 plus the capture peripheral PynqZ2RocketTacitCamConfig above introduced, in the
// shape that config used, for the shield riskybirdv3_pynq_camera rev 0.6 on the Z1's chipKIT
// header.  Nothing else in the SoC moves.
//
//   * ospi.WithOspiCaptureDma(frameBufferDepth = 512): the capture core at 0x1008_0000 with its
//     TileLink DMA master on the front bus.  The frame buffer is LINE-sized (324 pixels + EOF fit
//     in 512 beats), not frame-sized: the DMA drains it into DDR while the sensor reads out, so
//     a whole-frame buffer (~32 BRAM36) would buy nothing on a part at 85.5 of 140.  The price is
//     that software must have a transfer running before a frame starts (CAMERA_Z1.md section 5).
//   * chipyard.iobinders.WithOspiPunchthrough: SensorIO out as ChipTop's ospi_sensor_* ports.
//   * chipyard.config.WithI2C: a sifive TLI2C at 0x1004_0000 for the sensor's 0x24 control port.
//     Its AsynchronousCrossing parameters do not take effect here -- the TLI2C elaborates on the
//     pbus clock -- and AbstractConfig already carries WithI2CPunchthrough (i2c_0_* ports).
//   * WithHM01B0SimModel: the TestHarness binder for both ports, see below.
//
// The DMA master reaches DDR as fbus -> sbus -> the L2 (InclusiveCache) -> mbus -> ExtMem, the
// path TACIT's TraceSinkDMA takes, so a frame it writes is coherent with both harts' caches.
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig extends Config(
  new WithHM01B0SimModel ++
  new chipyard.iobinders.WithOspiPunchthrough ++
  new ospi.WithOspiCaptureDma(frameBufferDepth = 512) ++
  new chipyard.config.WithI2C ++
  new PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonConfig)

// A SIMULATION-ONLY HM01B0 in the TestHarness, instead of a tie-off (fpga/pynq-z2/sim/
// hm01b0_sim_model.v has the model's contract).  One instance serves both of ChipTop's port
// groups: the sensor's video pins and its I2C slave at 0x24.  HarnessBinders see one port at a
// time, so the instance is created by whichever binder runs first and found by the other.
//
// This changes the TestHarness only.  ChipTop -- and so *.top.f, which is all the bitstream is
// built from -- does not see it, and the Verilog is a plain BlackBox that only the Verilator
// build is given (scripts/65_cam_rtl_sim.sh).
class HM01B0SimModel extends BlackBox(Map(
    "WIDTH"  -> chisel3.experimental.IntParam(32),
    "HEIGHT" -> chisel3.experimental.IntParam(24))) {
  val io = IO(new Bundle {
    val reset     = Input(Bool())
    val i2c_clock = Input(Clock())
    val mclk      = Input(Clock())
    val trig      = Input(Bool())
    val pclk      = Output(Clock())
    val fvld      = Output(Bool())
    val lvld      = Output(Bool())
    val d         = Output(UInt(8.W))
    val intr      = Output(Bool())
    val scl_out   = Input(Bool())
    val scl_oe    = Input(Bool())
    val sda_out   = Input(Bool())
    val sda_oe    = Input(Bool())
    val scl_in    = Output(Bool())
    val sda_in    = Output(Bool())
  })
}

object HM01B0SimModel {
  private val instances = scala.collection.mutable.WeakHashMap[AnyRef, HM01B0SimModel]()
  def apply(th: chipyard.harness.HasHarnessInstantiators): HM01B0SimModel =
    instances.getOrElseUpdate(th, {
      val m = Module(new HM01B0SimModel)
      m.io.reset     := th.harnessBinderReset.asBool
      m.io.i2c_clock := th.harnessBinderClock
      m
    })
}

class WithHM01B0SimModel extends chipyard.harness.HarnessBinder({
  case (th: chipyard.harness.HasHarnessInstantiators, port: chipyard.iobinders.OspiPort, chipId: Int) => {
    val m = HM01B0SimModel(th)
    port.io.pclk := m.io.pclk
    port.io.fvld := m.io.fvld
    port.io.lvld := m.io.lvld
    port.io.d    := m.io.d
    port.io.intr := m.io.intr
    m.io.mclk    := port.io.mclk
    m.io.trig    := port.io.trig
  }
  case (th: chipyard.harness.HasHarnessInstantiators, port: chipyard.iobinders.I2CPort, chipId: Int) => {
    val m = HM01B0SimModel(th)
    m.io.scl_out     := port.io.scl.out
    m.io.scl_oe      := port.io.scl.oe
    m.io.sda_out     := port.io.sda.out
    m.io.sda_oe      := port.io.sda.oe
    port.io.scl.in   := m.io.scl_in
    port.io.sda.in   := m.io.sda_in
  }
})

// The shipped full-feature config under a second name, elaborated with patches/0101 applied,
// so the patch's claim to be inert is a diff against fpga/pynq-z2/chipyard/gensrc rather than
// an assertion.  Never built into a bitstream.
class PynqZ2RocketBigLittlePextTacitMicRgbInertCheckConfig extends Config(
  new PynqZ2RocketBigLittlePextTacitMicRgbConfig)

// ---------------------------------------------------------------------------------------
// THE L2 MISS PATH, the mechanism test (MEMORY_BANDWIDTH.md section 6): TLCacheCork serves
// ReleaseAck ahead of GrantData.  patches/0091-rocketchip-cachecork-releaseack-first.patch
// adds the Field, default false.  A simulation of this repo's own L2 + cork RTL attributes
// the DRAM plateau to ReleaseAck starvation on the cork's shared D channel and predicts
// 64/9 = 7.11 B/cycle with this set; this is the bitstream that tests it.  Stacks on any
// config with an InclusiveCache.
class WithCacheCorkReleaseAckFirst extends Config((site, here, up) => {
  case freechips.rocketchip.tilelink.TLCacheCorkReleaseAckFirst => true
})

// SOC_MAGIC 0x5A5A000E.
class PynqZ2RocketBigLittlePextTacitMicRgbBwL2CorkConfig extends Config(
  new WithCacheCorkReleaseAckFirst ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ---------------------------------------------------------------------------------------
// THE BYPASS FUSION (MEMORY_BANDWIDTH.md section 8; TODO.md item 13).  SOC_MAGIC 0x5A5A0015.
//
// Two levers that measured null BEHIND the L2 (sections 3.4 and 3.6), stacked with the one
// change that takes the L2 out of the path:
//   * WithBwBypass: the instrument on the MEMORY bus, 2 lanes x 16 source IDs, each lane an
//     independent TileLink client with its own D channel (BwBypass.scala).  BwProbe stays on
//     the system bus at 0x100A_0000, so the L2 path is measured on the same bitstream.
//   * WithNMemoryChannels(2), channel 1 wired to S_AXI_HP2 in the top level (PYNQZ2_CH1_HP2):
//     HP0 and HP2 are on DIFFERENT DDR controller ports.  Channel c owns the 64-byte blocks
//     whose address[6] = c, so lane c on a stride of 128 bytes talks to HP port 2c.
//   * WithMemoryBusOnItsOwnClock: mbus, both TLToAXI4 couplers, both shims, the HP ports and
//     the bypass lanes on FCLK1, timed at 100 MHz, SET and READ BACK at run time.
//   * WithExtMemPortBuffer (patches/0061): a TLBuffer between the mbus crossbar and each
//     channel's TLToAXI4.
//
// FIRST BUILD, NEVER MEASURED.  This config first had four lanes on four channels (HP0-HP3)
// and no port buffer (commit 7a7e05e).  That build (md5 c0bf3870) missed timing on BOTH clocks:
// FCLK0 by -0.296 ns (the L2 MSHR path, at 45,294 LUT) and FCLK1 by -3.930 ns, on a 15-level
// path from a lane through the 5x5 crossbar and TLToAXI4's stall lookup.  Nothing was run on
// it.  Two lanes on the pair of ports that can parallelise, plus a registered slice, is the
// revision; the four-port question is section 7's, measured with a raw AXI master.
class WithExtMemPortBuffer extends Config((site, here, up) => {
  case freechips.rocketchip.subsystem.ExtMemPortBuffer => true
})

class PynqZ2RocketBigLittlePextTacitMicRgbBwBypassConfig extends Config(
  new chipyard.bwprobe.WithBwBypass(address = 0x100b0000L, lanes = 2, depth = 16, getBytes = 64) ++
  new WithExtMemPortBuffer ++
  new freechips.rocketchip.subsystem.WithNMemoryChannels(2) ++
  new WithMemoryBusOnItsOwnClock(100.0) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ---------------------------------------------------------------------------------------
// THE L2 MISS PATH, the fix the model points at (MEMORY_BANDWIDTH.md section 6.6): a clean
// victim sends no outer Release.  patches/0092-inclusivecache-skip-clean-release.patch adds
// the Field (default false) and a require that the L2 is last-level.  The model puts a
// saturated miss stream at 7.9997 B/cycle with it, without the liveness hazard it found in
// the ReleaseAck-first cork (WithCacheCorkReleaseAckFirst, 0x5A5A000E).  Stacks on any config
// with an InclusiveCache.
class WithL2SkipCleanRelease extends Config((site, here, up) => {
  case sifive.blocks.inclusivecache.InclusiveCacheSkipCleanRelease => true
})

// SOC_MAGIC 0x5A5A001A.  (First assigned 0x5A5A000F, which was also given to lever 4's 256-bit
// build; renumbered before any measurement.  The generated Verilog does not carry the magic.)
class PynqZ2RocketBigLittlePextTacitMicRgbBwL2SkipConfig extends Config(
  new WithL2SkipCleanRelease ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ---------------------------------------------------------------------------------------
// THE L2 PATH PAST ONE 64-BIT BEAT (MEMORY_BANDWIDTH.md section 6.6-6.8).  With clean
// Releases skipped (0092) a miss stream through the L2 is bound by the L2's OUTER D channel
// -- one 64-bit beat per L2 cycle -- and lever 4's 128-bit system bus only widens the INNER
// side.  So widen both: WithEdgeDataBits(128) makes the memory bus 128-bit, which puts
// rocket-chip's own TLWidthWidget(mbus.beatBytes) in front of TLToAXI4 (Ports.scala), so the
// ExtMem AXI port and S_AXI_HP0 stay 64-bit.  Composed from lever 4's WithWideSystemBus and
// 0092's WithL2SkipCleanRelease, nothing new.  Elaborated first for the model; a bitstream
// takes one of 0x5A5A0018-001B only after the model has predicted it.
// THE AXI MEMORY PORT STAYS 64-BIT.  rocket-chip's ExtMem takes beatBytes from
// site(MemoryBusKey), so WithEdgeDataBits(128) alone makes ChipTop's axi4_mem_0 128-bit --
// and pynqz2_rocket_top.v's shim and S_AXI_HP0 are 64-bit.  The first 0x5A5A0018 build did
// exactly that and issued 16-byte-beat AXI bursts into a 64-bit HP port (MEMORY_BANDWIDTH.md
// section 6.12).  Pinning ExtMem's beatBytes makes Ports.scala's TLWidthWidget(mbus.beatBytes)
// a real 128 -> 64 adapter in front of TLToAXI4.
class WithExtMemBeatBytes(bytes: Int) extends Config((site, here, up) => {
  case freechips.rocketchip.subsystem.ExtMem =>
    up(freechips.rocketchip.subsystem.ExtMem, site).map(m => m.copy(master = m.master.copy(beatBytes = bytes)))
})

class PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipConfig extends Config(
  new WithExtMemBeatBytes(8) ++
  new WithL2SkipCleanRelease ++
  new freechips.rocketchip.subsystem.WithEdgeDataBits(128) ++
  new WithWideSystemBus(128) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// The same L2 with lever 4's held handler count released: at a 128-bit inner beat a 64-byte
// block is 4 beats, so WithInclusiveCache's own outerLatencyCycles = 40 already gives
// 2 + ceil(40/4) = 12 MSHRs (10 take Gets).  WithWideSystemBus pins 7 to isolate width;
// WithL2MissHandlers(40) on the left undoes that.  Model first.
class PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipM12Config extends Config(
  new WithL2MissHandlers(40) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipConfig)

// ... and each with lever 2's memory bus on FCLK1, because the model says a 128-bit outer side
// only pays if the memory can SUPPLY a 128-bit beat every L2 cycle, which a TLWidthWidget
// over a 64-bit AXI port on the L2's own clock cannot (MEMORY_BANDWIDTH.md section 6.9).
// SOC_MAGIC 0x5A5A0018 and 0x5A5A0019.  FCLK1 must be SET and read back (host/fclk.py).
class PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipFastConfig extends Config(
  new WithMemoryBusOnItsOwnClock(100.0) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipConfig)

class PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipM12FastConfig extends Config(
  new WithMemoryBusOnItsOwnClock(100.0) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipM12Config)

// THE BYPASS ON ALL FOUR HP PORTS (MEMORY_BANDWIDTH.md s8.7).  SOC_MAGIC 0x5A5A0017.
//
// 0x5A5A0016 measured the D channel as what binds: 8 B per memory-bus cycle per lane, and two
// lanes on HP0+HP1 at exactly 2x (1,600 MB/s at 100 MHz).  More lanes on more ports is the
// remaining port lever: four lanes, channel c on S_AXI_HPc (PYNQZ2_NMEM4), address[7:6] = c.
// Lanes are 8 deep, not 16: the knee is at <= 5 in flight at 100 MHz (L = 20.25 cycles), and
// the first four-lane build (16 deep, no port buffers) missed timing on both clocks.
class PynqZ2RocketBigLittlePextTacitMicRgbBwBypass4Config extends Config(
  new chipyard.bwprobe.WithBwBypass(address = 0x100b0000L, lanes = 4, depth = 8, getBytes = 64) ++
  new WithExtMemPortBuffer ++
  new freechips.rocketchip.subsystem.WithNMemoryChannels(4) ++
  new WithMemoryBusOnItsOwnClock(100.0) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// ---------------------------------------------------------------------------------------
// THE SYSTEM-BUS SIDE OF THE MEMORY ARCHITECTURE (MEMORY_BANDWIDTH.md section 9).
// SOC_MAGIC 0x5A5A001C.
//
// Sections 6 and 8 took the two ends of the memory path to their links: an SBUS requester through
// the L2 reaches one 64-bit beat per core cycle (275.8 MB/s, 0x5A5A001A), an MBUS requester on the
// memory clock reaches 800 MB/s per HP port and a 2,008 MB/s PS-side cap on four (0x5A5A0017).
// This config asks what a requester that stays ON THE CORE CLOCK can get without the L2, and what
// the harts pay to share memory with it:
//   * WithBwWindow: four lanes of mbxd_dma at FCLK0, each a 128-bit TileLink client with its own
//     async crossing, the 128 -> 64 widget on the memory-clock side, and its own channel/HP port
//     (BwWindow.scala).  Candidate 1 of section 9.
//   * WithDmaAperture: DDR aliased UNCACHED at 0x4000_0000 on the system bus, one async crossing
//     straight into the memory bus, four sources in flight.  The harts' and BwProbe's way into the
//     DMA view, and the thing section 9.4's coherence contract is measured on.
//   * The memory side is 0x5A5A0017's exactly: four channels on HP0-HP3 (PYNQZ2_NMEM4), memory bus
//     on FCLK1 timed at 100 MHz, patch 0061's port buffer.  BwBypass is NOT here: its numbers are
//     0017's, and 0017 is this build's A/B for "the same lanes on the memory clock".
class PynqZ2RocketBigLittlePextTacitMicRgbBwWinConfig extends Config(
  new chipyard.bwprobe.WithBwWindow(address = 0x100c0000L, lanes = 4, depth = 8, laneBits = 128) ++
  new chipyard.bwprobe.WithDmaAperture(base = 0x40000000L, target = 0x80000000L,
                                       size = 0x10000000L, inFlight = 4) ++
  new WithExtMemPortBuffer ++
  new freechips.rocketchip.subsystem.WithNMemoryChannels(4) ++
  new WithMemoryBusOnItsOwnClock(100.0) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwConfig)

// The partition contract as address decode (BwWindow.scala WithDmaPartition): the upper 128 MB of
// DDR (0x8800_0000) is removed from what the L2 can name and is reachable only through the aperture,
// at 0x4800_0000.  ELABORATION CHECK ONLY -- no MAGIC, never built.  It exists so section 9.4 can
// say what hardware enforces, from the generated address map rather than from a sentence.
class PynqZ2RocketBigLittlePextTacitMicRgbBwWinPoolConfig extends Config(
  new chipyard.bwprobe.WithDmaPartition(poolBase = 0x88000000L, poolSize = 0x08000000L,
                                        aliasBase = 0x48000000L) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbBwWinConfig)

// ---------------------------------------------------------------------------------------
// NCH 8: THE MAC ARRAY WIDENED TO 64 MAC/cycle (B96).  No SOC_MAGIC -- a FIT EXPERIMENT.
//
// PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig with nch = 8 and NOTHING else: the same
// skipped clean Release, the same pipelined multiplier on hart 0, the same peripherals, the same
// engine RTL.  WithRoccMoon's nch reaches mbxr_engine.v as the NCH parameter (RoccMoon.scala:150,
// IntParam) and that Verilog is parameterised on it throughout -- mbxr_tseq, mbxr_wunpack,
// mbxr_mac, mbxr_lanes, mbxr_quant and mbxr_pack each take .NCH(NCH).
//
// WHY IT EXISTS.  Every "it does not fit" figure for this widening -- 100.8 %, 101.7 %, "223
// slices over" -- is a LUT count divided by a packing DENSITY borrowed from a different design.
// Slices are shared containers and report_utilization -hierarchical has no Slice column, so no
// report can attribute them per module.  The deficit is 1.68 % of density against a run-to-run
// occupancy swing measured at 4.4 points on identical logic.  A place-and-route is the only
// instrument that answers it, and one has never been run.
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8Config extends Config(
  new WithL2SkipCleanRelease ++
  new WithPipelinedMulOnTiles(0) ++
  new chipyard.roccmoon.WithRoccMoon(hart = 1, nch = 8) ++
  new chipyard.config.WithMultiRoCC ++
  new PynqZ2RocketBigLittlePextTacitMicRgbConfig)

// ---------------------------------------------------------------------------------------
// THE OLED / BUTTON PANEL ON THE Nch = 8 MACHINE (B135).  Two configs, added alongside
// PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8Config and changing nothing in it.
//
// WHAT THEY ARE FOR.  0x5A5A0035 is the bitstream every measured Moonshine number in this
// repo runs on.  A tutorial demo wants two things it does not have: an SSD1306 OLED on
// I2C (0x3c) and a physical pushbutton to start a recording.  Both are PERIPHERAL
// additions -- neither touches a tile, the L2, the memory path, the RoCC engine or the
// clock -- so the arithmetic and the cycle behaviour of the machine are unchanged and a
// number measured on 0x5A5A0035 is still a number about this machine's compute.
//
// WHAT CHANGES IN THE SoC, and it is not nothing:
//   * the PLIC renumbers.  DigitalTop mixes HasPeripheryI2C in before HasPeripheryUART and
//     HasPeripheryGPIO, so the TLI2C takes source 1, the UART moves 1 -> 2 and the GPIO
//     block moves up behind it.  docs/OLED_SSD1306.md F6 measured exactly this on
//     0x5A5A001E's generated DTS.  A guest built for 0x5A5A0035's board will get the UART
//     wrong; these configs need a board of their own.
//   * the peripheral bus grows one crossbar port (I2C), and in the Btn config the GPIO
//     block grows from 6 pins to 10.
//
// WHY THE GPIO IS WIDENED RATHER THAN A SECOND CONTROLLER ADDED.  All six of the existing
// controller's pins are consumed by the two RGB LEDs (WithGPIO(0x10010000, width = 6) in
// PynqZ2RocketBigLittlePextTacitMicRgbConfig), so there is no spare pin to read a button
// on.  chipyard.config.WithGPIO APPENDS a controller; a second one would cost another pbus
// crossbar port and another register file on a device that places at 99.96 % slice
// occupancy.  Widening the one that is there costs four pins' worth of registers and no
// new bus port.  WithGPIOWidth maps over whatever PeripheryGPIOKey already holds, so it
// keeps the address (0x1001_0000) and adds nothing of its own.
//
// BIT ORDER, fixed here and asserted in src/pynqz2_btn.xdc and tcl/build_rocket.tcl:
//   pins 0..5  the RGB LEDs, exactly as they are in 0x5A5A0035 (L15 G17 N15 G14 L14 M15)
//   pins 6..9  BTN0..BTN3   (D19 D20 L20 L19), inputs only -- the top level drives i_ival
//              from the pad and leaves o_oval/o_oe alone, so software reads them through
//              the GPIO input_val register.
class WithGPIOWidth(width: Int) extends Config((site, here, up) => {
  case sifive.blocks.devices.gpio.PeripheryGPIOKey =>
    up(sifive.blocks.devices.gpio.PeripheryGPIOKey, site).map(_.copy(width = width))
})

// I2C ONLY: the minimal OLED machine.  chipyard.config.WithI2C puts a sifive TLI2C at
// 0x1004_0000; AbstractConfig already carries WithI2CPunchthrough (ChipTop's i2c_0_* ports)
// and chipyard.harness.WithI2CTiedOff, so nothing else is needed.  Note what is NOT here,
// against PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig: no WithOspiCaptureDma, no
// WithOspiPunchthrough and no WithHM01B0SimModel.  The camera's DMA and frame buffer are
// the expensive part of that config and the OLED does not need them.
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cConfig extends Config(
  new chipyard.config.WithI2C ++
  new PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8Config)

// I2C PLUS THE FOUR PUSHBUTTONS.  The I2C config with the GPIO widened 6 -> 10.
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cBtnConfig extends Config(
  new WithGPIOWidth(10) ++
  new chipyard.config.WithI2C ++
  new PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8Config)

// THE CAMERA'S CAPTURE DMA ON TOP OF THE PANEL -- A FIT EXPERIMENT, NO SOC_MAGIC AND NO VARIANT.
//
// B135 step 4 asks whether the ospi capture DMA fits alongside the OLED and the buttons on a part
// that already places at 99.96 % slice occupancy.  The cheap gate is tcl/ooc_area.tcl: synthesise
// ChipTop alone for this config and for the I2cBtn config and subtract.  Both arms exclude the
// RoCC engine identically (mbxr_engine is a BlackBox and its Verilog comes from the repo, not from
// the elaboration), so the DIFFERENCE is the capture core, its DMA master and its frame buffer,
// measured inside this SoC rather than borrowed from micrgb_roccmooncam's context.
//
// WithHM01B0SimModel is deliberately absent: it is a TestHarness binder, simulation only, and
// ChipTop -- which is all a bitstream is built from -- never sees it.
// WithOspiTiedOff is needed for the same reason PynqZ2RocketTacitCamConfig needs it: Chipyard
// always elaborates the TestHarness alongside ChipTop and Chisel refuses to finish with an
// uninitialised sink.  TestHarness only; ChipTop does not see it.
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cBtnCamConfig extends Config(
  new WithOspiTiedOff ++
  new chipyard.iobinders.WithOspiPunchthrough ++
  new ospi.WithOspiCaptureDma(frameBufferDepth = 512) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cBtnConfig)

// ---------------------------------------------------------------------------------------
// B137: EVERY INTERFACE AT ONCE -- ENGINE, P-EXT, MIC, RGB, I2C, BUTTONS *AND* THE CAMERA'S
// CAPTURE DMA -- PAID FOR BY DROPPING TACIT.
//
// B135 measured that the ospi capture DMA does NOT fit on 0x5A5A0037's panel SoC: +1,697 LUT
// out of context (~1,485 in context at ooc_area.tcl's own 0.875 ratio) against a routed panel
// build with TWO of the device's 13,300 slices free.  B135's own conclusion was that making
// room means giving something up, and named three candidates: the L2's fourth way, the
// P-extension, and TACIT.
//
// TACIT IS THE ONE THAT COSTS THE WORKLOAD NOTHING, and this is measured rather than argued.
// From 0x5A5A0037's own post_route_util_hier.rpt, the trace machinery is, per tile:
//
//     TacitEncoder_19   926 LUT   TraceSinkDMA_20    99 LUT   TraceEncoderController_25  2 LUT
//     TacitEncoder      896 LUT   TraceSinkDMA      100 LUT   TraceEncoderController     0 LUT
//     ------------------------------------------------------------------------------------
//     2,023 LUT of routed logic, plus the two sbus master ports their DMAs occupy and the
//     two MMIO regions (0x300_0000 / 0x301_0000) every PMAChecker and PTW decodes.
//
// NOTHING IN THE MOONSHINE PATH READS A TRACE.  samples/tacit_boot and samples/membench do,
// and they keep working on the bitstreams that have it -- 0x5A5A0035, 0x5A5A0036, 0x5A5A0037
// and every earlier TACIT variant are untouched.  This is a NEW variant, not a replacement.
//
// WHAT REMOVING IT DOES *NOT* CHANGE, stated because "it only removes a monitor" has to be
// checkable:  rocketParams.enableTraceCoreIngress guards exactly one block in
// rocket-chip's RocketCore.scala (L876-L895): a TraceCoreIngress module fed from wb_valid,
// wb_reg_inst, wb_reg_pc, the branch flags and four CSR outputs, driving io.trace_core_ingress.
// It READS the writeback stage and drives nothing back into it.  There is no datapath, no
// control signal and no scheduling decision downstream of it, so a core elaborated with it
// false executes the same instructions in the same cycles.  Rocket.sv still CHANGES -- the
// port and the ingress module vanish -- so the md5-equality argument B135 used for the
// engine cannot be used here for the core, and it is not claimed.
//
// WHAT IS KEPT, BYTE FOR BYTE: fclk 40 MHz, the md5-pinned engine snapshot
// src/lanes_engine_b98nch8b, nch = 8, the P-extension on hart 0, the RoCC engine on hart 1,
// WithInclusiveCache(nWays = 4, capacityKB = 64), WithL2SkipCleanRelease, the pipelined
// multiplier on tile 0, ExtMem 256 MB / 4 ID bits, WithoutFPU, the PDM mic, the six RGB pins,
// the TLI2C at 0x1004_0000 and the GPIO widened to 10.  Only the trace machinery leaves and
// only the capture DMA arrives.
//
// SUBTRACTIVE, NOT A REBUILT CHAIN, AND THAT IS DELIBERATE.  This could have been written as a
// fresh Config listing every fragment except the two TACIT ones.  It is not, because that
// re-states twenty fragments in an order CDE is sensitive to -- WithNBigCores(1) must still
// run before WithNSmallCores(1) or the LITTLE hart silently gets the P-extension (see
// WithPExtOnTiles above) -- and a transcription error there elaborates, builds and boots.
// Applying ONE fragment on top of the config B135 already measured makes the delta exactly
// "TACIT removed" by construction.
//
// HOW IT WORKS.  CDE applies the RIGHTMOST fragment first, so a fragment on the LEFT sees the
// result of everything to its right: chipyard.WithTacitEncoder has already set traceParams and
// enableTraceCoreIngress, and tacit.WithTraceSinkDMA has already appended its sink (its
// traceParams.get is evaluated before this runs, so it does not throw).  This clears both.
// TraceSinkDMAInjector stays in SubsystemInjectorKey and is inert: its body is guarded by
// `if (traceSinkDMAs.nonEmpty)` (tacit/src/main/scala/TraceSinkDMA.scala L183) and with no
// tile carrying a sink it connects nothing.
class WithoutTacitOnTiles extends Config((site, here, up) => {
  case freechips.rocketchip.subsystem.TilesLocated(freechips.rocketchip.subsystem.InSubsystem) =>
    up(freechips.rocketchip.subsystem.TilesLocated(freechips.rocketchip.subsystem.InSubsystem), site) map {
      case tp: freechips.rocketchip.subsystem.RocketTileAttachParams =>
        tp.copy(tileParams = tp.tileParams.copy(
          traceParams = None,
          core = tp.tileParams.core.copy(enableTraceCoreIngress = false)))
      case other => other
    }
})

// THE DELIVERABLE'S CONFIG: the panel SoC plus the camera's capture DMA, minus TACIT.
//
// PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cBtnCamConfig is B135's step-4 fit
// experiment and already carries exactly the three camera fragments the real camera variant
// (PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig) uses: WithOspiCaptureDma(512),
// chipyard.iobinders.WithOspiPunchthrough and the TestHarness-only WithOspiTiedOff.  It is
// unchanged and still elaborates to the same thing it did for B135's measurement.
//
// ONE TLI2C SERVES BOTH THE OLED AND THE SENSOR, and that is a property of the board rather
// than a compromise: the camera shield hangs its J4 OLED row straight on PL_SDA/PL_SCL
// (P15/P16) and puts the sensor behind a PCA9306 on the same pair, so there is one bus, one
// controller at 0x1004_0000 and one pair of balls.  B136 measured an SSD1306 answering at 0x3c
// on exactly those two balls on 0x5A5A0037.  The top level therefore keeps PYNQZ2_HAS_I2C for
// the pads and gets a new PYNQZ2_HAS_OSPI for the sensor's fourteen video pins alone.
class PynqZ2RocketBigLittlePextMicRgbRoccMoonAllNch8I2cBtnCamNoTacitConfig extends Config(
  new WithoutTacitOnTiles ++
  new PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cBtnCamConfig)

// ---------------------------------------------------------------------------------------
// B138: THE TRACE BITSTREAM -- TACIT ON BOTH HARTS, THE P-EXTENSION, EVERY INTERFACE, AND
// NO ACCELERATOR.  SOC_MAGIC 0x5A5A0039 (tcl/build_rocket.tcl, MAGIC_REGISTRY.md).
//
// WHAT IT IS FOR, AND WHY IT IS NOT A MEASUREMENT BITSTREAM.  0x5A5A0035/0036/0037 exist to
// run the Moonshine workload on the nch = 8 RoCC engine; a trace taken on them is a trace of
// a machine whose arithmetic is mostly inside a BlackBox the encoder cannot see (the engine
// retires ONE custom-1 instruction per dispatch and then runs for thousands of cycles).  This
// variant is the other half of that pair: the same two harts, the same P-extension on hart 0,
// the same peripherals, and NO engine -- so the arithmetic the trace is being taken of is
// executed by instructions, and the decoder's slices are the computation rather than a
// dispatch stub.  It is built to be TRACED, not to be fast.
//
// BOTH TILES CARRY AN ENCODER, AND THAT IS A PROPERTY OF THE FRAGMENT, NOT OF THIS FILE.
// chipyard.WithTacitEncoder (generators/tacit/chipyard/TacitConfigs.scala:21) maps over
// TilesLocated(InSubsystem) and rewrites EVERY RocketTileAttachParams, giving each tile
// traceParams with encoderBaseAddr = 0x3000000 + tileId * 0x1000 and
// core.enableTraceCoreIngress = true.  tacit.WithTraceSinkDMA(1) does the same for the sinks
// at 0x3010000 + tileId * 0x1000.  Both are inherited unchanged from
// PynqZ2RocketBigLittleTacitConfig through the chain below; nothing here re-states them, and
// nothing here restricts them to one tile.  The elaborated DTS and the routed hierarchy report
// are where that is CHECKED (two trace-encoder-controller nodes, TacitEncoder + TacitEncoder_N).
//
// THE mcycle FREE-RUN PATCH IS WHAT MAKES TWO ENCODERS WORTH HAVING.  patches/0004 takes
// reg_wfi out of the cycle counter's enable, so the two harts' mcycle -- which IS the TACIT
// timebase -- stay locked to one clock and the two traces can be merged onto one axis.
// TACIT_MULTICORE.md measures barrier skew going from 8,857,274 cycles to 64 across that one
// token.  It is applied to the shared rocket-chip tree by scripts/07_patch_rocketchip.sh and
// is therefore in EVERY elaboration taken from that tree since 2026-09-15, this one included
// -- it is not a distinguishing feature of this config, it is a precondition of the tree, and
// the bundle's .provenance is where it is recorded per build.
//
// WHAT IS REMOVED, AND WHAT THAT LEAVES BEHIND.  Against
// PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cBtnCamConfig (0x5A5A0037's config plus
// the camera), this config drops BOTH RoCC fragments: chipyard.roccmoon.WithRoccMoon(hart = 1,
// nch = 8) and chipyard.config.WithMultiRoCC.  It drops them by NOT APPLYING THEM -- this is a
// fresh chain off PynqZ2RocketBigLittlePextTacitMicRgbConfig, not a subtractive fragment --
// because there is no "remove the RoCC" fragment that is sound: WithMultiRoCC rewrites
// BuildRoCC to read MultiRoCCKey, so undoing it means restoring a key's default rather than
// mapping over it.
//
// THERE IS NO STUB LEFT.  BuildRoCC is `Field[Seq[Parameters => LazyRoCC]](Nil)`
// (rocket-chip tile/LazyRoCC.scala:22) and nothing in this chain writes it, so p(BuildRoCC) is
// Nil on BOTH tiles and BaseTile.usingRoCC (BaseTile.scala:61) is false on both.  Everything
// downstream is guarded on it: no RoCCDecode table is prepended to the decoder
// (RocketCore.scala:241), no id_rocc_busy term (428), no RoCC port block (839), and no
// RoccCommandRouter / RoccMoonShim / RoccMoonEngine is elaborated at all.  Two consequences
// that are NOT cosmetic and are stated here rather than discovered on the board:
//
//   * HART 1 NOW TRAPS ON custom-1.  WithRoccMoon set RoCCDecodeOpcodes to custom-1 so hart 1
//     decoded the engine's dispatch; with no RoCC there is no custom-1 decode on either hart.
//     Every ModelBlaster kernel that dispatches to the engine raises an illegal instruction
//     here.  Hart 0 keeps custom-0 (the MBP ALU) -- that is the whole point of the variant.
//   * mstatus.XS READS 0 INSTEAD OF 3 (CSR.scala:394) and misa loses its X bit unless
//     patches/0008 sets customIsaExt.  Nothing in this repo's guests reads either.
//
// AND ONE CONFLICT THAT CANNOT FIRE ANY MORE: patches/0008's
// require(!(coreParams.usePExt && usingRoCC)) (RocketCore.scala:232) is what forced
// WithMultiRoCC into every engine config in the first place, so that tile 0 did not see a
// global BuildRoCC.  With no RoCC anywhere, usePExt on tile 0 is unconditionally legal.
//
// WHAT IS KEPT, DELIBERATELY, SO THE TRACE IS OF THE SAME MACHINE:
//   * WithPipelinedMulOnTiles(0) -- hart 0's mulUnroll = 64 pipelined multiplier (0x5A5A0011).
//     The traced software is M-extension heavy; tracing it on the iterative multiplier would
//     be tracing a different core from the one every measured number on this bench comes from.
//   * WithL2SkipCleanRelease -- patch 0092's L2 Field (0x5A5A001A).  It changes the generated
//     MSHR, so leaving it out would change the memory system under the trace.
//   * WithPExtOnTiles(0), the PDM mic at 0x1009_0000, the six RGB pins, WithI2C at 0x1004_0000,
//     WithGPIOWidth(10) for BTN0..BTN3 on pins 6..9, and the ospi capture DMA at 0x1008_0000
//     with WithOspiPunchthrough -- all byte-for-byte the fragments the panel and camera
//     configs above use, in the same order.
//
// THE PLIC.  The peripheral set here (I2C, UART, GPIO x 10, ospi) is the same set B137's
// ...I2cBtnCamNoTacitConfig has, and TACIT contributes NO interrupt (it is MMIO and a bus
// master only), so the numbering is expected to be i2c 1, uart 2, gpio 3..12, ospi 13,
// riscv,ndev 13.  EXPECTED is not measured: B136 got a console wrong by assuming a PLIC
// number, so the Zephyr board for this MAGIC reads the numbering out of this config's own
// generated DTS (or out of the bitstream's bootrom, gen-collateral/TLROM.sv).
//
// WithOspiTiedOff is the TestHarness binder, present for the same reason
// PynqZ2RocketTacitCamConfig needs it: Chisel refuses to finish with an uninitialised sink.
// ChipTop -- which is all the bitstream is built from -- never sees it.
class PynqZ2RocketBigLittlePextTacitMicRgbI2cBtnCamConfig extends Config(
  new WithOspiTiedOff ++
  new chipyard.iobinders.WithOspiPunchthrough ++
  new ospi.WithOspiCaptureDma(frameBufferDepth = 512) ++
  new WithGPIOWidth(10) ++
  new chipyard.config.WithI2C ++
  new WithL2SkipCleanRelease ++
  new WithPipelinedMulOnTiles(0) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbConfig)
