// -----------------------------------------------------------------------------
// Self-checking functional testbench for the behavioural (LUT) MBX blocks.
// Same rule as rtl_study/pext/tb_pext.sv: no block's area is reported until it
// has been checked against an independent reference.
//
//   $VERILATOR --binary -Wno-fatal --top-module tb_mbx tb_mbx.sv \
//              mbx_mac.v mbx_quant.v mbx_gather.v
//
// The DSP48E1 packing is checked separately, against the Xilinx unisim models,
// by tb_mbx_dsp.sv -- Verilator has no DSP48E1.
// -----------------------------------------------------------------------------
module tb_mbx;
  localparam N = 1000;
  reg clk = 0;
  always #5 clk = ~clk;

  integer i, l, k, errs = 0;
  reg signed [63:0] ref64;
  reg signed [63:0] acc_ref [0:3];

  // ---------------- 1. mbx_mac8xn_lut : broadcast MAC ------------------------
  reg  [63:0]  a;
  reg  [255:0] w;
  reg  [63:0]  seed;
  reg          en, clr;
  wire [255:0] acc;
  mbx_mac8xn_lut #(.N(4)) u_mac (.clk(clk), .en(en), .clr(clr), .a(a), .w(w),
                                 .seed(seed), .acc(acc));

  function automatic signed [63:0] dot8(input [63:0] x, input [63:0] y);
    integer j; reg signed [63:0] s; reg signed [7:0] xb, yb;
    begin
      s = 0;
      for (j = 0; j < 8; j = j + 1) begin
        xb = x[j*8 +: 8]; yb = y[j*8 +: 8];
        s = s + $signed(xb) * $signed(yb);
      end
      dot8 = s;
    end
  endfunction

  // ---------------- 2. mbx_quant : the requantised output stage --------------
  reg  [255:0] qacc;
  reg  [31:0]  mult;
  reg  [5:0]   sh;
  reg          relu;
  wire [31:0]  y;
  mbx_quant #(.LANES(4), .STAGES(1)) u_q (.clk(clk), .en(1'b1), .acc(qacc),
                                          .mult(mult), .shift(sh), .relu(relu),
                                          .y(y));

  function automatic signed [7:0] qref(input [31:0] av, input [31:0] mv,
                                       input [5:0] sv, input rl);
    reg signed [31:0] a32, m32;
    reg signed [63:0] p, q, r;
    begin
      a32 = av; m32 = mv;
      p = ($signed({{32{a32[31]}}, a32}) * $signed({{32{m32[31]}}, m32})
           + 64'sd1073741824) >>> 31;
      if (sv == 0) q = p;
      else         q = (p + (64'sd1 <<< (sv - 1))) >>> sv;
      r = q;
      if (r < -64'sd128) r = -64'sd128;
      if (r >  64'sd127) r =  64'sd127;
      if (rl && r < 0)   r = 0;
      qref = r[7:0];
    end
  endfunction

  // ---------------- 3. mbx_align : the gather byte funnel --------------------
  reg  [63:0] glo, ghi, gres;
  reg  [2:0]  gsh, gpos;
  reg  [3:0]  glen;
  wire [63:0] gm;
  wire [7:0]  gbe;
  mbx_align u_al (.lo(glo), .hi(ghi), .sh(gsh), .pos(gpos), .len(glen),
                  .resid(gres), .merged(gm), .be(gbe));

  reg [63:0] aref;
  reg [127:0] pairref;

  initial begin
    // ---- MAC ----------------------------------------------------------------
    for (i = 0; i < N; i = i + 1) begin
      a    = {$random, $random};
      w    = {$random, $random, $random, $random, $random, $random, $random, $random};
      seed = {$random, $random};
      clr = (i == 0) || ($random & 3) == 0;
      en  = 1'b1;
      for (l = 0; l < 4; l = l + 1)
        acc_ref[l] = (clr ? $signed(seed) : acc_ref[l]) + dot8(a, w[l*64 +: 64]);
      @(posedge clk); #1;
      for (l = 0; l < 4; l = l + 1)
        if ($signed(acc[l*64 +: 64]) !== acc_ref[l]) begin
          errs = errs + 1;
          if (errs < 8)
            $display("MAC FAIL i=%0d lane=%0d got=%0d want=%0d",
                     i, l, $signed(acc[l*64 +: 64]), acc_ref[l]);
        end
    end
    en = 0; clr = 0;

    // ---- quant --------------------------------------------------------------
    for (i = 0; i < N; i = i + 1) begin
      qacc = {$random, $random, $random, $random, $random, $random, $random, $random};
      mult = $random; sh = $random & 6'h1f; relu = $random & 1;  // shift 0..31,
      // which PEXT_SPEC.md 1.2 measures as the whole domain: output_shift is
      // always strictly positive and never above 31 in any record this
      // exporter emits.  mbx_quant is not defined outside it.
      #1;
      for (l = 0; l < 4; l = l + 1)
        if ($signed(y[l*8 +: 8]) !== qref(qacc[l*64 +: 32], mult, sh, relu)) begin
          errs = errs + 1;
          if (errs < 16)
            $display("QUANT FAIL i=%0d lane=%0d acc=%h mult=%h sh=%0d relu=%0d got=%0d want=%0d",
                     i, l, qacc[l*64 +: 32], mult, sh, relu,
                     $signed(y[l*8 +: 8]), qref(qacc[l*64 +: 32], mult, sh, relu));
        end
    end

    // ---- align --------------------------------------------------------------
    for (i = 0; i < N; i = i + 1) begin
      glo = {$random, $random}; ghi = {$random, $random};
      gres = {$random, $random};
      gsh = $random; gpos = $random; glen = ($random % 8) + 1;
      if (glen + gpos > 8) glen = 8 - gpos;
      if (glen == 0) glen = 1;
      #1;
      pairref = {ghi, glo};
      aref = gres;
      for (k = 0; k < glen; k = k + 1)
        aref[(gpos + k)*8 +: 8] = pairref[(gsh + k)*8 +: 8];
      if (gm !== aref) begin
        errs = errs + 1;
        if (errs < 24)
          $display("ALIGN FAIL i=%0d sh=%0d pos=%0d len=%0d got=%h want=%h",
                   i, gsh, gpos, glen, gm, aref);
      end
    end

    if (errs == 0) $display("MBX_TB_OK %0d vectors per block, 0 mismatches", N);
    else           $display("MBX_TB_FAIL %0d mismatches", errs);
    $finish;
  end
endmodule
