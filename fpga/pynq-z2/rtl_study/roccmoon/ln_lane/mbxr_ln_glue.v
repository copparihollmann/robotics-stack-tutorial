// SPDX-License-Identifier: Apache-2.0
//
// mbxr_ln_glue -- the LN half of merge/mbxr_lanes.v, wired to the engine's REAL scratchpad, so
// tb_lnglue.cpp can check the part that no other testbench sees.
//
// What is uncovered without this, and why no existing suite can see it (LAYERNORM_LANE.md
// s13.3, s16.5):
//   * ln_lane/tb_ln.cpp drives mbxr_ln's own valid/ready ports directly.  It never sees the
//     streamer that turns 64-bit scratchpad words into that stream, nor the packer that turns
//     the result back into 64-bit drain words.
//   * the merged engine's gate, tb_mbxr, runs with the lanes IDLE by construction.
//   * the attention track's mbxa_glue.v covers mbxa_core through the same mbxr_lanes, but not
//     this path -- it declined the LN half because it could not ground the byte order against
//     anything it had verified.  This can: the q16 reference kernels are the ground truth.
//
// So the defects this and only this can find are: element order out of a scratchpad word,
// in_last placement against K, byte and halfword order into the drain, the int8/int16 width
// switches, back-pressure through out_hold, and whether ownership is returned.
//
// The scratchpad is the real mbxd_spad2 at the engine's geometry, not a behavioural model, so
// the one-cycle registered read the streamer is written against is the one it gets.

`default_nettype none

module mbxr_ln_glue #(
  parameter NCH    = 4,
  parameter AW     = 10,
  parameter LN_KL2 = 9,
  parameter LN_TL2 = 9,
  parameter LN_OFW = 4
) (
  input  wire        clk,
  input  wire        rst,
  // configuration, in the merged unit's own {lane[2:0], local[12:0]} space
  input  wire        cfg_we,
  input  wire [15:0] cfg_addr,
  input  wire [31:0] cfg_wdata,
  // start, and the activation buffer the engine's cfg would have named
  input  wire        go_ln,
  input  wire        abuf,
  // the scratchpad's activation write port, so the testbench can load a row
  input  wire        sp_we,
  input  wire [15:0] sp_word,
  input  wire [63:0] sp_data,
  // the engine's drain, as mbxr_st would see it
  output wire        out_valid,
  output wire [63:0] out_data,
  input  wire        out_hold,
  // status
  output wire        busy,
  output wire        go_bad,
  output wire        rd_own,
  output wire        out_own,
  output wire [31:0] status
);
  localparam NRD = NCH + 1;

  wire [NRD*16-1:0] rd_addr;
  wire [NRD*64-1:0] rd_data;

  mbxd_spad2 #(.NRD(NRD), .GRP(4), .DEPTH(512)) u_sp (
    .clk(clk), .rd_addr(rd_addr), .rd_data(rd_data),
    .wa_clk(clk), .wa_en(sp_we), .wa_word(sp_word), .wa_data(sp_data),
    .ww_clk(clk), .ww_en(1'b0), .ww_word(16'd0), .ww_data(64'd0));

  /* verilator lint_off PINCONNECTEMPTY */
  mbxr_lanes #(.NCH(NCH), .AW(AW), .LN_KL2(LN_KL2), .LN_TL2(LN_TL2), .LN_OFW(LN_OFW)) u_lanes (
    .clk(clk), .rst(rst),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
    .go_attn(1'b0), .go_ln(go_ln), .go_lut(1'b0), .abuf(abuf), .wbuf(1'b0),
    .rd_addr(rd_addr), .rd_data(rd_data), .rd_own(rd_own),
    // the attention unit is idle here, so the shared MAC's ports are left open
    .s0_valid(), .s0_clr(), .s0_last(), .act_sel(), .p_rdata(),
    .acc({(32*NCH){1'b0}}), .acc_valid(1'b0),
    .out_valid(out_valid), .out_data(out_data), .out_hold(out_hold), .out_own(out_own),
    .busy(busy), .go_bad(go_bad), .status(status));
  /* verilator lint_on PINCONNECTEMPTY */
endmodule

`default_nettype wire
