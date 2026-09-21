// -----------------------------------------------------------------------------
// Four-stage CIC decimator for a 1-bit PDM bitstream.  R:1, differential delay 1.
//
// Everything runs on the system clock; `in_valid` is the PDM-rate enable.  There is
// no second clock domain anywhere in this design, by choice: the PDM clock is a
// SIGNAL this block generates, not a clock the fabric runs on.
//
// Register width.  The classic CIC growth bound is
//     B_max = N*log2(R*M) + B_in = 4*log2(22) + 2 = 19.84  ->  W = 20
// with B_in = 2 because the PDM bit is mapped to the two's-complement values -1/+1.
// The integrators are allowed to wrap: the comb section is the exact inverse of the
// integrator section modulo 2^W, so as long as W >= B_max the output is exact.  This
// is the only reason a 1-bit stream can be integrated in 20 bits at all.
//
// Alias rejection is what sets N.  At R=22 the first band that folds into 0-7 kHz
// after decimation sits at f_cic - 7 kHz = 105 kHz, where four stages give -94.2 dB
// (gen_fir.py prints the number).  A PDM microphone's shaped quantisation noise is
// tens of dB above its in-band floor up there, so this margin is the whole point of
// decimating in two stages instead of one.
// -----------------------------------------------------------------------------
module pdm_cic4 #(
  parameter integer W = 20,
  parameter integer R = 22
) (
  input  wire                clk,
  input  wire                rst,        // synchronous, active high
  input  wire                in_valid,   // one pulse per PDM bit
  input  wire                in_bit,
  output reg                 out_valid,
  output reg  signed [W-1:0] out_data
);
  localparam integer CNTW = (R <= 2) ? 1 : $clog2(R);

  wire signed [W-1:0] x = in_bit ? {{(W-1){1'b0}}, 1'b1}     // +1
                                 : {W{1'b1}};                 // -1

  reg signed [W-1:0] i1, i2, i3, i4;
  reg signed [W-1:0] c1, c2, c3;
  reg signed [W-1:0] d1, d2, d3, d4;
  reg      [CNTW-1:0] cnt;

  wire tick = in_valid && (cnt == R[CNTW-1:0] - 1'b1);

  always @(posedge clk) begin
    if (rst) begin
      i1 <= 0; i2 <= 0; i3 <= 0; i4 <= 0;
      c1 <= 0; c2 <= 0; c3 <= 0;
      d1 <= 0; d2 <= 0; d3 <= 0; d4 <= 0;
      cnt <= 0;
      out_valid <= 1'b0;
      out_data  <= 0;
    end else begin
      out_valid <= 1'b0;

      // integrator cascade, one register per stage (a pure z^-1 per stage)
      if (in_valid) begin
        i1 <= i1 + x;
        i2 <= i2 + i1;
        i3 <= i3 + i2;
        i4 <= i4 + i3;
        cnt <= tick ? {CNTW{1'b0}} : (cnt + 1'b1);
      end

      // comb cascade, at the decimated rate
      if (tick) begin
        c1       <= i4 - d1;  d1 <= i4;
        c2       <= c1 - d2;  d2 <= c1;
        c3       <= c2 - d3;  d3 <= c2;
        out_data <= c3 - d4;  d4 <= c3;
        out_valid <= 1'b1;
      end
    end
  end
endmodule
