// SPDX-License-Identifier: Apache-2.0
//
// mbxa_glue -- the attention unit as `merge/mbxr_lanes.v` wires it, presented with
// `mbxa_unit`'s exact port list so that attn_unit/tb_attn.cpp runs against the MERGED
// design without a line of change.
//
// AN OUT-OF-CONTEXT STUDY.  No SoC, no MAGIC, no bitstream.
//
// WHY THIS FILE EXISTS.  `mbxa_core` is verified in this directory and `mbxr_ln` in ln_lane/,
// and the merged engine's own gate (tb_mbxr, 162 cases against kernel_linear_s8) runs WITH
// THE LANES IDLE -- which is what proves the merge does not disturb revision 2a, and which
// by construction cannot see a defect in the lanes' glue.  Unchecked by either: the widened
// {lane[2:0], local[12:0]} configuration decode, the `own` arbitration, the s0_* mux into the
// shared mbxr_mac, the act_sel/p_rdata path, and the drain hand-off.  A defect in any of them
// produces a wrong byte.
//
// WHAT IT PROVES, AND WHAT IT DOES NOT.
//   * It drives the REAL merge/mbxr_lanes.v, the real mbxa_core inside it, and the real
//     mbxr_mac, through the real 16-bit configuration path.  tb_attn's 210 dispatches over
//     four models pass or they do not.
//   * `idle` here is OWNERSHIP RETURNED (`own == 0`), not the core's own idle.  So every
//     dispatch tb_attn runs is also a test that the `guard`/`a_idle` path gives the
//     scratchpad and the drain back -- if it did not, the dispatch would time out.  That is
//     the case the merge's author and this author independently guessed would break first.
//   * It does NOT test the LN lane, the LN streamer, or `own` switching BETWEEN lanes, and it
//     does not test the engine's own tseq taking the array back.  Those need mbxr_engine and
//     tb_mbxr; they are named here so the gap is visible rather than assumed covered.
//
// The 10-bit address tb_attn writes is translated here into the merged space, which is the
// inverse of mbxr_lanes' own decode and therefore also a check on it:
//     tb_attn 0x200..0x3FF (unit registers) -> lane 0, local = addr[8:0]
//     tb_attn 0x000..0x1FF (softmax lane)   -> lane 1, local = addr[8:0]

`default_nettype none

module mbxa_glue #(
  parameter NCH  = 4,
  parameter AW   = 10,
  parameter PRAW = 7,
  parameter DIV_BPC = 6
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,
  input  wire [9:0]  cfg_addr,
  input  wire [31:0] cfg_wdata,
  input  wire        start,
  output wire [(NCH+1)*16-1:0] rd_addr,
  input  wire [(NCH+1)*64-1:0] rd_data,
  input  wire        abuf,
  input  wire        wbuf,
  output wire        out_valid,
  output wire [63:0] out_data,
  input  wire        out_hold,
  output wire        busy,
  output wire        idle,
  output wire [3:0]  err
);
  // {lane[2:0], local[12:0]}: lane 0 is the unit's own registers, lane 1 the softmax lane
  wire [15:0] cfg_addr16 = {(cfg_addr[9] ? 3'd0 : 3'd1), 4'd0, cfg_addr[8:0]};

  wire        s0_valid, s0_clr, s0_last, act_sel;
  wire [63:0] p_rdata;
  wire [32*NCH-1:0] acc;
  wire        rd_own, out_own;
  wire [31:0] status;
  wire        l_busy;
  // the engine's own two stages between the lanes and the array, declared before the
  // instantiation that consumes s2_final
  reg s1_valid, s1_clr, s1_last, s1_sel;
  reg s2_final;

  mbxr_lanes #(.NCH(NCH), .AW(AW), .PRAW(PRAW), .DIV_BPC(DIV_BPC)) u_lanes (
    .clk(clk), .rst(rst),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr16), .cfg_wdata(cfg_wdata),
    .go_attn(start), .go_ln(1'b0), .abuf(abuf), .wbuf(wbuf),
    .rd_addr(rd_addr), .rd_data(rd_data), .rd_own(rd_own),
    .s0_valid(s0_valid), .s0_clr(s0_clr), .s0_last(s0_last),
    .act_sel(act_sel), .p_rdata(p_rdata), .acc(acc), .acc_valid(s2_final),
    .out_valid(out_valid), .out_data(out_data), .out_hold(out_hold), .out_own(out_own),
    .busy(l_busy), .status(status));

  // verbatim from mbxr_engine
  always @(posedge clk) begin
    if (rst) begin
      s1_valid <= 1'b0; s1_clr <= 1'b0; s1_last <= 1'b0; s2_final <= 1'b0;
    end else begin
      s1_valid <= s0_valid;
      s1_clr   <= s0_clr;
      s1_last  <= s0_last;
      s2_final <= s1_valid && s1_last;
    end
    s1_sel <= act_sel;
  end

  wire [63:0] a_word = s1_sel ? p_rdata : rd_data[63:0];

  mbxr_mac #(.NCH(NCH)) u_mac (
    .clk(clk), .valid(s1_valid), .clr(s1_clr),
    .a(a_word), .w(rd_data[64*(NCH+1)-1:64]), .acc(acc));

  // `idle` is OWNERSHIP RETURNED, so tb_attn's wait-for-idle is also the guard/a_idle test
  assign busy = l_busy;
  assign idle = ~l_busy;
  assign err  = status[19:16];      // a_err, at the offset the merge contract fixes

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, rd_own, out_own, status[31:20], status[15:0]};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
