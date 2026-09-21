// -----------------------------------------------------------------------------
// Packed max / min, 8 x int8.  ReLU is pmax8 against a zero register; maxpool is
// a chain of pmax8.
//   fn[0] : 1 = max, 0 = min
//   fn[1] : 1 = signed, 0 = unsigned
// -----------------------------------------------------------------------------
module pext_pmaxmin8 (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire do_max = fn[0];
  wire sgn    = fn[1];
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_lane
      wire [7:0] av = a[i*8 +: 8];
      wire [7:0] bv = b[i*8 +: 8];
      // one 9-bit subtract serves signed and unsigned: flip the sign bits when signed
      wire [8:0] ax = {sgn ^ av[7], av[6:0], 1'b1};
      wire [8:0] bx = {sgn ^ bv[7], bv[6:0], 1'b0};
      wire       agt = ax > bx;           // a > b in the selected ordering
      assign z[i*8 +: 8] = (agt == do_max) ? av : bv;
    end
  endgenerate
endmodule
