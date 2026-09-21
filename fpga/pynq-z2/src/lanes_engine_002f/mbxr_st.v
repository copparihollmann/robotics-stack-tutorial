// SPDX-License-Identifier: Apache-2.0
//
// mbxr_st -- the result drain.  Quantised words out as TileLink PutFullData bursts, over a
// TWO-DIMENSIONAL destination: `nrows` rows of `row_bytes`, `row_stride` bytes apart.
//
// Derived from rtl_study/rocc/mbxd_st.v, which is left as it was measured.  Two changes were
// found by building rather than pricing, and are unchanged here:
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
// A burst's beats go out contiguously on A (TileLink requires it) at one address, so the
// first beat is not issued until the whole burst is in the FIFO.
//
// THE ROW WALK, and why it is an adder and a comparator.  mbxd_dma.v (the fill) has had a
// 2-D descriptor since it was built, and its header says why it costs nothing: "No
// multipliers.  The row walk is a running add of row_stride, not row * stride."  The drain
// now has the same structure -- `row_addr <= row_addr + stride_q` once per row, never a
// product.  What the drain may NOT copy from the fill is its tolerance of slop: the fill
// may over-FETCH the 63 bytes past the end of a row and ignore them; a drain that
// over-WROTE them would corrupt the next row of the caller's tensor.
//
//   THE FILL'S ESCAPE IS OVER-FETCH; THE DRAIN'S IS TRANSACTION SIZE.  Every Put issued
//   here is a naturally aligned PutFullData of 8, 16, 32 or 64 bytes -- the largest that
//   both fits the bytes left in the row and is aligned to the address they start at.  A row
//   of 13 words at byte 32 of a block goes out as 32 + 64 + 8 bytes: three transactions,
//   thirteen beats, and not one byte written that the row does not own.  No byte masks, so
//   no PutPartialData on a path that has never issued one and no read-modify-write in the
//   L2; no byte funnel, so no residue register and no bubble at a row boundary.
//
//   WHAT THAT COSTS THE CALLER, and it is a software constraint, not a silicon one: a row
//   must start and end on an 8-byte boundary.  mbxr.c's planner buys that by rounding the
//   weight tile's quad count DOWN TO EVEN (NCH = 4 bytes a quad, so an even quad count is a
//   whole number of 64-bit words).  On the encoder's enc_qkvo that is Q 27 -> 26 with the
//   tile count, the plane size and the fill traffic all unchanged.  A shape that cannot meet
//   it keeps the flat descriptor and the CPU placement step, which is one row of one
//   descriptor here and bit-identical traffic to the engine that was measured.
//
//   A FLAT DRAIN IS THE ONE-ROW CASE.  nrows = 1, row_bytes = nblocks * 64, dst_base
//   64-byte aligned: the size select picks 64 bytes every time and the A channel is beat for
//   beat what revision 2a's `nblocks` loop emitted.
//
// THE ACKNOWLEDGED WATERMARK.  `acked_blocks` counts the transactions b such that every
// transaction below b has had its AccessAck.  Each source ID remembers the index of the one
// it carries; while a source is busy, no index at or past it is counted.  A reader may treat
// [0, acked_blocks) as complete: an ack, not elapsed time, says a Put is done.  Acks of
// different source IDs return in any order, so this is the minimum over busy sources.  With
// the strided drain nothing in the driver needs it -- there is no placement left to gate --
// but it is what a bypassed client would read and it is two counters and a compare.

module mbxr_st #(
  parameter DEPTH   = 2,     // Puts in flight == source IDs
  parameter LGFIFO  = 5,
  parameter MARGIN  = 4      // words of headroom behind almost_full
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  input  wire [39:0] dst_base,     // byte address of row 0, 8-byte aligned
  input  wire [15:0] row_bytes,    // bytes per row, a multiple of 8
  input  wire [15:0] nrows,
  input  wire [31:0] row_stride,   // bytes from one row's base to the next

  input  wire        in_valid,
  input  wire [63:0] in_data,
  output wire        almost_full,
  output wire        overflow,        // sticky: a word arrived with the FIFO full
  output wire        desc_bad,        // sticky: a descriptor this engine cannot honour

  output wire        req_valid,
  input  wire        req_ready,
  output wire [39:0] req_addr,
  output wire [1:0]  req_size,        // 0 = 8 B, 1 = 16 B, 2 = 32 B, 3 = 64 B
  output wire [3:0]  req_source,      // 0..DEPTH-1; the engine offsets it
  output wire [63:0] req_data,
  output wire        req_last,

  input  wire        rsp_valid,       // AccessAck
  input  wire [3:0]  rsp_source,

  output wire        busy,
  output wire [15:0] left_rows,
  output wire [15:0] acked_blocks
);
  localparam FD = (1 << LGFIFO);

  reg [63:0]      fifo [0:FD-1];
  reg [LGFIFO:0]  wp, rp;
  wire [LGFIFO:0] used = wp - rp;
  wire            full = used[LGFIFO];
  assign almost_full = (used >= (FD - MARGIN));

  reg [39:0]      addr;         // base address of the transaction being issued
  reg [39:0]      row_addr;     // base address of the current row
  reg [12:0]      rw_left;      // 64-bit words left in the current row
  reg [12:0]      rw_q;         // words per row
  reg [15:0]      rows_left;    // rows left, including the one in progress
  reg [31:0]      stride_q;
  reg [2:0]       beat;
  reg [1:0]       bsz;          // size of the burst in progress, held
  reg [3:0]       sid;          // held for a whole burst
  reg [DEPTH-1:0] s_busy;
  reg             run;
  reg             ovf, dbad;
  reg [15:0]      issued;       // transactions whose first beat has gone out
  reg [15:0]      blk [0:DEPTH-1];

  integer fi;
  reg [3:0] free_id;
  reg       have_free;
  always @* begin
    free_id = 4'd0; have_free = 1'b0;
    for (fi = DEPTH-1; fi >= 0; fi = fi - 1)
      if (!s_busy[fi]) begin free_id = fi[3:0]; have_free = 1'b1; end
  end

  // ---- transaction size: the largest aligned power of two the row still holds ------------
  // addr[5:3] is the word offset within a 64-byte block.  No arithmetic: three compares.
  wire [2:0]  wo  = addr[5:3];
  wire        f64 = (wo      == 3'd0) && (rw_left >= 13'd8);
  wire        f32 = (wo[1:0] == 2'd0) && (rw_left >= 13'd4);
  wire        f16 = (wo[0]   == 1'b0) && (rw_left >= 13'd2);
  wire [1:0]  nsz = f64 ? 2'd3 : (f32 ? 2'd2 : (f16 ? 2'd1 : 2'd0));
  wire [3:0]  nbe = f64 ? 4'd8 : (f32 ? 4'd4 : (f16 ? 4'd2 : 4'd1));   // beats of that size

  wire at_start   = (beat == 3'd0);
  wire have_burst = (used >= {{(LGFIFO-3){1'b0}}, nbe});
  wire can_issue  = run && (rw_left != 13'd0) &&
                    (at_start ? (have_burst && have_free) : 1'b1);

  wire [3:0] cur_be = at_start ? nbe : (4'd1 << bsz);
  wire       last_b = (({1'b0, beat} + 4'd1) == cur_be);

  assign req_valid   = can_issue;
  assign req_addr    = addr;
  assign req_size    = at_start ? nsz : bsz;
  assign req_source  = at_start ? free_id : sid;
  assign req_data    = fifo[rp[LGFIFO-1:0]];
  assign req_last    = last_b;
  assign busy        = run || (s_busy != {DEPTH{1'b0}});
  assign overflow    = ovf;
  assign desc_bad    = dbad;
  assign left_rows   = rows_left;

  integer ai;
  reg [15:0] wm;
  always @* begin
    wm = issued;
    for (ai = 0; ai < DEPTH; ai = ai + 1)
      if (s_busy[ai] && blk[ai] < wm) wm = blk[ai];
  end
  assign acked_blocks = wm;

  wire fire = req_valid && req_ready;
  // bytes this transaction covers: 8 << size
  wire [6:0] sz_bytes = 7'd8 << (at_start ? nsz : bsz);
  wire       last_row = (rows_left == 16'd1);

  always @(posedge clk) begin
    if (rst) begin
      wp <= 0; rp <= 0; addr <= 40'd0; row_addr <= 40'd0; beat <= 3'd0; sid <= 4'd0;
      bsz <= 2'd0; rw_left <= 13'd0; rw_q <= 13'd0; rows_left <= 16'd0; stride_q <= 32'd0;
      issued <= 16'd0; s_busy <= {DEPTH{1'b0}}; run <= 1'b0; ovf <= 1'b0; dbad <= 1'b0;
    end else begin
      if (in_valid) begin
        if (full) ovf <= 1'b1;
        else begin
          fifo[wp[LGFIFO-1:0]] <= in_data;
          wp <= wp + 1'b1;
        end
      end
      if (start && !busy) begin
        addr      <= dst_base;
        row_addr  <= dst_base;
        rw_left   <= row_bytes[15:3];
        rw_q      <= row_bytes[15:3];
        rows_left <= nrows;
        stride_q  <= row_stride;
        beat      <= 3'd0;
        issued    <= 16'd0;
        run       <= (nrows != 16'd0) && (row_bytes[15:3] != 13'd0);
        // A descriptor this engine cannot honour: a row that is not a whole number of
        // 64-bit words, or a base that is not 8-byte aligned.  Flagged, not silently
        // rounded -- the driver's planner is what guarantees both.
        if ((row_bytes[2:0] != 3'd0) || (dst_base[2:0] != 3'd0) || (row_stride[2:0] != 3'd0))
          dbad <= 1'b1;
      end
      if (rsp_valid && rsp_source < DEPTH) begin
        s_busy[rsp_source[$clog2(DEPTH > 1 ? DEPTH : 2)-1:0]] <= 1'b0;
      end
      if (fire) begin
        rp   <= rp + 1'b1;
        beat <= beat + 3'd1;
        if (at_start) begin
          sid <= free_id;
          bsz <= nsz;
          s_busy[free_id[$clog2(DEPTH > 1 ? DEPTH : 2)-1:0]] <= 1'b1;
          blk[free_id[$clog2(DEPTH > 1 ? DEPTH : 2)-1:0]] <= issued;
          issued <= issued + 16'd1;
        end
        if (last_b) begin
          beat <= 3'd0;
          if (rw_left == {9'd0, cur_be}) begin       // the row ends with this transaction
            rw_left   <= rw_q;
            rows_left <= rows_left - 16'd1;
            row_addr  <= row_addr + {8'd0, stride_q};
            addr      <= row_addr + {8'd0, stride_q};
            if (last_row) run <= 1'b0;
          end else begin
            rw_left <= rw_left - {9'd0, cur_be};
            addr    <= addr + {33'd0, sz_bytes};
          end
        end
      end
    end
  end
endmodule
