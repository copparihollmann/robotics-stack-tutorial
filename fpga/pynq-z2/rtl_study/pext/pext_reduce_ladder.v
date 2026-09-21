// -----------------------------------------------------------------------------
// The int8 multiply-reduce ladder, at four reduction depths.  Same 8x8 multiply
// array underneath; the only difference is how much of the adder tree is inside
// the instruction.  Depth is what costs path delay here, so this is the axis the
// spec should be traded along.
//
//   depth 0  pext_pmul8_16      4 x (int8*int8) -> 4 x int16   (low or high half)
//   depth 1  pext_pdot8_4x16    8 x int8 pairwise-dot -> 4 x int16
//   depth 2  pext_pdot8_2x32    8 x int8 -> 2 x int32 (4 terms each)
//   depth 3  pext_pdot8_lut     8 x int8 -> 1 x int64          (in pext_pdot8_lut.v)
//
// fn[0] : 1 = signed, 0 = unsigned
// fn[2] : (pmul8_16 only) 1 = high half of the operands, 0 = low half
// -----------------------------------------------------------------------------

// depth 0 -- no adder tree at all.  4 products of the selected half.
module pext_pmul8_16 (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire sgn = fn[0];
  wire hi  = fn[2];
  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_lane
      wire [2:0] k = hi ? (i + 4) : i;
      wire [7:0] av = a[k*8 +: 8];
      wire [7:0] bv = b[k*8 +: 8];
      wire signed [8:0] ae = {sgn & av[7], av};
      wire signed [8:0] be = {sgn & bv[7], bv};
      wire signed [17:0] p = ae * be;
      assign z[i*16 +: 16] = p[15:0];
    end
  endgenerate
endmodule

// depth 1 -- one adder level.  z.h[j] = a.b[2j]*b.b[2j] + a.b[2j+1]*b.b[2j+1]
module pext_pdot8_4x16 (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire sgn = fn[0];
  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_lane
      wire signed [8:0] a0 = {sgn & a[(2*i)*8+7],   a[(2*i)*8   +: 8]};
      wire signed [8:0] b0 = {sgn & b[(2*i)*8+7],   b[(2*i)*8   +: 8]};
      wire signed [8:0] a1 = {sgn & a[(2*i+1)*8+7], a[(2*i+1)*8 +: 8]};
      wire signed [8:0] b1 = {sgn & b[(2*i+1)*8+7], b[(2*i+1)*8 +: 8]};
      wire signed [17:0] p0 = a0 * b0;
      wire signed [17:0] p1 = a1 * b1;
      wire signed [18:0] s  = p0 + p1;
      assign z[i*16 +: 16] = s[15:0];
    end
  endgenerate
endmodule

// depth 2 -- two adder levels.  z.w[j] = sum of the 4 products in that half.
module pext_pdot8_2x32 (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire sgn = fn[0];
  genvar i, j;
  generate
    for (j = 0; j < 2; j = j + 1) begin : g_half
      wire signed [17:0] p [0:3];
      for (i = 0; i < 4; i = i + 1) begin : g_mul
        wire [2:0] k = 4*j + i;
        wire signed [8:0] ae = {sgn & a[k*8+7], a[k*8 +: 8]};
        wire signed [8:0] be = {sgn & b[k*8+7], b[k*8 +: 8]};
        assign p[i] = ae * be;
      end
      wire signed [18:0] s0 = p[0] + p[1];
      wire signed [18:0] s1 = p[2] + p[3];
      wire signed [19:0] s  = s0 + s1;
      assign z[j*32 +: 32] = {{12{s[19]}}, s};
    end
  endgenerate
endmodule
