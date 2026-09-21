// -----------------------------------------------------------------------------
// MBX quantised output stage -- the op the ALU could not have.
//
// PEXT_FEASIBILITY.md section 1.4 measured the fused requantize at 30-38 logic
// levels and 9.6-11.2 ns of logic, and section 2 concluded "no clock drop
// rescues it ... it must be decomposed".  It was decomposed: MBP ships QMUL and
// CLIP8 as two single-cycle ALU ops with the rounding shift left to `srai`, and
// QMUL alone still came out as the built design's critical path (16.375 ns OOC,
// 25.535 ns in context).
//
// The same function in a RoCC is not in the ALU's timing cone and does not have
// to be single-cycle.  This file measures the fused form at STAGES = 1 (one
// combinational blob, for comparison with section 1.4) and STAGES = 3, which is
// what a decoupled unit would actually build.
//
// Semantics are bit-identical to sw/pext.h's software model, which
// PEXT_SPEC.md section 3.5 makes normative:
//
//   p = ((int64)(int32)acc * (int64)(int32)mult + (1<<30)) >> 31     -- MBP.QMUL
//   q = s ? (p + (1 << (s-1))) >> s : p                              -- scalar
//   y = clamp(q, -128, 127)                                          -- MBP.CLIP8
//   y = relu ? max(y, 0) : y                                         -- MBP.MAX8 vs x0
//
// Both roundings are round-half-up (add, then ARITHMETIC shift), because that is
// what ModelBlaster's reference expression computes -- PEXT_KERNELS.md 2.5.
// -----------------------------------------------------------------------------
module mbx_quant #(
  parameter LANES  = 4,
  parameter STAGES = 3      // 1 = combinational, 3 = pipelined
) (
  input  wire                clk,
  input  wire                en,
  input  wire [64*LANES-1:0] acc,     // LANES accumulators (low 32 bits used)
  input  wire [31:0]         mult,    // Q0.31 output_multiplier
  input  wire [5:0]          shift,   // output_shift, 0..31
  input  wire                relu,    // fold activation_min = 0
  output wire [8*LANES-1:0]  y        // LANES packed int8
);
  genvar l;
  generate
    for (l = 0; l < LANES; l = l + 1) begin : g_lane
      wire signed [31:0] a32 = acc[l*64 +: 32];
      wire signed [31:0] m32 = mult;

      // ---- stage 1 : the 32x32 multiply, 10 DSP48E1s when inferred ----------
      wire signed [64:0] prod = $signed({{33{a32[31]}}, a32}) *
                                $signed({{33{m32[31]}}, m32});
      wire signed [64:0] s1_in = prod + 65'sd1073741824;          // + 2^30
      wire signed [64:0] s1_d  = s1_in;
      reg  signed [64:0] s1_q;
      always @(posedge clk) if (en) s1_q <= s1_d;
      wire signed [64:0] s1 = (STAGES >= 2) ? s1_q : s1_d;

      // ---- stage 2 : >>31, the rounding add, and the variable shift ---------
      wire signed [33:0] p31 = s1 >>> 31;
      wire signed [33:0] rnd = (shift == 6'd0) ? 34'sd0
                                               : ($signed(34'sd1) <<< (shift - 1));
      wire signed [34:0] sum = $signed({p31[33], p31}) + $signed({rnd[33], rnd});
      wire signed [34:0] q_d = sum >>> shift;
      reg  signed [34:0] q_q;
      always @(posedge clk) if (en) q_q <= q_d;
      wire signed [34:0] q = (STAGES >= 3) ? q_q : q_d;

      // ---- stage 3 : clamp, relu, pack -------------------------------------
      wire signed [8:0] cl = (q < -35'sd128) ? -9'sd128 :
                             (q >  35'sd127) ?  9'sd127 : q[8:0];
      wire signed [8:0] rl = (relu && cl[8]) ? 9'sd0 : cl;
      assign y[l*8 +: 8] = rl[7:0];
    end
  endgenerate
endmodule

// The decomposed pieces, so the RoCC cost can be compared with the ALU cost of
// the same function that PEXT_FEASIBILITY.md section 1.4 already measured.
module mbx_qmul32 (
  input  wire        clk,
  input  wire [31:0] acc,
  input  wire [31:0] mult,
  output wire [33:0] p
);
  wire signed [31:0] a32 = acc;
  wire signed [31:0] m32 = mult;
  wire signed [64:0] prod = $signed({{33{a32[31]}}, a32}) *
                            $signed({{33{m32[31]}}, m32});
  assign p = (prod + 65'sd1073741824) >>> 31;
endmodule
