// axiceil_top -- PYNQ-Z1 top level for the interface-ceiling instrument (MAGIC 0x5A5A0020).
//
// MEMORY_BANDWIDTH.md section 7.  PS7 + axiceil_core: four raw AXI3 masters, one on each of
// S_AXI_HP0..HP3, and nothing else in the PL.  No SoC, no TileLink, no L2, no shim.
//
// Everything runs on FCLK0.  The HP ports' AFIs cross into the PS internally, so the fabric
// clock can be swept at run time (pynq.ps.Clocks, read back with host/fclk.py) down from
// the frequency this build closes timing at, with no rebuild.
//
// Why all four ports in one bitstream: HP0 alone, HP0+HP1 (one DDR controller port),
// HP0+HP2 (two) and all four are then one register write apart, on identical silicon and
// placement.  The comparison that matters most -- whether a second HP port on the same DDR
// controller port buys anything -- is not confounded by a rebuild.
//
// Address safety lives in axiceil_guard, one per port, inside axiceil_core.

module axiceil_top (
  output wire [3:0] leds
);
  wire fclk, rstn;

  wire [11:0] gp0_awid, gp0_arid, gp0_wid, gp0_bid, gp0_rid;
  wire [31:0] gp0_awaddr, gp0_araddr, gp0_wdata, gp0_rdata;
  wire [3:0]  gp0_awlen, gp0_arlen, gp0_wstrb;
  wire        gp0_awvalid, gp0_awready, gp0_wvalid, gp0_wready, gp0_wlast;
  wire        gp0_bvalid, gp0_bready, gp0_arvalid, gp0_arready;
  wire        gp0_rvalid, gp0_rready, gp0_rlast;
  wire [1:0]  gp0_bresp, gp0_rresp;

  wire [23:0]  hp_awid, hp_wid, hp_bid, hp_arid, hp_rid, hp_wacount;
  wire [127:0] hp_awaddr, hp_araddr;
  wire [15:0]  hp_awlen, hp_arlen;
  wire [255:0] hp_wdata, hp_rdata;
  wire [7:0]   hp_bresp, hp_rresp;
  wire [3:0]   hp_awvalid, hp_awready, hp_wlast, hp_wvalid, hp_wready, hp_bvalid, hp_bready;
  wire [3:0]   hp_arvalid, hp_arready, hp_rlast, hp_rvalid, hp_rready;
  wire [11:0]  hp_racount;
  wire [31:0]  hp_rcount, hp_wcount;

  axiceil_core #(.N_PORTS(4), .MAGIC(32'h5A5A_0020)) u_core (
    .clk(fclk), .rstn(rstn),
    .s_awid(gp0_awid), .s_awaddr(gp0_awaddr), .s_awlen(gp0_awlen),
    .s_awvalid(gp0_awvalid), .s_awready(gp0_awready),
    .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(gp0_wlast),
    .s_wvalid(gp0_wvalid), .s_wready(gp0_wready),
    .s_bid(gp0_bid), .s_bresp(gp0_bresp), .s_bvalid(gp0_bvalid), .s_bready(gp0_bready),
    .s_arid(gp0_arid), .s_araddr(gp0_araddr), .s_arlen(gp0_arlen),
    .s_arvalid(gp0_arvalid), .s_arready(gp0_arready),
    .s_rdata(gp0_rdata), .s_rresp(gp0_rresp), .s_rid(gp0_rid), .s_rlast(gp0_rlast),
    .s_rvalid(gp0_rvalid), .s_rready(gp0_rready),
    .hp_awid(hp_awid), .hp_awaddr(hp_awaddr), .hp_awlen(hp_awlen), .hp_awvalid(hp_awvalid),
    .hp_awready(hp_awready), .hp_wid(hp_wid), .hp_wdata(hp_wdata), .hp_wlast(hp_wlast),
    .hp_wvalid(hp_wvalid), .hp_wready(hp_wready), .hp_bid(hp_bid), .hp_bresp(hp_bresp),
    .hp_bvalid(hp_bvalid), .hp_bready(hp_bready), .hp_arid(hp_arid), .hp_araddr(hp_araddr),
    .hp_arlen(hp_arlen), .hp_arvalid(hp_arvalid), .hp_arready(hp_arready), .hp_rid(hp_rid),
    .hp_rdata(hp_rdata), .hp_rresp(hp_rresp), .hp_rlast(hp_rlast), .hp_rvalid(hp_rvalid),
    .hp_rready(hp_rready), .hp_racount(hp_racount), .hp_rcount(hp_rcount),
    .hp_wacount(hp_wacount), .hp_wcount(hp_wcount),
    .leds(leds)
  );

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

    // ---- S_AXI_HP0: master 0.  DDR controller port 3 (HP0+HP1 share port 3, HP2+HP3 port 2)
    .S_AXI_HP0_ACLK(fclk),
    .S_AXI_HP0_AWID(hp_awid[5:0]), .S_AXI_HP0_AWADDR(hp_awaddr[31:0]),
    .S_AXI_HP0_AWLEN(hp_awlen[3:0]), .S_AXI_HP0_AWSIZE(3'b011), .S_AXI_HP0_AWBURST(2'b01),
    .S_AXI_HP0_AWLOCK(2'b00), .S_AXI_HP0_AWCACHE(4'b0011), .S_AXI_HP0_AWPROT(3'b000),
    .S_AXI_HP0_AWQOS(4'b0000), .S_AXI_HP0_AWVALID(hp_awvalid[0]), .S_AXI_HP0_AWREADY(hp_awready[0]),
    .S_AXI_HP0_WID(hp_wid[5:0]), .S_AXI_HP0_WDATA(hp_wdata[63:0]),
    .S_AXI_HP0_WSTRB(8'hFF), .S_AXI_HP0_WLAST(hp_wlast[0]), .S_AXI_HP0_WVALID(hp_wvalid[0]),
    .S_AXI_HP0_WREADY(hp_wready[0]),
    .S_AXI_HP0_BID(hp_bid[5:0]), .S_AXI_HP0_BRESP(hp_bresp[1:0]),
    .S_AXI_HP0_BVALID(hp_bvalid[0]), .S_AXI_HP0_BREADY(hp_bready[0]),
    .S_AXI_HP0_ARID(hp_arid[5:0]), .S_AXI_HP0_ARADDR(hp_araddr[31:0]),
    .S_AXI_HP0_ARLEN(hp_arlen[3:0]), .S_AXI_HP0_ARSIZE(3'b011), .S_AXI_HP0_ARBURST(2'b01),
    .S_AXI_HP0_ARLOCK(2'b00), .S_AXI_HP0_ARCACHE(4'b0011), .S_AXI_HP0_ARPROT(3'b000),
    .S_AXI_HP0_ARQOS(4'b0000), .S_AXI_HP0_ARVALID(hp_arvalid[0]), .S_AXI_HP0_ARREADY(hp_arready[0]),
    .S_AXI_HP0_RID(hp_rid[5:0]), .S_AXI_HP0_RDATA(hp_rdata[63:0]),
    .S_AXI_HP0_RRESP(hp_rresp[1:0]), .S_AXI_HP0_RLAST(hp_rlast[0]),
    .S_AXI_HP0_RVALID(hp_rvalid[0]), .S_AXI_HP0_RREADY(hp_rready[0]),
    .S_AXI_HP0_RDISSUECAP1_EN(1'b0), .S_AXI_HP0_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP0_RACOUNT(hp_racount[2:0]), .S_AXI_HP0_RCOUNT(hp_rcount[7:0]),
    .S_AXI_HP0_WACOUNT(hp_wacount[5:0]), .S_AXI_HP0_WCOUNT(hp_wcount[7:0]),
    // ---- S_AXI_HP1: master 1.  DDR controller port 3 (HP0+HP1 share port 3, HP2+HP3 port 2)
    .S_AXI_HP1_ACLK(fclk),
    .S_AXI_HP1_AWID(hp_awid[11:6]), .S_AXI_HP1_AWADDR(hp_awaddr[63:32]),
    .S_AXI_HP1_AWLEN(hp_awlen[7:4]), .S_AXI_HP1_AWSIZE(3'b011), .S_AXI_HP1_AWBURST(2'b01),
    .S_AXI_HP1_AWLOCK(2'b00), .S_AXI_HP1_AWCACHE(4'b0011), .S_AXI_HP1_AWPROT(3'b000),
    .S_AXI_HP1_AWQOS(4'b0000), .S_AXI_HP1_AWVALID(hp_awvalid[1]), .S_AXI_HP1_AWREADY(hp_awready[1]),
    .S_AXI_HP1_WID(hp_wid[11:6]), .S_AXI_HP1_WDATA(hp_wdata[127:64]),
    .S_AXI_HP1_WSTRB(8'hFF), .S_AXI_HP1_WLAST(hp_wlast[1]), .S_AXI_HP1_WVALID(hp_wvalid[1]),
    .S_AXI_HP1_WREADY(hp_wready[1]),
    .S_AXI_HP1_BID(hp_bid[11:6]), .S_AXI_HP1_BRESP(hp_bresp[3:2]),
    .S_AXI_HP1_BVALID(hp_bvalid[1]), .S_AXI_HP1_BREADY(hp_bready[1]),
    .S_AXI_HP1_ARID(hp_arid[11:6]), .S_AXI_HP1_ARADDR(hp_araddr[63:32]),
    .S_AXI_HP1_ARLEN(hp_arlen[7:4]), .S_AXI_HP1_ARSIZE(3'b011), .S_AXI_HP1_ARBURST(2'b01),
    .S_AXI_HP1_ARLOCK(2'b00), .S_AXI_HP1_ARCACHE(4'b0011), .S_AXI_HP1_ARPROT(3'b000),
    .S_AXI_HP1_ARQOS(4'b0000), .S_AXI_HP1_ARVALID(hp_arvalid[1]), .S_AXI_HP1_ARREADY(hp_arready[1]),
    .S_AXI_HP1_RID(hp_rid[11:6]), .S_AXI_HP1_RDATA(hp_rdata[127:64]),
    .S_AXI_HP1_RRESP(hp_rresp[3:2]), .S_AXI_HP1_RLAST(hp_rlast[1]),
    .S_AXI_HP1_RVALID(hp_rvalid[1]), .S_AXI_HP1_RREADY(hp_rready[1]),
    .S_AXI_HP1_RDISSUECAP1_EN(1'b0), .S_AXI_HP1_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP1_RACOUNT(hp_racount[5:3]), .S_AXI_HP1_RCOUNT(hp_rcount[15:8]),
    .S_AXI_HP1_WACOUNT(hp_wacount[11:6]), .S_AXI_HP1_WCOUNT(hp_wcount[15:8]),
    // ---- S_AXI_HP2: master 2.  DDR controller port 2 (HP0+HP1 share port 3, HP2+HP3 port 2)
    .S_AXI_HP2_ACLK(fclk),
    .S_AXI_HP2_AWID(hp_awid[17:12]), .S_AXI_HP2_AWADDR(hp_awaddr[95:64]),
    .S_AXI_HP2_AWLEN(hp_awlen[11:8]), .S_AXI_HP2_AWSIZE(3'b011), .S_AXI_HP2_AWBURST(2'b01),
    .S_AXI_HP2_AWLOCK(2'b00), .S_AXI_HP2_AWCACHE(4'b0011), .S_AXI_HP2_AWPROT(3'b000),
    .S_AXI_HP2_AWQOS(4'b0000), .S_AXI_HP2_AWVALID(hp_awvalid[2]), .S_AXI_HP2_AWREADY(hp_awready[2]),
    .S_AXI_HP2_WID(hp_wid[17:12]), .S_AXI_HP2_WDATA(hp_wdata[191:128]),
    .S_AXI_HP2_WSTRB(8'hFF), .S_AXI_HP2_WLAST(hp_wlast[2]), .S_AXI_HP2_WVALID(hp_wvalid[2]),
    .S_AXI_HP2_WREADY(hp_wready[2]),
    .S_AXI_HP2_BID(hp_bid[17:12]), .S_AXI_HP2_BRESP(hp_bresp[5:4]),
    .S_AXI_HP2_BVALID(hp_bvalid[2]), .S_AXI_HP2_BREADY(hp_bready[2]),
    .S_AXI_HP2_ARID(hp_arid[17:12]), .S_AXI_HP2_ARADDR(hp_araddr[95:64]),
    .S_AXI_HP2_ARLEN(hp_arlen[11:8]), .S_AXI_HP2_ARSIZE(3'b011), .S_AXI_HP2_ARBURST(2'b01),
    .S_AXI_HP2_ARLOCK(2'b00), .S_AXI_HP2_ARCACHE(4'b0011), .S_AXI_HP2_ARPROT(3'b000),
    .S_AXI_HP2_ARQOS(4'b0000), .S_AXI_HP2_ARVALID(hp_arvalid[2]), .S_AXI_HP2_ARREADY(hp_arready[2]),
    .S_AXI_HP2_RID(hp_rid[17:12]), .S_AXI_HP2_RDATA(hp_rdata[191:128]),
    .S_AXI_HP2_RRESP(hp_rresp[5:4]), .S_AXI_HP2_RLAST(hp_rlast[2]),
    .S_AXI_HP2_RVALID(hp_rvalid[2]), .S_AXI_HP2_RREADY(hp_rready[2]),
    .S_AXI_HP2_RDISSUECAP1_EN(1'b0), .S_AXI_HP2_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP2_RACOUNT(hp_racount[8:6]), .S_AXI_HP2_RCOUNT(hp_rcount[23:16]),
    .S_AXI_HP2_WACOUNT(hp_wacount[17:12]), .S_AXI_HP2_WCOUNT(hp_wcount[23:16]),
    // ---- S_AXI_HP3: master 3.  DDR controller port 2 (HP0+HP1 share port 3, HP2+HP3 port 2)
    .S_AXI_HP3_ACLK(fclk),
    .S_AXI_HP3_AWID(hp_awid[23:18]), .S_AXI_HP3_AWADDR(hp_awaddr[127:96]),
    .S_AXI_HP3_AWLEN(hp_awlen[15:12]), .S_AXI_HP3_AWSIZE(3'b011), .S_AXI_HP3_AWBURST(2'b01),
    .S_AXI_HP3_AWLOCK(2'b00), .S_AXI_HP3_AWCACHE(4'b0011), .S_AXI_HP3_AWPROT(3'b000),
    .S_AXI_HP3_AWQOS(4'b0000), .S_AXI_HP3_AWVALID(hp_awvalid[3]), .S_AXI_HP3_AWREADY(hp_awready[3]),
    .S_AXI_HP3_WID(hp_wid[23:18]), .S_AXI_HP3_WDATA(hp_wdata[255:192]),
    .S_AXI_HP3_WSTRB(8'hFF), .S_AXI_HP3_WLAST(hp_wlast[3]), .S_AXI_HP3_WVALID(hp_wvalid[3]),
    .S_AXI_HP3_WREADY(hp_wready[3]),
    .S_AXI_HP3_BID(hp_bid[23:18]), .S_AXI_HP3_BRESP(hp_bresp[7:6]),
    .S_AXI_HP3_BVALID(hp_bvalid[3]), .S_AXI_HP3_BREADY(hp_bready[3]),
    .S_AXI_HP3_ARID(hp_arid[23:18]), .S_AXI_HP3_ARADDR(hp_araddr[127:96]),
    .S_AXI_HP3_ARLEN(hp_arlen[15:12]), .S_AXI_HP3_ARSIZE(3'b011), .S_AXI_HP3_ARBURST(2'b01),
    .S_AXI_HP3_ARLOCK(2'b00), .S_AXI_HP3_ARCACHE(4'b0011), .S_AXI_HP3_ARPROT(3'b000),
    .S_AXI_HP3_ARQOS(4'b0000), .S_AXI_HP3_ARVALID(hp_arvalid[3]), .S_AXI_HP3_ARREADY(hp_arready[3]),
    .S_AXI_HP3_RID(hp_rid[23:18]), .S_AXI_HP3_RDATA(hp_rdata[255:192]),
    .S_AXI_HP3_RRESP(hp_rresp[7:6]), .S_AXI_HP3_RLAST(hp_rlast[3]),
    .S_AXI_HP3_RVALID(hp_rvalid[3]), .S_AXI_HP3_RREADY(hp_rready[3]),
    .S_AXI_HP3_RDISSUECAP1_EN(1'b0), .S_AXI_HP3_WRISSUECAP1_EN(1'b0),
    .S_AXI_HP3_RACOUNT(hp_racount[11:9]), .S_AXI_HP3_RCOUNT(hp_rcount[31:24]),
    .S_AXI_HP3_WACOUNT(hp_wacount[23:18]), .S_AXI_HP3_WCOUNT(hp_wcount[31:24]),

    .MIO(), .DDR_CAS_n(), .DDR_CKE(), .DDR_Clk_n(), .DDR_Clk(), .DDR_CS_n(),
    .DDR_DRSTB(), .DDR_ODT(), .DDR_RAS_n(), .DDR_WEB(), .DDR_BankAddr(), .DDR_Addr(),
    .DDR_VRN(), .DDR_VRP(), .DDR_DM(), .DDR_DQ(), .DDR_DQS_n(), .DDR_DQS(),
    .PS_SRSTB(), .PS_CLK(), .PS_PORB()
  );
endmodule
