// -----------------------------------------------------------------------------
// OOC timing harness.  Registers every input and the output so the routed design
// has a reg -> DUT -> reg path that report_timing can measure directly.  The DUT
// name is supplied at synthesis time:
//     synth_design -verilog_define PEXT_DUT=pext_pmaxmin8 ...
// -----------------------------------------------------------------------------
`ifndef PEXT_DUT
`define PEXT_DUT pext_pdot8_lut
`endif

module pext_harness (
  input  wire        clk,
  input  wire [63:0] a_i,
  input  wire [63:0] b_i,
  input  wire [63:0] c_i,
  input  wire [7:0]  fn_i,
  output reg  [63:0] z_o
);
  reg [63:0] a_q, b_q, c_q;
  reg [7:0]  fn_q;
  wire [63:0] z;

  always @(posedge clk) begin
    a_q  <= a_i;
    b_q  <= b_i;
    c_q  <= c_i;
    fn_q <= fn_i;
    z_o  <= z;
  end

  `PEXT_DUT dut (.clk(clk), .a(a_q), .b(b_q), .c(c_q), .fn(fn_q), .z(z));
endmodule
