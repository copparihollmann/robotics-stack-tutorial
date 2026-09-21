// SPDX-License-Identifier: Apache-2.0
//
// Out-of-context harness for mbxr_engine: every port registered on both sides, so
// report_timing measures reg -> logic -> reg paths and the LUT count is the engine's own
// plus 2 x (port width) flip-flops of harness -- the same convention as rtl_study/rocc's
// mbx_harness.v, whose `null` row is the floor to subtract.
module mbxr_ooc_wrap #(
  parameter NCH = 4
) (
  input  wire         clk,
  input  wire         rst_i,
  input  wire         cmd_valid_i, input wire [6:0] cmd_funct_i,
  input  wire [63:0]  cmd_rs1_i, input wire [63:0] cmd_rs2_i, input wire cmd_xd_i,
  output reg          resp_valid_o, output reg [63:0] resp_data_o, output reg busy_o,
  output reg          wa_valid_o, input wire wa_ready_i, output reg [39:0] wa_addr_o,
  output reg [3:0]    wa_source_o,
  input  wire         wd_valid_i, input wire [3:0] wd_source_i, input wire [63:0] wd_data_i,
  input  wire         wd_error_i,
  output reg          aa_valid_o, input wire aa_ready_i, output reg aa_put_o,
  output reg [1:0]    aa_size_o,
  output reg [39:0]   aa_addr_o, output reg [3:0] aa_source_o, output reg [63:0] aa_data_o,
  output reg          aa_last_o,
  input  wire         ad_valid_i, input wire ad_ack_i, input wire [3:0] ad_source_i,
  input  wire [63:0]  ad_data_i, input wire ad_error_i
);
  reg rst, cmd_valid, cmd_xd, wa_ready, wd_valid, wd_error, aa_ready, ad_valid, ad_ack, ad_error;
  reg [6:0] cmd_funct; reg [63:0] cmd_rs1, cmd_rs2, wd_data, ad_data;
  reg [3:0] wd_source, ad_source;
  wire resp_valid, busy, wa_valid, aa_valid, aa_put, aa_last;
  wire [1:0] aa_size;
  wire [63:0] resp_data, aa_data; wire [39:0] wa_addr, aa_addr; wire [3:0] wa_source, aa_source;
  always @(posedge clk) begin
    rst <= rst_i; cmd_valid <= cmd_valid_i; cmd_funct <= cmd_funct_i; cmd_rs1 <= cmd_rs1_i;
    cmd_rs2 <= cmd_rs2_i; cmd_xd <= cmd_xd_i; wa_ready <= wa_ready_i; wd_valid <= wd_valid_i;
    wd_source <= wd_source_i; wd_data <= wd_data_i; wd_error <= wd_error_i;
    aa_ready <= aa_ready_i; ad_valid <= ad_valid_i; ad_ack <= ad_ack_i;
    ad_source <= ad_source_i; ad_data <= ad_data_i; ad_error <= ad_error_i;
    resp_valid_o <= resp_valid; resp_data_o <= resp_data; busy_o <= busy;
    wa_valid_o <= wa_valid; wa_addr_o <= wa_addr; wa_source_o <= wa_source;
    aa_valid_o <= aa_valid; aa_put_o <= aa_put; aa_size_o <= aa_size;
    aa_addr_o <= aa_addr; aa_source_o <= aa_source;
    aa_data_o <= aa_data; aa_last_o <= aa_last;
  end
  mbxr_engine #(.NCH(NCH)) u (
    .clk(clk), .rst(rst), .cmd_valid(cmd_valid), .cmd_funct(cmd_funct), .cmd_rs1(cmd_rs1),
    .cmd_rs2(cmd_rs2), .cmd_xd(cmd_xd), .resp_valid(resp_valid), .resp_data(resp_data),
    .busy(busy), .wa_valid(wa_valid), .wa_ready(wa_ready), .wa_addr(wa_addr),
    .wa_source(wa_source), .wd_valid(wd_valid), .wd_source(wd_source), .wd_data(wd_data),
    .wd_error(wd_error), .aa_valid(aa_valid), .aa_ready(aa_ready), .aa_put(aa_put),
    .aa_size(aa_size),
    .aa_addr(aa_addr), .aa_source(aa_source), .aa_data(aa_data), .aa_last(aa_last),
    .ad_valid(ad_valid), .ad_ack(ad_ack), .ad_source(ad_source), .ad_data(ad_data),
    .ad_error(ad_error));
endmodule
