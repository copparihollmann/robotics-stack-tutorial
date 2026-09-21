// SPDX-License-Identifier: Apache-2.0
//
// mbxd_st -- the result drain: quantised bytes out, as 64-byte TileLink Puts.
//
// WHY IT IS A SEPARATE MODULE.  Revision 2's mbx_tiled has an `mbx.st` opcode that is
// decoded and wired to nothing; the results leave on a raw `out_bytes/out_valid` stream
// and the writeback is left to software.  That is a hole, and it is the kind of hole
// that makes a projected speedup wrong in the direction nobody checks: a tile whose
// outputs go back through the core's store path pays the core's store path.
//
// It is separate rather than folded into mbxd_dma so the two can be PRICED SEPARATELY --
// the load engine is the part that is worth landing on its own, for every memory-bound
// thing on this SoC, and mixing its area with the drain's would hide that.
//
// THE ASYMMETRY WITH THE LOAD ENGINE IS REAL AND IT IS WHY THIS IS SMALLER.  A Get's
// beats come back whenever the L2 feels like it, so the load engine needs per-source
// reassembly state.  A Put's beats go out when WE feel like it, and TileLink requires
// them contiguous on A, so a store holds one source for eight consecutive beats and the
// only per-source state is "is this ID still waiting for its AccessAck".  Outstanding
// stores therefore need a counter, not a table.
//
// Deliberately NOT here: no read-modify-write, no partial-block masks, no ordering
// against the load engine.  Output tiles are whole 64-byte blocks by construction
// (the quantiser emits NCH bytes at a time and software sizes tiles so the drain is a
// multiple of 64), and anything else is a software fence.

module mbxd_st #(
  parameter DEPTH   = 2,     // 64-byte Puts in flight
  parameter LGBEATS = 3,
  parameter LGFIFO  = 5      // 32 x 64b of write-combining, in LUTRAM
) (
  input  wire        clk,
  input  wire        rst,

  input  wire        start,
  input  wire [39:0] dst_base,
  input  wire [15:0] nblocks,

  // ---- quantised result stream in ---------------------------------------------
  input  wire        in_valid,
  output wire        in_ready,
  input  wire [63:0] in_data,

  // ---- TileLink A: PutFullData.  first/last bracket one block's beats. ----------
  output wire        req_valid,
  input  wire        req_ready,
  output wire [39:0] req_addr,
  output wire [3:0]  req_source,
  output wire [63:0] req_data,
  output wire        req_first,
  output wire        req_last,

  // ---- TileLink D: AccessAck (no data) ------------------------------------------
  input  wire        rsp_valid,

  output wire        busy
);
  localparam BEATS = (1 << LGBEATS);
  localparam [39:0] BLKB = BEATS * 8;
  localparam FD = (1 << LGFIFO);

  reg [63:0]         fifo [0:FD-1];
  reg [LGFIFO:0]     wp, rp;
  wire [LGFIFO:0]    used = wp - rp;
  // used ranges over [0, FD]; the FIFO is full exactly when the top bit is set.  The
  // first version of this line tested for used == 2*FD-1, which never happens, so the
  // FIFO silently wrapped and dropped results -- caught by tb_mbxd.sv.
  wire               full = used[LGFIFO];

  assign in_ready = !full;

  reg [39:0]  addr;
  reg [15:0]  left;
  reg [LGBEATS-1:0] beat;
  reg [3:0]   sid;
  reg [7:0]   outst;          // Puts awaiting AccessAck
  reg         run;

  // A whole block must be present before the FIRST beat goes out: TileLink wants the
  // beats contiguous, and a FIFO that runs dry mid-burst would deadlock the A channel.
  // The condition applies only at beat 0 -- gating every beat on it stalls the burst
  // after the first beat, because that beat has just taken `used` below BEATS.  That is
  // exactly what happened, and it is why this has a testbench.
  wire have_block = (used >= BEATS[LGFIFO:0]);
  wire at_start   = (beat == {LGBEATS{1'b0}});
  wire can_issue  = run && (left != 16'd0) && (!at_start || have_block)
                    && (outst < DEPTH[7:0]);

  assign req_valid  = can_issue;
  assign req_addr   = addr;
  assign req_source = sid;
  assign req_data   = fifo[rp[LGFIFO-1:0]];
  assign req_first  = (beat == {LGBEATS{1'b0}});
  assign req_last   = (beat == {LGBEATS{1'b1}});
  assign busy       = run || (outst != 8'd0);

  wire fire = req_valid && req_ready;

  always @(posedge clk) begin
    if (rst) begin
      wp <= 0; rp <= 0; addr <= 40'd0; left <= 16'd0;
      beat <= {LGBEATS{1'b0}}; sid <= 4'd0; outst <= 8'd0; run <= 1'b0;
    end else begin
      if (in_valid && in_ready) begin
        fifo[wp[LGFIFO-1:0]] <= in_data;
        wp <= wp + 1'b1;
      end
      if (start && !busy) begin
        addr <= dst_base;
        left <= nblocks;
        beat <= {LGBEATS{1'b0}};
        run  <= (nblocks != 16'd0);
      end
      if (fire) begin
        rp   <= rp + 1'b1;
        beat <= beat + {{(LGBEATS-1){1'b0}}, 1'b1};
        if (req_last) begin
          addr  <= addr + BLKB;
          left  <= left - 16'd1;
          sid   <= (sid + 4'd1) & (DEPTH[3:0] - 4'd1);
          outst <= outst + 8'd1 - {7'd0, rsp_valid};
          if (left == 16'd1) begin
            run <= 1'b0;
          end
        end else if (rsp_valid) begin
          outst <= outst - 8'd1;
        end
      end else if (rsp_valid) begin
        outst <= outst - 8'd1;
      end
    end
  end
endmodule
