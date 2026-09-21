// -----------------------------------------------------------------------------
// MBX MAC datapaths -- the arithmetic core of a streaming RoCC dot-product unit.
//
// The shape is deliberately NOT the P-extension's.  MBP.DOT8 reads two
// independent 64-bit registers and writes one; it therefore has no shared
// operand and PEXT_FEASIBILITY.md section 1.5 measured that as "no packing for a
// general packed dot product on DSP48E1: one product per DSP, eight DSPs".
//
// A RoCC unit is not a two-read one-write instruction.  It can broadcast ONE
// activation word against N weight words into N internal accumulators, and that
// is exactly the shared-operand shape section 1.5 named as "a genuine ISA lever
// if the spec wants one".  This file measures what the lever is worth.
//
//   mbx_mac8_dsp   : 8 lanes x 1 channel, 8 DSP48E1   -- the bandwidth-matched engine
//   mbx_mac8xN_dsp : 8 lanes x N channels
//        PACK=0    : one product per DSP48E1      -> 8N DSPs
//        PACK=1    : two products per DSP48E1     -> 4N DSPs
//   mbx_mac8xN_lut : the same, LUT multipliers, for the LUT/DSP comparison
//
// PACKING, in full, because getting it wrong is silent:
//
//   A = w_hi*2^16 + w_lo   (25-bit signed; |A| <= 128*65536+128 = 8.4M < 2^24)
//   B = a                  (9-bit signed activation byte)
//   P = A*B = w_hi*a*2^16 + w_lo*a
//
//   |w_lo*a| <= 16384 = 2^14, so the low product occupies P[15:0] in two's
//   complement and borrows exactly one from the high field when negative:
//
//       w_lo*a = $signed(P[15:0])
//       w_hi*a = $signed(P[31:16]) + P[15]
//
//   Shift 16 (not the usual 17 or 18) is what keeps A inside 25 bits for a FULL
//   int8 x int8 range including -128 * -128.  At shift 17, w_hi = w_lo = -128
//   gives A = -16,777,344, which is 128 outside 25-bit signed and wraps.
//
// Vivado 2023.1 segfaults inferring a DSP cascade from multipliers feeding an
// adder tree (PEXT_FEASIBILITY.md risk 4), so every DSP is instantiated and
// every adder tree is marked use_dsp = "no".
// -----------------------------------------------------------------------------

// ---- one DSP48E1, combinational or with MREG ---------------------------------
module mbx_dsp_cell #(
  parameter PIPE = 0
) (
  input  wire        clk,
  input  wire [24:0] a,      // packed weight(s), signed
  input  wire [17:0] b,      // activation, signed
  output wire [47:0] p
);
  DSP48E1 #(
    .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .USE_DPORT("FALSE"),
    .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
    .AREG(0), .BREG(0), .CREG(0), .DREG(0), .ADREG(0),
    .MREG(PIPE), .PREG(0),
    .OPMODEREG(0), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0),
    .INMODEREG(0), .ACASCREG(0), .BCASCREG(0),
    .USE_PATTERN_DETECT("NO_PATDET"), .MASK(48'h3FFFFFFFFFFF),
    .PATTERN(48'h000000000000), .SEL_MASK("MASK"), .SEL_PATTERN("PATTERN"),
    .AUTORESET_PATDET("NO_RESET")
  ) u (
    .A({{5{a[24]}}, a}), .B(b), .C(48'd0), .D(25'd0),
    .P(p), .PCOUT(), .ACOUT(), .BCOUT(),
    .CARRYOUT(), .CARRYCASCOUT(), .MULTSIGNOUT(), .OVERFLOW(), .UNDERFLOW(),
    .PATTERNDETECT(), .PATTERNBDETECT(),
    .ACIN(30'd0), .BCIN(18'd0), .PCIN(48'd0),
    .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0), .CARRYIN(1'b0),
    .CARRYINSEL(3'b000), .OPMODE(7'b0000101), .ALUMODE(4'b0000),
    .INMODE(5'b00000),
    .CLK(clk),
    .CEA1(1'b0), .CEA2(1'b0), .CEB1(1'b0), .CEB2(1'b0), .CEC(1'b0),
    .CED(1'b0), .CEAD(1'b0), .CEM(1'b1), .CEP(1'b1),
    .CEALUMODE(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b0), .CEINMODE(1'b0),
    .RSTA(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTD(1'b0), .RSTM(1'b0),
    .RSTP(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
    .RSTCTRL(1'b0), .RSTINMODE(1'b0)
  );
endmodule

// ---- 8 x int16 products -> one int32 sum, in fabric --------------------------
(* use_dsp = "no" *)
module mbx_addtree8 (
  input  wire signed [16:0] p0, p1, p2, p3, p4, p5, p6, p7,
  output wire signed [20:0] z
);
  wire signed [17:0] s0 = p0 + p1;
  wire signed [17:0] s1 = p2 + p3;
  wire signed [17:0] s2 = p4 + p5;
  wire signed [17:0] s3 = p6 + p7;
  wire signed [18:0] t0 = s0 + s1;
  wire signed [18:0] t1 = s2 + s3;
  assign z = t0 + t1;
endmodule

// -----------------------------------------------------------------------------
// N-channel MAC.  One activation word `a` (8 int8 lanes) is broadcast against N
// weight words `w`.  Each channel gets its own 64-bit accumulator, held here.
//   PACK = 0 : 8N DSP48E1
//   PACK = 1 : 4N DSP48E1 (requires N even)
// -----------------------------------------------------------------------------
module mbx_mac8xn_dsp #(
  parameter N    = 4,
  parameter PACK = 1,
  parameter PIPE = 0,
  // Accumulator width.  64 matches MBP.DOT8's int64 result and the kernels'
  // int64 accumulators, and costs 16 levels of CARRY4 per channel.  32 is
  // sufficient for every shape in these models -- the longest reduction is
  // DroNet conv_modules.8 at K = 1152, so |acc| <= 1152*128*127 = 18.7e6 < 2^31
  // -- and mbx_quant reads only acc[31:0] anyway.
  parameter ACCW = 64
) (
  input  wire              clk,
  input  wire              en,     // accumulate this cycle
  input  wire              clr,    // load instead of accumulate (bias / first group)
  input  wire [63:0]       a,      // 8 activation bytes, shared
  input  wire [64*N-1:0]   w,      // N weight words
  input  wire [63:0]       seed,   // bias for the cleared channel set
  output wire [64*N-1:0]   acc
);
  genvar c, i;
  wire signed [20:0] dot [0:N-1];
  reg  signed [ACCW-1:0] acc_q [0:N-1];

  generate
    if (PACK == 0) begin : g_nopack
      for (c = 0; c < N; c = c + 1) begin : g_ch
        wire signed [16:0] pr [0:7];
        for (i = 0; i < 8; i = i + 1) begin : g_lane
          wire [7:0]  wb = w[c*64 + i*8 +: 8];
          wire [7:0]  ab = a[i*8 +: 8];
          wire [24:0] da = {{17{wb[7]}}, wb};
          wire [17:0] db = {{10{ab[7]}}, ab};
          wire [47:0] dp;
          mbx_dsp_cell #(.PIPE(PIPE)) u (.clk(clk), .a(da), .b(db), .p(dp));
          assign pr[i] = dp[16:0];
        end
        mbx_addtree8 t (.p0(pr[0]), .p1(pr[1]), .p2(pr[2]), .p3(pr[3]),
                        .p4(pr[4]), .p5(pr[5]), .p6(pr[6]), .p7(pr[7]),
                        .z(dot[c]));
      end
    end else begin : g_pack
      // channel pair (2j, 2j+1) shares one DSP per lane
      for (c = 0; c < N/2; c = c + 1) begin : g_pair
        wire signed [16:0] plo [0:7];
        wire signed [16:0] phi [0:7];
        for (i = 0; i < 8; i = i + 1) begin : g_lane
          wire [7:0]  wlo = w[(2*c)  *64 + i*8 +: 8];
          wire [7:0]  whi = w[(2*c+1)*64 + i*8 +: 8];
          wire [7:0]  ab  = a[i*8 +: 8];
          // A = whi*2^16 + wlo, as a 25-bit signed value
          wire signed [24:0] da = ($signed({{17{whi[7]}}, whi}) <<< 16) +
                                   $signed({{17{wlo[7]}}, wlo});
          wire        [17:0] db = {{10{ab[7]}}, ab};
          wire        [47:0] dp;
          mbx_dsp_cell #(.PIPE(PIPE)) u (.clk(clk), .a(da), .b(db), .p(dp));
          // both operands explicitly signed: one unsigned term would make the
          // whole Verilog expression unsigned and silently drop the sign.
          assign plo[i] = $signed({dp[15], dp[15:0]});
          assign phi[i] = $signed({dp[31], dp[31:16]}) + $signed({16'b0, dp[15]});
        end
        mbx_addtree8 tl (.p0(plo[0]), .p1(plo[1]), .p2(plo[2]), .p3(plo[3]),
                         .p4(plo[4]), .p5(plo[5]), .p6(plo[6]), .p7(plo[7]),
                         .z(dot[2*c]));
        mbx_addtree8 th (.p0(phi[0]), .p1(phi[1]), .p2(phi[2]), .p3(phi[3]),
                         .p4(phi[4]), .p5(phi[5]), .p6(phi[6]), .p7(phi[7]),
                         .z(dot[2*c+1]));
      end
    end
  endgenerate

  generate
    for (c = 0; c < N; c = c + 1) begin : g_acc
      wire [ACCW-1:0] dx = {{(ACCW-21){dot[c][20]}}, dot[c]};
      always @(posedge clk)
        if (clr)     acc_q[c] <= seed[ACCW-1:0] + dx;
        else if (en) acc_q[c] <= acc_q[c]       + dx;
      assign acc[c*64 +: 64] = {{(64-ACCW){acc_q[c][ACCW-1]}}, acc_q[c]};
    end
  endgenerate
endmodule

// -----------------------------------------------------------------------------
// The same thing in LUTs, so the DSP saving is measured rather than assumed.
// -----------------------------------------------------------------------------
(* use_dsp = "no" *)
module mbx_mac8xn_lut #(
  parameter N = 4
) (
  input  wire            clk,
  input  wire            en,
  input  wire            clr,
  input  wire [63:0]     a,
  input  wire [64*N-1:0] w,
  input  wire [63:0]     seed,
  output wire [64*N-1:0] acc
);
  genvar c, i;
  wire signed [20:0] dot [0:N-1];
  reg  signed [63:0] acc_q [0:N-1];

  generate
    for (c = 0; c < N; c = c + 1) begin : g_ch
      wire signed [16:0] pr [0:7];
      for (i = 0; i < 8; i = i + 1) begin : g_lane
        wire signed [8:0] wb = $signed({w[c*64 + i*8 + 7], w[c*64 + i*8 +: 8]});
        wire signed [8:0] ab = $signed({a[i*8 + 7], a[i*8 +: 8]});
        assign pr[i] = wb * ab;
      end
      mbx_addtree8 t (.p0(pr[0]), .p1(pr[1]), .p2(pr[2]), .p3(pr[3]),
                      .p4(pr[4]), .p5(pr[5]), .p6(pr[6]), .p7(pr[7]),
                      .z(dot[c]));
    end
    for (c = 0; c < N; c = c + 1) begin : g_acc
      always @(posedge clk)
        if (clr)     acc_q[c] <= $signed(seed) + {{43{dot[c][20]}}, dot[c]};
        else if (en) acc_q[c] <= acc_q[c]      + {{43{dot[c][20]}}, dot[c]};
      assign acc[c*64 +: 64] = acc_q[c];
    end
  endgenerate
endmodule
