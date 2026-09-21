// Integration testbench: register file + self-test engine + AXI3 memory.
//
// Drives the design exactly the way software does -- through the GP0 register interface --
// and runs the engine MORE THAN ONCE. That last part is the point: the engine used to park
// in S_DONE after a run, where a start pulse was consumed merely returning to S_IDLE, so
// every second run silently did nothing. On hardware that looked like 64 KiB passing,
// 256 KiB timing out, 1 MiB passing, 4 MiB timing out, and so on.
//
// Run it with sim/run_dram_sim.sh.
`timescale 1ns/1ps

module tb_dramtest;
  localparam ID_W = 12, MID_W = 6, DATA_W = 64;
  localparam [31:0] REGION = 32'h1000_0000;

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;

  // ---- GP0 side ----
  logic [ID_W-1:0] awid = 0;  logic [31:0] awaddr = 0;
  logic awvalid = 0;          wire         awready;
  logic [31:0] wdata = 0;     logic [3:0]  wstrb = 4'hF;
  logic wlast = 0, wvalid = 0; wire        wready;
  wire [ID_W-1:0] bid;        wire [1:0]   bresp;   wire bvalid;  logic bready = 1;
  logic [ID_W-1:0] arid = 0;  logic [31:0] araddr = 0;
  logic arvalid = 0;          wire         arready;
  wire [31:0] rdata;          wire [1:0]   rresp;
  wire [ID_W-1:0] rid;        wire rlast, rvalid;   logic rready = 1;

  wire start;  wire [31:0] base_addr, num_bursts, err_count, beats_done;
  wire busy, done;

  axi_ctrl_regs #(.ADDR_W(32), .ID_W(ID_W)) regs (
    .clk(clk), .rstn(rstn),
    .s_awid(awid), .s_awaddr(awaddr), .s_awlen(8'd0),
    .s_awvalid(awvalid), .s_awready(awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
    .s_wvalid(wvalid), .s_wready(wready),
    .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_arid(arid), .s_araddr(araddr), .s_arlen(8'd0),
    .s_arvalid(arvalid), .s_arready(arready),
    .s_rdata(rdata), .s_rresp(rresp), .s_rid(rid), .s_rlast(rlast),
    .s_rvalid(rvalid), .s_rready(rready),
    .start(start), .base_addr(base_addr), .num_bursts(num_bursts),
    .busy(busy), .done(done), .err_count(err_count), .beats_done(beats_done)
  );

  // ---- HP0 side ----
  wire [MID_W-1:0] m_awid, m_arid, m_bid, m_rid;
  wire [31:0] m_awaddr, m_araddr;
  wire [7:0]  m_awlen, m_arlen;
  wire [2:0]  m_awsize, m_arsize;  wire [1:0] m_awburst, m_arburst;
  wire        m_awvalid, m_awready, m_arvalid, m_arready;
  wire [DATA_W-1:0] m_wdata, m_rdata;
  wire [DATA_W/8-1:0] m_wstrb;
  wire m_wlast, m_wvalid, m_wready, m_bvalid, m_bready, m_rlast, m_rvalid, m_rready;
  wire [1:0] m_bresp, m_rresp;

  axi_dram_selftest #(.ADDR_W(32), .DATA_W(DATA_W), .ID_W(MID_W), .BURSTLEN(8'd7)) eng (
    .clk(clk), .rstn(rstn),
    .start(start), .base_addr(base_addr), .num_bursts(num_bursts),
    .busy(busy), .done(done), .err_count(err_count), .beats_done(beats_done),
    .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
    .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
    .m_wready(m_wready),
    .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
    .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
    .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid),
    .m_rready(m_rready)
  );

  // HP0 is AXI3: 4-bit LEN, exactly as the real top truncates it.
  axi3_slave_mem #(.ADDR_W(32), .DATA_W(DATA_W), .ID_W(MID_W),
                   .MEM_KB(64), .BASE(REGION)) mem (
    .clk(clk), .rstn(rstn),
    .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen[3:0]), .awvalid(m_awvalid),
    .awready(m_awready),
    .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
    .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
    .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen[3:0]), .arvalid(m_arvalid),
    .arready(m_arready),
    .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready)
  );

  int errors = 0;
  task automatic chk(input logic cond, input string what);
    if (!cond) begin $display("  FAIL  %s", what); errors++; end
    else         $display("  pass  %s", what);
  endtask

  task automatic wr(input [31:0] a, input [31:0] d_in);
    @(negedge clk); awaddr = a; awid = 1; awvalid = 1;
    while (!awready) @(negedge clk);
    @(negedge clk); awvalid = 0;
    wdata = d_in; wstrb = 4'hF; wlast = 1; wvalid = 1;
    while (!wready) @(negedge clk);
    @(negedge clk); wvalid = 0; wlast = 0;
    while (!bvalid) @(negedge clk);
    @(negedge clk);
  endtask

  task automatic rd(input [31:0] a, output [31:0] d_out);
    @(negedge clk); araddr = a; arid = 2; arvalid = 1;
    while (!arready) @(negedge clk);
    @(negedge clk); arvalid = 0;
    while (!rvalid) @(negedge clk);
    d_out = rdata;
    @(negedge clk);
  endtask

  // One full run, driven the way host/run_dramtest.py drives it.
  task automatic do_run(input int nbursts, input string label);
    logic [31:0] runs0, runs1, st, errs, beats;
    int cycles;
    wr(32'h04, REGION);
    wr(32'h08, nbursts);
    rd(32'h1C, runs0);
    wr(32'h00, 32'd1);                      // CTRL.start
    cycles = 0;
    forever begin
      rd(32'h1C, runs1);
      if (runs1 != runs0) break;
      cycles++;
      if (cycles > 20000) begin
        rd(32'h0C, st); rd(32'h14, beats);
        $display("  FAIL  %s: engine never ran (RUNS stuck at %0d, status=0x%0h, beats=%0d)",
                 label, runs0, st, beats);
        errors++;
        return;
      end
    end
    rd(32'h10, errs);
    rd(32'h14, beats);
    chk(errs === 32'd0, $sformatf("%s: ERRCNT == 0 (got %0d)", label, errs));
    chk(beats === nbursts * 16,
        $sformatf("%s: beats == %0d (got %0d)", label, nbursts * 16, beats));
    chk(runs1 === runs0 + 1, $sformatf("%s: RUNS advanced by one", label));
  endtask

  logic [31:0] d;

  initial begin
    repeat (5) @(negedge clk);
    rstn = 1;
    repeat (2) @(negedge clk);

    rd(32'h18, d);
    chk(d === 32'h5A5A_0001, $sformatf("MAGIC (got 0x%08X)", d));

    // Four consecutive runs of DIFFERENT sizes. Before the S_DONE fix, runs 2 and 4
    // never started -- which is exactly what the board did.
    $display("\n-- four consecutive runs through the register interface --");
    do_run(16,  "run 1 (16 bursts)");
    do_run(32,  "run 2 (32 bursts)");
    do_run(8,   "run 3 (8 bursts)");
    do_run(64,  "run 4 (64 bursts)");

    $display("\n-- a repeat of the same size must also re-run --");
    do_run(64,  "run 5 (64 bursts again)");

    $display("\n==================================================");
    if (errors == 0) begin
      $display("ALL CHECKS PASSED");
      $display("==================================================");
      $finish;
    end else begin
      $display("==================================================");
      $fatal(1, "*** %0d CHECK(S) FAILED ***", errors);
    end
  end

  initial begin
    #5000000;
    $fatal(1, "*** TESTBENCH TIMEOUT ***");
  end
endmodule
