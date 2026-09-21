// -----------------------------------------------------------------------------
// Candidate fixed-point FFT assists for the speech front end, for out-of-context
// area and timing ONLY.  Nothing here is integrated into any bitstream, and this
// directory deliberately touches no shared file: the top level, the XDC and the
// IOBinders belong to the bitstream builds.
//
// The question these answer is in fpga/pynq-z2/docs/SPEECH_ON_ROCKET.md section 7.
// MBP.QMUL already halves the transform (measured, Lab B15: cfft256 61,211 ->
// 30,885 cycles), so the remaining question is what a DEDICATED unit would buy on
// top of that -- and the answer has to be priced against the ~12,600 LUT of
// headroom the microphone bitstream leaves, not asserted.
//
// The variants, all Q0.31 fixed point, all combinational, all measured against
// the same registered harness the RoCC study uses so the numbers are comparable
// with rtl_study/rocc/ooc_out/ (qmul32 = 48 LUT, 4 DSP, 18.507 ns slack).
//
//   fft_v_qmul1    the SHIPPED MBP.QMUL, re-measured here as the baseline.
//   fft_v_qmul2    two independent Q0.31 multiplies, packed 2x32 in / 2x32 out.
//                  Halves the twiddle multiply COUNT; still four per butterfly's
//                  worth of work, issued as two instructions.
//   fft_v_cmul     ONE complex Q0.31 multiply: (ar,ai) x (wr,wi) ->
//                  (ar*wr - ai*wi, ar*wi + ai*wr).  Four multipliers and two
//                  add/subs.  Replaces four MBP.QMULs and two adds -- six
//                  instructions -- with one.
//   fft_v_bf2      a whole radix-2 butterfly: t = b*w; (a+t, a-t).  THREE 64-bit
//                  source operands, so it cannot be an R-type instruction at all;
//                  priced to establish the ceiling, not because it is proposable
//                  without a RoCC or an architectural twiddle register.
// -----------------------------------------------------------------------------

// rd = (a * m + 2^30) >>> 31, signed, exactly pext.h's mb_pext_qmul_sw.
module fft_qmul (
  input  wire signed [31:0] a,
  input  wire signed [31:0] m,
  output wire signed [33:0] p
);
  wire signed [64:0] prod = $signed({{33{a[31]}}, a}) * $signed({{33{m[31]}}, m});
  assign p = (prod + 65'sd1073741824) >>> 31;
endmodule

module fft_v_qmul1 (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  wire signed [33:0] p;
  fft_qmul u (.a(a[31:0]), .m(b[31:0]), .p(p));
  assign z = {{30{p[33]}}, p};
endmodule

module fft_v_qmul2 (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  wire signed [33:0] p0, p1;
  fft_qmul u0 (.a(a[31:0]),  .m(b[31:0]),  .p(p0));
  fft_qmul u1 (.a(a[63:32]), .m(b[63:32]), .p(p1));
  assign z = {p1[31:0], p0[31:0]};
endmodule

// The complex multiply. Saturation is deliberately NOT applied: the FFT data path
// carries int32 with proven headroom (audio_fe.h: 15 input bits + FE_IN_SHIFT + 8
// of transform growth < 31), so a saturating stage would add a level for a case
// that cannot occur, and would make the instruction disagree with the software
// model at exactly the inputs nobody tests.
module fft_v_cmul (input wire clk, rst, input wire [63:0] a, b, c, d,
                   input wire [15:0] ctl, output wire [63:0] z);
  wire signed [33:0] rr, ii, ri, ir;
  fft_qmul u0 (.a(a[31:0]),  .m(b[31:0]),  .p(rr));   // ar*wr
  fft_qmul u1 (.a(a[63:32]), .m(b[63:32]), .p(ii));   // ai*wi
  fft_qmul u2 (.a(a[31:0]),  .m(b[63:32]), .p(ri));   // ar*wi
  fft_qmul u3 (.a(a[63:32]), .m(b[31:0]),  .p(ir));   // ai*wr
  wire signed [34:0] re = rr - ii;
  wire signed [34:0] im = ri + ir;
  assign z = {im[31:0], re[31:0]};
endmodule

// The whole butterfly. a = (are,aim), b = (bre,bim), w = (wre,wim) -- three
// 64-bit sources and two 64-bit results, which is why this is a ceiling and not
// a proposal.
module fft_v_bf2 (input wire clk, rst, input wire [63:0] a, b, c, d,
                  input wire [15:0] ctl, output wire [63:0] z);
  wire signed [33:0] rr, ii, ri, ir;
  fft_qmul u0 (.a(b[31:0]),  .m(c[31:0]),  .p(rr));
  fft_qmul u1 (.a(b[63:32]), .m(c[63:32]), .p(ii));
  fft_qmul u2 (.a(b[31:0]),  .m(c[63:32]), .p(ri));
  fft_qmul u3 (.a(b[63:32]), .m(c[31:0]),  .p(ir));
  wire signed [32:0] tr = rr[32:0] - ii[32:0];
  wire signed [32:0] ti = ri[32:0] + ir[32:0];
  wire signed [32:0] hr = $signed(a[31:0])  + tr;
  wire signed [32:0] hi = $signed(a[63:32]) + ti;
  wire signed [32:0] lr = $signed(a[31:0])  - tr;
  wire signed [32:0] li = $signed(a[63:32]) - ti;
  // the harness has one 64-bit result; fold both halves so neither is trimmed
  assign z = {hi[31:0] ^ li[31:0], hr[31:0] ^ lr[31:0]};
endmodule

// The melbank's inner product, which Lab B15 measures at 32 cycles per tap and
// which MBP.QMUL cannot express: a 64-bit power value times a Q0.15 mel weight.
// Priced because it is the front end's remaining hotspot once the FFT is done.
module fft_v_melmac (input wire clk, rst, input wire [63:0] a, b, c, d,
                     input wire [15:0] ctl, output wire [63:0] z);
  wire [15:0] w = b[15:0];
  wire [79:0] prod = a * w;              // unsigned: mel power and weight are >= 0
  assign z = c + {16'd0, prod[79:16]};   // >>15 then accumulate, one instruction
endmodule

module fft_v_null (input wire clk, rst, input wire [63:0] a, b, c, d,
                   input wire [15:0] ctl, output wire [63:0] z);
  assign z = a ^ b ^ c ^ d ^ {48'd0, ctl} ^ {63'd0, rst};
endmodule

`ifndef FFT_DUT
`define FFT_DUT fft_v_null
`endif

module fft_harness (
  input  wire        clk,
  input  wire        rst_i,
  input  wire [63:0] a_i, b_i, c_i, d_i,
  input  wire [15:0] ctl_i,
  output reg  [63:0] z_o
);
  reg [63:0] a_q, b_q, c_q, d_q;
  reg [15:0] ctl_q;
  reg        rst_q;
  wire [63:0] z;
  always @(posedge clk) begin
    a_q <= a_i; b_q <= b_i; c_q <= c_i; d_q <= d_i;
    ctl_q <= ctl_i; rst_q <= rst_i; z_o <= z;
  end
  `FFT_DUT dut (.clk(clk), .rst(rst_q), .a(a_q), .b(b_q), .c(c_q), .d(d_q),
                .ctl(ctl_q), .z(z));
endmodule
