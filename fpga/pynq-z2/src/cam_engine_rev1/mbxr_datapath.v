// SPDX-License-Identifier: Apache-2.0
//
// The engine's arithmetic, as built: the MAC array, the requantiser and the byte packer.
//
// Bit-exact target: ModelBlaster's kernel_linear_s8 / kernel_conv2d_s8 reference with
// input_offset = filter_offset = output_offset = 0 (the only form the int8 extractor
// emits):
//
//     int32_t acc = bias[n];  acc += in * w  (int32, wraps)
//     int64_t prod = ((int64_t)acc * mult + (1 << 30)) >> 31;   int32_t s = (int32_t)prod;
//     shift > 0 :  s = (int32_t)(((int64_t)s + (1 << (shift-1))) >> shift)
//     shift < 0 :  s = s << -shift                                (32-bit wrap)
//     s = clamp(s, activation_min, activation_max)
//
// WHY THIS IS NOT mbx_mac.v + mbx_quant.v + mbx_accbank.v AS mbxd_top.v WIRED THEM.
// Building the engine meant reading that datapath against the reference, and it does not
// compute it.  None of this reached a published number -- tb_mbxd.sv checks the fill
// engine and the drain, never the array -- but each would have produced a wrong byte:
//
//   * the accumulator bank captured `acc` in the cycle its LAST group was still being
//     added, so every output missed one group of eight products;
//   * it was read back one cycle later at `out_index`, which had already advanced;
//   * mac_en rose in the cycle the scratchpad was ADDRESSED, one cycle before the block
//     RAM's registered output was valid;
//   * mbx_quant's three stages were all gated by one single-cycle `en`, so they were not a
//     pipeline: stage 2 captured stage 1's previous contents.
//
// Here every stage carries its own valid bit, and tb_mbxr checks the bytes against the
// reference kernel compiled from C.

// ---- one int8 x int8 product --------------------------------------------------------------
// Synthesis instantiates a DSP48E1 through rtl_study/rocc/mbx_mac.v's mbx_dsp_cell, because
// Vivado 2023.1 segfaults inferring DSPs from multipliers that feed an adder tree
// (PEXT_FEASIBILITY.md risk 4).  Verilator has no DSP48E1, so the testbench defines
// MBXR_BEHAVIOURAL and gets the same product from `*`.
module mbxr_mul8 (
  input  wire        clk,
  input  wire [7:0]  w,
  input  wire [7:0]  a,
  output wire [16:0] p
);
`ifdef MBXR_BEHAVIOURAL
  wire signed [16:0] ws = {{9{w[7]}}, w};
  wire signed [16:0] as = {{9{a[7]}}, a};
  assign p = ws * as;
`else
  wire [47:0] dp;
  mbx_dsp_cell #(.PIPE(0)) u (.clk(clk), .a({{17{w[7]}}, w}), .b({{10{a[7]}}, a}), .p(dp));
  assign p = dp[16:0];
`endif
endmodule

// ---- NCH lanes of eight int8 x int8 products, one shared activation word ---------------
module mbxr_mac #(
  parameter NCH = 4
) (
  input  wire              clk,
  input  wire              valid,     // a step's words are on a/w this cycle
  input  wire              clr,       // ... and it is the bias step: acc[c] = w[c][31:0]
  input  wire [63:0]       a,
  input  wire [64*NCH-1:0] w,
  output wire [32*NCH-1:0] acc
);
  genvar c, i;
  generate
    for (c = 0; c < NCH; c = c + 1) begin : g_lane
      wire signed [16:0] pr [0:7];
      for (i = 0; i < 8; i = i + 1) begin : g_mul
        mbxr_mul8 u (.clk(clk), .w(w[c*64 + i*8 +: 8]), .a(a[i*8 +: 8]), .p(pr[i]));
      end
      wire signed [20:0] dot;
      mbx_addtree8 t (.p0(pr[0]), .p1(pr[1]), .p2(pr[2]), .p3(pr[3]),
                      .p4(pr[4]), .p5(pr[5]), .p6(pr[6]), .p7(pr[7]), .z(dot));
      reg [31:0] acc_q;
      always @(posedge clk) begin
        if (valid) begin
          acc_q <= clr ? w[c*64 +: 32] : acc_q + {{11{dot[20]}}, dot};
        end
      end
      assign acc[c*32 +: 32] = acc_q;
    end
  endgenerate
endmodule

// ---- requantise: three registered stages, each with its own valid ----------------------
module mbxr_quant #(
  parameter NCH = 4
) (
  input  wire              clk,
  input  wire              rst,
  input  wire              in_valid,
  input  wire [32*NCH-1:0] acc,
  input  wire [31:0]       mult,
  input  wire [5:0]        shift,     // two's complement, -31..31
  input  wire [7:0]        amin,      // int8
  input  wire [7:0]        amax,      // int8
  output wire              out_valid,
  output wire [8*NCH-1:0]  y,
  output wire              busy
);
  reg v1, v2, v3;
  assign busy = v1 || v2 || v3;
  always @(posedge clk) begin
    if (rst) begin
      v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
    end else begin
      v1 <= in_valid; v2 <= v1; v3 <= v2;
    end
  end
  assign out_valid = v3;

  wire        sh_neg = shift[5];
  wire [5:0]  sh_mag = sh_neg ? (~shift + 6'd1) : shift;

  genvar c;
  generate
    for (c = 0; c < NCH; c = c + 1) begin : g_lane
      // stage 1: the Q0.31 rounding multiply
      wire signed [31:0] a32 = acc[c*32 +: 32];
      wire signed [63:0] prod = $signed(a32) * $signed(mult);
      reg  signed [63:0] p1;
      always @(posedge clk) p1 <= prod + 64'sd1073741824;
      // (prod + 2^30) >> 31 fits int32 for any int32 acc and a Q0.31 multiplier, so the
      // reference's (int32_t) cast is a no-op here; bits [62:31] ARE the int32.
      wire signed [31:0] s = p1[62:31];

      // stage 2: the output shift, both directions
      wire signed [32:0] rnd  = (sh_mag == 6'd0) ? 33'sd0 : ($signed(33'sd1) <<< (sh_mag - 6'd1));
      wire signed [32:0] sum  = $signed({s[31], s}) + rnd;
      wire signed [32:0] rsh  = sum >>> sh_mag;
      wire        [31:0] lsh  = s << sh_mag;
      reg  signed [31:0] p2;
      always @(posedge clk) begin
        if (sh_neg)               p2 <= lsh;
        else if (sh_mag == 6'd0)  p2 <= s;
        else                      p2 <= rsh[31:0];
      end

      // stage 3: clamp to [activation_min, activation_max]
      wire signed [31:0] lo = {{24{amin[7]}}, amin};
      wire signed [31:0] hi = {{24{amax[7]}}, amax};
      reg [7:0] p3;
      always @(posedge clk) begin
        if (p2 < lo)       p3 <= amin;
        else if (p2 > hi)  p3 <= amax;
        else               p3 <= p2[7:0];
      end
      assign y[c*8 +: 8] = p3;
    end
  endgenerate
endmodule

// ---- NCH bytes at a time into little-endian 64-bit words -------------------------------
module mbxr_pack #(
  parameter NCH = 4          // 1, 2, 4 or 8
) (
  input  wire             clk,
  input  wire             rst,
  input  wire             in_valid,
  input  wire [8*NCH-1:0] in_bytes,
  output reg              out_valid,
  output wire [63:0]      out_word,
  output wire [3:0]       fill        // lane groups held, for status
);
  localparam PER = 8 / NCH;
  reg [63:0] sh;
  reg [3:0]  cnt;
  assign out_word = sh;
  assign fill = cnt;
  always @(posedge clk) begin
    out_valid <= 1'b0;
    if (rst) begin
      cnt <= 4'd0;
    end else if (in_valid) begin
      if (NCH == 8) sh <= in_bytes;
      else          sh <= {in_bytes, sh[63:8*NCH]};
      if (cnt + 4'd1 == PER[3:0]) begin
        cnt <= 4'd0;
        out_valid <= 1'b1;
      end else begin
        cnt <= cnt + 4'd1;
      end
    end
  end
endmodule
