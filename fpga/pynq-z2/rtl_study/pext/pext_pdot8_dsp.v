// -----------------------------------------------------------------------------
// 8-way int8 dot product forced onto DSP48E1 multipliers.
//
// WHY 8 DSPs AND NOT 4: the Xilinx INT8 packing trick (WP487) puts two 8x8
// products in one 25x18 multiplier only when the two products SHARE an operand:
//   A = a1<<17 | a0  (25 bits),  B = b        ->  a1*b<<17 + a0*b
// For a dot product of two independent registers the pairs are distinct, so both
// operands must be packed:
//   A = a1<<k | a0, B = b1<<m | b0
//   A*B = a0b0 + a0b1<<m + a1b0<<k + a1b1<<(k+m)
// The two wanted terms are only separable if min(k,m) >= 16, and B is 18 bits so
// m <= 10. The cross terms always land inside a0b0's 16-bit field. There is no
// packing; it is one product per DSP.
//
// PIPE = 0 : purely combinational (M and P registers bypassed)
// PIPE = 1 : DSP M register used -> product stage registered, 2-cycle latency
// -----------------------------------------------------------------------------
(* use_dsp = "yes" *)
module pext_pdot8_dsp #(
  parameter ACC  = 0,
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

  wire signed [17:0] p [0:7];
  reg  signed [17:0] pq [0:7];
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_mul
      wire signed [8:0] ae = {sgn & a[i*8+7], a[i*8 +: 8]};
      wire signed [8:0] be = {sgn & b[i*8+7], b[i*8 +: 8]};
      wire signed [17:0] pr;
      pext_mul9x9_dsp m (.a(ae), .b(be), .p(pr));
      assign p[i] = pr;
      always @(posedge clk) pq[i] <= pr;
    end
  endgenerate

  wire signed [17:0] q [0:7];
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_sel
      assign q[i] = (PIPE != 0) ? pq[i] : p[i];
    end
  endgenerate

  wire signed [18:0] s0 = q[0] + q[1];
  wire signed [18:0] s1 = q[2] + q[3];
  wire signed [18:0] s2 = q[4] + q[5];
  wire signed [18:0] s3 = q[6] + q[7];
  wire signed [19:0] t0 = s0 + s1;
  wire signed [19:0] t1 = s2 + s3;
  wire signed [20:0] dot = t0 + t1;

  wire [63:0] dot_x = {{43{dot[20]}}, dot};
  assign z = (ACC != 0) ? (c + dot_x) : dot_x;
endmodule
