// -----------------------------------------------------------------------------
// The decomposed alternatives to the fused ops -- the pieces a spec can pick
// from when it would rather spend an extra instruction than an extra nanosecond.
// -----------------------------------------------------------------------------

// --- accumulate helpers (the "and another add" half of a decomposed dot) ------

// packed 2 x int32 add, no saturation.  The natural accumulator step for
// pext_pdot8_2x32.
module pext_padd_2x32 (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  assign z[31:0]  = a[31:0]  + b[31:0];
  assign z[63:32] = a[63:32] + b[63:32];
endmodule

// packed 4 x int16 add with signed saturation.  The accumulator step for
// pext_pdot8_4x16 / pext_pmul8_16.
module pext_padd_4x16_sat (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  wire sub = fn[0];
  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_lane
      wire signed [15:0] av = a[i*16 +: 16];
      wire signed [15:0] bv = b[i*16 +: 16];
      wire signed [16:0] bs = sub ? -$signed({bv[15], bv}) : $signed({bv[15], bv});
      wire signed [17:0] s  = $signed({{2{av[15]}}, av}) + $signed({bs[16], bs});
      wire ovf = (s[17:15] != 3'b000) && (s[17:15] != 3'b111);
      assign z[i*16 +: 16] = ovf ? (s[17] ? 16'h8000 : 16'h7FFF) : s[15:0];
    end
  endgenerate
endmodule

// --- the requantize output stage, split in two ------------------------------

// piece 1: scale multiply + rounding arithmetic shift, 2 x int32 -> 2 x int32.
// The result stays 32-bit-per-lane so it still fits one register; the clamp and
// the pack are a separate instruction.
module pext_pqmul_2x32 #(parameter USE_DSP = "auto") (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  wire signed [15:0] scale = b[15:0];
  wire        [5:0]  sh    = b[21:16];
  wire [47:0] one_sh = 48'd1 << sh;
  wire [47:0] rnd    = (sh == 6'd0) ? 48'd0 : (one_sh >> 1);
  genvar i;
  generate
    for (i = 0; i < 2; i = i + 1) begin : g_lane
      wire signed [31:0] acc = a[i*32 +: 32];
      wire signed [47:0] prod;
      if (USE_DSP == "yes")     begin : m_dsp  pext_mul32x16_dsp  m (.a(acc), .b(scale), .p(prod)); end
      else if (USE_DSP == "no") begin : m_lut  pext_mul32x16_lut  m (.a(acc), .b(scale), .p(prod)); end
      else                      begin : m_auto pext_mul32x16_auto m (.a(acc), .b(scale), .p(prod)); end
      wire signed [48:0] sum = $signed({prod[47], prod}) + $signed({1'b0, rnd});
      wire signed [48:0] shr = sum >>> sh;
      assign z[i*32 +: 32] = shr[31:0];
    end
  endgenerate
endmodule

// piece 2: clamp 2 x int32 to int8 and pack into the low half of rd, with the
// zero point added.  No multiply, no barrel shifter.
module pext_pclamp_2x32_to_8 (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  wire signed [7:0] zp = b[31:24];
  wire [63:0] zz;
  genvar i;
  generate
    for (i = 0; i < 2; i = i + 1) begin : g_lane
      wire signed [31:0] v  = a[i*32 +: 32];
      wire signed [32:0] w  = $signed({v[31], v}) + $signed({{25{zp[7]}}, zp});
      wire hi = ~w[32] & (|w[31:7]);
      wire lo =  w[32] & ~(&w[31:7]);
      assign zz[i*8 +: 8] = hi ? 8'h7F : lo ? 8'h80 : w[7:0];
    end
    for (i = 2; i < 8; i = i + 1) begin : g_zero
      assign zz[i*8 +: 8] = 8'h00;
    end
  endgenerate
  assign z = zz;
endmodule

// the same narrowing from the int16 packed form: 4 x int16 -> 4 x int8, clamped.
// This is the pack that pairs with the depth-1 / depth-0 dot forms.
module pext_pclamp_4x16_to_8 (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  wire [63:0] zz;
  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_lane
      wire signed [15:0] v = a[i*16 +: 16];
      wire hi = ~v[15] & (|v[14:7]);
      wire lo =  v[15] & ~(&v[14:7]);
      assign zz[i*8 +: 8] = hi ? 8'h7F : lo ? 8'h80 : v[7:0];
    end
    for (i = 4; i < 8; i = i + 1) begin : g_zero
      assign zz[i*8 +: 8] = 8'h00;
    end
  endgenerate
  assign z = zz;
endmodule

// depth-2 op set: 8xint8 -> 2xint32 dot, max/min, saturating add/sub, and the
// packed 2xint32 accumulate that pairs with it.  The middle point of the ladder.
module pext_simd_alu_mid (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  wire [63:0] z_dot, z_mm, z_as, z_ac;
  pext_pdot8_2x32   u_dot (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_dot));
  pext_pmaxmin8     u_mm  (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_mm));
  pext_paddsub8_sat u_as  (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_as));
  pext_padd_2x32    u_ac  (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_ac));
  reg [63:0] sel;
  always @(*) begin
    case (fn[7:5])
      3'd0:    sel = z_dot;
      3'd1:    sel = z_mm;
      3'd2:    sel = z_as;
      3'd3:    sel = z_ac;
      default: sel = 64'd0;
    endcase
  end
  assign z = sel;
endmodule

// --- a shallow 4-op set built only from short-path pieces --------------------
// depth-1 dot, max/min, saturating add, int16->int8 clamp-and-pack.  No 48-bit
// barrel shifter, no depth-3 tree.
module pext_simd_alu_shallow (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  wire [63:0] z_dot, z_mm, z_as, z_pk;
  pext_pdot8_4x16       u_dot (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_dot));
  pext_pmaxmin8         u_mm  (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_mm));
  pext_paddsub8_sat     u_as  (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_as));
  pext_pclamp_4x16_to_8 u_pk  (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_pk));
  reg [63:0] sel;
  always @(*) begin
    case (fn[7:5])
      3'd0:    sel = z_dot;
      3'd1:    sel = z_mm;
      3'd2:    sel = z_as;
      3'd3:    sel = z_pk;
      default: sel = 64'd0;
    endcase
  end
  assign z = sel;
endmodule

// piece 1a / 1b: the two halves of pqmul, separated, to see which one costs.
// 1a -- the scale multiply alone, 2 x int32 * int16 -> the low 32 bits of each
// 48-bit product.  No shift.
module pext_pmulscale_2x32 #(parameter USE_DSP = "auto") (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  wire signed [15:0] scale = b[15:0];
  genvar i;
  generate
    for (i = 0; i < 2; i = i + 1) begin : g_lane
      wire signed [31:0] acc = a[i*32 +: 32];
      wire signed [47:0] prod;
      if (USE_DSP == "yes")     begin : m_dsp  pext_mul32x16_dsp  m (.a(acc), .b(scale), .p(prod)); end
      else if (USE_DSP == "no") begin : m_lut  pext_mul32x16_lut  m (.a(acc), .b(scale), .p(prod)); end
      else                      begin : m_auto pext_mul32x16_auto m (.a(acc), .b(scale), .p(prod)); end
      assign z[i*32 +: 32] = prod[31:0];
    end
  endgenerate
endmodule

// 1b -- the rounding arithmetic right shift alone, 2 x int32 by a register
// amount.  No multiply.
module pext_pshift_2x32 (
  input  wire clk, input wire [63:0] a, input wire [63:0] b, input wire [63:0] c,
  input wire [7:0] fn, output wire [63:0] z
);
  wire [4:0] sh = b[20:16];
  wire [31:0] rnd = (sh == 5'd0) ? 32'd0 : (32'd1 << (sh - 5'd1));
  genvar i;
  generate
    for (i = 0; i < 2; i = i + 1) begin : g_lane
      wire signed [32:0] v = $signed({a[i*32+31], a[i*32 +: 32]}) + $signed({1'b0, rnd});
      wire signed [32:0] s = v >>> sh;
      assign z[i*32 +: 32] = s[31:0];
    end
  endgenerate
endmodule
