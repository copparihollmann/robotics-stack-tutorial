// -----------------------------------------------------------------------------
// Synchronous 16-bit sample FIFO with a level count and a sticky overrun flag.
//
// First-word-fall-through, because a register read that pops has to return the
// sample in the same bus cycle.  The naive way to get that is an asynchronous array
// read, which Vivado cannot put in a block RAM -- 1024x16 of LUT RAM is around 160
// LUTs, and this design is already at 75%.  So the RAM read is synchronous and one
// output register in front of it does the fall-through.  BRAM here is genuinely
// free: 76 BRAM36 are spare and this is one BRAM18.
//
// Depth is the amount of lateness the software is allowed.  1024 entries is 64 ms at
// 15.99 kHz -- a whole DMIC block plus an inference pass.
// -----------------------------------------------------------------------------
module pdm_mic_fifo #(
  parameter integer DW    = 16,
  parameter integer ALOG2 = 10
) (
  input  wire            clk,
  input  wire            rst,
  input  wire            wr_en,
  input  wire [DW-1:0]   wr_data,
  input  wire            rd_en,
  output wire [DW-1:0]   rd_data,
  output wire            empty,
  output wire            full,
  output wire [ALOG2:0]  level,
  output reg             overrun     // sticky: a sample arrived with the FIFO full
);
  localparam integer DEPTH = 1 << ALOG2;

  (* ram_style = "block" *) reg [DW-1:0] mem [0:DEPTH-1];
  reg [ALOG2:0] wptr, rptr;
  reg [DW-1:0]  outreg;
  reg           outvalid;

  wire [ALOG2:0] fill   = wptr - rptr;          // still in the RAM
  wire           ram_ne = (wptr != rptr);
  wire           fetch  = ram_ne && (!outvalid || rd_en);

  assign full    = (fill == DEPTH[ALOG2:0]);
  assign empty   = !outvalid;
  // LEVEL COUNTS WHAT CAN BE READ, NOT WHAT EXISTS.  For the one or two cycles after a
  // sample is written into an empty FIFO, `fill` is 1 but the fall-through register has
  // not fetched it yet, so `empty` is still set and a read returns 0 without popping.
  // Reporting `fill + outvalid` there tells software there is a sample when there is not,
  // and the driver writes a spurious zero into its block -- once in maybe a thousand
  // captures, one sample out of 31744, which is exactly the sort of thing that is never
  // debugged. Under-reporting for two cycles costs nothing: the caller polls again.
  assign level   = outvalid ? (fill + 1'b1) : {(ALOG2+1){1'b0}};
  assign rd_data = outreg;

  always @(posedge clk) begin
    if (rst) begin
      wptr <= 0; rptr <= 0; outvalid <= 1'b0; overrun <= 1'b0; outreg <= {DW{1'b0}};
    end else begin
      if (wr_en && !full) begin
        mem[wptr[ALOG2-1:0]] <= wr_data;
        wptr <= wptr + 1'b1;
      end
      if (wr_en && full) overrun <= 1'b1;

      if (fetch) begin
        outreg   <= mem[rptr[ALOG2-1:0]];
        rptr     <= rptr + 1'b1;
        outvalid <= 1'b1;
      end else if (rd_en && outvalid) begin
        outvalid <= 1'b0;
      end
    end
  end
endmodule
