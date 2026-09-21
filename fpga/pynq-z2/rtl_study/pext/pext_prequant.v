// -----------------------------------------------------------------------------
// Requantize-and-pack: the output stage of a quantized layer.
//
//   per lane:  q = clamp_int8( ((acc * scale) + (1 << (sh-1))) >>> sh  +  zp )
//
//   a (+ b when LANES=4) : int32 accumulators, 2 per 64-bit register
//   control register     : [15:0] scale (int16 signed)
//                          [21:16] sh   (0..47)
//                          [31:24] zp   (int8)
//   z[8*LANES-1:0]       : packed int8 results
//
// LANES=2 is the 2-read form (rs1 = accumulators, rs2 = control).
// LANES=4 needs 128 bits of accumulator, i.e. a 3-read form or a CSR-held control.
// USE_DSP: "yes" forces the 32x16 multiply into DSP48E1s (2 per lane, since the
// primitive is 25x18), "no" forces a LUT array.
// -----------------------------------------------------------------------------
module pext_prequant #(
  parameter LANES   = 2,
  parameter USE_DSP = "auto"
) (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire [127:0] acc_all = {b, a};
  wire [63:0]  ctl     = (LANES == 4) ? c : b;

  wire signed [15:0] scale = ctl[15:0];
  wire        [5:0]  sh    = ctl[21:16];
  wire signed [7:0]  zp    = ctl[31:24];

  // rounding constant 1 << (sh-1), 0 when sh == 0
  wire [47:0] one_sh = 48'd1 << sh;
  wire [47:0] rnd    = (sh == 6'd0) ? 48'd0 : (one_sh >> 1);

  wire [63:0] zz;
  genvar i;
  generate
    for (i = 0; i < LANES; i = i + 1) begin : g_lane
      wire signed [31:0] acc = acc_all[i*32 +: 32];
      wire signed [47:0] prod;
      if (USE_DSP == "yes")     begin : m_dsp  pext_mul32x16_dsp  m (.a(acc), .b(scale), .p(prod)); end
      else if (USE_DSP == "no") begin : m_lut  pext_mul32x16_lut  m (.a(acc), .b(scale), .p(prod)); end
      else                      begin : m_auto pext_mul32x16_auto m (.a(acc), .b(scale), .p(prod)); end
      wire signed [48:0] sum  = $signed({prod[47], prod}) + $signed({1'b0, rnd});
      wire signed [48:0] shr  = sum >>> sh;
      wire signed [49:0] wzp  = $signed({shr[48], shr}) + $signed({{42{zp[7]}}, zp});
      wire               hi   = ~wzp[49] & (|wzp[48:7]);
      wire               lo   =  wzp[49] & ~(&wzp[48:7]);
      assign zz[i*8 +: 8] = hi ? 8'h7F : lo ? 8'h80 : wzp[7:0];
    end
    for (i = LANES; i < 8; i = i + 1) begin : g_zero
      assign zz[i*8 +: 8] = 8'h00;
    end
  endgenerate
  assign z = zz;
endmodule
