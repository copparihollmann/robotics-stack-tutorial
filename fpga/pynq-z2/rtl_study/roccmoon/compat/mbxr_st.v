// SPDX-License-Identifier: Apache-2.0
//
// FROZEN: the drain and the engine AS 0x5A5A0028 AND EVERY BITSTREAM BEFORE 0x5A5A002E CARRY
// THEM.  Do not develop here.  This directory exists for exactly one purpose: so that the
// CURRENT driver can be run against the OLD silicon in Verilator, every time, instead of on a
// board by four workstreams in one afternoon.
//
// WHAT IT CAUGHT, and why it is worth the two files.  `st`'s rs2 carried `nblocks[15:0]` here
// and nothing else; the 2-D descriptor reuses that word.  The first cut of the 2-D encoding put
// `row_bytes` in the low sixteen bits, so THIS engine -- which reads exactly those bits and
// ignores the rest -- was told `nblocks = 64` for every drain, waited for blocks that never
// arrived, and returned MBXR_E_TIMEOUT from the first dispatch with no error bit set. On a
// board that reads as `image_bytes = 98,304, calls_engine = 0, last_rc = -4`, which is
// indistinguishable from a dozen other faults; four runs on two boards were spent on it.
//
// The fix is that `nrows` lives in rs2[15:0], so a flat descriptor means the same thing to both
// engines. run_compat_tb.sh is what proves it still does. If you change the `st` encoding and
// this stops passing, the encoding is wrong -- not this file.
//
//
// mbxr_st -- the result drain, as built: quantised words out as 64-byte TileLink Puts.
//
// Derived from rtl_study/rocc/mbxd_st.v, which is left as it was measured.  Two changes,
// both found by building rather than pricing:
//
//   * SOURCE IDs ARE TRACKED, NOT ROUND-ROBINED.  mbxd_st assigned `sid <= sid + 1` modulo
//     DEPTH and gated issue on a count of outstanding Puts.  With DEPTH = 2, a Put on ID 0
//     that is still awaiting its AccessAck while ID 1's has returned leaves the count at 1,
//     so the next burst goes out on ID 0 again -- two in-flight transactions on one source,
//     which TileLink forbids.  Acks usually return in order, so it would usually work.
//     Here each ID has a busy bit, cleared by its own AccessAck.
//
//   * THE FIFO SAYS WHEN IT IS NEARLY FULL.  mbxd_st's in_ready fell when the FIFO was
//     full and mbxd_top ignored it, so a result arriving then was dropped.  `almost_full`
//     leaves room for everything already in the arithmetic pipeline when the sequencer
//     is told to hold.
//
// A block's beats go out contiguously on A (TileLink requires it), so the first beat is not
// issued until a whole block is in the FIFO.
//
// REVISION 2 (a proposal, not built): THE ACKNOWLEDGED WATERMARK.  `acked_blocks` counts the
// blocks b such that every block below b has had its AccessAck.  Each source ID remembers the
// index of the block it carries; while a source is busy, no block at or past that index is
// counted.  A reader (incremental placement on hart 1, or a client past a bypass) may read
// [0, acked_blocks) and nothing else: an ack, not elapsed time, says a Put is complete.  Acks
// of different source IDs return in any order, so this is the minimum over busy sources.

module mbxr_st #(
  parameter DEPTH   = 2,     // 64-byte Puts in flight == source IDs
  parameter LGFIFO  = 5,
  parameter MARGIN  = 4      // words of headroom behind almost_full
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  input  wire [39:0] dst_base,
  input  wire [15:0] nblocks,

  input  wire        in_valid,
  input  wire [63:0] in_data,
  output wire        almost_full,
  output wire        overflow,        // sticky: a word arrived with the FIFO full

  output wire        req_valid,
  input  wire        req_ready,
  output wire [39:0] req_addr,
  output wire [3:0]  req_source,      // 0..DEPTH-1; the engine offsets it
  output wire [63:0] req_data,
  output wire        req_last,

  input  wire        rsp_valid,       // AccessAck
  input  wire [3:0]  rsp_source,

  output wire        busy,
  output wire [15:0] left_blocks,
  output wire [15:0] acked_blocks
);
  localparam FD = (1 << LGFIFO);

  reg [63:0]      fifo [0:FD-1];
  reg [LGFIFO:0]  wp, rp;
  wire [LGFIFO:0] used = wp - rp;
  wire            full = used[LGFIFO];
  assign almost_full = (used >= (FD - MARGIN));

  reg [39:0]      addr;
  reg [15:0]      left;
  reg [2:0]       beat;
  reg [3:0]       sid;          // held for a whole burst
  reg [DEPTH-1:0] s_busy;
  reg             run;
  reg             ovf;
  reg [15:0]      issued;       // blocks whose first beat has gone out
  reg [15:0]      blk [0:DEPTH-1];

  integer fi;
  reg [3:0] free_id;
  reg       have_free;
  always @* begin
    free_id = 4'd0; have_free = 1'b0;
    for (fi = DEPTH-1; fi >= 0; fi = fi - 1)
      if (!s_busy[fi]) begin free_id = fi[3:0]; have_free = 1'b1; end
  end

  wire at_start   = (beat == 3'd0);
  wire have_block = (used >= 8);
  wire can_issue  = run && (left != 16'd0) &&
                    (at_start ? (have_block && have_free) : 1'b1);

  assign req_valid   = can_issue;
  assign req_addr    = addr;
  assign req_source  = at_start ? free_id : sid;
  assign req_data    = fifo[rp[LGFIFO-1:0]];
  assign req_last    = (beat == 3'd7);
  assign busy        = run || (s_busy != {DEPTH{1'b0}});
  assign overflow    = ovf;
  assign left_blocks = left;

  integer ai;
  reg [15:0] wm;
  always @* begin
    wm = issued;
    for (ai = 0; ai < DEPTH; ai = ai + 1)
      if (s_busy[ai] && blk[ai] < wm) wm = blk[ai];
  end
  assign acked_blocks = wm;

  wire fire = req_valid && req_ready;

  always @(posedge clk) begin
    if (rst) begin
      wp <= 0; rp <= 0; addr <= 40'd0; left <= 16'd0; beat <= 3'd0; sid <= 4'd0; issued <= 16'd0;
      s_busy <= {DEPTH{1'b0}}; run <= 1'b0; ovf <= 1'b0;
    end else begin
      if (in_valid) begin
        if (full) ovf <= 1'b1;
        else begin
          fifo[wp[LGFIFO-1:0]] <= in_data;
          wp <= wp + 1'b1;
        end
      end
      if (start && !busy) begin
        addr <= dst_base;
        issued <= 16'd0;
        left <= nblocks;
        beat <= 3'd0;
        run  <= (nblocks != 16'd0);
      end
      if (rsp_valid && rsp_source < DEPTH) begin
        s_busy[rsp_source[$clog2(DEPTH > 1 ? DEPTH : 2)-1:0]] <= 1'b0;
      end
      if (fire) begin
        rp   <= rp + 1'b1;
        beat <= beat + 3'd1;
        if (at_start) begin
          sid <= free_id;
          s_busy[free_id[$clog2(DEPTH > 1 ? DEPTH : 2)-1:0]] <= 1'b1;
          blk[free_id[$clog2(DEPTH > 1 ? DEPTH : 2)-1:0]] <= issued;
          issued <= issued + 16'd1;
        end
        if (req_last) begin
          addr <= addr + 40'd64;
          left <= left - 16'd1;
          if (left == 16'd1) run <= 1'b0;
        end
      end
    end
  end
endmodule
