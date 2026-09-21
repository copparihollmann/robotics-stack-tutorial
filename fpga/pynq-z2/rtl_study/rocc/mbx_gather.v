// -----------------------------------------------------------------------------
// MBX patch-gather (im2col) engine -- the datapath that attacks the 21.7 %.
//
// PEXT_KERNELS.md section 4 measures mb_pext_conv_gather at 90,880 instructions,
// 21.7 % of the accelerated LeNet stream, against DOT8's 9.2 %.  It exists only
// because ModelBlaster emits NCHW, so the reduction axis (ic, kh, kw) is not
// contiguous; every gathered byte costs 3.2 instructions against a floor of 2.
//
// In hardware the same work is a funnel shift: read the 64-bit word containing
// row_base + iw0, rotate it into place, merge KW bytes into the patch word being
// assembled, emit the word when eight bytes are full.  One source row per cycle
// rather than 2-3 instructions per byte.
//
//   mbx_align   : the byte funnel + merge register -- the whole per-cycle cost
//   mbx_gather  : that, plus the row walker and the row-pointer RAM
//
// ROWS is the row-pointer table depth: IC*KH for the layer.  LeNet conv2 needs
// 30, DroNet conv_modules.8 needs 384; 64 is measured here and the table is a
// LUTRAM so the depth is close to linear.
// -----------------------------------------------------------------------------

// ---- the byte funnel ---------------------------------------------------------
// Two consecutive source beats in, one 64-bit patch word being assembled.
//   sh   : byte offset of the run inside {hi,lo}
//   pos  : byte offset in the patch word where the run starts
//   len  : run length, 1..8 (KW, or the tail of it)
// Emits the merged patch word and a byte-enable mask.
module mbx_align (
  input  wire [63:0] lo,
  input  wire [63:0] hi,
  input  wire [2:0]  sh,
  input  wire [2:0]  pos,
  input  wire [3:0]  len,
  input  wire [63:0] resid,      // patch word so far
  output wire [63:0] merged,
  output wire [7:0]  be
);
  // funnel right by sh bytes out of the 128-bit pair
  wire [127:0] pair = {hi, lo};
  wire [63:0]  src  = pair >> (sh * 8);
  // rotate left by pos bytes so the run lands at its destination byte
  wire [127:0] rot  = {src, src} << (pos * 8);
  wire [63:0]  plc  = rot[127:64];
  // byte enables: `len` ones starting at `pos`, wrapping is not wanted so the
  // caller splits a run that crosses the word boundary into two.
  wire [7:0]   ones = (8'hff >> (4'd8 - len));
  wire [15:0]  msk  = {8'h00, ones} << pos;
  assign be = msk[7:0];

  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_byte
      assign merged[i*8 +: 8] = be[i] ? plc[i*8 +: 8] : resid[i*8 +: 8];
    end
  endgenerate
endmodule

// ---- the whole engine --------------------------------------------------------
module mbx_gather #(
  parameter ROWS = 64
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        start,      // begin one output pixel
  input  wire [31:0] iw0,        // ow*SW - PW, may be negative (two's complement)
  input  wire [3:0]  kw,         // 1..8
  input  wire [15:0] nrows,      // IC*KH
  input  wire [31:0] iwid,       // IW, for the bounds test
  // row-pointer table write port (one per output ROW, not per pixel)
  input  wire        rp_we,
  input  wire [15:0] rp_wa,
  input  wire [32:0] rp_wd,      // {valid, byte address}
  // memory read request / response
  output wire [31:0] mem_addr,
  output wire        mem_req,
  input  wire        mem_gnt,
  input  wire [63:0] mem_lo,
  input  wire [63:0] mem_hi,
  // patch write port
  output wire [63:0] patch_wd,
  output wire [15:0] patch_wa,
  output wire        patch_we,
  output wire        busy
);
  reg [32:0] rptr [0:ROWS-1];
  always @(posedge clk) if (rp_we) rptr[rp_wa[$clog2(ROWS)-1:0]] <= rp_wd;

  reg [15:0] row;
  reg [15:0] cnt;        // bytes written into the patch so far
  reg [63:0] resid;
  reg        run;

  wire [32:0] rp   = rptr[row[$clog2(ROWS)-1:0]];
  wire        rvld = rp[32];
  wire [31:0] base = rp[31:0] + iw0;
  wire        inb  = rvld && !iw0[31] && ((iw0 + {28'd0, kw}) <= iwid);

  assign mem_addr = {base[31:3], 3'b000};
  assign mem_req  = run && rvld;

  wire [2:0] sh  = base[2:0];
  wire [2:0] pos = cnt[2:0];
  // a run that would cross the patch word boundary is split; `len` is the part
  // that fits in this word.
  wire [3:0] room = 4'd8 - {1'b0, pos};
  wire [3:0] len  = (kw > room) ? room : kw;

  wire [63:0] merged;
  wire [7:0]  be;
  mbx_align u_al (.lo(inb ? mem_lo : 64'd0), .hi(inb ? mem_hi : 64'd0),
                  .sh(sh), .pos(pos), .len(len), .resid(resid),
                  .merged(merged), .be(be));

  wire step = run && (mem_gnt || !rvld);
  wire full = (({1'b0, pos} + len) == 4'd8);

  assign patch_wd = merged;
  assign patch_wa = {3'd0, cnt[15:3]};
  assign patch_we = step && full;
  assign busy     = run;

  always @(posedge clk) begin
    if (rst) begin
      run <= 1'b0; row <= 16'd0; cnt <= 16'd0; resid <= 64'd0;
    end else if (start) begin
      run <= 1'b1; row <= 16'd0; cnt <= 16'd0; resid <= 64'd0;
    end else if (step) begin
      resid <= full ? 64'd0 : merged;
      cnt   <= cnt + {12'd0, len};
      if (len == kw) begin
        row <= row + 16'd1;
        if (row + 16'd1 >= nrows) run <= 1'b0;
      end
    end
  end
endmodule
