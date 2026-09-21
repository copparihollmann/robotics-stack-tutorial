// SPDX-License-Identifier: Apache-2.0
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
  output wire [15:0] left_blocks
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

  wire fire = req_valid && req_ready;

  always @(posedge clk) begin
    if (rst) begin
      wp <= 0; rp <= 0; addr <= 40'd0; left <= 16'd0; beat <= 3'd0; sid <= 4'd0;
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
