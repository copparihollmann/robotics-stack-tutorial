// -----------------------------------------------------------------------------
// 8-way int8 dot product with EXPLICITLY INSTANTIATED DSP48E1 primitives.
//
// Two reasons this exists rather than relying on inference:
//
//  1. Vivado 2023.1 SEGFAULTS on the inferred version.  With eight inferred 9x9
//     multipliers feeding a balanced adder tree, synthesis crashes in
//     HARTGDspAbsorbTernaryAdder::repositionAnchorDsp() while trying to fold the
//     tree into the DSP post-adder cascade.  See PEXT_FEASIBILITY.md.
//  2. Inference hides the packing question.  A DSP48E1 is 25x18.  Two 8x8
//     products fit one multiplier only when they SHARE an operand:
//        A = a1<<17 | a0 (25 bits), B = b  ->  a1*b<<17 + a0*b
//     For a dot product of two independent registers both operands must be
//     packed, and then the cross terms a0*b1 and a1*b0 land inside the wanted
//     fields: separating them needs min(k,m) >= 16 and B is only 18 bits wide,
//     so m <= 10.  There is no packing.  One product per DSP, eight DSPs.
//
// The adder tree is deliberately NOT cascaded through PCIN: an 8-deep
// combinational P-cascade is far slower than a 3-level LUT tree.  It is built in
// fabric in a module marked use_dsp = "no".
//
// PIPE = 0 : A/B/M/P registers all bypassed -- purely combinational
// PIPE = 1 : MREG used -- the product is registered, 2-cycle latency
// -----------------------------------------------------------------------------
module pext_pdot8_dsp48 #(
  parameter PIPE = 0
) (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire sgn = fn[0];
  wire [17:0] p [0:7];

  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_dsp
      wire [8:0]  ae = {sgn & a[i*8+7], a[i*8 +: 8]};
      wire [8:0]  be = {sgn & b[i*8+7], b[i*8 +: 8]};
      wire [29:0] dsp_a = {{21{ae[8]}}, ae};
      wire [17:0] dsp_b = {{9{be[8]}},  be};
      wire [47:0] dsp_p;
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
      ) u_dsp (
        .A(dsp_a), .B(dsp_b), .C(48'd0), .D(25'd0),
        .P(dsp_p), .PCOUT(), .ACOUT(), .BCOUT(),
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
      assign p[i] = dsp_p[17:0];
    end
  endgenerate

  pext_dsp_addtree u_tree (
    .p0(p[0]), .p1(p[1]), .p2(p[2]), .p3(p[3]),
    .p4(p[4]), .p5(p[5]), .p6(p[6]), .p7(p[7]), .z(z));
endmodule

// Kept in fabric on purpose: a combinational 8-deep DSP P-cascade is much slower
// than three levels of CARRY4.
(* use_dsp = "no" *)
module pext_dsp_addtree (
  input  wire [17:0] p0, p1, p2, p3, p4, p5, p6, p7,
  output wire [63:0] z
);
  wire signed [18:0] s0 = $signed(p0) + $signed(p1);
  wire signed [18:0] s1 = $signed(p2) + $signed(p3);
  wire signed [18:0] s2 = $signed(p4) + $signed(p5);
  wire signed [18:0] s3 = $signed(p6) + $signed(p7);
  wire signed [19:0] t0 = s0 + s1;
  wire signed [19:0] t1 = s2 + s3;
  wire signed [20:0] dot = t0 + t1;
  assign z = {{43{dot[20]}}, dot};
endmodule

module pext_v_dot8_dsp48    (input wire clk, input wire [63:0] a, b, c, input wire [7:0] fn, output wire [63:0] z);
  pext_pdot8_dsp48 #(.PIPE(0)) u (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z));
endmodule
module pext_v_dot8_dsp48_p2 (input wire clk, input wire [63:0] a, b, c, input wire [7:0] fn, output wire [63:0] z);
  pext_pdot8_dsp48 #(.PIPE(1)) u (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z));
endmodule
