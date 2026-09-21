// Self-checking testbench for soc_ctrl_regs -- the PS7 M_AXI_GP0 register file in the
// ROCKET bitstreams (axi_ctrl_regs, covered by tb_ctrl_regs.sv, is the DRAM-self-test one).
//
// This module was never simulated. It is a near-copy of axi_ctrl_regs, so it inherits the
// same two shapes of bug that were found on hardware and cost a power cycle:
//
//   1. RID must be driven and must echo ARID. The PS7 GP0 master will not retire a read
//      whose RID does not match the ARID it issued; an undriven RID synthesises to
//      constant 0 with only a WARNING and locks the ARM on the first register read.
//   2. W must not be accepted before AW. AXI allows write data to arrive first and the PS
//      does that; decoding W against a stale registered AW writes the previous
//      transaction's address. Here that would mean soc_resetn/custom_boot changing when
//      something else was addressed.
//
// It also pins down the MAGIC parameter, which is what tells the host which of the two
// pin-compatible Rocket bitstreams is actually loaded:
//   default        -> 0x5A5A0002  single-core Rocket + TACIT
//   -generic ...   -> 0x5A5A0003  dual-core big.LITTLE + TACIT
// Both are instantiated below from one stimulus, so a regression that severed the
// parameter (for example re-introducing the old localparam) fails here rather than by
// letting a dual-core run silently execute against the single-core PL.
//
// Run it with sim/run_soc_ctrl_sim.sh.
`timescale 1ns/1ps

module tb_soc_ctrl_regs;
  localparam ID_W        = 12;
  localparam [31:0] MAGIC_DEFAULT = 32'h5A5A_0002;
  localparam [31:0] MAGIC_SMP     = 32'h5A5A_0003;

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;                        // 100 MHz

  // --- stimulus, shared by both DUTs -------------------------------------------------
  logic [ID_W-1:0] awid = 0;   logic [31:0] awaddr = 0;  logic [7:0] awlen = 0;
  logic            awvalid = 0;
  logic [31:0]     wdata = 0;  logic [3:0]  wstrb = 4'hF;
  logic            wlast = 0, wvalid = 0;
  logic            bready = 1;
  logic [ID_W-1:0] arid = 0;   logic [31:0] araddr = 0;  logic [7:0] arlen = 0;
  logic            arvalid = 0;
  logic            rready = 1;
  logic [31:0]     status_in = 32'h0000_0005;
  logic            err_burst = 0;

  // --- DUT A: default MAGIC (the single-core bitstream) -------------------------------
  wire             a_awready, a_wready, a_bvalid, a_arready, a_rvalid, a_rlast;
  wire [ID_W-1:0]  a_bid, a_rid;
  wire [1:0]       a_bresp, a_rresp;
  wire [31:0]      a_rdata;
  wire             a_soc_resetn, a_custom_boot;

  soc_ctrl_regs #(.ID_W(ID_W)) dut_a (
    .clk(clk), .rstn(rstn),
    .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen),
    .s_awvalid(awvalid), .s_awready(a_awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid),
    .s_wready(a_wready),
    .s_bid(a_bid), .s_bresp(a_bresp), .s_bvalid(a_bvalid), .s_bready(bready),
    .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen),
    .s_arvalid(arvalid), .s_arready(a_arready),
    .s_rdata(a_rdata), .s_rresp(a_rresp), .s_rid(a_rid), .s_rlast(a_rlast),
    .s_rvalid(a_rvalid), .s_rready(rready),
    .soc_resetn(a_soc_resetn), .custom_boot(a_custom_boot),
    .err_burst_too_long(err_burst), .status(status_in)
  );

  // --- DUT B: MAGIC overridden, as tcl/build_rocket_smp.tcl does ----------------------
  wire             b_awready, b_wready, b_bvalid, b_arready, b_rvalid, b_rlast;
  wire [ID_W-1:0]  b_bid, b_rid;
  wire [1:0]       b_bresp, b_rresp;
  wire [31:0]      b_rdata;
  wire             b_soc_resetn, b_custom_boot;

  soc_ctrl_regs #(.ID_W(ID_W), .MAGIC(MAGIC_SMP)) dut_b (
    .clk(clk), .rstn(rstn),
    .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen),
    .s_awvalid(awvalid), .s_awready(b_awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid),
    .s_wready(b_wready),
    .s_bid(b_bid), .s_bresp(b_bresp), .s_bvalid(b_bvalid), .s_bready(bready),
    .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen),
    .s_arvalid(arvalid), .s_arready(b_arready),
    .s_rdata(b_rdata), .s_rresp(b_rresp), .s_rid(b_rid), .s_rlast(b_rlast),
    .s_rvalid(b_rvalid), .s_rready(rready),
    .soc_resetn(b_soc_resetn), .custom_boot(b_custom_boot),
    .err_burst_too_long(err_burst), .status(status_in)
  );

  integer errors = 0, checks = 0;

  task automatic chk(input string what, input logic cond);
    checks++;
    if (cond) $display("  pass  %s", what);
    else begin errors++; $display("  FAIL  %s", what); end
  endtask

  // The two instances differ only by a constant, so every handshake signal must agree.
  // If they ever do not, the parameter is doing more than it should.
  always @(posedge clk) if (rstn) begin
    if ({a_awready, a_wready, a_bvalid, a_arready, a_rvalid, a_rlast} !==
        {b_awready, b_wready, b_bvalid, b_arready, b_rvalid, b_rlast}) begin
      errors++;
      $display("  FAIL  DUT A and DUT B handshakes diverged at t=%0t", $time);
    end
  end

  // --- bus helpers -------------------------------------------------------------------
  // Same handshake pattern as tb_ctrl_regs.sv: sample ready at a NEGEDGE and hold valid
  // across the following posedge, which is where the DUT actually consumes the beat.
  task automatic hs_aw(input [31:0] a, input [ID_W-1:0] id);
    @(negedge clk); awid = id; awaddr = a; awlen = 0; awvalid = 1;
    while (!a_awready) @(negedge clk);
    @(negedge clk); awvalid = 0;
  endtask

  task automatic hs_w(input [31:0] d_in);
    @(negedge clk); wdata = d_in; wstrb = 4'hF; wlast = 1; wvalid = 1;
    while (!a_wready) @(negedge clk);
    @(negedge clk); wvalid = 0; wlast = 0;
  endtask

  task automatic await_b;
    while (!a_bvalid) @(negedge clk);
    @(negedge clk);
  endtask

  task automatic axi_write(input [31:0] addr, input [31:0] data, input [ID_W-1:0] id);
    begin
      hs_aw(addr, id);
      hs_w(data);
      await_b();
    end
  endtask

  // Write data BEFORE the address -- the ordering the PS7 actually uses, and the one that
  // broke axi_ctrl_regs on hardware.
  task automatic axi_write_w_first(input [31:0] addr, input [31:0] data,
                                   input [ID_W-1:0] id);
    begin
      fork
        hs_w(data);
        begin
          repeat (4) @(negedge clk);
          chk("W is not accepted before AW", a_wready === 1'b0);
          hs_aw(addr, id);
        end
      join
      await_b();
    end
  endtask

  task automatic axi_read(input [31:0] addr, input [ID_W-1:0] id,
                          output [31:0] da_o, output [31:0] db_o);
    begin
      @(negedge clk); arid = id; araddr = addr; arlen = 0; arvalid = 1;
      while (!a_arready) @(negedge clk);
      @(negedge clk); arvalid = 0;
      while (!a_rvalid) @(negedge clk);
      da_o = a_rdata; db_o = b_rdata;
      chk($sformatf("RID echoes ARID 0x%0h on a read of 0x%0h", id, addr),
          a_rid === id && b_rid === id);
      chk("RLAST set on a single-beat read", a_rlast === 1'b1);
      chk("RRESP is OKAY", a_rresp === 2'b00);
      @(negedge clk);
    end
  endtask

  logic [31:0] da, db;
  integer beats;

  initial begin
    repeat (4) @(negedge clk);
    rstn = 1;
    repeat (2) @(negedge clk);

    $display("== soc_ctrl_regs ==");

    // Power-up state: the SoC must come out of configuration HELD IN RESET, so that the
    // PS can place a program in DDR before the core fetches anything.
    chk("soc_resetn is 0 out of reset (SoC held in reset)", a_soc_resetn === 1'b0);
    chk("custom_boot is 0 out of reset",                    a_custom_boot === 1'b0);

    // MAGIC -- the parameter, on both instances, from one read.
    axi_read(32'h08, 12'h123, da, db);
    chk($sformatf("default MAGIC reads 0x%08h (got 0x%08h)", MAGIC_DEFAULT, da),
        da === MAGIC_DEFAULT);
    chk($sformatf("overridden MAGIC reads 0x%08h (got 0x%08h)", MAGIC_SMP, db),
        db === MAGIC_SMP);

    // STATUS is a pure passthrough of the `status` input.
    axi_read(32'h04, 12'h456, da, db);
    chk("STATUS mirrors the status input", da === status_in && db === status_in);

    // CTRL: release reset, then arm custom_boot, then drop it again -- the exact sequence
    // run_rocket.py uses.
    axi_write(32'h00, 32'h1, 12'h001);
    chk("CTRL[0]=1 releases soc_resetn", a_soc_resetn === 1'b1 && b_soc_resetn === 1'b1);
    chk("CTRL[1] still 0",               a_custom_boot === 1'b0);

    axi_write(32'h00, 32'h3, 12'h002);
    chk("CTRL[1]=1 asserts custom_boot", a_custom_boot === 1'b1 && b_custom_boot === 1'b1);

    axi_read(32'h00, 12'h789, da, db);
    chk("CTRL reads back {custom_boot, soc_resetn}", da === 32'h3 && db === 32'h3);

    axi_write(32'h00, 32'h1, 12'h003);
    chk("CTRL[1]=0 drops custom_boot", a_custom_boot === 1'b0);

    // W-before-AW against the CTRL register.
    axi_write_w_first(32'h00, 32'h3, 12'h004);
    chk("W-before-AW still lands in CTRL", a_custom_boot === 1'b1 && a_soc_resetn === 1'b1);

    // A write to a register that does not exist must not disturb CTRL. This is the
    // failure mode of decoding W against a stale AW: the bits move when something else
    // was addressed.
    axi_write(32'h20, 32'h0, 12'h005);
    chk("a write to an unmapped offset leaves CTRL alone",
        a_custom_boot === 1'b1 && a_soc_resetn === 1'b1);

    // Unmapped reads return the poison value rather than floating.
    axi_read(32'h20, 12'h006, da, db);
    chk("unmapped offset reads 0xDEADBEEF", da === 32'hDEAD_BEEF);

    // err_burst_too_long is a level input, not a register: STATUS is a passthrough, so
    // this only checks the input is not being swallowed somewhere.
    status_in = 32'h0000_000F; err_burst = 1;
    axi_read(32'h04, 12'h007, da, db);
    chk("STATUS follows a changed status input", da === 32'h0000_000F);

    // Burst read: the PS7 issues multi-beat reads. ARLEN=3 must give 4 beats with RLAST
    // only on the last, and the address must walk 0x00,0x04,0x08,0x0C.
    @(negedge clk);
    arid = 12'h0AB; araddr = 32'h00; arlen = 8'd3; arvalid = 1;
    while (!a_arready) @(negedge clk);
    @(negedge clk); arvalid = 0;
    beats = 0;
    while (beats < 4) begin
      while (!a_rvalid) @(negedge clk);
      case (beats)
        0: chk("burst beat 0 is CTRL",   a_rdata === 32'h3);
        1: chk("burst beat 1 is STATUS", a_rdata === 32'h0000_000F);
        2: chk("burst beat 2 is MAGIC",  a_rdata === MAGIC_DEFAULT && b_rdata === MAGIC_SMP);
        3: chk("burst beat 3 is the poison value", a_rdata === 32'hDEAD_BEEF);
      endcase
      chk($sformatf("burst beat %0d RID echoes ARID", beats), a_rid === 12'h0AB);
      chk($sformatf("burst beat %0d RLAST is %0d", beats, (beats == 3)),
          a_rlast === (beats == 3));
      beats++;
      @(negedge clk);
    end

    // Reset must put the SoC back into reset -- otherwise a PS reboot would leave a core
    // running against DDR the PS is about to reuse.
    rstn = 0; repeat (3) @(negedge clk);
    chk("rstn returns soc_resetn to 0",  a_soc_resetn === 1'b0);
    chk("rstn returns custom_boot to 0", a_custom_boot === 1'b0);

    $display("%0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("ALL CHECKS PASSED");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  // Nothing here should take anywhere near this long; a hang is a bug, not a slow test.
  initial begin
    #200000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
