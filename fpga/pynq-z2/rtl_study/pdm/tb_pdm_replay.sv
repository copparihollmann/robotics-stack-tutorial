// -----------------------------------------------------------------------------
// Replay a captured PDM bitstream through the real RTL and write out the PCM.
//
// This is not a check, it is the demonstration: the bits in the input file were
// recorded from the PYNQ-Z1's OWN microphone (host/record_pdm.py, via the PYNQ base
// overlay), and what comes out of the other end is what the decimator in this repo
// would have produced from the same acoustic event.
//
//   +bits=<file>   one ASCII '0' or '1' per PDM sample, no separators
//   +pcm=<file>    output, one decimal 16-bit sample per line
//   +nbits=<N>     stop after N bits (0 = whole file)
//
// RATE NOTE.  PYNQ's audio_direct IP clocks the microphone at 100 MHz / 32 =
// 3.125 MHz; this decimator clocks it at 34.482759/14 = 2.463054 MHz.  Replaying the
// same bit sequence more slowly scales the whole spectrum by 2.463054/3.125 = 0.7882,
// so the PCM this writes must be interpreted at
//     15993.86 Hz * 3.125/2.463054 = 20291.6 Hz
// to recover the original frequencies.  That is a property of replaying a recording,
// not of the decimator.
`timescale 1ns/1ps

module tb_pdm_replay;
  localparam real    TCLK     = 29.0;
  localparam integer PDM_HALF = 7;

  logic clk = 0, rst = 1;
  always #(TCLK/2.0) clk = ~clk;

  logic [3:0]  reg_addr = 0;
  logic        reg_wr = 0, reg_rd = 0;
  logic [31:0] reg_wdata = 0;
  wire  [31:0] reg_rdata;
  wire         pdm_m_clk, irq;
  logic        pdm_m_data = 0;

  pdm_mic_core #(.PDM_HALF(PDM_HALF), .SETTLE(2048), .FIFO_ALOG2(10)) dut (
    .clk(clk), .rst(rst), .pdm_m_clk(pdm_m_clk), .pdm_m_data(pdm_m_data),
    .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
    .reg_rd(reg_rd), .reg_rdata(reg_rdata), .irq(irq));

  integer fin, fout, c;
  longint nbits = 0, limit = 0, nsamp = 0;
  string  bits_file, pcm_file;
  logic   eof = 0;

  always @(posedge pdm_m_clk) begin
    if (!eof) begin
      c = $fgetc(fin);
      if (c == -1 || (limit != 0 && nbits >= limit)) eof <= 1'b1;
      else if (c == "0" || c == "1") begin
        nbits = nbits + 1;
        #20 pdm_m_data = (c == "1");
      end
    end
  end

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

  logic [31:0] lv, dv;
  initial begin
    if (!$value$plusargs("bits=%s", bits_file)) $fatal(1, "need +bits=<file>");
    if (!$value$plusargs("pcm=%s",  pcm_file))  $fatal(1, "need +pcm=<file>");
    void'($value$plusargs("nbits=%d", limit));
    fin  = $fopen(bits_file, "r");
    if (fin == 0) $fatal(1, "cannot open %s", bits_file);
    fout = $fopen(pcm_file, "w");

    repeat (8) @(negedge clk); rst = 0; repeat (4) @(negedge clk);
    reg_write(4'h1, 32'h1);                       // enable, DC blocker on
    forever begin
      reg_read(4'h3, lv);
      if (lv != 0) begin
        reg_read(4'h4, dv);
        $fdisplay(fout, "%0d", $signed(dv));
        nsamp = nsamp + 1;
      end else if (eof) begin
        break;
      end
    end
    $fclose(fout); $fclose(fin);
    $display("PDM_REPLAY_DONE bits=%0d samples=%0d -> %s", nbits, nsamp, pcm_file);
    $finish;
  end

  initial begin
    #(64'd6_000_000_000);
    $fatal(1, "*** REPLAY TIMEOUT ***");
  end
endmodule
