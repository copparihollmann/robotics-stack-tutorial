// SPDX-License-Identifier: Apache-2.0
//
// mbxd_engine -- a RoCC accelerator whose whole purpose is to decouple compute from the
// memory port.
//
// THE ARGUMENT, IN ONE PARAGRAPH.  On this SoC a hart sustains 1.01 outstanding cache
// misses and 1.34 B/cycle of DRAM against a 64-bit link that can carry 8.0
// (MEMORY_HIERARCHY.md 5).  The free DSP48E1 on the part could do ~356 int8 MAC/cycle if
// packed.  That is 265x more arithmetic than the port delivers, and it is why every
// accelerator estimate in this repository is capped by the port rather than by its
// datapath.  So this unit spends its area, in order: on ISSUING MANY LARGE REQUESTS
// (mbxd_dma), on a WIDE PATH FROM BRAM TO THE ARRAY (mbxd_spad, 40 B/cycle), on
// SEQUENCING A TILE WITHOUT THE CORE (mbx_tseq, 127 LUT), and only then on multipliers --
// and it sizes the multipliers to what the fixed port can actually feed rather than to
// what the DSP column allows.
//
// THE SIZING CALCULATION, because an array the port cannot fill is the mistake this
// whole exercise exists to avoid.  The array does 8*NCH MAC/cycle.  A tile whose
// arithmetic intensity is AI MACs per byte fetched sustains F*AI MAC/cycle at a fill
// rate of F B/cycle.  So the array is fed only where
//
//        8 * NCH  <=  F * AI       i.e.      NCH <= F * AI / 8
//
// With the projected F = 6 B/cycle (see mbxd_dma, and it is a projection):
//
//     AI  8.2  (DroNet conv_modules.3, the worst convolution)   ->  NCH <= 6.2
//     AI 30.3  (DroNet, all 12 convolutions)                    ->  NCH <= 22
//     AI 46-89 (LeNet conv1/conv2)                              ->  NCH <= 35-67
//     AI  1.0  (every fully-connected layer; and EVERY step of  ->  NCH <= 0.75
//               an autoregressive decoder, where each weight
//               byte is used exactly once)
//
// NCH = 4, i.e. 32 MAC/cycle, is therefore the right width: it is fed by the worst
// convolution in either network and it is 5x too wide for a matrix-vector layer no
// matter what is built.  That last row is not a detail -- it is the whole answer for a
// transcription decoder, and no array fixes it.
//
// WHAT IS DELIBERATELY LEFT OUT, and why (this is not Gemmini):
//
//   * No reorder buffer.  Source IDs carry destinations; see mbxd_dma.
//   * No dependency tracking and no instruction window.  Six instructions, one
//     descriptor of each kind live, one `busy` bit, software fences at tile boundaries.
//     Gemmini's ROB and its LoopConv are 5,810 LUT and 114 DSP of control
//     (ACCELERATOR_FIT.md 2) and are what ruled it out here.
//   * No im2col engine.  It was 449 LUT of unit_tiled4, and NHWC removes the need for
//     it -- which is the conclusion PEXT_SPEC.md 1.6, PEXT_KERNELS.md and
//     SPEECH_ON_ROCKET.md 11.4 have now each reached independently, the last of them by
//     measuring 16.93x on one network for a change of axis order alone.  Paying 449 LUT
//     to make a layout mistake cheaper, rather than not making it, is the wrong trade.
//   * No padding, stride, dilation or output-channel blocking in hardware.  The loop
//     nest with the shape-dependent edge cases stays in C; the one with three counters
//     and constant strides is the 127 LUT worth moving.
//   * No coherence with the L1.  Every tile boundary is a software fence-and-flush
//     contract, and ROCC_STUDY.md 9 is right that this is the real price.
//
// INSTRUCTIONS (custom-1; only mbxd.fence returns a value):
//
//   funct7 mnemonic     xd  rs1                       rs2
//   0      mbxd.sd      0   src_base[39:0]            {stride[63:32], nrows[31:16],
//                                                      row_blocks[15:0]}
//   1      mbxd.ld      0   {buf, dst_word[15:0]}     -        fill a tile
//   2      mbxd.cfg     0   {P[47:32],Q[31:16],G[15:0]} {out_base[47:32],
//                                                      wgt_base[31:16], act_base[15:0]}
//   3      mbxd.mm      0   -                         -        run the tile
//   4      mbxd.sq      0   -                         {relu[38], shift[37:32],
//                                                      mult[31:0]}
//   5      mbxd.st      0   dst_base[39:0]            nblocks[15:0]   drain results
//   6      mbxd.fence   1   -                         -   rd = {inflight, busy bits}
//
// One `mbxd.ld` is a tile's worth of address walk; one `mbxd.mm` is a tile's worth of
// arithmetic.  That is the granularity ROCC_STUDY.md 7.3 argued for and it is what
// deletes the 21.5% of the frame that section 1 measured as per-output-pixel setup and
// driver loops.

module mbxd_engine #(
  parameter NCH    = 4,      // output channels per pass: 8*NCH MAC/cycle
  parameter GRP    = 4,      // scratchpad banks per read port (even: top bit = buffer)
  parameter LDEPTH = 8,      // 64-byte Gets in flight
  parameter SDEPTH = 2,      // 64-byte Puts in flight
  parameter STORE  = 1       // include the result drain
) (
  input  wire        clk,
  input  wire        rst,

  // ---- RoCC command ---------------------------------------------------------------
  input  wire        cmd_valid,
  input  wire [6:0]  cmd_funct,
  input  wire [63:0] cmd_rs1,
  input  wire [63:0] cmd_rs2,
  input  wire [4:0]  cmd_rd,
  input  wire        cmd_xd,
  output wire        cmd_ready,
  output wire        resp_valid,
  output wire [4:0]  resp_rd,
  output wire [63:0] resp_data,
  output wire        busy,

  // ---- TileLink A (shared by the load and store engines) ---------------------------
  output wire        req_valid,
  input  wire        req_ready,
  output wire        req_write,
  output wire [39:0] req_addr,
  output wire [3:0]  req_source,
  output wire [63:0] req_data,
  output wire        req_first,
  output wire        req_last,

  // ---- TileLink D ------------------------------------------------------------------
  input  wire        rsp_valid,
  input  wire        rsp_write,     // 1 = AccessAck for a Put, 0 = AccessAckData
  input  wire [3:0]  rsp_source,
  input  wire [63:0] rsp_data,

  // ---- the quantised result stream, exposed so the array is observable with the
  //      drain compiled out (STORE = 0) -- otherwise the whole datapath has no reachable
  //      output and out-of-context synthesis deletes it, which is how the first
  //      STORE = 0 row came back at 275 LUT and 0 DSP. ----------------------------
  output wire [63:0] out_bytes,
  output wire        out_valid
);
  localparam NRD = NCH + 1;

  // ---- command decode.  cmd_ready is tied high: RocketCore turns a stalled RoCC
  // command into a pipeline flush and refetch, not a stall, so refusing one is more
  // expensive than accepting it. --------------------------------------------------
  assign cmd_ready = 1'b1;
  wire c = cmd_valid;
  wire sd  = c && (cmd_funct == 7'd0);
  wire ld  = c && (cmd_funct == 7'd1);
  wire cfg = c && (cmd_funct == 7'd2);
  wire mm  = c && (cmd_funct == 7'd3);
  wire sq  = c && (cmd_funct == 7'd4);
  wire st  = c && (cmd_funct == 7'd5);
  wire fen = c && (cmd_funct == 7'd6);

  reg [39:0] d_base;
  reg [15:0] d_rblk, d_rows;
  reg [31:0] d_stride;
  reg [15:0] t_g, t_q, t_p, t_ab, t_wb, t_ob;
  reg [31:0] q_mult;
  reg [5:0]  q_shift;
  reg        q_relu;
  reg        buf_sel;         // the whole of double buffering
  reg [39:0] s_base;
  reg [15:0] s_blocks;

  always @(posedge clk) begin
    if (rst) begin
      d_base <= 40'd0; d_rblk <= 16'd0; d_rows <= 16'd0; d_stride <= 32'd0;
      t_g <= 16'd0; t_q <= 16'd0; t_p <= 16'd0;
      t_ab <= 16'd0; t_wb <= 16'd0; t_ob <= 16'd0;
      q_mult <= 32'd0; q_shift <= 6'd0; q_relu <= 1'b0; buf_sel <= 1'b0;
      s_base <= 40'd0; s_blocks <= 16'd0;
    end else begin
      if (sd) begin
        d_base   <= cmd_rs1[39:0];
        d_rblk   <= cmd_rs2[15:0];
        d_rows   <= cmd_rs2[31:16];
        d_stride <= cmd_rs2[63:32];
      end
      if (ld) begin
        buf_sel <= cmd_rs1[16];
      end
      if (cfg) begin
        t_g  <= cmd_rs1[15:0];
        t_q  <= cmd_rs1[31:16];
        t_p  <= cmd_rs1[47:32];
        t_ab <= cmd_rs2[15:0];
        t_wb <= cmd_rs2[31:16];
        t_ob <= cmd_rs2[47:32];
      end
      if (sq) begin
        q_mult  <= cmd_rs2[31:0];
        q_shift <= cmd_rs2[37:32];
        q_relu  <= cmd_rs2[38];
      end
      if (st) begin
        s_base   <= cmd_rs1[39:0];
        s_blocks <= cmd_rs2[15:0];
      end
    end
  end

  // ---- the fill engine: the whole point --------------------------------------------
  wire        l_rv, l_rr, l_we, l_busy;
  wire [39:0] l_addr;
  wire [3:0]  l_src;
  wire [15:0] l_word;
  wire [63:0] l_wdata;
  wire [7:0]  l_inflight;

  mbxd_dma #(.DEPTH(LDEPTH), .LGBEATS(3)) u_ld (
    .clk(clk), .rst(rst), .start(ld),
    .src_base(d_base), .row_blocks(d_rblk), .nrows(d_rows),
    .row_stride(d_stride), .dst_word(cmd_rs1[15:0]),
    .req_valid(l_rv), .req_ready(l_rr), .req_addr(l_addr), .req_source(l_src),
    .rsp_valid(rsp_valid && !rsp_write), .rsp_ready(),
    .rsp_source(rsp_source), .rsp_data(rsp_data),
    .sp_we(l_we), .sp_word(l_word), .sp_data(l_wdata),
    .busy(l_busy), .inflight(l_inflight));

  // ---- scratchpad ------------------------------------------------------------------
  wire [NRD*16-1:0] rd_addr;
  wire [NRD*64-1:0] rd_data;

  mbxd_spad #(.NRD(NRD), .GRP(GRP), .DEPTH(512)) u_sp (
    .clk(clk), .rd_addr(rd_addr), .rd_data(rd_data),
    .wr_en(l_we), .wr_word(l_word), .wr_data(l_wdata));

  // ---- tile sequencer, MAC array, accumulators, requantise -------------------------
  wire               mac_en, mac_clr, quant_en, t_busy;
  wire [15:0]        out_index;
  wire [64*NCH-1:0]  acc, bank_rd;
  reg                quant_en_q;
  wire [8*NCH-1:0]   qbytes;

  // The buffer bit is prepended to the activation and weight bases, so a flip is a
  // register write and not a recomputed descriptor.
  wire [15:0] ab = {buf_sel, t_ab[14:0]};
  wire [15:0] wb = {buf_sel, t_wb[14:0]};

  mbx_tseq #(.NCH(NCH)) u_ts (
    .clk(clk), .rst(rst), .start(mm),
    .ngroups(t_g), .nquads(t_q), .npix(t_p),
    .act_base(ab), .wgt_base(wb), .out_base(t_ob),
    .rd_addr(rd_addr), .mac_en(mac_en), .mac_clr(mac_clr),
    .quant_en(quant_en), .out_index(out_index), .busy(t_busy));

  mbx_mac8xn_dsp #(.N(NCH), .PACK(0), .PIPE(0), .ACCW(32)) u_mac (
    .clk(clk), .en(mac_en), .clr(mac_clr),
    .a(rd_data[63:0]), .w(rd_data[64*NRD-1:64]),
    .seed(64'd0), .acc(acc));

  mbx_accbank #(.NACC(16), .NCH(NCH)) u_bank (
    .clk(clk), .we(quant_en), .wa(out_index[3:0]), .wd(acc),
    .ra(out_index[3:0]), .rd(bank_rd));

  always @(posedge clk) begin
    quant_en_q <= quant_en;
  end

  mbx_quant #(.LANES(NCH), .STAGES(3)) u_q (
    .clk(clk), .en(quant_en_q), .acc(bank_rd),
    .mult(q_mult), .shift(q_shift), .relu(q_relu), .y(qbytes));

  // ---- pack NCH quantised bytes into 64-bit words for the drain ---------------------
  // The quantiser emits NCH bytes per output pixel; the drain wants 8.  With NCH = 4
  // that is a two-deep shift register and a toggle, which is the whole packer.
  localparam PK = (8 / NCH) > 0 ? (8 / NCH) : 1;
  reg [63:0]           pk_sh;
  reg [3:0]            pk_cnt;
  reg                  pk_valid;
  reg [2:0]            qd;
  always @(posedge clk) begin
    qd <= {qd[1:0], quant_en_q};      // mbx_quant is 3 stages deep
    pk_valid <= 1'b0;
    if (rst) begin
      pk_cnt <= 4'd0;
    end else if (qd[2]) begin
      if (NCH >= 8) begin
        pk_sh <= qbytes[63:0];        // NCH = 8 already fills a word
      end else begin
        pk_sh <= {qbytes, pk_sh[63:(8*NCH > 63 ? 63 : 8*NCH)]};
      end
      if (pk_cnt + 4'd1 >= PK[3:0]) begin
        pk_cnt   <= 4'd0;
        pk_valid <= 1'b1;
      end else begin
        pk_cnt <= pk_cnt + 4'd1;
      end
    end
  end
  assign out_bytes = pk_sh;
  assign out_valid = pk_valid;

  // ---- drain ------------------------------------------------------------------------
  wire        s_rv, s_rr, s_busy, s_iready;
  wire [39:0] s_addr;
  wire [3:0]  s_src;
  wire [63:0] s_data;
  wire        s_first, s_last;

  generate
    if (STORE) begin : gen_st
      mbxd_st #(.DEPTH(SDEPTH), .LGBEATS(3), .LGFIFO(5)) u_st (
        .clk(clk), .rst(rst), .start(st),
        .dst_base(s_base), .nblocks(s_blocks),
        .in_valid(pk_valid), .in_ready(s_iready), .in_data(pk_sh),
        .req_valid(s_rv), .req_ready(s_rr), .req_addr(s_addr), .req_source(s_src),
        .req_data(s_data), .req_first(s_first), .req_last(s_last),
        .rsp_valid(rsp_valid && rsp_write), .busy(s_busy));
    end else begin : gen_nost
      assign s_rv = 1'b0; assign s_addr = 40'd0; assign s_src = 4'd0;
      assign s_data = 64'd0; assign s_first = 1'b0; assign s_last = 1'b0;
      assign s_busy = 1'b0; assign s_iready = 1'b1;
    end
  endgenerate

  // ---- A-channel arbiter.  Loads win, and the reason is the whole thesis: a stalled
  // load stalls the array, and a stalled store stalls nothing until the FIFO fills.
  // Once a store burst has started it must finish, so the grant is held across its
  // eight beats.
  reg st_hold;
  always @(posedge clk) begin
    if (rst) begin
      st_hold <= 1'b0;
    end else if (s_rv && s_rr) begin
      st_hold <= !s_last;
    end
  end
  wire st_grant = st_hold || (!l_rv && s_rv);

  assign req_valid  = st_grant ? s_rv    : l_rv;
  assign req_write  = st_grant;
  assign req_addr   = st_grant ? s_addr  : l_addr;
  assign req_source = st_grant ? (4'd8 | s_src) : l_src;   // stores use the high IDs
  assign req_data   = s_data;
  assign req_first  = st_grant ? s_first : 1'b1;
  assign req_last   = st_grant ? s_last  : 1'b1;
  assign l_rr = req_ready && !st_grant;
  assign s_rr = req_ready &&  st_grant;

  assign busy       = l_busy || t_busy || s_busy;
  assign resp_valid = fen && cmd_xd;
  assign resp_rd    = cmd_rd;
  assign resp_data  = {48'd0, l_inflight, 5'd0, s_busy, t_busy, l_busy};
endmodule
