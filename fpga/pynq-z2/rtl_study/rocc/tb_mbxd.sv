// SPDX-License-Identifier: Apache-2.0
//
// Self-checking testbench for the decoupled fill engine and the result drain.
//
// WHY IT EXISTS.  Revision 2's mbx_dma has no testbench at all, and it has a real bug:
// `head`/`tail` are declared [TW-1:0] with TW hard-coded to 3 while `ent_v` and `robuf`
// are DEPTH deep, so at the DEPTH = 4 that mbx_tiled instantiates the pointers index
// past the end of both arrays.  It synthesises and it produced the dma_d4 row of
// ooc_out/summary.tsv.  The rule this repository already applies to arithmetic blocks --
// no block's area is reported until it is checked (ROCC_STUDY.md 3.1) -- was not applied
// to the control ones, and this is the correction.
//
// THE MEMORY MODEL IS ADVERSARIAL ON PURPOSE.  It returns beats with random per-source
// latency and interleaves sources as freely as TileLink permits: beats of ONE source in
// order, beats of DIFFERENT sources in any order at all.  An engine that quietly assumed
// in-order completion -- which is what a reorder buffer retired by a head pointer is --
// fails here and passes a simple model.
//
// Build and run (the command is in ROCC_STUDY.md's appendix in full):
//     $V --binary -Wno-fatal --Mdir /tmp/vmbxd --top-module tb_mbxd \
//        tb_mbxd.sv mbxd_dma.v mbxd_st.v   &&  /tmp/vmbxd/Vtb_mbxd
// Expect a line beginning MBXD_TB_OK.

`timescale 1ns/1ps

module tb_mbxd;
  localparam DEPTH = 8;
  localparam MEMW  = 65536;      // 64-bit words of behavioural memory
  localparam SPW   = 16384;      // scratchpad words modelled

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ---------------- behavioural memory ------------------------------------------
  logic [63:0] mem  [0:MEMW-1];
  logic [63:0] spad [0:SPW-1];
  logic        spad_w [0:SPW-1];

  // ---------------- DUT: the fill engine ----------------------------------------
  logic        start;
  logic [39:0] src_base;
  logic [15:0] row_blocks, nrows, dst_word;
  logic [31:0] row_stride;

  logic        req_valid;
  logic        req_ready = 1'b1;
  logic [39:0] req_addr;
  logic [3:0]  req_source;
  logic        rsp_valid;
  logic [3:0]  rsp_source;
  logic [63:0] rsp_data;
  // back-pressure on A, because the real channel has it

  logic        sp_we;
  logic [15:0] sp_word;
  logic [63:0] sp_data;
  logic        busy;
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

  // ---------------- the adversarial responder -----------------------------------
  // One slot per source ID.  A slot holds its block's word address, how many beats it
  // still owes, and a countdown before it may answer.  Every cycle at most one slot
  // answers, chosen at random among those that are ready -- so sources interleave.
  logic [31:0] q_word [0:DEPTH-1];
  int          q_left [0:DEPTH-1];
  int          q_wait [0:DEPTH-1];
  logic        q_live [0:DEPTH-1];

  int          errs = 0, blocks_done = 0, max_inflight = 0;
  int          concurrency_sum = 0, concurrency_n = 0;

  // One always block, nonblocking throughout, so there is no race between accepting a
  // request and answering one.  `rot` makes the scan order rotate every cycle, which
  // together with the random per-source latency scrambles completion order thoroughly
  // while staying deterministic run to run.
  int          rot = 0;
  int          pick;
  always @* begin
    pick = -1;
    for (int t = 0; t < DEPTH; t++) begin
      int i = (rot + t) % DEPTH;
      if (pick < 0 && q_live[i] && q_wait[i] == 0 && q_left[i] > 0) pick = i;
    end
  end

  always @(posedge clk) begin
    rot <= (rot + 3) % DEPTH;
    req_ready <= ($urandom % 4) != 0;
    rsp_valid <= 1'b0;
    if (rst) begin
      for (int i = 0; i < DEPTH; i++) begin
        q_live[i] <= 0; q_left[i] <= 0; q_wait[i] <= 0; q_word[i] <= 0;
      end
    end else begin
      if (req_valid && req_ready) begin
        if (q_live[req_source]) begin
          $display("TB FAIL: source %0d reissued while live", req_source);
          errs++;
        end
        q_live[req_source] <= 1'b1;
        q_word[req_source] <= req_addr[39:3];
        q_left[req_source] <= 8;
        q_wait[req_source] <= ($urandom % 40) + 1;
      end
      for (int i = 0; i < DEPTH; i++) begin
        if (q_live[i] && q_wait[i] > 0) q_wait[i] <= q_wait[i] - 1;
      end
      if (pick >= 0) begin
        rsp_valid  <= 1'b1;
        rsp_source <= pick[3:0];
        rsp_data   <= mem[(q_word[pick] + (8 - q_left[pick])) % MEMW];
        q_left[pick] <= q_left[pick] - 1;
        if (q_left[pick] == 1) begin
          q_live[pick] <= 1'b0;
          blocks_done  <= blocks_done + 1;
        end
      end
    end
  end

  // record the scratchpad writes
  always @(posedge clk) begin
    if (!rst && sp_we) begin
      spad[sp_word % SPW]   <= sp_data;
      spad_w[sp_word % SPW] <= 1'b1;
    end
    if (!rst && busy) begin
      concurrency_sum += int'(inflight);
      concurrency_n++;
      if (int'(inflight) > max_inflight) max_inflight = int'(inflight);
    end
  end


  // ---------------- the drain ----------------------------------------------------
  logic        s_start, s_iv, s_ir, s_rv, s_first, s_last, s_busy;
  wire         s_rr;
  logic [39:0] s_base, s_addr;
  logic [15:0] s_nblocks;
  logic [3:0]  s_src;
  logic [63:0] s_idata, s_data;
  logic        s_ack;

  mbxd_st #(.DEPTH(2), .LGBEATS(3), .LGFIFO(5)) dst_ (
    .clk(clk), .rst(rst), .start(s_start),
    .dst_base(s_base), .nblocks(s_nblocks),
    .in_valid(s_iv), .in_ready(s_ir), .in_data(s_idata),
    .req_valid(s_rv), .req_ready(s_rr), .req_addr(s_addr), .req_source(s_src),
    .req_data(s_data), .req_first(s_first), .req_last(s_last),
    .rsp_valid(s_ack), .busy(s_busy));

  logic [63:0] omem [0:1023];
  int          obeat = 0, oerrs = 0, oblocks = 0;
  logic [39:0] oaddr_expect;
  int          in_burst = 0;
  logic [3:0]  burst_src;

  logic s_rr_r = 1'b1;
  assign s_rr = s_rr_r;
  always @(posedge clk) s_rr_r <= ($urandom % 3) != 0;

  always @(posedge clk) begin
    s_ack <= 1'b0;
    if (!rst && s_rv && s_rr) begin
      if (in_burst == 0) begin
        if (!s_first) begin
          $display("TB FAIL: store burst did not start with first"); oerrs++;
        end
        burst_src <= s_src;
        oaddr_expect <= s_addr;
      end else begin
        if (s_src !== burst_src) begin
          $display("TB FAIL: store source changed mid-burst"); oerrs++;
        end
        if (s_addr !== oaddr_expect) begin
          $display("TB FAIL: store address moved mid-burst"); oerrs++;
        end
      end
      omem[obeat % 1024] <= s_data;
      obeat <= obeat + 1;
      if (s_last) begin
        if (in_burst != 7) begin
          $display("TB FAIL: store burst was %0d beats, want 8", in_burst + 1);
          oerrs++;
        end
        in_burst <= 0;
        oblocks  <= oblocks + 1;
        s_ack    <= 1'b1;
      end else begin
        in_burst <= in_burst + 1;
      end
    end
  end

  // ---------------- stimulus ------------------------------------------------------
  int          exp_words;
  logic [39:0] base;
  int          rb, nr, stride_blocks;
  int          w, srcw;

  initial begin
    for (int i = 0; i < MEMW; i++) mem[i] = {$urandom, $urandom};
    for (int i = 0; i < SPW; i++)  begin spad[i] = 64'hx; spad_w[i] = 0; end
    start = 0; src_base = 0; row_blocks = 0; nrows = 0; row_stride = 0; dst_word = 0;
    s_start = 0; s_iv = 0; s_idata = 0; s_base = 0; s_nblocks = 0; s_ack = 0;
    repeat (5) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // ---- 12 random 2-D descriptors ------------------------------------------------
    for (int t = 0; t < 12; t++) begin
      rb            = ($urandom % 6) + 1;          // blocks per row
      nr            = ($urandom % 7) + 1;          // rows
      stride_blocks = rb + ($urandom % 3);         // >= rb, so rows do not overlap
      base          = (($urandom % 2000) + 1) * 64;
      for (int i = 0; i < SPW; i++) spad_w[i] = 0;

      @(negedge clk);
      src_base   = base;
      row_blocks = rb[15:0];
      nrows      = nr[15:0];
      row_stride = stride_blocks * 64;
      dst_word   = 16'd0;
      start      = 1;
      @(negedge clk);
      start = 0;

      // run to completion
      begin
        int guard = 0;
        while (busy && guard < 200000) begin
          @(posedge clk);
          guard++;
        end
        if (guard >= 200000) begin
          $display("TB FAIL: descriptor %0d never completed", t);
          errs++;
        end
      end
      repeat (4) @(posedge clk);

      // ---- check the scratchpad against memory ------------------------------------
      exp_words = rb * nr * 8;
      for (int r = 0; r < nr; r++) begin
        for (int bkt = 0; bkt < rb * 8; bkt++) begin
          w    = r * rb * 8 + bkt;
          srcw = int'(base / 8) + r * (stride_blocks * 8) + bkt;
          if (!spad_w[w]) begin
            $display("TB FAIL: desc %0d word %0d never written", t, w);
            errs++;
          end else if (spad[w] !== mem[srcw % MEMW]) begin
            $display("TB FAIL: desc %0d word %0d got %h want %h",
                     t, w, spad[w], mem[srcw % MEMW]);
            errs++;
          end
        end
      end
      // nothing beyond the descriptor may have been written
      for (int i = exp_words; i < exp_words + 64; i++) begin
        if (spad_w[i]) begin
          $display("TB FAIL: desc %0d wrote word %0d past the tile", t, i);
          errs++;
        end
      end
      if (errs > 20) break;
    end

    // ---- the drain: 3 blocks of 8 words -------------------------------------------
    @(negedge clk);
    s_base = 40'h1000;
    s_nblocks = 16'd3;
    s_start = 1;
    @(negedge clk);
    s_start = 0;
    fork
      begin : feeder
        for (int i = 0; i < 24; i++) begin
          @(negedge clk);
          s_idata = {32'hCAFE0000 + i, 32'h0000BEEF + i};
          s_iv = 1;
          @(posedge clk);
          while (!s_ir) @(posedge clk);
          @(negedge clk);
          s_iv = 0;
          begin
            int gap = $urandom % 5;
            if (($urandom % 3) == 0) begin
              for (int gg = 0; gg < gap; gg++) @(negedge clk);
            end
          end
        end
        s_iv = 0;
      end
    join_none
    begin
      int guard = 0;
      while ((oblocks < 3) && guard < 20000) begin
        @(posedge clk);
        guard++;
      end
      if (oblocks < 3) begin
        $display("TB FAIL: drain emitted %0d of 3 blocks", oblocks);
        oerrs++;
      end
    end
    for (int i = 0; i < 24; i++) begin
      if (omem[i] !== {32'hCAFE0000 + i, 32'h0000BEEF + i}) begin
        $display("TB FAIL: drain word %0d got %h", i, omem[i]);
        oerrs++;
      end
    end

    $display("MBXD peak inflight = %0d of %0d, mean %0.2f while busy",
             max_inflight, DEPTH,
             (concurrency_n > 0) ? real'(concurrency_sum) / real'(concurrency_n) : 0.0);
    if (errs == 0 && oerrs == 0) begin
      $display("MBXD_TB_OK  fill: 12 descriptors, out-of-order responses, 0 mismatches; drain: 3 blocks, 0 framing errors");
    end else begin
      $display("MBXD_TB_FAIL fill_errs=%0d drain_errs=%0d", errs, oerrs);
    end
    $finish;
  end
endmodule
