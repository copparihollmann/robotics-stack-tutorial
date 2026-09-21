# Build a PYNQ-Z1/Z2 Rocket + TACIT + PS-DDR bitstream.
#
#   vivado -mode batch -source tcl/build_rocket.tcl      -tclargs [synth|all]  single core
#   vivado -mode batch -source tcl/build_rocket_smp.tcl  -tclargs [synth|all]  dual core
#   vivado -mode batch -source tcl/build_rocket_pext.tcl -tclargs [synth|all]  dual core + MBP
#
# Sources come from a Chipyard elaboration; see chipyard/README.md for how to produce it.
# Override the location with the CHIPYARD_GENSRC environment variable.
#
# ONE SCRIPT, TWO VARIANTS. The single-core and dual-core SoCs present an IDENTICAL
# ChipTop port list -- verified by diffing the generated ChipTop.sv module headers -- so
# src/pynqz2_rocket_top.v, src/axi4_to_axi3.v and src/pynqz2_rocket.xdc are shared
# unchanged and the only differences are which generated-src to read, where to write, and
# the SOC_MAGIC the PS reads back over GP0 to tell the two bitstreams apart.
# ROCKET_VARIANT defaults to "tacit", which reproduces the original single-core build
# exactly; tcl/build_rocket_smp.tcl sets it to "smp" and tcl/build_rocket_pext.tcl to
# "pext".
#
# THE CLOCK IS PER-VARIANT. "tacit" and "smp" are both timed at 40 MHz and their numbers
# in docs/DUAL_CORE.md are 40 MHz numbers. "pext" asks for 35 MHz, because the depth-3
# DOT8 and the 32x32 QMUL do not fit a 25 ns EX stage (PEXT_FEASIBILITY.md section 2).
#
# "35 MHz" IS 34.4828 MHz, AND THAT IS NOT A ROUNDING NOTE -- it is the number every other
# file has to carry. FCLK0 on this PS7 is IO PLL / (DIVISOR0 * DIVISOR1), the IO PLL is
# 50 MHz * 20 = 1000 MHz, and both divisors are integers. 1000/40 = 25 = 5*5 exactly, which
# is why the 40 MHz builds are exactly 40 MHz. 1000/35 = 28.571 is NOT an integer, so
# MEASURED, by querying the configured IP:
#
#   requested 35      -> DIVISOR0=29 DIVISOR1=1  -> PCW_CLK0_FREQ = 34,482,761 Hz (29.000 ns)
#   requested 35.7143 -> DIVISOR0=7  DIVISOR1=4  -> PCW_CLK0_FREQ = 35,714,283 Hz (28.000 ns)
#
# 1000/29 is the closest the part can get to 35 MHz, so this build is CONSTRAINED and RUN
# at 34.4828 MHz. PYNQ's Clocks.fclk0_mhz setter searches the same integer-divisor product
# space and independently picks 29 for a request of 35, so the board agrees with the
# constraint -- but only because both round the same way, which is why host/run_rocket_pext.py
# asks for 34.4828 explicitly rather than 35.
#
# The actual frequency has to agree with three other places, or the board misbehaves in a
# way that does not look like a clock problem:
#   * CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC in the Zephyr board  -> 34483 (mtime = clock/1000),
#     which ALSO sets the SiFive UART baud divisor; wrong here gives a GARBLED console
#     rather than a silent one. 35000 against this clock is 1.21% of baud error -- it would
#     probably still work, and it would be wrong.
#   * host/run_rocket_pext.py's --fclk default                -> 34.4828
#   * whatever this synthesises against                       -> PCW_FPGA0_PERIPHERAL_FREQMHZ
set root  [file normalize [file dirname [info script]]/..]
set stage [expr {$argc > 0 ? [lindex $argv 0] : "all"}]
set variant [expr {[info exists ::env(ROCKET_VARIANT)] ? $::env(ROCKET_VARIANT) : "tacit"}]
switch -- $variant {
  tacit {
    set cfg        "PynqZ2RocketTacitConfig"
    set projname   "pynqz2_rocket"
    set builddir   "build_rocket"
    set bitsuffix  "rocket_tacit"
    set soc_magic  "32'h5A5A0002"
    set fclk_mhz   40
  }
  smp {
    set cfg        "PynqZ2RocketBigLittleTacitConfig"
    set projname   "pynqz2_rocket_smp"
    set builddir   "build_rocket_smp"
    set bitsuffix  "rocket_smp"
    set soc_magic  "32'h5A5A0003"
    set fclk_mhz   40
  }
  pext {
    set cfg        "PynqZ2RocketBigLittlePextTacitConfig"
    set projname   "pynqz2_rocket_pext"
    set builddir   "build_rocket_pext"
    set bitsuffix  "rocket_pext"
    set soc_magic  "32'h5A5A0004"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; see the note above
  }
  mic {
    # The P-ext SoC plus the board's PDM microphone on the periphery bus at 0x1009_0000.
    # Pin-compatible with the pext bitstream in every other respect, which is exactly why
    # it needs its own MAGIC: without one, run_rocket_pext.py would happily drive this
    # image and a mic run would happily drive that one, and neither would say anything.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicConfig"
    set projname   "pynqz2_rocket_mic"
    set builddir   "build_rocket_mic"
    set bitsuffix  "rocket_mic"
    set soc_magic  "32'h5A5A0005"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; see the note above
    set has_mic    1
  }
  micrgb {
    # The mic SoC plus a sifive GPIO controller at 0x1001_0000 whose six pins are the
    # board's two RGB LEDs, LD4 and LD5. Same clock, same harts, same microphone; the
    # only additions are one stock Chipyard peripheral and six package balls.
    #
    # ITS OWN MAGIC, for the same reason every other variant has one: this design is
    # register-compatible with the mic design for everything the mic labs touch, so
    # 34_rocket_mic_capture.sh would run happily against it and say nothing, and
    # 35_rocket_rgb_leds.sh would run happily against the MIC bitstream and find a GPIO
    # controller that is not there. The PLIC also differs (riscv,ndev = 7 against 1), so
    # the two are NOT interchangeable for an image that enables the GPIO driver.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbConfig"
    set projname   "pynqz2_rocket_micrgb"
    set builddir   "build_rocket_micrgb"
    set bitsuffix  "rocket_micrgb"
    set soc_magic  "32'h5A5A0006"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; see the note above
    set has_mic    1
    set has_rgb    1
  }
  bw {
    # The full-feature SoC (micrgb) plus a TileLink BANDWIDTH INSTRUMENT on the system
    # bus: rtl_study/rocc/mbxd_dma.v behind an MMIO control block at 0x100A_0000.
    #
    # WHY IT IS BUILT ON micrgb RATHER THAN ON SOMETHING SMALLER.  The point of the
    # measurement is what the memory system delivers to the workloads, so it has to be
    # the memory system the workloads run on -- the same 64 KB inclusive L2, the same
    # AXI4-to-AXI3 shim, the same PS DDR window, the same two harts and the same
    # TraceSinkDMA sharing the bus. A stripped-down SoC would measure a different
    # machine and every comparison with MEMORY_HIERARCHY.md would become an argument.
    #
    # NOTE WHAT IS *NOT* DIFFERENT.  has_mic and has_rgb are both 1 and the XDC list,
    # the -verilog_define set and src/pynqz2_rocket_top.v are byte-identical to the
    # micrgb build. The instrument attaches through a testchipip SubsystemInjector, so
    # it has no pins and needs no IOBinder. The only deltas between this bitstream and
    # 0x5A5A0006 are the generated Verilog, one BlackBox file, and this magic.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwConfig"
    set projname   "pynqz2_rocket_micrgb_bw"
    set builddir   "build_rocket_micrgb_bw"
    set bitsuffix  "rocket_micrgb_bw"
    set soc_magic  "32'h5A5A0007"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; see the note above
    set has_mic    1
    set has_rgb    1
    set has_bw     1
  }
  bwfast {
    # LEVER 2: the bandwidth instrument with the MEMORY BUS ON ITS OWN CLOCK.
    #
    # Identical to `bw` except that mbus, the AXI4-to-AXI3 shim and S_AXI_HP0 run on
    # FCLK1 instead of FCLK0, with a real TileLink AsynchronousCrossing between the
    # system bus and the memory bus.  The core, the L2 and everything else stay at
    # 34.4828 MHz, because that clock is set by the P-extension's critical path
    # (PEXT_BITSTREAM.md) and nothing about the AXI path requires it.
    #
    # MEMORY_BANDWIDTH.md section 2 is why: with lever 1 in place the L2 path saturates
    # its 64-bit link at EXACTLY 8.00 B/cycle, so its ceiling IS the clock.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwFastConfig"
    set projname   "pynqz2_rocket_micrgb_bwfast"
    set builddir   "build_rocket_micrgb_bwfast"
    set bitsuffix  "rocket_micrgb_bwfast"
    set soc_magic  "32'h5A5A0008"
    set fclk_mhz   35          ;# core/uncore -> 34.4828 MHz actual
    set has_mic    1
    set has_rgb    1
    set has_bw     1
    set has_memclk 1
    set fclk_mem_mhz 100       ;# FCLK1; 1000/10, so it lands exactly
  }
  bwports {
    # LEVER 3: the bandwidth instrument with TWO memory channels, into S_AXI_HP0 and HP1.
    #
    # Built on `bw` and NOT on `bwfast`, so the comparison isolates PORTS at one clock.
    #
    # WHY IT IS BUILT AT ALL, given that MEMORY_BANDWIDTH.md section 3.5 predicts it will
    # not help: that prediction comes from a NEGATIVE result (lever 2 moved the DRAM
    # number by -1%), and a prediction derived from a null result is exactly the kind that
    # deserves one measurement rather than a paragraph.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwPortsConfig"
    set projname   "pynqz2_rocket_micrgb_bwports"
    set builddir   "build_rocket_micrgb_bwports"
    set bitsuffix  "rocket_micrgb_bwports"
    set soc_magic  "32'h5A5A0009"
    set fclk_mhz   35
    set has_mic    1
    set has_rgb    1
    set has_bw     1
    set has_nmem2  1
  }
  bwl2mshr {
    # THE L2 MISS PATH, experiment (a), handlers: the lever-1 instrument build with the L2's
    # outerLatencyCycles raised 40 -> 80, which is what sizes its miss handlers --
    # 7 -> 12 MSHRs, 5 -> 10 of them able to take a Get.  MEMORY_BANDWIDTH.md section 6.
    # Same top level, same XDC, same defines as `bw`: the generated Verilog and this magic
    # are the only differences.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwL2Mshr12Config"
    set projname   "pynqz2_rocket_micrgb_bwl2mshr"
    set builddir   "build_rocket_micrgb_bwl2mshr"
    set bitsuffix  "rocket_micrgb_bwl2mshr"
    set soc_magic  "32'h5A5A000B"
    set fclk_mhz   35
    set has_mic    1
    set has_rgb    1
    set has_bw     1
  }
  bwl2cap {
    # Experiment (a), capacity: the L2 at 256 KB (4 ways, 1024 sets) instead of 64 KB, with
    # the same seven MSHRs.  Separate from bwl2mshr because capacity and handlers predict
    # different things.  MEMORY_BANDWIDTH.md section 6.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwL2Cap256Config"
    set projname   "pynqz2_rocket_micrgb_bwl2cap"
    set builddir   "build_rocket_micrgb_bwl2cap"
    set bitsuffix  "rocket_micrgb_bwl2cap"
    set soc_magic  "32'h5A5A000C"
    set fclk_mhz   35
    set has_mic    1
    set has_rgb    1
    set has_bw     1
  }
  bwl2cork {
    # The L2 miss path, the MECHANISM test: the lever-1 instrument build with TLCacheCork
    # serving ReleaseAck ahead of GrantData (patches/0091, WithCacheCorkReleaseAckFirst).
    # The model in rtl_study/l2tb predicts 7.11 B/cycle at 4/6/8 in flight.
    # MEMORY_BANDWIDTH.md section 6.  Same top level, XDC and defines as `bw`.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwL2CorkConfig"
    set projname   "pynqz2_rocket_micrgb_bwl2cork"
    set builddir   "build_rocket_micrgb_bwl2cork"
    set bitsuffix  "rocket_micrgb_bwl2cork"
    set soc_magic  "32'h5A5A000E"
    set fclk_mhz   35
    set has_mic    1
    set has_rgb    1
    set has_bw     1
  }
  bwl2skip {
    # The L2 miss path, the fix: a clean victim sends no outer Release (patches/0092,
    # WithL2SkipCleanRelease).  The model in rtl_study/l2tb predicts ~8.00 B/cycle at 6/8 in
    # flight -- the 64-bit link.  MEMORY_BANDWIDTH.md section 6.  Same top level, XDC and
    # defines as `bw`.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwL2SkipConfig"
    set projname   "pynqz2_rocket_micrgb_bwl2skip"
    set builddir   "build_rocket_micrgb_bwl2skip"
    set bitsuffix  "rocket_micrgb_bwl2skip"
    set soc_magic  "32'h5A5A001A"   ;# not 000F: that one was also given to lever 4's 256-bit build
    set fclk_mhz   35
    set has_mic    1
    set has_rgb    1
    set has_bw     1
  }
  bwl2wsf {
    # The L2 path past one 64-bit beat (MEMORY_BANDWIDTH.md section 6.9): a 128-bit L2 on both
    # sides (lever 4's system bus + WithEdgeDataBits(128)), clean Releases skipped (0092),
    # 7 MSHRs, and lever 2's memory bus + AXI shim + S_AXI_HP0 on FCLK1 so the 64-bit HP port
    # can supply a 128-bit TL beat every L2 cycle.  Top level is lever 2's (has_memclk).
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipFastConfig"
    set projname   "pynqz2_rocket_micrgb_bwl2wsf"
    set builddir   "build_rocket_micrgb_bwl2wsf"
    set bitsuffix  "rocket_micrgb_bwl2wsf"
    set soc_magic  "32'h5A5A0018"
    set fclk_mhz   35
    set has_mic    1
    set has_rgb    1
    set has_bw     1
    set has_memclk 1
    set fclk_mem_mhz 100
  }
  bwl2wsmf {
    # The L2 path past one 64-bit beat (MEMORY_BANDWIDTH.md section 6.9): a 128-bit L2 on both
    # sides (lever 4's system bus + WithEdgeDataBits(128)), clean Releases skipped (0092),
    # 12 MSHRs, and lever 2's memory bus + AXI shim + S_AXI_HP0 on FCLK1 so the 64-bit HP port
    # can supply a 128-bit TL beat every L2 cycle.  Top level is lever 2's (has_memclk).
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwL2WideSkipM12FastConfig"
    set projname   "pynqz2_rocket_micrgb_bwl2wsmf"
    set builddir   "build_rocket_micrgb_bwl2wsmf"
    set bitsuffix  "rocket_micrgb_bwl2wsmf"
    set soc_magic  "32'h5A5A0019"
    set fclk_mhz   35
    set has_mic    1
    set has_rgb    1
    set has_bw     1
    set has_memclk 1
    set fclk_mem_mhz 100
  }
  bwl2fast {
    # Experiment (b): the L2 ON A FASTER CLOCK.  The tiles stay on FCLK0 at 34.4828 MHz,
    # behind a rocket-chip AsynchronousCrossing; the sbus, the L2, mbus, pbus and the
    # instrument move to FCLK1.  It reuses lever 2's FCLK1 plumbing wholesale (has_memclk:
    # fclk_mem, the shim and S_AXI_HP0 on FCLK1, pynqz2_memclk.xdc) and adds only the
    # ChipTop clock swap in pynqz2_rocket_top.v (PYNQZ2_HAS_TILECLK).
    #
    # FCLK1 IS SWEPT.  One config, one magic; each frequency is a separate build, told apart
    # by md5, in its own directory: ROCKET_FCLK_MEM_MHZ picks the clock and
    # ROCKET_BUILD_TAG names the directory.  The default is FCLK1 = FCLK0, the crossing-only
    # control.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwL2FastConfig"
    set projname   "pynqz2_rocket_micrgb_bwl2fast"
    set builddir   "build_rocket_micrgb_bwl2fast"
    set bitsuffix  "rocket_micrgb_bwl2fast"
    set soc_magic  "32'h5A5A000D"
    set fclk_mhz   35          ;# tiles -> 34.4828 MHz actual
    set has_mic    1
    set has_rgb    1
    set has_bw     1
    set has_memclk 1
    set has_tileclk 1
    set fclk_mem_mhz 34.4828   ;# uncore incl. the L2; override with ROCKET_FCLK_MEM_MHZ
  }
  bwwide {
    # LEVER 4: the bandwidth instrument on a 128-BIT TILELINK SYSTEM BUS.
    #
    # Built on `bw` and on nothing else: one HP port, one clock, so the comparison with
    # 0x5A5A0007 is the bus width.  Everything that differs is inside ChipTop --
    # PynqZ2Configs.scala's WithWideSystemBus(128), which also pins both harts' L1 rowBits
    # at 64 and holds the L2 at 7 MSHRs -- so there is no has_* flag here and
    # src/pynqz2_rocket_top.v, the XDC list and the -verilog_define set are `bw`'s.  The
    # memory bus, ExtMem and S_AXI_HP0 stay 64-bit: the L2 is the 128 -> 64 adapter.
    #
    # COMPOSABLE: a wide sbus stacks with `bwfast`'s memory clock (has_memclk) or
    # `bwports`'s second channel (has_nmem2) by naming a config that adds
    # WithWideSystemBus(128) to theirs and copying their flags -- no top-level change.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwWideConfig"
    set projname   "pynqz2_rocket_micrgb_bwwide"
    set builddir   "build_rocket_micrgb_bwwide"
    set bitsuffix  "rocket_micrgb_bwwide"
    set soc_magic  "32'h5A5A000A"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; see the note above
    set has_mic    1
    set has_rgb    1
    set has_bw     1
  }
  bwwide256 {
    # LEVER 4, second point: the same on a 256-BIT system bus (MEMORY_BANDWIDTH.md 5.7).
    # 128 bits measured 16.00 B/cycle, its D channel exactly; 256 is also the last width
    # that can pay for 64-byte Gets, because the L2's single-port Directory caps a hit
    # stream at 0.5 Gets per cycle = 32 B/cycle.  Everything else as `bwwide`.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbBwWide256Config"
    set projname   "pynqz2_rocket_micrgb_bwwide256"
    set builddir   "build_rocket_micrgb_bwwide256"
    set bitsuffix  "rocket_micrgb_bwwide256"
    set soc_magic  "32'h5A5A000F"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; see the note above
    set has_mic    1
    set has_rgb    1
    set has_bw     1
  }
  roccmoon {
    # THE DECOUPLED ACCELERATOR (ROCC_DECOUPLED.md section 8): the full-feature SoC (micrgb)
    # plus rtl_study/roccmoon/mbxr_engine.v as a RoCC on hart 1, its weight and activation
    # clients on the system bus.  Built on micrgb and NOT on bw, so the only delta against
    # 0x5A5A0006 is the accelerator: same top level, same XDC files, same defines.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoon"
    set builddir   "build_rocket_micrgb_roccmoon"
    set bitsuffix  "rocket_micrgb_roccmoon"
    set soc_magic  "32'h5A5A0010"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual
    set has_mic    1
    set has_rgb    1
    set has_roccmoon 1
    # Engine revision 1, the files this bitstream was built from: rtl_study/ moved to revision
    # 2a on 2026-09-17, so a rebuild reads the md5-checked snapshot (src/cam_engine_rev1).
    set roccmoon_rtl_snapshot src/cam_engine_rev1
  }
  roccmoonmul {
    # THE FAST MULTIPLIER (ROCC_DECOUPLED.md section 8.15.3): `roccmoon` with the BIG core's
    # MulDivParams.mulUnroll = 64, so RocketCore instantiates PipelinedMultiplier(64, 2) and
    # mul/mulh stop stalling the pipeline (the divider stays in MulDiv).  The LITTLE core's
    # MulDiv is unchanged.  Everything else is `roccmoon`: same top level, XDC, defines and
    # engine RTL, so the delta against 0x5A5A0010 is hart 0's multiplier.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonMulConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonmul"
    set builddir   "build_rocket_micrgb_roccmoonmul"
    set bitsuffix  "rocket_micrgb_roccmoonmul"
    set soc_magic  "32'h5A5A0011"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual
    set has_mic    1
    set has_rgb    1
    set has_roccmoon 1
    # Engine revision 1, as 0x5A5A0011 was built (see roccmoon).
    set roccmoon_rtl_snapshot src/cam_engine_rev1
  }
  roccmoon2a {
    # ENGINE REVISION 2a (ROCC_DECOUPLED.md section 8.15.5): `roccmoon` with rtl_study/'s
    # revision-2a engine -- the drain's acknowledged watermark (fence bits 63:48, which gates
    # incremental placement), one DMA per TileLink client with the weight half as its own module,
    # two scratchpad write ports on disjoint banks with a read enable per bank, and sticky errors
    # for three driver protocol violations.  One clock, revision 1's port list: the Chisel shim
    # and the elaborated SoC are 0x5A5A0010's, so the only delta is the engine RTL.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoon2a"
    set builddir   "build_rocket_micrgb_roccmoon2a"
    set bitsuffix  "rocket_micrgb_roccmoon2a"
    set soc_magic  "32'h5A5A0012"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual
    set has_mic    1
    set has_rgb    1
    set has_roccmoon 1
  }
  roccmoon2b {
    # ENGINE REVISION 2b: the weight half on its OWN AXI4 port and its own clock (MEMORY_BANDWIDTH.md
    # sections 9.9 and 9.10, design (ii')).  W leaves the system bus: chipyard.wlane (patches/0110)
    # gives ChipTop axi4_wlane_0 and clock_wlane, the top level takes that port through its own
    # axi4_to_axi3 onto S_AXI_HP2 at FCLK1 = 100 MHz, and the L2's channel keeps S_AXI_HP0 on FCLK0 --
    # so the harts' DRAM path is untouched and costs them nothing.  Activations and results stay on
    # SBUS through the L2.
    #
    # THE BASE IS 0x5A5A0028, NOT 0x5A5A0010: the config is RoccMoonAll's (revision 2a's engine, the
    # big core's pipelined multiplier, 0092's skipped clean Release) plus the lane, so the A/B against
    # 0028 isolates the lane against encoder images already measured on that bitstream (RTF 3.759).
    # On the engine itself 0092 is worth 6.006 -> 6.203 B/cycle -- the fill is latency-bound at an
    # outstanding cap of 3 -- which is the reason this variant exists (MEMORY_BANDWIDTH.md 9.9).
    #
    # The engine RTL is rtl_study/roccmoon/rev2 (revision 2b), NOT the revision-1 snapshot and not
    # roccmoon/'s revision-2a files: rev2/mbxr_engine.v also defines mbxr_engine and mbxr_st, so the
    # two sets cannot both be in the project.
    #
    # Its gate is the two-clock simulation in MEMORY_BANDWIDTH.md 9.9 on the generated RTL of this
    # config (archive/rtl_study/wlanetb/gate_rev2b_v3): the AR contract, the abort-drain, finding (a)
    # (a short reset must not release the lane with bursts outstanding) and finding (b) (no Get
    # outside the weight window), with fence bit 41 enforced.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoon2bConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoon2b"
    set builddir   "build_rocket_micrgb_roccmoon2b"
    set bitsuffix  "rocket_micrgb_roccmoon2b"
    set soc_magic  "32'h5A5A0013"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual
    set fclk_wlane_mhz 100     ;# FCLK1, the weight lane only; 1000/10, so the PLL lands exactly
    set has_mic    1
    set has_rgb    1
    set has_roccmoon2b 1
    set has_wlane  1
  }
  roccmoonall {
    # EVERY MEASURED LEVER IN ONE BUILD (ROCC_DECOUPLED.md 8.15.9): `roccmoon2a`'s engine (revision
    # 2a, whose acknowledged watermark lets the driver place results while the engine runs) plus the
    # big core's pipelined multiplier (0x5A5A0011) plus 0092's skipped clean Release (0x5A5A001A).
    # The engine RTL is rtl_study/'s, as roccmoon2a reads it; the config is elaborated on its own,
    # because InclusiveCacheSkipCleanRelease changes the generated MSHR.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonall"
    set builddir   "build_rocket_micrgb_roccmoonall"
    set bitsuffix  "rocket_micrgb_roccmoonall"
    set soc_magic  "32'h5A5A0028"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual
    set has_mic    1
    set has_rgb    1
    set has_roccmoon 1
  }
  roccmoonlanes {
    # THE TWO LANES INSIDE THE ENGINE (LAYERNORM_LANE.md s11, ATTENTION_UNIT.md s7).
    # MAGIC 0x5A5A002A since 2026-09-17.  It built 0x5A5A0029 at commit ca4a990, before
    # merge/mbxr_lanes.v gained the streamer's two-pass replay (LAYERNORM_LANE.md s18); that
    # bitstream is archive/bitstreams/0x5A5A0029_roccmoonlanes_3710420a.bit and its reports are
    # in archive/builds/.  002A is 0029 plus ten lines of streamer and nothing else.
    # It is `roccmoonall` (0x5A5A0028) PLUS mbxa_core and mbxr_ln, and
    # nothing else: the same elaborated SoC -- the BlackBox port list does not change, so the
    # config, the gensrc bundle, the top level, the XDC and the -verilog_define set are
    # 0028's byte for byte.  The only delta is the engine's Verilog, which is read from
    # rtl_study/roccmoon/merge/ rather than rtl_study/roccmoon/: merge/mbxr_engine.v also
    # defines mbxr_engine, mbxr_engine_core and mbxr_whalf, so roccmoon/mbxr_engine.v must
    # NOT be added alongside it (the guard below refuses has_roccmoon with has_lanes).
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonlanes"
    set builddir   "build_rocket_micrgb_roccmoonlanes"
    set bitsuffix  "rocket_micrgb_roccmoonlanes"
    set soc_magic  "32'h5A5A002A"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; ROCKET_FCLK_MHZ overrides it
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
  }
  roccmoonlut {
    # THREE LANES INSIDE THE ENGINE: 0x5A5A002A PLUS T4's LUT LANE (T4_LANES.md s6).
    # MAGIC 0x5A5A002C -- claimed 2026-09-17, MOVED from 002B after a same-minute collision
    # with `lanesdev` (MAGIC_REGISTRY.md carries both commits and why mine moved).
    #
    # It is `roccmoonlanes` byte for byte except the MAGIC: the same config, gensrc bundle,
    # top level, XDC and -verilog_define set, and the same merge/ RTL -- which since 86b89cd
    # CONTAINS mbxl_lut as lane 4.  So a rebuild of roccmoonlanes would now also carry the LUT
    # lane while stamping 002A, which is why this variant exists rather than a rebuild: 002A's
    # registry row describes a two-lane engine and must keep meaning that.
    #
    # THE FIT RISK, RECORDED BEFORE THE BUILD (MAGIC_REGISTRY.md's 002C row, and T4_LANES.md
    # s4): 0x5A5A0029 placed at 95.23 % slice occupancy and 002A at 94.25 %.  The LUT lane is
    # 592 LUT out of context, ~170 slices at this design's 3.54 LUT/slice, so ~95.7 %.
    # IF THIS FAILS TO PLACE THAT IS A FINDING ABOUT THE PART, NOT ABOUT THE LANE -- an
    # xc7z020 holds three of T4's four tiers and the fourth needs something to come out.  The
    # measured mitigation is `lanesdev` (0x5A5A002B) at 74.32 %, where lane FUNCTION can be
    # proven independently of fit.
    #
    # WHAT IS VERIFIED AND WHAT IS NOT.  mbxl_lut: 53 dispatches / 73,936 byte checks / 0
    # differ and 11 of 11 mutants killed in Verilator (lut_lane/run_tb.sh, mutants.sh); 592
    # LUT / 0 DSP / 0 BRAM / WNS +20.881 out of context.  NOTHING HAS DISPATCHED TO IT ON
    # SILICON, and a closed bitstream here must not be read as a working lane until M1 and M2
    # (T4_LANES.md s8.4-8.5) have run.  Still covered by nothing, as for 0029 and 002A:
    # `own` switching between lanes, and tseq reclaiming the array after a lane.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonlut"
    set builddir   "build_rocket_micrgb_roccmoonlut"
    set bitsuffix  "rocket_micrgb_roccmoonlut"
    set soc_magic  "32'h5A5A002C"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; ROCKET_FCLK_MHZ overrides it
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
  }
  roccmoonlut2 {
    # 0x5A5A002C's SoC WITH THE LUT LANE'S out_valid FIXED (T4_LANES.md s11).  MAGIC
    # 0x5A5A002D, claimed in MAGIC_REGISTRY.md in the same commit as this block.
    #
    # It is `roccmoonlut` byte for byte except the MAGIC: same config, gensrc bundle, top
    # level, XDC and -verilog_define set.  The ONE difference is inside
    # rtl_study/roccmoon/lut_lane/mbxl_lut.v -- `assign out_valid = o0_fire` rather than
    # `o0_v`, one AND gate -- so `git diff` between the two builds' ENGINE_RTL hashes is the
    # whole change.
    #
    # WHY NOT A SECOND BUILD OF 002C.  The registry permits two builds of one config under one
    # MAGIC and the labs gate on md5.  What does not permit it is that another workstream is
    # measuring on fc26e76d right now and its gate pins that file; overwriting it would break
    # a live run.
    #
    # WHAT 002C ESTABLISHED AND THIS INHERITS: the lane fits and closes.  44,904 LUT, 95.62 %
    # slices, WNS +0.552.  One AND gate does not move that, and if this fails to place after
    # 002C placed, that is a tool-noise finding and not a design one.
    #
    # WHAT IS VERIFIED HERE AND WAS NOT FOR 002C: the lane THROUGH mbxr_lanes INTO mbxr_st,
    # by lut_lane/tb_lutint.cpp -- the integration arm A hung in.  8 to 1,024 words, every
    # size byte-exact and returning ownership.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonlut2"
    set builddir   "build_rocket_micrgb_roccmoonlut2"
    set bitsuffix  "rocket_micrgb_roccmoonlut2"
    set soc_magic  "32'h5A5A002D"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; ROCKET_FCLK_MHZ overrides it
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
  }
  roccmoondrain {
    # 0x5A5A002D's SoC WITH THE 2-D DRAIN (rtl_study/roccmoon/STRIDED_DRAIN.md).  MAGIC
    # 0x5A5A002E, claimed in MAGIC_REGISTRY.md in the same commit as this block.
    #
    # NOT a Verilog-only respin.  0029 -> 002A -> 002C -> 002D were each "the same config, the
    # same gensrc bundle, the same top level" because mbxr_engine is a BlackBox and every change
    # was inside it.  THIS ONE MOVES THE BLACKBOX PORT LIST -- `aa_size[1:0]`, the drain's
    # PutFullData size -- so the SoC must be RE-ELABORATED.  Point CHIPYARD_GENSRC at the
    # elaboration of PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig with this repo's
    # RoccMoon.scala installed; the VENDORED bundle for that config is 002D's and instantiates
    # mbxr_engine_core WITHOUT aa_size, which would leave the size output dangling and every
    # drain transaction 64 bytes wide -- silently wrong, not a build error.  build_rocket.tcl
    # refuses that below.
    #
    # WHAT 002D ESTABLISHED AND THIS INHERITS: the engine, the attention unit, the LayerNorm
    # lane and the LUT lane all fit and close at 44,897 LUT (84.39 %) and 12,725 slices
    # (95.68 %), WNS +0.374.  The band for the delta is in STRIDED_DRAIN.md, written before the
    # synthesis that scores it: +90..+240 LUT, +80..+130 FF, DSP and BRAM unchanged, WNS within
    # +/- 0.15 ns.  At 95.68 % slices the falsifier is placement, not LUT count.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoondrain"
    set builddir   "build_rocket_micrgb_roccmoondrain"
    set bitsuffix  "rocket_micrgb_roccmoondrain"
    set soc_magic  "32'h5A5A002E"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; ROCKET_FCLK_MHZ overrides it
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
  }
  roccmoonint6 {
    # 0x5A5A002E's SoC WITH THE 6-BIT WEIGHT UNPACKER at the engine's read port.  MAGIC
    # 0x5A5A002F, claimed in MAGIC_REGISTRY.md in the same commit as this block.
    #
    # A VERILOG-ONLY RESPIN, and it genuinely is one: the BlackBox port list does not move --
    # no engine port is added, the grid is a `cfg` bit (rs1[48]) inside the existing command --
    # so this reads 0x5A5A002E's gensrc bundle, top level and XDC unchanged.  need_aa_size
    # stays 1 because the drain descriptor is 002E's.
    #
    # WHY A NEW MAGIC AND NOT A SECOND BUILD OF 002E.  The content differs by +429 LUT of
    # fabric that changes what the silicon COMPUTES when a dispatch sets the new bit.  A lab
    # holding an int6 image against a 002E bitstream would get silently wrong numbers -- the
    # engine would read packed codes as bytes -- and that is exactly the class 6f3e6f98 cost
    # four board runs to learn.  Registered by CONTENT in MAGIC_FEATURES.tsv, feature
    # `wgt_int6`, so a lab is refused before it dispatches.
    #
    # ONE BITSTREAM RUNS BOTH ARMS.  A guest that never sets cfg rs1[48] gets, beat for beat,
    # the machine 002E is: compat/run_compat_tb.sh is unmoved at 119 / 1,078,701 / 96,619 /
    # 63,999,256 and tb_mbxr on merge/ is unmoved at 201 / 1,435,630 / 127,080 / 79,347,241.
    # So the A/B is one guest define (MBXR_RT_WBITS) and the int8 control is the decoder that
    # was already measured.
    #
    # WHAT 002E ESTABLISHED AND THIS INHERITS: 45,051 LUT (84.68 %), 12,858 slices (96.68 %),
    # WNS +0.719 -- and that the instrument's own run-to-run spread on this part is 0.585 ns
    # (6f3e6f98 and d6112edd are the same logic at +0.134 and +0.719).  The band for this
    # delta is in rtl_study/roccmoon/INT6_WEIGHTS.md, written before the synthesis that
    # scores it.  At 96.68 % slices the falsifier is TIMING, not LUT count.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonint6"
    set builddir   "build_rocket_micrgb_roccmoonint6"
    set bitsuffix  "rocket_micrgb_roccmoonint6"
    set soc_magic  "32'h5A5A002F"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual; ROCKET_FCLK_MHZ overrides it
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
  }
  roccmoonf40 {
    # 0x5A5A002E's SoC, BYTE FOR BYTE, TIMED AND RUN AT FCLK0 = 40.0000 MHz.  MAGIC
    # 0x5A5A0030, claimed in MAGIC_REGISTRY.md in the same commit as this block.
    #
    # THE ONLY DIFFERENCE FROM `roccmoondrain` IS THE CLOCK (and the MAGIC that names it).
    # Same config, same gensrc bundle, same engine RTL, same top level, same XDC, same
    # -verilog_define set, same need_aa_size.  B79 built this netlist at ten FCLK0 values and
    # the post-synthesis netlist was bit-identical in all ten (46,496 LUT / 26,625 FF /
    # 141 DSP / 90.5 BRAM36); 40.0000 MHz (1000/25) is the HIGHEST that closes --
    # WNS +0.717, WHS +0.024, 0 failing endpoints of 93,776 -- and 41.6667 (1000/24) misses
    # by -0.267 ns on 2 endpoints.  archive/runs/b79_fclk0_ceiling/FALSIFIED.md.
    #
    # WHY A NEW MAGIC AND NOT `ROCKET_FCLK_MHZ=40` ON `roccmoondrain`.  B79's ten bitstreams
    # all bind 32'h5A5A002E, which is why archive/runs/b79_fclk0_ceiling/DO_NOT_LOAD.md exists.
    # A 40 MHz PL under a guest built for 34483 does not crash: CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC
    # also sets the SiFive UART's baud divisor, so the console garbles and `mtime` runs 16 %
    # fast while `mcycle` stays right -- plausible numbers, silently wrong, the class 6f3e6f98
    # cost four board runs to learn.  The MAGIC is what lets a guest, a runner and a lab refuse
    # the pair BEFORE the board: this one is bound at synthesis and travels with the clock.
    #
    # WHAT MUST TRAVEL WITH IT, and all of it lands in the same commit as this block:
    #   1. this MAGIC, registered BY CONTENT (md5) in MAGIC_FEATURES.tsv;
    #   2. boards/chipyard/pynqz1_micrgb_f40/, whose ONLY difference from pynqz1_micrgb is
    #      CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=40000 (the existing board is NOT edited);
    #   3. host/run_rocket_roccmoonf40.py (a symlink) in EXPECT_BY_RUNNER, and `--fclk 40`
    #      on the load line -- run_rocket.py programs fclk0_mhz only on the load path;
    #   4. the labs' `CLK` constant, which is what turns cycles into RTF.  A stale one does
    #      not fail: model_rtf_e2e.py reads clock_hz from the record and only checks that the
    #      two halves AGREE, and two halves at the same wrong clock agree perfectly.
    #
    # 40 MHz is EXACT on this PS7: FCLK0 = IO PLL / (DIVISOR0 * DIVISOR1) with the IO PLL at
    # 50 MHz * 20 = 1000 MHz, and 1000/40 = 25 = 5*5.  So the timed clock, the clock PYNQ's
    # Clocks.fclk0_mhz setter lands on, and the 40,000,000 Hz the labs divide by are one number.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonf40"
    set builddir   "build_rocket_micrgb_roccmoonf40"
    set bitsuffix  "rocket_micrgb_roccmoonf40"
    set soc_magic  "32'h5A5A0030"
    set fclk_mhz   40          ;# 1000/25, exact; the WHOLE of this variant's delta
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
    # THE ENGINE IS PINNED, not read live.  rtl_study/roccmoon/merge/ belongs to the int6
    # workstream and moved to 0x5A5A002F's d13170d8 while this block was written.  This
    # variant's whole claim is "0x5A5A002E's logic at a different clock", so it reads a
    # SNAPSHOT of 002E's thirteen lane files (merge/mbxr_engine.v cce8c84f, mbxr_tseq.v
    # 8596f212, mbxr_datapath.v 6c6aa1b8 and the ten that int6 did not touch), md5-checked
    # before Vivado reads a line of it.  Without this the build would silently carry the
    # unpacker as well as the clock and the arm would answer neither question.
    set lanes_rtl_snapshot src/lanes_engine_002e
  }
  roccmoonint6f40 {
    # THE TWO LEVERS COMPOSED: 0x5A5A002F's engine -- the 6-bit weight unpacker at the read
    # port -- AT FCLK0 = 40.0000 MHz.  MAGIC 0x5A5A0031, claimed in MAGIC_REGISTRY.md in the
    # same commit as this block.  It is `roccmoonf40` with the int6 snapshot instead of the
    # 002E one, and `roccmoonint6` with 40 MHz instead of 35; nothing else moves in either
    # direction, so the three-way A/B/C is one variant switch.
    #
    # THE ENGINE IS PINNED HERE TOO, and for the reason B79 was contaminated by: `add_files`
    # reads RTL at synth_design time, not at add time, so a build that names
    # rtl_study/roccmoon/merge/ takes whatever is in that directory WHEN VIVADO GETS THERE.
    # The int6 workstream edited those files at 19:52 on 2026-09-18 while B79's sweep was
    # running, and five of its ten arms silently changed design mid-sweep (+368 LUT at
    # b79f4167, visible in their own ENGINE_RTL lines).  src/lanes_engine_002f/ is that
    # directory's content taken once and md5-checked before every build, so this variant
    # cannot be moved underneath by an edit -- and if the workstream advances the engine, the
    # snapshot must be RE-TAKEN deliberately, which is the point.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonint6f40"
    set builddir   "build_rocket_micrgb_roccmoonint6f40"
    set bitsuffix  "rocket_micrgb_roccmoonint6f40"
    set soc_magic  "32'h5A5A0031"
    set fclk_mhz   40          ;# 1000/25, exact
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
    set lanes_rtl_snapshot src/lanes_engine_002f
    # MEASURED, AND IT NEEDS THE POST-ROUTE PASS.  The first draw of this variant missed at
    # WNS -0.647 with 25 failing endpoints; ROCKET_POSTROUTE_PHYSOPT=1 -- the opt-in already in
    # this file, added for bwwin's 2 ps miss -- takes it to +0.013 with 0 failing of 93,776.
    # BUILD IT AS:  ROCKET_POSTROUTE_PHYSOPT=1 ROCKET_VARIANT=roccmoonint6f40 ...
    # The registered md5 (de4ec983, MAGIC_FEATURES.tsv) is that build.  +13 ps is one fiftieth
    # of this part's own 0.585 ns run-to-run WNS spread, so expect to re-draw rather than to
    # reproduce the number.
  }
  roccmoonint6f41667 {
    # B83 -- THE CONSOLIDATION BUILD: 0x5A5A002F's engine (the 6-bit weight unpacker at the
    # read port) AT FCLK0 = 41.6667 MHz.  MAGIC 0x5A5A0032, claimed in MAGIC_REGISTRY.md in
    # the same commit as this block.  It is `roccmoonint6f40` with 1000/24 in place of
    # 1000/25 and NOTHING else: same config, same gensrc bundle, same top level, same XDC,
    # same -verilog_define set, same need_aa_size, same md5-pinned engine snapshot.
    #
    # WHY 41.6667 AND NOT 40.  B79 swept FCLK0 on a bit-identical netlist and concluded the
    # ceiling was 40.0000.  B81 falsified that: its b79f4167 arm had been CONTAMINATED by an
    # edit to rtl_study/roccmoon/merge/ that `add_files` picked up at synth_design time, and
    # rebuilt from the md5-pinned clean tree 41.6667 closes -- WNS +0.239, WHS +0.025,
    # 0 failing of 93,776 -- with ROCKET_POSTROUTE_PHYSOPT=1.  THAT WAS 002E's NETLIST.
    # This variant is 002F's, +323 LUT and +123 slices on top of it, at a 24.000 ns period
    # instead of 25.000.  Whether it closes is its own question and the answer is the build.
    #
    # WHY A NEW MAGIC AND NOT ROCKET_FCLK_MHZ=41.6667 ON roccmoonint6f40.  The reason
    # 0x5A5A0030 exists: CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC sets the SiFive UART's baud
    # divisor as well as mtime's tick, so a guest built for the wrong clock GARBLES THE
    # CONSOLE and runs mtime off by the ratio -- it does not fail.  B81's own 41.6667 probes
    # bind 32'h5A5A0030 and carry archive/runs/b81_fclk40_silicon/DO_NOT_LOAD_probe4167.md
    # for exactly that.  The MAGIC is bound at synthesis and travels with the clock, so a
    # guest, a runner and a lab can refuse the pair BEFORE the board.
    #
    # 41.6667 IS EXACT ON THIS PS7: FCLK0 = IO PLL / (DIVISOR0 * DIVISOR1) with the IO PLL at
    # 50 MHz * 20 = 1000 MHz, and 1000/24 with N = 24 an integer.  So the timed clock, the
    # clock Clocks.fclk0_mhz lands on, and the 41,666,667 Hz the labs divide by are one
    # number -- the labs derive that Hz from N, not from the rounded MHz.
    #
    # WHAT MUST TRAVEL WITH IT, all in the same commit as this block:
    #   1. this MAGIC, registered BY CONTENT (md5) in MAGIC_FEATURES.tsv;
    #   2. boards/chipyard/pynqz1_micrgb_f41667/, whose ONLY difference from pynqz1_micrgb is
    #      CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=41667 (the existing boards are NOT edited);
    #   3. host/run_rocket_roccmoonint6f41667.py (a symlink) in EXPECT_BY_RUNNER, with
    #      DEFAULT_FCLK_BY_RUNNER carrying 41.6667, and `--fclk 41.6667` on the load line;
    #   4. 0x5A5A0032 in the CAP=4 MAGIC list of scripts/57 and scripts/58.  That list is a
    #      `case` whose WILDCARD DEFAULT IS CAP=3, so an unlisted MAGIC silently changes the
    #      engine's outstanding cap as well as the clock -- a second lever wearing one name.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonint6f41667"
    set builddir   "build_rocket_micrgb_roccmoonint6f41667"
    set bitsuffix  "rocket_micrgb_roccmoonint6f41667"
    set soc_magic  "32'h5A5A0032"
    set fclk_mhz   41.6667     ;# 1000/24; the WHOLE of this variant's delta from roccmoonint6f40
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
    # PINNED, like 0x5A5A0031's, and for the reason B79 was contaminated by: `add_files` reads
    # RTL at synth_design time, so a build naming rtl_study/roccmoon/merge/ takes whatever is
    # there when Vivado gets there.  If the int6 workstream advances the engine this snapshot
    # must be RE-TAKEN deliberately.
    set lanes_rtl_snapshot src/lanes_engine_002f
    # BUILD IT AS:  ROCKET_POSTROUTE_PHYSOPT=1 ROCKET_VARIANT=roccmoonint6f41667 ...
    # 0x5A5A0031 needed the post-route pass to get from -0.647 to +0.013 at 25.000 ns; this is
    # 24.000 ns on a netlist that is no smaller, so it needs it at least as much.
  }
  roccmoonnch8 {
    # B96: THE MAC ARRAY WIDENED TO 64 MAC/cycle, WITH THE ATTENTION LANE CORRECTLY CONNECTED.
    # A FIT-AND-TIMING EXPERIMENT.  NOT A DELIVERABLE, and its MAGIC is deliberately one no
    # lab accepts.
    #
    # It is `roccmoonint6f41667` with exactly two changes:
    #   * the SoC elaborated from ...RoccMoonAllNch8Config, which is the shipping config with
    #     nch = 8 -- RoccMoonEngine.sv carries `.NCH(8)` instead of `.NCH(4)`;
    #   * a snapshot in which `mbxa_core` TAKES the NCH parameter.  The shipping snapshot does
    #     not pass it and hard-codes `acc` at 128 bits, so at NCH = 8 Vivado truncated the
    #     accumulator to its low 128 bits and REPORTED IT AS [Synth 8-689], A WARNING.  Every
    #     out-of-context NCH = 8 number this tree ever produced was measured on that.
    #
    # WHY A DISTINCT MAGIC.  The first attempt reused 0x5A5A0032 and produced a bitstream that
    # reported itself as the SHIPPING build while carrying a 64-MAC array that computed
    # attention wrong (md5 52080a12..., now in bitstream_refused and run_rocket.py's
    # REFUSED_MD5).  A colliding identity is strictly worse than an unknown one: 0x5A5A0FF8 is
    # registered NOWHERE, so bitstream_identify returns UNKNOWN and every lab refuses it.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8Config"
    set projname   "pynqz2_rocket_micrgb_roccmoonnch8"
    set builddir   "build_rocket_micrgb_roccmoonnch8"
    set bitsuffix  "rocket_micrgb_roccmoonnch8"
    set soc_magic  "32'h5A5A0FF8"
    set fclk_mhz   41.6667
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
    set lanes_rtl_snapshot src/lanes_engine_b96nch8
    # BUILD IT AS:  ROCKET_VARIANT=roccmoonnch8 CHIPYARD_GENSRC=<the Nch8 elaboration> ...
    # DEFAULT DIRECTIVES FIRST.  The first draw is the honest one; ROCKET_POSTROUTE_PHYSOPT is
    # a SECOND question and must not be folded into the first.
  }
  roccmoonnch8f40 {
    # B96: THE WIDENED ARRAY AT 40 MHz, AND THE ONE INTENDED TO BE LOADED.  SOC_MAGIC 0x5A5A0033.
    #
    # `roccmoonnch8` byte for byte except the clock and the MAGIC: same config
    # (...RoccMoonAllNch8Config), same gensrc bundle, same top level, same XDC, same
    # -verilog_define set, same md5-pinned snapshot src/lanes_engine_b96nch8.
    #
    # IT NEEDS ROCKET_POSTROUTE_PHYSOPT=1 AND THAT IS RECORDED, NOT HIDDEN.  On default
    # directives at 25.000 ns it came in at WNS -0.662 with TWO failing endpoints of 96,966;
    # with the post-route phys_opt_design -directive AggressiveExplore pass it closed at
    # +0.045, 0 failing.  0x5A5A0031 needed the same pass for the same reason (-0.647 ->
    # +0.013).  +0.045 ns is ONE THIRTEENTH of this part's 0.585 ns run-to-run WNS spread, so
    # THIS BUILD CLOSING IS NOT EVIDENCE THAT THE DESIGN CLOSES -- it is one draw, and a
    # rebuild may well miss.  Treat a pass as a licence to run it, not as closure.
    #
    # ITS GUEST IS boards/chipyard/pynqz1_micrgb_f40 (CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=40000),
    # which already exists.  Run it with --fclk 40.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8Config"
    set projname   "pynqz2_rocket_micrgb_roccmoonnch8f40"
    set builddir   "build_rocket_micrgb_roccmoonnch8f40"
    set bitsuffix  "rocket_micrgb_roccmoonnch8f40"
    set soc_magic  "32'h5A5A0033"
    set fclk_mhz   40
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
    set lanes_rtl_snapshot src/lanes_engine_b96nch8
    # BUILD IT AS:  ROCKET_POSTROUTE_PHYSOPT=1 ROCKET_VARIANT=roccmoonnch8f40 ...
  }
  roccmoonnch8f40b98 {
    # B98: THE WIDENED ARRAY, CORRECTED, AT 40 MHz.  SOC_MAGIC 0x5A5A0034.
    #
    # `roccmoonnch8f40` byte for byte except the MAGIC and ONE LINE OF RTL: same config
    # (...RoccMoonAllNch8Config), same gensrc bundle, same top level, same XDC, same
    # -verilog_define set, same clock.  The snapshot is src/lanes_engine_b98nch8, which is
    # src/lanes_engine_b96nch8 with `mbxr_engine.v` alone changed -- three files from shipping
    # `lanes_engine_002f` in total (mbxa_unit.v, mbxr_lanes.v, mbxr_engine.v).
    #
    # WHY 0x5A5A0033 IS DEAD AND THIS EXISTS.  That build closed at +0.208, placed into 13,272
    # of 13,300 slices, booted and passed its feature gate -- and `mbxr_whalf`'s port index was
    # THREE BITS (`wire [2:0] pport = pr[2:0] + 3'd1`), so at NCH = 8 weight plane 7 addressed
    # port 8, wrapped to 0, matched no weight bank and was SILENTLY DISCARDED.  With the
    # shipping MBXR_NCH=4 guest that only hangs (0 of 4,125 dispatches, last_rc -4); with a
    # guest built -DMBXR_NCH=8 to fix the hang it COMPLETES AND RETURNS WRONG BYTES, with
    # calls_engine > 0, calls_fallback = 0 and every scripts/74 gate green.  Its md5
    # 275c728234a980f69689e22058b3470b is in bitstream_refused and REFUSED_MD5.  0x5A5A0033 is
    # NOT reused: it names the broken artefact (TODO.md, B98).
    #
    # GATE THE PLACE-AND-ROUTE ON THE SIMULATION, NOT THE OTHER WAY ROUND.  Before any hours go
    # into this variant, rtl_study/roccmoon/run_nch8_gate.sh must report MBXR_NCH8_GATE_OK on
    # src/lanes_engine_b98nch8: MBXR_TB_OK 119 cases at NCH = 8, and at NCH = 4 the shipping
    # machine's exact Gets, Puts and cycles.  Three sessions of area and timing arithmetic
    # preceded the one minute of simulation that invalidated 0x5A5A0033.
    #
    # IT NEEDS ROCKET_POSTROUTE_PHYSOPT=1, as 0x5A5A0033 and 0x5A5A0031 did.  The netlist is
    # the same size; a 4-bit `+ 1` in place of a 3-bit one adds no logic the array did not
    # already carry.  Draw the honest one first: default directives, then the post-route pass.
    #
    # ITS GUEST IS boards/chipyard/pynqz1_micrgb_f40 (CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=40000)
    # and the guest must be built -DMBXR_NCH=8: mbxr.h's constant is now #ifndef-guarded, and
    # mbxr_rt.h refuses with MBXR_E_WIDTH = -6 at init if the two disagree.  Run it with
    # --fclk 40 through run_rocket_roccmoonnch8f40b98.py, whose EXPECT_BY_RUNNER carries
    # 0x5A5A0034.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8Config"
    set projname   "pynqz2_rocket_micrgb_roccmoonnch8f40b98"
    set builddir   "build_rocket_micrgb_roccmoonnch8f40b98"
    set bitsuffix  "rocket_micrgb_roccmoonnch8f40b98"
    set soc_magic  "32'h5A5A0034"
    set fclk_mhz   40
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
    set lanes_rtl_snapshot src/lanes_engine_b98nch8
    # BUILD IT AS:  ROCKET_POSTROUTE_PHYSOPT=1 ROCKET_VARIANT=roccmoonnch8f40b98 \
    #   CHIPYARD_GENSRC=<the Nch8 elaboration> vivado -mode batch ... tcl/build_rocket.tcl
  }
  roccmoonnch8f40b98b {
    # B98: THE WIDENED ARRAY WITH THE ATTENTION LANE ACTUALLY USABLE.  SOC_MAGIC 0x5A5A0035.
    #
    # `roccmoonnch8f40b98` byte for byte except the MAGIC and ONE LINE of mbxa_unit.v.  The
    # snapshot is src/lanes_engine_b98nch8b = src/lanes_engine_b98nch8 with `mbxa_unit.v`
    # alone changed (three files from shipping lanes_engine_002f in total).
    #
    # WHY 0x5A5A0034 IS NOT ENOUGH.  It computes linear_s8 and conv2d_s8 correctly at NCH = 8
    # -- 4,200 of 4,200 dispatches, 8/8 sequences -- and its ATTENTION LANE refuses every
    # dispatch: attn_lane 0, attn_fallback 6, attn_last_rc -69, attn_aerr 4 (err[2],
    # |acc| >= 2^24).  A fused-attention graph then spends 84 % of its time in the software
    # fallback and runs 7.7x SLOWER than NCH = 4, with max_abs_err 0 because the fallback is
    # correct.  Cause: the attention weight image is planar exactly as the engine's is, and
    # was laid out `row 4j+c` across FOUR planes in three places (the kernel's builder,
    # kstage.inc, tb_attn.cpp) while mbxr.c had been parameterised at 23 of 23 sites; and
    # mbxa_unit.v:248 validated `{qs,2'd0} >= nsc`, i.e. qs*4, the hardware half of the same
    # NCH = 4 contract.  All four sites now take NCH.  0x5A5A0034 stays registered and is NOT
    # refused -- it is correct silicon for an engine-only workload -- but a fused-attention
    # arm must use this build (TODO.md, B98).
    #
    # GATED ON SIMULATION BEFORE PLACE-AND-ROUTE, on all FOUR arms this time:
    # rtl_study/roccmoon/run_nch8_gate.sh must report MBXR_NCH8_GATE_OK on
    # src/lanes_engine_b98nch8b -- engine at both widths, ATTENTION at both widths, and the
    # LN/LUT dispatchers at both widths.  The attention arm is the one 0x5A5A0034 did not have.
    #
    # ITS GUEST IS boards/chipyard/pynqz1_micrgb_f40 built -DMBXR_NCH=8 (which now also sets
    # MBXA_NCH, derived rather than repeated).  Run it with --fclk 40 through
    # run_rocket_roccmoonnch8f40b98b.py, whose EXPECT_BY_RUNNER carries 0x5A5A0035.
    # Needs ROCKET_POSTROUTE_PHYSOPT=1, as 0x5A5A0031/0033/0034 did.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8Config"
    set projname   "pynqz2_rocket_micrgb_roccmoonnch8f40b98b"
    set builddir   "build_rocket_micrgb_roccmoonnch8f40b98b"
    set bitsuffix  "rocket_micrgb_roccmoonnch8f40b98b"
    set soc_magic  "32'h5A5A0035"
    set fclk_mhz   40
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set need_aa_size 1
    set lanes_rtl_snapshot src/lanes_engine_b98nch8b
    # BUILD IT AS:  ROCKET_POSTROUTE_PHYSOPT=1 ROCKET_VARIANT=roccmoonnch8f40b98b \
    #   CHIPYARD_GENSRC=<the Nch8 elaboration> vivado -mode batch ... tcl/build_rocket.tcl
  }
  roccmoonnch8f40b98boled {
    # B135, STEP 1: 0x5A5A0035 PLUS A TLI2C, AND NOTHING ELSE.  SOC_MAGIC 0x5A5A0036, claimed in
    # MAGIC_REGISTRY.md in the same commit as this block.
    #
    # WHAT IT IS FOR.  An SSD1306 OLED (0x3c) wired to the PL's two I2C balls, so the tutorial
    # demo has a display.  docs/OLED_SSD1306.md section 3 wrote this variant out as a PROPOSAL
    # ("proposal, not applied") down to the config, the `ifdef and the XDC; this is that proposal
    # applied to the Nch = 8 machine rather than to micrgb.
    #
    # WHAT IS THE SAME AS 0x5A5A0035, and it is nearly everything: fclk_mhz 40, the same
    # md5-pinned engine snapshot src/lanes_engine_b98nch8b, the same need_aa_size, the same mic,
    # the same six RGB pins, the same two harts, L2, memory path and clock.  MEASURED on the
    # generated collateral: RoccMoonEngine.sv, RoccMoonShim.sv, RoccCommandRouter.sv, Rocket.sv,
    # Rocket_1.sv, ICache.sv, ICache_1.sv and TacitEncoder.sv are all BYTE-IDENTICAL to the
    # Nch8 elaboration's.
    #
    # WHAT IS NOT THE SAME, stated because "it only adds a peripheral" is not quite true:
    #   * THE PLIC RENUMBERS.  DigitalTop mixes HasPeripheryI2C in ahead of HasPeripheryUART, so
    #     the TLI2C is source 1, the UART moves 1 -> 2 and the GPIO 2..7 -> 3..8; riscv,ndev
    #     7 -> 8.  MEASURED in this config's own generated DTS, and exactly what
    #     docs/OLED_SSD1306.md F6 predicted from 0x5A5A001E.  A guest built for 0x5A5A0035's
    #     board gets the CONSOLE wrong, so this variant needs a Zephyr board of its own.
    #   * PTW.sv AND PMAChecker.sv CHANGE INSIDE THE TILES.  The page-table walker's homogeneity
    #     check and the PMA checker enumerate every MMIO region, so a new device at 0x1004_0000
    #     adds one term to each decoder.  It is a handful of LUT in an address comparator; it
    #     changes no arithmetic, no cycle count and nothing the engine sees.  There is no way to
    #     add an MMIO device without it.
    #   * TLROM.sv changes: the bootrom carries the DTB, and the DTB now has an i2c node.
    #
    # NOT THE CAMERA.  PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig adds
    # WithOspiCaptureDma + WithOspiPunchthrough + WithHM01B0SimModel on top of the same WithI2C;
    # the DMA and its 512-beat frame buffer are the expensive part and the OLED needs none of it.
    # has_cam and has_i2c are refused together below: both drive ChipTop's i2c_0_* and both claim
    # P15/P16.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonnch8f40b98boled"
    set builddir   "build_rocket_micrgb_roccmoonnch8f40b98boled"
    set bitsuffix  "rocket_micrgb_roccmoonnch8f40b98boled"
    set soc_magic  "32'h5A5A0036"
    set fclk_mhz   40
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set has_i2c    1
    set need_aa_size 1
    set lanes_rtl_snapshot src/lanes_engine_b98nch8b
    # BUILD IT AS:  ROCKET_POSTROUTE_PHYSOPT=1 ROCKET_VARIANT=roccmoonnch8f40b98boled \
    #   CHIPYARD_GENSRC=<the Nch8 I2c elaboration> vivado -mode batch ... tcl/build_rocket.tcl
  }
  roccmoonnch8f40b98bpanel {
    # B135, STEP 2: 0x5A5A0036 PLUS THE FOUR PUSHBUTTONS.  SOC_MAGIC 0x5A5A0037, claimed in
    # MAGIC_REGISTRY.md in the same commit as this block.
    #
    # THE TUTORIAL PANEL: an SSD1306 on I2C and a physical button that starts a recording.  It is
    # `roccmoonnch8f40b98boled` with the GPIO controller at 0x1001_0000 widened from 6 pins to 10
    # (chipyard.WithGPIOWidth(10) in PynqZ2Configs.scala) and BTN0..BTN3 on pins 6..9.
    #
    # WHY WIDEN RATHER THAN ADD A SECOND CONTROLLER.  All six of the existing controller's pins
    # are the two RGB LEDs, so there is no spare pin to read a button on, and
    # chipyard.config.WithI2C-style fragments APPEND: a second GPIO would cost another pbus
    # crossbar port and another register file on a device that places at 99.96 % slice occupancy.
    # Widening costs four pins' worth of registers and no new bus port.  docs/RGB_LEDS.md
    # section 8 priced this addition at ~100-250 LUT for six more pins and said "the honest way
    # to get the number is WithGPIO(width = 12) and one synthesis run"; that run is B135.
    #
    # THE PINS ARE INPUT ONLY.  Nothing in the PL drives D19/D20/L20/L19; the top level feeds the
    # controller's i_ival from the pad, gated by the controller's own input_en exactly as
    # GenericDigitalGPIOCell would (`assign i = ie ? pad : 1'b0`).  A guest that does not set
    # input_en for pins 6..9 reads every button as 0 -- see src/pynqz2_rocket_top.v.
    #
    # THE PLIC RENUMBERS AGAIN, on top of the I2C's renumbering: GPIO takes sources 3..12 and
    # riscv,ndev is 12.  MEASURED in this config's generated DTS.  The UART stays at 2.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllNch8I2cBtnConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonnch8f40b98bpanel"
    set builddir   "build_rocket_micrgb_roccmoonnch8f40b98bpanel"
    set bitsuffix  "rocket_micrgb_roccmoonnch8f40b98bpanel"
    set soc_magic  "32'h5A5A0037"
    set fclk_mhz   40
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set has_i2c    1
    set has_btn    1
    set need_aa_size 1
    set lanes_rtl_snapshot src/lanes_engine_b98nch8b
    # BUILD IT AS:  ROCKET_POSTROUTE_PHYSOPT=1 ROCKET_VARIANT=roccmoonnch8f40b98bpanel \
    #   CHIPYARD_GENSRC=<the Nch8 I2cBtn elaboration> vivado -mode batch ... tcl/build_rocket.tcl
  }
  roccmoonnch8f40b98ball {
    # B137: EVERY INTERFACE AT ONCE -- 0x5A5A0037's panel PLUS THE CAMERA'S ospi CAPTURE DMA,
    # PAID FOR BY DROPPING TACIT.  SOC_MAGIC 0x5A5A0038, claimed in MAGIC_REGISTRY.md in the
    # same commit as this block.
    #
    # WHAT IT CARRIES.  The nch = 8 RoCC engine, the P-extension on hart 0, the PDM microphone,
    # the six RGB LED pins, the TLI2C at 0x1004_0000 (OLED at 0x3c), BTN0..BTN3 on GPIO pins
    # 6..9, and the HM01B0 capture peripheral at 0x1008_0000 with its TileLink DMA master --
    # at fclk_mhz 40, off the same md5-pinned engine snapshot src/lanes_engine_b98nch8b.
    #
    # WHAT IT GIVES UP, AND WHY THAT IS THE RIGHT TRADE.  B135 measured that the ospi capture
    # DMA does not fit on the panel: +1,697 LUT out of context, ~1,485 in context at
    # tcl/ooc_area.tcl's own 0.875 ratio, against a routed panel build with TWO of the device's
    # 13,300 slices free.  The TACIT trace encoders are the only block of comparable size that
    # NOTHING IN THE MOONSHINE PATH READS: from 0x5A5A0037's own post_route_util_hier.rpt,
    # TacitEncoder 896 + TacitEncoder_19 926 + TraceSinkDMA 100 + TraceSinkDMA_20 99 +
    # TraceEncoderController 0 + _25 2 = 2,023 LUT of routed logic, plus two sbus master ports
    # and two MMIO regions every PMAChecker and PTW decodes.
    #
    # THIS IS A NEW VARIANT, NOT A REPLACEMENT.  samples/tacit_boot and samples/membench need a
    # trace encoder and keep working on the bitstreams that have one: 0x5A5A0035, 0x5A5A0036 and
    # 0x5A5A0037 are untouched, unmodified and rebuildable.  An image that writes 0x300_0000 on
    # THIS bitstream writes to an error device.
    #
    # ONE TLI2C, TWO CONSUMERS.  has_i2c and has_ospi are set together and has_cam is NOT:
    # the shield's sensor sits behind a PCA9306 on PL_SDA/PL_SCL and its J4 OLED row hangs
    # straight on the same pair, so P15/P16 carry both.  PYNQZ2_HAS_I2C owns those two pads
    # (src/pynqz2_i2c.xdc) and PYNQZ2_HAS_OSPI carries the fourteen video pins alone
    # (src/pynqz2_ospi.xdc, which is src/pynqz2_cam.xdc minus its two I2C lines).  The guard
    # below refuses has_ospi with has_cam, which would be a second driver of i2c_0_*.
    #
    # THE PLIC, MEASURED in this config's own generated DTS: i2c 1, uart 2, gpio 3..12,
    # ospi 13, riscv,ndev 13.  The UART and the GPIO are where 0x5A5A0037 has them, so a
    # board file for the panel gets the CONSOLE right here -- but ndev and the camera node
    # differ, so this variant still needs a board of its own.
    set cfg        "PynqZ2RocketBigLittlePextMicRgbRoccMoonAllNch8I2cBtnCamNoTacitConfig"
    set projname   "pynqz2_rocket_micrgb_roccmoonnch8f40b98ball"
    set builddir   "build_rocket_micrgb_roccmoonnch8f40b98ball"
    set bitsuffix  "rocket_micrgb_roccmoonnch8f40b98ball"
    set soc_magic  "32'h5A5A0038"
    set fclk_mhz   40
    set has_mic    1
    set has_rgb    1
    set has_lanes  1
    set has_i2c    1
    set has_btn    1
    set has_ospi   1
    set need_aa_size 1
    set lanes_rtl_snapshot src/lanes_engine_b98nch8b
    # BUILD IT AS:  ROCKET_POSTROUTE_PHYSOPT=1 ROCKET_VARIANT=roccmoonnch8f40b98ball \
    #   CHIPYARD_GENSRC=<the Nch8 I2cBtnCamNoTacit elaboration> vivado -mode batch ... tcl/build_rocket.tcl
  }
  tracepanelcam {
    # B138: THE TRACE BITSTREAM -- TACIT ON BOTH HARTS, THE P-EXTENSION, EVERY INTERFACE, AND
    # NO ROCCMOON ENGINE.  SOC_MAGIC 0x5A5A0039, claimed in MAGIC_REGISTRY.md in the same
    # commit as this block.
    #
    # WHAT IT IS FOR, AND WHY IT IS NOT ONE OF THE MEASUREMENT BITSTREAMS.  0x5A5A0035/36/37
    # run the Moonshine workload on the nch = 8 RoCC engine, and a TACIT trace taken on them
    # is a trace of a machine whose arithmetic is inside a BlackBox the encoder cannot see:
    # one custom-1 instruction retires and the engine then runs for thousands of cycles with
    # nothing in the instruction stream to show for it.  THIS variant is the other half of
    # that pair -- the same two harts, the same MBP P-extension on hart 0, the same
    # peripherals, and NO engine -- so the work being traced is done by instructions and the
    # decoder's slices are the computation.  It is built to be TRACED, not to be fast.
    #
    # WHAT IT CARRIES.  Both harts with a TacitEncoder and a TraceSinkDMA (0x300_0000 /
    # 0x300_1000 and 0x301_0000 / 0x301_1000 -- FOUR MMIO regions, MEASURED in this config's
    # own generated DTS, not inferred from the fragment's name), the MBP P-extension on hart 0,
    # hart 0's pipelined multiplier, patch 0092's skipped clean Release in the L2, the PDM
    # microphone at 0x1009_0000, the six RGB LED pins, the TLI2C at 0x1004_0000 (OLED at 0x3c),
    # BTN0..BTN3 on GPIO pins 6..9, and the HM01B0 capture peripheral at 0x1008_0000 with its
    # TileLink DMA master.  40 MHz.
    #
    # WHAT IT DOES NOT CARRY, AND THE EVIDENCE THAT NOTHING IS LEFT BEHIND.  No
    # chipyard.roccmoon.WithRoccMoon and no chipyard.config.WithMultiRoCC, so BuildRoCC keeps
    # its Nil default (rocket-chip tile/LazyRoCC.scala:22) and BaseTile.usingRoCC is false on
    # BOTH tiles.  MEASURED on the generated Verilog: NEITHER Rocket.sv NOR Rocket_1.sv has a
    # single io_rocc_* port (the panel's Rocket_1.sv has 30-odd), there is no
    # RoccCommandRouter, no RoccMoonShim, no RoccMoonEngine and no mbxr_* module in
    # gen-collateral at all.  What DOES survive is a handful of dead decoder bits --
    # ex/mem/wb_ctrl_rocc and rocc_blocked -- which exist in the control bundle whatever
    # BuildRoCC says; with no RoCC decode table nothing ever sets them and they are provably
    # constant 0 (ex_ctrl_rocc's own next state is `ctrl_killd & ex_ctrl_rocc`).  That is a
    # few flops of dead logic, not an accelerator stub, and the post-route hierarchy report is
    # where it is checked rather than argued.
    #
    # SO has_lanes IS 0 AND THERE IS NO lanes_rtl_snapshot.  This variant reads no engine RTL
    # out of rtl_study/, pins no engine md5 and needs no need_aa_size: there is no mbxr_engine
    # BlackBox in the elaboration for a port list to disagree with.
    #
    # THE P-EXTENSION IS UNAFFECTED BY DROPPING THE ROCC, and this is the one interaction
    # worth naming.  patches/0008's require(!(usePExt && usingRoCC)) (RocketCore.scala:232) is
    # why every engine config needs WithMultiRoCC -- to stop tile 0 seeing a global BuildRoCC.
    # With no RoCC anywhere the requirement is vacuously satisfied.  MEASURED: this config's
    # RocketALU.sv (hart 0's, fn codes 5'h14..5'h17 = DOT8/MAX8/QMUL/CLIP8) and RocketALU_1.sv
    # (hart 1's, none of them) are BYTE-IDENTICAL to the panel elaboration's.
    #
    # THE mcycle FREE-RUN PATCH IS IN IT, and it is what makes two encoders worth having:
    # patches/0004 takes reg_wfi out of the cycle counter's enable so both harts' mcycle -- the
    # TACIT timebase -- stay locked to one clock (TACIT_MULTICORE.md: barrier skew 8,857,274
    # cycles -> 64).  MEASURED in this config's own CSRFile.sv AND CSRFile_1.sv:
    # `nextSmall_1 = {1'h0, small_1} + {6'h0, ~io_status_cease_r}` on both harts, with
    # `io_csr_stall = reg_wfi | io_status_cease_r` still driving the pipeline stall.  NOTE that
    # this is a property of the shared rocket-chip tree (scripts/07_patch_rocketchip.sh), not
    # of this variant: every elaboration taken from that tree since 2026-09-15 has it,
    # 0x5A5A0035/36/37 included.
    #
    # ONE TLI2C, TWO CONSUMERS -- the same arrangement B137's `roccmoonnch8f40b98ball` block
    # documents: has_i2c and has_ospi together, has_cam NOT, because the shield hangs its J4
    # OLED row and (through a PCA9306) its sensor on the same P15/P16 pair.  This variant
    # DEPENDS on the has_ospi plumbing that block introduced (PYNQZ2_HAS_OSPI,
    # src/pynqz2_ospi.xdc, the ospi_pins table and the two guards) and adds none of its own.
    #
    # THE PLIC, MEASURED in this config's own generated DTS: i2c 1, uart 2, gpio 3..12,
    # ospi 13, riscv,ndev 13 -- identical to 0x5A5A0038's, because TACIT contributes no
    # interrupt (it is MMIO and a bus master only) and the RoCC never did either.  The UART is
    # at 2, where 0x5A5A0036/37 have it.  It still needs a Zephyr board of its own: ndev and
    # the device set are not 0x5A5A0037's.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbI2cBtnCamConfig"
    set projname   "pynqz2_rocket_micrgb_tracepanelcam"
    set builddir   "build_rocket_micrgb_tracepanelcam"
    set bitsuffix  "rocket_micrgb_tracepanelcam"
    set soc_magic  "32'h5A5A0039"
    set fclk_mhz   40
    set has_mic    1
    set has_rgb    1
    set has_i2c    1
    set has_btn    1
    set has_ospi   1
    # THIS VARIANT DEPENDS ON THE has_ospi PLUMBING INTRODUCED WITH 0x5A5A0038, AND THE
    # DEPENDENCY IS CHECKED RATHER THAN ASSUMED.  Without src/pynqz2_ospi.xdc -- and the
    # PYNQZ2_HAS_OSPI define, the ospi_pins table and the post-synth/post-route pin checks that
    # come with it -- `set has_ospi 1` above is an UNUSED VARIABLE: the camera's fourteen pads
    # would go unconstrained, PYNQZ2_HAS_OSPI would not reach the preprocessor, ChipTop's
    # ospi_sensor_* ports would dangle, and Vivado would write a bitstream that looks right and
    # HAS NO CAMERA.  That is the silent-wrong-bitstream failure this file exists to refuse.
    if {![file exists $root/src/pynqz2_ospi.xdc]} {
      error "tracepanelcam needs src/pynqz2_ospi.xdc and the has_ospi plumbing that arrived with\
        0x5A5A0038 (roccmoonnch8f40b98ball).  Without it this variant builds SILENTLY WITHOUT the\
        camera: has_ospi is set in its block but nothing downstream reads it."
    }
    # BUILD IT AS:  ROCKET_VARIANT=tracepanelcam \
    #   CHIPYARD_GENSRC=<the PextTacitMicRgbI2cBtnCam elaboration> vivado -mode batch ... tcl/build_rocket.tcl
    # ROCKET_POSTROUTE_PHYSOPT is NOT set by default here: the engine is gone, so this design
    # is far below the 99.96 % slice occupancy that made the panel need it.  Turn it on if the
    # first route misses.
  }
  lanesdev {
    # THE LANE DEVELOPMENT CONFIG (LAYERNORM_LANE.md s20).  MAGIC 0x5A5A002B.
    # 0x5A5A002A's SoC with everything a lane does not touch removed, so lane FUNCTION can be
    # iterated without place-and-route fighting a 95 %-full device.  Keeps both harts (the RoCC
    # is on hart 1), the same 64 KB 4-way L2 with 0092, DDR and the console.  Drops TACIT
    # (2,202 LUT measured), the PDM mic (549), the RGB GPIO (89), the MBP P-extension (265, and
    # its 6 m 38 s build gate) and hart 0's pipelined multiplier.
    #
    # IT IS A DIFFERENT MACHINE.  It answers "does the lane compute the right bytes, does the
    # dispatch protocol work, does it refuse what it should" and tells you essentially nothing
    # about fit or timing.  Name the config beside every utilisation or WNS number taken here.
    #
    # NO P-EXTENSION: an image for this config must use kernels that emit no custom-0.
    # layernorm_pc_s8 -> reference and groupnorm_s16 -> pext_int_memo are custom0 = 0, so T3's
    # lane-off baseline is unaffected; the DOT8 kernels are not available, so a T2 A/B here
    # must fall back to reference kernels -- honest about function, silent about the deployed mix.
    set cfg        "PynqZ2RocketBigLittleRoccMoonLanesDevConfig"
    set projname   "pynqz2_rocket_lanesdev"
    set builddir   "build_rocket_lanesdev"
    set bitsuffix  "rocket_lanesdev"
    set soc_magic  "32'h5A5A002B"
    set fclk_mhz   35
    set has_lanes  1
  }
  roccmooncam {
    # THE HM01B0 CAMERA ON THE Z1 SHIELD (docs/CAMERA_Z1.md): `roccmoon` plus the ospi capture
    # peripheral with its DMA master (MMIO 0x1008_0000) and a sifive TLI2C for the sensor's
    # 0x24 control port.  The shield's pins are src/pynqz2_cam.xdc; the top-level wiring (I2C
    # IOBUFs, the MCLK ODDR, the PCLK BUFG) is behind PYNQZ2_CAM.  Every other define, XDC and
    # the top level are `roccmoon`'s, so the delta against 0x5A5A0010 is the camera.
    #
    # THE ENGINE RTL IS A SNAPSHOT, NOT rtl_study/.  src/cam_engine_rev1/ holds the seven files
    # 0x5A5A0010 (md5 7475c1b2) was synthesised from -- engine revision 1, byte-identical to
    # commit f69acfb, every mtime before that build's 21:54:57 start -- with their md5s in
    # MD5SUMS, which is checked below before a file is read.  rtl_study/roccmoon and
    # rtl_study/rocc move to revision 2a after 0x5A5A0011; this variant does not follow them.
    set cfg        "PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig"
    set projname   "pynqz2_rocket_micrgb_roccmooncam"
    set builddir   "build_rocket_micrgb_roccmooncam"
    set bitsuffix  "rocket_micrgb_roccmooncam"
    set soc_magic  "32'h5A5A001E"
    set fclk_mhz   35          ;# -> 34.4828 MHz actual
    set has_mic    1
    set has_rgb    1
    set has_roccmoon 1
    set has_cam    1
    set roccmoon_rtl_snapshot src/cam_engine_rev1
  }
  bwbypassl2 {
    # LEVER 3 ON THE OTHER DDR CONTROLLER PORT: `bwports` with channel 1 on S_AXI_HP2.
    #
    # The Zynq DDR controller has four AXI ports, and HP0 and HP1 SHARE one of them (port 3;
    # HP2 and HP3 share port 2).  `bwports` put its second channel on HP1, so both channels
    # met again at one controller port.  This is the configuration that can parallelise.
    # Behind the L2 it is expected to read the same null as 0x5A5A0009 (MEMORY_BANDWIDTH.md
    # s3.6: the cap is the L2's single outer D channel); it is the L2-in-path control for the
    # bypass family (s8), same clock, same instrument.
    #
    # THE SAME ELABORATED SoC AS `bwports`: WithNMemoryChannels(2) does not know which HP
    # port a channel is wired to, so `cfg` is the BwPorts bundle and only the top level
    # (PYNQZ2_CH1_HP2) and the PS7 (HP2 instead of HP1) differ.  configs.csv joins on
    # (config, soc_magic).
    set cfg         "PynqZ2RocketBigLittlePextTacitMicRgbBwPortsConfig"
    set projname    "pynqz2_rocket_micrgb_bwbypassl2"
    set builddir    "build_rocket_micrgb_bwbypassl2"
    set bitsuffix   "rocket_micrgb_bwbypassl2"
    set soc_magic   "32'h5A5A0014"
    set fclk_mhz    35
    set has_mic     1
    set has_rgb     1
    set has_bw      1
    set has_nmem2   1
    set has_ch1_hp2 1
  }
  bwbypass {
    # THE BYPASS FUSION (MEMORY_BANDWIDTH.md s8; TODO.md item 13).  Two levers that read null
    # behind the L2 -- the memory clock (lever 2) and a second HP port (lever 3) -- stacked
    # with the change that takes the L2 out of the path: BwBypass, two lanes on the MEMORY
    # bus.  BwProbe stays on the system bus, behind the L2, in the same bitstream.
    #
    # Two memory channels, channel 1 on S_AXI_HP2 (PYNQZ2_CH1_HP2): HP0 and HP2 are on
    # different DDR controller ports.  mbus, both TLToAXI4 couplers (each with patches/0061's
    # TLBuffer), both shims, the HP ports and the lanes on FCLK1, timed at 100 MHz.  FCLK1 is
    # SET and READ BACK at run time (host/fclk.py); a run below closure is legal, above it not.
    #
    # The first build of this variant had four channels (has_nmem4) and four lanes and missed
    # timing on both clocks (md5 c0bf3870, never measured; PynqZ2Configs.scala has the detail).
    set cfg          "PynqZ2RocketBigLittlePextTacitMicRgbBwBypassConfig"
    set projname     "pynqz2_rocket_micrgb_bwbypass"
    set builddir     "build_rocket_micrgb_bwbypass"
    set bitsuffix    "rocket_micrgb_bwbypass"
    set soc_magic    "32'h5A5A0015"
    set fclk_mhz     35
    set has_mic      1
    set has_rgb      1
    set has_bw       1
    set has_memclk   1
    set fclk_mem_mhz 100
    set has_nmem2    1
    set has_ch1_hp2  1
  }
  bwbypass01 {
    # The bypass fusion with channel 1 on S_AXI_HP1 instead of HP2: HP0 and HP1 share DDR
    # controller port 3.  The same elaborated SoC as `bwbypass` (one Chipyard config; the port a
    # channel reaches is the top level's choice), so against it this isolates the controller
    # port.  MEMORY_BANDWIDTH.md s8.
    set cfg          "PynqZ2RocketBigLittlePextTacitMicRgbBwBypassConfig"
    set projname     "pynqz2_rocket_micrgb_bwbypass01"
    set builddir     "build_rocket_micrgb_bwbypass01"
    set bitsuffix    "rocket_micrgb_bwbypass01"
    set soc_magic    "32'h5A5A0016"
    set fclk_mhz     35
    set has_mic      1
    set has_rgb      1
    set has_bw       1
    set has_memclk   1
    set fclk_mem_mhz 100
    set has_nmem2    1
  }
  bwbypass4 {
    # The bypass on all four HP ports (MEMORY_BANDWIDTH.md s8.7): BwBypass with 4 lanes x 8 sources
    # on MBUS, four memory channels into S_AXI_HP0-HP3 (PYNQZ2_NMEM4), memory bus on FCLK1 timed
    # at 100 MHz, patch 0061's port buffer.  SOC_MAGIC 0x5A5A0017 (MAGIC_REGISTRY.md).
    set cfg          "PynqZ2RocketBigLittlePextTacitMicRgbBwBypass4Config"
    set projname     "pynqz2_rocket_micrgb_bwbypass4"
    set builddir     "build_rocket_micrgb_bwbypass4"
    set bitsuffix    "rocket_micrgb_bwbypass4"
    set soc_magic    "32'h5A5A0017"
    set fclk_mhz     35
    set has_mic      1
    set has_rgb      1
    set has_bw       1
    set has_memclk   1
    set fclk_mem_mhz 100
    set has_nmem2    1
    set has_nmem4    1
  }
  bwwin {
    # THE SYSTEM-BUS SIDE OF THE MEMORY ARCHITECTURE (MEMORY_BANDWIDTH.md s9).  BwWindow: four 128-bit
    # lanes of mbxd_dma at the CORE clock (FCLK0), each through its own TileLink async crossing into the
    # memory bus with the 128 -> 64 widget on the memory-clock side; the DMA aperture: DDR aliased
    # uncached at 0x4000_0000 on the system bus.  The memory side is bwbypass4's exactly: four channels
    # into S_AXI_HP0-HP3 (PYNQZ2_NMEM4), memory bus on FCLK1 timed at 100 MHz, patch 0061's port
    # buffer; ChipTop's ports are identical to it.  SOC_MAGIC 0x5A5A001C (MAGIC_REGISTRY.md).
    set cfg          "PynqZ2RocketBigLittlePextTacitMicRgbBwWinConfig"
    set projname     "pynqz2_rocket_micrgb_bwwin"
    set builddir     "build_rocket_micrgb_bwwin"
    set bitsuffix    "rocket_micrgb_bwwin"
    set soc_magic    "32'h5A5A001C"
    set fclk_mhz     35
    set has_mic      1
    set has_rgb      1
    set has_bw       1
    set has_memclk   1
    set fclk_mem_mhz 100
    set has_nmem2    1
    set has_nmem4    1
  }
  default { error "ROCKET_VARIANT must be tacit, smp, pext, mic, micrgb, bw, bwfast, bwports, bwl2mshr, bwl2cap, bwl2fast or bwwide, bwwide256, roccmoon, roccmoonmul, roccmoon2a, roccmoonall, roccmoonlanes, roccmoonlut, roccmoonlut2, roccmoondrain, roccmoonint6, roccmoonf40, roccmoonint6f40, roccmoonint6f41667, lanesdev, roccmoonnch8f40b98boled, roccmoonnch8f40b98bpanel, roccmoonnch8f40b98ball, tracepanelcam, roccmooncam or bwbypassl2, bwbypass, bwbypass01 or bwbypass4, or bwwin, got '$variant'" }
}
if {![info exists has_mic]} { set has_mic 0 }
if {![info exists has_bw]}  { set has_bw  0 }
if {![info exists has_roccmoon]} { set has_roccmoon 0 }
if {![info exists has_roccmoon2b]} { set has_roccmoon2b 0 }
if {![info exists has_lanes]}        { set has_lanes 0 }
if {![info exists need_aa_size]}     { set need_aa_size 0 }
if {![info exists has_wlane]} { set has_wlane 0 }
if {![info exists fclk_wlane_mhz]} { set fclk_wlane_mhz 100 }
if {![info exists has_cam]} { set has_cam 0 }
if {![info exists has_i2c]} { set has_i2c 0 }
if {![info exists has_btn]} { set has_btn 0 }
if {![info exists has_ospi]} { set has_ospi 0 }
if {![info exists has_memclk]} { set has_memclk 0 }
if {![info exists has_nmem2]}  { set has_nmem2  0 }
if {![info exists has_ch1_hp2]} { set has_ch1_hp2 0 }
if {![info exists has_nmem4]}  { set has_nmem4  0 }
if {$has_nmem4 && (!$has_nmem2 || $has_ch1_hp2)} {
  error "has_nmem4 needs has_nmem2 and puts channels 1-3 on HP1-HP3; has_ch1_hp2 cannot be set with it"
}
# The weight lane owns S_AXI_HP2 and FCLK1.  has_ch1_hp2 and has_nmem4 put a MEMORY CHANNEL on HP2,
# and has_memclk drives FCLK1 for the memory domain: each would be a second driver of the same PS7
# port or clock in pynqz2_rocket_top.v, where the last `ifdef` would silently win.  Refuse instead.
# has_cam is orthogonal and may be combined: the camera adds pins, an XDC file and PYNQZ2_CAM, and
# its capture DMA is a TileLink master inside the SoC -- it touches no HP port.
if {$has_wlane && ($has_ch1_hp2 || $has_nmem4)} {
  error "has_wlane puts the weight lane on S_AXI_HP2; has_ch1_hp2 / has_nmem4 claim it for a memory channel"
}
if {$has_wlane && $has_memclk} {
  error "has_wlane drives FCLK1 for the weight lane; has_memclk drives it for the memory bus"
}
if {$has_roccmoon2b && $has_roccmoon} {
  error "has_roccmoon2b reads rtl_study/roccmoon/rev2, which redefines mbxr_engine and mbxr_st; has_roccmoon adds the other copies"
}
if {$has_lanes && ($has_roccmoon || $has_roccmoon2b)} {
  error "has_lanes reads rtl_study/roccmoon/merge, which redefines mbxr_engine; the others add another copy"
}
# has_i2c and has_cam are the SAME TLI2C on the SAME two balls.  PYNQZ2_CAM already brings
# ChipTop's i2c_0_* out through its own IOBUFs on P15/P16 (cam_sda/cam_scl); PYNQZ2_HAS_I2C does
# it again on i2c_sda/i2c_scl.  Both defined at once is two drivers of the same six ChipTop ports
# and two ports on each of two balls -- a synthesis error at best and the wrong bitstream at
# worst.  Refuse, rather than letting the later `ifdef win.
if {$has_i2c && $has_cam} {
  error "has_i2c and has_cam both wire ChipTop's i2c_0_* and both claim P15/P16; pick one"
}
# has_btn reads the GPIO controller's pins 6..9, which exist only when the config widened the
# controller past the six the RGB LEDs use.  has_rgb is what says this design has that
# controller at all, so a btn variant without it is a config that cannot have elaborated.
if {$has_btn && !$has_rgb} {
  error "has_btn reads gpio_0 pins 6..9; that controller is the RGB LEDs' and needs has_rgb"
}
# has_ospi is the CAMERA'S VIDEO PINS WITHOUT ITS I2C -- PYNQZ2_HAS_OSPI, src/pynqz2_ospi.xdc.
# has_cam is the same seven signals PLUS ChipTop's i2c_0_* on its own two ports.  Both defined
# at once declares cam_d/cam_pclk/... twice and instantiates u_cam_pclk_ibuf, u_cam_pclk_bufg
# and u_cam_mclk_oddr twice.  Refuse, the same way has_i2c and has_cam are refused above.
if {$has_ospi && $has_cam} {
  error "has_ospi and has_cam declare the same video ports and the same pad instances; pick one"
}
# A config with ospi.WithOspiCaptureDma also carries chipyard.config.WithI2C (the sensor's 0x24
# control port), so ChipTop has i2c_0_scl_in / i2c_0_sda_in whatever this variant does with the
# pads.  Leaving them unconnected floats two inputs of the TLI2C -- which synthesises to a
# constant and looks exactly like a dead bus.  has_ospi therefore REQUIRES has_i2c: one TLI2C,
# one pair of balls (P15/P16), shared by the sensor and the OLED on the shield's J4 row.
if {$has_ospi && !$has_i2c} {
  error "has_ospi's config elaborates a TLI2C; set has_i2c so P15/P16 are driven (src/pynqz2_i2c.xdc)"
}
if {![info exists has_tileclk]} { set has_tileclk 0 }
# A build-directory tag, so several builds of ONE variant (a clock sweep) can run at once
# without sharing a project directory.  Empty by default, which leaves every existing
# variant's paths exactly as they were.
if {[info exists ::env(ROCKET_BUILD_TAG)] && $::env(ROCKET_BUILD_TAG) ne ""} {
  append projname  "_$::env(ROCKET_BUILD_TAG)"
  append builddir  "_$::env(ROCKET_BUILD_TAG)"
  append bitsuffix "_$::env(ROCKET_BUILD_TAG)"
}
if {[info exists ::env(ROCKET_FCLK_MEM_MHZ)]} { set fclk_mem_mhz $::env(ROCKET_FCLK_MEM_MHZ) }
if {![info exists has_rgb]} { set has_rgb 0 }

# THE RGB LED PIN TABLE, stated once, in real Tcl, and asserted twice -- after synthesis
# against the constraint, and after ROUTE against where the port actually landed.
#
# Why post-route and not just post-synth: `get_property PACKAGE_PIN` after synthesis reads
# back the CONSTRAINT, so it answers "did the XDC parse", not "is the signal on that ball".
# Those are different questions and only the second one matters. An XDC Vivado declines to
# run (see src/pynqz2_rgb.xdc) leaves the pins unconstrained and the placer puts them
# wherever it likes -- which is a bitstream with six LED signals on six arbitrary balls,
# and nobody here can see the board to notice.
#
# This list must agree with src/pynqz2_rgb.xdc and with the table in
# scripts/build_micrgb_z1.sh. Three independent statements of the same six facts, all
# checked against the implemented design: any two of them disagreeing is a loud error
# rather than a wrong bitstream. The source for the mapping is in src/pynqz2_rgb.xdc.
set rgb_pins {
  rgb_led[0] L15   rgb_led[1] G17   rgb_led[2] N15
  rgb_led[3] G14   rgb_led[4] L14   rgb_led[5] M15
}
# THE CAMERA SHIELD'S PIN TABLE (roccmooncam), asserted the same two ways as rgb_pins: after
# synthesis against the constraint and after route against the placement.  Source:
# archive/drafts/PINMAP_riskybirdv3_pynq_camera_rev0.6.md (riskybirdv3_pynq_camera rev 0.6 on
# the Z1's chipKIT header).  It must agree with src/pynqz2_cam.xdc.  U13 is PUDC_B, tied to 3V3
# on the shield, and is checked to carry NO port after route.
set cam_pins {
  cam_d[0] T14   cam_d[1] U12   cam_d[2] V13   cam_d[3] V15
  cam_d[4] T15   cam_d[5] R16   cam_d[6] U17   cam_d[7] V17
  cam_pclk U10   cam_fvld W11   cam_lvld V11   cam_int  T5
  cam_mclk V18   cam_trig T16   cam_sda  P15   cam_scl  P16
}
# THE I2C BUS'S TWO BALLS (has_i2c), asserted the same two ways as rgb_pins and cam_pins.  The
# source is boards/arty-z7-20/A.0/part0_pins.xml -- the board file this build actually loads --
# which names i2c_scl_i on P16 and i2c_sda_i on P15, and src/pynqz2_cam.xdc, which put the
# camera shield's SDA/SCL on the same two balls from the shield's own netlist.  They agree.
set i2c_pins {
  i2c_scl P16   i2c_sda P15
}
# THE FOUR PUSHBUTTONS (has_btn), same two assertions.  Source: boards/arty-z7-20/A.0/
# part0_pins.xml's btns_4bits_tri_i_0..3, and boards/pynq-z2/A.0/part0_pins.xml, which agree ball
# for ball and in the same order.  It must agree with src/pynqz2_btn.xdc, where the reasoning is.
set btn_pins {
  btn[0] D19   btn[1] D20   btn[2] L20   btn[3] L19
}
# THE CAMERA'S VIDEO PINS WITHOUT ITS I2C (has_ospi): cam_pins above, minus cam_sda/cam_scl,
# which src/pynqz2_i2c.xdc's i2c_pins owns for this variant.  Same source, same two assertions
# (post-synth against the constraint, post-route against the placement), and the same U13
# PUDC_B check afterwards.  It must agree with src/pynqz2_ospi.xdc.
set ospi_pins {
  cam_d[0] T14   cam_d[1] U12   cam_d[2] V13   cam_d[3] V15
  cam_d[4] T15   cam_d[5] R16   cam_d[6] U17   cam_d[7] V17
  cam_pclk U10   cam_fvld W11   cam_lvld V11   cam_int  T5
  cam_mclk V18   cam_trig T16
}
# An explicit override, for sweeping the clock without editing this file. Everything
# downstream (the PS7 preset, and therefore the timing constraint) follows it.
if {[info exists ::env(ROCKET_FCLK_MHZ)] && $::env(ROCKET_FCLK_MHZ) ne ""} {
  set fclk_mhz $::env(ROCKET_FCLK_MHZ)
}
# Where the generated Verilog comes from, in order of preference:
#
#   1. $CHIPYARD_GENSRC          -- an explicit override, always wins
#   2. $CHIPYARD_DIR's elaboration for $cfg -- a live Chipyard tree, so someone who has
#                                   just re-elaborated gets what they just built
#   3. the collateral vendored in this repo, unpacked by scripts/08_gensrc.sh -- which is
#                                   what a fresh checkout with no Chipyard install uses
#
# There is no hard-coded fallback into anyone's scratch directory any more; if none of the
# three resolve, this errors with the command to run. See docs/REPRODUCING.md.
set gensrc ""
if {[info exists ::env(CHIPYARD_GENSRC)]} {
  set gensrc $::env(CHIPYARD_GENSRC)
} else {
  if {[info exists ::env(CHIPYARD_DIR)] && $::env(CHIPYARD_DIR) ne ""} {
    set cand $::env(CHIPYARD_DIR)/sims/verilator/generated-src/chipyard.harness.TestHarness.$cfg
    if {[file isdirectory $cand]} { set gensrc $cand }
  }
  if {$gensrc eq ""} {
    set gsroot [expr {[info exists ::env(CHIPYARD_GENSRC_ROOT)] ? $::env(CHIPYARD_GENSRC_ROOT)
                                                               : [file normalize $root/../../out/gensrc]}]
    set cand $gsroot/chipyard.harness.TestHarness.$cfg
    if {[file isdirectory $cand]} { set gensrc $cand }
  }
}
if {$gensrc eq "" || ![file isdirectory $gensrc]} {
  error "no generated Verilog for $cfg.\n\
    Unpack the collateral vendored in this repo:  scripts/08_gensrc.sh\n\
    or point CHIPYARD_GENSRC at an elaboration, or CHIPYARD_DIR at a Chipyard tree.\n\
    See docs/REPRODUCING.md."
}
puts "CHIPYARD_GENSRC: $gensrc"
# THE COLLATERAL AND THE BLACKBOX MUST AGREE ON THE PORT LIST.  Every 0029..002D respin got away
# with the vendored bundle because mbxr_engine is a BlackBox and nothing inside it is elaborated.
# The 2-D drain adds `aa_size` to that port list; a bundle without it leaves the output dangling
# and the A channel hard-wired to 64-byte transactions, which is a WRONG BITSTREAM and not a
# build error.  So check the generated Verilog, not the config name.
if {$need_aa_size} {
  set eng_sv ""
  foreach cand [glob -nocomplain $gensrc/gen-collateral/RoccMoonEngine.sv $gensrc/*.top.v \
                                 $gensrc/gen-collateral/*.sv] {
    set fh [open $cand r]; set txt [read $fh]; close $fh
    if {[string match "*aa_size*" $txt]} { set eng_sv $cand; break }
  }
  if {$eng_sv eq ""} {
    error "AA_SIZE_MISSING: the generated Verilog under $gensrc does not connect mbxr_engine's\n\
      aa_size port.  This variant needs the SoC RE-ELABORATED with this repo's\n\
      chipyard/RoccMoon.scala:  scripts/62_patch_chipyard_roccmoon.sh && make -C\n\
      \$CHIPYARD_DIR/sims/verilator CONFIG=$cfg verilog, then point CHIPYARD_GENSRC at it.\n\
      The VENDORED bundle for $cfg is 0x5A5A002D's and does NOT have it."
  }
  puts "AA_SIZE_OK: $eng_sv"
}
puts "ROCKET_VARIANT: $variant  config=$cfg  magic=$soc_magic  fclk=${fclk_mhz}MHz"

# THE MEMORY-PORT CONTRACT, checked before anything is built.  Every width on the path
# ChipTop.axi4_mem_* -> this top level's wires -> axi4_to_axi3 -> S_AXI_HPn must agree for THIS
# variant's define set and THIS generated Verilog.  Verilog connects mismatched widths silently:
# the first 0x5A5A0018/0019 builds elaborated a 128-bit ExtMem into the 64-bit wires, met
# timing, and printed nothing on the board (MEMORY_BANDWIDTH.md s6.9).  The checker reads the
# variant's defines from this file, so the two cannot drift; --all lints every variant.
if {[catch {exec -ignorestderr python3 $root/scripts/check_mem_contract.py \
              --variant $variant --gensrc $gensrc} contract_out]} {
  puts $contract_out
  error "MEM_PORT_CONTRACT: ChipTop's memory ports and src/pynqz2_rocket_top.v disagree for '$variant' -- refusing to build"
}
puts $contract_out
set topf [glob -nocomplain $gensrc/*.top.f]
if {[llength $topf] != 1} { error "expected exactly one *.top.f in $gensrc" }
set topf [lindex $topf 0]

# 40 MHz, not 50, for the two TACIT variants (the P-ext variant is 35 -- see the
# ROCKET_VARIANT table above). MEASURED: at 50 MHz this design misses by WNS -2.063 ns, on a path
# inside the L2 MSHR scheduler (mshrs_1/s_grantack -> mshrs_4/s_writeback): 30 logic
# levels, 21.65 ns, 72% of it routing. That is the inclusive cache's scheduler, not
# anything in the PS interface, and it is a known long path for this cache on a small
# congested -1 part. 25 ns leaves roughly 3 ns of margin. Going faster means trimming the
# L2 further (fewer MSHRs/ways) rather than tweaking constraints.
set_param board.repoPaths [list $root/boards]
source $root/tcl/board.tcl
set build $root/${builddir}_$::BOARD
file mkdir $build/reports

create_project $projname $build/proj -part xc7z020clg400-1 -force
set_property board_part $::BOARD_PART [current_project]

# --- Chipyard sources. top.f is the chip only: it carries ChipTop plus the synthesizable
# --- blackboxes, and excludes TestHarness/SimDRAM/ClockSourceAtFreqMHz, which are
# --- simulation-only and would not synthesise.
set fh [open $topf r]; set files [split [string trim [read $fh]] "\n"]; close $fh
puts "Chipyard sources from top.f: [llength $files]"
add_files -norecurse $files

# The SRAM macros (cc_dir_ext, tag_array_ext, ...) are emitted by a separate mem-gen pass
# into *.top.mems.v and are NOT listed in top.f. Without them synthesis fails with
# "module 'cc_dir_ext' not found" on the L2 directory.
set mems [glob -nocomplain $gensrc/gen-collateral/*.top.mems.v]
if {[llength $mems] == 0} { error "no *.top.mems.v found in $gensrc/gen-collateral" }
puts "SRAM macro files: [llength $mems]"
add_files -norecurse $mems
set_property file_type SystemVerilog [get_files -quiet *.sv]

set repo_rtl [list $root/src/pynqz2_rocket_top.v \
                   $root/src/axi4_to_axi3.v \
                   $root/src/soc_ctrl_regs.v]
if {$has_mic} {
  # The microphone front end.  It is a Chisel BlackBox -- an extmodule -- so Chipyard emits
  # the instantiation and NOT the module, and these files are where the module comes from.
  # They are deliberately not vendored into the generator's resources: sim/run_pdm_sim.sh
  # tests exactly these files, and a second copy inside Chipyard would be free to drift.
  lappend repo_rtl $root/src/pdm_mic_core.v $root/src/pdm_mic_capture.v \
                   $root/src/pdm_cic4.v $root/src/pdm_fir_mac.v \
                   $root/src/pdm_dcblock.v $root/src/pdm_mic_fifo.v
}
if {$has_bw} {
  # The bandwidth instrument's engine.  Same reasoning as the microphone's Verilog, and
  # a stronger version of it: this is the EXACT file that rtl_study/rocc/ooc_rocc_d.tcl
  # synthesised out of context and that tb_mbxd.sv and tb_mbxd_bw.sv simulate. The whole
  # claim of the experiment is that the routed engine is the engine that was measured, so
  # there is one copy of it and Vivado reads that one.
  lappend repo_rtl $root/rtl_study/rocc/mbxd_dma.v
}
if {$has_roccmoon2b} {
  # ENGINE REVISION 2b.  rev2/mbxr_engine.v carries mbxr_engine_core and mbxr_whalf (the two the
  # Chisel instantiates), and also mbxr_engine and mbxr_engine_x, which this build does not use --
  # which is why roccmoon/mbxr_engine.v, roccmoon/mbxr_st.v and roccmoon/mbxd_spad2.v must NOT be
  # added alongside it (the guard above refuses has_roccmoon with has_roccmoon2b).  mbxr_tseq.v and
  # mbxr_datapath.v are shared with revision 2a; mbxd_dma.v (client A) and mbx_mac.v (the DSP48E1
  # cell) are the measured study files, unchanged.
  # The nine files, each with its md5 in the build log: the bitstream is tied to the RTL it was
  # built from, and the W-lane gate (scripts/build_roccmoon2b_z1.sh, run immediately before Vivado)
  # checks the same nine md5s against the copy it simulates.  rtl_study/ is read directly, with no
  # snapshot, because revision 2b is still being edited -- the md5 line is what pins a build to it.
  foreach f {roccmoon/rev2/mbxr_engine.v roccmoon/rev2/mbxr_wx.v roccmoon/rev2/mbxd_dma2.v
             roccmoon/rev2/mbxd_spad2.v roccmoon/rev2/mbxr_st.v
             roccmoon/mbxr_tseq.v roccmoon/mbxr_datapath.v
             rocc/mbxd_dma.v rocc/mbx_mac.v} {
    if {![file exists $root/rtl_study/$f]} { error "ENGINE_RTL: missing $root/rtl_study/$f" }
    puts "ENGINE_RTL: rtl_study/$f [lindex [exec md5sum $root/rtl_study/$f] 0]"
    lappend repo_rtl $root/rtl_study/$f
  }
}
if {$has_roccmoon} {
  # The decoupled engine.  One copy of every file, and it is the copy tb_mbxr.cpp checked
  # byte for byte against ModelBlaster's kernel_linear_s8: mbxd_dma.v and mbxd_spad.v are
  # the measured study files unchanged, mbx_mac.v supplies the instantiated DSP48E1 cell.
  if {[info exists roccmoon_rtl_snapshot]} {
    # A variant that pins the engine revision (roccmooncam) reads its own copy, and refuses to
    # build unless every file matches the md5 recorded when the copy was taken.
    set snap $root/$roccmoon_rtl_snapshot
    set want {mbxd_dma.v mbxd_spad.v mbx_mac.v mbxr_datapath.v mbxr_engine.v mbxr_st.v mbxr_tseq.v}
    set fh [open $snap/MD5SUMS r]; set sums [split [string trim [read $fh]] "\n"]; close $fh
    set got {}
    foreach line $sums {
      lassign $line sum f
      set actual [lindex [exec md5sum $snap/$f] 0]
      if {$actual ne $sum} {
        error "ENGINE_RTL_SNAPSHOT: $roccmoon_rtl_snapshot/$f is $actual, MD5SUMS says $sum -- refusing to build"
      }
      puts "ENGINE_RTL_SNAPSHOT: $roccmoon_rtl_snapshot/$f $actual"
      lappend got $f
      lappend repo_rtl $snap/$f
    }
    if {[lsort $got] ne [lsort $want]} {
      error "ENGINE_RTL_SNAPSHOT: MD5SUMS lists '[lsort $got]', expected '[lsort $want]'"
    }
  } else {
    # rtl_study/ holds engine revision 2a (since 2026-09-17): the scratchpad is mbxd_spad2.v
    foreach f {roccmoon/mbxr_engine.v roccmoon/mbxr_tseq.v roccmoon/mbxr_datapath.v
               roccmoon/mbxr_st.v roccmoon/mbxd_spad2.v rocc/mbxd_dma.v rocc/mbx_mac.v} {
      lappend repo_rtl $root/rtl_study/$f
    }
  }
}
if {$has_lanes && [info exists lanes_rtl_snapshot]} {
  # A variant that PINS the lane-bearing engine to a revision reads its own copy and refuses to
  # build unless every file matches the md5 recorded when the copy was taken -- the same
  # mechanism roccmooncam uses for has_roccmoon, for the same reason and one more.
  #
  # THE REASON: rtl_study/roccmoon/merge/ is a LIVE workstream's directory.  A variant whose
  # whole claim is "this is <some other build>'s logic at a different clock" cannot read a
  # directory that another workstream is editing -- the engine moved from 0x5A5A002E's
  # cce8c84f to 0x5A5A002F's d13170d8 while this variant was being written, and a build that
  # silently picked that up would be TWO changes wearing one MAGIC.  The md5 check is what
  # makes "byte for byte 002E's" a checked claim rather than a hopeful one.
  set snap $root/$lanes_rtl_snapshot
  set want {mbxr_engine.v mbxr_lanes.v mbxa_unit.v mbxa_rq.v mbxr_smx.v mbxr_ln.v mbxl_lut.v
            mbxr_tseq.v mbxr_datapath.v mbxr_st.v mbxd_spad2.v mbxd_dma.v mbx_mac.v}
  set fh [open $snap/MD5SUMS r]; set sums [split [string trim [read $fh]] "\n"]; close $fh
  set got {}
  foreach line $sums {
    if {[string index $line 0] eq "#" || [string trim $line] eq ""} { continue }
    lassign $line sum f
    set actual [lindex [exec md5sum $snap/$f] 0]
    if {$actual ne $sum} {
      error "LANES_RTL_SNAPSHOT: $lanes_rtl_snapshot/$f is $actual, MD5SUMS says $sum -- refusing to build"
    }
    puts "ENGINE_RTL_SNAPSHOT: $lanes_rtl_snapshot/$f $actual"
    lappend got $f
    lappend repo_rtl $snap/$f
  }
  if {[lsort $got] ne [lsort $want]} {
    error "LANES_RTL_SNAPSHOT: MD5SUMS lists '[lsort $got]', expected '[lsort $want]'"
  }
} elseif {$has_lanes} {
  # Engine revision 2a with the two lanes merged in (rtl_study/roccmoon/merge/mbxr_engine.v).
  # mbxr_tseq.v, mbxr_datapath.v, mbxr_st.v, mbxd_spad2.v, mbxd_dma.v and mbx_mac.v are
  # roccmoon/'s, unchanged and shared with 0x5A5A0028; the lanes are their own workstreams'
  # committed files, read here unedited -- the config-space widening is entirely inside
  # merge/mbxr_lanes.v, so the committed out-of-context numbers are the numbers for these
  # files.  Every md5 is printed, because this variant reads from four directories.
  foreach f {roccmoon/merge/mbxr_engine.v roccmoon/merge/mbxr_lanes.v
             roccmoon/attn_unit/mbxa_unit.v roccmoon/attn_unit/mbxa_rq.v
             roccmoon/smx_lane/mbxr_smx.v roccmoon/ln_lane/mbxr_ln.v
             roccmoon/lut_lane/mbxl_lut.v
             roccmoon/mbxr_tseq.v roccmoon/mbxr_datapath.v roccmoon/mbxr_st.v
             roccmoon/mbxd_spad2.v rocc/mbxd_dma.v rocc/mbx_mac.v} {
    set path $root/rtl_study/$f
    puts "ENGINE_RTL: rtl_study/$f [lindex [exec md5sum $path] 0]"
    lappend repo_rtl $path
  }
  set fh [open $root/rtl_study/roccmoon/merge/MD5SUMS.src r]
  foreach line [split [string trim [read $fh]] "\n"] {
    if {[string index $line 0] eq "#" || $line eq ""} { continue }
    lassign $line sum f
    set actual [lindex [exec md5sum $root/$f] 0]
    if {$actual ne $sum} {
      puts "ENGINE_RTL_SRC_MOVED: $f is $actual, merge/MD5SUMS.src recorded $sum"
    } else {
      puts "ENGINE_RTL_SRC: $f $actual"
    }
  }
  close $fh
}
add_files -norecurse $repo_rtl
add_files -fileset constrs_1 -norecurse $root/src/pynqz2_rocket.xdc
if {$has_mic} {
  # A SEPARATE file, not a guarded block inside pynqz2_rocket.xdc. Vivado parses anything in
  # constrs_1 as XDC, which has no `if` and no `foreach` -- it answers both with a CRITICAL
  # WARNING and then runs neither, leaving the microphone's two pins unconstrained and
  # auto-placed. See the header of src/pynqz2_mic.xdc.
  add_files -fileset constrs_1 -norecurse $root/src/pynqz2_mic.xdc
}
if {$has_rgb} {
  # Same rule, same reason: a separate file, added only for the variant that has the ports.
  # There is no RTL to add alongside it -- unlike the microphone, the GPIO controller is
  # ordinary Chisel and arrives in the generated Verilog, so nothing here is a BlackBox.
  add_files -fileset constrs_1 -norecurse $root/src/pynqz2_rgb.xdc
}
if {$has_cam} {
  # The camera shield's pins and the PCLK clock, in their own file for the XDC reason above.
  add_files -fileset constrs_1 -norecurse $root/src/pynqz2_cam.xdc
}
if {$has_i2c} {
  # The I2C bus without the camera: two balls, their pull-ups and two false paths.  Its own
  # file, for the XDC reason above.
  add_files -fileset constrs_1 -norecurse $root/src/pynqz2_i2c.xdc
}
if {$has_btn} {
  # The four pushbuttons.  Same rule, same reason.
  add_files -fileset constrs_1 -norecurse $root/src/pynqz2_btn.xdc
}
if {$has_ospi} {
  # The camera's video pins and the PCLK clock, without its I2C: src/pynqz2_cam.xdc minus its
  # two I2C lines.  Its own file, for the XDC reason above.
  add_files -fileset constrs_1 -norecurse $root/src/pynqz2_ospi.xdc
}
if {$has_memclk} {
  # FCLK0 and FCLK1 are unrelated as far as timing is concerned -- see the file.
  add_files -fileset constrs_1 -norecurse $root/src/pynqz2_memclk.xdc
}
if {$has_wlane} {
  # The same statement for the weight lane's FCLK1, plus the lane's own crossings: its file, not
  # pynqz2_memclk.xdc, because that one's CDC waivers name the memory domain's structures.
  add_files -fileset constrs_1 -norecurse $root/src/pynqz2_wlane.xdc
}
set_property top pynqz2_rocket_top [current_fileset]

# --- PS7: same explicit preset, plus UART1 on EMIO for the Rocket console ---
source $root/tcl/$::PRESET_FILE
create_ip -name processing_system7 -vendor xilinx.com -library ip -module_name ps7_0
$::PRESET_PROC [get_ips ps7_0]
set_property -dict [list \
  CONFIG.PCW_USE_S_AXI_HP0 {1} \
  CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk_mhz \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_EN_RST0_PORT {1} \
  CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
  CONFIG.PCW_UART1_UART1_IO {EMIO} \
  CONFIG.PCW_UART1_BAUD_RATE {115200} \
] [get_ips ps7_0]

# The extra memory channels' HP ports.  S_AXI_HP0..HP3 are PS7-internal hard silicon -- no
# package pins, no XDC, and they cost nothing in PL resources.  Channel 1 goes to HP1, or to
# HP2 under has_ch1_hp2; has_nmem4 adds channels 2 and 3 on HP2 and HP3.  NOTE the PS7 IP
# settings configure the PL-side ports only: the AFI and DDR controller registers are
# programmed by the FSBL at boot and are read back on the board, not assumed from here.
set extra_hp {}
if {$has_nmem4}        { set extra_hp {1 2 3} } \
elseif {$has_ch1_hp2}  { set extra_hp {2} } \
elseif {$has_nmem2}    { set extra_hp {1} }
# The weight lane's port.  It is not a memory channel -- ExtMem still has exactly one, on HP0 -- so
# it is added here rather than through the channel count, and the guard above has already refused the
# variants that would claim HP2 for a channel.
if {$has_wlane}        { lappend extra_hp 2 }
foreach hp $extra_hp {
  set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP$hp {1} \
    CONFIG.PCW_S_AXI_HP${hp}_DATA_WIDTH {64} \
  ] [get_ips ps7_0]
  foreach {k want} [list PCW_USE_S_AXI_HP$hp {1} PCW_S_AXI_HP${hp}_DATA_WIDTH {64}] {
    set got [get_property CONFIG.$k [get_ips ps7_0]]
    if {[string trim $got] ne [string trim $want]} {
      error "PS7 misconfigured: $k = '$got', expected '$want'"
    }
  }
  puts "PS7: S_AXI_HP$hp enabled, 64-bit"
}

if {$has_wlane} {
  # FCLK1 for the weight lane, exactly as has_memclk does it for the memory domain (the two are
  # refused together above).  The achieved frequency is checked for the same reason: every
  # B-per-cycle figure the lane reports is computed from the clock it actually got, and the labs
  # read it back on the board with host/fclk.py --expect.
  set_property -dict [list \
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_FPGA_FCLK1_ENABLE {1} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ $fclk_wlane_mhz \
  ] [get_ips ps7_0]
  set clk1_hz [get_property CONFIG.PCW_CLK1_FREQ [get_ips ps7_0]]
  set clk1_mhz [expr {$clk1_hz / 1.0e6}]
  puts [format "PS7 FCLK1 (W lane): requested %s MHz -> ACHIEVED %.4f MHz (%.3f ns)" \
        $fclk_wlane_mhz $clk1_mhz [expr {1000.0 / $clk1_mhz}]]
  if {[expr {abs($clk1_mhz - $fclk_wlane_mhz) / double($fclk_wlane_mhz)}] > 0.02} {
    error "FCLK1 is $clk1_mhz MHz, more than 2% from the requested $fclk_wlane_mhz"
  }
}
if {$has_memclk} {
  # FCLK1 for the memory domain.  ps7_preset_pynqz1.tcl ships PCW_EN_CLK1_PORT {0} and
  # PCW_FPGA_FCLK1_ENABLE {0}; FCLK1-3 are free and cost nothing but configuration.
  #
  # The achieved frequency is checked below the same way FCLK0's is, because
  # PCW_FPGA1_PERIPHERAL_FREQMHZ is a REQUEST: FCLK = IO PLL / (integer x integer) and
  # the IO PLL is 1000 MHz, so only 1000/N is reachable.  100 is 1000/10 and lands
  # exactly; a request the PLL cannot make would otherwise be silently rounded and every
  # bytes-per-cycle number computed from the requested clock would be wrong by that
  # rounding.
  set_property -dict [list \
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_FPGA_FCLK1_ENABLE {1} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ $fclk_mem_mhz \
  ] [get_ips ps7_0]
  # PCW_CLK1_FREQ is the ACHIEVED frequency in Hz, the same property the FCLK0 check
  # below reads.  There is no PCW_FPGA1_ACTUAL_PERIPHERAL_FREQMHZ.
  set clk1_hz [get_property CONFIG.PCW_CLK1_FREQ [get_ips ps7_0]]
  set clk1_mhz [expr {$clk1_hz / 1.0e6}]
  puts [format "PS7 FCLK1: requested %s MHz -> ACHIEVED %.4f MHz (%.3f ns)" \
        $fclk_mem_mhz $clk1_mhz [expr {1000.0 / $clk1_mhz}]]
  if {[expr {abs($clk1_mhz - $fclk_mem_mhz) / double($fclk_mem_mhz)}] > 0.02} {
    error "FCLK1 is $clk1_mhz MHz, more than 2% from the requested $fclk_mem_mhz"
  }
}

foreach {k want} [list PCW_UIPARAM_DDR_PARTNO {MT41J256M16 RE-125} \
                                    PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
                                    PCW_USE_S_AXI_HP0 {1} \
                                    PCW_UIPARAM_DDR_T_RCD $::DDR_T_RCD \
                                    PCW_UART1_UART1_IO {EMIO}] {
  set got [get_property CONFIG.$k [get_ips ps7_0]]
  if {[string trim $got] ne [string trim $want]} {
    error "PS7 misconfigured: $k = '$got', expected '$want'"
  }
}
puts "PS7 verified: DDR geometry + HP0 + UART1 on EMIO."

# The ACHIEVED FCLK0, not the requested one. FCLK0 = IO PLL / (DIVISOR0 * DIVISOR1) with
# both divisors integers, so a request the PLL cannot divide down to exactly is silently
# rounded -- and everything downstream (the timing constraint, the Zephyr tick rate, the
# UART baud divisor) has to follow the ACHIEVED value, not the request. Print it, and
# refuse a request that landed more than 2% away, which would mean this table and the
# board disagree about what was built.
set clk0_hz [get_property CONFIG.PCW_CLK0_FREQ [get_ips ps7_0]]
set clk0_mhz [expr {double($clk0_hz) / 1.0e6}]
puts [format "PS7 FCLK0: requested %s MHz -> ACHIEVED %.4f MHz (%.3f ns), divisors %s x %s" \
        $fclk_mhz $clk0_mhz [expr {1.0e9 / double($clk0_hz)}] \
        [get_property CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR0 [get_ips ps7_0]] \
        [get_property CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR1 [get_ips ps7_0]]]
puts [format "ACHIEVED_FCLK_HZ: %d" $clk0_hz]
if {abs($clk0_mhz - $fclk_mhz) > 0.02 * $fclk_mhz} {
  error "PS7 cannot deliver $fclk_mhz MHz: nearest is $clk0_mhz MHz (>2% away)"
}

generate_target all [get_ips ps7_0]
synth_ip [get_ips ps7_0]

# An undriven net synthesises to constant 0 with only a WARNING. On an AXI ID path that is
# fatal but silent: the PS7 GP0 master never retires a read whose RID does not match the
# ARID it issued, so the CPU locks on the very first register read and the board needs a
# physical power cycle. MEASURED: gp0_rid was undriven in the first Z1 builds and did
# exactly that. It was the only 8-3848 in either build, so promoting it is safe.
set_msg_config -id {Synth 8-3848} -new_severity ERROR
# ...and a port connection whose width differs from the port's (Synth 8-689), the as-built half of
# the memory-port contract above.  MEASURED: it fired on w data and w strb in the broken 128-bit
# 0x5A5A0018/0019 builds and in none of 27 other rocket build logs.  It does not fire for a
# too-wide INPUT (r data was silent), which is why the checker runs first.
set_msg_config -id {Synth 8-689} -new_severity ERROR

# SOC_MAGIC is a top-level Verilog parameter (default 0x5A5A0002). Overriding it here
# is what makes the dual-core bitstream identifiable at 0x4000_0008: the two designs are
# otherwise pin- and register-compatible, so a run against the wrong one would boot
# happily and be silently single-core.
# PYNQZ2_HAS_MIC adds two ports to pynqz2_rocket_top and two connections to ChipTop.  A
# preprocessor conditional rather than a parameter, because ChipTop only HAS those ports in
# the mic config -- and because for every other variant the lines then vanish, leaving the
# top's RTL textually unchanged and u_soc's hierarchy path (and placement) untouched.
# -include_dirs src is for `include "pdm_fir_coeffs.vh" in pdm_fir_mac.v.
set synth_args [list -top pynqz2_rocket_top -part xc7z020clg400-1 -generic SOC_MAGIC=$soc_magic]
if {$has_mic} {
  lappend synth_args -verilog_define PYNQZ2_HAS_MIC=1 -include_dirs $root/src
}
if {$has_rgb} { lappend synth_args -verilog_define PYNQZ2_HAS_RGB=1 }
if {$has_cam} { lappend synth_args -verilog_define PYNQZ2_CAM=1 }
if {$has_i2c} { lappend synth_args -verilog_define PYNQZ2_HAS_I2C=1 }
if {$has_btn} { lappend synth_args -verilog_define PYNQZ2_HAS_BTN=1 }
if {$has_ospi} { lappend synth_args -verilog_define PYNQZ2_HAS_OSPI=1 }
if {$has_wlane}  { lappend synth_args -verilog_define PYNQZ2_WLANE=1 }
if {$has_memclk} { lappend synth_args -verilog_define PYNQZ2_HAS_MEMCLK=1 }
if {$has_tileclk} { lappend synth_args -verilog_define PYNQZ2_HAS_TILECLK=1 }
if {$has_nmem2}  { lappend synth_args -verilog_define PYNQZ2_NMEM2=1 }
if {$has_ch1_hp2} { lappend synth_args -verilog_define PYNQZ2_CH1_HP2=1 }
if {$has_nmem4}  { lappend synth_args -verilog_define PYNQZ2_NMEM4=1 }
synth_design {*}$synth_args
set md [get_nets -quiet -filter {ROUTE_STATUS == CONFLICTS}]
if {[llength $md] > 0} { error "multi-driven nets after synthesis: $md" }

if {$has_wlane} {
  # THE TWO RESET-FREE INSTANCES, checked in the netlist rather than trusted from the RTL.
  #
  #   roccmoon_wquiet   the AR/RLAST balance counter at the lane's AXI4 pins (rtl_study/roccmoon/
  #                     rev2/mbxr_wx.v).  After a reset with bursts outstanding it must still know
  #                     how many RLASTs are due, so nothing may clear it.
  #   resetHold/hold    the flop that keeps the lane in reset until that counter says quiet
  #                     (chipyard/WLanePort.scala).  It is SET by the lane's reset -- that is its
  #                     function -- and cleared only by quiet, so a synchronous set is expected and
  #                     an asynchronous set or reset is not.
  #
  # Both must be FDRE or FDSE with no asynchronous set/reset, and INIT equal to the power-up value
  # THE RTL DECLARES -- which is not the same value for both.  `mbxr_wquiet`'s output is
  # `initial quiet = 1'b1` (rtl_study/roccmoon/rev2/mbxr_wx.v:214): with nothing outstanding the
  # lane IS quiet at power-up, which is what lets the hold release on a board whose PL is never
  # reset again.  Its two counters and the hold flop are 1'b0.  The first build of 0x5A5A0013
  # stopped here because this check demanded 1'b0 of every flop: the check was wrong, the netlist
  # was right (MEMORY_BANDWIDTH.md 9.10, build note).
  #
  # What must not change is that NOTHING CLEARS THESE FLOPS: an FDRE's R pin must be tied to
  # ground, and so must an FDSE's S pin -- except on the hold flop itself, whose synchronous set
  # by the lane's reset is its function.  A reset net anywhere else here would undo the whole
  # point (MEMORY_BANDWIDTH.md 9.9).
  set nrf 0
  foreach pat {*roccmoon_wquiet/* */resetHold/hold*} {
    foreach c [get_cells -quiet -hier -filter "NAME =~ $pat && PRIMITIVE_GROUP == FLOP_LATCH"] {
      set ref [get_property REF_NAME $c]
      if {[lsearch -exact {FDRE FDSE} $ref] < 0} {
        error "WLANE_RESET_FREE: $c is $ref -- it must be a synchronous flop with no asynchronous set/reset"
      }
      set nm [get_property NAME $c]
      set want [expr {[string match {*roccmoon_wquiet/quiet*} $nm] ? "1'b1" : "1'b0"}]
      if {[get_property INIT $c] ne $want} {
        error "WLANE_RESET_FREE: $nm INIT is [get_property INIT $c], expected $want"
      }
      if {$ref eq "FDRE"} {
        set rnet [get_nets -quiet -of_objects [get_pins -quiet $c/R]]
        if {[llength $rnet] && [get_property TYPE $rnet] ne "GROUND"} {
          error "WLANE_RESET_FREE: $nm/R is driven by $rnet -- it must never be reset"
        }
      } elseif {![string match {*resetHold/hold*} $nm]} {
        set snet [get_nets -quiet -of_objects [get_pins -quiet $c/S]]
        if {[llength $snet] && [get_property TYPE $snet] ne "GROUND"} {
          error "WLANE_RESET_FREE: $nm/S is driven by $snet -- only the hold flop may be set by a net"
        }
      }
      puts "WLANE_RESET_FREE_CELL: $nm $ref INIT $want"
      incr nrf
    }
  }
  if {$nrf == 0} { error "WLANE_RESET_FREE: found no flops in roccmoon_wquiet or resetHold -- did the names change?" }
  puts "WLANE_RESET_FREE: $nrf flop(s) checked, all synchronous, INIT as the RTL declares, nothing\
        clears them"

  # EVERY OBJECT QUERY IN src/pynqz2_wlane.xdc MUST MATCH SOMETHING.
  #
  # The first build of 0x5A5A0013 shipped two set_max_delay lines whose cell filters matched ZERO
  # cells -- they named a hierarchy this netlist does not have -- and `-quiet` swallowed the
  # empty-object warning, so the build passed with its crossings unbounded (MEMORY_BANDWIDTH.md
  # 9.11).  A constraint that names nothing looks exactly like a constraint that works, so this
  # re-runs the file's queries generally: every bracketed get_* in it is evaluated here, and an
  # empty result fails the build.  It costs a second and it is not specific to today's three
  # constraints -- add a fourth and it is checked too.
  set fh [open $root/src/pynqz2_wlane.xdc r]
  set xdc_txt [read $fh]
  close $fh
  set xdc_body ""
  foreach line [split $xdc_txt "\n"] {
    if {[string index [string trimleft $line] 0] eq "#"} { continue }
    append xdc_body $line "\n"
  }
  set nq 0
  set i 0
  while {[set i [string first "\[get_" $xdc_body $i]] >= 0} {
    set depth 0
    set j $i
    set len [string length $xdc_body]
    while {$j < $len} {
      set ch [string index $xdc_body $j]
      if {$ch eq "\["} { incr depth } elseif {$ch eq "\]"} { incr depth -1 ; if {$depth == 0} { break } }
      incr j
    }
    set q [string range $xdc_body [expr {$i + 1}] [expr {$j - 1}]]
    set objs [eval $q]
    if {[llength $objs] == 0} {
      error "WLANE_XDC_QUERY: a query in src/pynqz2_wlane.xdc matched NOTHING, so whatever it\
             constrains is unconstrained -- $q"
    }
    puts "WLANE_XDC_QUERY: [llength $objs] objects <- [string range $q 0 79]"
    incr nq
    set i [expr {$j + 1}]
  }
  if {$nq == 0} { error "WLANE_XDC_QUERY: no object queries found in src/pynqz2_wlane.xdc -- did the file move?" }
  puts "WLANE_XDC_QUERY: $nq queries, every one matched"

  # AND THE BOUND MUST ACTUALLY BE IN FORCE.  Matching cells is only half of it: a clock-group
  # false path outranks set_max_delay (UG903), which is how the first build ended up unbounded in
  # the one direction where the names were right.  The only honest test is to ask the timer whether
  # a crossing has a slack at all.  Post-synthesis, so a mistake costs a synthesis and not a route.
  set wl_c0 [get_clocks -include_generated_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *PS7_i/FCLKCLK[0]}]]
  set wl_c1 [get_clocks -include_generated_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *PS7_i/FCLKCLK[1]}]]
  foreach {tag wfrom wto} [list ENGINE_TO_LANE $wl_c0 $wl_c1 LANE_TO_ENGINE $wl_c1 $wl_c0] {
    set wp [get_timing_paths -quiet -from $wfrom -to $wto -max_paths 1 -sort_by slack]
    if {[llength $wp] == 0} {
      error "WLANE_CDC_BOUND: no $tag paths at all -- the lane is not connected to the engine, or the clocks changed"
    }
    set ws [get_property SLACK $wp]
    if {![string is double -strict $ws]} {
      error "WLANE_CDC_BOUND: the $tag crossing is UNCONSTRAINED (slack '$ws') -- something outranks\
             the max delay in src/pynqz2_wlane.xdc, most likely a clock group or a false path"
    }
    puts [format "WLANE_CDC_BOUND: %s worst slack %s ns  (%s -> %s)" $tag $ws \
            [get_property STARTPOINT_PIN $wp] [get_property ENDPOINT_PIN $wp]]
  }
}

# The microphone's two pins, checked rather than assumed. BOTH halves of this have already
# failed silently once: PYNQZ2_HAS_MIC not reaching the preprocessor would leave the ports
# off the module, and a constraint file Vivado declines to run would leave them unplaced
# and then auto-placed on arbitrary balls. Neither shows up as an error on its own; the
# first produces an unconnected ChipTop port, the second a bitstream with the microphone
# wired somewhere else. This is real Tcl, not XDC, so `if` and `foreach` work here.
if {$has_mic} {
  foreach port {mic_pdm_clk mic_pdm_data} {
    set obj [get_ports -quiet $port]
    if {[llength $obj] == 0} {
      error "top-level port '$port' does not exist after synthesis -- PYNQZ2_HAS_MIC did\
             not reach src/pynqz2_rocket_top.v"
    }
    set pin [get_property PACKAGE_PIN $obj]
    if {$pin eq ""} {
      error "top-level port '$port' has no PACKAGE_PIN -- src/pynqz2_mic.xdc did not apply.\
             Check the log for 'Designutils 20-1307'."
    }
    puts "MIC_PIN: $port -> $pin"
  }
}

# The six RGB pins, checked against the constraint the same way -- this half catches
# PYNQZ2_HAS_RGB not reaching the preprocessor, and an XDC Vivado refused to run. It does
# NOT catch a misplacement, because at this point PACKAGE_PIN is still just the constraint
# read back to us. The post-route check below is the one that looks at the implementation.
if {$has_rgb} {
  foreach {port want} $rgb_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] == 0} {
      error "top-level port '$port' does not exist after synthesis -- PYNQZ2_HAS_RGB did\
             not reach src/pynqz2_rocket_top.v"
    }
    set got [get_property PACKAGE_PIN $obj]
    if {$got eq ""} {
      error "top-level port '$port' has no PACKAGE_PIN -- src/pynqz2_rgb.xdc did not apply.\
             Check the log for 'Designutils 20-1307'."
    }
    if {$got ne $want} {
      error "top-level port '$port' is constrained to $got, expected $want -- \
             src/pynqz2_rgb.xdc and this script's rgb_pins table disagree."
    }
    puts "RGB_PIN_SYNTH: $port -> $got"
  }
}
if {$has_cam} {
  foreach {port want} $cam_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} {
      error "top-level port '$port' does not exist after synthesis -- PYNQZ2_CAM did not reach\
             src/pynqz2_rocket_top.v"
    }
    set got [get_property PACKAGE_PIN $obj]
    if {$got ne $want} {
      error "top-level port '$port' is constrained to '$got', expected $want -- src/pynqz2_cam.xdc\
             did not apply or disagrees with cam_pins"
    }
    puts "CAM_PIN_SYNTH: $port -> $got"
  }
}
if {$has_i2c} {
  foreach {port want} $i2c_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} {
      error "top-level port '$port' does not exist after synthesis -- PYNQZ2_HAS_I2C did not\
             reach src/pynqz2_rocket_top.v"
    }
    set got [get_property PACKAGE_PIN $obj]
    if {$got ne $want} {
      error "top-level port '$port' is constrained to '$got', expected $want -- src/pynqz2_i2c.xdc\
             did not apply or disagrees with i2c_pins"
    }
    puts "I2C_PIN_SYNTH: $port -> $got"
  }
}
if {$has_btn} {
  foreach {port want} $btn_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} {
      error "top-level port '$port' does not exist after synthesis -- PYNQZ2_HAS_BTN did not\
             reach src/pynqz2_rocket_top.v"
    }
    set got [get_property PACKAGE_PIN $obj]
    if {$got ne $want} {
      error "top-level port '$port' is constrained to '$got', expected $want -- src/pynqz2_btn.xdc\
             did not apply or disagrees with btn_pins"
    }
    puts "BTN_PIN_SYNTH: $port -> $got"
  }
}
if {$has_ospi} {
  foreach {port want} $ospi_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} {
      error "top-level port '$port' does not exist after synthesis -- PYNQZ2_HAS_OSPI did not\
             reach src/pynqz2_rocket_top.v"
    }
    set got [get_property PACKAGE_PIN $obj]
    if {$got ne $want} {
      error "top-level port '$port' is constrained to '$got', expected $want --\
             src/pynqz2_ospi.xdc did not apply or disagrees with ospi_pins"
    }
    puts "OSPI_PIN_SYNTH: $port -> $got"
  }
}
report_utilization -file $build/reports/post_synth_util.rpt
write_checkpoint -force $build/post_synth.dcp

# Area gate: report before committing an hour to place and route.
set luts [get_property SLICE_LUTS [get_cells -hier -quiet]]
puts "=== POST-SYNTH UTILIZATION ==="
foreach line [split [exec grep -E {^\| (Slice LUTs|Slice Registers|Block RAM Tile|DSPs)} $build/reports/post_synth_util.rpt] "\n"] { puts $line }
if {$stage eq "synth"} { puts "SYNTH_ONLY_DONE"; exit 0 }

opt_design
place_design
phys_opt_design
route_design
# OPT-IN (ROCKET_POSTROUTE_PHYSOPT=1): one post-route phys_opt_design pass, only when setup slack is
# negative.  Added for bwwin (0x5A5A001C), whose first build missed FCLK0 by 2 ps on one L2 scheduler
# endpoint at 91 % LUT.  Unset, the flow -- and every existing variant's netlist -- is unchanged.
if {[info exists ::env(ROCKET_POSTROUTE_PHYSOPT)] && $::env(ROCKET_POSTROUTE_PHYSOPT) eq "1"} {
  set wns_pr [get_property SLACK [get_timing_paths -delay_type max]]
  puts "POSTROUTE_PHYSOPT: WNS before $wns_pr"
  if {$wns_pr < 0} {
    phys_opt_design -directive AggressiveExplore
    puts "POSTROUTE_PHYSOPT: WNS after [get_property SLACK [get_timing_paths -delay_type max]]"
  }
}
report_utilization      -file $build/reports/post_route_util.rpt
report_utilization -hierarchical -file $build/reports/post_route_util_hier.rpt
report_timing_summary   -file $build/reports/timing_summary.rpt -max_paths 10
report_drc              -file $build/reports/drc.rpt
# With two asynchronous clock domains an unsynchronised crossing stops being a timing
# failure and becomes a silent one.  This is where it shows up instead.
report_cdc              -file $build/reports/cdc.rpt
if {$has_wlane} {
  # report_cdc is a GATE for this variant, not a report.  Two of the lane's crossings are
  # structures Vivado cannot recognise -- a descriptor held stable by a handshake, and a Gray
  # encode computed at the source -- so they are waived in src/pynqz2_wlane.xdc by ID and by exact
  # pin pattern, with a reason each.  Anything left unsafe or unknown is a crossing nobody has
  # reviewed, and it fails the build (MEMORY_BANDWIDTH.md 9.11).
  set fh [open $build/reports/cdc.rpt r]
  set cdc_txt [read $fh]
  close $fh
  set cdc_bad 0
  foreach line [split $cdc_txt "\n"] {
    if {![string match "*No Common Primary Clock*" $line]} { continue }
    set f [regexp -all -inline {\S+} $line]
    if {[llength $f] < 6} { continue }
    set cdc_unsafe [lindex $f end-2]
    set cdc_unknown [lindex $f end-1]
    if {![string is integer -strict $cdc_unsafe] || ![string is integer -strict $cdc_unknown]} { continue }
    puts "WLANE_CDC: [lindex $f 1] -> [lindex $f 2]  endpoints [lindex $f end-4]\
          safe [lindex $f end-3]  unsafe $cdc_unsafe  unknown $cdc_unknown  no_async_reg [lindex $f end]"
    incr cdc_bad [expr {$cdc_unsafe + $cdc_unknown}]
  }
  if {$cdc_bad > 0} {
    error "WLANE_CDC: $cdc_bad unsafe or unknown crossing endpoint(s) in $build/reports/cdc.rpt --\
           every lane crossing is meant to be a synchroniser or one of the four waived structures;\
           a new one is a failure, not a waiver"
  }
  puts "WLANE_CDC: 0 unsafe, 0 unknown"
}
write_checkpoint -force $build/post_route.dcp

# ---------------------------------------------------------------------------------------
# WHERE THE PINS ACTUALLY LANDED, read out of the ROUTED design.
#
# report_io is written for every variant: it is a durable text artifact that a reader (or
# scripts/build_micrgb_z1.sh) can check later without opening Vivado again, and it is
# derived from the placement rather than from the constraint file.
report_io -file $build/reports/post_route_io.rpt

# And for the RGB build, assert it. `get_package_pins -of_objects [get_ports ...]` is
# answered by the PLACER, not by the XDC parser: it returns the package pin the port's IOB
# is placed on in THIS design. So is `get_sites -of_objects`. Both are checked, and both
# against the same table the XDC used -- because the whole hazard here is that nobody
# involved can look at the board, so "the constraint said L15" has to be upgraded to "the
# implemented design puts rgb_led[0] on L15" before it is worth anything.
if {$has_rgb} {
  foreach {port want} $rgb_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} { error "post-route: port '$port' vanished" }
    set pkg [get_package_pins -quiet -of_objects $obj]
    if {[llength $pkg] != 1} {
      error "post-route: port '$port' is not placed on exactly one package pin (got '$pkg')"
    }
    set pkgname [get_property NAME $pkg]
    if {$pkgname ne $want} {
      error "ROUTED DESIGN PUTS $port ON BALL $pkgname, NOT $want.\
             The bitstream would drive the wrong LED. Do not program this."
    }
    # Belt and braces, and both deliberately non-fatal if the tool will not answer: the
    # ball comparison above is the check, these two only add detail. A `catch` because a
    # property that a future Vivado renames should not destroy an hour of place and route
    # at the last line -- it should say so and let the ball check stand.
    set site "?"
    catch { set site [get_property NAME [get_sites -quiet -of_objects $obj]] }
    set fixed "?"
    catch { set fixed [get_property IS_LOC_FIXED $obj] }
    if {$fixed eq "0"} {
      error "post-route: '$port' landed on $pkgname but IS_LOC_FIXED is 0 -- it was\
             AUTO-PLACED, not constrained. src/pynqz2_rgb.xdc did not reach this design;\
             that it happened to land on the right ball is luck, not a constraint."
    }
    puts "RGB_PIN: $port -> $pkgname  site $site  fixed $fixed"
  }
  puts "RGB_PINS_VERIFIED_POST_ROUTE: 6"
}

if {$has_cam} {
  foreach {port want} $cam_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} { error "post-route: port '$port' vanished" }
    set pkg [get_property NAME [get_package_pins -quiet -of_objects $obj]]
    if {$pkg ne $want} {
      error "ROUTED DESIGN PUTS $port ON BALL '$pkg', NOT $want. Do not program this."
    }
    if {[get_property IS_LOC_FIXED $obj] ne "1"} {
      error "post-route: '$port' landed on $pkg but was AUTO-PLACED -- src/pynqz2_cam.xdc did not apply"
    }
    puts "CAM_PIN: $port -> $pkg"
  }
  puts "CAM_PINS_VERIFIED_POST_ROUTE: [expr {[llength $cam_pins] / 2}]"
  # PUDC_B.  The shield ties U13 to 3V3 through 0 ohms; a port there fights the tie.
  set pudc [get_ports -quiet -of_objects [get_package_pins U13]]
  if {[llength $pudc] != 0} { error "post-route: port '$pudc' is on U13 (PUDC_B, tied to 3V3 on the shield)" }
  puts "CAM_PUDC_B_U13: unassigned"
}

# The I2C balls and the buttons, in the ROUTED design -- the same upgrade from "the constraint
# said P16" to "the implemented design puts i2c_scl on P16" that rgb_pins gets above, and for the
# same reason: nobody involved can look at the board.  An OLED on the wrong two balls is a demo
# that does not light, and four buttons auto-placed on four arbitrary balls is worse, because
# some of them would be outputs of something else.
if {$has_i2c} {
  foreach {port want} $i2c_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} { error "post-route: port '$port' vanished" }
    set pkg [get_property NAME [get_package_pins -quiet -of_objects $obj]]
    if {$pkg ne $want} {
      error "ROUTED DESIGN PUTS $port ON BALL '$pkg', NOT $want. Do not program this."
    }
    if {[get_property IS_LOC_FIXED $obj] ne "1"} {
      error "post-route: '$port' landed on $pkg but was AUTO-PLACED -- src/pynqz2_i2c.xdc did not apply"
    }
    puts "I2C_PIN: $port -> $pkg"
  }
  puts "I2C_PINS_VERIFIED_POST_ROUTE: [expr {[llength $i2c_pins] / 2}]"
}
if {$has_btn} {
  foreach {port want} $btn_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} { error "post-route: port '$port' vanished" }
    set pkg [get_property NAME [get_package_pins -quiet -of_objects $obj]]
    if {$pkg ne $want} {
      error "ROUTED DESIGN PUTS $port ON BALL '$pkg', NOT $want. Do not program this."
    }
    if {[get_property IS_LOC_FIXED $obj] ne "1"} {
      error "post-route: '$port' landed on $pkg but was AUTO-PLACED -- src/pynqz2_btn.xdc did not apply"
    }
    puts "BTN_PIN: $port -> $pkg"
  }
  puts "BTN_PINS_VERIFIED_POST_ROUTE: [expr {[llength $btn_pins] / 2}]"
}
if {$has_ospi} {
  foreach {port want} $ospi_pins {
    set obj [get_ports -quiet $port]
    if {[llength $obj] != 1} { error "post-route: port '$port' vanished" }
    set pkg [get_property NAME [get_package_pins -quiet -of_objects $obj]]
    if {$pkg ne $want} {
      error "ROUTED DESIGN PUTS $port ON BALL '$pkg', NOT $want. Do not program this."
    }
    if {[get_property IS_LOC_FIXED $obj] ne "1"} {
      error "post-route: '$port' landed on $pkg but was AUTO-PLACED -- src/pynqz2_ospi.xdc did not apply"
    }
    puts "OSPI_PIN: $port -> $pkg"
  }
  puts "OSPI_PINS_VERIFIED_POST_ROUTE: [expr {[llength $ospi_pins] / 2}]"
  # PUDC_B, the same check has_cam makes: the shield ties U13 to 3V3 through 0 ohms, so a port
  # there fights the tie.
  set pudc [get_ports -quiet -of_objects [get_package_pins U13]]
  if {[llength $pudc] != 0} { error "post-route: port '$pudc' is on U13 (PUDC_B, tied to 3V3 on the shield)" }
  puts "OSPI_PUDC_B_U13: unassigned"
}

# Setup and hold PER CLOCK.  This was inside the camera branch, where it was added so the
# PCLK domain was reported on its own; every multi-clock variant needs it for the same
# reason (FCLK1's memory domain, and the W lane's).  It only PRINTS: no property is set,
# no design object is touched, and no build's result changes.
#
# TIMING_WNS below is NOT per clock: it is the design's worst setup slack across every
# clock (get_timing_paths with no -to).  A negative TIMING_WNS says the build missed
# somewhere; the TIMING_CLOCK lines say which domain.
foreach c [get_clocks] {
  set pmax [get_timing_paths -quiet -delay_type max -to $c]
  set pmin [get_timing_paths -quiet -delay_type min -to $c]
  puts [format "TIMING_CLOCK: %-24s WNS %s  WHS %s" [get_property NAME $c] \
        [expr {[llength $pmax] ? [get_property SLACK $pmax] : "none"}] \
        [expr {[llength $pmin] ? [get_property SLACK $pmin] : "none"}]]
}
set _overall_wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "TIMING_WNS: $_overall_wns"
puts "TIMING_WHS: [get_property SLACK [get_timing_paths -delay_type min]]"

# ---------------------------------------------------------------------------------------
# SAY IT HERE, SO A FOURTH LAB DOES NOT RE-DERIVE IT.
#
# Three separate workstreams have now independently worked out that a negative TIMING_WNS on
# a variant with the camera is not a missed build.  Each time, the number was read off this
# log, taken for the SoC clock, and re-explained from the routed checkpoint.  The
# explanation belongs next to the number, so it is printed next to the number.
#
# src/pynqz2_cam.xdc / src/pynqz2_ospi.xdc constrain cam_pclk at the HM01B0's DATASHEET
# ABSOLUTE MAXIMUM, 36 MHz -- a 13.889 ns falling-to-rising window -- against their own
# set_input_delay -max 15.000.  That is unsatisfiable by arithmetic before any logic is
# placed, and no configuration of this design can drive the sensor there anyway: the MCLK
# divider tops out at 17.24 MHz on the 34.4828 MHz builds and 20 MHz on the 40 MHz ones, and
# the part's own reset defaults run PCLK at MCLK/2.  MEASURED on the board, 2026-09-21:
# 2.833 MHz PCLK at MCLKDIV 2.  Re-timed on the SAME routed netlist at a reachable PCLK the
# camera group has large positive slack and zero failing endpoints.
#
# So read TIMING_CLOCK: clk_fpga_0 above for whether the SoC closed.  CAMERA_Z1.md 7.5 is
# the long form.  This block only PRINTS; it touches no design object.
if {$_overall_wns < 0} {
  set _soc [get_clocks -quiet clk_fpga_0]
  if {[llength $_soc]} {
    set _soc_p [get_timing_paths -quiet -delay_type max -to $_soc]
    set _soc_wns [expr {[llength $_soc_p] ? [get_property SLACK $_soc_p] : "none"}]
    if {$_soc_wns ne "none" && $_soc_wns >= 0} {
      puts "TIMING_NOTE: TIMING_WNS is the worst slack over ALL clocks and it is NEGATIVE,"
      puts "TIMING_NOTE:   but clk_fpga_0 (the SoC) is $_soc_wns -- the SoC CLOSED."
      puts "TIMING_NOTE:   On a camera variant the negative group is cam_pclk, constrained at"
      puts "TIMING_NOTE:   the HM01B0's 36 MHz datasheet MAXIMUM against a 15.0 ns input delay:"
      puts "TIMING_NOTE:   unsatisfiable by arithmetic, and unreachable by this design, whose"
      puts "TIMING_NOTE:   MCLK divider cannot drive the sensor above 20 MHz (measured PCLK on"
      puts "TIMING_NOTE:   the board 2026-09-21: 2.833 MHz). See the TIMING_CLOCK lines above"
      puts "TIMING_NOTE:   for which domain, and fpga/pynq-z2/docs/CAMERA_Z1.md section 7.5."
    }
  }
}
write_bitstream -force $build/pynq${::BOARD}_${bitsuffix}.bit
puts "BITSTREAM_OK: $build/pynq${::BOARD}_${bitsuffix}.bit"
exit
