// Functional check of the explicitly-instantiated DSP48E1 dot product against
// the LUT version, using the Vivado unisim models.
//   xvlog ... ; xelab -L unisims_ver ; xsim
module tb_pext_dsp48;
  reg clk = 0;
  always #5 clk = ~clk;
  reg [63:0] a, b, c;
  reg [7:0]  fn;
  integer n, errs = 0;
  wire [63:0] z_dsp, z_lut;
  pext_v_dot8_dsp48 ud (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_dsp));
  pext_v_dot8_lut   ul (.clk(clk), .a(a), .b(b), .c(c), .fn(fn), .z(z_lut));
  initial begin
    for (n = 0; n < 600; n = n + 1) begin
      a = {$random, $random}; b = {$random, $random}; c = 64'd0; fn = $random;
      #20;
      if (z_dsp !== z_lut) begin
        errs = errs + 1;
        if (errs < 8) $display("FAIL a=%h b=%h fn=%h dsp=%h lut=%h", a, b, fn, z_dsp, z_lut);
      end
    end
    if (errs == 0) $display("PEXT_DSP48_OK %0d vectors", n);
    else           $display("PEXT_DSP48_FAIL %0d mismatches", errs);
    $finish;
  end
endmodule
