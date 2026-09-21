// SPDX-License-Identifier: Apache-2.0
//
// Width-selectable engine datapath: a PARAMETER STUDY for ROCC_DECOUPLED.md s8.13-8.14, not yet
// wired into mbxr_engine.  It answers one question with a synthesis result instead of an
// estimate: what do int16 x int8 MACs, a wider requantise and per-channel requant cost against
// today's int8 datapath (mbxr_mac + mbxr_quant), in DSP48E1s, LUTs and slack at 34.48 MHz?
//
//   MODE (parameter)
//     0  today's contract, rebuilt here as the control: 8 int8 x int8 products per lane per step,
//        a 32-bit accumulator, a 32x32 Q0.31 requantise, an int8 clamp.
//     1  (b1) width-selectable on the SAME 8 DSPs per lane.  An int16 dispatch reads 4 int16
//        elements from the 64-bit activation word and multiplies them by 4 int8 weights: bytes
//        0..3 of the weight word on a step with wsel_hi = 0, bytes 4..7 with wsel_hi = 1
//        (the sequencer halves its weight stride).  16 MAC/cycle for int16, 32 for int8.
//     2  (b2) int16 lanes doubled: a second activation word per step (a1) and 8 more DSPs per
//        lane, so an int16 dispatch keeps 8 products per step (32 MAC/cycle).  The second word
//        needs a second activation read port in the scratchpad; that is NOT in this block and
//        is priced separately.
//   For MODE 1 and 2:
//     * the accumulator is 40 bits: |int16 x int8| * 2,016 taps < 2^34, plus an int32 bias;
//     * the requantise is (acc40 * mult + 2^30) >> 31, then the output shift and the clamp,
//       to int8 or int16 by the dispatch's width;
//     * PER-CHANNEL REQUANT (pcq = 1): the bias step's weight word carries the int32 bias in
//       bits 31:0 (as today) and {shift[5:0], mult[25:0]} in bits 63:32, which today are
//       unused.  The lane captures them with the bias, so they travel with that row's
//       accumulator.  The multiplier is used as mult26 << 5 in Q0.31 (26 significant bits).
//
// Bit-exact target, stated for the C golden (F3PR's int16 convolutions and linears):
//     int64_t acc = bias;  acc += (int64_t)a * w                  (a int8 or int16, w int8)
//     int64_t s = ((__int128)acc * M + (1 << 30)) >> 31;           M = pcq ? mult26 << 5 : mult
//     shift > 0 : s = (s + (1 << (shift-1))) >> shift;  shift < 0 : s = s << -shift
//     clamp to [amin, amax] (int8 or int16 range)

module mbxr_dpw #(
  parameter NCH  = 4,
  parameter MODE = 1
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               valid,       // a step's words are on a0/a1/w
  input  wire               clr,         // ... and it is the bias step
  input  wire               w16,         // this dispatch's activations are int16
  input  wire               wsel_hi,     // MODE 1, int16: use weight bytes 4..7
  input  wire               pcq,         // per-channel requant from the bias word
  input  wire               last,        // the step that completes an output (to the quantiser)
  input  wire [63:0]        a0,
  input  wire [63:0]        a1,          // MODE 2 only
  input  wire [64*NCH-1:0]  w,
  input  wire [31:0]        mult,        // per-tensor requant (pcq = 0)
  input  wire [5:0]         shift,
  input  wire [15:0]        amin,        // sign-extended int8 or int16
  input  wire [15:0]        amax,
  output wire               out_valid,
  output wire [16*NCH-1:0]  y
);
  localparam AW = (MODE == 0) ? 32 : 40;
  localparam NP = (MODE == 2) ? 16 : 8;        // products per lane per step

  // ---- valid pipeline: product (registered in the DSP), accumulate, 3 requant stages ------
  reg v_m, v_acc, l_m, c_m, v1, v2, v3;
  always @(posedge clk) begin
    if (rst) begin
      v_m <= 1'b0; v_acc <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; l_m <= 1'b0; c_m <= 1'b0;
    end else begin
      v_m <= valid; l_m <= valid & last; c_m <= valid & clr;
      v_acc <= l_m;          // an output's accumulator is complete one cycle after its last product
      v1 <= v_acc; v2 <= v1; v3 <= v2;
    end
  end
  assign out_valid = v3;

  genvar c, i;
  generate
    for (c = 0; c < NCH; c = c + 1) begin : g_lane
      wire [63:0] wl = w[c*64 +: 64];
      // ---- operands --------------------------------------------------------------------
      wire signed [24:0] opa [0:NP-1];      // weight (int8, sign-extended)
      wire signed [17:0] opb [0:NP-1];      // activation (int8 or int16, sign-extended)
      for (i = 0; i < NP; i = i + 1) begin : g_op
        if (MODE == 0) begin : m0
          assign opa[i] = {{17{wl[i*8+7]}}, wl[i*8 +: 8]};
          assign opb[i] = {{10{a0[i*8+7]}}, a0[i*8 +: 8]};
        end else if (MODE == 1) begin : m1
          // int8: product i = w byte i x a byte i.  int16: product i < 4 = w byte (i or i+4) x
          // a element i (bytes 2i, 2i+1); products 4..7 are zero.
          wire [7:0]  wb8  = wl[i*8 +: 8];
          wire [7:0]  wb16 = (i < 4) ? (wsel_hi ? wl[(i+4)*8 +: 8] : wl[i*8 +: 8]) : 8'd0;
          wire [15:0] ae16 = (i < 4) ? a0[i*16 +: 16] : 16'd0;
          assign opa[i] = w16 ? {{17{wb16[7]}}, wb16} : {{17{wb8[7]}}, wb8};
          assign opb[i] = w16 ? {{2{ae16[15]}}, ae16} : {{10{a0[i*8+7]}}, a0[i*8 +: 8]};
        end else begin : m2
          // int8: products 0..7 as today, 8..15 zero.  int16: 8 elements from a0 and a1.
          wire [7:0]  wb   = wl[(i % 8)*8 +: 8];
          wire [15:0] ae16 = (i < 8) ? ((i < 4) ? a0[i*16 +: 16] : a1[(i-4)*16 +: 16]) : 16'd0;
          wire [7:0]  ab8  = (i < 8) ? a0[i*8 +: 8] : 8'd0;
          wire [7:0]  wb16 = (i < 8) ? wl[i*8 +: 8] : 8'd0;
          assign opa[i] = w16 ? {{17{wb16[7]}}, wb16} : ((i < 8) ? {{17{wb[7]}}, wb} : 25'd0);
          assign opb[i] = w16 ? {{2{ae16[15]}}, ae16} : {{10{ab8[7]}}, ab8};
        end
      end
      // ---- products: one DSP48E1 each, product registered in the DSP (MREG) -------------
      wire signed [25:0] pr [0:NP-1];
      for (i = 0; i < NP; i = i + 1) begin : g_mul
`ifdef MBXR_BEHAVIOURAL
        reg signed [25:0] q;
        always @(posedge clk) q <= opa[i] * opb[i];
        assign pr[i] = q;
`else
        wire [47:0] dp;
        mbx_dsp_cell #(.PIPE(1)) u (.clk(clk), .a(opa[i]), .b(opb[i]), .p(dp));
        assign pr[i] = dp[25:0];
`endif
      end
      // ---- the sum of this step's products ----------------------------------------------
      reg signed [AW-1:0] dotv;
      integer k;
      always @* begin
        dotv = {AW{1'b0}};
        for (k = 0; k < NP; k = k + 1) dotv = dotv + {{(AW-26){pr[k][25]}}, pr[k]};
      end
      // ---- bias word, delayed to the product's cycle ---------------------------------------
      reg [63:0] wb_m;
      always @(posedge clk) if (valid & clr) wb_m <= wl;
      // ---- accumulator, and the per-channel requant word riding with it -----------------
      reg signed [AW-1:0] acc;
      reg [31:0] m_row;
      reg [5:0]  s_row;
      always @(posedge clk) begin
        if (v_m) begin
          if (c_m) begin
            acc   <= {{(AW-32){wb_m[31]}}, wb_m[31:0]};     // the bias step adds no products
            m_row <= {wb_m[57:32], 5'd0};
            s_row <= wb_m[63:58];
          end else begin
            acc <= acc + dotv;
          end
        end
      end
      // ---- requantise ----------------------------------------------------------------------
      wire [31:0] m_use = (MODE != 0 && pcq) ? m_row : mult;
      wire [5:0]  s_use = (MODE != 0 && pcq) ? s_row : shift;
      // stage 1: the Q0.31 multiply (AW x 32), registered
      wire signed [AW+31:0] prod = $signed(acc) * $signed({1'b0, m_use[30:0]});
      reg  signed [AW+31:0] p1;
      reg  [5:0]            s1;
      always @(posedge clk) begin
        p1 <= prod + (64'sd1 <<< 30);
        s1 <= s_use;
      end
      wire signed [AW:0] s0 = p1[AW+31:31];
      // stage 2: output shift
      wire        sh_neg = s1[5];
      wire [5:0]  sh_mag = sh_neg ? (~s1 + 6'd1) : s1;
      wire signed [AW+1:0] rnd = (sh_mag == 6'd0) ? {(AW+2){1'b0}} : ($signed({{(AW+1){1'b0}}, 1'b1}) <<< (sh_mag - 6'd1));
      wire signed [AW+1:0] sum = $signed({s0[AW], s0}) + rnd;
      wire signed [AW+1:0] rsh = sum >>> sh_mag;
      wire signed [AW+1:0] lsh = $signed({s0[AW], s0}) <<< sh_mag;
      reg  signed [AW+1:0] p2;
      always @(posedge clk) p2 <= sh_neg ? lsh : ((sh_mag == 6'd0) ? $signed({s0[AW], s0}) : rsh);
      // stage 3: clamp
      wire signed [AW+1:0] lo = {{(AW-14){amin[15]}}, amin};
      wire signed [AW+1:0] hi = {{(AW-14){amax[15]}}, amax};
      reg [15:0] p3;
      always @(posedge clk) p3 <= (p2 < lo) ? amin : ((p2 > hi) ? amax : p2[15:0]);
      assign y[c*16 +: 16] = p3;
    end
  endgenerate
endmodule

// Registers every input and output, so the OOC numbers are register-to-register.
module mbxr_dpw_ooc #(
  parameter NCH  = 4,
  parameter MODE = 1
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               valid, clr, w16, wsel_hi, pcq, last,
  input  wire [63:0]        a0, a1,
  input  wire [64*NCH-1:0]  w,
  input  wire [31:0]        mult,
  input  wire [5:0]         shift,
  input  wire [15:0]        amin, amax,
  output reg                out_valid,
  output reg  [16*NCH-1:0]  y
);
  reg valid_q, clr_q, w16_q, wsel_q, pcq_q, last_q;
  reg [63:0] a0_q, a1_q;
  reg [64*NCH-1:0] w_q;
  reg [31:0] mult_q;
  reg [5:0] shift_q;
  reg [15:0] amin_q, amax_q;
  wire ov;
  wire [16*NCH-1:0] yy;
  always @(posedge clk) begin
    valid_q <= valid; clr_q <= clr; w16_q <= w16; wsel_q <= wsel_hi; pcq_q <= pcq; last_q <= last;
    a0_q <= a0; a1_q <= a1; w_q <= w; mult_q <= mult; shift_q <= shift; amin_q <= amin; amax_q <= amax;
    out_valid <= ov; y <= yy;
  end
  mbxr_dpw #(.NCH(NCH), .MODE(MODE)) u (
    .clk(clk), .rst(rst), .valid(valid_q), .clr(clr_q), .w16(w16_q), .wsel_hi(wsel_q), .pcq(pcq_q),
    .last(last_q), .a0(a0_q), .a1(a1_q), .w(w_q), .mult(mult_q), .shift(shift_q), .amin(amin_q),
    .amax(amax_q), .out_valid(ov), .y(yy));
endmodule
