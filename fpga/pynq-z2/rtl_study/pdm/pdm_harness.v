// -----------------------------------------------------------------------------
// Registered-I/O harnesses for the out-of-context area/timing study, in the style of
// rtl_study/pext/pext_harness.v.  Every port of the DUT is driven from, or captured
// into, a flip-flop, so `report_timing -from [all_registers] -to [all_registers]`
// sees the block's own worst path and nothing about unconstrained package pins.
//
// The harnesses contribute flip-flops and no LUTs, so the LUT column in the report
// is the DUT's own cost.
// -----------------------------------------------------------------------------
module pdm_h_cic (
  input  wire clk,
  input  wire in_valid_i, in_bit_i,
  output reg  out_valid_o,
  output reg signed [19:0] out_data_o
);
  reg iv, ib;
  wire ov; wire signed [19:0] od;
  always @(posedge clk) begin
    iv <= in_valid_i; ib <= in_bit_i;
    out_valid_o <= ov; out_data_o <= od;
  end
  pdm_cic4 #(.W(20), .R(22)) dut (.clk(clk), .rst(1'b0),
    .in_valid(iv), .in_bit(ib), .out_valid(ov), .out_data(od));
endmodule

module pdm_h_fir (
  input  wire clk,
  input  wire in_valid_i,
  input  wire signed [19:0] in_data_i,
  output reg  out_valid_o, saturated_o,
  output reg signed [15:0] out_data_o
);
  reg iv; reg signed [19:0] id;
  wire ov, sat; wire signed [15:0] od;
  always @(posedge clk) begin
    iv <= in_valid_i; id <= in_data_i;
    out_valid_o <= ov; out_data_o <= od; saturated_o <= sat;
  end
  pdm_fir_mac dut (.clk(clk), .rst(1'b0),
    .in_valid(iv), .in_data(id), .out_valid(ov), .out_data(od), .saturated(sat));
endmodule

module pdm_h_dcblock (
  input  wire clk,
  input  wire in_valid_i, bypass_i,
  input  wire signed [15:0] in_data_i,
  output reg  out_valid_o,
  output reg signed [15:0] out_data_o
);
  reg iv, byp; reg signed [15:0] id;
  wire ov; wire signed [15:0] od;
  always @(posedge clk) begin
    iv <= in_valid_i; byp <= bypass_i; id <= in_data_i;
    out_valid_o <= ov; out_data_o <= od;
  end
  pdm_dcblock dut (.clk(clk), .rst(1'b0), .bypass(byp),
    .in_valid(iv), .in_data(id), .out_valid(ov), .out_data(od));
endmodule

module pdm_h_fifo (
  input  wire clk,
  input  wire wr_en_i, rd_en_i,
  input  wire [15:0] wr_data_i,
  output reg  [15:0] rd_data_o,
  output reg  empty_o, full_o, overrun_o,
  output reg  [10:0] level_o
);
  reg we, re; reg [15:0] wd;
  wire [15:0] rd; wire e, f, ov; wire [10:0] lv;
  always @(posedge clk) begin
    we <= wr_en_i; re <= rd_en_i; wd <= wr_data_i;
    rd_data_o <= rd; empty_o <= e; full_o <= f; overrun_o <= ov; level_o <= lv;
  end
  pdm_mic_fifo #(.DW(16), .ALOG2(10)) dut (.clk(clk), .rst(1'b0),
    .wr_en(we), .wr_data(wd), .rd_en(re), .rd_data(rd),
    .empty(e), .full(f), .level(lv), .overrun(ov));
endmodule

module pdm_h_capture (
  input  wire clk,
  input  wire enable_i, dc_bypass_i, pdm_m_data_i,
  output reg  pdm_m_clk_o, pcm_valid_o, settling_o, saturated_o,
  output reg signed [15:0] pcm_data_o
);
  reg en, byp, din;
  wire pclk, pv, st, sat; wire signed [15:0] pd;
  always @(posedge clk) begin
    en <= enable_i; byp <= dc_bypass_i; din <= pdm_m_data_i;
    pdm_m_clk_o <= pclk; pcm_valid_o <= pv; pcm_data_o <= pd;
    settling_o <= st; saturated_o <= sat;
  end
  pdm_mic_capture dut (.clk(clk), .rst(1'b0),
    .enable(en), .dc_bypass(byp), .pdm_m_clk(pclk), .pdm_m_data(din),
    .pcm_valid(pv), .pcm_data(pd), .settling(st), .saturated(sat));
endmodule

module pdm_h_core (
  input  wire clk,
  input  wire pdm_m_data_i, reg_wr_i, reg_rd_i,
  input  wire [3:0]  reg_addr_i,
  input  wire [31:0] reg_wdata_i,
  output reg  pdm_m_clk_o, irq_o,
  output reg [31:0] reg_rdata_o
);
  reg din, wr, rd; reg [3:0] a; reg [31:0] wd;
  wire pclk, irq; wire [31:0] rdat;
  always @(posedge clk) begin
    din <= pdm_m_data_i; wr <= reg_wr_i; rd <= reg_rd_i;
    a <= reg_addr_i; wd <= reg_wdata_i;
    pdm_m_clk_o <= pclk; irq_o <= irq; reg_rdata_o <= rdat;
  end
  pdm_mic_core dut (.clk(clk), .rst(1'b0),
    .pdm_m_clk(pclk), .pdm_m_data(din),
    .reg_addr(a), .reg_wr(wr), .reg_wdata(wd), .reg_rd(rd), .reg_rdata(rdat),
    .irq(irq));
endmodule
