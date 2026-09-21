// -----------------------------------------------------------------------------
// MBX tile fill engine -- one instruction moves a 2-D tile.
//
// This is the block that attacks the 53.9 % of the remaining instruction stream that
// ROCC_STUDY.md section 1 measures as moving bytes and computing addresses, rather than
// the 12.7 % that is arithmetic.  A descriptor is (base, row_bytes, stride, nrows), so
// a weight tile or an activation tile is one `mbx.ld` instead of a software copy loop.
//
// Two things it has to do that the core cannot:
//   - DEPTH outstanding loads.  MEMORY_HIERARCHY.md section 5 measures both harts at
//     concurrency 1.01 because nMSHRs = 0 selects the blocking DCache.
//   - realign.  The source rows are byte-addressed and the scratchpad is 64-bit, so
//     every row needs a funnel shift; in software that is the 3.23 instructions per
//     gathered byte the patch gather already pays.
//
// Responses may return out of order, so the reorder buffer is indexed by tag and
// retired in issue order by a head pointer -- the same structure mbx_ctrl uses, sized
// by DEPTH, which is the parameter that prices the concurrency.
// -----------------------------------------------------------------------------
module mbx_dma #(
  parameter DEPTH = 4
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  input  wire [39:0] src_base,
  input  wire [15:0] row_bytes,
  input  wire [15:0] src_stride,
  input  wire [15:0] nrows,
  input  wire [15:0] dst_bank,
  input  wire [15:0] dst_addr,
  // memory
  output wire [39:0] req_addr,
  output wire        req_valid,
  input  wire        req_ready,
  output wire [2:0]  req_tag,
  input  wire        rsp_valid,
  input  wire [2:0]  rsp_tag,
  input  wire [63:0] rsp_data,
  // scratchpad fill port
  output wire        sp_we,
  output wire [15:0] sp_bank,
  output wire [15:0] sp_addr,
  output wire [63:0] sp_data,
  output wire        busy
);
  localparam TW = 3;

  // ---- issue side ----------------------------------------------------------
  reg [15:0] irow, ioff;
  reg        run_i;
  reg [39:0] base_q; reg [15:0] rb_q, str_q, nr_q, db_q, da_q;

  wire [39:0] iaddr = base_q + {24'd0, irow} * {24'd0, str_q} + {24'd0, ioff};
  wire        last_in_row = (ioff + 16'd8) >= rb_q;
  wire        last_row    = (irow + 16'd1) >= nr_q;

  reg  [DEPTH-1:0] ent_v;
  reg  [63:0]      robuf [0:DEPTH-1];
  reg  [DEPTH-1:0] ent_d;
  reg  [TW-1:0]    head, tail;
  wire             full = ent_v[tail];

  assign req_addr  = {iaddr[39:3], 3'b000};
  assign req_valid = run_i && !full;
  assign req_tag   = tail;

  // ---- retire side: in issue order, realigned -----------------------------
  reg [15:0] wrow, woff;
  reg [63:0] resid;
  reg        have_resid;
  wire       ret = ent_v[head] && ent_d[head];
  wire [2:0] sh  = base_q[2:0];               // constant per descriptor
  wire [127:0] pair = {robuf[head], resid};
  wire [63:0]  aligned = pair >> (sh * 8);

  assign sp_we   = ret && have_resid;
  assign sp_bank = db_q;
  assign sp_addr = da_q + {3'd0, woff[15:3]} + {3'd0, wrow[12:0]} * {3'd0, rb_q[15:3]};
  assign sp_data = (sh == 3'd0) ? robuf[head] : aligned;
  assign busy    = run_i || (|ent_v);

  integer k;
  always @(posedge clk) begin
    if (rst) begin
      run_i <= 1'b0; ent_v <= {DEPTH{1'b0}}; ent_d <= {DEPTH{1'b0}};
      head <= 0; tail <= 0; irow <= 0; ioff <= 0; wrow <= 0; woff <= 0;
      have_resid <= 1'b0;
    end else begin
      if (start) begin
        run_i <= 1'b1; irow <= 0; ioff <= 0; wrow <= 0; woff <= 0;
        head <= 0; tail <= 0; ent_v <= {DEPTH{1'b0}}; ent_d <= {DEPTH{1'b0}};
        have_resid <= 1'b0;
        base_q <= src_base; rb_q <= row_bytes; str_q <= src_stride;
        nr_q <= nrows; db_q <= dst_bank; da_q <= dst_addr;
      end
      if (req_valid && req_ready) begin
        ent_v[tail] <= 1'b1;
        ent_d[tail] <= 1'b0;
        tail <= tail + 1'b1;
        if (last_in_row) begin
          ioff <= 16'd0;
          irow <= irow + 16'd1;
          if (last_row) run_i <= 1'b0;
        end else begin
          ioff <= ioff + 16'd8;
        end
      end
      if (rsp_valid) begin
        robuf[rsp_tag] <= rsp_data;
        ent_d[rsp_tag] <= 1'b1;
      end
      if (ret) begin
        ent_v[head] <= 1'b0;
        head  <= head + 1'b1;
        resid <= robuf[head];
        have_resid <= 1'b1;
        if ((woff + 16'd8) >= rb_q) begin
          woff <= 16'd0;
          wrow <= wrow + 16'd1;
          have_resid <= 1'b0;
        end else begin
          woff <= woff + 16'd8;
        end
      end
    end
  end
endmodule
