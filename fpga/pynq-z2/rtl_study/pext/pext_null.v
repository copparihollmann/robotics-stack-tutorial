// The harness floor: a DUT with essentially no logic, so the fixed cost of the
// input/output registers can be subtracted from every other measurement.
module pext_null (
  input wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  assign z = a ^ b ^ c ^ {56'd0, fn};
endmodule
