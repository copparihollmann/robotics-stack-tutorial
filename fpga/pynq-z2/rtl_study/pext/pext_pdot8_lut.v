// -----------------------------------------------------------------------------
// 8-way int8 dot product, LUT-based multipliers + adder tree.
//
//   z = sum_{i=0..7} a.b[i] * b.b[i]        (fn[0]=1 signed, fn[0]=0 unsigned)
//   ACC=1 adds the 64-bit c operand (the 3-read-port accumulating form).
//
// Range: signed  sum in [-130048, +131072]   -> 19 bits signed
//        unsigned sum in [0, 520200]         -> 20 bits unsigned
// A 21-bit signed accumulator covers both, so one sign-extend serves both modes.
// -----------------------------------------------------------------------------
module pext_pdot8_lut #(
  parameter ACC       = 0,   // 1 = z = c + dot(a,b)
  parameter DUAL_SIGN = 1    // 1 = runtime signed/unsigned via fn[0]; 0 = signed only
) (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire sgn = DUAL_SIGN ? fn[0] : 1'b1;

  // 9-bit sign/zero-extended operands -> one signed multiplier serves both modes.
  wire signed [17:0] p [0:7];
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_mul
      wire signed [8:0] ae = {sgn & a[i*8+7], a[i*8 +: 8]};
      wire signed [8:0] be = {sgn & b[i*8+7], b[i*8 +: 8]};
      wire signed [17:0] pr;
      pext_mul9x9_lut m (.a(ae), .b(be), .p(pr));
      assign p[i] = pr;
    end
  endgenerate

  // 3-level balanced adder tree: 8 -> 4 -> 2 -> 1
  wire signed [18:0] s0 = p[0] + p[1];
  wire signed [18:0] s1 = p[2] + p[3];
  wire signed [18:0] s2 = p[4] + p[5];
  wire signed [18:0] s3 = p[6] + p[7];
  wire signed [19:0] t0 = s0 + s1;
  wire signed [19:0] t1 = s2 + s3;
  wire signed [20:0] dot = t0 + t1;

  wire [63:0] dot_x = {{43{dot[20]}}, dot};
  assign z = (ACC != 0) ? (c + dot_x) : dot_x;
endmodule
