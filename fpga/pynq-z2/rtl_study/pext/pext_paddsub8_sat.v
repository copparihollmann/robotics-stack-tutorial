// -----------------------------------------------------------------------------
// Packed add / subtract with saturation, 8 x int8.  Bias and residual adds.
//   fn[0] : 1 = subtract, 0 = add
//   fn[1] : 1 = signed saturation, 0 = unsigned saturation
// -----------------------------------------------------------------------------
module pext_paddsub8_sat (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire sub = fn[0];
  wire sgn = fn[1];
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_lane
      wire signed [7:0] av = a[i*8 +: 8];
      wire signed [7:0] bv = b[i*8 +: 8];
      wire signed [8:0] bs = sub ? -$signed({bv[7], bv}) : $signed({bv[7], bv});
      wire signed [9:0] s  = $signed({{2{av[7]}}, av}) + $signed({bs[8], bs});

      // unsigned lane: 9-bit magnitude path
      wire [8:0] ua = {1'b0, a[i*8 +: 8]};
      wire [8:0] ub = {1'b0, b[i*8 +: 8]};
      wire [9:0] us = sub ? ({1'b0, ua} - {1'b0, ub}) : ({1'b0, ua} + {1'b0, ub});

      wire        s_ovf = (s[9:7] != 3'b000) && (s[9:7] != 3'b111);
      wire [7:0]  s_sat = s[9] ? 8'h80 : 8'h7F;
      wire [7:0]  s_res = s_ovf ? s_sat : s[7:0];

      wire        u_ovf = us[9] | us[8];
      wire [7:0]  u_sat = us[9] ? 8'h00 : 8'hFF;   // borrow -> 0, carry -> 255
      wire [7:0]  u_res = u_ovf ? u_sat : us[7:0];

      assign z[i*8 +: 8] = sgn ? s_res : u_res;
    end
  endgenerate
endmodule
