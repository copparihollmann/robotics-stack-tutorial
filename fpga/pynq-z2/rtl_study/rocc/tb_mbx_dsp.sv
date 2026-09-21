// -----------------------------------------------------------------------------
// The DSP48E1 packing, checked against the LUT multipliers using Xilinx's own
// unisim models.  This is the one piece of arithmetic in the study that is not
// obvious, and it fails silently when it fails:
//
//   A = w_hi*2^16 + w_lo ,  B = a
//   w_lo*a = $signed(P[15:0]) ;  w_hi*a = $signed(P[31:16]) + P[15]
//
// The corner that matters is w_hi = w_lo = a = -128, which is why the vectors
// below are half random and half drawn from {-128, -1, 0, 1, 127}.
//
//   xvlog -sv tb_mbx_dsp.sv ; xvlog mbx_mac.v ; xelab -L unisims_ver tb_mbx_dsp ; xsim ...
// -----------------------------------------------------------------------------
module tb_mbx_dsp;
  localparam N = 800;
  reg clk = 0;
  always #5 clk = ~clk;

  reg  [63:0]  a;
  reg  [255:0] w;
  reg          en, clr;
  wire [255:0] acc_pack, acc_nopack, acc_lut;
  integer i, l, b, errs = 0;
  reg [7:0] corner [0:4];

  mbx_mac8xn_dsp #(.N(4), .PACK(1), .PIPE(0)) up (
    .clk(clk), .en(en), .clr(clr), .a(a), .w(w), .seed(64'd0), .acc(acc_pack));
  mbx_mac8xn_dsp #(.N(4), .PACK(0), .PIPE(0)) un (
    .clk(clk), .en(en), .clr(clr), .a(a), .w(w), .seed(64'd0), .acc(acc_nopack));
  mbx_mac8xn_lut #(.N(4)) ul (
    .clk(clk), .en(en), .clr(clr), .a(a), .w(w), .seed(64'd0), .acc(acc_lut));

  initial begin
    corner[0] = 8'h80; corner[1] = 8'hff; corner[2] = 8'h00;
    corner[3] = 8'h01; corner[4] = 8'h7f;
    en = 1; clr = 1;
    for (i = 0; i < N; i = i + 1) begin
      if (i < N/2) begin
        // corner sweep: every byte drawn from {-128,-1,0,1,127}
        for (b = 0; b < 8; b = b + 1) a[b*8 +: 8] = corner[$random % 5 < 0 ? 0 : ($random % 5)];
        for (b = 0; b < 32; b = b + 1) w[b*8 +: 8] = corner[({$random} % 5)];
        for (b = 0; b < 8; b = b + 1)  a[b*8 +: 8] = corner[({$random} % 5)];
      end else begin
        a = {$random, $random};
        w = {$random, $random, $random, $random, $random, $random, $random, $random};
      end
      clr = 1;
      @(posedge clk); #1;
      for (l = 0; l < 4; l = l + 1) begin
        if (acc_pack[l*64 +: 64] !== acc_lut[l*64 +: 64]) begin
          errs = errs + 1;
          if (errs < 8) $display("PACK FAIL i=%0d lane=%0d a=%h w=%h pack=%h lut=%h",
                                 i, l, a, w[l*64 +: 64],
                                 acc_pack[l*64 +: 64], acc_lut[l*64 +: 64]);
        end
        if (acc_nopack[l*64 +: 64] !== acc_lut[l*64 +: 64]) begin
          errs = errs + 1;
          if (errs < 8) $display("NOPACK FAIL i=%0d lane=%0d", i, l);
        end
      end
    end
    if (errs == 0) $display("MBX_DSP_OK %0d vectors, pack and nopack both match the LUT array", N);
    else           $display("MBX_DSP_FAIL %0d mismatches", errs);
    $finish;
  end
endmodule
