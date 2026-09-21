// -----------------------------------------------------------------------------
// Candidate units for the operations a TRANSCRIPTION model needs and a keyword
// spotter does not -- softmax's exponential and reciprocal, layer norm's inverse
// square root -- for out-of-context area and timing ONLY.
//
// Nothing here is integrated into any bitstream. This directory touches no shared
// file: the top level, the XDC and the IOBinders belong to the bitstream builds.
//
// WHY THESE AND NOT AN FPU. Rocket's IEEE-754 FPU is 13,878 LUT and does not fit
// beside everything else. A RoCC accelerator does not have to be ISA-compatible:
// no FP register file, no FP load/store, no rounding-mode surface, no denormals,
// no NaN propagation, no fflags, and no requirement to be correctly rounded --
// only accurate enough, which fpga/pynq-z2/docs/SPEECH_ON_ROCKET.md makes a
// measured bar rather than an assumed one. So the honest comparison is between
// what the WORKLOAD calls and what each way of providing it costs:
//
//   exp2_lut    the integer 2^x of int_nonlin.c's int_exp2_q31, in hardware:
//               33-entry Q0.16 table, linear interpolation, barrel shift.
//   rsqrt_step  one Newton iteration of 1/sqrt, the inner loop of int_rsqrt_q31.
//   recip_step  one Newton iteration of 1/x, softmax's per-row normalisation.
//   fmul32      a DELIBERATELY MINIMAL binary32 multiply: round-to-nearest-even
//               only, no denormals, no NaN/Inf semantics, no flags. This is the
//               cheapest thing that can honestly be called a float multiplier.
//   fadd32      the same for addition -- align, add, normalise, round. Addition
//               is the expensive one in any float unit, because the normalising
//               shift is data-dependent in both directions.
//
// The comparison that matters is not between these; it is between ANY of them and
// the measured software number in Lab B20. A unit that is never built costs zero
// LUT and zero integration risk.
// -----------------------------------------------------------------------------

// ---- the integer transcendental, as hardware -------------------------------------
module nl_exp2_lut (
  input  wire [31:0] z_q16,          // <= 0
  output wire [31:0] q31
);
  // 2^(-i/32) in Q0.16, i = 0..32 -- the table int_nonlin.c carries.
  function [16:0] lut(input [5:0] i);
    case (i)
      6'd0: lut=17'd65536; 6'd1: lut=17'd64132; 6'd2: lut=17'd62757; 6'd3: lut=17'd61410;
      6'd4: lut=17'd60093; 6'd5: lut=17'd58803; 6'd6: lut=17'd57540; 6'd7: lut=17'd56305;
      6'd8: lut=17'd55095; 6'd9: lut=17'd53912; 6'd10:lut=17'd52754; 6'd11:lut=17'd51621;
      6'd12:lut=17'd50512; 6'd13:lut=17'd49427; 6'd14:lut=17'd48366; 6'd15:lut=17'd47327;
      6'd16:lut=17'd46311; 6'd17:lut=17'd45316; 6'd18:lut=17'd44343; 6'd19:lut=17'd43391;
      6'd20:lut=17'd42460; 6'd21:lut=17'd41548; 6'd22:lut=17'd40657; 6'd23:lut=17'd39784;
      6'd24:lut=17'd38932; 6'd25:lut=17'd38097; 6'd26:lut=17'd37281; 6'd27:lut=17'd36483;
      6'd28:lut=17'd35702; 6'd29:lut=17'd34938; 6'd30:lut=17'd34191; 6'd31:lut=17'd33461;
      default: lut=17'd32768;
    endcase
  endfunction
  wire [31:0] nz  = -z_q16;
  wire [4:0]  n   = nz[20:16];
  wire [15:0] f   = nz[15:0];
  wire [4:0]  idx = f[15:11];
  wire [15:0] rem = {f[10:0], 5'd0};
  wire [16:0] lo  = lut({1'b0, idx});
  wire [16:0] hi  = lut({1'b0, idx} + 6'd1);
  wire [16:0] dd  = lo - hi;
  wire [32:0] mul = dd * rem;
  wire [16:0] m   = lo - mul[32:16];
  wire [46:0] wide = {m, 15'd0};
  assign q31 = (nz[31] || n >= 5'd31) ? 32'd0 : (wide >> n);
endmodule

// ---- one Newton step of 1/sqrt: r <- r*(3 - m*r^2)/2 -------------------------------
module nl_rsqrt_step (
  input  wire [31:0] m_q30,
  input  wire [31:0] r_q31,
  output wire [31:0] r_next
);
  wire [63:0] r2  = r_q31 * r_q31;
  wire [63:0] mr2 = m_q30 * r2[63:32];
  wire [32:0] t   = 33'h180000000 - {1'b0, mr2[63:31]};
  wire [64:0] p   = r_q31 * t[31:0];
  assign r_next = p[63:32];
endmodule

// ---- one Newton step of 1/x: q <- q*(2 - n*q) -------------------------------------
module nl_recip_step (
  input  wire [31:0] n_q31,
  input  wire [31:0] q_q31,
  output wire [31:0] q_next
);
  wire [63:0] nq = n_q31 * q_q31;
  wire [32:0] t  = 33'h100000000 - {1'b0, nq[63:32]};
  wire [64:0] p  = q_q31 * t[31:0];
  assign q_next = p[62:31];
endmodule

// ---- a deliberately minimal binary32 multiply -------------------------------------
// No denormals, no NaN/Inf, no flags, round-to-nearest-even on the product only.
module nl_fmul32 (
  input  wire [31:0] a,
  input  wire [31:0] b,
  output wire [31:0] y
);
  wire        sa = a[31], sb = b[31];
  wire [7:0]  ea = a[30:23], eb = b[30:23];
  wire [23:0] ma = {1'b1, a[22:0]}, mb = {1'b1, b[22:0]};
  wire [47:0] p  = ma * mb;
  wire        nrm = p[47];
  wire [22:0] mant = nrm ? p[46:24] : p[45:23];
  wire        rbit = nrm ? p[23] : p[22];
  wire [23:0] rounded = {1'b0, mant} + {23'd0, rbit};
  wire [9:0]  esum = {2'd0, ea} + {2'd0, eb} - 10'd127 + {9'd0, nrm} + {9'd0, rounded[23]};
  assign y = (ea == 8'd0 || eb == 8'd0) ? 32'd0
           : {sa ^ sb, esum[7:0], rounded[23] ? rounded[23:1] : rounded[22:0]};
endmodule

// ---- and the expensive half of any float unit: addition ---------------------------
module nl_fadd32 (
  input  wire [31:0] a,
  input  wire [31:0] b,
  output wire [31:0] y
);
  wire        agtb = a[30:0] >= b[30:0];
  wire [31:0] hi = agtb ? a : b;
  wire [31:0] lo = agtb ? b : a;
  wire [7:0]  eh = hi[30:23], el = lo[30:23];
  wire [7:0]  sh = eh - el;
  wire [23:0] mh = {1'b1, hi[22:0]}, ml = {1'b1, lo[22:0]};
  wire [26:0] mhs = {mh, 3'd0};
  wire [26:0] mls = (sh > 8'd26) ? 27'd0 : ({ml, 3'd0} >> sh);
  wire        sub = hi[31] ^ lo[31];
  wire [27:0] s   = sub ? ({1'b0, mhs} - {1'b0, mls}) : ({1'b0, mhs} + {1'b0, mls});
  // Leading-zero count over 28 bits -- the normalising shift, and the reason float
  // addition is not cheap. Written as a priority casez rather than a for loop that
  // assigns its own index: the loop form is legal Verilog, simulates correctly, and
  // Vivado refuses to synthesise it.
  reg  [4:0] lz;
  always @* begin
    casez (s)
      28'b1???????????????????????????: lz = 5'd0;
      28'b01??????????????????????????: lz = 5'd1;
      28'b001?????????????????????????: lz = 5'd2;
      28'b0001????????????????????????: lz = 5'd3;
      28'b00001???????????????????????: lz = 5'd4;
      28'b000001??????????????????????: lz = 5'd5;
      28'b0000001?????????????????????: lz = 5'd6;
      28'b00000001????????????????????: lz = 5'd7;
      28'b000000001???????????????????: lz = 5'd8;
      28'b0000000001??????????????????: lz = 5'd9;
      28'b00000000001?????????????????: lz = 5'd10;
      28'b000000000001????????????????: lz = 5'd11;
      28'b0000000000001???????????????: lz = 5'd12;
      28'b00000000000001??????????????: lz = 5'd13;
      28'b000000000000001?????????????: lz = 5'd14;
      28'b0000000000000001????????????: lz = 5'd15;
      28'b00000000000000001???????????: lz = 5'd16;
      28'b000000000000000001??????????: lz = 5'd17;
      28'b0000000000000000001?????????: lz = 5'd18;
      28'b00000000000000000001????????: lz = 5'd19;
      28'b000000000000000000001???????: lz = 5'd20;
      28'b0000000000000000000001??????: lz = 5'd21;
      28'b00000000000000000000001?????: lz = 5'd22;
      28'b000000000000000000000001????: lz = 5'd23;
      28'b0000000000000000000000001???: lz = 5'd24;
      28'b00000000000000000000000001??: lz = 5'd25;
      28'b000000000000000000000000001?: lz = 5'd26;
      default:                          lz = 5'd27;
    endcase
  end
  wire [27:0] nrm = s << lz;
  wire [7:0]  ey  = eh + 8'd1 - {3'd0, lz};
  wire [23:0] my  = nrm[27:4] + {23'd0, nrm[3]};
  assign y = (s == 28'd0) ? 32'd0 : {hi[31], ey, my[22:0]};
endmodule

module nl_v_null (input wire clk, rst, input wire [63:0] a, b, c, d,
                  input wire [15:0] ctl, output wire [63:0] z);
  assign z = a ^ b ^ c ^ d ^ {48'd0, ctl} ^ {63'd0, rst};
endmodule
module nl_v_exp2 (input wire clk, rst, input wire [63:0] a, b, c, d,
                  input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] q; nl_exp2_lut u (.z_q16(a[31:0]), .q31(q)); assign z = {32'd0, q};
endmodule
module nl_v_rsqrt (input wire clk, rst, input wire [63:0] a, b, c, d,
                   input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] r; nl_rsqrt_step u (.m_q30(a[31:0]), .r_q31(b[31:0]), .r_next(r));
  assign z = {32'd0, r};
endmodule
module nl_v_recip (input wire clk, rst, input wire [63:0] a, b, c, d,
                   input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] q; nl_recip_step u (.n_q31(a[31:0]), .q_q31(b[31:0]), .q_next(q));
  assign z = {32'd0, q};
endmodule
module nl_v_fmul (input wire clk, rst, input wire [63:0] a, b, c, d,
                  input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] y; nl_fmul32 u (.a(a[31:0]), .b(b[31:0]), .y(y)); assign z = {32'd0, y};
endmodule
module nl_v_fadd (input wire clk, rst, input wire [63:0] a, b, c, d,
                  input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] y; nl_fadd32 u (.a(a[31:0]), .b(b[31:0]), .y(y)); assign z = {32'd0, y};
endmodule
// A minimal float MAC: the pair a transformer's requantise actually calls.
module nl_v_fmac (input wire clk, rst, input wire [63:0] a, b, c, d,
                  input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] p, y;
  nl_fmul32 um (.a(a[31:0]), .b(b[31:0]), .y(p));
  nl_fadd32 ua (.a(p), .b(c[31:0]), .y(y));
  assign z = {32'd0, y};
endmodule

`ifndef NL_DUT
`define NL_DUT nl_v_null
`endif
module nl_harness (
  input  wire        clk, rst_i,
  input  wire [63:0] a_i, b_i, c_i, d_i,
  input  wire [15:0] ctl_i,
  output reg  [63:0] z_o
);
  reg [63:0] a_q, b_q, c_q, d_q; reg [15:0] ctl_q; reg rst_q;
  wire [63:0] z;
  always @(posedge clk) begin
    a_q <= a_i; b_q <= b_i; c_q <= c_i; d_q <= d_i;
    ctl_q <= ctl_i; rst_q <= rst_i; z_o <= z;
  end
  `NL_DUT dut (.clk(clk), .rst(rst_q), .a(a_q), .b(b_q), .c(c_q), .d(d_q),
               .ctl(ctl_q), .z(z));
endmodule
