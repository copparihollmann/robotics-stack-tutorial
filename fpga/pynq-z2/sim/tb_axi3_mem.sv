// Datapath test: the self-test master against a behavioural AXI3 memory.
//
// Proves the thing the PS7 VIP cannot in Vivado 2023.1 (its DDR model cannot be powered
// up from a testbench): that every byte the master writes comes back byte-for-byte,
// through 4-bit-LEN AXI3 bursts shaped exactly as S_AXI_HP0 will see them.
//
// Same RTL as the bitstream, unmodified.

`timescale 1ns/1ps

module tb_axi3_mem;
  localparam int NBURSTS = 64;                 // 64 * 64 B = 4 KB
  localparam [31:0] BASE = 32'h1000_0000;

  logic clk = 0, rstn = 0;
  always #10 clk = ~clk;                       // 50 MHz, matching FCLK_CLK0

  logic        start = 0, busy, done;
  logic [31:0] err_count, beats_done;

  wire [5:0]  awid, arid, bid, rid;
  wire [31:0] awaddr, araddr;
  wire [7:0]  awlen8, arlen8;
  wire [63:0] wdata, rdata;
  wire [7:0]  wstrb;
  wire [2:0]  awsize, arsize;
  wire [1:0]  awburst, arburst, bresp, rresp;
  wire        awvalid, awready, wvalid, wready, wlast;
  wire        bvalid, bready, arvalid, arready, rvalid, rready, rlast;

  axi_dram_selftest #(.ADDR_W(32), .DATA_W(64), .ID_W(6), .BURSTLEN(8'd7)) dut (
    .clk(clk), .rstn(rstn),
    .start(start), .base_addr(BASE), .num_bursts(NBURSTS),
    .busy(busy), .done(done), .err_count(err_count), .beats_done(beats_done),
    .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen8), .m_awsize(awsize),
    .m_awburst(awburst), .m_awvalid(awvalid), .m_awready(awready),
    .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
    .m_wready(wready),
    .m_bid(bid), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
    .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen8), .m_arsize(arsize),
    .m_arburst(arburst), .m_arvalid(arvalid), .m_arready(arready),
    .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
    .m_rready(rready)
  );

  // AXI3: only the low 4 bits of LEN exist on the real port.
  axi3_slave_mem #(.MEM_KB(64), .BASE(BASE)) mem (
    .clk(clk), .rstn(rstn),
    .awid(awid), .awaddr(awaddr), .awlen(awlen8[3:0]), .awvalid(awvalid),
    .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .arid(arid), .araddr(araddr), .arlen(arlen8[3:0]), .arvalid(arvalid),
    .arready(arready),
    .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
  );

  // Independent check that the master never exceeds what AXI3 can encode.
  always @(posedge clk) if (rstn) begin
    if (awvalid && awlen8 > 8'd15) begin
      $display("AXI3_MEM_TEST: FAIL -- AWLEN=%0d exceeds the AXI3 16-beat limit", awlen8);
      $finish;
    end
    if (arvalid && arlen8 > 8'd15) begin
      $display("AXI3_MEM_TEST: FAIL -- ARLEN=%0d exceeds the AXI3 16-beat limit", arlen8);
      $finish;
    end
  end

  initial begin
    repeat (10) @(posedge clk);
    rstn = 1;
    repeat (5) @(posedge clk);
    $display("[TB] start: %0d bursts @ 0x%08x", NBURSTS, BASE);
    @(posedge clk) start <= 1;
    @(posedge clk) start <= 0;

    wait (done === 1'b1);
    repeat (3) @(posedge clk);
    $display("[TB] beats=%0d (expect %0d)  errors=%0d", beats_done, NBURSTS*8*2, err_count);
    if (err_count == 0 && beats_done == NBURSTS*8*2)
      $display("AXI3_MEM_TEST: PASS");
    else
      $display("AXI3_MEM_TEST: FAIL");
    $finish;
  end

  initial begin
    #5_000_000;
    $display("AXI3_MEM_TEST: TIMEOUT (beats=%0d busy=%0b done=%0b)", beats_done, busy, done);
    $finish;
  end
endmodule
