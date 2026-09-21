// -----------------------------------------------------------------------------
// A faithful model of Rocket's EX stage, so the cost of bolting a packed-SIMD
// block onto the ALU is measured on the path that actually exists rather than on
// a synthetic wrapper.
//
// Transcribed from rocket-chip/src/main/scala/rocket/RocketCore.scala:
//   :489-493  bypass_sources  = {0, mem_reg_wdata, wb_reg_wdata, dcache_bypass_data}
//   :505-518  ex_op1/ex_op2 muxes (RS1/PC, RS2/IMM/zero/size)
//   :537-541  alu.io.in1/in2 <- ex_op1/ex_op2
//   :692      mem_reg_wdata := alu.io.out          (registered)
//   :693      mem_br_taken  := alu.io.cmp_out      (registered)
//   :1205     io.dmem.req.bits.addr := f(alu.io.adder_out)   (same cycle, then registered)
//
// The three ALU outputs go to three SEPARATE registers, as they do in the core.
// SIMD selects what the result mux at alu.io.out costs.
//
//   SIMD = "none"     -- the baseline, RocketALU alone
//   SIMD = "shallow"  -- depth-1 dot, max/min, saturating add/sub, int16->int8 pack
//   SIMD = "deep"     -- depth-3 dot, max/min, saturating add/sub (no requantize)
//   SIMD = "full"     -- deep plus the fused requantize
//   SIMD = "dsp48"    -- deep, with the dot product on explicit DSP48E1s
// -----------------------------------------------------------------------------
module pext_ex_stage #(
  parameter SIMD = "none"
) (
  input  wire        clk,
  input  wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i,
  input  wire [1:0]  sel1_i, sel2_i,
  input  wire [1:0]  byp1_i, byp2_i,
  input  wire [7:0]  fn_i,
  input  wire        dw_i, simd_i,
  output reg  [63:0] mem_reg_wdata,
  output reg  [63:0] dmem_addr,
  output reg         mem_br_taken
);
  reg [63:0] rs1, rs2, byp, imm, pc;
  reg [1:0]  sel1, sel2, byp1, byp2;
  reg [7:0]  fn;
  reg        dw, simd_en;
  always @(posedge clk) begin
    rs1 <= rs1_i; rs2 <= rs2_i; byp <= bypass_i; imm <= imm_i; pc <= pc_i;
    sel1 <= sel1_i; sel2 <= sel2_i; byp1 <= byp1_i; byp2 <= byp2_i;
    fn <= fn_i; dw <= dw_i; simd_en <= simd_i;
  end

  // bypass network (RocketCore.scala:489-493)
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

  // operand muxes (RocketCore.scala:505-518)
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
  RocketALU u_alu (
    .io_dw(dw), .io_fn(fn[4:0]), .io_in2(ex_op2), .io_in1(ex_op1),
    .io_out(alu_out), .io_adder_out(alu_adder), .io_cmp_out(alu_cmp));

  wire [63:0] simd_out;
  generate
    if (SIMD == "shallow") begin : g_shallow
      pext_simd_alu_shallow u_s (.clk(clk), .a(ex_op1), .b(ex_op2), .c(64'd0), .fn(fn), .z(simd_out));
    end else if (SIMD == "mid") begin : g_mid
      pext_simd_alu_mid u_s (.clk(clk), .a(ex_op1), .b(ex_op2), .c(64'd0), .fn(fn), .z(simd_out));
    end else if (SIMD == "deep") begin : g_deep
      pext_simd_alu #(.DOT_USE_DSP("no"), .WITH_DOT16(0), .WITH_REQ(0))
        u_s (.clk(clk), .a(ex_op1), .b(ex_op2), .c(64'd0), .fn(fn), .z(simd_out));
    end else if (SIMD == "full") begin : g_full
      pext_simd_alu #(.DOT_USE_DSP("no"), .WITH_DOT16(0), .WITH_REQ(1))
        u_s (.clk(clk), .a(ex_op1), .b(ex_op2), .c(64'd0), .fn(fn), .z(simd_out));
    end else if (SIMD == "dsp48") begin : g_dsp48
      pext_simd_alu #(.DOT_USE_DSP("dsp48"), .WITH_DOT16(0), .WITH_REQ(0))
        u_s (.clk(clk), .a(ex_op1), .b(ex_op2), .c(64'd0), .fn(fn), .z(simd_out));
    end else begin : g_none
      assign simd_out = 64'd0;
    end
  endgenerate

  wire [63:0] ex_result = (SIMD == "none") ? alu_out : (simd_en ? simd_out : alu_out);

  always @(posedge clk) begin
    mem_reg_wdata <= ex_result;                       // :692
    mem_br_taken  <= alu_cmp;                         // :693
    dmem_addr     <= {alu_adder[63] ^ alu_adder[38],  // encodeVirtualAddress, :1205
                      alu_adder[62:0]};
  end
endmodule

module pext_ex_none    (input wire clk, input wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i, input wire [1:0] sel1_i, sel2_i, byp1_i, byp2_i, input wire [7:0] fn_i, input wire dw_i, simd_i, output wire [63:0] mem_reg_wdata, dmem_addr, output wire mem_br_taken);
  pext_ex_stage #(.SIMD("none")) u (.*);
endmodule
module pext_ex_shallow (input wire clk, input wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i, input wire [1:0] sel1_i, sel2_i, byp1_i, byp2_i, input wire [7:0] fn_i, input wire dw_i, simd_i, output wire [63:0] mem_reg_wdata, dmem_addr, output wire mem_br_taken);
  pext_ex_stage #(.SIMD("shallow")) u (.*);
endmodule
module pext_ex_mid     (input wire clk, input wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i, input wire [1:0] sel1_i, sel2_i, byp1_i, byp2_i, input wire [7:0] fn_i, input wire dw_i, simd_i, output wire [63:0] mem_reg_wdata, dmem_addr, output wire mem_br_taken);
  pext_ex_stage #(.SIMD("mid")) u (.*);
endmodule
module pext_ex_deep    (input wire clk, input wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i, input wire [1:0] sel1_i, sel2_i, byp1_i, byp2_i, input wire [7:0] fn_i, input wire dw_i, simd_i, output wire [63:0] mem_reg_wdata, dmem_addr, output wire mem_br_taken);
  pext_ex_stage #(.SIMD("deep")) u (.*);
endmodule
module pext_ex_full    (input wire clk, input wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i, input wire [1:0] sel1_i, sel2_i, byp1_i, byp2_i, input wire [7:0] fn_i, input wire dw_i, simd_i, output wire [63:0] mem_reg_wdata, dmem_addr, output wire mem_br_taken);
  pext_ex_stage #(.SIMD("full")) u (.*);
endmodule
module pext_ex_dsp48   (input wire clk, input wire [63:0] rs1_i, rs2_i, bypass_i, imm_i, pc_i, input wire [1:0] sel1_i, sel2_i, byp1_i, byp2_i, input wire [7:0] fn_i, input wire dw_i, simd_i, output wire [63:0] mem_reg_wdata, dmem_addr, output wire mem_br_taken);
  pext_ex_stage #(.SIMD("dsp48")) u (.*);
endmodule
