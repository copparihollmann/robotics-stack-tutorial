// PYNQ-Z2 top level: PS7 + PL DRAM self-test.
//
// Purpose: a bitstream that can be loaded the day a board arrives and immediately answers
// the one question Chipyard has no precedent for -- can a PL master reach PS DDR through
// S_AXI_HP0 and read back what it wrote?
//
// PS7 has no PL-side pins to constrain: DDR and MIO are hard silicon on dedicated balls,
// so this design needs only the LED constraints. That is also why there is no MIG here --
// PYNQ-Z2 has no PL-side DRAM at all.
//
// AXI3, NOT AXI4. Both M_AXI_GP0 and S_AXI_HP0 on PS7 are AXI3:
//   * AWLEN/ARLEN are 4 bits (16-beat maximum), not 8
//   * a WID signal exists on the write-data channel and must match AWID
// A Chipyard/Rocket AXI4 memory port therefore cannot be wired straight to HP0. It needs
// burst fragmenting to <=16 beats and WID generation -- either Xilinx's
// axi_protocol_converter, or an AXI4Fragmenter plus an AXI4-to-AXI3 shim on the Chisel
// side. The self-test master below is written to AXI3 directly so this bitstream does not
// depend on that shim existing yet.

module pynqz2_top (
  output wire [3:0] leds
);

  // ---- PS7 <-> PL ----
  wire        fclk, rstn;

  // M_AXI_GP0 (PS master -> PL registers), AXI3, 32-bit
  wire [11:0] gp0_awid, gp0_arid, gp0_wid, gp0_bid, gp0_rid;
  wire [31:0] gp0_awaddr, gp0_araddr, gp0_wdata, gp0_rdata;
  wire [3:0]  gp0_awlen, gp0_arlen, gp0_wstrb;
  wire        gp0_awvalid, gp0_awready, gp0_wvalid, gp0_wready, gp0_wlast;
  wire        gp0_bvalid, gp0_bready, gp0_arvalid, gp0_arready;
  wire        gp0_rvalid, gp0_rready, gp0_rlast;
  wire [1:0]  gp0_bresp, gp0_rresp;

  // S_AXI_HP0 (PL master -> PS DDR), AXI3, 64-bit
  wire [5:0]  hp0_awid, hp0_arid, hp0_bid, hp0_rid;
  wire [31:0] hp0_awaddr, hp0_araddr;
  wire [7:0]  hp0_awlen_full, hp0_arlen_full;   // from the AXI4-style master
  wire [63:0] hp0_wdata, hp0_rdata;
  wire [7:0]  hp0_wstrb;
  wire [2:0]  hp0_awsize, hp0_arsize;
  wire [1:0]  hp0_awburst, hp0_arburst, hp0_bresp, hp0_rresp;
  wire        hp0_awvalid, hp0_awready, hp0_wvalid, hp0_wready, hp0_wlast;
  wire        hp0_bvalid, hp0_bready, hp0_arvalid, hp0_arready;
  wire        hp0_rvalid, hp0_rready, hp0_rlast;

  // ---- control/status ----
  wire        start, busy, done;
  wire [31:0] base_addr, num_bursts, err_count, beats_done;

  axi_ctrl_regs #(.ADDR_W(32), .ID_W(12)) u_regs (
    .clk(fclk), .rstn(rstn),
    .s_awid(gp0_awid), .s_awaddr(gp0_awaddr), .s_awlen({4'd0, gp0_awlen}),
    .s_awvalid(gp0_awvalid), .s_awready(gp0_awready),
    .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(gp0_wlast),
    .s_wvalid(gp0_wvalid), .s_wready(gp0_wready),
    .s_bid(gp0_bid), .s_bresp(gp0_bresp), .s_bvalid(gp0_bvalid), .s_bready(gp0_bready),
    .s_arid(gp0_arid), .s_araddr(gp0_araddr), .s_arlen({4'd0, gp0_arlen}),
    .s_arvalid(gp0_arvalid), .s_arready(gp0_arready),
    .s_rdata(gp0_rdata), .s_rresp(gp0_rresp), .s_rid(gp0_rid), .s_rlast(gp0_rlast),
    .s_rvalid(gp0_rvalid), .s_rready(gp0_rready),
    .start(start), .base_addr(base_addr), .num_bursts(num_bursts),
    .busy(busy), .done(done), .err_count(err_count), .beats_done(beats_done)
  );

  axi_dram_selftest #(.ADDR_W(32), .DATA_W(64), .ID_W(6), .BURSTLEN(8'd7)) u_test (
    .clk(fclk), .rstn(rstn),
    .start(start), .base_addr(base_addr), .num_bursts(num_bursts),
    .busy(busy), .done(done), .err_count(err_count), .beats_done(beats_done),
    .m_awid(hp0_awid), .m_awaddr(hp0_awaddr), .m_awlen(hp0_awlen_full),
    .m_awsize(hp0_awsize), .m_awburst(hp0_awburst), .m_awvalid(hp0_awvalid),
    .m_awready(hp0_awready),
    .m_wdata(hp0_wdata), .m_wstrb(hp0_wstrb), .m_wlast(hp0_wlast),
    .m_wvalid(hp0_wvalid), .m_wready(hp0_wready),
    .m_bid(hp0_bid), .m_bresp(hp0_bresp), .m_bvalid(hp0_bvalid), .m_bready(hp0_bready),
    .m_arid(hp0_arid), .m_araddr(hp0_araddr), .m_arlen(hp0_arlen_full),
    .m_arsize(hp0_arsize), .m_arburst(hp0_arburst), .m_arvalid(hp0_arvalid),
    .m_arready(hp0_arready),
    .m_rdata(hp0_rdata), .m_rresp(hp0_rresp), .m_rlast(hp0_rlast),
    .m_rvalid(hp0_rvalid), .m_rready(hp0_rready)
  );

  // Status on the LEDs so the board self-reports with nothing attached:
  //   LED0 heartbeat (PL clocked)   LED1 busy   LED2 done   LED3 error
  reg [25:0] hb;
  always @(posedge fclk) if (!rstn) hb <= 26'd0; else hb <= hb + 26'd1;
  assign leds = {(err_count != 32'd0), done, busy, hb[25]};

  ps7_0 u_ps7 (
    .FCLK_CLK0(fclk),
    .FCLK_RESET0_N(rstn),

    .M_AXI_GP0_ACLK(fclk),
    .M_AXI_GP0_AWID(gp0_awid), .M_AXI_GP0_AWADDR(gp0_awaddr), .M_AXI_GP0_AWLEN(gp0_awlen),
    .M_AXI_GP0_AWSIZE(), .M_AXI_GP0_AWBURST(), .M_AXI_GP0_AWLOCK(),
    .M_AXI_GP0_AWCACHE(), .M_AXI_GP0_AWPROT(), .M_AXI_GP0_AWQOS(),
    .M_AXI_GP0_AWVALID(gp0_awvalid), .M_AXI_GP0_AWREADY(gp0_awready),
    .M_AXI_GP0_WID(gp0_wid), .M_AXI_GP0_WDATA(gp0_wdata), .M_AXI_GP0_WSTRB(gp0_wstrb),
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

    .S_AXI_HP0_ACLK(fclk),
    // AXI3: LEN is 4 bits. The master is capped at 16-beat bursts, so this truncation
    // cannot lose information -- but it is the reason a raw AXI4 master will not work.
    .S_AXI_HP0_AWID(hp0_awid), .S_AXI_HP0_AWADDR(hp0_awaddr),
    .S_AXI_HP0_AWLEN(hp0_awlen_full[3:0]), .S_AXI_HP0_AWSIZE(hp0_awsize),
    .S_AXI_HP0_AWBURST(hp0_awburst), .S_AXI_HP0_AWLOCK(2'b00),
    .S_AXI_HP0_AWCACHE(4'b0011), .S_AXI_HP0_AWPROT(3'b000), .S_AXI_HP0_AWQOS(4'b0000),
    .S_AXI_HP0_AWVALID(hp0_awvalid), .S_AXI_HP0_AWREADY(hp0_awready),
    .S_AXI_HP0_WID(hp0_awid),          // AXI3 requires WID; single-outstanding so AWID holds
    .S_AXI_HP0_WDATA(hp0_wdata), .S_AXI_HP0_WSTRB(hp0_wstrb),
    .S_AXI_HP0_WLAST(hp0_wlast), .S_AXI_HP0_WVALID(hp0_wvalid),
    .S_AXI_HP0_WREADY(hp0_wready),
    .S_AXI_HP0_BID(hp0_bid), .S_AXI_HP0_BRESP(hp0_bresp),
    .S_AXI_HP0_BVALID(hp0_bvalid), .S_AXI_HP0_BREADY(hp0_bready),
    .S_AXI_HP0_ARID(hp0_arid), .S_AXI_HP0_ARADDR(hp0_araddr),
    .S_AXI_HP0_ARLEN(hp0_arlen_full[3:0]), .S_AXI_HP0_ARSIZE(hp0_arsize),
    .S_AXI_HP0_ARBURST(hp0_arburst), .S_AXI_HP0_ARLOCK(2'b00),
    .S_AXI_HP0_ARCACHE(4'b0011), .S_AXI_HP0_ARPROT(3'b000), .S_AXI_HP0_ARQOS(4'b0000),
    .S_AXI_HP0_ARVALID(hp0_arvalid), .S_AXI_HP0_ARREADY(hp0_arready),
    .S_AXI_HP0_RID(hp0_rid), .S_AXI_HP0_RDATA(hp0_rdata), .S_AXI_HP0_RRESP(hp0_rresp),
    .S_AXI_HP0_RLAST(hp0_rlast), .S_AXI_HP0_RVALID(hp0_rvalid),
    .S_AXI_HP0_RREADY(hp0_rready),
    // FIFO occupancy sidebands, unused
    .S_AXI_HP0_RDISSUECAP1_EN(1'b0), .S_AXI_HP0_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP0_RACOUNT(), .S_AXI_HP0_RCOUNT(),
    .S_AXI_HP0_WACOUNT(), .S_AXI_HP0_WCOUNT(),

    .MIO(), .DDR_CAS_n(), .DDR_CKE(), .DDR_Clk_n(), .DDR_Clk(), .DDR_CS_n(),
    .DDR_DRSTB(), .DDR_ODT(), .DDR_RAS_n(), .DDR_WEB(), .DDR_BankAddr(), .DDR_Addr(),
    .DDR_VRN(), .DDR_VRP(), .DDR_DM(), .DDR_DQ(), .DDR_DQS_n(), .DDR_DQS(),
    .PS_SRSTB(), .PS_CLK(), .PS_PORB()
  );
endmodule
