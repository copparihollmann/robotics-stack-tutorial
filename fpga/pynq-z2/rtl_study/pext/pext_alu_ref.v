// -----------------------------------------------------------------------------
// Reference harnesses that put the real Rocket ALU on the same measuring stick.
//
//   pext_alu_only  : RocketALU alone (generated from this exact config)
//   pext_alu_simd  : RocketALU and the 4-op SIMD block in parallel, muxed by one
//                    extra bit -- the shape option (a) actually produces.
//
// RocketALU.sv comes from the generated sources of PynqZ2RocketBigLittleTacitConfig,
// so io_fn is 5 bits (the Zb-extended ALUFN) exactly as built.
// -----------------------------------------------------------------------------
module pext_alu_only (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire [63:0] alu_out, alu_adder;
  wire        alu_cmp;
  RocketALU u_alu (
    .io_dw(fn[7]), .io_fn(fn[4:0]), .io_in2(b), .io_in1(a),
    .io_out(alu_out), .io_adder_out(alu_adder), .io_cmp_out(alu_cmp));
  assign z = alu_out ^ alu_adder ^ {63'd0, alu_cmp};
endmodule

module pext_alu_simd #(
  parameter DOT_USE_DSP = "no",
  parameter WITH_REQ    = 1
) (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire [63:0] alu_out, alu_adder;
  wire        alu_cmp;
  RocketALU u_alu (
    .io_dw(fn[7]), .io_fn(fn[4:0]), .io_in2(b), .io_in1(a),
    .io_out(alu_out), .io_adder_out(alu_adder), .io_cmp_out(alu_cmp));

  wire [63:0] simd_out;
  pext_simd_alu #(.DOT_USE_DSP(DOT_USE_DSP), .WITH_DOT16(0), .WITH_REQ(WITH_REQ))
    u_simd (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(simd_out));

  // one extra mux level at the ALU output, which is where option (a) puts it
  wire [63:0] muxed = fn[6] ? simd_out : alu_out;
  assign z = muxed ^ alu_adder ^ {63'd0, alu_cmp};
endmodule

// RocketALU + the shallow 4-op set, same one-mux attachment.
module pext_alu_simd_shallow (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire [63:0] alu_out, alu_adder;
  wire        alu_cmp;
  RocketALU u_alu (
    .io_dw(fn[7]), .io_fn(fn[4:0]), .io_in2(b), .io_in1(a),
    .io_out(alu_out), .io_adder_out(alu_adder), .io_cmp_out(alu_cmp));
  wire [63:0] simd_out;
  pext_simd_alu_shallow u_simd (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(simd_out));
  wire [63:0] muxed = fn[6] ? simd_out : alu_out;
  assign z = muxed ^ alu_adder ^ {63'd0, alu_cmp};
endmodule
