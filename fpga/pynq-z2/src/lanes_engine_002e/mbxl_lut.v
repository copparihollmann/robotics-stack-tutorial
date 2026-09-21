// SPDX-License-Identifier: Apache-2.0
//
// mbxl_lut -- T4's LUT lane: a 256-entry int8 -> int8 pointwise map at EIGHT elements per
// cycle, one 64-bit scratchpad word in and one drain word out.  `gelu_s8` today; `silu_s8`
// and `tanh_s8` are the same shape and the same lane.
//
// WHY EIGHT AND NOT ONE.  The scratchpad delivers one 64-bit word per cycle and mbxr_st
// accepts one; eight parallel lookups match both exactly, and cost eight copies of the
// table.  At one element per cycle the lane would be 8x slower for the same control.
//
// WHY ONE ENTRY PER CONFIG WRITE, AND WHY THAT IS NOT THE OBVIOUS CHOICE.  A config write
// carries 32 bits, so four entries per write and 64 writes is the tempting encoding.  It was
// the first implementation and it cost 10,588 LUT against a predicted 530 -- a 20x miss --
// because four entries per cycle is four write ports, and the four-bank workaround that
// avoids that (entry e in bank e[1:0] at address e[7:2]) is a THREE-dimensional array whose
// inner index is dynamic, and Vivado infers no distributed RAM for it at all: `LUT as
// Memory` read 0 and the whole table synthesised as logic.  One entry per write is the flat,
// single-write-port, one-dimensional pattern that infers RAM256X1S, which is what the 530
// was an estimate of.  256 writes load the table -- and the table changes once per LAYER,
// not per dispatch, so the extra 192 writes are ~768 cycles per encoder against 21.9 M saved.
// The lesson is recorded rather than tidied away: the prediction was right about the
// primitive and the first RTL did not reach the primitive.
//
// WHAT THIS LANE CANNOT REFUSE.  Every int8 input is a valid table index by construction.
// There is no out-of-range case, no saturation case, and deliberately no error bit for the
// data: every error below is a config/start protocol one.  See T4_LANES.md s3.
//
// WHAT IT DOES REFUSE, AND WHY IT IS HERE FROM THE FIRST COMMIT.  A word range that leaves
// the activation buffer.  The address is AW bits and a buffer is 2^AW words (8 KB at AW=10);
// past that the address WRAPS and the lane reads the start of its own buffer as if it were
// more data -- a plausible wrong answer with no error anywhere.  The LayerNorm lane shipped
// that defect in 0x5A5A0029/002A and it survived its own gate, because the gate's largest
// two-pass case was 512 words against a 1,024-word limit and a 71,928-word target: a suite
// whose largest case is half the limit cannot find the limit.  The engine's own activation
// mapper has always raised `pa_bad` on exactly this.  err[2] is that comparator, and it is
// the reason this lane's encoder dispatch is TILED -- 190,080 elements is 23,760 words and
// does not fit any buffer this engine has.
//
// NOT A GELU EVALUATOR.  The lane does not compute GELU; software builds the table from the
// same kernel that would otherwise run.  Bit-exactness is therefore a property of the
// STREAM -- that every input byte reaches its own table entry and every output byte reaches
// its own position -- which is what tb_lut.cpp checks.

`default_nettype none

module mbxl_lut #(
  parameter AW = 10
) (
  input  wire        clk,
  input  wire        rst,
  // ---- configuration: this lane's own 13-bit local space -------------------------------
  //   0x000..0x0FF  table, ONE entry per word (entry i = wdata[7:0]) -- see the header
  //   0x100         first scratchpad word
  //   0x101         words to read
  //   0x102         clear err
  input  wire        cfg_we,
  input  wire [12:0] cfg_addr,
  /* verilator lint_off UNUSEDSIGNAL */   // the table takes [7:0], the lengths [15:0]
  input  wire [31:0] cfg_wdata,
  /* verilator lint_on UNUSEDSIGNAL */
  // ---- start, one cycle -----------------------------------------------------------------
  input  wire        start,
  // ---- scratchpad port 0 -----------------------------------------------------------------
  output wire [AW-1:0] rd_word,
  input  wire [63:0]   rd_data,
  // ---- the engine's drain ----------------------------------------------------------------
  output wire        out_valid,
  output wire [63:0] out_data,
  input  wire        out_hold,
  // ---- status ------------------------------------------------------------------------------
  output wire        busy,
  output wire        idle,
  output wire [2:0]  err
);
  // ======================================================================================
  // the table: 8 copies x 4 banks x 64 entries x 8 bits
  // ======================================================================================
  wire       t_we = cfg_we && (cfg_addr[12:8] == 5'd0);
  wire [7:0] t_a  = cfg_addr[7:0];
  wire [7:0] t_d  = cfg_wdata[7:0];

  // ======================================================================================
  // the dispatch registers
  // ======================================================================================
  reg [AW-1:0] c_word0;
  reg [15:0]   c_words;
  reg          e_cfg, e_busy, e_range;

  // the range must stay inside one activation buffer: word0 + words <= 2^AW.  Checked at
  // start, from the registers actually latched, not from what software believed it wrote.
  wire [16:0] rng_end = {{(17-AW){1'b0}}, c_word0} + {1'b0, c_words};
  wire        rng_bad = rng_end > 17'd1024;

  wire cfg_hit  = cfg_we && (cfg_addr[12:8] != 5'd0);
  wire cfg_w0   = cfg_hit && (cfg_addr == 13'h100);
  wire cfg_wn   = cfg_hit && (cfg_addr == 13'h101);
  wire cfg_clr  = cfg_hit && (cfg_addr == 13'h102);

  // ======================================================================================
  // the pipeline: issue -> (scratchpad latency 1) -> lookup -> two-deep output
  // ======================================================================================
  reg          run;
  reg [AW-1:0] a_word;
  reg [15:0]   a_left;
  reg          pend;
  reg          o0_v, o1_v;
  reg [63:0]   o0_d, o1_d;

  wire o0_fire = o0_v && !out_hold;

  // where this cycle's returning word lands.  o1 is only ever written when o0 is held, and
  // an issue is refused in exactly that case, so o1 cannot be overwritten while valid.
  wire w_o0 = pend && ((!o0_v) || (o0_fire && !o1_v));
  wire w_o1 = pend && !w_o0;

  wire can_issue = run && (a_left != 16'd0) && !o1_v && (!pend || w_o0);

  // the eight lookups, combinational off the distributed RAM
  wire [63:0] y;
  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_lut
      (* ram_style = "distributed" *) reg [7:0] tbl [0:255];
      always @(posedge clk) if (t_we) tbl[t_a] <= t_d;
      assign y[8*g +: 8] = tbl[rd_data[8*g +: 8]];
    end
  endgenerate

  assign rd_word   = a_word;
  // OUT_VALID IS A ONE-CYCLE PULSE PER WORD, NOT A HELD VALID, AND THAT IS THE ENGINE'S
  // CONTRACT RATHER THAN A CHOICE.  `mbxr_st` has no ready: `if (in_valid) begin if (full)
  // ovf else fifo[wp] <= in_data` (mbxr_st.v:117) pushes on EVERY cycle in_valid is high, and
  // `almost_full` -- which arrives here as `out_hold` -- is advisory, meaning "stop
  // producing", never "that word was not taken".  Both other lanes already obey it: mbxr_lnpk
  // clears out_valid unconditionally at the top of its always block, and mbxa_core's pad term
  // is explicitly `&& !out_hold`.
  //
  // This lane did NOT, and it was the whole of Lab B37 arm A.  Holding o0_v high while
  // out_hold was asserted pushed the SAME word once per cycle: at 8 elements/cycle the drain
  // backs up almost immediately, the FIFO takes four more pushes past almost_full, s_ovf sets,
  // almost_full never clears, o0_v never clears, `busy` never falls and OWNERSHIP IS NEVER
  // RETURNED.  On silicon that is a hung lane; in tb_lutint it reproduces exactly (ovf at the
  // fourth block of a 32-block dispatch).  And below the hang there is a worse polarity: a
  // 28-word dispatch RETURNS CLEANLY with rc = 0, u_err = 0x0 and 32 duplicated bytes.
  //
  // Nothing could have caught it here: tb_lut.cpp drives a valid/ready handshake, consuming a
  // word only when !hold, which is a DIFFERENT CONTRACT from the one mbxr_st implements -- so
  // 73,936 byte checks under 95 % backpressure all passed against a model of the sink rather
  // than against the sink.  The gate for this is tb_lutint.cpp, on the merged engine.
  assign out_valid = o0_fire;
  assign out_data  = o0_d;
  assign busy      = run || pend || o0_v || o1_v;
  assign idle      = !busy;
  assign err       = {e_range, e_busy, e_cfg};

  always @(posedge clk) begin
    if (rst) begin
      c_word0 <= {AW{1'b0}}; c_words <= 16'd0;
      e_cfg <= 1'b0; e_busy <= 1'b0; e_range <= 1'b0;
      run <= 1'b0; a_word <= {AW{1'b0}}; a_left <= 16'd0;
      pend <= 1'b0; o0_v <= 1'b0; o1_v <= 1'b0;
      o0_d <= 64'd0; o1_d <= 64'd0;
    end else begin
      // ---- configuration.  A write while the lane is running is refused and recorded:
      // silently latching a new length mid-dispatch is the failure this bit exists to stop.
      if (cfg_hit && busy) begin
        e_busy <= 1'b1;
      end else begin
        if (cfg_w0) c_word0 <= cfg_wdata[AW-1:0];
        if (cfg_wn) c_words <= cfg_wdata[15:0];
        if (cfg_clr) begin e_cfg <= 1'b0; e_busy <= 1'b0; e_range <= 1'b0; end
      end

      // ---- start.  A zero-length dispatch is refused rather than run: it would return
      // ownership with the drain never written, which reads downstream as a lane that ran.
      if (start && !busy) begin
        if (c_words == 16'd0) begin
          e_cfg <= 1'b1;
        end else if (rng_bad) begin
          // refused BEFORE any word is read, so no partial wrong tensor is drained
          e_range <= 1'b1;
        end else begin
          run <= 1'b1; a_word <= c_word0; a_left <= c_words;
        end
      end

      // ---- issue
      pend <= can_issue;
      if (can_issue) begin
        a_word <= a_word + {{(AW-1){1'b0}}, 1'b1};
        a_left <= a_left - 16'd1;
        if (a_left == 16'd1) run <= 1'b0;
      end

      // ---- the output stage
      if (o0_fire && o1_v) begin
        o0_d <= o1_d; o1_v <= 1'b0;
      end else if (o0_fire && !w_o0) begin
        o0_v <= 1'b0;
      end
      if (w_o0) begin o0_d <= y; o0_v <= 1'b1; end
      if (w_o1) begin o1_d <= y; o1_v <= 1'b1; end
    end
  end
endmodule

// ============================================================================================
// mbxl_gtag -- the generation tag.
//
// Built even though the add lane it protects is HELD (T4_LANES.md s3, precondition 4): a
// stale per-channel scale table produces a correct-looking tensor with plausible values and
// no error anywhere, which is the worst failure polarity in T4.  Twenty LUTs turn it into a
// refused dispatch.  The argument does not depend on which lanes ship.
//
// Software writes the tag it believes the staged table carries; the lane samples the tag word
// the table actually carries as it reads it.  A mismatch refuses the dispatch BEFORE any
// output is produced -- the refusal must beat the first drain word, or a partial wrong tensor
// is written and the error bit only says it was noticed afterwards.
// ============================================================================================
/* verilator lint_off DECLFILENAME */
module mbxl_gtag (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,          // software's expected tag
  input  wire [31:0] cfg_wdata,
  input  wire        clr,
  input  wire        sample,          // the staged table's tag word is on obs this cycle
  input  wire [31:0] obs,
  output wire        ok,              // hold this to allow the dispatch to proceed
  output reg         err
);
  reg [31:0] expect_tag;
  reg [31:0] seen_tag;
  reg        seen;

  assign ok = seen && (seen_tag == expect_tag);

  always @(posedge clk) begin
    if (rst) begin
      expect_tag <= 32'd0; seen_tag <= 32'd0; seen <= 1'b0; err <= 1'b0;
    end else begin
      if (cfg_we) begin expect_tag <= cfg_wdata; seen <= 1'b0; end
      if (clr)    begin err <= 1'b0; seen <= 1'b0; end
      if (sample) begin
        seen_tag <= obs; seen <= 1'b1;
        if (obs != expect_tag) err <= 1'b1;
      end
    end
  end
endmodule

// ============================================================================================
// out-of-context wrapper: registers every boundary so the OOC run measures the lane and not
// the pads, exactly as mbxa_core_ooc and the LN lane's wrapper do.
// ============================================================================================
module mbxl_lut_ooc (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,
  input  wire [12:0] cfg_addr,
  input  wire [31:0] cfg_wdata,
  input  wire        start,
  input  wire [63:0] rd_data,
  input  wire        out_hold,
  output reg  [9:0]  rd_word,
  output reg         out_valid,
  output reg  [63:0] out_data,
  output reg         busy,
  output reg  [2:0]  err
);
  reg        r_we, r_start, r_hold;
  reg [12:0] r_addr;
  reg [31:0] r_wdata;
  reg [63:0] r_rdata;

  wire [9:0]  w_word;
  wire        w_ov, w_busy, w_idle;
  wire [63:0] w_od;
  wire [2:0]  w_err;

  always @(posedge clk) begin
    r_we <= cfg_we; r_addr <= cfg_addr; r_wdata <= cfg_wdata;
    r_start <= start; r_rdata <= rd_data; r_hold <= out_hold;
    rd_word <= w_word; out_valid <= w_ov; out_data <= w_od;
    busy <= w_busy; err <= w_err;
  end

  mbxl_lut #(.AW(10)) u_lut (
    .clk(clk), .rst(rst),
    .cfg_we(r_we), .cfg_addr(r_addr), .cfg_wdata(r_wdata),
    .start(r_start),
    .rd_word(w_word), .rd_data(r_rdata),
    .out_valid(w_ov), .out_data(w_od), .out_hold(r_hold),
    .busy(w_busy), .idle(w_idle), .err(w_err));
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = w_idle;
  /* verilator lint_on UNUSEDSIGNAL */
endmodule

/* verilator lint_on DECLFILENAME */
`default_nettype wire
