// SPDX-License-Identifier: Apache-2.0
//
// mbxd_dma -- the decoupled tile fill engine.  THIS IS THE POINT OF THE WHOLE STUDY.
//
// WHAT IT REPLACES AND WHY.  mbx_dma.v (revision 2, ROCC_STUDY.md 7.4) issues EIGHT-BYTE
// requests and tracks DEPTH of them in a reorder buffer.  Four outstanding 8-byte Gets
// over a ~16-cycle L2 hit is 2.0 B/cycle, and every accelerator number in this repository
// is capped by that and not by its datapath: unit_tiled4 has a 32 MAC/cycle array and is
// port-limited to 4.5-6.4.  MEMORY_HIERARCHY.md section 5 measured the same disease in
// the core -- both harts instantiate rocket-chip's BLOCKING DCache (nMSHRs = 0), so a
// hart sustains 1.01 outstanding misses and 1.34 B/cycle of DRAM, 17% of the 64-bit link
// it is attached to.  "Every DRAM bandwidth figure here is a latency in disguise."
//
// THREE CHANGES, AND THE THIRD IS THE ONE THAT MAKES IT SMALL.
//
//   1. CACHE-BLOCK REQUESTS.  One Get per 64-byte block instead of eight 8-byte Gets.
//      The ~41-cycle round trip is amortised over 8 beats instead of 1, and the request
//      channel stops being the bottleneck: 8 blocks in flight is 8 A-channel beats, not
//      64.
//
//   2. MANY OF THEM.  TileLink distinguishes concurrent transactions by SOURCE ID, so
//      DEPTH Gets can be in flight with no ordering constraint between them.  A hart
//      cannot do this; a DMA engine has no architectural reason not to.
//
//   3. NO REORDER BUFFER.  This is what keeps it at a few hundred LUT and is the
//      deliberate un-Gemmini-ing.  Each source ID is assigned its DESTINATION SCRATCHPAD
//      WORD at issue time, so a returning beat carries everything needed to place it:
//      the source names the block, and TileLink guarantees beats WITHIN one source
//      arrive in order, so a 3-bit beat counter per source is the entire reassembly
//      state.  Blocks may return in any order and interleave freely; nothing is buffered
//      and nothing is retired in order.  Per-source state is one 16-bit word address and
//      one 3-bit beat counter -- 19 bits, against the 64 bits of payload per entry the
//      old engine held, and against the ~1,800 flip-flops ROCC_STUDY.md 7.4 priced a
//      64-byte reorder buffer at.
//
// WHAT IS DELIBERATELY NOT HERE, and what it costs:
//
//   * No byte funnel.  mbx_dma realigned every row into the scratchpad's 64-bit words,
//     which is 44 LUT of LUTRAM plus a residue register plus a one-cycle bubble at every
//     row boundary.  Here the scratchpad is a 1:1 image of 64-byte-aligned memory and
//     the leading offset is the READ side's problem, where it is a byte rotate the tile
//     sequencer's address already expresses.  Cost: a row that is not a multiple of 64
//     bytes fetches up to 63 bytes it does not use.  For a weight tile of thousands of
//     bytes that is under 1%; for a 64-byte row it would be 50%, which is what the
//     descriptor's row_blocks field exists to let software avoid.
//
//   * No multipliers.  The row walk is a running add of row_stride, not row * stride.
//     mbx_dma's 4 DSP48E1 were exactly that multiply and ROCC_STUDY.md 7.4 calls them
//     "an artefact: strength-reduce to a running add and they go away".  They are gone.
//
//   * No dependency tracking, no command queue, no reorder buffer, no general control.
//     One descriptor at a time, one `busy` bit, and software fences.
//
// A BUG IN THE THING THIS REPLACES, recorded because it is the reason there is now a
// testbench: mbx_dma declares `head`/`tail` as [TW-1:0] with TW hard-coded to 3, and
// indexes `ent_v[DEPTH-1:0]` and `robuf[0:DEPTH-1]` with them.  At the DEPTH=4 that
// mbx_tiled actually instantiates, the pointers count to 8 and walk off the end of both
// arrays.  It synthesises, it produces the dma_d4 area number in summary.tsv, and it is
// not correct.  tb_mbxd.sv checks THIS engine against a behavioural memory that returns
// beats out of order on purpose.

module mbxd_dma #(
  parameter DEPTH   = 8,     // cache blocks in flight == distinct TileLink source IDs
  parameter LGBEATS = 3      // 2^LGBEATS beats of 64 bits per request (3 -> 64 bytes)
) (
  input  wire        clk,
  input  wire        rst,

  // ---- descriptor.  One instruction's worth of work. ------------------------------
  input  wire        start,
  input  wire [39:0] src_base,     // byte address of the first block, 64-byte aligned
  input  wire [15:0] row_blocks,   // blocks per row  (row_bytes rounded up to 64)
  input  wire [15:0] nrows,
  input  wire [31:0] row_stride,   // bytes from one row's base to the next
  input  wire [15:0] dst_word,     // scratchpad word address of the first beat

  // ---- TileLink A: Get ------------------------------------------------------------
  output wire        req_valid,
  input  wire        req_ready,
  output wire [39:0] req_addr,
  output wire [3:0]  req_source,

  // ---- TileLink D: AccessAckData.  Beats of different sources may interleave; beats
  //      of ONE source arrive in order, which is all the reassembly this needs. -------
  input  wire        rsp_valid,
  output wire        rsp_ready,
  input  wire [3:0]  rsp_source,
  input  wire [63:0] rsp_data,

  // ---- scratchpad fill port -------------------------------------------------------
  output wire        sp_we,
  output wire [15:0] sp_word,      // flat word address; the scratchpad splits it
  output wire [63:0] sp_data,

  output wire        busy,
  output wire [7:0]  inflight      // outstanding transactions, for a real counter
);
  localparam BEATS = (1 << LGBEATS);
  localparam [39:0] BLKB = BEATS * 8;   // bytes per request

  // ---- descriptor registers --------------------------------------------------------
  reg [39:0] blk_addr;             // address of the next block to request
  reg [39:0] row_addr;             // base of the row it belongs to
  reg [15:0] blk_in_row;
  reg [15:0] rows_left;
  reg [15:0] rb_q;
  reg [31:0] stride_q;
  reg [15:0] wptr;                 // destination word of the next block
  reg        issuing;              // still have blocks to request
  // Issued and returned counters rather than a remaining-block count, so the engine
  // needs no nrows*row_blocks product and therefore no multiplier at all.
  reg [23:0] nissued, nret;

  // ---- per-source state.  NO payload storage: 19 bits per outstanding block. -------
  reg [DEPTH-1:0]       s_busy;
  reg [15:0]            s_word [0:DEPTH-1];
  reg [LGBEATS-1:0]     s_beat [0:DEPTH-1];

  // free-source select: lowest clear bit of s_busy.  DEPTH <= 8, so this is a 3-bit
  // priority encoder and not worth being clever about.
  integer         fi;
  reg [3:0]       free_id;
  reg             have_free;
  always @* begin
    free_id   = 4'd0;
    have_free = 1'b0;
    for (fi = DEPTH-1; fi >= 0; fi = fi - 1) begin
      if (!s_busy[fi]) begin
        free_id   = fi[3:0];
        have_free = 1'b1;
      end
    end
  end

  assign req_valid  = issuing && have_free;
  assign req_addr   = {blk_addr[39:LGBEATS+3], {(LGBEATS+3){1'b0}}};
  assign req_source = free_id;
  assign rsp_ready  = 1'b1;        // the fill port is ours; we can always take a beat

  wire        fire_req  = req_valid && req_ready;
  wire        last_blk  = (blk_in_row + 16'd1 >= rb_q);
  wire [15:0] r_word    = s_word[rsp_source] + {13'd0, s_beat[rsp_source]};
  wire        r_last    = (s_beat[rsp_source] == {LGBEATS{1'b1}});

  assign sp_we   = rsp_valid;
  assign sp_word = r_word;
  assign sp_data = rsp_data;
  assign busy    = issuing || (nret != nissued);

  // population count of s_busy, for the outstanding-transaction counter
  integer ci;
  reg [7:0] cnt;
  always @* begin
    cnt = 8'd0;
    for (ci = 0; ci < DEPTH; ci = ci + 1) begin
      cnt = cnt + {7'd0, s_busy[ci]};
    end
  end
  assign inflight = cnt;

  integer k;
  always @(posedge clk) begin
    if (rst) begin
      issuing    <= 1'b0;
      s_busy     <= {DEPTH{1'b0}};
      nissued    <= 24'd0;
      nret       <= 24'd0;
      blk_addr   <= 40'd0;
      row_addr   <= 40'd0;
      blk_in_row <= 16'd0;
      rows_left  <= 16'd0;
      wptr       <= 16'd0;
      rb_q       <= 16'd0;
      stride_q   <= 32'd0;
      for (k = 0; k < DEPTH; k = k + 1) begin
        s_word[k] <= 16'd0;
        s_beat[k] <= {LGBEATS{1'b0}};
      end
    end else begin
      if (start && !busy) begin
        blk_addr   <= src_base;
        row_addr   <= src_base;
        blk_in_row <= 16'd0;
        rows_left  <= nrows;
        rb_q       <= row_blocks;
        stride_q   <= row_stride;
        wptr       <= dst_word;
        nissued    <= 24'd0;
        nret       <= 24'd0;
        issuing    <= (nrows != 16'd0) && (row_blocks != 16'd0);
      end

      // ---- issue ------------------------------------------------------------------
      if (fire_req) begin
        s_busy[free_id] <= 1'b1;
        s_word[free_id] <= wptr;
        s_beat[free_id] <= {LGBEATS{1'b0}};
        wptr            <= wptr + BEATS[15:0];
        nissued         <= nissued + 24'd1;
        if (last_blk) begin
          blk_in_row <= 16'd0;
          row_addr   <= row_addr + {8'd0, stride_q};
          blk_addr   <= row_addr + {8'd0, stride_q};
          rows_left  <= rows_left - 16'd1;
          if (rows_left == 16'd1) begin
            issuing <= 1'b0;
          end
        end else begin
          blk_in_row <= blk_in_row + 16'd1;
          blk_addr   <= blk_addr + BLKB;
        end
      end

      // ---- return.  Out of order across sources, in order within one. --------------
      if (rsp_valid) begin
        s_beat[rsp_source] <= s_beat[rsp_source] + {{(LGBEATS-1){1'b0}}, 1'b1};
        if (r_last) begin
          s_busy[rsp_source] <= 1'b0;
          nret <= nret + 24'd1;
        end
      end
    end
  end
endmodule
