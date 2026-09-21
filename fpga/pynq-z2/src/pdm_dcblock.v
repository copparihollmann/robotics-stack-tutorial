// -----------------------------------------------------------------------------
// One-pole DC blocker at the PCM rate.
//
//     y[n] = x[n] - x[n-1] + a*y[n-1],   a = 1 - 2^-K
//
// implemented on an extended-precision accumulator so `a` costs a shift and a
// subtract rather than a multiplier:
//
//     acc <- acc - (acc >>> K) + ((x[n] - x[n-1]) <<< FRAC)
//     y    = sat16(acc >>> FRAC)
//
// The -3 dB corner is fs / (2*pi*2^K) = 15994 / (2*pi*128) = 19.9 Hz at K=7.
//
// This is not cosmetic.  The board's own microphone was measured at a PDM density of
// 0.516384 with no deliberate sound (see MICROPHONE.md), and the +-1 mapping turns
// that into a DC offset of 0.0328 full scale = 1074 LSB of the 16-bit output -- 3.3%
// of the headroom, permanently, before any signal arrives.
// -----------------------------------------------------------------------------
module pdm_dcblock #(
  parameter integer K    = 7,
  parameter integer FRAC = 8,
  parameter integer AW   = 32
) (
  input  wire                clk,
  input  wire                rst,
  input  wire                bypass,
  input  wire                in_valid,
  input  wire signed [15:0]  in_data,
  output reg                 out_valid,
  output reg  signed [15:0]  out_data
);
  reg signed [15:0] xprev;
  reg signed [AW-1:0] acc;

  wire signed [16:0]   diff = in_data - xprev;
  wire signed [AW-1:0] dscaled = {{(AW-17-FRAC){diff[16]}}, diff, {FRAC{1'b0}}};
  wire signed [AW-1:0] nxt = acc - (acc >>> K) + dscaled;
  wire signed [AW-1:0] y   = nxt >>> FRAC;
  wire signed [15:0]   ysat = (y >  32767) ?  16'sd32767 :
                              (y < -32768) ? -16'sd32768 : y[15:0];

  always @(posedge clk) begin
    if (rst) begin
      xprev <= 16'sd0; acc <= 0; out_valid <= 1'b0; out_data <= 16'sd0;
    end else begin
      out_valid <= in_valid;
      if (in_valid) begin
        xprev    <= in_data;
        acc      <= nxt;
        out_data <= bypass ? in_data : ysat;
      end
    end
  end
endmodule
