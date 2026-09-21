// SPDX-License-Identifier: Apache-2.0
//
// mbxd_dma on a WIDE system bus -- the arithmetic BwProbe.scala wraps around it, checked.
//
// WHY THIS EXISTS.  Lever 4 (MEMORY_BANDWIDTH.md section 5) widens the TileLink system bus
// to 128 bits.  mbxd_dma.v is NOT modified for that -- other bitstreams read the same file
// and its claim is that it is the file that was simulated and synthesised.  Instead
// BwProbe.scala instantiates it at LGBEATS = log2(64 / beatBytes), a parameter it has
// always had, and runs its address walk in UNITS of beatBytes/8 bytes:
//
//     engine src_base   = src    >> log2(beatBytes/8)
//     engine row_stride = stride >> log2(beatBytes/8)
//     bus Get address   = engine req_addr << log2(beatBytes/8),   lgSize = 6 (64 bytes)
//
// and folds each wide D beat to 64 bits for the checksum outside the engine, because the
// engine never stores payload.  That is a claim about arithmetic, and a wrong shift would
// still produce a well-formed bytes-per-cycle figure on silicon -- reading the wrong
// blocks, or half of them.  The checksum would catch it there; this catches it here, for
// the cost of a Verilator run, before an hour of Vivado.
//
// WHAT IS CHECKED, against a responder that is as adversarial as tb_mbxd.sv's (random
// per-source latency, sources interleaved freely, beats of one source in order,
// back-pressure on A):
//   * every Get is 64-byte aligned and is EXACTLY the next block of the descriptor's walk
//     -- none skipped, none repeated, none past the end;
//   * the D channel delivers 64/beatBytes beats per Get, and the in-flight cap BwProbe
//     applies in Chisel is honoured and reached;
//   * the folded checksum of every wide beat equals the XOR of the 64-bit words of every
//     block the descriptor names -- i.e. each beat carried beatBytes of the right bytes;
//   * BwProbe's registers' identities: WORDS = DBEATS * beatBytes/8 and
//     REQS * 64 = DBEATS * beatBytes.
//
//   $V --binary -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --Mdir /tmp/vwide \
//      --top-module tb_mbxd_wide -GBB=16 tb_mbxd_wide.sv mbxd_dma.v && /tmp/vwide/Vtb_mbxd_wide
// Expect a line beginning MBXD_WIDE_TB_OK.  -GBB=32 checks the 256-bit arithmetic.

`timescale 1ns/1ps

module tb_mbxd_wide #(parameter int BB = 16);
  localparam int DEPTH   = 8;
  localparam int UNIT    = BB / 8;           // bytes per engine address unit
  localparam int LGUNIT  = $clog2(UNIT);
  localparam int NB      = 64 / BB;          // D beats per 64-byte Get
  localparam int LGBEATS = $clog2(NB);
  localparam int W       = BB * 8;           // bus data bits
  localparam int MEMW    = 1 << 18;          // 64-bit words of behavioural memory
  localparam logic [39:0] MBASE = 40'h00_8100_0000;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic [63:0] mem [0:MEMW-1];

  // ---------------- BwProbe's registers, as the guest writes them ------------------
  logic [39:0] src;
  logic [15:0] row_blocks, nrows;
  logic [31:0] row_stride;
  logic [7:0]  maxout;
  logic        go;

  // ---------------- the engine, unmodified, at BwProbe's parameters ----------------
  logic        req_valid, req_ready;
  logic [39:0] req_addr;
  logic [3:0]  req_source;
  logic        d_valid, d_last;
  logic [3:0]  d_source;
  logic [W-1:0] d_data;
  logic        busy;
  logic [7:0]  eng_inflight;
  logic        sp_we;
  logic [63:0] sp_data;
  logic [15:0] sp_word;

  mbxd_dma #(.DEPTH(DEPTH), .LGBEATS(LGBEATS)) dut (
    .clk(clk), .rst(rst), .start(go),
    .src_base(src >> LGUNIT), .row_blocks(row_blocks), .nrows(nrows),
    .row_stride(row_stride >> LGUNIT), .dst_word(16'd0),
    .req_valid(req_valid), .req_ready(a_ready && allow),
    .req_addr(req_addr), .req_source(req_source),
    .rsp_valid(d_valid), .rsp_ready(), .rsp_source(d_source), .rsp_data(d_data[63:0]),
    .sp_we(sp_we), .sp_word(sp_word), .sp_data(sp_data),
    .busy(busy), .inflight(eng_inflight));

  // ---------------- BwProbe's Chisel-side wrapper -----------------------------------
  logic        a_ready;
  logic [7:0]  inflight;
  wire         allow   = inflight < maxout;
  wire         a_valid = req_valid && allow;
  wire         a_fire  = a_valid && a_ready;
  wire  [39:0] bus_addr = req_addr << LGUNIT;

  function automatic logic [63:0] fold(input logic [W-1:0] x);
    logic [63:0] f = 64'd0;
    for (int i = 0; i < UNIT; i++) f ^= x[i*64 +: 64];
    return f;
  endfunction

  logic [63:0] reqs, dbeats, words, cksum;
  int          peak;
  always @(posedge clk) begin
    if (rst || go) begin
      inflight <= 0; reqs <= 0; dbeats <= 0; words <= 0; cksum <= 0; peak <= 0;
    end else begin
      if (a_fire && !(d_valid && d_last))      inflight <= inflight + 1;
      else if (!a_fire && (d_valid && d_last)) inflight <= inflight - 1;
      if (int'(inflight) > peak) peak <= int'(inflight);
      if (a_fire) reqs <= reqs + 1;
      if (sp_we) begin                       // sp_we == d fire of an AccessAckData
        dbeats <= dbeats + 1;
        words  <= words + UNIT;
        cksum  <= cksum ^ fold(d_data);
      end
    end
  end

  // ---------------- the adversarial wide responder ----------------------------------
  logic [39:0] q_addr [0:DEPTH-1];
  int          q_left [0:DEPTH-1];
  int          q_wait [0:DEPTH-1];
  logic        q_live [0:DEPTH-1];
  int          rot = 0, pick, errs = 0;

  always @* begin
    pick = -1;
    for (int t = 0; t < DEPTH; t++) begin
      int i = (rot + t) % DEPTH;
      if (pick < 0 && q_live[i] && q_wait[i] == 0 && q_left[i] > 0) pick = i;
    end
  end

  // the walk the descriptor names, and where in it the next Get must be
  logic [39:0] expect_q [$];
  int          exp_idx;

  always @(posedge clk) begin
    rot     <= (rot + 3) % DEPTH;
    a_ready <= ($urandom % 4) != 0;
    d_valid <= 1'b0;
    if (rst) begin
      for (int i = 0; i < DEPTH; i++) begin
        q_live[i] <= 0; q_left[i] <= 0; q_wait[i] <= 0; q_addr[i] <= 0;
      end
    end else begin
      if (a_fire) begin
        if (bus_addr[5:0] != 6'd0) begin
          $display("TB FAIL: Get at %h is not 64-byte aligned", bus_addr); errs++;
        end
        if (exp_idx >= expect_q.size()) begin
          $display("TB FAIL: Get %0d at %h is past the end of the walk", exp_idx, bus_addr);
          errs++;
        end else if (bus_addr != expect_q[exp_idx]) begin
          $display("TB FAIL: Get %0d at %h, the walk says %h", exp_idx, bus_addr,
                   expect_q[exp_idx]);
          errs++;
        end
        exp_idx <= exp_idx + 1;
        if (q_live[req_source]) begin
          $display("TB FAIL: source %0d reissued while live", req_source); errs++;
        end
        q_live[req_source] <= 1'b1;
        q_addr[req_source] <= bus_addr;
        q_left[req_source] <= NB;
        q_wait[req_source] <= ($urandom % 40) + 1;
      end
      for (int i = 0; i < DEPTH; i++) begin
        if (q_live[i] && q_wait[i] > 0) q_wait[i] <= q_wait[i] - 1;
      end
      if (pick >= 0) begin
        automatic int w0 = int'((q_addr[pick] - MBASE) >> 3) + (NB - q_left[pick]) * UNIT;
        for (int u = 0; u < UNIT; u++) d_data[u*64 +: 64] <= mem[(w0 + u) % MEMW];
        d_valid  <= 1'b1;
        d_last   <= (q_left[pick] == 1);
        d_source <= pick[3:0];
        q_left[pick] <= q_left[pick] - 1;
        if (q_left[pick] == 1) q_live[pick] <= 1'b0;
      end
    end
  end

  // ---------------- stimulus ----------------------------------------------------------
  int ndesc = 0, rb, nr, sb, reps_hits = 0;
  logic [63:0] sw;
  logic [39:0] base;
  static int outs[6] = '{1, 2, 3, 4, 6, 8};

  task automatic run_desc(input logic [39:0] b, input int rbk, input int nrw,
                          input int strideb, input int mo);
    int guard;
    expect_q.delete();
    sw = 64'd0;
    for (int r = 0; r < nrw; r++) begin
      for (int k = 0; k < rbk; k++) begin
        automatic logic [39:0] blk = b + r * strideb + k * 64;
        expect_q.push_back(blk);
        for (int wd = 0; wd < 8; wd++) sw ^= mem[(int'((blk - MBASE) >> 3) + wd) % MEMW];
      end
    end
    @(negedge clk);
    src = b; row_blocks = rbk[15:0]; nrows = nrw[15:0]; row_stride = strideb[31:0];
    maxout = mo[7:0];
    exp_idx = 0;
    go = 1;
    @(negedge clk);
    go = 0;
    @(posedge clk);
    guard = 0;
    while ((busy || inflight != 0) && guard < 400000) begin
      @(posedge clk); guard++;
    end
    repeat (3) @(posedge clk);
    ndesc++;
    if (guard >= 400000) begin
      $display("TB FAIL: descriptor %0d never completed", ndesc); errs++;
    end
    if (exp_idx != expect_q.size()) begin
      $display("TB FAIL: desc %0d issued %0d Gets, the walk has %0d", ndesc, exp_idx,
               expect_q.size()); errs++;
    end
    if (reqs != expect_q.size()) begin
      $display("TB FAIL: desc %0d REQS=%0d want %0d", ndesc, reqs, expect_q.size()); errs++;
    end
    if (dbeats != reqs * NB) begin
      $display("TB FAIL: desc %0d DBEATS=%0d, REQS*%0d=%0d", ndesc, dbeats, NB, reqs * NB);
      errs++;
    end
    if (words * 8 != reqs * 64 || words != dbeats * UNIT) begin
      $display("TB FAIL: desc %0d WORDS=%0d DBEATS=%0d REQS=%0d", ndesc, words, dbeats, reqs);
      errs++;
    end
    if (cksum !== sw) begin
      $display("TB FAIL: desc %0d checksum %h, the walk's words XOR to %h", ndesc, cksum, sw);
      errs++;
    end
    if (peak > mo) begin
      $display("TB FAIL: desc %0d peak in flight %0d over the cap %0d", ndesc, peak, mo); errs++;
    end
    if (expect_q.size() >= 4 * mo && peak != mo) begin
      $display("TB FAIL: desc %0d peak in flight %0d never reached the cap %0d", ndesc, peak, mo);
      errs++;
    end
  endtask

  initial begin
    for (int i = 0; i < MEMW; i++) mem[i] = {$urandom, $urandom};
    src = 0; row_blocks = 0; nrows = 0; row_stride = 0; maxout = 8; go = 0;
    a_ready = 1; d_valid = 0; d_last = 0; d_source = 0; d_data = '0; exp_idx = 0;
    repeat (5) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // The lab's own three shapes, at every outstanding count it sweeps:
    //   a region re-read an ODD number of times (stride 0), as the L2 points are;
    //   a long contiguous stream in rows whose stride is the row length, as DRAM is;
    //   one block per 4 KiB page, as lever 3's DRAM_ALT shape is.
    foreach (outs[oi]) begin
      run_desc(MBASE,             16, 5,  0,           outs[oi]);
      run_desc(MBASE + 64 * 3,    40, 6,  40 * 64,     outs[oi]);
      run_desc(MBASE + 64 * 2,     1, 48, 4096,        outs[oi]);
    end
    // ... and random 2-D descriptors, rows not overlapping.
    for (int t = 0; t < 30; t++) begin
      rb   = ($urandom % 6) + 1;
      nr   = ($urandom % 7) + 1;
      sb   = (rb + ($urandom % 3)) * 64;
      base = MBASE + (($urandom % 2000) + 1) * 64;
      run_desc(base, rb, nr, sb, outs[$urandom % 6]);
      if (errs > 20) break;
    end

    if (errs == 0) begin
      $display("MBXD_WIDE_TB_OK  beat=%0d bytes, %0d beats per 64-byte Get, engine LGBEATS=%0d: %0d descriptors, every Get the next block of the walk, every beat %0d bytes of the right data",
               BB, NB, LGBEATS, ndesc, BB);
    end else begin
      $display("MBXD_WIDE_TB_FAIL errs=%0d", errs);
    end
    $finish;
  end
endmodule
