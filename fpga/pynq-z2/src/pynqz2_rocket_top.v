// PYNQ-Z2 top level: Chipyard Rocket + TACIT, memory served by the Zynq PS.
//
//   PS7 ──FCLK_CLK0 (50 MHz)──▶ everything in the PL
//       ──M_AXI_GP0──────────▶ soc_ctrl_regs   (reset/boot control + status)
//       ◀─S_AXI_HP0──────────── axi4_to_axi3 ◀── ChipTop.axi4_mem_0
//       ◀─UART1 via EMIO──────▶ ChipTop.uart_0
//
// Three things are worth knowing before reading:
//
// ADDRESS FOLD. Chipyard's ExtMem sits at 0x8000_0000 (its default, kept so it does not
// collide with the bootrom/CLINT/PLIC/TACIT MMIO low in the map). The PS DDR window is
// 0x0010_0000-0x1FFF_FFFF. {4'd1, addr[27:0]} folds a 256 MB ExtMem into 0x1000_0000-
// 0x1FFF_FFFF -- the upper half of the board's 512 MB, above the low memory Linux uses.
// This is the ucb-bar/fpga-zynq pattern.
//
// NO PL UART PINS. The board's FT2232 UART is wired to PS_MIO14/15 and belongs to the ARM.
// Instead PS UART1 is routed to EMIO and cross-connected to Rocket's UART here, so the
// console appears as /dev/ttyPS1. See docs/UART.md.
//
// ROCKET IS HELD IN RESET AT POWER-UP. The PS must be able to load a program into DDR
// before the core runs, so reset is software-released through SOC_CTRL bit 0.

// SOC_MAGIC is what the PS reads at GP0 offset 0x08 to identify which bitstream is in
// the PL. The default is the single-core Rocket + TACIT value; tcl/build_rocket_smp.tcl
// overrides it to 0x5A5A0003 with `synth_design -generic`, because the dual-core design
// is otherwise indistinguishable over this interface.
//
// RGB_DUTY is the RGB LEDs' fixed brightness chopper, in 256ths. It is a parameter and
// not a constant only so that it can be swept with `synth_design -generic` without
// editing this file; the default is the value the board is built with. See the
// PYNQZ2_HAS_RGB block below for why a chopper exists at all. It sits INSIDE the ifdef so
// that the four builds without RGB LEDs keep a byte-identical module header as well as a
// byte-identical body -- see the note on `ifdef vs generate in the mic port block.
module pynqz2_rocket_top #(
  parameter [31:0] SOC_MAGIC = 32'h5A5A_0002
`ifdef PYNQZ2_HAS_RGB
  ,
  parameter [7:0]  RGB_DUTY  = 8'd32
`endif
) (
  output wire [3:0] leds
`ifdef PYNQZ2_HAS_MIC
  ,
  // The PDM microphone's two PL pins.  Present only when the SoC was elaborated with
  // chipyard.iobinders.WithPdmMicPunchthrough, because ChipTop only has the matching
  // ports in that case -- connecting them unconditionally would break the three configs
  // that do not have a microphone.  A preprocessor conditional rather than a generate
  // block on purpose: these lines vanish entirely for the other builds, so their RTL is
  // textually unchanged and u_soc keeps its hierarchy path (and therefore its
  // placement).  tcl/build_rocket.tcl defines PYNQZ2_HAS_MIC for the mic variant only.
  output wire mic_pdm_clk,   // -> F17
  input  wire mic_pdm_data   // <- G18
`endif
`ifdef PYNQZ2_HAS_RGB
  ,
  // The two tri-colour LEDs, LD4 and LD5.  Present only when the SoC was elaborated with
  // chipyard.config.WithGPIO + chipyard.iobinders.WithGPIOPunchthrough, for the same
  // reason as the microphone's pair above: ChipTop only has the matching ports in that
  // case.  Bit order is the VENDOR'S, not ours --
  //
  //     [0] L15  LD4 blue     [3] G14  LD5 blue
  //     [1] G17  LD4 green    [4] L14  LD5 green
  //     [2] N15  LD4 red      [5] M15  LD5 red
  //
  // -- from Digilent's Arty-Z7-20-Master.xdc (whose trailing comments carry the schematic
  // net names Sch=LED4_B .. Sch=LED5_R) and independently from Xilinx's PYNQ RGBLED class
  // (RGB_BLUE=1, RGB_GREEN=2, RGB_RED=4, three bits per LED, LD4 first) read against
  // PYNQ's own base.xdc.  src/pynqz2_rgb.xdc quotes both and is where the balls are
  // actually assigned; docs/RGB_LEDS.md section 1 has the reasoning.
  output wire [5:0] rgb_led
`endif
`ifdef PYNQZ2_CAM
  ,
  // The HM01B0 camera shield (riskybirdv3_pynq_camera rev 0.6) on the chipKIT header.  Present
  // only when the SoC was elaborated with ospi.WithOspiCaptureDma + WithOspiPunchthrough +
  // chipyard.config.WithI2C (PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig), because only
  // then does ChipTop have ospi_sensor_* and i2c_0_*.  Balls, IOSTANDARD and timing are in
  // src/pynqz2_cam.xdc; docs/CAMERA_Z1.md is the write-up.
  input  wire [7:0] cam_d,      // T14 U12 V13 V15 T15 R16 U17 V17  (IO0,1,3..8; 200 ohm on the Z1)
  input  wire       cam_pclk,   // U10  A5, IO_L12N_T1_MRCC_13
  input  wire       cam_fvld,   // W11  A2
  input  wire       cam_lvld,   // V11  A3
  input  wire       cam_int,    // T5   A4
  output wire       cam_mclk,   // V18  IO9
  output wire       cam_trig,   // T16  IO10
  inout  wire       cam_scl,    // P16  SCL (2.2 k pull-up on the Z1)
  inout  wire       cam_sda     // P15  SDA (2.2 k pull-up on the Z1)
`endif
`ifdef PYNQZ2_HAS_I2C
  ,
  // THE I2C BUS ON ITS OWN, WITHOUT THE CAMERA.  Present only when the SoC was elaborated
  // with chipyard.config.WithI2C, because only then does ChipTop have i2c_0_* -- the same
  // rule as the microphone's pair and the RGB LEDs' six above, and a preprocessor
  // conditional for the same reason: these lines vanish entirely for every other build, so
  // their RTL is textually unchanged and u_soc keeps its hierarchy path and its placement.
  //
  // THE SAME TWO BALLS THE CAMERA SHIELD USES (P15/P16, the Z1's chipKIT SDA/SCL, with the
  // board's 2.2 k pull-ups R49/R50), because they are the only two on this board that have
  // pull-ups fitted -- docs/OLED_SSD1306.md section 1.  PYNQZ2_HAS_I2C and PYNQZ2_CAM are
  // therefore MUTUALLY EXCLUSIVE: both drive ChipTop's i2c_0_* and both claim P15/P16.
  // tcl/build_rocket.tcl refuses the combination rather than letting the last `ifdef win.
  inout  wire       i2c_scl,    // P16  SCL
  inout  wire       i2c_sda     // P15  SDA
`endif
`ifdef PYNQZ2_HAS_BTN
  ,
  // THE FOUR PUSHBUTTONS, BTN0..BTN3, read through the sifive GPIO controller's pins 6..9.
  // Present only when the SoC was elaborated with the GPIO widened past the six pins the
  // RGB LEDs consume (chipyard.WithGPIOWidth(10) in PynqZ2Configs.scala), because only then
  // does ChipTop have gpio_0_pins_6..9_*.  Same `ifdef rule and same reason as above.
  //
  //     btn[0] D19   btn[1] D20   btn[2] L20   btn[3] L19
  //
  // INPUT ONLY.  These balls are driven by the board's buttons; nothing here drives them,
  // so the controller's output_value / output_en for pins 6..9 reach no pad.  Balls and
  // IOSTANDARD are in src/pynqz2_btn.xdc, which is where the source for the mapping is.
  input  wire [3:0] btn
`endif
`ifdef PYNQZ2_HAS_OSPI
  ,
  // THE CAMERA'S VIDEO PINS, WITHOUT ITS I2C -- the fourteen ports of PYNQZ2_CAM minus
  // cam_scl/cam_sda.  Present only when the SoC was elaborated with
  // ospi.WithOspiCaptureDma + chipyard.iobinders.WithOspiPunchthrough, because only then
  // does ChipTop have ospi_sensor_*.  Same `ifdef rule and same reason as every block above.
  //
  // WHY THIS EXISTS SEPARATELY FROM PYNQZ2_CAM, which has the same seven signals.  PYNQZ2_CAM
  // also brings ChipTop's i2c_0_* out on its OWN two ports (cam_scl/cam_sda, P16/P15) because
  // the camera variants have no other I2C.  This variant has PYNQZ2_HAS_I2C, which does exactly
  // that on i2c_scl/i2c_sda -- the SAME TLI2C on the SAME two balls, since the shield's sensor
  // (behind a PCA9306) and its J4 OLED row both hang on PL_SDA/PL_SCL.  One controller, one
  // pair of pads, one owner of the i2c_0_* ports.  PYNQZ2_HAS_OSPI therefore carries the video
  // pins alone; tcl/build_rocket.tcl refuses has_ospi together with has_cam, and requires
  // has_i2c with it, rather than letting a second driver of i2c_0_* through.
  //
  // Balls, IOSTANDARD and the PCLK timing are in src/pynqz2_ospi.xdc, which is
  // src/pynqz2_cam.xdc minus its two I2C lines; docs/CAMERA_Z1.md is the write-up.
  input  wire [7:0] cam_d,      // T14 U12 V13 V15 T15 R16 U17 V17  (IO0,1,3..8; 200 ohm on the Z1)
  input  wire       cam_pclk,   // U10  A5, IO_L12N_T1_MRCC_13
  input  wire       cam_fvld,   // W11  A2
  input  wire       cam_lvld,   // V11  A3
  input  wire       cam_int,    // T5   A4
  output wire       cam_mclk,   // V18  IO9
  output wire       cam_trig    // T16  IO10
`endif
);

  wire fclk, ps_rstn;
`ifdef PYNQZ2_HAS_MEMCLK
  // LEVER 2: the memory path on its own clock.
  //
  // The whole PL runs at 34.4828 MHz because of the P-extension's critical path
  // (PEXT_BITSTREAM.md).  The AXI4-to-AXI3 shim, the mbus crossbar and S_AXI_HP0 inherit
  // that ceiling for no reason of their own, and MEMORY_BANDWIDTH.md section 2 measured
  // what it costs: the L2 path saturates its 64-bit link at EXACTLY 8.00 B/cycle, so its
  // ceiling IS the clock.
  //
  // ChipTop exposes clock_mem as a second input because PynqZ2Configs.scala splits mbus
  // into its own clock group; the TileLink side of the boundary is a real
  // AsynchronousCrossing, so this is a clock-domain crossing and not a wish.
  wire fclk_mem;
`endif
`ifdef PYNQZ2_WLANE
  // ---------------------------------------------------------------------------------
  // THE WEIGHT LANE'S CLOCK (MEMORY_BANDWIDTH.md section 9.9, design (ii')).  FCLK1 again, but for
  // the accelerator's private weight channel and NOT for the memory bus: the L2's channel, every
  // hart's path and S_AXI_HP0 stay on FCLK0, which is the whole point -- the harts pay nothing.
  //
  // ChipTop exposes clock_wlane because chipyard.wlane (patches/0110) puts the lane in its own clock
  // group.  The crossing into the engine is inside the SoC (mbxr_wx, two ASYNC_REG flops each way);
  // on this side the lane, its TileLink-to-AXI bridge, mbxr_wquiet and the shim below are all on
  // this one clock, so nothing here crosses.
  //
  // PYNQZ2_WLANE and PYNQZ2_HAS_MEMCLK would both drive FCLK1 here, and PYNQZ2_WLANE,
  // PYNQZ2_CH1_HP2 and PYNQZ2_NMEM4 would all claim S_AXI_HP2; tcl/build_rocket.tcl refuses those
  // combinations rather than letting the last `ifdef` win.
  wire fclk_wlane;
`endif

  // ---- M_AXI_GP0 (AXI3, 32-bit) ----
  wire [11:0] gp0_awid, gp0_arid, gp0_bid, gp0_rid;
  wire [31:0] gp0_awaddr, gp0_araddr, gp0_wdata, gp0_rdata;
  wire [3:0]  gp0_awlen, gp0_arlen, gp0_wstrb;
  wire        gp0_awvalid, gp0_awready, gp0_wvalid, gp0_wready, gp0_wlast;
  wire        gp0_bvalid, gp0_bready, gp0_arvalid, gp0_arready;
  wire        gp0_rvalid, gp0_rready, gp0_rlast;
  wire [1:0]  gp0_bresp, gp0_rresp;

  // ---- ChipTop AXI4 memory port (4-bit ID, 64-bit data) ----
  wire        m_awvalid, m_awready, m_wvalid, m_wready, m_wlast;
  wire        m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready, m_rlast;
  wire [3:0]  m_awid, m_arid, m_bid, m_rid;
  wire [31:0] m_awaddr, m_araddr;
  wire [7:0]  m_awlen, m_arlen;
  wire [2:0]  m_awsize, m_arsize;
  wire [1:0]  m_awburst, m_arburst, m_bresp, m_rresp;
  wire        m_awlock, m_arlock;
  wire [3:0]  m_awcache, m_arcache, m_awqos, m_arqos;
  wire [2:0]  m_awprot, m_arprot;
  wire [63:0] m_wdata, m_rdata;
  wire [7:0]  m_wstrb;

  // ---- AXI3 side, into S_AXI_HP0 (6-bit ID) ----
  wire [5:0]  h_awid, h_arid, h_wid;
  wire [31:0] h_awaddr_raw, h_araddr_raw;
  wire [3:0]  h_awlen, h_arlen, h_awcache, h_arcache, h_awqos, h_arqos;
  wire [2:0]  h_awsize, h_arsize, h_awprot, h_arprot;
  wire [1:0]  h_awburst, h_arburst, h_awlock, h_arlock, h_bresp, h_rresp;
  wire        h_awvalid, h_awready, h_wvalid, h_wready, h_wlast;
  wire        h_bvalid, h_bready, h_arvalid, h_arready, h_rvalid, h_rready, h_rlast;
  wire [63:0] h_wdata, h_rdata;
  wire [7:0]  h_wstrb;
  wire [5:0]  h_bid, h_rid;
  wire        err_burst_too_long;
`ifdef PYNQZ2_WLANE
  // ---- ChipTop AXI4 weight-lane port (4-bit ID, 64-bit data) ----
  // READ-ONLY BY CONSTRUCTION: the lane's AXI4 slave advertises Get only (WLanePort.scala), so
  // AWVALID and WVALID never assert.  The write channels are wired through the shim all the same,
  // so the port is an ordinary AXI4 master and scripts/check_mem_contract.py sizes it exactly as it
  // sizes axi4_mem_*.  The simulation gate checks the same thing at the pins: every AR is an 8-beat
  // 64-byte INCR burst inside the weight window, and AWVALID/WVALID never rise.
  wire        w_awvalid, w_awready, w_wvalid, w_wready, w_wlast;
  wire        w_bvalid, w_bready, w_arvalid, w_arready, w_rvalid, w_rready, w_rlast;
  wire [3:0]  w_awid, w_arid, w_bid, w_rid;
  wire [31:0] w_awaddr, w_araddr;
  wire [7:0]  w_awlen, w_arlen;
  wire [2:0]  w_awsize, w_arsize;
  wire [1:0]  w_awburst, w_arburst, w_bresp, w_rresp;
  wire        w_awlock, w_arlock;
  wire [3:0]  w_awcache, w_arcache, w_awqos, w_arqos;
  wire [2:0]  w_awprot, w_arprot;
  wire [63:0] w_wdata, w_rdata;
  wire [7:0]  w_wstrb;

  // ---- AXI3 side, into S_AXI_HP2 (6-bit ID) ----
  // HP2 is on DDR controller port 2; HP0, which carries the L2's channel, is on port 3.  The two
  // therefore do not share a controller port, which is why the lane costs the harts no DRAM
  // bandwidth beyond the DDR array itself (MEMORY_BANDWIDTH.md section 8.3, S10a).
  wire [5:0]  hw_awid, hw_arid, hw_wid;
  wire [31:0] hw_awaddr_raw, hw_araddr_raw;
  wire [3:0]  hw_awlen, hw_arlen, hw_awcache, hw_arcache, hw_awqos, hw_arqos;
  wire [2:0]  hw_awsize, hw_arsize, hw_awprot, hw_arprot;
  wire [1:0]  hw_awburst, hw_arburst, hw_awlock, hw_arlock, hw_bresp, hw_rresp;
  wire        hw_awvalid, hw_awready, hw_wvalid, hw_wready, hw_wlast;
  wire        hw_bvalid, hw_bready, hw_arvalid, hw_arready, hw_rvalid, hw_rready, hw_rlast;
  wire [63:0] hw_wdata, hw_rdata;
  wire [7:0]  hw_wstrb;
  wire [5:0]  hw_bid, hw_rid;
  wire        err_burst_too_long_w;
`endif
`ifdef PYNQZ2_NMEM2
  // ---------------------------------------------------------------------------------
  // LEVER 3: the SECOND memory channel, into S_AXI_HP1.
  //
  // WithNMemoryChannels(2) makes ChipTop emit axi4_mem_1_* as an INDEPENDENT AXI4
  // master (Ports.scala's Seq.tabulate over memAXI4Node), so this is a second copy of
  // the whole path -- wires, shim, address fold and HP port -- and not a wider one.
  // HP ports are PS7-internal: no package pins and no XDC change.
  //
  // It is a textual duplicate on purpose: a `generate` loop cannot index ChipTop's port
  // names, and the builds without it must keep byte-identical RTL so `u_soc` keeps its
  // hierarchy path and its placement (see this file's header).
  //
  // PYNQZ2_CH1_HP2 puts channel 1 on S_AXI_HP2 instead of HP1.  The Zynq DDR controller
  // has four AXI ports: CPUs/ACP on port 0, the central interconnect on port 1, HP2+HP3 on
  // port 2 and HP0+HP1 on port 3 (AMD, SPA-UG "Evaluating DDR controller settings").  HP0
  // and HP1 therefore share one controller port; HP0 and HP2 do not.
  //
  // It STACKS with PYNQZ2_HAS_MEMCLK: u_bridge1 and S_AXI_HP1_ACLK take fclk_mem under it
  // exactly as u_bridge and HP0 do, so lever 2 + lever 3 is two defines, not a variant.
  //
  // WithNMemoryChannels(2) does NOT split ExtMem in halves: channel c owns the 64-byte
  // blocks whose bit 6 is c (Ports.scala: AddressSet(c * blockBytes, ~((n-1) * blockBytes))
  // with the mbus blockBytes = CacheBlockBytes = 64; the elaborated TLXbar_mbus decodes
  // address[6]).  Both channels therefore get the SAME address fold below -- they are two
  // views of one DDR window, interleaved block by block, and a sequential read alternates
  // between them on every refill.
  // ---- ChipTop AXI4 memory port 1 (4-bit ID, 64-bit data) ----
  wire        m1_awvalid, m1_awready, m1_wvalid, m1_wready, m1_wlast;
  wire        m1_bvalid, m1_bready, m1_arvalid, m1_arready, m1_rvalid, m1_rready, m1_rlast;
  wire [3:0]  m1_awid, m1_arid, m1_bid, m1_rid;
  wire [31:0] m1_awaddr, m1_araddr;
  wire [7:0]  m1_awlen, m1_arlen;
  wire [2:0]  m1_awsize, m1_arsize;
  wire [1:0]  m1_awburst, m1_arburst, m1_bresp, m1_rresp;
  wire        m1_awlock, m1_arlock;
  wire [3:0]  m1_awcache, m1_arcache, m1_awqos, m1_arqos;
  wire [2:0]  m1_awprot, m1_arprot;
  wire [63:0] m1_wdata, m1_rdata;
  wire [7:0]  m1_wstrb;

  // ---- AXI3 side, into S_AXI_HP1 (6-bit ID) ----
  wire [5:0]  h1_awid, h1_arid, h1_wid;
  wire [31:0] h1_awaddr_raw, h1_araddr_raw;
  wire [3:0]  h1_awlen, h1_arlen, h1_awcache, h1_arcache, h1_awqos, h1_arqos;
  wire [2:0]  h1_awsize, h1_arsize, h1_awprot, h1_arprot;
  wire [1:0]  h1_awburst, h1_arburst, h1_awlock, h1_arlock, h1_bresp, h1_rresp;
  wire        h1_awvalid, h1_awready, h1_wvalid, h1_wready, h1_wlast;
  wire        h1_bvalid, h1_bready, h1_arvalid, h1_arready, h1_rvalid, h1_rready, h1_rlast;
  wire [63:0] h1_wdata, h1_rdata;
  wire [7:0]  h1_wstrb;
  wire [5:0]  h1_bid, h1_rid;
  wire        err_burst_too_long1;
`endif
`ifdef PYNQZ2_NMEM4
  // ---------------------------------------------------------------------------------
  // LEVER 3, FOUR channels (PYNQZ2_NMEM4, requires PYNQZ2_NMEM2): axi4_mem_2 and
  // axi4_mem_3 into S_AXI_HP2 and S_AXI_HP3, so all four HP ports are mastered.
  // WithNMemoryChannels(4) splits on address[7:6], so channel c owns the 64-byte
  // blocks whose bits 7:6 equal c.  Same shim, same fold, same clock rule as channel 1.
  wire        m2_awvalid, m2_awready, m2_wvalid, m2_wready, m2_wlast;
  wire        m2_bvalid, m2_bready, m2_arvalid, m2_arready, m2_rvalid, m2_rready, m2_rlast;
  wire [3:0]  m2_awid, m2_arid, m2_bid, m2_rid;
  wire [31:0] m2_awaddr, m2_araddr;
  wire [7:0]  m2_awlen, m2_arlen;
  wire [2:0]  m2_awsize, m2_arsize;
  wire [1:0]  m2_awburst, m2_arburst, m2_bresp, m2_rresp;
  wire        m2_awlock, m2_arlock;
  wire [3:0]  m2_awcache, m2_arcache, m2_awqos, m2_arqos;
  wire [2:0]  m2_awprot, m2_arprot;
  wire [63:0] m2_wdata, m2_rdata;
  wire [7:0]  m2_wstrb;

  // ---- AXI3 side, into S_AXI_HP1 (6-bit ID) ----
  wire [5:0]  h2_awid, h2_arid, h2_wid;
  wire [31:0] h2_awaddr_raw, h2_araddr_raw;
  wire [3:0]  h2_awlen, h2_arlen, h2_awcache, h2_arcache, h2_awqos, h2_arqos;
  wire [2:0]  h2_awsize, h2_arsize, h2_awprot, h2_arprot;
  wire [1:0]  h2_awburst, h2_arburst, h2_awlock, h2_arlock, h2_bresp, h2_rresp;
  wire        h2_awvalid, h2_awready, h2_wvalid, h2_wready, h2_wlast;
  wire        h2_bvalid, h2_bready, h2_arvalid, h2_arready, h2_rvalid, h2_rready, h2_rlast;
  wire [63:0] h2_wdata, h2_rdata;
  wire [7:0]  h2_wstrb;
  wire [5:0]  h2_bid, h2_rid;
  wire        err_burst_too_long2;
  wire        m3_awvalid, m3_awready, m3_wvalid, m3_wready, m3_wlast;
  wire        m3_bvalid, m3_bready, m3_arvalid, m3_arready, m3_rvalid, m3_rready, m3_rlast;
  wire [3:0]  m3_awid, m3_arid, m3_bid, m3_rid;
  wire [31:0] m3_awaddr, m3_araddr;
  wire [7:0]  m3_awlen, m3_arlen;
  wire [2:0]  m3_awsize, m3_arsize;
  wire [1:0]  m3_awburst, m3_arburst, m3_bresp, m3_rresp;
  wire        m3_awlock, m3_arlock;
  wire [3:0]  m3_awcache, m3_arcache, m3_awqos, m3_arqos;
  wire [2:0]  m3_awprot, m3_arprot;
  wire [63:0] m3_wdata, m3_rdata;
  wire [7:0]  m3_wstrb;

  // ---- AXI3 side, into S_AXI_HP1 (6-bit ID) ----
  wire [5:0]  h3_awid, h3_arid, h3_wid;
  wire [31:0] h3_awaddr_raw, h3_araddr_raw;
  wire [3:0]  h3_awlen, h3_arlen, h3_awcache, h3_arcache, h3_awqos, h3_arqos;
  wire [2:0]  h3_awsize, h3_arsize, h3_awprot, h3_arprot;
  wire [1:0]  h3_awburst, h3_arburst, h3_awlock, h3_arlock, h3_bresp, h3_rresp;
  wire        h3_awvalid, h3_awready, h3_wvalid, h3_wready, h3_wlast;
  wire        h3_bvalid, h3_bready, h3_arvalid, h3_arready, h3_rvalid, h3_rready, h3_rlast;
  wire [63:0] h3_wdata, h3_rdata;
  wire [7:0]  h3_wstrb;
  wire [5:0]  h3_bid, h3_rid;
  wire        err_burst_too_long3;
`endif

  // ---- UART crossover nets (declared before use) ----
  wire        uart_soc_tx, uart_soc_rx;
  wire        ps_uart1_tx, ps_uart1_rx;

  // ---- control ----
  wire        soc_resetn, custom_boot;
`ifdef PYNQZ2_HAS_MEMCLK
  // soc_resetn is asserted asynchronously from the fclk domain and must be DE-asserted
  // synchronously in the memory domain.  Two flops, ASYNC_REG so the placer keeps them
  // adjacent.  It sits here rather than beside the `fclk_mem` declaration because
  // soc_resetn is declared on the line above -- a forward reference would resolve, and
  // would be the kind of thing that resolves differently in another tool.
  (* ASYNC_REG = "TRUE" *) reg [1:0] memrst_sync;
  always @(posedge fclk_mem or negedge soc_resetn) begin
    if (!soc_resetn) begin
      memrst_sync <= 2'b00;
    end else begin
      memrst_sync <= {memrst_sync[0], 1'b1};
    end
  end
  wire mem_resetn = memrst_sync[1];
`endif
`ifdef PYNQZ2_WLANE
  // The same two flops for the weight lane's clock: soc_resetn is asserted asynchronously in the
  // fclk domain and de-asserted synchronously here.  Inside ChipTop the lane's own WLaneResetHold
  // extends this reset further -- until mbxr_wquiet says the lane's AXI pins are quiet -- so that a
  // short reset cannot release the lane while bursts are still due (MEMORY_BANDWIDTH.md 9.9).
  (* ASYNC_REG = "TRUE" *) reg [1:0] wlrst_sync;
  always @(posedge fclk_wlane or negedge soc_resetn) begin
    if (!soc_resetn) begin
      wlrst_sync <= 2'b00;
    end else begin
      wlrst_sync <= {wlrst_sync[0], 1'b1};
    end
  end
  wire wlane_resetn = wlrst_sync[1];
`endif
`ifdef PYNQZ2_HAS_TILECLK
  // custom_boot is a level from soc_ctrl_regs (fclk) into CustomBootPin, which now lives in
  // the uncore on FCLK1.  The PS holds it for tens of milliseconds, so two flops cost
  // nothing and make it a synchronised crossing rather than one report_cdc has to excuse.
  (* ASYNC_REG = "TRUE" *) reg [1:0] cboot_sync;
  always @(posedge fclk_mem) cboot_sync <= {cboot_sync[0], custom_boot};
  wire custom_boot_uncore = cboot_sync[1];
`endif
  wire [31:0] status;

  soc_ctrl_regs #(.ID_W(12), .MAGIC(SOC_MAGIC)) u_ctrl (
    .clk(fclk), .rstn(ps_rstn),
    .s_awid(gp0_awid), .s_awaddr(gp0_awaddr), .s_awlen({4'd0, gp0_awlen}),
    .s_awvalid(gp0_awvalid), .s_awready(gp0_awready),
    .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(gp0_wlast),
    .s_wvalid(gp0_wvalid), .s_wready(gp0_wready),
    .s_bid(gp0_bid), .s_bresp(gp0_bresp), .s_bvalid(gp0_bvalid), .s_bready(gp0_bready),
    .s_arid(gp0_arid), .s_araddr(gp0_araddr), .s_arlen({4'd0, gp0_arlen}),
    .s_arvalid(gp0_arvalid), .s_arready(gp0_arready),
    .s_rdata(gp0_rdata), .s_rresp(gp0_rresp), .s_rid(gp0_rid), .s_rlast(gp0_rlast),
    .s_rvalid(gp0_rvalid), .s_rready(gp0_rready),
    .soc_resetn(soc_resetn), .custom_boot(custom_boot),
    .err_burst_too_long(err_burst_too_long), .status(status)
  );

`ifdef PYNQZ2_HAS_RGB
  // ---- RGB LEDs: the sifive GPIO controller's pad-facing signals ----
  //
  // chipyard.iobinders.WithGPIOPunchthrough brings sifive's EnhancedPin bundle straight
  // out of ChipTop -- ten signals per pin, no IOCell, no IOBUF -- and leaves the pad
  // behaviour to whoever instantiates it. That is here.
  // Declared here, driven below: an undeclared identifier in a port connection becomes an
  // implicit ONE-BIT net, which would silently truncate all six of these to bit 0.
  wire [5:0] rgb_oval, rgb_oe, rgb_ie, rgb_pue;
  wire [5:0] rgb_ival, rgb_drive;
`endif
`ifdef PYNQZ2_CAM
  // ---- the camera shield's pad logic ----
  wire cam_pclk_ibuf, cam_pclk_bufg;       // PCLK into the capture core's clock domain
  wire cam_mclk_soc, cam_trig_soc;         // from ChipTop
  wire i2c_scl_in, i2c_scl_out, i2c_scl_oe;
  wire i2c_sda_in, i2c_sda_out, i2c_sda_oe;

  // PCLK: an explicit IBUF and BUFG so the constraint in src/pynqz2_cam.xdc names a real net.
  // U10 is the N side of its clock-capable pair, which has no dedicated route to a BUFG
  // (CLOCK_DEDICATED_ROUTE FALSE there).
  IBUF u_cam_pclk_ibuf (.I(cam_pclk), .O(cam_pclk_ibuf));
  BUFG u_cam_pclk_bufg (.I(cam_pclk_ibuf), .O(cam_pclk_bufg));

  // MCLK: ChipTop's ospi_sensor_mclk is a toggle flop on FCLK0 (MCLK = FCLK0 / (2*(mclkDiv+1)),
  // HM01B0Capture).  Re-launching it from an ODDR with D1 = D2 puts the last flop in the IOB, so
  // the sensor's clock edge is set by FCLK0 and one OLOGIC rather than by a fabric route to V18.
  // SAME_EDGE: both inputs are sampled on the rising edge, a full-cycle path from the toggle flop,
  // and the output follows one FCLK0 cycle later with the flop's 50 % duty cycle.
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_cam_mclk_oddr (
    .Q(cam_mclk), .C(fclk), .CE(1'b1), .D1(cam_mclk_soc), .D2(cam_mclk_soc), .R(1'b0), .S(1'b0));
  assign cam_trig = cam_trig_soc;

  // I2C: open drain, the Arty-200T binder's shape exactly.  WithArty200TI2C does
  // UIntToAnalog(port.io.scl.out, pin, port.io.scl.oe), i.e. `assign pin = oe ? out : 1'bz`, and
  // port.io.scl.in := AnalogToUInt(pin), i.e. `in = pin`.  An IOBUF drives IO = I when T = 0 and
  // floats it when T = 1, and O = IO, so I = out, T = ~oe, O -> in is the same function.  The
  // TLI2C holds *_out at 0 and signals the drive on *_oe; the pull-ups make the high.
  IOBUF u_cam_scl (.I(i2c_scl_out), .T(~i2c_scl_oe), .O(i2c_scl_in), .IO(cam_scl));
  IOBUF u_cam_sda (.I(i2c_sda_out), .T(~i2c_sda_oe), .O(i2c_sda_in), .IO(cam_sda));
`endif
`ifdef PYNQZ2_HAS_I2C
  // ---- the I2C bus's pad logic, without the camera ----
  //
  // Byte for byte the PYNQZ2_CAM block's I2C wiring above, on its own two ports: open
  // drain, the Arty-200T binder's shape (WithArty200TI2C does
  // `assign pin = oe ? out : 1'bz` and `in = pin`).  An IOBUF drives IO = I when T = 0 and
  // floats it when T = 1, and O = IO, so I = out, T = ~oe, O -> in is the same function.
  // The TLI2C holds *_out at 0 and signals the drive on *_oe; the board's pull-ups make
  // the high.  The failure to look for here is `.T(oe)`, which would hold BOTH lines low
  // while idle and look exactly like a dead bus.
  wire i2c_scl_i, i2c_scl_o, i2c_scl_t;
  wire i2c_sda_i, i2c_sda_o, i2c_sda_t;
  IOBUF u_i2c_scl (.I(i2c_scl_o), .T(~i2c_scl_t), .O(i2c_scl_i), .IO(i2c_scl));
  IOBUF u_i2c_sda (.I(i2c_sda_o), .T(~i2c_sda_t), .O(i2c_sda_i), .IO(i2c_sda));
`endif
`ifdef PYNQZ2_HAS_BTN
  // ---- the pushbuttons' pad behaviour ----
  //
  // The GPIO controller's pins 6..9, input only.  btn_ie is the controller's input_en for
  // those four pins and the gating below is GenericDigitalGPIOCell's, verbatim --
  //     assign i = ie ? pad : 1'b0;
  // (chipyard iocell/IOCell.scala) -- which is what WithGPIOCells would have put on these
  // pads had this build used IO cells rather than WithGPIOPunchthrough.  The consequence
  // for software, stated here because it looks like broken hardware when it bites: a guest
  // that has not set input_en for pins 6..9 reads every button as 0 forever.  Zephyr's
  // gpio_sifive.c sets input_en for GPIO_INPUT, so a correctly configured guest is fine.
  //
  // TWO FLOPS WITH ASYNC_REG, AND WHY -- because the first draft of this block said the
  // opposite and the routed design refuted it.
  //
  // rocket-chip-blocks' GPIO does put a 3-deep SynchronizerShiftReg on i.ival before valueReg
  // (devices/gpio/GPIO.scala:86), so on paper a synchroniser here is redundant.  MEASURED in the
  // routed 0x5A5A0037 design that it is not:  report_cdc -details reported, for all four buttons,
  //     CDC-13  Critical  1-bit CDC path on a non-FD primitive   Depth 0
  //     btn[0] -> u_soc/system/gpioClockDomainWrapper/gpio_0/inSyncReg_inSyncReg/
  //               output_chain_6/sync_1_reg_srl2/D
  // Vivado had inferred the front of that chain as an SRL.  An SRL's storage is not a
  // metastability-hardened flop and cannot carry ASYNC_REG, so the reported synchroniser DEPTH is
  // 0 -- the asynchronous pad reaches a non-FD primitive directly.  On a part placed at 99.98 %
  // slice occupancy the tool takes every SRL it can get, which is exactly when you would least
  // like to be relying on a library's synchroniser surviving inference.
  //
  // So the synchroniser is here instead, in two fabric flops this file owns and marks, the same
  // way sawmem_sync below does it for the memory domain's handshake.  What the controller's own
  // chain is inferred as then stops mattering: it is fed an already-synchronised signal.
  //
  // The gating with the controller's input_en is AFTER the synchroniser, so it is an ordinary
  // synchronous AND and carries no crossing of its own.
  //
  // STILL NO DEBOUNCE, on purpose.  A mechanical contact bounces for milliseconds -- 10^5 cycles
  // at 40 MHz -- and no number of flops fixes that; it is software's to do, as it is on every
  // other board with these four buttons.  src/pynqz2_btn.xdc false-paths the four inputs, because
  // there is no off-chip launch edge for the timing engine to budget against.
  //
  // fclk is the right clock here because this variant has neither PYNQZ2_HAS_TILECLK nor
  // PYNQZ2_HAS_MEMCLK, so the GPIO controller is on FCLK0 like everything else.  A future btn
  // variant that moved the pbus would have to move these two flops with it.
  (* ASYNC_REG = "TRUE" *) reg [3:0] btn_sync0 = 4'd0;
  (* ASYNC_REG = "TRUE" *) reg [3:0] btn_sync1 = 4'd0;
  always @(posedge fclk) begin
    btn_sync0 <= btn;
    btn_sync1 <= btn_sync0;
  end
  wire [3:0] btn_ie;
  wire [3:0] btn_ival = btn_sync1 & btn_ie;
`endif
`ifdef PYNQZ2_HAS_OSPI
  // ---- the camera shield's pad logic, WITHOUT its I2C ----
  //
  // Byte for byte the PYNQZ2_CAM block's video wiring above, with the two IOBUFs left out:
  // PYNQZ2_HAS_I2C owns i2c_0_* and the P15/P16 pads in this variant.  The instance names
  // u_cam_pclk_ibuf / u_cam_pclk_bufg / u_cam_mclk_oddr are PYNQZ2_CAM's, because
  // src/pynqz2_ospi.xdc names two of them (CLOCK_DEDICATED_ROUTE on the BUFG's input net, and
  // the generated clock on the ODDR's C pin) and it is a copy of src/pynqz2_cam.xdc.  The two
  // `ifdef regions are mutually exclusive, so the names never collide.
  wire cam_pclk_ibuf, cam_pclk_bufg;       // PCLK into the capture core's clock domain
  wire cam_mclk_soc, cam_trig_soc;         // from ChipTop

  // PCLK: an explicit IBUF and BUFG so the constraint in src/pynqz2_ospi.xdc names a real net.
  // U10 is the N side of its clock-capable pair, which has no dedicated route to a BUFG
  // (CLOCK_DEDICATED_ROUTE FALSE there).
  IBUF u_cam_pclk_ibuf (.I(cam_pclk), .O(cam_pclk_ibuf));
  BUFG u_cam_pclk_bufg (.I(cam_pclk_ibuf), .O(cam_pclk_bufg));

  // MCLK: ChipTop's ospi_sensor_mclk is a toggle flop on FCLK0 (MCLK = FCLK0 / (2*(mclkDiv+1)),
  // HM01B0Capture).  Re-launching it from an ODDR with D1 = D2 puts the last flop in the IOB, so
  // the sensor's clock edge is set by FCLK0 and one OLOGIC rather than by a fabric route to V18.
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_cam_mclk_oddr (
    .Q(cam_mclk), .C(fclk), .CE(1'b1), .D1(cam_mclk_soc), .D2(cam_mclk_soc), .R(1'b0), .S(1'b0));
  assign cam_trig = cam_trig_soc;
`endif

  // ---- the SoC ----
  ChipTop u_soc (
`ifdef PYNQZ2_HAS_MIC
    .mic_pdm_clk(mic_pdm_clk), .mic_pdm_data(mic_pdm_data),
`endif
`ifdef PYNQZ2_HAS_RGB
    // Sixty ports, written out one pin at a time rather than hidden behind a `define with
    // token pasting. The thing most likely to be wrong here is the bit order, and the only
    // defence against that is being able to read it -- so the colour is named on the line
    // that makes the connection. rgb_ival/rgb_pue feed the controller's input path; see
    // below for what that is and is not evidence of.
    .gpio_0_pins_0_o_oval(rgb_oval[0]), .gpio_0_pins_0_o_oe(rgb_oe[0]),   // L15 LD4 blue
    .gpio_0_pins_0_o_ie(rgb_ie[0]), .gpio_0_pins_0_o_pue(rgb_pue[0]),
    .gpio_0_pins_0_o_ds(), .gpio_0_pins_0_o_ps(), .gpio_0_pins_0_o_ds1(),
    .gpio_0_pins_0_o_poe(),
    .gpio_0_pins_0_i_ival(rgb_ival[0]), .gpio_0_pins_0_i_po(1'b0),

    .gpio_0_pins_1_o_oval(rgb_oval[1]), .gpio_0_pins_1_o_oe(rgb_oe[1]),   // G17 LD4 green
    .gpio_0_pins_1_o_ie(rgb_ie[1]), .gpio_0_pins_1_o_pue(rgb_pue[1]),
    .gpio_0_pins_1_o_ds(), .gpio_0_pins_1_o_ps(), .gpio_0_pins_1_o_ds1(),
    .gpio_0_pins_1_o_poe(),
    .gpio_0_pins_1_i_ival(rgb_ival[1]), .gpio_0_pins_1_i_po(1'b0),

    .gpio_0_pins_2_o_oval(rgb_oval[2]), .gpio_0_pins_2_o_oe(rgb_oe[2]),   // N15 LD4 red
    .gpio_0_pins_2_o_ie(rgb_ie[2]), .gpio_0_pins_2_o_pue(rgb_pue[2]),
    .gpio_0_pins_2_o_ds(), .gpio_0_pins_2_o_ps(), .gpio_0_pins_2_o_ds1(),
    .gpio_0_pins_2_o_poe(),
    .gpio_0_pins_2_i_ival(rgb_ival[2]), .gpio_0_pins_2_i_po(1'b0),

    .gpio_0_pins_3_o_oval(rgb_oval[3]), .gpio_0_pins_3_o_oe(rgb_oe[3]),   // G14 LD5 blue
    .gpio_0_pins_3_o_ie(rgb_ie[3]), .gpio_0_pins_3_o_pue(rgb_pue[3]),
    .gpio_0_pins_3_o_ds(), .gpio_0_pins_3_o_ps(), .gpio_0_pins_3_o_ds1(),
    .gpio_0_pins_3_o_poe(),
    .gpio_0_pins_3_i_ival(rgb_ival[3]), .gpio_0_pins_3_i_po(1'b0),

    .gpio_0_pins_4_o_oval(rgb_oval[4]), .gpio_0_pins_4_o_oe(rgb_oe[4]),   // L14 LD5 green
    .gpio_0_pins_4_o_ie(rgb_ie[4]), .gpio_0_pins_4_o_pue(rgb_pue[4]),
    .gpio_0_pins_4_o_ds(), .gpio_0_pins_4_o_ps(), .gpio_0_pins_4_o_ds1(),
    .gpio_0_pins_4_o_poe(),
    .gpio_0_pins_4_i_ival(rgb_ival[4]), .gpio_0_pins_4_i_po(1'b0),

    .gpio_0_pins_5_o_oval(rgb_oval[5]), .gpio_0_pins_5_o_oe(rgb_oe[5]),   // M15 LD5 red
    .gpio_0_pins_5_o_ie(rgb_ie[5]), .gpio_0_pins_5_o_pue(rgb_pue[5]),
    .gpio_0_pins_5_o_ds(), .gpio_0_pins_5_o_ps(), .gpio_0_pins_5_o_ds1(),
    .gpio_0_pins_5_o_poe(),
    .gpio_0_pins_5_i_ival(rgb_ival[5]), .gpio_0_pins_5_i_po(1'b0),
`endif
`ifdef PYNQZ2_CAM
    // The camera shield -- see the PYNQZ2_CAM pad block above.
    .i2c_0_scl_in(i2c_scl_in), .i2c_0_scl_out(i2c_scl_out), .i2c_0_scl_oe(i2c_scl_oe),
    .i2c_0_sda_in(i2c_sda_in), .i2c_0_sda_out(i2c_sda_out), .i2c_0_sda_oe(i2c_sda_oe),
    .ospi_sensor_pclk(cam_pclk_bufg), .ospi_sensor_fvld(cam_fvld), .ospi_sensor_lvld(cam_lvld),
    .ospi_sensor_d(cam_d), .ospi_sensor_intr(cam_int),
    .ospi_sensor_mclk(cam_mclk_soc), .ospi_sensor_trig(cam_trig_soc),
`endif
`ifdef PYNQZ2_HAS_I2C
    // The TLI2C, without the camera -- see the PYNQZ2_HAS_I2C pad block above.
    .i2c_0_scl_in(i2c_scl_i), .i2c_0_scl_out(i2c_scl_o), .i2c_0_scl_oe(i2c_scl_t),
    .i2c_0_sda_in(i2c_sda_i), .i2c_0_sda_out(i2c_sda_o), .i2c_0_sda_oe(i2c_sda_t),
`endif
`ifdef PYNQZ2_HAS_BTN
    // The GPIO controller's pins 6..9 -- BTN0..BTN3, input only.  Written out one pin at a
    // time for the same reason the six RGB pins above are: the thing most likely to be
    // wrong is the bit order, and the only defence against that is being able to read it.
    // o_oval / o_oe / o_pue are deliberately left unconnected: nothing in the PL drives
    // these four balls, so a guest that sets output_en on a button changes nothing at the
    // pad.  o_ie is the ONE output of the four that is used.
    .gpio_0_pins_6_o_oval(), .gpio_0_pins_6_o_oe(),                        // D19  BTN0
    .gpio_0_pins_6_o_ie(btn_ie[0]), .gpio_0_pins_6_o_pue(),
    .gpio_0_pins_6_o_ds(), .gpio_0_pins_6_o_ps(), .gpio_0_pins_6_o_ds1(),
    .gpio_0_pins_6_o_poe(),
    .gpio_0_pins_6_i_ival(btn_ival[0]), .gpio_0_pins_6_i_po(1'b0),

    .gpio_0_pins_7_o_oval(), .gpio_0_pins_7_o_oe(),                        // D20  BTN1
    .gpio_0_pins_7_o_ie(btn_ie[1]), .gpio_0_pins_7_o_pue(),
    .gpio_0_pins_7_o_ds(), .gpio_0_pins_7_o_ps(), .gpio_0_pins_7_o_ds1(),
    .gpio_0_pins_7_o_poe(),
    .gpio_0_pins_7_i_ival(btn_ival[1]), .gpio_0_pins_7_i_po(1'b0),

    .gpio_0_pins_8_o_oval(), .gpio_0_pins_8_o_oe(),                        // L20  BTN2
    .gpio_0_pins_8_o_ie(btn_ie[2]), .gpio_0_pins_8_o_pue(),
    .gpio_0_pins_8_o_ds(), .gpio_0_pins_8_o_ps(), .gpio_0_pins_8_o_ds1(),
    .gpio_0_pins_8_o_poe(),
    .gpio_0_pins_8_i_ival(btn_ival[2]), .gpio_0_pins_8_i_po(1'b0),

    .gpio_0_pins_9_o_oval(), .gpio_0_pins_9_o_oe(),                        // L19  BTN3
    .gpio_0_pins_9_o_ie(btn_ie[3]), .gpio_0_pins_9_o_pue(),
    .gpio_0_pins_9_o_ds(), .gpio_0_pins_9_o_ps(), .gpio_0_pins_9_o_ds1(),
    .gpio_0_pins_9_o_poe(),
    .gpio_0_pins_9_i_ival(btn_ival[3]), .gpio_0_pins_9_i_po(1'b0),
`endif
`ifdef PYNQZ2_HAS_OSPI
    // The camera's capture core -- see the PYNQZ2_HAS_OSPI pad block above.  The seven
    // ospi_sensor_* connections are PYNQZ2_CAM's, verbatim; i2c_0_* is PYNQZ2_HAS_I2C's.
    .ospi_sensor_pclk(cam_pclk_bufg), .ospi_sensor_fvld(cam_fvld), .ospi_sensor_lvld(cam_lvld),
    .ospi_sensor_d(cam_d), .ospi_sensor_intr(cam_int),
    .ospi_sensor_mclk(cam_mclk_soc), .ospi_sensor_trig(cam_trig_soc),
`endif
`ifdef PYNQZ2_HAS_TILECLK
    // THE L2 ON A FASTER CLOCK (MEMORY_BANDWIDTH.md section 6).  The inverse of lever 2's
    // split: the TILES keep FCLK0, because that is the clock the P-extension's critical
    // path sets, and EVERYTHING ELSE -- sbus, the L2, mbus, pbus, cbus, the bandwidth
    // instrument -- moves to FCLK1.  PynqZ2Configs.scala's WithTilesOnTheirOwnClock makes
    // each tile's crossing a rocket-chip AsynchronousCrossing, which is what creates
    // clock_tile; this is only where the two PS clocks land.  PYNQZ2_HAS_MEMCLK is set
    // alongside it, so fclk_mem, mem_resetn, the shim on FCLK1, S_AXI_HP0_ACLK and
    // pynqz2_memclk.xdc are all lever 2's, unchanged.
    .clock_uncore(fclk_mem),
    .clock_tile(fclk),
`else
    .clock_uncore(fclk),
`ifdef PYNQZ2_HAS_MEMCLK
    .clock_mem(fclk_mem),
`endif
`endif
    .reset_io(~soc_resetn),          // ChipTop takes active-high reset
    .clock_tap(),
`ifdef PYNQZ2_HAS_TILECLK
    .custom_boot(custom_boot_uncore),
`else
    .custom_boot(custom_boot),
`endif

    .uart_0_txd(uart_soc_tx), .uart_0_rxd(uart_soc_rx),

    // Debug JTAG unused: held in reset. TMS idles high per JTAG convention.
    .jtag_TCK(1'b0), .jtag_TMS(1'b1), .jtag_TDI(1'b0), .jtag_TDO(), .jtag_reset(1'b1),

    // serial-TL unused for now -- this is where a PS-hosted TSI bridge would attach
    // (docs/UART.md option D). Parked so the link never presents traffic.
    .serial_tl_0_clock_in(fclk),
    .serial_tl_0_in_valid(1'b0), .serial_tl_0_in_bits_phit(32'd0),
    .serial_tl_0_in_ready(),
    .serial_tl_0_out_ready(1'b1), .serial_tl_0_out_valid(), .serial_tl_0_out_bits_phit(),

    .axi4_mem_0_clock(),
    .axi4_mem_0_bits_aw_valid(m_awvalid), .axi4_mem_0_bits_aw_ready(m_awready),
    .axi4_mem_0_bits_aw_bits_id(m_awid), .axi4_mem_0_bits_aw_bits_addr(m_awaddr),
    .axi4_mem_0_bits_aw_bits_len(m_awlen), .axi4_mem_0_bits_aw_bits_size(m_awsize),
    .axi4_mem_0_bits_aw_bits_burst(m_awburst), .axi4_mem_0_bits_aw_bits_lock(m_awlock),
    .axi4_mem_0_bits_aw_bits_cache(m_awcache), .axi4_mem_0_bits_aw_bits_prot(m_awprot),
    .axi4_mem_0_bits_aw_bits_qos(m_awqos),
    .axi4_mem_0_bits_w_valid(m_wvalid), .axi4_mem_0_bits_w_ready(m_wready),
    .axi4_mem_0_bits_w_bits_data(m_wdata), .axi4_mem_0_bits_w_bits_strb(m_wstrb),
    .axi4_mem_0_bits_w_bits_last(m_wlast),
    .axi4_mem_0_bits_b_valid(m_bvalid), .axi4_mem_0_bits_b_ready(m_bready),
    .axi4_mem_0_bits_b_bits_id(m_bid), .axi4_mem_0_bits_b_bits_resp(m_bresp),
    .axi4_mem_0_bits_ar_valid(m_arvalid), .axi4_mem_0_bits_ar_ready(m_arready),
    .axi4_mem_0_bits_ar_bits_id(m_arid), .axi4_mem_0_bits_ar_bits_addr(m_araddr),
    .axi4_mem_0_bits_ar_bits_len(m_arlen), .axi4_mem_0_bits_ar_bits_size(m_arsize),
    .axi4_mem_0_bits_ar_bits_burst(m_arburst), .axi4_mem_0_bits_ar_bits_lock(m_arlock),
    .axi4_mem_0_bits_ar_bits_cache(m_arcache), .axi4_mem_0_bits_ar_bits_prot(m_arprot),
    .axi4_mem_0_bits_ar_bits_qos(m_arqos),
    .axi4_mem_0_bits_r_valid(m_rvalid), .axi4_mem_0_bits_r_ready(m_rready),
    .axi4_mem_0_bits_r_bits_id(m_rid), .axi4_mem_0_bits_r_bits_data(m_rdata),
    .axi4_mem_0_bits_r_bits_resp(m_rresp), .axi4_mem_0_bits_r_bits_last(m_rlast)
`ifdef PYNQZ2_NMEM2
    ,
  // LEVER 3, channel 1 -- see the PYNQZ2_NMEM2 wire block above.
    .axi4_mem_1_clock(),
    .axi4_mem_1_bits_aw_valid(m1_awvalid), .axi4_mem_1_bits_aw_ready(m1_awready),
    .axi4_mem_1_bits_aw_bits_id(m1_awid), .axi4_mem_1_bits_aw_bits_addr(m1_awaddr),
    .axi4_mem_1_bits_aw_bits_len(m1_awlen), .axi4_mem_1_bits_aw_bits_size(m1_awsize),
    .axi4_mem_1_bits_aw_bits_burst(m1_awburst), .axi4_mem_1_bits_aw_bits_lock(m1_awlock),
    .axi4_mem_1_bits_aw_bits_cache(m1_awcache), .axi4_mem_1_bits_aw_bits_prot(m1_awprot),
    .axi4_mem_1_bits_aw_bits_qos(m1_awqos),
    .axi4_mem_1_bits_w_valid(m1_wvalid), .axi4_mem_1_bits_w_ready(m1_wready),
    .axi4_mem_1_bits_w_bits_data(m1_wdata), .axi4_mem_1_bits_w_bits_strb(m1_wstrb),
    .axi4_mem_1_bits_w_bits_last(m1_wlast),
    .axi4_mem_1_bits_b_valid(m1_bvalid), .axi4_mem_1_bits_b_ready(m1_bready),
    .axi4_mem_1_bits_b_bits_id(m1_bid), .axi4_mem_1_bits_b_bits_resp(m1_bresp),
    .axi4_mem_1_bits_ar_valid(m1_arvalid), .axi4_mem_1_bits_ar_ready(m1_arready),
    .axi4_mem_1_bits_ar_bits_id(m1_arid), .axi4_mem_1_bits_ar_bits_addr(m1_araddr),
    .axi4_mem_1_bits_ar_bits_len(m1_arlen), .axi4_mem_1_bits_ar_bits_size(m1_arsize),
    .axi4_mem_1_bits_ar_bits_burst(m1_arburst), .axi4_mem_1_bits_ar_bits_lock(m1_arlock),
    .axi4_mem_1_bits_ar_bits_cache(m1_arcache), .axi4_mem_1_bits_ar_bits_prot(m1_arprot),
    .axi4_mem_1_bits_ar_bits_qos(m1_arqos),
    .axi4_mem_1_bits_r_valid(m1_rvalid), .axi4_mem_1_bits_r_ready(m1_rready),
    .axi4_mem_1_bits_r_bits_id(m1_rid), .axi4_mem_1_bits_r_bits_data(m1_rdata),
    .axi4_mem_1_bits_r_bits_resp(m1_rresp), .axi4_mem_1_bits_r_bits_last(m1_rlast)
`ifdef PYNQZ2_NMEM4
    ,
  // channels 2 and 3 -- see the PYNQZ2_NMEM4 wire block.
    .axi4_mem_2_clock(),
    .axi4_mem_2_bits_aw_valid(m2_awvalid), .axi4_mem_2_bits_aw_ready(m2_awready),
    .axi4_mem_2_bits_aw_bits_id(m2_awid), .axi4_mem_2_bits_aw_bits_addr(m2_awaddr),
    .axi4_mem_2_bits_aw_bits_len(m2_awlen), .axi4_mem_2_bits_aw_bits_size(m2_awsize),
    .axi4_mem_2_bits_aw_bits_burst(m2_awburst), .axi4_mem_2_bits_aw_bits_lock(m2_awlock),
    .axi4_mem_2_bits_aw_bits_cache(m2_awcache), .axi4_mem_2_bits_aw_bits_prot(m2_awprot),
    .axi4_mem_2_bits_aw_bits_qos(m2_awqos),
    .axi4_mem_2_bits_w_valid(m2_wvalid), .axi4_mem_2_bits_w_ready(m2_wready),
    .axi4_mem_2_bits_w_bits_data(m2_wdata), .axi4_mem_2_bits_w_bits_strb(m2_wstrb),
    .axi4_mem_2_bits_w_bits_last(m2_wlast),
    .axi4_mem_2_bits_b_valid(m2_bvalid), .axi4_mem_2_bits_b_ready(m2_bready),
    .axi4_mem_2_bits_b_bits_id(m2_bid), .axi4_mem_2_bits_b_bits_resp(m2_bresp),
    .axi4_mem_2_bits_ar_valid(m2_arvalid), .axi4_mem_2_bits_ar_ready(m2_arready),
    .axi4_mem_2_bits_ar_bits_id(m2_arid), .axi4_mem_2_bits_ar_bits_addr(m2_araddr),
    .axi4_mem_2_bits_ar_bits_len(m2_arlen), .axi4_mem_2_bits_ar_bits_size(m2_arsize),
    .axi4_mem_2_bits_ar_bits_burst(m2_arburst), .axi4_mem_2_bits_ar_bits_lock(m2_arlock),
    .axi4_mem_2_bits_ar_bits_cache(m2_arcache), .axi4_mem_2_bits_ar_bits_prot(m2_arprot),
    .axi4_mem_2_bits_ar_bits_qos(m2_arqos),
    .axi4_mem_2_bits_r_valid(m2_rvalid), .axi4_mem_2_bits_r_ready(m2_rready),
    .axi4_mem_2_bits_r_bits_id(m2_rid), .axi4_mem_2_bits_r_bits_data(m2_rdata),
    .axi4_mem_2_bits_r_bits_resp(m2_rresp), .axi4_mem_2_bits_r_bits_last(m2_rlast)
    ,
    .axi4_mem_3_clock(),
    .axi4_mem_3_bits_aw_valid(m3_awvalid), .axi4_mem_3_bits_aw_ready(m3_awready),
    .axi4_mem_3_bits_aw_bits_id(m3_awid), .axi4_mem_3_bits_aw_bits_addr(m3_awaddr),
    .axi4_mem_3_bits_aw_bits_len(m3_awlen), .axi4_mem_3_bits_aw_bits_size(m3_awsize),
    .axi4_mem_3_bits_aw_bits_burst(m3_awburst), .axi4_mem_3_bits_aw_bits_lock(m3_awlock),
    .axi4_mem_3_bits_aw_bits_cache(m3_awcache), .axi4_mem_3_bits_aw_bits_prot(m3_awprot),
    .axi4_mem_3_bits_aw_bits_qos(m3_awqos),
    .axi4_mem_3_bits_w_valid(m3_wvalid), .axi4_mem_3_bits_w_ready(m3_wready),
    .axi4_mem_3_bits_w_bits_data(m3_wdata), .axi4_mem_3_bits_w_bits_strb(m3_wstrb),
    .axi4_mem_3_bits_w_bits_last(m3_wlast),
    .axi4_mem_3_bits_b_valid(m3_bvalid), .axi4_mem_3_bits_b_ready(m3_bready),
    .axi4_mem_3_bits_b_bits_id(m3_bid), .axi4_mem_3_bits_b_bits_resp(m3_bresp),
    .axi4_mem_3_bits_ar_valid(m3_arvalid), .axi4_mem_3_bits_ar_ready(m3_arready),
    .axi4_mem_3_bits_ar_bits_id(m3_arid), .axi4_mem_3_bits_ar_bits_addr(m3_araddr),
    .axi4_mem_3_bits_ar_bits_len(m3_arlen), .axi4_mem_3_bits_ar_bits_size(m3_arsize),
    .axi4_mem_3_bits_ar_bits_burst(m3_arburst), .axi4_mem_3_bits_ar_bits_lock(m3_arlock),
    .axi4_mem_3_bits_ar_bits_cache(m3_arcache), .axi4_mem_3_bits_ar_bits_prot(m3_arprot),
    .axi4_mem_3_bits_ar_bits_qos(m3_arqos),
    .axi4_mem_3_bits_r_valid(m3_rvalid), .axi4_mem_3_bits_r_ready(m3_rready),
    .axi4_mem_3_bits_r_bits_id(m3_rid), .axi4_mem_3_bits_r_bits_data(m3_rdata),
    .axi4_mem_3_bits_r_bits_resp(m3_rresp), .axi4_mem_3_bits_r_bits_last(m3_rlast)
`endif
`endif
`ifdef PYNQZ2_WLANE
    ,
  // THE WEIGHT LANE -- see the PYNQZ2_WLANE wire block above.  Its own clock in, its own AXI4
  // master out; axi4_wlane_0_clock is ChipTop echoing that clock back and is left open, as
  // axi4_mem_0_clock is.
    .clock_wlane(fclk_wlane),
    .axi4_wlane_0_clock(),
    .axi4_wlane_0_bits_aw_valid(w_awvalid), .axi4_wlane_0_bits_aw_ready(w_awready),
    .axi4_wlane_0_bits_aw_bits_id(w_awid), .axi4_wlane_0_bits_aw_bits_addr(w_awaddr),
    .axi4_wlane_0_bits_aw_bits_len(w_awlen), .axi4_wlane_0_bits_aw_bits_size(w_awsize),
    .axi4_wlane_0_bits_aw_bits_burst(w_awburst), .axi4_wlane_0_bits_aw_bits_lock(w_awlock),
    .axi4_wlane_0_bits_aw_bits_cache(w_awcache), .axi4_wlane_0_bits_aw_bits_prot(w_awprot),
    .axi4_wlane_0_bits_aw_bits_qos(w_awqos),
    .axi4_wlane_0_bits_w_valid(w_wvalid), .axi4_wlane_0_bits_w_ready(w_wready),
    .axi4_wlane_0_bits_w_bits_data(w_wdata), .axi4_wlane_0_bits_w_bits_strb(w_wstrb),
    .axi4_wlane_0_bits_w_bits_last(w_wlast),
    .axi4_wlane_0_bits_b_valid(w_bvalid), .axi4_wlane_0_bits_b_ready(w_bready),
    .axi4_wlane_0_bits_b_bits_id(w_bid), .axi4_wlane_0_bits_b_bits_resp(w_bresp),
    .axi4_wlane_0_bits_ar_valid(w_arvalid), .axi4_wlane_0_bits_ar_ready(w_arready),
    .axi4_wlane_0_bits_ar_bits_id(w_arid), .axi4_wlane_0_bits_ar_bits_addr(w_araddr),
    .axi4_wlane_0_bits_ar_bits_len(w_arlen), .axi4_wlane_0_bits_ar_bits_size(w_arsize),
    .axi4_wlane_0_bits_ar_bits_burst(w_arburst), .axi4_wlane_0_bits_ar_bits_lock(w_arlock),
    .axi4_wlane_0_bits_ar_bits_cache(w_arcache), .axi4_wlane_0_bits_ar_bits_prot(w_arprot),
    .axi4_wlane_0_bits_ar_bits_qos(w_arqos),
    .axi4_wlane_0_bits_r_valid(w_rvalid), .axi4_wlane_0_bits_r_ready(w_rready),
    .axi4_wlane_0_bits_r_bits_id(w_rid), .axi4_wlane_0_bits_r_bits_data(w_rdata),
    .axi4_wlane_0_bits_r_bits_resp(w_rresp), .axi4_wlane_0_bits_r_bits_last(w_rlast)
`endif
  );

  // ChipTop drives a 4-bit ID; HP0's is 6. Zero-extend rather than let the tools pick.
  axi4_to_axi3 #(.ADDR_W(32), .DATA_W(64), .ID_W(6)) u_bridge (
`ifdef PYNQZ2_HAS_MEMCLK
    .clk(fclk_mem), .rstn(mem_resetn),
`else
    .clk(fclk), .rstn(soc_resetn),
`endif
    .s_awid({2'b00, m_awid}), .s_awaddr(m_awaddr), .s_awlen(m_awlen),
    .s_awsize(m_awsize), .s_awburst(m_awburst), .s_awlock(m_awlock),
    .s_awcache(m_awcache), .s_awprot(m_awprot), .s_awqos(m_awqos),
    .s_awvalid(m_awvalid), .s_awready(m_awready),
    .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
    .s_wvalid(m_wvalid), .s_wready(m_wready),
    .s_bid(), .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready),
    .s_arid({2'b00, m_arid}), .s_araddr(m_araddr), .s_arlen(m_arlen),
    .s_arsize(m_arsize), .s_arburst(m_arburst), .s_arlock(m_arlock),
    .s_arcache(m_arcache), .s_arprot(m_arprot), .s_arqos(m_arqos),
    .s_arvalid(m_arvalid), .s_arready(m_arready),
    .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast),
    .s_rvalid(m_rvalid), .s_rready(m_rready),
    .m_awid(h_awid), .m_awaddr(h_awaddr_raw), .m_awlen(h_awlen), .m_awsize(h_awsize),
    .m_awburst(h_awburst), .m_awlock(h_awlock), .m_awcache(h_awcache),
    .m_awprot(h_awprot), .m_awqos(h_awqos),
    .m_awvalid(h_awvalid), .m_awready(h_awready),
    .m_wid(h_wid), .m_wdata(h_wdata), .m_wstrb(h_wstrb), .m_wlast(h_wlast),
    .m_wvalid(h_wvalid), .m_wready(h_wready),
    .m_bid(h_bid), .m_bresp(h_bresp), .m_bvalid(h_bvalid), .m_bready(h_bready),
    .m_arid(h_arid), .m_araddr(h_araddr_raw), .m_arlen(h_arlen), .m_arsize(h_arsize),
    .m_arburst(h_arburst), .m_arlock(h_arlock), .m_arcache(h_arcache),
    .m_arprot(h_arprot), .m_arqos(h_arqos),
    .m_arvalid(h_arvalid), .m_arready(h_arready),
    .m_rdata(h_rdata), .m_rresp(h_rresp), .m_rlast(h_rlast),
    .m_rvalid(h_rvalid), .m_rready(h_rready),
    .err_burst_too_long(err_burst_too_long)
  );

  // rid from HP0 is 6-bit; ChipTop expects 4. The bridge passes IDs through unchanged and
  // we only ever issue IDs with the top two bits clear, so truncating is lossless.
  assign m_bid = h_bid[3:0];
  assign m_rid = h_rid[3:0];
`ifdef PYNQZ2_NMEM2
  // LEVER 3, channel 1 -- see the PYNQZ2_NMEM2 wire block above.
  axi4_to_axi3 #(.ADDR_W(32), .DATA_W(64), .ID_W(6)) u_bridge1 (
`ifdef PYNQZ2_HAS_MEMCLK
    .clk(fclk_mem), .rstn(mem_resetn),
`else
    .clk(fclk), .rstn(soc_resetn),
`endif
    .s_awid({2'b00, m1_awid}), .s_awaddr(m1_awaddr), .s_awlen(m1_awlen),
    .s_awsize(m1_awsize), .s_awburst(m1_awburst), .s_awlock(m1_awlock),
    .s_awcache(m1_awcache), .s_awprot(m1_awprot), .s_awqos(m1_awqos),
    .s_awvalid(m1_awvalid), .s_awready(m1_awready),
    .s_wdata(m1_wdata), .s_wstrb(m1_wstrb), .s_wlast(m1_wlast),
    .s_wvalid(m1_wvalid), .s_wready(m1_wready),
    .s_bid(), .s_bresp(m1_bresp), .s_bvalid(m1_bvalid), .s_bready(m1_bready),
    .s_arid({2'b00, m1_arid}), .s_araddr(m1_araddr), .s_arlen(m1_arlen),
    .s_arsize(m1_arsize), .s_arburst(m1_arburst), .s_arlock(m1_arlock),
    .s_arcache(m1_arcache), .s_arprot(m1_arprot), .s_arqos(m1_arqos),
    .s_arvalid(m1_arvalid), .s_arready(m1_arready),
    .s_rdata(m1_rdata), .s_rresp(m1_rresp), .s_rlast(m1_rlast),
    .s_rvalid(m1_rvalid), .s_rready(m1_rready),
    .m_awid(h1_awid), .m_awaddr(h1_awaddr_raw), .m_awlen(h1_awlen), .m_awsize(h1_awsize),
    .m_awburst(h1_awburst), .m_awlock(h1_awlock), .m_awcache(h1_awcache),
    .m_awprot(h1_awprot), .m_awqos(h1_awqos),
    .m_awvalid(h1_awvalid), .m_awready(h1_awready),
    .m_wid(h1_wid), .m_wdata(h1_wdata), .m_wstrb(h1_wstrb), .m_wlast(h1_wlast),
    .m_wvalid(h1_wvalid), .m_wready(h1_wready),
    .m_bid(h1_bid), .m_bresp(h1_bresp), .m_bvalid(h1_bvalid), .m_bready(h1_bready),
    .m_arid(h1_arid), .m_araddr(h1_araddr_raw), .m_arlen(h1_arlen), .m_arsize(h1_arsize),
    .m_arburst(h1_arburst), .m_arlock(h1_arlock), .m_arcache(h1_arcache),
    .m_arprot(h1_arprot), .m_arqos(h1_arqos),
    .m_arvalid(h1_arvalid), .m_arready(h1_arready),
    .m_rdata(h1_rdata), .m_rresp(h1_rresp), .m_rlast(h1_rlast),
    .m_rvalid(h1_rvalid), .m_rready(h1_rready),
    .err_burst_too_long(err_burst_too_long1)
  );

  // HP1 IDs are 6-bit; ChipTop expects 4 -- as for HP0 above.
  assign m1_bid = h1_bid[3:0];
  assign m1_rid = h1_rid[3:0];
`endif
`ifdef PYNQZ2_NMEM4
  // channels 2 and 3 -- see the PYNQZ2_NMEM4 wire block.
  axi4_to_axi3 #(.ADDR_W(32), .DATA_W(64), .ID_W(6)) u_bridge2 (
`ifdef PYNQZ2_HAS_MEMCLK
    .clk(fclk_mem), .rstn(mem_resetn),
`else
    .clk(fclk), .rstn(soc_resetn),
`endif
    .s_awid({2'b00, m2_awid}), .s_awaddr(m2_awaddr), .s_awlen(m2_awlen),
    .s_awsize(m2_awsize), .s_awburst(m2_awburst), .s_awlock(m2_awlock),
    .s_awcache(m2_awcache), .s_awprot(m2_awprot), .s_awqos(m2_awqos),
    .s_awvalid(m2_awvalid), .s_awready(m2_awready),
    .s_wdata(m2_wdata), .s_wstrb(m2_wstrb), .s_wlast(m2_wlast),
    .s_wvalid(m2_wvalid), .s_wready(m2_wready),
    .s_bid(), .s_bresp(m2_bresp), .s_bvalid(m2_bvalid), .s_bready(m2_bready),
    .s_arid({2'b00, m2_arid}), .s_araddr(m2_araddr), .s_arlen(m2_arlen),
    .s_arsize(m2_arsize), .s_arburst(m2_arburst), .s_arlock(m2_arlock),
    .s_arcache(m2_arcache), .s_arprot(m2_arprot), .s_arqos(m2_arqos),
    .s_arvalid(m2_arvalid), .s_arready(m2_arready),
    .s_rdata(m2_rdata), .s_rresp(m2_rresp), .s_rlast(m2_rlast),
    .s_rvalid(m2_rvalid), .s_rready(m2_rready),
    .m_awid(h2_awid), .m_awaddr(h2_awaddr_raw), .m_awlen(h2_awlen), .m_awsize(h2_awsize),
    .m_awburst(h2_awburst), .m_awlock(h2_awlock), .m_awcache(h2_awcache),
    .m_awprot(h2_awprot), .m_awqos(h2_awqos),
    .m_awvalid(h2_awvalid), .m_awready(h2_awready),
    .m_wid(h2_wid), .m_wdata(h2_wdata), .m_wstrb(h2_wstrb), .m_wlast(h2_wlast),
    .m_wvalid(h2_wvalid), .m_wready(h2_wready),
    .m_bid(h2_bid), .m_bresp(h2_bresp), .m_bvalid(h2_bvalid), .m_bready(h2_bready),
    .m_arid(h2_arid), .m_araddr(h2_araddr_raw), .m_arlen(h2_arlen), .m_arsize(h2_arsize),
    .m_arburst(h2_arburst), .m_arlock(h2_arlock), .m_arcache(h2_arcache),
    .m_arprot(h2_arprot), .m_arqos(h2_arqos),
    .m_arvalid(h2_arvalid), .m_arready(h2_arready),
    .m_rdata(h2_rdata), .m_rresp(h2_rresp), .m_rlast(h2_rlast),
    .m_rvalid(h2_rvalid), .m_rready(h2_rready),
    .err_burst_too_long(err_burst_too_long2)
  );

  // HP1 IDs are 6-bit; ChipTop expects 4 -- as for HP0 above.
  assign m2_bid = h2_bid[3:0];
  assign m2_rid = h2_rid[3:0];
  axi4_to_axi3 #(.ADDR_W(32), .DATA_W(64), .ID_W(6)) u_bridge3 (
`ifdef PYNQZ2_HAS_MEMCLK
    .clk(fclk_mem), .rstn(mem_resetn),
`else
    .clk(fclk), .rstn(soc_resetn),
`endif
    .s_awid({2'b00, m3_awid}), .s_awaddr(m3_awaddr), .s_awlen(m3_awlen),
    .s_awsize(m3_awsize), .s_awburst(m3_awburst), .s_awlock(m3_awlock),
    .s_awcache(m3_awcache), .s_awprot(m3_awprot), .s_awqos(m3_awqos),
    .s_awvalid(m3_awvalid), .s_awready(m3_awready),
    .s_wdata(m3_wdata), .s_wstrb(m3_wstrb), .s_wlast(m3_wlast),
    .s_wvalid(m3_wvalid), .s_wready(m3_wready),
    .s_bid(), .s_bresp(m3_bresp), .s_bvalid(m3_bvalid), .s_bready(m3_bready),
    .s_arid({2'b00, m3_arid}), .s_araddr(m3_araddr), .s_arlen(m3_arlen),
    .s_arsize(m3_arsize), .s_arburst(m3_arburst), .s_arlock(m3_arlock),
    .s_arcache(m3_arcache), .s_arprot(m3_arprot), .s_arqos(m3_arqos),
    .s_arvalid(m3_arvalid), .s_arready(m3_arready),
    .s_rdata(m3_rdata), .s_rresp(m3_rresp), .s_rlast(m3_rlast),
    .s_rvalid(m3_rvalid), .s_rready(m3_rready),
    .m_awid(h3_awid), .m_awaddr(h3_awaddr_raw), .m_awlen(h3_awlen), .m_awsize(h3_awsize),
    .m_awburst(h3_awburst), .m_awlock(h3_awlock), .m_awcache(h3_awcache),
    .m_awprot(h3_awprot), .m_awqos(h3_awqos),
    .m_awvalid(h3_awvalid), .m_awready(h3_awready),
    .m_wid(h3_wid), .m_wdata(h3_wdata), .m_wstrb(h3_wstrb), .m_wlast(h3_wlast),
    .m_wvalid(h3_wvalid), .m_wready(h3_wready),
    .m_bid(h3_bid), .m_bresp(h3_bresp), .m_bvalid(h3_bvalid), .m_bready(h3_bready),
    .m_arid(h3_arid), .m_araddr(h3_araddr_raw), .m_arlen(h3_arlen), .m_arsize(h3_arsize),
    .m_arburst(h3_arburst), .m_arlock(h3_arlock), .m_arcache(h3_arcache),
    .m_arprot(h3_arprot), .m_arqos(h3_arqos),
    .m_arvalid(h3_arvalid), .m_arready(h3_arready),
    .m_rdata(h3_rdata), .m_rresp(h3_rresp), .m_rlast(h3_rlast),
    .m_rvalid(h3_rvalid), .m_rready(h3_rready),
    .err_burst_too_long(err_burst_too_long3)
  );

  // HP1 IDs are 6-bit; ChipTop expects 4 -- as for HP0 above.
  assign m3_bid = h3_bid[3:0];
  assign m3_rid = h3_rid[3:0];
`endif

`ifdef PYNQZ2_WLANE
  // THE WEIGHT LANE's own AXI4-to-AXI3 shim, on the lane's clock -- see the PYNQZ2_WLANE wire
  // block.  Identical to u_bridge but for its clock, its reset and its port; the lane only ever
  // reads, so the write side of it is dead logic that costs a few LUTs and keeps the instance the
  // same module as every other channel's.
  axi4_to_axi3 #(.ADDR_W(32), .DATA_W(64), .ID_W(6)) u_bridge_w (
    .clk(fclk_wlane), .rstn(wlane_resetn),
    .s_awid({2'b00, w_awid}), .s_awaddr(w_awaddr), .s_awlen(w_awlen),
    .s_awsize(w_awsize), .s_awburst(w_awburst), .s_awlock(w_awlock),
    .s_awcache(w_awcache), .s_awprot(w_awprot), .s_awqos(w_awqos),
    .s_awvalid(w_awvalid), .s_awready(w_awready),
    .s_wdata(w_wdata), .s_wstrb(w_wstrb), .s_wlast(w_wlast),
    .s_wvalid(w_wvalid), .s_wready(w_wready),
    .s_bid(), .s_bresp(w_bresp), .s_bvalid(w_bvalid), .s_bready(w_bready),
    .s_arid({2'b00, w_arid}), .s_araddr(w_araddr), .s_arlen(w_arlen),
    .s_arsize(w_arsize), .s_arburst(w_arburst), .s_arlock(w_arlock),
    .s_arcache(w_arcache), .s_arprot(w_arprot), .s_arqos(w_arqos),
    .s_arvalid(w_arvalid), .s_arready(w_arready),
    .s_rdata(w_rdata), .s_rresp(w_rresp), .s_rlast(w_rlast),
    .s_rvalid(w_rvalid), .s_rready(w_rready),
    .m_awid(hw_awid), .m_awaddr(hw_awaddr_raw), .m_awlen(hw_awlen), .m_awsize(hw_awsize),
    .m_awburst(hw_awburst), .m_awlock(hw_awlock), .m_awcache(hw_awcache),
    .m_awprot(hw_awprot), .m_awqos(hw_awqos),
    .m_awvalid(hw_awvalid), .m_awready(hw_awready),
    .m_wid(hw_wid), .m_wdata(hw_wdata), .m_wstrb(hw_wstrb), .m_wlast(hw_wlast),
    .m_wvalid(hw_wvalid), .m_wready(hw_wready),
    .m_bid(hw_bid), .m_bresp(hw_bresp), .m_bvalid(hw_bvalid), .m_bready(hw_bready),
    .m_arid(hw_arid), .m_araddr(hw_araddr_raw), .m_arlen(hw_arlen), .m_arsize(hw_arsize),
    .m_arburst(hw_arburst), .m_arlock(hw_arlock), .m_arcache(hw_arcache),
    .m_arprot(hw_arprot), .m_arqos(hw_arqos),
    .m_arvalid(hw_arvalid), .m_arready(hw_arready),
    .m_rdata(hw_rdata), .m_rresp(hw_rresp), .m_rlast(hw_rlast),
    .m_rvalid(hw_rvalid), .m_rready(hw_rready),
    .err_burst_too_long(err_burst_too_long_w)
  );

  // HP2 IDs are 6-bit; ChipTop expects 4 -- as for HP0 above.
  assign w_bid = hw_bid[3:0];
  assign w_rid = hw_rid[3:0];
`endif

  // The address fold. Everything above bit 27 of the SoC's view is discarded and replaced
  // by 0x1, which is what puts a 256 MB ExtMem in the upper half of PS DDR.
  wire [31:0] h_awaddr = {4'd1, h_awaddr_raw[27:0]};
  wire [31:0] h_araddr = {4'd1, h_araddr_raw[27:0]};
`ifdef PYNQZ2_WLANE
  // The weight lane reads the SAME DDR window through the same fold, so a weight image the PS wrote
  // at 0x8000_0000 + x in the SoC's view is at 0x1000_0000 + x in the PS's, exactly as for the L2's
  // channel.  It is also the only bound on the lane's address on this side: nothing inside the SoC
  // stops a Get outside the weight window, and mbxd_dma2's per-Get window check is what does
  // (MEMORY_BANDWIDTH.md 9.9, finding (b)).
  wire [31:0] hw_awaddr = {4'd1, hw_awaddr_raw[27:0]};
  wire [31:0] hw_araddr = {4'd1, hw_araddr_raw[27:0]};
`endif
`ifdef PYNQZ2_NMEM2
  // LEVER 3, channel 1 -- see the PYNQZ2_NMEM2 wire block above.
  wire [31:0] h1_awaddr = {4'd1, h1_awaddr_raw[27:0]};
  wire [31:0] h1_araddr = {4'd1, h1_araddr_raw[27:0]};
`endif
`ifdef PYNQZ2_NMEM4
  // channels 2 and 3 -- see the PYNQZ2_NMEM4 wire block.
  wire [31:0] h2_awaddr = {4'd1, h2_awaddr_raw[27:0]};
  wire [31:0] h2_araddr = {4'd1, h2_araddr_raw[27:0]};
  wire [31:0] h3_awaddr = {4'd1, h3_awaddr_raw[27:0]};
  wire [31:0] h3_araddr = {4'd1, h3_araddr_raw[27:0]};
`endif

  // ---- UART crossover to PS UART1 (EMIO) ----
  assign ps_uart1_rx = uart_soc_tx;   // PS receives what the SoC sends
  assign uart_soc_rx = ps_uart1_tx;   // SoC receives what the PS sends

  // LD0 heartbeat, LD1 SoC out of reset, LD2 memory traffic seen, LD3 burst-length error
  reg [25:0] hb = 0;
`ifdef PYNQZ2_HAS_MEMCLK
  // h_awvalid/h_arvalid live in the MEMORY domain once the shim moves to FCLK1, and
  // saw_mem is sampled here in the fclk domain and read back over GP0.  Two flops.
  //
  // Found by report_cdc, which is the whole reason the build runs it: with
  // pynqz2_memclk.xdc declaring the two clocks asynchronous, this stopped being a timing
  // failure and became a silent one.  It is BENIGN -- a sticky "the PL has issued a
  // memory transaction" flag driving an LED and a status bit, where metastability can
  // only delay the LED by a cycle -- but "benign" is a conclusion to reach after looking,
  // not a reason not to look.  Bitstream f507f18f was built before this fix and carries
  // the unsynchronised version; its bandwidth numbers cannot be affected by it, because
  // saw_mem drives nothing but an LED and bit 2 of STATUS.
  //
  // AND THE OR IS REGISTERED IN THE MEMORY DOMAIN FIRST.  report_cdc flagged the version
  // above as CDC-10, combinational logic ahead of a synchroniser (MEMORY_BANDWIDTH.md s8):
  // a glitch on the OR can be captured.  The source is now a flop, and a sticky one, so a
  // one-cycle valid at FCLK1 is a level by the time the slower fclk domain samples it.
  reg sawmem_src = 1'b0;
  always @(posedge fclk_mem) begin
    if (!mem_resetn)                 sawmem_src <= 1'b0;
    else if (h_awvalid || h_arvalid) sawmem_src <= 1'b1;
  end
  (* ASYNC_REG = "TRUE" *) reg [1:0] sawmem_sync;
  always @(posedge fclk) begin
    if (!ps_rstn) sawmem_sync <= 2'b00;
    else          sawmem_sync <= {sawmem_sync[0], sawmem_src};
  end
`endif
  reg        saw_mem = 0;
  always @(posedge fclk) begin
    hb <= hb + 1'b1;
    if (!ps_rstn) saw_mem <= 1'b0;
`ifdef PYNQZ2_HAS_MEMCLK
    else if (sawmem_sync[1]) saw_mem <= 1'b1;
`else
    else if (h_awvalid || h_arvalid) saw_mem <= 1'b1;
`endif
  end
`ifdef PYNQZ2_WLANE
  wire err_burst_lane = err_burst_too_long_w;   // the weight lane's shim, on its own clock
`else
  wire err_burst_lane = 1'b0;
`endif
`ifdef PYNQZ2_NMEM4
  wire err_burst_any = err_burst_too_long | err_burst_too_long1 |
                       err_burst_too_long2 | err_burst_too_long3 | err_burst_lane;
`elsif PYNQZ2_NMEM2
  wire err_burst_any = err_burst_too_long | err_burst_too_long1 | err_burst_lane;
`else
  wire err_burst_any = err_burst_too_long | err_burst_lane;
`endif
  assign leds = {err_burst_any, saw_mem, soc_resetn, hb[25]};

`ifdef PYNQZ2_HAS_RGB
  // ---- the RGB LEDs' pad behaviour ----
  //
  // WHAT SOFTWARE DRIVES. sifive's GPIO presents oval (output_value) and oe (output_en) as
  // separate registers, both zero at reset, so a pin is dark until a guest has explicitly
  // asked for it -- which is the right power-on state for something that is otherwise on
  // from the moment the bitstream loads. Zephyr's gpio_sifive.c sets out_en for
  // GPIO_OUTPUT and out_val for the value, so `rgb_oval & rgb_oe` is exactly "the guest
  // asked for this LED".
  assign rgb_drive = rgb_oval & rgb_oe;

  // THE BRIGHTNESS CHOPPER, AND WHY IT IS IN HARDWARE.
  //
  // PYNQ-Z1 Reference Manual section 12.1: "Digilent strongly recommends the use of
  // pulse-width modulation (PWM) when driving the tri-color LEDs. Driving any of the
  // inputs to a steady logic '1' will result in the LED being illuminated at an
  // uncomfortably bright level. You can avoid this by ensuring that none of the tri-color
  // signals are driven with more than a 50% duty cycle."
  //
  // So all six signals are gated by a free-running RGB_DUTY/256 chopper. RGB_DUTY is
  // CLAMPED to 128 here, in a comparison against a compile-time constant that synthesises
  // to nothing, so the vendor's 50% ceiling holds even against a -generic override -- and
  // so that no guest, and no bug in one, can leave one of these at 100%. The default 32
  // is 12.5%: a quarter of the permitted ceiling and still plainly visible.
  //
  // 8 bits at 34.4828 MHz is 134.7 kHz, four orders of magnitude above anything the eye
  // or a phone camera integrates over. The counter is its own, not a slice of hb, so that
  // this whole block lives and dies with the `ifdef and the four builds without RGB LEDs
  // keep textually identical RTL (see the header of the port list).
  //
  // This is a fixed brightness limit, NOT colour mixing: all six channels share one duty,
  // so software still gets exactly the eight on/off states per LED. Per-channel PWM would
  // mean sifive's PWM block instead of (or beside) the GPIO -- docs/RGB_LEDS.md section 8
  // prices it.
  reg [7:0] rgb_phase = 8'd0;
`ifdef PYNQZ2_HAS_TILECLK
  // Under PYNQZ2_HAS_TILECLK the GPIO controller is on FCLK1, so the chopper is too; the
  // pins are outputs and nothing samples rgb_led, so only the duty's frequency changes.
  always @(posedge fclk_mem) rgb_phase <= rgb_phase + 8'd1;
`else
  always @(posedge fclk) rgb_phase <= rgb_phase + 8'd1;
`endif
  wire rgb_lit = (rgb_phase < ((RGB_DUTY > 8'd128) ? 8'd128 : RGB_DUTY));
  assign rgb_led = rgb_drive & {6{rgb_lit}};

  // READBACK INTO THE CONTROLLER'S INPUT PATH.
  //
  // These are outputs into a transistor base: there is no input buffer and no way to
  // sense the ball. What there is, is sifive's own definition of what a pad does when you
  // loop it back -- Pin.toLoopback in rocket-chip-blocks' pinctrl:
  //     p.i.ival := Mux(p.o.oe, p.o.oval, p.o.pue) & p.o.ie
  // which is reproduced exactly here. Note it is taken PRE-chopper on purpose: reading a
  // 12.5%-duty pad would return 1 twelve percent of the time, which is worse than useless.
  //
  // WHAT THIS PROVES AND WHAT IT DOES NOT. It proves the guest's write reached the
  // controller's output registers, came out of ChipTop on the bit it was supposed to, and
  // came back -- so a swapped or truncated bit vector between the SoC and this module is
  // caught by software, with no instrument and nobody looking at the board. It proves
  // NOTHING about the OBUF, the package ball, or the colour. Only the eye can do that.
  assign rgb_ival = ((rgb_oval & rgb_oe) | (~rgb_oe & rgb_pue)) & rgb_ie;
`endif

  // status is what the PS reads at GP0 offset 0x04. The low four bits are the same four
  // things they have always been, in the same places.
`ifdef PYNQZ2_HAS_RGB
  // ... and [9:4] carry what the PL is actually driving at the six RGB pins. That is a
  // SECOND observer of the same signals, on a different bus and a different master: Rocket
  // writes output_value over TileLink, the ARM reads it back over M_AXI_GP0 without the
  // guest's help. scripts/35_rocket_rgb_leds.sh checks the two against each other, which
  // is the closest thing to a readback these pins have.
`ifdef PYNQZ2_HAS_TILECLK
  // rgb_drive comes from the GPIO controller on FCLK1 and STATUS is read in the fclk
  // domain: two flops, for the same reason saw_mem has them.
  (* ASYNC_REG = "TRUE" *) reg [11:0] rgbdrv_sync;
  always @(posedge fclk) rgbdrv_sync <= {rgbdrv_sync[5:0], rgb_drive};
  assign status = {22'd0, rgbdrv_sync[11:6], err_burst_any, saw_mem, soc_resetn, 1'b1};
`else
  assign status = {22'd0, rgb_drive, err_burst_any, saw_mem, soc_resetn, 1'b1};
`endif
`else
  assign status = {28'd0, err_burst_any, saw_mem, soc_resetn, 1'b1};
`endif

  ps7_0 u_ps7 (
    .FCLK_CLK0(fclk), .FCLK_RESET0_N(ps_rstn),
`ifdef PYNQZ2_HAS_MEMCLK
    .FCLK_CLK1(fclk_mem),
`endif
`ifdef PYNQZ2_WLANE
    .FCLK_CLK1(fclk_wlane),
`endif

    .UART1_TX(ps_uart1_tx), .UART1_RX(ps_uart1_rx),

    .M_AXI_GP0_ACLK(fclk),
    .M_AXI_GP0_AWID(gp0_awid), .M_AXI_GP0_AWADDR(gp0_awaddr), .M_AXI_GP0_AWLEN(gp0_awlen),
    .M_AXI_GP0_AWSIZE(), .M_AXI_GP0_AWBURST(), .M_AXI_GP0_AWLOCK(),
    .M_AXI_GP0_AWCACHE(), .M_AXI_GP0_AWPROT(), .M_AXI_GP0_AWQOS(),
    .M_AXI_GP0_AWVALID(gp0_awvalid), .M_AXI_GP0_AWREADY(gp0_awready),
    .M_AXI_GP0_WID(), .M_AXI_GP0_WDATA(gp0_wdata), .M_AXI_GP0_WSTRB(gp0_wstrb),
    .M_AXI_GP0_WLAST(gp0_wlast), .M_AXI_GP0_WVALID(gp0_wvalid),
    .M_AXI_GP0_WREADY(gp0_wready),
    .M_AXI_GP0_BID(gp0_bid), .M_AXI_GP0_BRESP(gp0_bresp),
    .M_AXI_GP0_BVALID(gp0_bvalid), .M_AXI_GP0_BREADY(gp0_bready),
    .M_AXI_GP0_ARID(gp0_arid), .M_AXI_GP0_ARADDR(gp0_araddr), .M_AXI_GP0_ARLEN(gp0_arlen),
    .M_AXI_GP0_ARSIZE(), .M_AXI_GP0_ARBURST(), .M_AXI_GP0_ARLOCK(),
    .M_AXI_GP0_ARCACHE(), .M_AXI_GP0_ARPROT(), .M_AXI_GP0_ARQOS(),
    .M_AXI_GP0_ARVALID(gp0_arvalid), .M_AXI_GP0_ARREADY(gp0_arready),
    .M_AXI_GP0_RID(gp0_rid), .M_AXI_GP0_RDATA(gp0_rdata), .M_AXI_GP0_RRESP(gp0_rresp),
    .M_AXI_GP0_RLAST(gp0_rlast), .M_AXI_GP0_RVALID(gp0_rvalid),
    .M_AXI_GP0_RREADY(gp0_rready),

`ifdef PYNQZ2_HAS_MEMCLK
    .S_AXI_HP0_ACLK(fclk_mem),
`else
    .S_AXI_HP0_ACLK(fclk),
`endif
    .S_AXI_HP0_AWID(h_awid), .S_AXI_HP0_AWADDR(h_awaddr), .S_AXI_HP0_AWLEN(h_awlen),
    .S_AXI_HP0_AWSIZE(h_awsize), .S_AXI_HP0_AWBURST(h_awburst),
    .S_AXI_HP0_AWLOCK(h_awlock), .S_AXI_HP0_AWCACHE(h_awcache),
    .S_AXI_HP0_AWPROT(h_awprot), .S_AXI_HP0_AWQOS(h_awqos),
    .S_AXI_HP0_AWVALID(h_awvalid), .S_AXI_HP0_AWREADY(h_awready),
    .S_AXI_HP0_WID(h_wid), .S_AXI_HP0_WDATA(h_wdata), .S_AXI_HP0_WSTRB(h_wstrb),
    .S_AXI_HP0_WLAST(h_wlast), .S_AXI_HP0_WVALID(h_wvalid),
    .S_AXI_HP0_WREADY(h_wready),
    .S_AXI_HP0_BID(h_bid), .S_AXI_HP0_BRESP(h_bresp),
    .S_AXI_HP0_BVALID(h_bvalid), .S_AXI_HP0_BREADY(h_bready),
    .S_AXI_HP0_ARID(h_arid), .S_AXI_HP0_ARADDR(h_araddr), .S_AXI_HP0_ARLEN(h_arlen),
    .S_AXI_HP0_ARSIZE(h_arsize), .S_AXI_HP0_ARBURST(h_arburst),
    .S_AXI_HP0_ARLOCK(h_arlock), .S_AXI_HP0_ARCACHE(h_arcache),
    .S_AXI_HP0_ARPROT(h_arprot), .S_AXI_HP0_ARQOS(h_arqos),
    .S_AXI_HP0_ARVALID(h_arvalid), .S_AXI_HP0_ARREADY(h_arready),
    .S_AXI_HP0_RID(h_rid), .S_AXI_HP0_RDATA(h_rdata), .S_AXI_HP0_RRESP(h_rresp),
    .S_AXI_HP0_RLAST(h_rlast), .S_AXI_HP0_RVALID(h_rvalid),
    .S_AXI_HP0_RREADY(h_rready),
    .S_AXI_HP0_RDISSUECAP1_EN(1'b0), .S_AXI_HP0_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP0_RACOUNT(), .S_AXI_HP0_RCOUNT(),
    .S_AXI_HP0_WACOUNT(), .S_AXI_HP0_WCOUNT(),
`ifdef PYNQZ2_WLANE
  // THE WEIGHT LANE on S_AXI_HP2 (DDR controller port 2), clocked by FCLK1.  The L2's channel keeps
  // HP0 on port 3 and FCLK0.  tcl/build_rocket.tcl refuses has_wlane together with has_ch1_hp2 or
  // has_nmem4, which are the other claimants of HP2.
    .S_AXI_HP2_ACLK(fclk_wlane),
    .S_AXI_HP2_AWID(hw_awid), .S_AXI_HP2_AWADDR(hw_awaddr), .S_AXI_HP2_AWLEN(hw_awlen),
    .S_AXI_HP2_AWSIZE(hw_awsize), .S_AXI_HP2_AWBURST(hw_awburst),
    .S_AXI_HP2_AWLOCK(hw_awlock), .S_AXI_HP2_AWCACHE(hw_awcache),
    .S_AXI_HP2_AWPROT(hw_awprot), .S_AXI_HP2_AWQOS(hw_awqos),
    .S_AXI_HP2_AWVALID(hw_awvalid), .S_AXI_HP2_AWREADY(hw_awready),
    .S_AXI_HP2_WID(hw_wid), .S_AXI_HP2_WDATA(hw_wdata), .S_AXI_HP2_WSTRB(hw_wstrb),
    .S_AXI_HP2_WLAST(hw_wlast), .S_AXI_HP2_WVALID(hw_wvalid),
    .S_AXI_HP2_WREADY(hw_wready),
    .S_AXI_HP2_BID(hw_bid), .S_AXI_HP2_BRESP(hw_bresp),
    .S_AXI_HP2_BVALID(hw_bvalid), .S_AXI_HP2_BREADY(hw_bready),
    .S_AXI_HP2_ARID(hw_arid), .S_AXI_HP2_ARADDR(hw_araddr), .S_AXI_HP2_ARLEN(hw_arlen),
    .S_AXI_HP2_ARSIZE(hw_arsize), .S_AXI_HP2_ARBURST(hw_arburst),
    .S_AXI_HP2_ARLOCK(hw_arlock), .S_AXI_HP2_ARCACHE(hw_arcache),
    .S_AXI_HP2_ARPROT(hw_arprot), .S_AXI_HP2_ARQOS(hw_arqos),
    .S_AXI_HP2_ARVALID(hw_arvalid), .S_AXI_HP2_ARREADY(hw_arready),
    .S_AXI_HP2_RID(hw_rid), .S_AXI_HP2_RDATA(hw_rdata), .S_AXI_HP2_RRESP(hw_rresp),
    .S_AXI_HP2_RLAST(hw_rlast), .S_AXI_HP2_RVALID(hw_rvalid),
    .S_AXI_HP2_RREADY(hw_rready),
    .S_AXI_HP2_RDISSUECAP1_EN(1'b0), .S_AXI_HP2_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP2_RACOUNT(), .S_AXI_HP2_RCOUNT(),
    .S_AXI_HP2_WACOUNT(), .S_AXI_HP2_WCOUNT(),
`endif
`ifdef PYNQZ2_NMEM2
  // LEVER 3, channel 1 -- see the PYNQZ2_NMEM2 wire block above.
`ifdef PYNQZ2_CH1_HP2
  // ... on S_AXI_HP2: DDR controller port 2, not HP0's port 3 (see the wire block).
`ifdef PYNQZ2_HAS_MEMCLK
    .S_AXI_HP2_ACLK(fclk_mem),
`else
    .S_AXI_HP2_ACLK(fclk),
`endif
    .S_AXI_HP2_AWID(h1_awid), .S_AXI_HP2_AWADDR(h1_awaddr), .S_AXI_HP2_AWLEN(h1_awlen),
    .S_AXI_HP2_AWSIZE(h1_awsize), .S_AXI_HP2_AWBURST(h1_awburst),
    .S_AXI_HP2_AWLOCK(h1_awlock), .S_AXI_HP2_AWCACHE(h1_awcache),
    .S_AXI_HP2_AWPROT(h1_awprot), .S_AXI_HP2_AWQOS(h1_awqos),
    .S_AXI_HP2_AWVALID(h1_awvalid), .S_AXI_HP2_AWREADY(h1_awready),
    .S_AXI_HP2_WID(h1_wid), .S_AXI_HP2_WDATA(h1_wdata), .S_AXI_HP2_WSTRB(h1_wstrb),
    .S_AXI_HP2_WLAST(h1_wlast), .S_AXI_HP2_WVALID(h1_wvalid),
    .S_AXI_HP2_WREADY(h1_wready),
    .S_AXI_HP2_BID(h1_bid), .S_AXI_HP2_BRESP(h1_bresp),
    .S_AXI_HP2_BVALID(h1_bvalid), .S_AXI_HP2_BREADY(h1_bready),
    .S_AXI_HP2_ARID(h1_arid), .S_AXI_HP2_ARADDR(h1_araddr), .S_AXI_HP2_ARLEN(h1_arlen),
    .S_AXI_HP2_ARSIZE(h1_arsize), .S_AXI_HP2_ARBURST(h1_arburst),
    .S_AXI_HP2_ARLOCK(h1_arlock), .S_AXI_HP2_ARCACHE(h1_arcache),
    .S_AXI_HP2_ARPROT(h1_arprot), .S_AXI_HP2_ARQOS(h1_arqos),
    .S_AXI_HP2_ARVALID(h1_arvalid), .S_AXI_HP2_ARREADY(h1_arready),
    .S_AXI_HP2_RID(h1_rid), .S_AXI_HP2_RDATA(h1_rdata), .S_AXI_HP2_RRESP(h1_rresp),
    .S_AXI_HP2_RLAST(h1_rlast), .S_AXI_HP2_RVALID(h1_rvalid),
    .S_AXI_HP2_RREADY(h1_rready),
    .S_AXI_HP2_RDISSUECAP1_EN(1'b0), .S_AXI_HP2_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP2_RACOUNT(), .S_AXI_HP2_RCOUNT(),
    .S_AXI_HP2_WACOUNT(), .S_AXI_HP2_WCOUNT(),
`else
`ifdef PYNQZ2_HAS_MEMCLK
    .S_AXI_HP1_ACLK(fclk_mem),
`else
    .S_AXI_HP1_ACLK(fclk),
`endif
    .S_AXI_HP1_AWID(h1_awid), .S_AXI_HP1_AWADDR(h1_awaddr), .S_AXI_HP1_AWLEN(h1_awlen),
    .S_AXI_HP1_AWSIZE(h1_awsize), .S_AXI_HP1_AWBURST(h1_awburst),
    .S_AXI_HP1_AWLOCK(h1_awlock), .S_AXI_HP1_AWCACHE(h1_awcache),
    .S_AXI_HP1_AWPROT(h1_awprot), .S_AXI_HP1_AWQOS(h1_awqos),
    .S_AXI_HP1_AWVALID(h1_awvalid), .S_AXI_HP1_AWREADY(h1_awready),
    .S_AXI_HP1_WID(h1_wid), .S_AXI_HP1_WDATA(h1_wdata), .S_AXI_HP1_WSTRB(h1_wstrb),
    .S_AXI_HP1_WLAST(h1_wlast), .S_AXI_HP1_WVALID(h1_wvalid),
    .S_AXI_HP1_WREADY(h1_wready),
    .S_AXI_HP1_BID(h1_bid), .S_AXI_HP1_BRESP(h1_bresp),
    .S_AXI_HP1_BVALID(h1_bvalid), .S_AXI_HP1_BREADY(h1_bready),
    .S_AXI_HP1_ARID(h1_arid), .S_AXI_HP1_ARADDR(h1_araddr), .S_AXI_HP1_ARLEN(h1_arlen),
    .S_AXI_HP1_ARSIZE(h1_arsize), .S_AXI_HP1_ARBURST(h1_arburst),
    .S_AXI_HP1_ARLOCK(h1_arlock), .S_AXI_HP1_ARCACHE(h1_arcache),
    .S_AXI_HP1_ARPROT(h1_arprot), .S_AXI_HP1_ARQOS(h1_arqos),
    .S_AXI_HP1_ARVALID(h1_arvalid), .S_AXI_HP1_ARREADY(h1_arready),
    .S_AXI_HP1_RID(h1_rid), .S_AXI_HP1_RDATA(h1_rdata), .S_AXI_HP1_RRESP(h1_rresp),
    .S_AXI_HP1_RLAST(h1_rlast), .S_AXI_HP1_RVALID(h1_rvalid),
    .S_AXI_HP1_RREADY(h1_rready),
    .S_AXI_HP1_RDISSUECAP1_EN(1'b0), .S_AXI_HP1_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP1_RACOUNT(), .S_AXI_HP1_RCOUNT(),
    .S_AXI_HP1_WACOUNT(), .S_AXI_HP1_WCOUNT(),
`endif
`ifdef PYNQZ2_NMEM4
  // channels 2 and 3 -- see the PYNQZ2_NMEM4 wire block.
`ifdef PYNQZ2_HAS_MEMCLK
    .S_AXI_HP2_ACLK(fclk_mem),
`else
    .S_AXI_HP2_ACLK(fclk),
`endif
    .S_AXI_HP2_AWID(h2_awid), .S_AXI_HP2_AWADDR(h2_awaddr), .S_AXI_HP2_AWLEN(h2_awlen),
    .S_AXI_HP2_AWSIZE(h2_awsize), .S_AXI_HP2_AWBURST(h2_awburst),
    .S_AXI_HP2_AWLOCK(h2_awlock), .S_AXI_HP2_AWCACHE(h2_awcache),
    .S_AXI_HP2_AWPROT(h2_awprot), .S_AXI_HP2_AWQOS(h2_awqos),
    .S_AXI_HP2_AWVALID(h2_awvalid), .S_AXI_HP2_AWREADY(h2_awready),
    .S_AXI_HP2_WID(h2_wid), .S_AXI_HP2_WDATA(h2_wdata), .S_AXI_HP2_WSTRB(h2_wstrb),
    .S_AXI_HP2_WLAST(h2_wlast), .S_AXI_HP2_WVALID(h2_wvalid),
    .S_AXI_HP2_WREADY(h2_wready),
    .S_AXI_HP2_BID(h2_bid), .S_AXI_HP2_BRESP(h2_bresp),
    .S_AXI_HP2_BVALID(h2_bvalid), .S_AXI_HP2_BREADY(h2_bready),
    .S_AXI_HP2_ARID(h2_arid), .S_AXI_HP2_ARADDR(h2_araddr), .S_AXI_HP2_ARLEN(h2_arlen),
    .S_AXI_HP2_ARSIZE(h2_arsize), .S_AXI_HP2_ARBURST(h2_arburst),
    .S_AXI_HP2_ARLOCK(h2_arlock), .S_AXI_HP2_ARCACHE(h2_arcache),
    .S_AXI_HP2_ARPROT(h2_arprot), .S_AXI_HP2_ARQOS(h2_arqos),
    .S_AXI_HP2_ARVALID(h2_arvalid), .S_AXI_HP2_ARREADY(h2_arready),
    .S_AXI_HP2_RID(h2_rid), .S_AXI_HP2_RDATA(h2_rdata), .S_AXI_HP2_RRESP(h2_rresp),
    .S_AXI_HP2_RLAST(h2_rlast), .S_AXI_HP2_RVALID(h2_rvalid),
    .S_AXI_HP2_RREADY(h2_rready),
    .S_AXI_HP2_RDISSUECAP1_EN(1'b0), .S_AXI_HP2_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP2_RACOUNT(), .S_AXI_HP2_RCOUNT(),
    .S_AXI_HP2_WACOUNT(), .S_AXI_HP2_WCOUNT(),
`ifdef PYNQZ2_HAS_MEMCLK
    .S_AXI_HP3_ACLK(fclk_mem),
`else
    .S_AXI_HP3_ACLK(fclk),
`endif
    .S_AXI_HP3_AWID(h3_awid), .S_AXI_HP3_AWADDR(h3_awaddr), .S_AXI_HP3_AWLEN(h3_awlen),
    .S_AXI_HP3_AWSIZE(h3_awsize), .S_AXI_HP3_AWBURST(h3_awburst),
    .S_AXI_HP3_AWLOCK(h3_awlock), .S_AXI_HP3_AWCACHE(h3_awcache),
    .S_AXI_HP3_AWPROT(h3_awprot), .S_AXI_HP3_AWQOS(h3_awqos),
    .S_AXI_HP3_AWVALID(h3_awvalid), .S_AXI_HP3_AWREADY(h3_awready),
    .S_AXI_HP3_WID(h3_wid), .S_AXI_HP3_WDATA(h3_wdata), .S_AXI_HP3_WSTRB(h3_wstrb),
    .S_AXI_HP3_WLAST(h3_wlast), .S_AXI_HP3_WVALID(h3_wvalid),
    .S_AXI_HP3_WREADY(h3_wready),
    .S_AXI_HP3_BID(h3_bid), .S_AXI_HP3_BRESP(h3_bresp),
    .S_AXI_HP3_BVALID(h3_bvalid), .S_AXI_HP3_BREADY(h3_bready),
    .S_AXI_HP3_ARID(h3_arid), .S_AXI_HP3_ARADDR(h3_araddr), .S_AXI_HP3_ARLEN(h3_arlen),
    .S_AXI_HP3_ARSIZE(h3_arsize), .S_AXI_HP3_ARBURST(h3_arburst),
    .S_AXI_HP3_ARLOCK(h3_arlock), .S_AXI_HP3_ARCACHE(h3_arcache),
    .S_AXI_HP3_ARPROT(h3_arprot), .S_AXI_HP3_ARQOS(h3_arqos),
    .S_AXI_HP3_ARVALID(h3_arvalid), .S_AXI_HP3_ARREADY(h3_arready),
    .S_AXI_HP3_RID(h3_rid), .S_AXI_HP3_RDATA(h3_rdata), .S_AXI_HP3_RRESP(h3_rresp),
    .S_AXI_HP3_RLAST(h3_rlast), .S_AXI_HP3_RVALID(h3_rvalid),
    .S_AXI_HP3_RREADY(h3_rready),
    .S_AXI_HP3_RDISSUECAP1_EN(1'b0), .S_AXI_HP3_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP3_RACOUNT(), .S_AXI_HP3_RCOUNT(),
    .S_AXI_HP3_WACOUNT(), .S_AXI_HP3_WCOUNT(),
`endif
`endif

    .MIO(), .DDR_CAS_n(), .DDR_CKE(), .DDR_Clk_n(), .DDR_Clk(), .DDR_CS_n(),
    .DDR_DRSTB(), .DDR_ODT(), .DDR_RAS_n(), .DDR_WEB(), .DDR_BankAddr(), .DDR_Addr(),
    .DDR_VRN(), .DDR_VRP(), .DDR_DM(), .DDR_DQ(), .DDR_DQS_n(), .DDR_DQS(),
    .PS_SRSTB(), .PS_CLK(), .PS_PORB()
  );
endmodule
