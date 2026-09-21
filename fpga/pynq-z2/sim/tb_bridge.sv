// Datapath test across the AXI4 -> AXI3 bridge, with Rocket-shaped traffic.
//
//   axi_dram_selftest (AXI4 master, 8-beat 64-bit bursts = one 64 B cache line)
//        -> axi4_to_axi3            (the bridge that goes in the bitstream)
//        -> axi3_slave_mem          (a strict AXI3 slave: 4-bit LEN only)
//
// The slave's LEN port is 4 bits wide, so if the bridge ever presented a longer burst the
// value would be silently truncated and the data would land in the wrong place -- which is
// exactly the corruption this is checking cannot happen. WID is checked too: the slave
// ignores it, so a separate monitor asserts it matches the AWID of the burst in flight.

`timescale 1ns/1ps

module tb_bridge;
  localparam int NBURSTS = 64;
  localparam [31:0] BASE = 32'h1000_0000;

  logic clk = 0, rstn = 0;
  always #12.5 clk = ~clk;                 // 40 MHz, matching the built design

  logic        start = 0, busy, done;
  logic [31:0] err_count, beats_done;

  // AXI4 side
  wire [5:0]  a4_awid, a4_arid;
  wire [31:0] a4_awaddr, a4_araddr;
  wire [7:0]  a4_awlen, a4_arlen;
  wire [2:0]  a4_awsize, a4_arsize;
  wire [1:0]  a4_awburst, a4_arburst, a4_bresp, a4_rresp;
  wire [63:0] a4_wdata, a4_rdata;
  wire [7:0]  a4_wstrb;
  wire        a4_awvalid, a4_awready, a4_wvalid, a4_wready, a4_wlast;
  wire        a4_bvalid, a4_bready, a4_arvalid, a4_arready, a4_rvalid, a4_rready, a4_rlast;
  wire [5:0]  a4_bid, a4_rid;

  // AXI3 side
  wire [5:0]  a3_awid, a3_arid, a3_wid, a3_bid, a3_rid;
  wire [31:0] a3_awaddr, a3_araddr;
  wire [3:0]  a3_awlen, a3_arlen, a3_awcache, a3_arcache, a3_awqos, a3_arqos;
  wire [2:0]  a3_awsize, a3_arsize, a3_awprot, a3_arprot;
  wire [1:0]  a3_awburst, a3_arburst, a3_awlock, a3_arlock, a3_bresp, a3_rresp;
  wire [63:0] a3_wdata, a3_rdata;
  wire [7:0]  a3_wstrb;
  wire        a3_awvalid, a3_awready, a3_wvalid, a3_wready, a3_wlast;
  wire        a3_bvalid, a3_bready, a3_arvalid, a3_arready, a3_rvalid, a3_rready, a3_rlast;
  wire        err_burst_too_long;

  axi_dram_selftest #(.ADDR_W(32), .DATA_W(64), .ID_W(6), .BURSTLEN(8'd7)) master (
    .clk(clk), .rstn(rstn),
    .start(start), .base_addr(BASE), .num_bursts(NBURSTS),
    .busy(busy), .done(done), .err_count(err_count), .beats_done(beats_done),
    .m_awid(a4_awid), .m_awaddr(a4_awaddr), .m_awlen(a4_awlen), .m_awsize(a4_awsize),
    .m_awburst(a4_awburst), .m_awvalid(a4_awvalid), .m_awready(a4_awready),
    .m_wdata(a4_wdata), .m_wstrb(a4_wstrb), .m_wlast(a4_wlast), .m_wvalid(a4_wvalid),
    .m_wready(a4_wready),
    .m_bid(a4_bid), .m_bresp(a4_bresp), .m_bvalid(a4_bvalid), .m_bready(a4_bready),
    .m_arid(a4_arid), .m_araddr(a4_araddr), .m_arlen(a4_arlen), .m_arsize(a4_arsize),
    .m_arburst(a4_arburst), .m_arvalid(a4_arvalid), .m_arready(a4_arready),
    .m_rdata(a4_rdata), .m_rresp(a4_rresp), .m_rlast(a4_rlast), .m_rvalid(a4_rvalid),
    .m_rready(a4_rready)
  );

  axi4_to_axi3 #(.ADDR_W(32), .DATA_W(64), .ID_W(6)) dut (
    .clk(clk), .rstn(rstn),
    .s_awid(a4_awid), .s_awaddr(a4_awaddr), .s_awlen(a4_awlen), .s_awsize(a4_awsize),
    .s_awburst(a4_awburst), .s_awlock(1'b0), .s_awcache(4'b0011), .s_awprot(3'b000),
    .s_awqos(4'b0000), .s_awvalid(a4_awvalid), .s_awready(a4_awready),
    .s_wdata(a4_wdata), .s_wstrb(a4_wstrb), .s_wlast(a4_wlast), .s_wvalid(a4_wvalid),
    .s_wready(a4_wready),
    .s_bid(a4_bid), .s_bresp(a4_bresp), .s_bvalid(a4_bvalid), .s_bready(a4_bready),
    .s_arid(a4_arid), .s_araddr(a4_araddr), .s_arlen(a4_arlen), .s_arsize(a4_arsize),
    .s_arburst(a4_arburst), .s_arlock(1'b0), .s_arcache(4'b0011), .s_arprot(3'b000),
    .s_arqos(4'b0000), .s_arvalid(a4_arvalid), .s_arready(a4_arready),
    .s_rdata(a4_rdata), .s_rresp(a4_rresp), .s_rlast(a4_rlast), .s_rvalid(a4_rvalid),
    .s_rready(a4_rready),
    .m_awid(a3_awid), .m_awaddr(a3_awaddr), .m_awlen(a3_awlen), .m_awsize(a3_awsize),
    .m_awburst(a3_awburst), .m_awlock(a3_awlock), .m_awcache(a3_awcache),
    .m_awprot(a3_awprot), .m_awqos(a3_awqos),
    .m_awvalid(a3_awvalid), .m_awready(a3_awready),
    .m_wid(a3_wid), .m_wdata(a3_wdata), .m_wstrb(a3_wstrb), .m_wlast(a3_wlast),
    .m_wvalid(a3_wvalid), .m_wready(a3_wready),
    .m_bid(a3_bid), .m_bresp(a3_bresp), .m_bvalid(a3_bvalid), .m_bready(a3_bready),
    .m_arid(a3_arid), .m_araddr(a3_araddr), .m_arlen(a3_arlen), .m_arsize(a3_arsize),
    .m_arburst(a3_arburst), .m_arlock(a3_arlock), .m_arcache(a3_arcache),
    .m_arprot(a3_arprot), .m_arqos(a3_arqos),
    .m_arvalid(a3_arvalid), .m_arready(a3_arready),
    .m_rdata(a3_rdata), .m_rresp(a3_rresp), .m_rlast(a3_rlast), .m_rvalid(a3_rvalid),
    .m_rready(a3_rready),
    .err_burst_too_long(err_burst_too_long)
  );

  axi3_slave_mem #(.MEM_KB(64), .BASE(BASE)) mem (
    .clk(clk), .rstn(rstn),
    .awid(a3_awid), .awaddr(a3_awaddr), .awlen(a3_awlen), .awvalid(a3_awvalid),
    .awready(a3_awready),
    .wdata(a3_wdata), .wstrb(a3_wstrb), .wlast(a3_wlast), .wvalid(a3_wvalid),
    .wready(a3_wready),
    .bid(a3_bid), .bresp(a3_bresp), .bvalid(a3_bvalid), .bready(a3_bready),
    .arid(a3_arid), .araddr(a3_araddr), .arlen(a3_arlen), .arvalid(a3_arvalid),
    .arready(a3_arready),
    .rdata(a3_rdata), .rresp(a3_rresp), .rlast(a3_rlast), .rvalid(a3_rvalid),
    .rready(a3_rready)
  );

  // WID must equal the AWID of the burst currently streaming. The slave ignores WID, so
  // without this monitor a broken FIFO would go unnoticed here and only fail on silicon.
  reg [5:0] expect_wid; reg have_wid = 0;
  integer   wid_errors = 0;
  always @(posedge clk) if (rstn) begin
    if (a3_awvalid && a3_awready && !have_wid) begin
      expect_wid <= a3_awid; have_wid <= 1;
    end
    if (a3_wvalid && a3_wready) begin
      if (have_wid && a3_wid !== expect_wid) wid_errors = wid_errors + 1;
      if (a3_wlast) have_wid <= 0;
    end
  end

  initial begin
    repeat (10) @(posedge clk);
    rstn = 1;
    repeat (5) @(posedge clk);
    $display("[TB] AXI4->AXI3 bridge: %0d bursts of 8 beats @ 0x%08x", NBURSTS, BASE);
    @(posedge clk) start <= 1;
    @(posedge clk) start <= 0;

    wait (done === 1'b1);
    repeat (3) @(posedge clk);
    $display("[TB] beats=%0d (expect %0d)  data_errors=%0d  wid_errors=%0d  burst_too_long=%0b",
             beats_done, NBURSTS*8*2, err_count, wid_errors, err_burst_too_long);
    if (err_count == 0 && wid_errors == 0 && !err_burst_too_long &&
        beats_done == NBURSTS*8*2)
      $display("BRIDGE_TEST: PASS");
    else
      $display("BRIDGE_TEST: FAIL");
    $finish;
  end

  initial begin
    #10_000_000;
    $display("BRIDGE_TEST: TIMEOUT (beats=%0d done=%0b)", beats_done, done);
    $finish;
  end
endmodule
