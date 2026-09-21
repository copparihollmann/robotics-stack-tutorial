// Thin parameter-fixing wrappers, so every point on the cost menu is a plain
// module name the OOC script can pass as PEXT_DUT.
`define PEXT_WRAP(NAME, INNER, PARAMS) \
module NAME (input wire clk, input wire [63:0] a, input wire [63:0] b, \
             input wire [63:0] c, input wire [7:0] fn, output wire [63:0] z); \
  INNER PARAMS u (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z)); \
endmodule

// --- dot product, depth 3 ---------------------------------------------------
`PEXT_WRAP(pext_v_dot8_lut,        pext_pdot8_lut, #(.ACC(0), .DUAL_SIGN(1)))
`PEXT_WRAP(pext_v_dot8_lut_signed, pext_pdot8_lut, #(.ACC(0), .DUAL_SIGN(0)))
`PEXT_WRAP(pext_v_dot8_lut_acc,    pext_pdot8_lut, #(.ACC(1), .DUAL_SIGN(1)))
`PEXT_WRAP(pext_v_dot8_dsp,        pext_pdot8_dsp, #(.ACC(0), .PIPE(0)))
`PEXT_WRAP(pext_v_dot8_dsp_p2,     pext_pdot8_dsp, #(.ACC(0), .PIPE(1)))

// --- requantize -------------------------------------------------------------
`PEXT_WRAP(pext_v_requant2,        pext_prequant, #(.LANES(2), .USE_DSP("auto")))
`PEXT_WRAP(pext_v_requant2_dsp,    pext_prequant, #(.LANES(2), .USE_DSP("yes")))
`PEXT_WRAP(pext_v_requant2_lut,    pext_prequant, #(.LANES(2), .USE_DSP("no")))
`PEXT_WRAP(pext_v_requant4,        pext_prequant, #(.LANES(4), .USE_DSP("auto")))
`PEXT_WRAP(pext_v_qmul2_dsp,       pext_pqmul_2x32, #(.USE_DSP("yes")))
`PEXT_WRAP(pext_v_qmul2_lut,       pext_pqmul_2x32, #(.USE_DSP("no")))
`PEXT_WRAP(pext_v_mulscale_dsp,    pext_pmulscale_2x32, #(.USE_DSP("yes")))
`PEXT_WRAP(pext_v_mulscale_lut,    pext_pmulscale_2x32, #(.USE_DSP("no")))

// --- int16 dot --------------------------------------------------------------
`PEXT_WRAP(pext_v_dot4_16_dsp,     pext_pdot4_16, #(.USE_DSP("yes")))
`PEXT_WRAP(pext_v_dot4_16_lut,     pext_pdot4_16, #(.USE_DSP("no")))

// --- combined op sets -------------------------------------------------------
`PEXT_WRAP(pext_v_simd4_lut,       pext_simd_alu, #(.DOT_USE_DSP("no"),  .WITH_DOT16(0), .WITH_REQ(1)))
`PEXT_WRAP(pext_v_simd4_dsp,       pext_simd_alu, #(.DOT_USE_DSP("yes"), .WITH_DOT16(0), .WITH_REQ(1)))
`PEXT_WRAP(pext_v_simd5_lut,       pext_simd_alu, #(.DOT_USE_DSP("no"),  .WITH_DOT16(1), .WITH_REQ(1)))
`PEXT_WRAP(pext_v_simd4_dsp48,     pext_simd_alu, #(.DOT_USE_DSP("dsp48"), .WITH_DOT16(0), .WITH_REQ(1)))

// --- ALU + SIMD, the option (a) shape --------------------------------------
`PEXT_WRAP(pext_v_alu_simd4_lut,   pext_alu_simd, #(.DOT_USE_DSP("no"), .WITH_REQ(1)))
`PEXT_WRAP(pext_v_alu_simd4_dsp,   pext_alu_simd, #(.DOT_USE_DSP("yes"), .WITH_REQ(1)))
`PEXT_WRAP(pext_v_alu_simd_noreq,  pext_alu_simd, #(.DOT_USE_DSP("no"), .WITH_REQ(0)))
`PEXT_WRAP(pext_v_alu_simd4_dsp48, pext_alu_simd, #(.DOT_USE_DSP("dsp48"), .WITH_REQ(1)))
