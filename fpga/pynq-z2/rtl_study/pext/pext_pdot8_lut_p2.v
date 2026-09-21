// 8-way int8 dot product, LUT multipliers, split across 2 cycles: the multiply
// array and the first tree level in stage 1, the rest in stage 2.
module pext_pdot8_lut_p2 (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire sgn = fn[0];
  wire signed [17:0] p [0:7];
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_mul
      wire signed [8:0] ae = {sgn & a[i*8+7], a[i*8 +: 8]};
      wire signed [8:0] be = {sgn & b[i*8+7], b[i*8 +: 8]};
      assign p[i] = ae * be;
    end
  endgenerate

  wire signed [18:0] s0 = p[0] + p[1];
  wire signed [18:0] s1 = p[2] + p[3];
  wire signed [18:0] s2 = p[4] + p[5];
  wire signed [18:0] s3 = p[6] + p[7];

  reg signed [18:0] r0, r1, r2, r3;
  always @(posedge clk) begin
    r0 <= s0; r1 <= s1; r2 <= s2; r3 <= s3;
  end

  wire signed [19:0] t0 = r0 + r1;
  wire signed [19:0] t1 = r2 + r3;
  wire signed [20:0] dot = t0 + t1;
  assign z = {{43{dot[20]}}, dot};
endmodule
