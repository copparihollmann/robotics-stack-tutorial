// -----------------------------------------------------------------------------
// OOC timing harness, same idea as rtl_study/pext/pext_harness.v: every input
// and the output is registered, so report_timing measures a genuine
// reg -> logic -> reg path and the LUT column is the datapath's own cost.
//
//     synth_design -verilog_define MBX_DUT=mbx_v_mac8x4_pack ...
//
// mbx_null measures the floor the way pext_null does.
// -----------------------------------------------------------------------------
`ifndef MBX_DUT
`define MBX_DUT mbx_v_null
`endif

module mbx_harness (
  input  wire        clk,
  input  wire        rst_i,
  input  wire [63:0] a_i,
  input  wire [63:0] b_i,
  input  wire [63:0] c_i,
  input  wire [63:0] d_i,
  input  wire [15:0] ctl_i,
  output reg  [63:0] z_o
);
  reg [63:0] a_q, b_q, c_q, d_q;
  reg [15:0] ctl_q;
  reg        rst_q;
  wire [63:0] z;

  always @(posedge clk) begin
    a_q <= a_i; b_q <= b_i; c_q <= c_i; d_q <= d_i;
    ctl_q <= ctl_i; rst_q <= rst_i;
    z_o <= z;
  end

  `MBX_DUT dut (.clk(clk), .rst(rst_q), .a(a_q), .b(b_q), .c(c_q), .d(d_q),
                .ctl(ctl_q), .z(z));
endmodule

module mbx_v_null (
  input wire clk, input wire rst,
  input wire [63:0] a, b, c, d, input wire [15:0] ctl,
  output wire [63:0] z
);
  assign z = a ^ b ^ c ^ d ^ {48'd0, ctl} ^ {63'd0, rst};
endmodule
