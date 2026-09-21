// SPDX-License-Identifier: Apache-2.0
//
// mbxa_rq -- the requantise tail of kernel_matmul_b_s8, exactly.
//
// AN OUT-OF-CONTEXT STUDY (ATTENTION_UNIT.md).  No SoC, no MAGIC, no bitstream.
//
// WHY THIS IS NOT mbxr_quant.  The engine's requantiser is bit-exact with
// kernel_linear_s8: a Q0.31 multiplier, (acc*mult + 2^30) >> 31, then (s + 2^(sh-1)) >> sh
// on the SIGNED value -- round-half-UP.  kernel_matmul_b_s8
// (modelblaster/kernels/pext_nl/pext_nl_matmul_b_s8_pext_dot8_exact.c, accuracy class
// bit_exact) reproduces a different expression, the reference's own:
//
//     v = (int32_t)roundf( (float)acc * total ),  total = (sa*sb)/(so*sdiv) in binary32
//
// with total computed once per dispatch in exact binary32 (fpga/pynq-z2/sw/fexact32.h) as
// (mt, -sh): mt is a 24-BIT MANTISSA in [2^23, 2^24), not a Q0.31 multiplier.  Three things
// differ from mbxr_quant and all three change bytes:
//
//   1. the product is rounded to 24 SIGNIFICANT bits, round-half-to-EVEN, before the final
//      rounding -- that is the float32 multiply;
//   2. the final rounding is half-AWAY-from-zero, on the MAGNITUDE, sign reapplied after;
//   3. the shift position moves per element, because it is 24 significant bits from the
//      product's own leading one, not a fixed binary point.
//
// (1) changes the answer only where it pushes the product across a half-integer -- about
// 2^-16 of elements.  Over the encoder's 1.59 M attention outputs that is a couple of dozen
// bytes, which is the difference between a golden check and no golden check at all.
//
// WHAT IS COMPUTED, and it is the kernel's own two paths collapsed into one.  The kernel
// has a fast path plus a guard G = (P >> 23) + 1 that sends near-ties to fexact32's
// pmmb_exact.  There is no need to build both: the expression below IS the reference, so it
// agrees with the fast path where the fast path is right and with pmmb_exact where it is
// not.  Checked, not asserted -- attn_unit/tb_rq.c compares this arithmetic against the
// kernel's own tail EXHAUSTIVELY over every reachable accumulator at Moonshine's two scale
// sets (6,534,914 values, 22,510 of them on the kernel's slow path, 0 differ).
//
//     neg = acc < 0;   A = |acc|                          (A < 2^24 required, see DOMAIN)
//     P   = A * mt                                        (24 x 24 -> 48, exact)
//     sh2 = max(bitlen(P) - 24, 0)
//     q   = P >> sh2, rounded half-to-even at bit sh2-1   (fx32_round)
//           if q == 2^24:  q >>= 1;  sh2 += 1             (fx32_round's renormalise)
//     d   = sh - sh2
//     mag = d <= 0  ? saturate : (q + 2^(d-1)) >> d       (fx32_roundf_i32)
//     y   = clamp(neg ? -mag : mag, amin, amax)
//
// DOMAIN.  |acc| < 2^24 -- where (float)acc is exact and fx32_round(|acc|) is the identity.
// With int8 operands that holds for every K <= 1032, which covers the kernel's own fast-path
// gate (K <= 1024) and both Moonshine shapes with room to spare: q.kT has
// |acc| <= 36*127*128 = 585,216 and p.v |acc| <= 165*127*128 = 2,682,240.  Outside it `ovf`
// rises and the byte is not to be trusted; the unit turns that into a sticky error rather
// than a wrong answer.  sh is taken in [1, 62] (the kernel's fast range is [2, 62]).
//
// Five registered stages, each with its own valid.  One lane: the array's four accumulators
// arrive at most one per cycle from mbxa_unit's serialiser, so four lanes would buy nothing.

`default_nettype none

module mbxa_rq (
  input  wire        clk,
  input  wire        rst,
  input  wire        in_valid,
  input  wire [31:0] acc,
  input  wire        in_tag,          // carried through: 0 = scores phase, 1 = p.v phase
  input  wire [23:0] mt,              // total.m, in [2^23, 2^24)
  input  wire [5:0]  sh,              // -total.e, 1..62
  input  wire [7:0]  amin,
  input  wire [7:0]  amax,
  output reg         out_valid,
  output reg  [7:0]  y,
  output reg         out_tag,
  output reg         ovf              // |acc| >= 2^24 was presented (sticky is the caller's)
);
  // ---- stage 1: magnitude and sign ------------------------------------------------------
  wire [31:0] mag32 = acc[31] ? (~acc + 32'd1) : acc;
  reg         v1, neg1, tag1, ov1;
  reg  [23:0] a1;
  reg  [5:0]  sh1;
  reg  [7:0]  lo1, hi1;
  reg  [23:0] mt1;
  always @(posedge clk) begin
    if (rst) v1 <= 1'b0; else v1 <= in_valid;
    neg1 <= acc[31];
    tag1 <= in_tag;
    a1   <= mag32[23:0];
    ov1  <= |mag32[31:24];
    mt1  <= mt;
    sh1  <= sh;
    lo1  <= amin;
    hi1  <= amax;
  end

  // ---- stage 2: the exact 24 x 24 product ------------------------------------------------
  reg         v2, neg2, tag2, ov2;
  reg  [47:0] p2;
  reg  [5:0]  sh2c;
  reg  [7:0]  lo2, hi2;
  always @(posedge clk) begin
    if (rst) v2 <= 1'b0; else v2 <= v1;
    neg2 <= neg1; tag2 <= tag1; ov2 <= ov1;
    p2   <= a1 * mt1;
    sh2c <= sh1; lo2 <= lo1; hi2 <= hi1;
  end

  // ---- stage 3: bitlen(P), hence the float32 rounding position ---------------------------
  integer i;
  reg  [5:0] plen;
  always @* begin
    plen = 6'd0;
    for (i = 0; i < 48; i = i + 1) if (p2[i]) plen = i[5:0] + 6'd1;
  end
  wire [5:0] sh2_n = (plen > 6'd24) ? (plen - 6'd24) : 6'd0;

  reg         v3, neg3, tag3, ov3;
  reg  [47:0] p3;
  reg  [5:0]  sh3, shc3;
  reg  [7:0]  lo3, hi3;
  always @(posedge clk) begin
    if (rst) v3 <= 1'b0; else v3 <= v2;
    neg3 <= neg2; tag3 <= tag2; ov3 <= ov2;
    p3   <= p2;
    sh3  <= sh2_n;
    shc3 <= sh2c; lo3 <= lo2; hi3 <= hi2;
  end

  // ---- stage 4: round the product to 24 significant bits, half to even -------------------
  // rem = P mod 2^sh3, half = 2^(sh3-1).  Round up on rem > half, or rem == half and odd.
  /* verilator lint_off UNUSEDSIGNAL */   // q_sh[47:25]: bits above the 24 kept
  wire [47:0] q_sh  = p3 >> sh3;
  /* verilator lint_on UNUSEDSIGNAL */
  wire [47:0] lmask = ~({48{1'b1}} << sh3);
  wire [47:0] rem   = p3 & lmask;
  wire [47:0] halfv = (sh3 == 6'd0) ? 48'd0 : ({47'd0, 1'b1} << (sh3 - 6'd1));
  wire        rup   = (sh3 != 6'd0) && ((rem > halfv) || ((rem == halfv) && q_sh[0]));
  wire [24:0] q_inc = q_sh[24:0] + {24'd0, rup};
  // fx32_round's renormalise: 2^24 folds back to 2^23 and costs one more bit of exponent
  wire        renm  = q_inc[24];
  wire [24:0] q4_n  = renm ? {1'b0, q_inc[24:1]} : q_inc;
  wire [6:0]  sh4_n = {1'b0, sh3} + {6'd0, renm};

  wire signed [8:0] d4_n = $signed({2'b00, shc3}) - $signed({1'b0, sh4_n});

  reg         v4, neg4, tag4, ov4;
  reg  [24:0] q4;
  reg  signed [8:0] d4;               // sh - sh2, in [-25, 62]
  reg  [7:0]  lo4, hi4;
  always @(posedge clk) begin
    if (rst) v4 <= 1'b0; else v4 <= v3;
    neg4 <= neg3; tag4 <= tag3; ov4 <= ov3;
    q4   <= q4_n;
    d4   <= d4_n;
    lo4  <= lo3; hi4 <= hi3;
  end

  // ---- stage 5: the final rounding, half away from zero, and the clamp -------------------
  // q < 2^25, so for d >= 26 the rounded magnitude is 0, and for 1 <= d <= 25 a 27-bit add
  // and a 27-bit shift are the whole of it.  d <= 0 means a magnitude >= 2^23: the clamp.
  wire        d_big  = (d4 >= 9'sd26);
  wire        d_sat  = (d4 <= 9'sd0);
  wire [4:0]  dsm    = d4[4:0];
  wire [25:0] halfd  = {25'd0, 1'b1} << (dsm - 5'd1);
  wire [26:0] sum5   = {2'd0, q4} + {1'b0, halfd};
  wire [26:0] magf   = sum5 >> dsm;
  wire [26:0] mag5   = d_big ? 27'd0 : magf;

  // a magnitude of 256 or more is outside every int8 clamp, whichever end it hits
  wire        mbig = d_sat || (|mag5[26:8]);
  wire signed [9:0] val5 = neg4 ? -$signed({2'b00, mag5[7:0]}) : $signed({2'b00, mag5[7:0]});
  wire signed [9:0] lo10 = {{2{lo4[7]}}, lo4};
  wire signed [9:0] hi10 = {{2{hi4[7]}}, hi4};
  reg  [7:0]  y5;
  always @* begin
    if (mbig)             y5 = neg4 ? lo4 : hi4;
    else if (val5 < lo10) y5 = lo4;
    else if (val5 > hi10) y5 = hi4;
    else                  y5 = val5[7:0];
  end

  always @(posedge clk) begin
    if (rst) out_valid <= 1'b0; else out_valid <= v4;
    y       <= y5;
    out_tag <= tag4;
    ovf     <= v4 & ov4;
  end
endmodule

`default_nettype wire
