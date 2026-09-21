// -----------------------------------------------------------------------------
// The INTEGRATED measurement: the ALU that Chisel actually generated, not a
// Verilog model of one.
//
// Everything else in this directory measures a candidate datapath bolted onto the
// side of RocketALU with an extra result mux -- which is what the FEASIBILITY study
// had to do, because nothing was integrated yet. That is no longer the honest
// question. `coreParams.usePExt` puts the four ops INSIDE RocketALU's own
// MuxLookup, so there is no extra mux level, and the thing to measure is the
// generated module:
//
//   RocketALU        <- RocketALU_vendored.sv       PynqZ2RocketBigLittleTacitConfig
//   RocketALU_pext   <- RocketALU_pext_vendored.sv  PynqZ2RocketBigLittlePextTacitConfig, hart 0
//
// Both are firtool output from a real elaboration. Hart 1's RocketALU_1 in the
// P-ext config is byte-identical to the stock RocketALU (verified by diff), so the
// stock module is BOTH the baseline and hart 1.
//
// Two shapes are measured, because they answer different questions:
//
//   pext_alu_only / pext_alu_pext        the ALU cone alone -- the delta the
//                                        instruction adds to the ALU itself
//   pext_ex_int_base / pext_ex_int_pext  the whole EX stage: bypass network,
//                                        operand muxes, ALU, and the three result
//                                        registers -- the path that has to close
//
// The EX-stage model below is pext_ex_stage.v with ONE change: the SIMD block and
// its result mux are gone, because with usePExt the SIMD is inside the ALU. That
// makes pext_ex_int_base and pext_ex_stage #(.SIMD("none")) the same circuit, and
// running both is the cross-check that this transcription did not drift.
// -----------------------------------------------------------------------------

// ---- the ALU cone alone, P-ext version (pext_alu_only is the baseline) -------
module pext_alu_pext (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire [63:0] alu_out, alu_adder;
  wire        alu_cmp;
  RocketALU_pext u_alu (
    .io_dw(fn[7]), .io_fn(fn[4:0]), .io_in2(b), .io_in1(a),
    .io_out(alu_out), .io_adder_out(alu_adder), .io_cmp_out(alu_cmp));
  // same output reduction as pext_alu_only, so the two rows are comparable
  assign z = alu_out ^ alu_adder ^ {63'd0, alu_cmp};
endmodule

// ---- the EX stage, with either ALU ------------------------------------------
//
// Transcribed from rocket-chip/src/main/scala/rocket/RocketCore.scala, same lines
// as pext_ex_stage.v:
//   :489-493  bypass_sources
//   :505-518  ex_op1/ex_op2 muxes
//   :537-541  alu.io.in1/in2 <- ex_op1/ex_op2
//   :692/:693 mem_reg_wdata / mem_br_taken
//   :1205     the D$ address off alu.io.adder_out
module pext_ex_int #(
  parameter ALU_MOD = "stock"      // "stock" | "pext"
) (
  input  wire        clk,
  input  wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i,
  input  wire [1:0]  sel1_i, sel2_i,
  input  wire [1:0]  byp1_i, byp2_i,
  input  wire [7:0]  fn_i,
  input  wire        dw_i,
  output reg  [63:0] mem_reg_wdata,
  output reg  [63:0] dmem_addr,
  output reg         mem_br_taken
);
  reg [63:0] rs1, rs2, byp, imm, pc;
  reg [1:0]  sel1, sel2, byp1, byp2;
  reg [7:0]  fn;
  reg        dw;
  always @(posedge clk) begin
    rs1 <= rs1_i; rs2 <= rs2_i; byp <= bypass_i; imm <= imm_i; pc <= pc_i;
    sel1 <= sel1_i; sel2 <= sel2_i; byp1 <= byp1_i; byp2 <= byp2_i;
    fn <= fn_i; dw <= dw_i;
  end

  reg [63:0] ex_rs1, ex_rs2;
  always @(*) begin
    case (byp1)
      2'd0: ex_rs1 = 64'd0;
      2'd1: ex_rs1 = byp;
      2'd2: ex_rs1 = {byp[31:0], byp[63:32]};
      default: ex_rs1 = rs1;
    endcase
    case (byp2)
      2'd0: ex_rs2 = 64'd0;
      2'd1: ex_rs2 = byp;
      2'd2: ex_rs2 = {byp[31:0], byp[63:32]};
      default: ex_rs2 = rs2;
    endcase
  end

  reg [63:0] ex_op1, ex_op2;
  always @(*) begin
    case (sel1)
      2'd0: ex_op1 = 64'd0;
      2'd1: ex_op1 = ex_rs1;
      2'd2: ex_op1 = pc;
      default: ex_op1 = ex_rs1;
    endcase
    case (sel2)
      2'd0: ex_op2 = 64'd0;
      2'd1: ex_op2 = ex_rs2;
      2'd2: ex_op2 = imm;
      default: ex_op2 = 64'd4;
    endcase
  end

  wire [63:0] alu_out, alu_adder;
  wire        alu_cmp;
  generate
    if (ALU_MOD == "pext") begin : g_alu_pext
      RocketALU_pext u_alu (
        .io_dw(dw), .io_fn(fn[4:0]), .io_in2(ex_op2), .io_in1(ex_op1),
        .io_out(alu_out), .io_adder_out(alu_adder), .io_cmp_out(alu_cmp));
    end else begin : g_alu_stock
      RocketALU u_alu (
        .io_dw(dw), .io_fn(fn[4:0]), .io_in2(ex_op2), .io_in1(ex_op1),
        .io_out(alu_out), .io_adder_out(alu_adder), .io_cmp_out(alu_cmp));
    end
  endgenerate

  always @(posedge clk) begin
    mem_reg_wdata <= alu_out;                         // :692
    mem_br_taken  <= alu_cmp;                         // :693
    dmem_addr     <= {alu_adder[63] ^ alu_adder[38],  // encodeVirtualAddress, :1205
                      alu_adder[62:0]};
  end
endmodule

module pext_ex_int_base (input wire clk, input wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i, input wire [1:0] sel1_i, sel2_i, byp1_i, byp2_i, input wire [7:0] fn_i, input wire dw_i, output wire [63:0] mem_reg_wdata, dmem_addr, output wire mem_br_taken);
  pext_ex_int #(.ALU_MOD("stock")) u (.*);
endmodule

module pext_ex_int_pext (input wire clk, input wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i, input wire [1:0] sel1_i, sel2_i, byp1_i, byp2_i, input wire [7:0] fn_i, input wire dw_i, output wire [63:0] mem_reg_wdata, dmem_addr, output wire mem_br_taken);
  pext_ex_int #(.ALU_MOD("pext")) u (.*);
endmodule

// -----------------------------------------------------------------------------
// Per-op cones.  The same generated RocketALU_pext with io_fn tied to one function
// code, so synthesis keeps only that op's logic and the question "which of the four
// is the critical path" gets a number instead of an inference.
//
// READ THESE HONESTLY: with fn constant the result mux collapses too, so a per-op
// row is a LOWER bound on that op's contribution to the real ALU, not its cost in
// it.  The row that matters for closure is alu_pext / ex_pext, where all four and
// the mux are live.  These exist to say WHICH op to attack if it does not close.
// -----------------------------------------------------------------------------
module pext_alu_op #(parameter [4:0] FN = 5'd20) (
  input  wire        clk,
  input  wire [63:0] a,
  input  wire [63:0] b,
  input  wire [63:0] c,
  input  wire [7:0]  fn,
  output wire [63:0] z
);
  wire [63:0] alu_out, alu_adder;
  wire        alu_cmp;
  RocketALU_pext u_alu (
    .io_dw(1'b1), .io_fn(FN), .io_in2(b), .io_in1(a),
    .io_out(alu_out), .io_adder_out(alu_adder), .io_cmp_out(alu_cmp));
  assign z = alu_out ^ alu_adder ^ {63'd0, alu_cmp};
endmodule

module pext_alu_op_dot8  (input wire clk, input wire [63:0] a, b, c, input wire [7:0] fn, output wire [63:0] z);
  pext_alu_op #(.FN(5'd20)) u (.*);
endmodule
module pext_alu_op_max8  (input wire clk, input wire [63:0] a, b, c, input wire [7:0] fn, output wire [63:0] z);
  pext_alu_op #(.FN(5'd21)) u (.*);
endmodule
module pext_alu_op_qmul  (input wire clk, input wire [63:0] a, b, c, input wire [7:0] fn, output wire [63:0] z);
  pext_alu_op #(.FN(5'd22)) u (.*);
endmodule
module pext_alu_op_clip8 (input wire clk, input wire [63:0] a, b, c, input wire [7:0] fn, output wire [63:0] z);
  pext_alu_op #(.FN(5'd23)) u (.*);
endmodule
