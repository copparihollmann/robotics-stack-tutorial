// SPDX-License-Identifier: Apache-2.0
//
// mbxr_wx -- the load descriptor/status crossing between mbxr_engine_core (engine clock) and
// mbxr_whalf (the weight lane's clock), MEMORY_BANDWIDTH.md 9.9 P3, for engine revision 2b.
// A proposal, checked by tb_wx.cpp; not in any build.
//
// ONE HANDSHAKE, NO BUSY SYNCHRONISER.  The core toggles `req` when it accepts a weight load.
// The lane sees the toggle two flops later, starts its DMA, and toggles `done` when that load
// has finished (busy fell) -- or at once if the load had nothing to fetch.  In the core, the
// weight fill is busy exactly while req != done_synced.  So FILL rises in the SAME cycle the
// load is accepted (no window where a synchronised busy still reads idle -- the "pending flag")
// and falls only after the lane's last scratchpad write, plus the synchroniser's two cycles.
//
// QUASI-STATIC FIELDS.  base/rblk/rows/stride are set by `sd` before `ld`, and fbuf/lgpw/cap at
// the accepting edge; the driver changes none of them until FILL has cleared (it waits for FILL
// before every sd).  The lane samples them only after the request toggle has crossed, so they
// are two or more lane cycles old: they need a max-delay constraint, not a synchroniser.
//
// COUNTS.  The lane counts delivered words in a 32-bit counter crossed Gray-coded; the core
// turns it back to binary and keeps its own 48-bit total with a clear offset, so STAT's fill
// beats are exact once the lane is idle.  Errors cross as a toggle.  `inflight` is a
// diagnostic and crosses bit-wise (it may read a mix of two values while it changes).
//
// LANE READY.  The lane registers (out of reset && quiet) and the core synchronises it into fence
// bit 41 -- a new crossing, two flops with ASYNC_REG, level-sensitive; a late edge only delays the
// driver's first weight load.  The driver checks it before arming a dispatch (mbxr_dev.lane_wait)
// and reports MBXR_E_LANE if the lane never becomes ready.
//
// ASYNC = 0 joins the two sides with wires (revision 2a's behaviour); ASYNC = 1 inserts the
// flops.  Every flop that samples the other domain carries (* ASYNC_REG = "TRUE" *).

module mbxr_wx_core #(
  parameter ASYNC = 1
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        accept,        // a weight load accepted this cycle (engine domain)
  output wire        busy,          // weight fill busy, engine domain
  input  wire        clr_count,     // STAT clear
  output wire [47:0] beats,         // weight words delivered since the last clear
  output wire        err_pulse,     // one cycle per lane error
  output wire [7:0]  inflight,
  output wire        lane_ready,    // the lane is out of reset and its W port is quiet (fence bit 41)
  // to / from the lane
  output wire        x_req,
  input  wire        x_done,
  input  wire [31:0] x_beats_gray,
  input  wire        x_err_tog,
  input  wire [7:0]  x_inflight,
  input  wire        x_ready
);
  reg req;
  always @(posedge clk) if (rst) req <= 1'b0; else if (accept) req <= ~req;
  assign x_req = req;

  generate
    if (ASYNC) begin : a
      (* ASYNC_REG = "TRUE" *) reg        done_s1, done_s2;
      (* ASYNC_REG = "TRUE" *) reg        err_s1, err_s2;
      (* ASYNC_REG = "TRUE" *) reg [31:0] g_s1, g_s2;
      (* ASYNC_REG = "TRUE" *) reg [7:0]  inf_s1, inf_s2;
      (* ASYNC_REG = "TRUE" *) reg        rdy_s1, rdy_s2;
      reg err_q;
      always @(posedge clk) begin
        if (rst) begin
          done_s1 <= 1'b0; done_s2 <= 1'b0; err_s1 <= 1'b0; err_s2 <= 1'b0; err_q <= 1'b0;
          g_s1 <= 32'd0; g_s2 <= 32'd0; inf_s1 <= 8'd0; inf_s2 <= 8'd0; rdy_s1 <= 1'b0; rdy_s2 <= 1'b0;
        end else begin
          rdy_s1 <= x_ready; rdy_s2 <= rdy_s1;
          done_s1 <= x_done; done_s2 <= done_s1;
          err_s1 <= x_err_tog; err_s2 <= err_s1; err_q <= err_s2;
          g_s1 <= x_beats_gray; g_s2 <= g_s1;
          inf_s1 <= x_inflight; inf_s2 <= inf_s1;
        end
      end
      assign busy      = req != done_s2;
      assign err_pulse = err_s2 != err_q;
      assign inflight  = inf_s2;
      assign lane_ready = rdy_s2;
      // Gray -> binary
      reg [31:0] bin;
      integer i;
      always @* begin
        bin[31] = g_s2[31];
        for (i = 30; i >= 0; i = i - 1) bin[i] = bin[i+1] ^ g_s2[i];
      end
      reg [31:0] last;
      reg [47:0] total, base;
      wire signed [32:0] d_sgn = $signed({1'b0, bin}) - $signed({1'b0, last});
      always @(posedge clk) begin
        if (rst) begin last <= 32'd0; total <= 48'd0; base <= 48'd0; end
        else begin
          last  <= bin;
          // SIGN-EXTENDED, not zero-extended: a delta that comes out negative must cancel, not add
          // 2^32 to a 48-bit accumulator.  With the source-domain Gray register above this should
          // never happen; it is kept because a counter that silently gains 4 G beats is the kind of
          // fault that is read as a bandwidth result.
          total <= total + {{15{d_sgn[32]}}, d_sgn};
          if (clr_count) base <= total + {{15{d_sgn[32]}}, d_sgn};
        end
      end
      assign beats = total - base;
    end else begin : s
      reg err_q;
      always @(posedge clk) if (rst) err_q <= 1'b0; else err_q <= x_err_tog;
      assign busy      = req != x_done;
      assign err_pulse = x_err_tog != err_q;
      assign inflight  = x_inflight;
      assign lane_ready = x_ready;
      reg [31:0] bin, last;
      wire signed [32:0] d_sgn = $signed({1'b0, bin}) - $signed({1'b0, last});
      integer i;
      always @* begin
        bin[31] = x_beats_gray[31];
        for (i = 30; i >= 0; i = i - 1) bin[i] = bin[i+1] ^ x_beats_gray[i];
      end
      reg [47:0] total, base;
      always @(posedge clk) begin
        if (rst) begin last <= 32'd0; total <= 48'd0; base <= 48'd0; end
        else begin
          last  <= bin;
          // SIGN-EXTENDED, not zero-extended: a delta that comes out negative must cancel, not add
          // 2^32 to a 48-bit accumulator.  With the source-domain Gray register above this should
          // never happen; it is kept because a counter that silently gains 4 G beats is the kind of
          // fault that is read as a bandwidth result.
          total <= total + {{15{d_sgn[32]}}, d_sgn};
          if (clr_count) base <= total + {{15{d_sgn[32]}}, d_sgn};
        end
      end
      assign beats = total - base;
    end
  endgenerate
endmodule

module mbxr_wx_half #(
  parameter ASYNC = 1
) (
  input  wire        wclk,
  input  wire        wrst,
  input  wire        x_req,          // from the core
  input  wire        quiet,          // the W port has no response outstanding (lane domain)
  output wire        x_done,
  output wire [31:0] x_beats_gray,
  output wire        x_err_tog,
  output wire [7:0]  x_inflight,
  output wire        x_ready,        // registered: out of reset and quiet
  // the lane's DMA
  output wire        start,          // one lane cycle
  input  wire        busy,
  input  wire        beat,
  input  wire        err,
  input  wire [7:0]  inflight
);
  reg        seen;                   // the request value last acted on
  reg        running;                // a started load has not yet finished
  reg        done;
  reg [31:0] cnt;
  // THE GRAY VALUE THAT CROSSES IS A FLOP OUTPUT, not a function of cnt.  `cnt ^ (cnt >> 1)` is
  // correct arithmetic but it is COMBINATIONAL: while cnt's bits settle, the wire carries values
  // that are not a Gray step from either neighbour, and the receiving flops can latch one of them.
  // Then the far side decodes a count that moved backwards, which is what put 2^32 into the
  // 48-bit total (41 such wraps in the failed 0x5A5A0013 run) and what makes the one-bit-at-a-time
  // argument that waives CDC-10 untrue.  Registered here, only one bit changes per lane cycle and
  // a sampled value is always one of the two neighbouring counts.  The cost is one lane cycle of
  // latency on a statistics counter.
  reg [31:0] gray_q;
  reg        etog;
  reg        ready;
  wire       req_now;

  generate
    if (ASYNC) begin : a
      (* ASYNC_REG = "TRUE" *) reg r1, r2;
      always @(posedge wclk) if (wrst) begin r1 <= 1'b0; r2 <= 1'b0; end else begin r1 <= x_req; r2 <= r1; end
      assign req_now = r2;
    end else begin : s
      assign req_now = x_req;
    end
  endgenerate

  wire go = (req_now != seen) && !running && quiet;
  assign start = go;
  always @(posedge wclk) begin
    if (wrst) begin
      seen <= 1'b0; running <= 1'b0; done <= 1'b0; cnt <= 32'd0; etog <= 1'b0; ready <= 1'b0;
      gray_q <= 32'd0;
    end else begin
      ready <= quiet;
      if (go) begin
        seen    <= req_now;
        running <= 1'b1;
      end else if (running && !busy) begin
        // the DMA took `start` last cycle; busy is registered, so one cycle after go it is
        // already high for any load with blocks to fetch, and low only when there were none
        running <= 1'b0;
        done    <= seen;
      end
      if (beat) cnt <= cnt + 32'd1;
      gray_q <= (beat ? (cnt + 32'd1) : cnt) ^ ((beat ? (cnt + 32'd1) : cnt) >> 1);
      if (err)  etog <= ~etog;
    end
  end
  assign x_done       = done;
  assign x_beats_gray = gray_q;
  assign x_err_tog    = etog;
  assign x_inflight   = inflight;
  assign x_ready      = ready;
endmodule

// ---- W_QUIET: the shim-side balance counter that drives mbxr_whalf.w_quiet -------------------
// SPECIFICATION for P4 (the memory-bus plumbing), with this module as the reference:
//   * Instantiated at the weight lane's AXI4 master pins (after the TileLink-to-AXI bridge and
//     any AXI4UserYanker), clocked by the lane clock.
//   * ar_fire = ARVALID && ARREADY; r_last_fire = RVALID && RREADY && RLAST.
//   * quiet = (ARs issued == RLASTs received), registered.  The weight half starts no load while
//     quiet is low, so a load never reuses a source ID with an older burst still on the wire.
//   * NO RESET INPUT.  The counters start from their configuration values (all zero) and are
//     never reset by the SoC: after a SoC or lane reset with bursts outstanding, they still
//     know how many are due.  Do not connect any SoC reset to them, and do not let synthesis
//     infer one (no set_property or IOBinder reset hook on this instance).  quiet is produced
//     and consumed in the lane domain, so it needs no synchroniser; ar_fire and r_last_fire are
//     in the same domain too.  If the shim runs RREADY from a different clock, move this module
//     to that clock and cross `quiet` into the lane with a two-flop synchroniser
//     (ASYNC_REG = "TRUE") -- a late 1 only delays a load start, which is safe.
//   * The widths wrap; equality of the wrapped counts is exact while fewer than 2^8 bursts are
//     outstanding (the lane has at most LDEPTH = 4).
module mbxr_wquiet (
  input  wire aclk,
  input  wire ar_fire,
  input  wire r_last_fire,
  output reg  quiet
);
  reg [7:0] n_ar = 8'd0;
  reg [7:0] n_rl = 8'd0;
  initial quiet = 1'b1;
  always @(posedge aclk) begin
    if (ar_fire)     n_ar <= n_ar + 8'd1;
    if (r_last_fire) n_rl <= n_rl + 8'd1;
    quiet <= (n_ar + {7'd0, ar_fire}) == (n_rl + {7'd0, r_last_fire});
  end
endmodule
