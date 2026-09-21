// -----------------------------------------------------------------------------
// The four-op packed-SIMD block as it would actually be added to the ALU: all
// four datapaths in parallel plus the result mux, because the mux is part of the
// delay and costing the ops one at a time hides it.
//
//   fn[7:5] = 000 pdot8    001 pmax/pmin8   010 padd/psub8.sat   011 prequant
//             100 pdot4.16 (only when WITH_DOT16 = 1)
//   fn[1:0] = the per-op modifier bits (signed/unsigned, max/min, add/sub)
// -----------------------------------------------------------------------------
module pext_simd_alu #(
  parameter DOT_USE_DSP = "no",
  parameter WITH_DOT16  = 0,
  parameter WITH_REQ    = 1
) (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire [63:0] z_dot, z_mm, z_as, z_rq, z_d16;

  generate
    if (DOT_USE_DSP == "dsp48") begin : g_dot_dsp48
      pext_pdot8_dsp48 #(.PIPE(0)) u_dot (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_dot));
    end else if (DOT_USE_DSP == "yes") begin : g_dot_dsp
      pext_pdot8_dsp #(.ACC(0), .PIPE(0)) u_dot (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_dot));
    end else begin : g_dot_lut
      pext_pdot8_lut #(.ACC(0), .DUAL_SIGN(1)) u_dot (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_dot));
    end
  endgenerate

  pext_pmaxmin8     u_mm (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_mm));
  pext_paddsub8_sat u_as (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_as));

  generate
    if (WITH_REQ != 0) begin : g_rq
      pext_prequant #(.LANES(2), .USE_DSP("auto")) u_rq (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_rq));
    end else begin : g_no_rq
      assign z_rq = 64'd0;
    end
    if (WITH_DOT16 != 0) begin : g_d16
      pext_pdot4_16 #(.USE_DSP("no")) u_d16 (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_d16));
    end else begin : g_no_d16
      assign z_d16 = 64'd0;
    end
  endgenerate

  reg [63:0] sel;
  always @(*) begin
    case (fn[7:5])
      3'd0:    sel = z_dot;
      3'd1:    sel = z_mm;
      3'd2:    sel = z_as;
      3'd3:    sel = z_rq;
      3'd4:    sel = z_d16;
      default: sel = 64'd0;
    endcase
  end
  assign z = sel;
endmodule
