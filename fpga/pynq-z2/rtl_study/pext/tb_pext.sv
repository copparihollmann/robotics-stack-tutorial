// Self-checking functional test for the pext study modules.  Random vectors
// against behavioural reference models.  Not a verification suite -- it exists
// so the area/timing numbers are for logic that computes the right thing.
// Build/run: see run_tb.sh in this directory.
module tb_pext;
  reg clk = 0;
  always #5 clk = ~clk;

  reg [63:0] a, b, c;
  reg [7:0]  fn;
  integer errs = 0, n;
  integer i;

  // NB: must be if/else, not ?: -- a ternary with one unsigned arm makes the
  // whole expression unsigned and silently zero-extends the signed arm.
  function automatic integer sx8(input [7:0] v, input sgn);
    if (sgn) sx8 = $signed(v);
    else     sx8 = {24'd0, v};
  endfunction
  function automatic integer sx16(input [15:0] v);
    sx16 = $signed(v);
  endfunction

  wire [63:0] z_dot, z_mm, z_as, z_rq, z_d16, z_m816, z_d4x16, z_d2x32;
  wire [63:0] z_pad32, z_pad16, z_qm, z_cl32, z_cl16, z_dsp;

  pext_pdot8_lut #(.ACC(0),.DUAL_SIGN(1)) u0(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_dot));
  pext_pdot8_dsp #(.ACC(0),.PIPE(0))      u0d(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_dsp));
  pext_pmaxmin8                           u1(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_mm));
  pext_paddsub8_sat                       u2(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_as));
  pext_prequant #(.LANES(2))              u3(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_rq));
  pext_pdot4_16                           u4(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_d16));
  pext_pmul8_16                           u5(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_m816));
  pext_pdot8_4x16                         u6(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_d4x16));
  pext_pdot8_2x32                         u7(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_d2x32));
  pext_padd_2x32                          u8(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_pad32));
  pext_padd_4x16_sat                      u9(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_pad16));
  pext_pqmul_2x32                         u10(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_qm));
  pext_pclamp_2x32_to_8                   u11(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_cl32));
  pext_pclamp_4x16_to_8                   u12(.clk(clk),.a(a),.b(b),.c(c),.fn(fn),.z(z_cl16));

  task chk(input [127:0] nm, input [63:0] got, input [63:0] exp);
    if (got !== exp) begin
      errs = errs + 1;
      if (errs < 12) $display("FAIL %0s a=%h b=%h fn=%h got=%h exp=%h", nm, a, b, fn, got, exp);
    end
  endtask

  reg signed [63:0] acc;
  reg        [63:0] e;
  reg signed [63:0] p, s, t;
  reg signed [7:0]  av8, bv8;
  reg signed [15:0] av16, bv16;
  reg        [5:0]  shq;
  reg signed [15:0] scl;
  reg signed [7:0]  zpq;
  reg signed [63:0] prod, sum2, shr2, wz;

  initial begin
    for (n = 0; n < 4000; n = n + 1) begin
      a  = {$random, $random};
      b  = {$random, $random};
      c  = {$random, $random};
      fn = $random;
      b[21] = 1'b0;   // keep the requantize shift in 0..31, the specified range
      #1;

      // --- pdot8 (depth 3), signed and unsigned -------------------------------
      acc = 0;
      for (i = 0; i < 8; i = i + 1)
        acc = acc + sx8(a[i*8 +: 8], fn[0]) * sx8(b[i*8 +: 8], fn[0]);
      chk("pdot8_lut", z_dot, acc[63:0]);
      chk("pdot8_dsp", z_dsp, acc[63:0]);

      // --- pmaxmin8 -----------------------------------------------------------
      for (i = 0; i < 8; i = i + 1) begin
        if (fn[1]) begin  // signed
          av8 = a[i*8 +: 8]; bv8 = b[i*8 +: 8];
          e[i*8 +: 8] = fn[0] ? ((av8 > bv8) ? av8 : bv8) : ((av8 < bv8) ? av8 : bv8);
        end else begin
          e[i*8 +: 8] = fn[0] ? ((a[i*8 +: 8] > b[i*8 +: 8]) ? a[i*8 +: 8] : b[i*8 +: 8])
                              : ((a[i*8 +: 8] < b[i*8 +: 8]) ? a[i*8 +: 8] : b[i*8 +: 8]);
        end
      end
      chk("pmaxmin8", z_mm, e);

      // --- paddsub8_sat -------------------------------------------------------
      for (i = 0; i < 8; i = i + 1) begin
        if (fn[1]) begin
          s = $signed({{56{a[i*8+7]}}, a[i*8 +: 8]});
          t = $signed({{56{b[i*8+7]}}, b[i*8 +: 8]});
          p = fn[0] ? (s - t) : (s + t);
          e[i*8 +: 8] = (p > 127) ? 8'h7F : (p < -128) ? 8'h80 : p[7:0];
        end else begin
          s = {56'd0, a[i*8 +: 8]};
          t = {56'd0, b[i*8 +: 8]};
          p = fn[0] ? (s - t) : (s + t);
          e[i*8 +: 8] = (p > 255) ? 8'hFF : (p < 0) ? 8'h00 : p[7:0];
        end
      end
      chk("paddsub8_sat", z_as, e);

      // --- pmul8_16 (depth 0) -------------------------------------------------
      for (i = 0; i < 4; i = i + 1) begin
        p = sx8(a[(fn[2] ? i+4 : i)*8 +: 8], fn[0]) * sx8(b[(fn[2] ? i+4 : i)*8 +: 8], fn[0]);
        e[i*16 +: 16] = p[15:0];
      end
      chk("pmul8_16", z_m816, e);

      // --- pdot8_4x16 (depth 1) ----------------------------------------------
      for (i = 0; i < 4; i = i + 1) begin
        p = sx8(a[(2*i)*8   +: 8], fn[0]) * sx8(b[(2*i)*8   +: 8], fn[0])
          + sx8(a[(2*i+1)*8 +: 8], fn[0]) * sx8(b[(2*i+1)*8 +: 8], fn[0]);
        e[i*16 +: 16] = p[15:0];
      end
      chk("pdot8_4x16", z_d4x16, e);

      // --- pdot8_2x32 (depth 2) ----------------------------------------------
      for (i = 0; i < 2; i = i + 1) begin
        p = sx8(a[(4*i+0)*8 +: 8], fn[0]) * sx8(b[(4*i+0)*8 +: 8], fn[0])
          + sx8(a[(4*i+1)*8 +: 8], fn[0]) * sx8(b[(4*i+1)*8 +: 8], fn[0])
          + sx8(a[(4*i+2)*8 +: 8], fn[0]) * sx8(b[(4*i+2)*8 +: 8], fn[0])
          + sx8(a[(4*i+3)*8 +: 8], fn[0]) * sx8(b[(4*i+3)*8 +: 8], fn[0]);
        e[i*32 +: 32] = p[31:0];
      end
      chk("pdot8_2x32", z_d2x32, e);

      // --- pdot4_16 -----------------------------------------------------------
      acc = 0;
      for (i = 0; i < 4; i = i + 1) begin
        if (fn[0]) acc = acc + $signed(a[i*16 +: 16]) * $signed(b[i*16 +: 16]);
        else       acc = acc + $unsigned(a[i*16 +: 16]) * $unsigned(b[i*16 +: 16]);
      end
      chk("pdot4_16", z_d16, acc[63:0]);

      // --- padd_2x32 / padd_4x16_sat -----------------------------------------
      e[31:0]  = a[31:0]  + b[31:0];
      e[63:32] = a[63:32] + b[63:32];
      chk("padd_2x32", z_pad32, e);

      for (i = 0; i < 4; i = i + 1) begin
        av16 = a[i*16 +: 16]; bv16 = b[i*16 +: 16];
        p = fn[0] ? ($signed({{48{av16[15]}},av16}) - $signed({{48{bv16[15]}},bv16}))
                  : ($signed({{48{av16[15]}},av16}) + $signed({{48{bv16[15]}},bv16}));
        e[i*16 +: 16] = (p > 32767) ? 16'h7FFF : (p < -32768) ? 16'h8000 : p[15:0];
      end
      chk("padd_4x16_sat", z_pad16, e);

      // --- pqmul_2x32 / prequant / clamps ------------------------------------
      scl = b[15:0]; shq = b[21:16]; zpq = b[31:24];
      e = 64'd0;
      for (i = 0; i < 2; i = i + 1) begin
        prod = $signed(a[i*32 +: 32]) * scl;
        sum2 = prod + ((shq == 0) ? 0 : (64'd1 << (shq-1)));
        shr2 = sum2 >>> shq;
        e[i*32 +: 32] = shr2[31:0];
      end
      chk("pqmul_2x32", z_qm, e);

      e = 64'd0;
      for (i = 0; i < 2; i = i + 1) begin
        prod = $signed(a[i*32 +: 32]) * scl;
        sum2 = prod + ((shq == 0) ? 0 : (64'd1 << (shq-1)));
        shr2 = sum2 >>> shq;
        wz   = shr2 + zpq;
        e[i*8 +: 8] = (wz > 127) ? 8'h7F : (wz < -128) ? 8'h80 : wz[7:0];
      end
      chk("prequant2", z_rq, e);

      e = 64'd0;
      for (i = 0; i < 2; i = i + 1) begin
        wz = $signed(a[i*32 +: 32]) + zpq;
        e[i*8 +: 8] = (wz > 127) ? 8'h7F : (wz < -128) ? 8'h80 : wz[7:0];
      end
      chk("pclamp_2x32_to_8", z_cl32, e);

      e = 64'd0;
      for (i = 0; i < 4; i = i + 1) begin
        wz = $signed(a[i*16 +: 16]);
        e[i*8 +: 8] = (wz > 127) ? 8'h7F : (wz < -128) ? 8'h80 : wz[7:0];
      end
      chk("pclamp_4x16_to_8", z_cl16, e);
    end

    // directed saturation corners
    a = 64'h7F7F_7F7F_8080_8080; b = 64'h7F7F_7F7F_8080_8080; fn = 8'h02; #1;
    if (z_as !== 64'h7F7F_7F7F_8080_8080) begin
      errs = errs + 1; $display("FAIL sat-corner got=%h", z_as);
    end

    if (errs == 0) $display("PEXT_TB_OK  %0d vectors, 0 mismatches", n);
    else           $display("PEXT_TB_FAIL %0d mismatches", errs);
    $finish;
  end
endmodule
