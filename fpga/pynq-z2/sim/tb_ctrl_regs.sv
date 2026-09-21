// Self-checking testbench for axi_ctrl_regs -- the PS7 M_AXI_GP0 register file.
//
// This exists because both hardware bugs found during Z1 bring-up were in this module and
// neither was simulated:
//
//   1. RID was never driven. The PS7 GP0 master issues non-zero ARIDs and will not retire
//      a read whose RID does not match, so the first register read locked the CPU hard.
//   2. W was accepted independently of AW. AXI allows write data to arrive before its
//      address and the PS does that, so a write landed in the register the PREVIOUS
//      transaction addressed -- the start bit went into num_bursts and the engine
//      never ran.
//
// Both are exercised below. Run it with sim/run_ctrl_sim.sh.
`timescale 1ns/1ps

module tb_ctrl_regs;
  localparam ID_W = 12;

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;                        // 100 MHz

  logic [ID_W-1:0] awid = 0;  logic [31:0] awaddr = 0;  logic [7:0] awlen = 0;
  logic awvalid = 0;          wire         awready;
  logic [31:0] wdata = 0;     logic [3:0]  wstrb = 4'hF;
  logic wlast = 0, wvalid = 0; wire        wready;
  wire [ID_W-1:0] bid;        wire [1:0]   bresp;
  wire bvalid;                logic        bready = 1;
  logic [ID_W-1:0] arid = 0;  logic [31:0] araddr = 0;  logic [7:0] arlen = 0;
  logic arvalid = 0;          wire         arready;
  wire [31:0] rdata;          wire [1:0]   rresp;
  wire [ID_W-1:0] rid;        wire         rlast, rvalid;
  logic rready = 1;

  wire start;  wire [31:0] base_addr, num_bursts;
  logic busy = 0, done = 0;
  logic [31:0] err_count = 32'd7, beats_done = 32'd9;

  int errors = 0;
  int start_pulses = 0;
  always @(posedge clk) if (rstn && start) start_pulses++;

  axi_ctrl_regs #(.ADDR_W(32), .ID_W(ID_W)) dut (
    .clk(clk), .rstn(rstn),
    .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen),
    .s_awvalid(awvalid), .s_awready(awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
    .s_wvalid(wvalid), .s_wready(wready),
    .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen),
    .s_arvalid(arvalid), .s_arready(arready),
    .s_rdata(rdata), .s_rresp(rresp), .s_rid(rid), .s_rlast(rlast),
    .s_rvalid(rvalid), .s_rready(rready),
    .start(start), .base_addr(base_addr), .num_bursts(num_bursts),
    .busy(busy), .done(done), .err_count(err_count), .beats_done(beats_done)
  );

  task automatic chk(input logic cond, input string what);
    if (!cond) begin $display("  FAIL  %s", what); errors++; end
    else         $display("  pass  %s", what);
  endtask

  // Handshake convention used below: drive on the negedge, observe READY on a negedge,
  // then hold VALID across ONE more negedge so the intervening posedge -- where the DUT
  // actually samples -- sees both VALID and READY high. Dropping VALID in the same negedge
  // that observed READY means the transfer never happens.
  task automatic hs_aw(input [31:0] a, input [ID_W-1:0] id);
    @(negedge clk); awid = id; awaddr = a; awlen = 0; awvalid = 1;
    while (!awready) @(negedge clk);
    @(negedge clk); awvalid = 0;
  endtask

  task automatic hs_w(input [31:0] d_in);
    @(negedge clk); wdata = d_in; wstrb = 4'hF; wlast = 1; wvalid = 1;
    while (!wready) @(negedge clk);
    @(negedge clk); wvalid = 0; wlast = 0;
  endtask

  task automatic await_b;
    while (!bvalid) @(negedge clk);
    @(negedge clk);
  endtask

  // Write with the address phase FIRST, then data.
  task automatic wr_aw_first(input [31:0] a, input [31:0] d_in, input [ID_W-1:0] id);
    hs_aw(a, id);
    hs_w(d_in);
    await_b();
  endtask

  // Write with the DATA phase first -- legal AXI, and what the PS7 actually does.
  // AW and W are driven as genuinely independent processes, each performing exactly ONE
  // handshake, because that is what the real master does. An earlier version of this
  // testbench left WVALID asserted after the beat was taken, which let a broken DUT
  // consume a second beat that happened to land on the right register -- masking the bug.
  task automatic wr_w_first(input [31:0] a, input [31:0] d_in, input [ID_W-1:0] id);
    fork
      hs_w(d_in);
      begin
        repeat (4) @(negedge clk);          // address arrives well after the data
        hs_aw(a, id);
      end
    join
    await_b();
  endtask

  // Address and data presented in the same cycle.
  task automatic wr_together(input [31:0] a, input [31:0] d_in, input [ID_W-1:0] id);
    fork
      hs_w(d_in);
      hs_aw(a, id);
    join
    await_b();
  endtask

  task automatic rd(input [31:0] a, input [ID_W-1:0] id,
                    output [31:0] d_out, output [ID_W-1:0] got_id);
    @(negedge clk); arid = id; araddr = a; arlen = 0; arvalid = 1;
    while (!arready) @(negedge clk);
    @(negedge clk); arvalid = 0;
    while (!rvalid) @(negedge clk);
    d_out  = rdata;
    got_id = rid;
    chk(rlast, "RLAST asserted on the single-beat read");
    @(negedge clk);
  endtask

  logic [31:0] d;  logic [ID_W-1:0] got;

  initial begin
    repeat (5) @(negedge clk);
    rstn = 1;
    repeat (2) @(negedge clk);

    $display("\n-- 1. read MAGIC, and check RID is echoed --");
    rd(32'h18, 12'hA5A, d, got);
    chk(d === 32'h5A5A_0001, $sformatf("MAGIC reads 0x5A5A0001 (got 0x%08X)", d));
    chk(got === 12'hA5A,     $sformatf("RID echoes ARID 0xA5A (got 0x%03X)", got));

    $display("\n-- 2. RID echoes a different ARID (not a stuck constant) --");
    rd(32'h18, 12'h123, d, got);
    chk(got === 12'h123, $sformatf("RID echoes ARID 0x123 (got 0x%03X)", got));

    $display("\n-- 3. write BASE with the address phase first --");
    wr_aw_first(32'h04, 32'h1234_5678, 12'h11);
    rd(32'h04, 12'h1, d, got);
    chk(d === 32'h1234_5678, $sformatf("BASE reads back (got 0x%08X)", d));

    $display("\n-- 4. write NBURST with the DATA phase first (the PS7 ordering) --");
    wr_w_first(32'h08, 32'h0000_BEEF, 12'h22);
    rd(32'h08, 12'h2, d, got);
    chk(d === 32'h0000_BEEF, $sformatf("NBURST reads back (got 0x%08X)", d));
    rd(32'h04, 12'h3, d, got);
    chk(d === 32'h1234_5678, $sformatf("BASE was NOT clobbered (got 0x%08X)", d));

    $display("\n-- 5. the regression: NBURST write, then a W-first CTRL write --");
    // The old code decoded this second write against the PREVIOUS address (NBURST),
    // so the start bit was written into num_bursts and the engine never ran.
    wr_aw_first(32'h08, 32'h0000_0400, 12'h33);
    start_pulses = 0;
    wr_w_first(32'h00, 32'h0000_0001, 12'h44);
    repeat (4) @(negedge clk);
    chk(start_pulses == 1, $sformatf("W-first CTRL write: start pulsed once (got %0d)", start_pulses));
    rd(32'h08, 12'h5, d, got);
    chk(d === 32'h0000_0400, $sformatf("NBURST still 0x400, not the CTRL data (got 0x%08X)", d));

    $display("\n-- 5b. address and data presented in the same cycle --");
    start_pulses = 0;
    wr_together(32'h00, 32'h0000_0001, 12'h55);
    repeat (4) @(negedge clk);
    chk(start_pulses == 1, $sformatf("same-cycle CTRL write: start pulsed once (got %0d)", start_pulses));
    rd(32'h08, 12'h5, d, got);
    chk(d === 32'h0000_0400, $sformatf("NBURST survived the same-cycle write (got 0x%08X)", d));
    rd(32'h04, 12'h5, d, got);
    chk(d === 32'h1234_5678, $sformatf("BASE survived the same-cycle write (got 0x%08X)", d));

    $display("\n-- 6. status/counters read back from the engine --");
    busy = 0; done = 1; @(negedge clk);
    rd(32'h0C, 12'h6, d, got);
    chk(d === 32'h2, $sformatf("STATUS shows done (got 0x%08X)", d));
    rd(32'h10, 12'h7, d, got);
    chk(d === 32'd7, $sformatf("ERRCNT passthrough (got %0d)", d));
    rd(32'h14, 12'h8, d, got);
    chk(d === 32'd9, $sformatf("BEATS passthrough (got %0d)", d));

    $display("\n-- 6b. RUNS distinguishes a fresh result from a stale one --");
    // done stays set after a run; only RUNS tells software the engine actually re-ran.
    done = 0; @(negedge clk);
    rd(32'h1C, 12'h9, d, got);
    begin
      automatic logic [31:0] r0 = d;
      done = 1; repeat (2) @(negedge clk);      // engine completes a run
      done = 0; repeat (2) @(negedge clk);
      rd(32'h1C, 12'h9, d, got);
      chk(d === r0 + 1, $sformatf("RUNS incremented on done's rising edge (%0d -> %0d)", r0, d));
      done = 1; repeat (2) @(negedge clk);      // a second run
      rd(32'h1C, 12'h9, d, got);
      chk(d === r0 + 2, $sformatf("RUNS incremented again (got %0d)", d));
      repeat (4) @(negedge clk);                // done held high must NOT keep counting
      rd(32'h1C, 12'h9, d, got);
      chk(d === r0 + 2, $sformatf("RUNS counts edges, not levels (got %0d)", d));
    end

    $display("\n-- 7. BID is echoed on the write response --");
    hs_aw(32'h04, 12'h5A5);
    hs_w(32'h0000_0001);
    while (!bvalid) @(negedge clk);
    chk(bid === 12'h5A5, $sformatf("BID echoes AWID 0x5A5 (got 0x%03X)", bid));
    chk(bresp === 2'b00, "BRESP is OKAY");
    @(negedge clk);
    repeat (5) @(negedge clk);

    $display("\n==================================================");
    if (errors == 0) begin
      $display("ALL CHECKS PASSED");
      $display("==================================================");
      $finish;
    end else begin
      $display("==================================================");
      $fatal(1, "*** %0d CHECK(S) FAILED ***", errors);   // non-zero exit for the caller
    end
  end

  initial begin
    #200000;
    $fatal(1, "*** TESTBENCH TIMEOUT -- a handshake never completed ***");
  end
endmodule
