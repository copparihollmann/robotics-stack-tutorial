// SPDX-License-Identifier: Apache-2.0
//
// What the fixed port delivers, in bytes per cycle, as a function of how many
// transactions are in flight -- simulated against a memory model whose ONLY free
// parameter is the round-trip latency, and whose latency values are the two this SoC
// has actually measured.
//
// WHY THIS EXISTS.  ROCC_STUDY.md 7.4 says its 5.6 B/cycle figure "is derived (64 B per
// Get, 16-cycle L2 latency, 8 beats), not measured, and it is labelled as such
// everywhere it appears".  This does not make it measured -- nothing short of a
// bitstream does that -- but it replaces an arithmetic identity with a simulation of
// the actual RTL against a model, so the engine's own issue behaviour, its free-source
// scan, its A-channel back-pressure and its beat accounting are in the loop instead of
// being assumed away.
//
// THE MODEL, stated so it can be disagreed with:
//
//   * One 64-byte Get is answered L cycles after it is accepted on A, then delivers
//     eight 64-bit beats.
//   * AT MOST ONE BEAT PER CYCLE crosses the D channel, for every transaction together.
//     That is the 64-bit link, and it is the hard ceiling at 8.0 B/cycle.
//   * At most one request per cycle is accepted on A.
//   * At most MSHR transactions may be outstanding at the memory, whatever the engine
//     offers.  The L2 in this SoC has SEVEN MSHRs (MEMORY_HIERARCHY.md 1, read out of
//     the L2's own configuration register on the board), and they are shared with the
//     harts -- so MSHR = 7 is an optimistic setting and MSHR = 4 is the conservative
//     one.  Both are reported.
//
//   L = 16   the L1+L2 lookup component of a miss, measured (MEMORY_HIERARCHY.md 3)
//   L = 41   the full load-to-use miss latency, measured at 41.23 cycles on hart 0
//
// WHAT IT CANNOT MODEL: whether the L2 will actually accept seven concurrent Gets from
// a RoCC client, what the DDR controller does under that pattern, and what routing does
// to the engine's Fmax in context.  Those need a bitstream.
//
// Build and run:
//     $V --binary -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --Mdir /tmp/vmbxbw \
//        --top-module tb_mbxd_bw tb_mbxd_bw.sv mbxd_dma.v  &&  /tmp/vmbxbw/Vtb_mbxd_bw

`timescale 1ns/1ps

module tb_mbxd_bw;
  localparam DEPTH = 8;
  localparam SLOTS = 16;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic        start;
  logic [39:0] src_base;
  logic [15:0] row_blocks, nrows, dst_word;
  logic [31:0] row_stride;
  logic        req_valid, req_ready;
  logic [39:0] req_addr;
  logic [3:0]  req_source;
  logic        rsp_valid;
  logic [3:0]  rsp_source;
  logic [63:0] rsp_data;
  logic        sp_we, busy;
  logic [15:0] sp_word;
  logic [63:0] sp_data;
  logic [7:0]  inflight;

  mbxd_dma #(.DEPTH(DEPTH), .LGBEATS(3)) dut (
    .clk(clk), .rst(rst), .start(start),
    .src_base(src_base), .row_blocks(row_blocks), .nrows(nrows),
    .row_stride(row_stride), .dst_word(dst_word),
    .req_valid(req_valid), .req_ready(req_ready),
    .req_addr(req_addr), .req_source(req_source),
    .rsp_valid(rsp_valid), .rsp_ready(), .rsp_source(rsp_source),
    .rsp_data(rsp_data),
    .sp_we(sp_we), .sp_word(sp_word), .sp_data(sp_data),
    .busy(busy), .inflight(inflight));

  int LAT = 41;
  int MSHR = 7;
  int MAXOUT = 8;         // how many source IDs the engine may use (DEPTH clamp)

  int  q_left [0:DEPTH-1];
  int  q_wait [0:DEPTH-1];
  bit  q_live [0:DEPTH-1];
  int  at_mem;            // transactions the memory has accepted and not finished
  int  beats, cycles;
  int  rot = 0;
  int  pick;

  // The engine may not use more than MAXOUT ids: model a shallower engine without
  // re-elaborating, by refusing A when too many are live.
  int live_n;
  always @* begin
    live_n = 0;
    for (int i = 0; i < DEPTH; i++) if (q_live[i]) live_n++;
  end
  assign req_ready = (live_n < MAXOUT) && (at_mem < MSHR);

  always @* begin
    pick = -1;
    for (int t = 0; t < DEPTH; t++) begin
      int i = (rot + t) % DEPTH;
      if (pick < 0 && q_live[i] && q_wait[i] == 0 && q_left[i] > 0) pick = i;
    end
  end

  always @(posedge clk) begin
    rot <= (rot + 1) % DEPTH;
    rsp_valid <= 1'b0;
    if (rst) begin
      for (int i = 0; i < DEPTH; i++) begin q_live[i] <= 0; q_left[i] <= 0; q_wait[i] <= 0; end
      at_mem <= 0;
    end else begin
      if (req_valid && req_ready) begin
        q_live[req_source] <= 1'b1;
        q_left[req_source] <= 8;
        q_wait[req_source] <= LAT;
        at_mem <= at_mem + 1 - ((pick >= 0 && q_left[pick] == 1) ? 1 : 0);
      end else if (pick >= 0 && q_left[pick] == 1) begin
        at_mem <= at_mem - 1;
      end
      for (int i = 0; i < DEPTH; i++)
        if (q_live[i] && q_wait[i] > 0) q_wait[i] <= q_wait[i] - 1;
      if (pick >= 0) begin
        rsp_valid  <= 1'b1;
        rsp_source <= pick[3:0];
        rsp_data   <= 64'hA5A5_0000_0000_0000 + pick;
        q_left[pick] <= q_left[pick] - 1;
        if (q_left[pick] == 1) q_live[pick] <= 1'b0;
      end
      if (busy) cycles <= cycles + 1;
      if (sp_we) beats <= beats + 1;
    end
  end

  task automatic run_case(int lat, int mshr, int maxout, int blocks);
    LAT = lat; MSHR = mshr; MAXOUT = maxout;
    beats = 0; cycles = 0;
    @(negedge clk);
    src_base = 40'h8000_0000;
    row_blocks = blocks[15:0];
    nrows = 16'd1;
    row_stride = 32'd0;
    dst_word = 16'd0;
    start = 1;
    @(negedge clk);
    start = 0;
    begin
      int guard = 0;
      while (busy && guard < 2000000) begin @(posedge clk); guard++; end
    end
    $display("  L=%0d  MSHR=%0d  outstanding<=%0d :  %0d beats in %0d cycles  ->  %0.2f B/cycle  (%0.1f MB/s at 34.4828 MHz)",
             lat, mshr, maxout, beats, cycles,
             real'(beats) * 8.0 / real'(cycles),
             real'(beats) * 8.0 / real'(cycles) * 34.4828);
  endtask

  initial begin
    start = 0; src_base = 0; row_blocks = 0; nrows = 0; row_stride = 0; dst_word = 0;
    beats = 0; cycles = 0;
    repeat (5) @(posedge clk);
    rst = 0;
    @(posedge clk);
    $display("MBXD_BW  64-byte Gets, one 64-bit beat per cycle on D, 512 blocks (32 KB)");
    $display(" -- L = 41 cycles: the MEASURED load-to-use miss latency on hart 0");
    for (int o = 1; o <= 8; o = o * 2) run_case(41, 7, o, 512);
    run_case(41, 4, 8, 512);
    $display(" -- L = 16 cycles: the MEASURED L1+L2 lookup component of a miss");
    for (int o = 1; o <= 8; o = o * 2) run_case(16, 7, o, 512);
    run_case(16, 4, 8, 512);
    $display("MBXD_BW_DONE");
    $finish;
  end
endmodule
