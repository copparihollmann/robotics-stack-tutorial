// SPDX-License-Identifier: Apache-2.0
//
// mbxr_lanes -- the attention unit and the normalisation lane, in one unit, inside
// mbxr_engine.  This is the merge patch the two lane workstreams agreed on
// (LAYERNORM_LANE.md s11, ATTENTION_UNIT.md s7): the config space widens to
//
//     cfg_addr = {lane[2:0], local[12:0]}
//       lane 0  unit registers of mbxa_core   (its own 0x200..0x3FF space)
//       lane 1  mbxr_smx inside mbxa_core     (its own 0x000..0x1FF space)
//       lane 2  mbxr_ln                       (its own 13-bit space, unchanged)
//       lane 3  this unit's LN streamer
//       lane 4..7  free -- s8.14's T4 wants LUT, add and rotary lanes
//
// and NEITHER LANE'S INTERNAL DECODE CHANGES.  That is the whole point of the contract: the
// committed out-of-context numbers for mbxa_core (2,358 LUT) and mbxr_ln (2,251 LUT) are the
// numbers for the files this instantiates, unedited.  The widening is the four comparisons
// below.
//
// WHAT EACH LANE IS GIVEN, and why it is free:
//   * mbxa_core was written against the engine's own interfaces -- it drives the scratchpad
//     read address, feeds the shared mbxr_mac through s0_*/act_sel/p_rdata, reads the
//     accumulators back, and hands 64-bit words to mbxr_st.  So it shares the engine's MAC
//     array rather than bringing its own: 10 DSP48E1, not 42.
//   * mbxr_ln streams one element per handshake, so it gets a streamer here: a 2-word
//     prefetch off the same scratchpad port and a packer back into the same drain.
//
// ONLY ONE PATH OWNS THE SCRATCHPAD AND THE DRAIN AT A TIME.  `own` is set by the engine's
// lgo command and cleared when that path goes quiet; while it is 0 the engine's own tseq and
// pack path have both, and every mux below selects the engine.  A start while busy is
// refused by the engine's decode, not here.
//
// NOT VERIFIED BY A TESTBENCH OF ITS OWN.  The two lanes are verified in their own
// directories (attn_unit/, ln_lane/) and the engine gate tb_mbxr runs on the merged
// mbxr_engine.v with the lanes idle, which is what proves the merge does not disturb the
// engine.  The streamer and the ownership arbitration below are checked by neither, and the
// build log and MAGIC_REGISTRY say so.

`default_nettype none

module mbxr_lanes #(
  parameter NCH     = 4,
  parameter AW      = 10,
  parameter PRAW    = 7,
  parameter DIV_BPC = 6,
  parameter LN_KL2  = 9,
  parameter LN_TL2  = 9,
  parameter LN_OFW  = 4
) (
  input  wire        clk,
  input  wire        rst,
  // ---- configuration: {lane[2:0], local[12:0]} ----------------------------------------
  input  wire        cfg_we,
  input  wire [15:0] cfg_addr,
  input  wire [31:0] cfg_wdata,
  // ---- starts, one cycle each, and the buffers cfg named -------------------------------
  input  wire        go_attn,
  input  wire        go_ln,
  input  wire        go_lut,
  input  wire        abuf,
  input  wire        wbuf,
  // ---- the engine's scratchpad, addressed as mbxr_engine addresses it -------------------
  //      (the weight ports are read by the shared MAC, not here: only port 0 is used)
  output wire [(NCH+1)*16-1:0] rd_addr,
  /* verilator lint_off UNUSEDSIGNAL */
  input  wire [(NCH+1)*64-1:0] rd_data,
  /* verilator lint_on UNUSEDSIGNAL */
  output wire        rd_own,
  // ---- the engine's shared MAC array ----------------------------------------------------
  output wire        s0_valid,
  output wire        s0_clr,
  output wire        s0_last,
  output wire        act_sel,
  output wire [63:0] p_rdata,
  input  wire [32*NCH-1:0] acc,
  input  wire        acc_valid,
  // ---- the engine's drain ---------------------------------------------------------------
  output wire        out_valid,
  output wire [63:0] out_data,
  input  wire        out_hold,
  output wire        out_own,
  // ---- status ----------------------------------------------------------------------------
  output wire        busy,
  output wire        go_bad,          // a refused lgo: the word range does not fit the buffer
  output wire [31:0] status
);
  localparam NRD = NCH + 1;

  // status[10:0] carries r_left, which is bounded by go_bad's word-range refusal at 2^AW.
  // If AW ever changes, the field must change with it -- this fails elaboration rather than
  // letting the field truncate silently (LAYERNORM_LANE.md s15.4a's failure class).
  generate
    if (AW != 10) begin : g_aw_check
      $error("mbxr_lanes: status[10:0] assumes AW == 10; widen the field with AW");
    end
  endgenerate

  // ======================================================================================
  // the widened configuration space: four comparisons, and each lane's own map beneath
  // ======================================================================================
  wire [2:0]  cl_lane  = cfg_addr[15:13];
  wire [12:0] cl_local = cfg_addr[12:0];

  wire        a_cfg_we   = cfg_we && ((cl_lane == 3'd0) || (cl_lane == 3'd1));
  // lane 0 is mbxa_core's unit space (its bit 9 set), lane 1 the softmax lane's
  wire [9:0]  a_cfg_addr = {(cl_lane == 3'd0), cl_local[8:0]};
  wire        l_cfg_we   = cfg_we && (cl_lane == 3'd2);
  wire        s_cfg_we   = cfg_we && (cl_lane == 3'd3);
  // lane 4: mbxl_lut's own 13-bit space, unchanged -- the fifth comparison, and no other
  // lane's internal decode moves.  Lanes 5..7 stay free.
  wire        u_cfg_we   = cfg_we && (cl_lane == 3'd4);

  // ---- lane 3: the LN streamer's own registers -------------------------------------------
  //   0 first scratchpad word   1 words to read   2 K   3 {two_pass, out16, in16}
  //
  // two_pass replays the word range ONCE, which is what mbxr_ln's two-pass mode needs: the
  // lane reduces the first copy to S and Q and applies R to the second.  It replays the whole
  // range, so a two-pass dispatch is ONE row -- which is what GroupNorm is (N=1, C=288,
  // HW=999, K=287,712, a single reduction over the sample).  See LAYERNORM_LANE.md s18.
  reg [15:0] sr_word0, sr_words;
  reg [19:0] sr_k;
  reg        sr_in16, sr_out16, sr_tp;
  reg        pass2;                    // the replay is under way
  always @(posedge clk) begin
    if (rst) begin
      sr_word0 <= 16'd0; sr_words <= 16'd0; sr_k <= 20'd1;
      sr_in16 <= 1'b0; sr_out16 <= 1'b0; sr_tp <= 1'b0;
    end else if (s_cfg_we) begin
      case (cl_local[2:0])
        3'd0: sr_word0 <= cfg_wdata[15:0];
        3'd1: sr_words <= cfg_wdata[15:0];
        3'd2: sr_k     <= cfg_wdata[19:0];
        3'd3: begin sr_in16 <= cfg_wdata[0]; sr_out16 <= cfg_wdata[1];
                    sr_tp <= cfg_wdata[2]; end
        default: ;
      endcase
    end
  end

  // ---- the word range must fit the activation buffer ------------------------------------
  // The buffer is 2**AW words and rd_addr[0] carries AW of them, so a range past it WRAPS and
  // the lane returns a confident wrong answer.  The engine's own activation mapper refuses
  // exactly this (pa_bad); a lane quieter than the engine about the same mistake is an
  // inconsistency a kernel author pays for, so this refuses the dispatch instead.
  wire [16:0] sr_end    = {1'b0, sr_word0} + {1'b0, sr_words};
  wire        words_bad = (sr_end > {{(16-AW){1'b0}}, 1'b1, {AW{1'b0}}}) || (sr_words == 16'd0);
  wire        go_ln_ok  = go_ln && !words_bad;
  assign      go_bad    = go_ln && words_bad;

  // ======================================================================================
  // ownership: 0 the engine, 1 the attention unit, 2 the normalisation lane
  // ======================================================================================
  reg  [1:0] own;
  reg  [3:0] guard;                      // a start is not "finished" for a few cycles
  wire       a_busy, a_idle;
  wire [3:0] a_err;
  wire       l_idle;
  wire [5:0] l_err;
  wire       ln_drained;                 // the streamer has nothing left anywhere

  always @(posedge clk) begin
    if (rst) begin
      own <= 2'd0; guard <= 4'd0;
    end else begin
      if (guard != 4'd0) guard <= guard - 4'd1;
      if (own == 2'd0) begin
        if (go_attn)    begin own <= 2'd1; guard <= 4'd15; end
        else if (go_ln_ok) begin own <= 2'd2; guard <= 4'd15; end
        else if (go_lut)   begin own <= 2'd3; guard <= 4'd15; end
      end else if (guard == 4'd0) begin
        if (own == 2'd1 && a_idle && !a_busy)      own <= 2'd0;
        else if (own == 2'd2 && ln_drained && l_idle) own <= 2'd0;
        else if (own == 2'd3 && u_idle)               own <= 2'd0;
      end
    end
  end
  wire attn_on = (own == 2'd1);
  wire ln_on   = (own == 2'd2);
  wire lut_on  = (own == 2'd3);
  assign rd_own  = (own != 2'd0);
  assign out_own = (own != 2'd0);
  assign busy    = (own != 2'd0);

  // ======================================================================================
  // the attention unit: mbxa_core, sharing the engine's mbxr_mac
  // ======================================================================================
  wire [AW-1:0] a_aaddr, a_waddr;
  wire          a_ov;
  wire [63:0]   a_od;

  mbxa_core #(.NCH(NCH), .AW(AW), .PRAW(PRAW), .DIV_BPC(DIV_BPC)) u_attn (
    .clk(clk), .rst(rst),
    .cfg_we(a_cfg_we), .cfg_addr(a_cfg_addr), .cfg_wdata(cfg_wdata),
    .start(go_attn && (own == 2'd0)),
    .a_addr(a_aaddr), .w_addr(a_waddr),
    .s0_valid(s0_valid), .s0_clr(s0_clr), .s0_last(s0_last),
    .act_sel(act_sel), .p_rdata(p_rdata),
    .acc(acc), .acc_valid(acc_valid),
    .out_valid(a_ov), .out_data(a_od), .out_hold(out_hold),
    .busy(a_busy), .idle(a_idle), .err(a_err));

  // ======================================================================================
  // the normalisation lane and its streamer
  // ======================================================================================
  // Input: a 2-word prefetch off scratchpad port 0.  `e` is the word being drained and `h`
  // the one behind it, so the two cycles a refill costs hide inside the eight (or four) the
  // current word takes to drain and the lane sees one element per cycle.
  reg  [15:0] r_word, r_left;
  reg         r_pend;
  reg         h_have;
  reg  [63:0] h_word;
  reg         e_have;
  reg  [63:0] e_sh;
  reg  [3:0]  e_cnt;
  reg  [19:0] r_pos;

  wire [3:0]  epw_last = sr_in16 ? 4'd3 : 4'd7;
  wire        l_iv     = e_have;
  wire        l_ir;
  wire        l_ifire  = l_iv && l_ir;
  wire [15:0] l_idata  = sr_in16 ? e_sh[15:0] : {8'd0, e_sh[7:0]};
  wire        l_ilast  = (r_pos == sr_k - 20'd1);
  wire        e_last_el = (e_cnt == epw_last);
  wire        r_issue  = ln_on && !r_pend && !h_have && (r_left != 16'd0);

  assign ln_drained = (r_left == 16'd0) && !r_pend && !h_have && !e_have;

  always @(posedge clk) begin
    if (rst) begin
      r_word <= 16'd0; r_left <= 16'd0; r_pend <= 1'b0;
      h_have <= 1'b0; e_have <= 1'b0; e_cnt <= 4'd0; r_pos <= 20'd0; pass2 <= 1'b0;
    end else if (go_ln_ok && (own == 2'd0)) begin
      r_word <= sr_word0; r_left <= sr_words; r_pend <= 1'b0; pass2 <= 1'b0;
      h_have <= 1'b0; e_have <= 1'b0; e_cnt <= 4'd0; r_pos <= 20'd0;
    end else begin
      r_pend <= r_issue;
      if (r_issue) begin
        if (sr_tp && !pass2 && (r_left == 16'd1)) begin
          r_word <= sr_word0; r_left <= sr_words; pass2 <= 1'b1;   // the replay
        end else begin
          r_word <= r_word + 16'd1; r_left <= r_left - 16'd1;
        end
      end

      // the word read last cycle is on rd_data now
      if (r_pend) begin
        if (!e_have || (l_ifire && e_last_el)) begin
          e_sh <= rd_data[63:0]; e_have <= 1'b1; e_cnt <= 4'd0;
        end else begin
          h_word <= rd_data[63:0]; h_have <= 1'b1;
        end
      end else if (l_ifire && e_last_el) begin
        if (h_have) begin
          e_sh <= h_word; e_have <= 1'b1; e_cnt <= 4'd0; h_have <= 1'b0;
        end else begin
          e_have <= 1'b0;
        end
      end

      if (l_ifire) begin
        if (!e_last_el) begin
          e_sh  <= sr_in16 ? {16'd0, e_sh[63:16]} : {8'd0, e_sh[63:8]};
          e_cnt <= e_cnt + 4'd1;
        end
        r_pos <= l_ilast ? 20'd0 : (r_pos + 20'd1);
      end
    end
  end

  wire        l_ov, l_olast;
  wire [15:0] l_odata;
  wire        l_or = !out_hold;

  mbxr_ln #(.KL2(LN_KL2), .TL2(LN_TL2), .OFW(LN_OFW)) u_ln (
    .clk(clk), .rst(rst),
    .cfg_we(l_cfg_we), .cfg_addr(cl_local), .cfg_wdata(cfg_wdata),
    .in_valid(l_iv), .in_ready(l_ir), .in_data(l_idata), .in_last(l_ilast),
    .out_valid(l_ov), .out_ready(l_or), .out_data(l_odata), .out_last(l_olast),
    .idle(l_idle), .err(l_err));

  // ======================================================================================
  // lane 4: the LUT lane.  No MAC, no accumulator, no p_rdata -- it reads one scratchpad
  // word, looks eight bytes up in parallel and hands one drain word back.  It refuses a
  // range that leaves the buffer itself (err[2], checked at start from its own latched
  // registers, before any word is read), so the engine's go_bad does not need to cover it.
  // ======================================================================================
  wire [AW-1:0] u_word;
  wire          u_ov, u_busy, u_idle;
  wire [63:0]   u_od;
  wire [2:0]    u_err;

  mbxl_lut #(.AW(AW)) u_lut (
    .clk(clk), .rst(rst),
    .cfg_we(u_cfg_we), .cfg_addr(cl_local), .cfg_wdata(cfg_wdata),
    .start(go_lut && (own == 2'd0)),
    .rd_word(u_word), .rd_data(rd_data[63:0]),
    .out_valid(u_ov), .out_data(u_od), .out_hold(out_hold),
    .busy(u_busy), .idle(u_idle), .err(u_err));
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused_u = u_busy;
  /* verilator lint_on UNUSEDSIGNAL */

  wire        p_ov;
  wire [63:0] p_od;
  mbxr_lnpk u_lnpk (
    .clk(clk), .rst(rst),
    .in_valid(l_ov && l_or), .in_data(l_odata), .in_last(l_olast), .wide(sr_out16),
    .out_valid(p_ov), .out_word(p_od));

  // ======================================================================================
  // the muxes the engine reads
  // ======================================================================================
  assign rd_addr[0 +: 16] = lut_on ? {5'd0, abuf, u_word}
                          : ln_on  ? {5'd0, abuf, r_word[AW-1:0]}
                                   : {5'd0, abuf, a_aaddr};
  genvar gp;
  generate
    for (gp = 1; gp < NRD; gp = gp + 1) begin : g_wport
      assign rd_addr[gp*16 +: 16] = {5'd0, wbuf, a_waddr};
    end
  endgenerate

  assign out_valid = lut_on ? u_ov : ln_on ? p_ov : (attn_on && a_ov);
  assign out_data  = lut_on ? u_od : ln_on ? p_od : a_od;

  // r_left cannot exceed 1,024 now that go_bad refuses a wider range, so 11 bits carry it and
  // bits [15:11] fall free.  THE LUT LANE'S FIELDS GO THERE AND NOTHING ELSE MOVES: own,
  // ln_drained, l_idle, a_idle, a_busy, l_err and a_err keep the exact bit positions they have
  // today, so `lst`'s existing decode is unchanged and the driver's change is one width
  // constant plus two new accessors.  r_left[10:0] is written as r_left[AW:0] with an
  // elaboration check that AW == 10, so the field and the refusal that bounds it move together
  // or fail loudly rather than truncating in silence.
  //
  //   [31:30] own    [29] ln_drained  [28] l_idle  [27] a_idle  [26] a_busy
  //   [25:20] l_err  [19:16] a_err    [15:13] u_err  [12] u_idle  [11] reserved
  //   [10:0]  r_left
  assign status = {own, ln_drained, l_idle, a_idle, a_busy, l_err, a_err,
                   u_err, u_idle, 1'b0, r_left[AW:0]};
endmodule

// ---- 8 bytes or 4 halfwords into a 64-bit drain word ---------------------------------------
/* verilator lint_off DECLFILENAME */
module mbxr_lnpk (
  input  wire        clk,
  input  wire        rst,
  input  wire        in_valid,
  input  wire [15:0] in_data,
  input  wire        in_last,
  input  wire        wide,
  output reg         out_valid,
  output reg  [63:0] out_word
);
  /* verilator lint_off UNUSEDSIGNAL */
  reg  [63:0] sh;          // sh[7:0] is always shifted out before it is read
  /* verilator lint_on UNUSEDSIGNAL */
  reg  [3:0]  cnt;
  wire [3:0]  lastn = wide ? 4'd3 : 4'd7;
  wire [63:0] nsh   = wide ? {in_data, sh[63:16]} : {in_data[7:0], sh[63:8]};
  wire [7:0]  sha   = wide ? ({4'd0, (4'd3 - cnt)} << 4) : ({4'd0, (4'd7 - cnt)} << 3);
  always @(posedge clk) begin
    out_valid <= 1'b0;
    if (rst) begin
      cnt <= 4'd0; sh <= 64'd0;
    end else if (in_valid) begin
      if (cnt == lastn) begin
        out_valid <= 1'b1; out_word <= nsh; cnt <= 4'd0; sh <= 64'd0;
      end else if (in_last) begin
        out_valid <= 1'b1; out_word <= nsh >> sha; cnt <= 4'd0; sh <= 64'd0;
      end else begin
        sh <= nsh; cnt <= cnt + 4'd1;
      end
    end
  end
endmodule
/* verilator lint_on DECLFILENAME */

`default_nettype wire
