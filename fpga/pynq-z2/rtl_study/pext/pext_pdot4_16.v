// -----------------------------------------------------------------------------
// 4-way int16 dot product -> 64-bit result.  The int16 half of the register
// view; one 16x16 product fits a DSP48E1 natively with no packing games.
//   fn[0] : 1 = signed, 0 = unsigned
// -----------------------------------------------------------------------------
module pext_pdot4_16 #(
  parameter USE_DSP = "auto"
) (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire sgn = fn[0];
  wire signed [33:0] p [0:3];
  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_mul
      wire signed [16:0] ae = {sgn & a[i*16+15], a[i*16 +: 16]};
      wire signed [16:0] be = {sgn & b[i*16+15], b[i*16 +: 16]};
      wire signed [33:0] pr;
      if (USE_DSP == "yes")     begin : m_dsp  pext_mul17x17_dsp  m (.a(ae), .b(be), .p(pr)); end
      else if (USE_DSP == "no") begin : m_lut  pext_mul17x17_lut  m (.a(ae), .b(be), .p(pr)); end
      else                      begin : m_auto pext_mul17x17_auto m (.a(ae), .b(be), .p(pr)); end
      assign p[i] = pr;
    end
  endgenerate
  wire signed [34:0] s0 = p[0] + p[1];
  wire signed [34:0] s1 = p[2] + p[3];
  wire signed [35:0] dot = s0 + s1;
  assign z = {{28{dot[35]}}, dot};
endmodule
