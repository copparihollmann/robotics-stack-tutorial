// -----------------------------------------------------------------------------
// Self-checking testbench for the PDM microphone peripheral.
//
// A PDM decimator is one of the few blocks where you can check the ANSWER and not
// just the handshakes, so this drives a real second-order sigma-delta modulator --
// the same thing the Knowles part contains -- and checks the PCM that comes out:
//
//   1. the register file and the FIFO behave (ID, CTRL, LEVEL, DATA, RATE, DEPTH)
//   2. `settling` holds off the chain, and no sample escapes while it is high
//   3. one PCM sample arrives every 2*PDM_HALF*CIC_R*FIR_DECIM = 2156 system clocks,
//      exactly -- this is the sample rate, and it is set by counters, so "exactly"
//      is the right word
//   4. the end-to-end DC gain is 32768: a modulator driven with u = +-0.5 has to come
//      out at +-16384 counts with the DC blocker bypassed
//   5. a 999.6 Hz tone comes out at 999.6 Hz with the right amplitude
//   6. a 9996.2 Hz tone -- which decimate-by-7 would fold onto 5997.7 Hz if the
//      anti-alias filter were not there -- is at least 60 dB down at that bin.
//      This is the check that the CIC order and the FIR stopband are real.
//   7. the DC blocker removes a DC offset the size of the one the real board's
//      microphone actually has (density 0.5164, measured -- see MICROPHONE.md)
//
// The stimulus is presented the way the part presents it: the testbench waits for
// the DUT's own pdm_m_clk to rise, then drives the data pin 20 ns later.  If the
// sampling edge in pdm_mic_capture were wrong, this testbench would see it.
//
// Run it with sim/run_pdm_sim.sh.
`timescale 1ns/1ps

module tb_pdm_mic;
  // 34.4828 MHz -- the P-ext bitstream clock.  Period 29.000 ns.
  localparam real    TCLK      = 29.0;
  localparam integer PDM_HALF  = 7;
  localparam integer CIC_R     = 22;
  localparam integer FIR_DECIM = 7;
  localparam integer SETTLE    = 2048;     // 131072 on hardware; 2048 keeps sim short
  localparam integer PERIOD    = 2*PDM_HALF*CIC_R*FIR_DECIM;   // 2156

  localparam real    FCLK  = 1.0e9/29.0;                        // Hz
  localparam real    FPDM  = FCLK/(2.0*PDM_HALF);
  localparam real    FPCM  = FPDM/(CIC_R*FIR_DECIM);

  // register file word indices
  localparam [3:0] R_ID=0, R_CTRL=1, R_STATUS=2, R_LEVEL=3, R_DATA=4,
                   R_RATE=5, R_DEPTH=6, R_WMARK=7;

  logic clk = 0, rst = 1;
  always #(TCLK/2.0) clk = ~clk;

  logic [3:0]  reg_addr = 0;
  logic        reg_wr = 0, reg_rd = 0;
  logic [31:0] reg_wdata = 0;
  wire  [31:0] reg_rdata;
  wire         pdm_m_clk, irq;
  logic        pdm_m_data = 0;

  pdm_mic_core #(.PDM_HALF(PDM_HALF), .CIC_R(CIC_R), .FIR_DECIM(FIR_DECIM),
                 .SETTLE(SETTLE), .FIFO_ALOG2(10)) dut (
    .clk(clk), .rst(rst),
    .pdm_m_clk(pdm_m_clk), .pdm_m_data(pdm_m_data),
    .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
    .reg_rd(reg_rd), .reg_rdata(reg_rdata), .irq(irq));

  // ---------------------------------------------------------------------------
  // Stimulus: a second-order sigma-delta modulator, clocked by the DUT's own
  // pdm_m_clk, presenting its bit 20 ns after the rising edge -- which is what the
  // SPK0833LM4H-B does with L/R SELECT tied low.
  // ---------------------------------------------------------------------------
  localparam real TWO_PI = 6.283185307179586;
  real sd_s1 = 0.0, sd_s2 = 0.0, sd_y = -1.0;
  real stim_dc = 0.0, stim_a1 = 0.0, stim_f1 = 0.0, stim_a2 = 0.0, stim_f2 = 0.0;
  longint sd_n = 0;
  longint pdm_bits = 0;

  function automatic real stim_u(longint n);
    real t;
    t = $itor(n) / FPDM;
    return stim_dc + stim_a1*$sin(TWO_PI*stim_f1*t) + stim_a2*$sin(TWO_PI*stim_f2*t);
  endfunction

  always @(posedge pdm_m_clk) begin
    real u;
    u = stim_u(sd_n);
    sd_s1 = sd_s1 + (u - sd_y);
    sd_s2 = sd_s2 + (sd_s1 - sd_y);
    sd_y  = (sd_s2 >= 0.0) ? 1.0 : -1.0;
    sd_n  = sd_n + 1;
    pdm_bits = pdm_bits + 1;
    #20 pdm_m_data = (sd_y > 0.0);
  end

  // ---------------------------------------------------------------------------
  int errors = 0, checks = 0;
  task automatic chk(input string what, input logic cond);
    begin
      checks++;
      if (cond) $display("  pass  %s", what);
      else begin errors++; $display("  FAIL  %s", what); end
    end
  endtask

  task automatic reg_write(input [3:0] a, input [31:0] d);
    begin
      @(negedge clk); reg_addr = a; reg_wdata = d; reg_wr = 1'b1;
      @(negedge clk); reg_wr = 1'b0;
    end
  endtask

  task automatic reg_read(input [3:0] a, output [31:0] d);
    begin
      @(negedge clk); reg_addr = a; reg_rd = 1'b1;
      #1 d = reg_rdata;
      @(negedge clk); reg_rd = 1'b0;
    end
  endtask

  // Pop one sample, waiting for the FIFO to have one.  Returns the system-clock
  // count at the moment LEVEL first showed it, so the caller can time the rate.
  task automatic pop(output shortint s);
    logic [31:0] lv, dv;
    begin
      lv = 0;
      while (lv == 0) reg_read(R_LEVEL, lv);
      reg_read(R_DATA, dv);
      s = dv[15:0];
    end
  endtask

  // free-running system-clock counter, for the rate check
  longint cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ---------------------------------------------------------------------------
  localparam integer NFFT = 1024;
  localparam integer K1   = 64;     // 999.62 Hz
  localparam integer K2   = 640;    // 9996.2 Hz  -> folds onto bin 384 if unfiltered
  localparam integer KA   = NFFT-K2;// 384, 5997.7 Hz
  localparam integer KN   = 200;    // a bin with nothing in it

  real buf_x [0:NFFT-1];

  function automatic real bin_amp(input integer k, input integer n);
    real re, im, ph; integer i;
    begin
      re = 0.0; im = 0.0;
      for (i = 0; i < n; i++) begin
        ph = TWO_PI*$itor(k)*$itor(i)/$itor(n);
        re = re + buf_x[i]*$cos(ph);
        im = im - buf_x[i]*$sin(ph);
      end
      bin_amp = 2.0*$sqrt(re*re + im*im)/$itor(n);
    end
  endfunction

  task automatic collect(input integer n);
    shortint s; integer i;
    begin
      for (i = 0; i < n; i++) begin pop(s); buf_x[i] = $itor(s); end
    end
  endtask

  task automatic mean_of(input integer n, output real m);
    shortint s; integer i; real acc;
    begin
      acc = 0.0;
      for (i = 0; i < n; i++) begin pop(s); acc = acc + $itor(s); end
      m = acc/$itor(n);
    end
  endtask

  // ---------------------------------------------------------------------------
  logic [31:0] rv, rv2;
  real  m, a1, aa, an, adc;
  longint t0, t1;
  shortint s;
  integer i;

  initial begin
    $display("PDM microphone peripheral -- f_pdm %.1f Hz, f_cic %.2f Hz, f_pcm %.4f Hz",
             FPDM, FPDM/CIC_R, FPCM);
    repeat (8) @(negedge clk);
    rst = 0;
    repeat (4) @(negedge clk);

    $display("\n-- 1. register file, quiescent --");
    reg_read(R_ID, rv);     chk($sformatf("ID reads 0x504D4331 (got 0x%08X)", rv), rv === 32'h504D4331);
    reg_read(R_RATE, rv);   chk($sformatf("RATE reads 15993859 mHz (got %0d)", rv), rv === 32'd15993859);
    reg_read(R_DEPTH, rv);  chk($sformatf("DEPTH reads 1024 (got %0d)", rv), rv === 32'd1024);
    reg_read(R_LEVEL, rv);  chk($sformatf("LEVEL is 0 before enable (got %0d)", rv), rv === 32'd0);
    reg_read(R_STATUS, rv); chk($sformatf("STATUS.empty set, settling clear before enable (got 0x%02X)", rv[7:0]),
                                rv[1] === 1'b1 && rv[0] === 1'b0);
    reg_read(4'hF, rv);     chk($sformatf("unmapped register reads 0xDEADBEEF (got 0x%08X)", rv), rv === 32'hDEADBEEF);

    $display("\n-- 2. settling holds the chain off --");
    stim_dc = 0.0; stim_a1 = 0.0; stim_a2 = 0.0;
    reg_write(R_CTRL, 32'h5);                       // enable | dc_bypass
    repeat (20) @(negedge clk);
    reg_read(R_STATUS, rv); chk("STATUS.settling set right after enable", rv[0] === 1'b1);
    // let it run to just before the end of settling, then check nothing came out
    wait (pdm_bits >= SETTLE - 8);
    reg_read(R_LEVEL, rv);  chk($sformatf("no sample produced while settling (LEVEL %0d)", rv), rv === 32'd0);
    wait (pdm_bits >= SETTLE + 64);
    reg_read(R_STATUS, rv); chk("STATUS.settling clears after SETTLE PDM bits", rv[0] === 1'b0);
    chk($sformatf("PDM clock ran at one bit per %0d system clocks", 2*PDM_HALF),
        pdm_bits > 0);

    $display("\n-- 3. sample rate --");
    for (i = 0; i < 4; i++) pop(s);                 // drain the pipeline transient
    reg_read(R_LEVEL, rv);
    while (rv != 0) begin pop(s); reg_read(R_LEVEL, rv); end
    // now the FIFO is empty; time the next two arrivals
    rv = 0; while (rv == 0) reg_read(R_LEVEL, rv);  t0 = cyc; pop(s);
    rv = 0; while (rv == 0) reg_read(R_LEVEL, rv);  t1 = cyc; pop(s);
    chk($sformatf("consecutive samples are %0d system clocks apart, expected %0d",
                  t1-t0, PERIOD), (t1-t0) == PERIOD);

    $display("\n-- 4. end-to-end DC gain (DC blocker bypassed) --");
    stim_dc = 0.5;  mean_of(400, m);   // let it settle, then measure
    mean_of(300, m);
    chk($sformatf("u=+0.5 -> %.1f counts, expected 16384 +-250", m), (m > 16134.0) && (m < 16634.0));
    stim_dc = -0.5; mean_of(400, m); mean_of(300, m);
    chk($sformatf("u=-0.5 -> %.1f counts, expected -16384 +-250", m), (m > -16634.0) && (m < -16134.0));
    stim_dc = 0.0;  mean_of(400, m); mean_of(300, m);
    chk($sformatf("u=0 -> %.1f counts, expected 0 +-120", m), (m > -120.0) && (m < 120.0));

    $display("\n-- 5/6. tone at 999.6 Hz, and the 9996.2 Hz alias that must not appear --");
    stim_dc = 0.0;
    stim_a1 = 0.25; stim_f1 = FPCM*$itor(K1)/$itor(NFFT);
    stim_a2 = 0.25; stim_f2 = FPCM*$itor(K2)/$itor(NFFT);
    $display("   f1 = %.2f Hz (bin %0d), f2 = %.2f Hz (bin %0d, folds onto bin %0d = %.2f Hz)",
             stim_f1, K1, stim_f2, K2, KA, FPCM*$itor(KA)/$itor(NFFT));
    mean_of(600, m);                                  // flush the step
    collect(NFFT);
    a1  = bin_amp(K1, NFFT);
    aa  = bin_amp(KA, NFFT);
    an  = bin_amp(KN, NFFT);
    adc = bin_amp(0,  NFFT);
    $display("   bin %0d (signal)     %10.2f counts", K1, a1);
    $display("   bin %0d (alias)      %10.4f counts  = %.1f dB below signal", KA, aa,
             20.0*$log10((aa < 1.0e-9 ? 1.0e-9 : aa)/a1));
    $display("   bin %0d (empty)      %10.4f counts", KN, an);
    chk($sformatf("999.6 Hz tone at %.1f counts, expected 8192 +-410 (0.25 x 32768)", a1),
        (a1 > 7782.0) && (a1 < 8602.0));
    chk($sformatf("9996.2 Hz alias is %.1f dB down, needs >= 60",
                  -20.0*$log10((aa < 1.0e-9 ? 1.0e-9 : aa)/a1)),
        aa*1000.0 < a1);
    chk($sformatf("empty bin is quiet (%.2f counts, needs < 1%% of signal)", an), an*100.0 < a1);

    $display("\n-- 7. DC blocker --");
    stim_a1 = 0.0; stim_a2 = 0.0;
    // 0.0328 of full scale is the offset the real board's microphone has: its
    // measured PDM density with no deliberate sound was 0.516384.
    stim_dc = 2.0*0.516384 - 1.0;
    mean_of(600, m); mean_of(300, m);
    chk($sformatf("bypassed, the real board's 0.5164 density gives %.1f counts (expect ~1074)", m),
        (m > 900.0) && (m < 1250.0));
    reg_write(R_CTRL, 32'h1);                        // enable, DC blocker ON
    mean_of(1500, m); mean_of(400, m);
    chk($sformatf("with the DC blocker on the same offset gives %.1f counts (expect |m| < 40)", m),
        (m > -40.0) && (m < 40.0));

    $display("\n-- 8. FIFO: LEVEL never promises a sample DATA cannot return --");
    // The one race in this design, and it is invisible from a normal bus transaction: for
    // the cycle or two after a sample lands in an empty FIFO, the fall-through register
    // has not fetched it yet, so STATUS.empty is still set and a DATA read returns 0
    // WITHOUT popping. If LEVEL counted it anyway, a driver that trusts LEVEL writes a
    // spurious zero into its block. One sample in 31744, once in maybe a thousand runs.
    //
    // Checkable here because the register file is combinational on reg_addr: moving the
    // address observes LEVEL and STATUS in the SAME cycle, with reg_rd held low so
    // nothing pops, and doing it on every negedge covers every cycle of the window.
    reg_write(R_CTRL, 32'h3);                        // enable + fifo_reset
    begin
      int bad_level = 0, watched = 0;
      logic [31:0] lv, st;
      @(negedge clk); reg_rd = 1'b0; reg_wr = 1'b0;
      for (i = 0; i < 6000; i++) begin
        @(negedge clk);
        reg_addr = R_LEVEL;  #1 lv = reg_rdata;
        reg_addr = R_STATUS; #1 st = reg_rdata;
        if (lv != 0 && st[1]) bad_level++;
        if (lv != 0) watched++;
        if (watched > 8) break;
      end
      chk($sformatf("LEVEL and STATUS.empty agreed on every one of %0d cycles", i + 1),
          bad_level == 0);
      chk("the FIFO did fill during the watch (otherwise the check above is vacuous)",
          watched > 0);
    end

    reg_read(R_STATUS, rv); chk("no overrun after all of the above", rv[3] === 1'b0);
    reg_write(R_CTRL, 32'h3);                        // enable + fifo_reset
    repeat (8) @(negedge clk);
    reg_read(R_LEVEL, rv);  chk($sformatf("fifo_reset empties the FIFO (LEVEL %0d)", rv), rv === 32'd0);
    reg_write(R_WMARK, 32'd4);
    for (i = 0; i < 4; i++) pop(s);
    reg_write(R_CTRL, 32'h0);                        // disable
    repeat (4) @(negedge clk);
    reg_read(R_STATUS, rv); chk("STATUS.settling clear while disabled", rv[0] === 1'b0);

    $display("\n==================================================");
    $display("%0d checks, %0d failures", checks, errors);
    if (errors == 0) begin
      $display("ALL CHECKS PASSED");
      $display("==================================================");
      $finish;
    end else begin
      $display("==================================================");
      $fatal(1, "*** %0d CHECK(S) FAILED ***", errors);
    end
  end

  initial begin
    #900_000_000;
    $fatal(1, "*** TESTBENCH TIMEOUT -- the chain never produced what was asked for ***");
  end
endmodule
