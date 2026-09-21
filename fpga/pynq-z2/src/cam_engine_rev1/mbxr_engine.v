// SPDX-License-Identifier: Apache-2.0
//
// mbxr_engine -- the decoupled accelerator as it is built into silicon (ROCC_DECOUPLED.md 8).
//
// It is ROCC_DECOUPLED.md section 4's d_eng4 with the corrections section 7 found by
// pricing Moonshine against the measured port, and the ones the testbench found by
// checking bytes:
//
//   FILL      rtl_study/rocc/mbxd_dma.v, BYTE-IDENTICAL to the file MEMORY_BANDWIDTH.md
//             measured on silicon (6.25 B/cycle DRAM at three outstanding).  The engine
//             inherits exactly that port.  An outstanding cap (default 3, the measured
//             optimum) gates its A channel as BwProbe's Chisel did.
//   PLANES    a mapper between the DMA's flat word index and the scratchpad: a load in
//             WEIGHT mode splits its words into NCH planes of 2^lgpw words, plane r into
//             read port r+1; a load in ACTIVATION mode goes to port 0.  No arithmetic but
//             a shift and a mask.  This is what makes the weights planar (7.5).
//   STORE     rtl_study/rocc/mbxd_spad.v, byte-identical: NCH+1 ports x 4 BRAM36 banks.
//   BUFFERS   the fill buffer is a field of each load; the compute buffers -- one for the
//             activation port, one for the weight ports -- are fields of `cfg`.
//             mbxd_top.v used ONE bit for both, so filling the other buffer while a tile
//             computed would have switched the tile's operands under it.
//   SEQUENCE  mbxr_tseq: bias step, planar weights, pixel stride, hold.
//   ARITH     mbxr_mac (32 MAC/cycle at NCH = 4), mbxr_quant, mbxr_pack.
//   DRAIN     mbxr_st: 64-byte Puts, tracked source IDs, almost_full -> hold.
//
// TWO TileLink CLIENTS, because item 13 needs the weight path to be movable:
//
//   W  weights only (Gets).  The Chisel wrapper attaches it to a PARAMETER: SBUS today,
//      MBUS for the bypass.  Weights are never written by a core after the PS loads the
//      image, so bypassing the L2 is coherent for them.
//   A  activations (Gets) and results (Puts).  Always SBUS, through the L2, because the
//      L2 is the TileLink-C manager that keeps the cores' L1s coherent with a third
//      master: it probes a client holding a block before serving another's Get, and
//      invalidates the clients' copies when this engine Puts.
//
// INSTRUCTIONS.  custom-1 (0x2B) only, so hart 1's custom-0 still traps (MBP is hart 0's).
//
//   funct7 name  xd  rs1                                     rs2
//   0      sd    0   src_base[39:0]                          {stride[63:32], nrows[31:16], row_blocks[15:0]}
//   1      ld    0   {client_A[18], weights[17], fbuf[16],   -
//                     lgpw[11:8]}                            (lgpw: log2 words per plane, 3..10)
//   2      cfg   0   {P[47:32], Q[31:16], G[15:0]}           {astride[63:48], wbuf[41], abuf[40], wbase[25:16], abase[9:0]}
//   3      mm    0   -                                       -
//   4      sq    0   -                                       {amax[55:48], amin[47:40], shift[37:32], mult[31:0]}
//   5      st    0   dst_base[39:0]                          nblocks[15:0]
//   6      fence 1   -                                       -        rd = status
//   7      stat  1   counter index[2:0]                      clear[0] rd = counter
//   8      cap   0   -                                       max outstanding Gets [3:0]

module mbxr_engine #(
  parameter NCH    = 4,
  parameter LDEPTH = 4,     // DMA source IDs (the fourth buys nothing on DRAM; measured)
  parameter SDEPTH = 2      // drain source IDs, offset by LDEPTH on client A
) (
  input  wire        clk,
  input  wire        rst,

  // ---- RoCC, forwarded from hart 1 by the Chisel shim ----------------------------------
  input  wire        cmd_valid,
  input  wire [6:0]  cmd_funct,
  input  wire [63:0] cmd_rs1,
  input  wire [63:0] cmd_rs2,
  input  wire        cmd_xd,
  output wire        resp_valid,     // same cycle as cmd_valid, for xd commands
  output wire [63:0] resp_data,
  output wire        busy,

  // ---- client W: Gets ------------------------------------------------------------------
  output wire        wa_valid,
  input  wire        wa_ready,
  output wire [39:0] wa_addr,
  output wire [3:0]  wa_source,
  input  wire        wd_valid,       // AccessAckData beats only
  input  wire [3:0]  wd_source,
  input  wire [63:0] wd_data,
  input  wire        wd_error,       // denied || corrupt

  // ---- client A: Gets and Puts -----------------------------------------------------------
  output wire        aa_valid,
  input  wire        aa_ready,
  output wire        aa_put,         // 1 = PutFullData beat, 0 = Get
  output wire [39:0] aa_addr,
  output wire [3:0]  aa_source,
  output wire [63:0] aa_data,
  output wire        aa_last,
  input  wire        ad_valid,
  input  wire        ad_ack,         // 1 = AccessAck (Put), 0 = AccessAckData beat (Get)
  input  wire [3:0]  ad_source,
  input  wire [63:0] ad_data,
  input  wire        ad_error
);
  localparam NRD = NCH + 1;
  localparam AW  = 10;

  // ---- command decode ------------------------------------------------------------------
  wire c   = cmd_valid;
  wire sd  = c && (cmd_funct == 7'd0);
  wire ld  = c && (cmd_funct == 7'd1);
  wire cfg = c && (cmd_funct == 7'd2);
  wire mm  = c && (cmd_funct == 7'd3);
  wire sq  = c && (cmd_funct == 7'd4);
  wire st  = c && (cmd_funct == 7'd5);
  wire fen = c && (cmd_funct == 7'd6);
  wire sta = c && (cmd_funct == 7'd7);
  wire cap = c && (cmd_funct == 7'd8);

  reg [39:0]   d_base;
  reg [15:0]   d_rblk, d_rows;
  reg [31:0]   d_stride;
  reg          l_client_a, l_weights, l_fbuf;
  reg [3:0]    l_lgpw;
  reg [3:0]    l_cap;
  reg [15:0]   t_g, t_q, t_p, t_s;
  reg [AW-1:0] t_ab, t_wb;
  reg          t_abuf, t_wbuf;
  reg [31:0]   q_mult;
  reg [5:0]    q_shift;
  reg [7:0]    q_amin, q_amax;
  reg          err_sticky;

  wire l_busy, t_busy, s_busy;

  always @(posedge clk) begin
    if (rst) begin
      d_base <= 40'd0; d_rblk <= 16'd0; d_rows <= 16'd0; d_stride <= 32'd0;
      l_client_a <= 1'b0; l_weights <= 1'b0; l_fbuf <= 1'b0; l_lgpw <= 4'd10;
      l_cap <= 4'd3;
      t_g <= 16'd0; t_q <= 16'd0; t_p <= 16'd0; t_s <= 16'd0;
      t_ab <= {AW{1'b0}}; t_wb <= {AW{1'b0}}; t_abuf <= 1'b0; t_wbuf <= 1'b0;
      q_mult <= 32'd0; q_shift <= 6'd0; q_amin <= 8'h80; q_amax <= 8'h7f;
    end else begin
      if (sd) begin
        d_base   <= cmd_rs1[39:0];
        d_rblk   <= cmd_rs2[15:0];
        d_rows   <= cmd_rs2[31:16];
        d_stride <= cmd_rs2[63:32];
      end
      // the load's routing fields are latched only when the DMA will accept the start, so
      // a refused load cannot re-route the returns of the one in flight
      if (ld && !l_busy) begin
        l_client_a <= cmd_rs1[18];
        l_weights  <= cmd_rs1[17];
        l_fbuf     <= cmd_rs1[16];
        l_lgpw     <= cmd_rs1[11:8];
      end
      if (cfg && !t_busy) begin
        t_g <= cmd_rs1[15:0]; t_q <= cmd_rs1[31:16]; t_p <= cmd_rs1[47:32];
        t_ab <= cmd_rs2[AW-1:0]; t_wb <= cmd_rs2[16 +: AW];
        t_abuf <= cmd_rs2[40]; t_wbuf <= cmd_rs2[41];
        t_s <= cmd_rs2[63:48];
      end
      if (sq && !t_busy) begin
        q_mult  <= cmd_rs2[31:0];
        q_shift <= cmd_rs2[37:32];
        q_amin  <= cmd_rs2[47:40];
        q_amax  <= cmd_rs2[55:48];
      end
      if (cap) l_cap <= (cmd_rs2[3:0] == 4'd0) ? 4'd1 : cmd_rs2[3:0];
    end
  end

  // ---- fill ------------------------------------------------------------------------------
  wire        l_rv, l_rr, l_we;
  wire [39:0] l_addr;
  wire [3:0]  l_src;
  wire [15:0] l_word;
  wire [63:0] l_wdata;
  wire [7:0]  l_inflight;

  wire        dma_rsp_valid  = l_client_a ? (ad_valid && !ad_ack) : wd_valid;
  wire [3:0]  dma_rsp_source = l_client_a ? ad_source : wd_source;
  wire [63:0] dma_rsp_data   = l_client_a ? ad_data   : wd_data;

  mbxd_dma #(.DEPTH(LDEPTH), .LGBEATS(3)) u_dma (
    .clk(clk), .rst(rst), .start(ld),
    .src_base(d_base), .row_blocks(d_rblk), .nrows(d_rows),
    .row_stride(d_stride), .dst_word(16'd0),
    .req_valid(l_rv), .req_ready(l_rr), .req_addr(l_addr), .req_source(l_src),
    .rsp_valid(dma_rsp_valid), .rsp_ready(), .rsp_source(dma_rsp_source),
    .rsp_data(dma_rsp_data),
    .sp_we(l_we), .sp_word(l_word), .sp_data(l_wdata),
    .busy(l_busy), .inflight(l_inflight));

  wire allow = (l_inflight < {4'd0, l_cap});

  // plane mapper: flat word index -> {port, buffer, bank bit, word}
  wire [15:0]   pl_r    = l_word >> l_lgpw;
  wire [15:0]   pl_mask = (16'd1 << l_lgpw) - 16'd1;
  wire [AW-1:0] pl_off  = l_word[AW-1:0] & pl_mask[AW-1:0];
  wire [2:0]    pl_port = l_weights ? (pl_r[2:0] + 3'd1) : 3'd0;
  wire [15:0]   sp_wr_word = {2'd0, pl_port, l_fbuf, pl_off};  // {port, bank-in-group, word}
  // A weight load wider than NCH planes, or an activation load wider than one buffer,
  // would write a port the tile does not own.  Drop those words and flag it.
  wire          pl_bad  = l_weights ? (pl_r >= NCH) : (pl_r != 16'd0);
  wire          sp_we   = l_we && !pl_bad;

  // ---- scratchpad ------------------------------------------------------------------------
  wire [NRD*16-1:0] rd_addr;
  wire [NRD*64-1:0] rd_data;

  mbxd_spad #(.NRD(NRD), .GRP(4), .DEPTH(512)) u_sp (
    .clk(clk), .rd_addr(rd_addr), .rd_data(rd_data),
    .wr_en(sp_we), .wr_word(sp_wr_word), .wr_data(l_wdata));

  // ---- sequencer -------------------------------------------------------------------------
  wire [AW-1:0] a_addr, w_addr;
  wire          s0_valid, s0_clr, s0_last, hold;

  mbxr_tseq #(.NCH(NCH), .AW(AW)) u_ts (
    .clk(clk), .rst(rst), .start(mm),
    .ngroups(t_g), .nquads(t_q), .npix(t_p), .astride(t_s),
    .act_base(t_ab), .wgt_base(t_wb), .hold(hold),
    .a_addr(a_addr), .w_addr(w_addr),
    .s0_valid(s0_valid), .s0_clr(s0_clr), .s0_last(s0_last), .busy(t_busy));

  // mbxd_spad's address is {bank-within-group, word}: bank = {buffer, top word bit}
  assign rd_addr[0 +: 16] = {5'd0, t_abuf, a_addr};
  genvar gp;
  generate
    for (gp = 1; gp < NRD; gp = gp + 1) begin : g_wport
      assign rd_addr[gp*16 +: 16] = {5'd0, t_wbuf, w_addr};
    end
  endgenerate

  // ---- arithmetic ------------------------------------------------------------------------
  // s1: the words addressed in the previous cycle are on the block RAM outputs
  reg s1_valid, s1_clr, s1_last;
  // s2: the accumulators hold what s1 computed; if s1 was a quad's last step, it is final
  reg s2_final;
  always @(posedge clk) begin
    if (rst) begin
      s1_valid <= 1'b0; s1_clr <= 1'b0; s1_last <= 1'b0; s2_final <= 1'b0;
    end else begin
      s1_valid <= s0_valid;
      s1_clr   <= s0_clr;
      s1_last  <= s0_last;
      s2_final <= s1_valid && s1_last;
    end
  end

  wire [32*NCH-1:0] acc;
  mbxr_mac #(.NCH(NCH)) u_mac (
    .clk(clk), .valid(s1_valid), .clr(s1_clr),
    .a(rd_data[63:0]), .w(rd_data[64*NRD-1:64]), .acc(acc));

  wire              qv, q_busy;
  wire [8*NCH-1:0]  qbytes;
  mbxr_quant #(.NCH(NCH)) u_q (
    .clk(clk), .rst(rst), .in_valid(s2_final), .acc(acc),
    .mult(q_mult), .shift(q_shift), .amin(q_amin), .amax(q_amax),
    .out_valid(qv), .y(qbytes), .busy(q_busy));

  wire        pk_valid;
  wire [63:0] pk_word;
  wire [3:0]  pk_fill;
  mbxr_pack #(.NCH(NCH)) u_pk (
    .clk(clk), .rst(rst), .in_valid(qv), .in_bytes(qbytes),
    .out_valid(pk_valid), .out_word(pk_word), .fill(pk_fill));

  // ---- drain -----------------------------------------------------------------------------
  wire        s_rv, s_rr, s_last, s_ovf;
  wire [39:0] s_addr;
  wire [3:0]  s_src;
  wire [63:0] s_data;
  wire [15:0] s_left;

  mbxr_st #(.DEPTH(SDEPTH), .LGFIFO(5), .MARGIN(4)) u_st (
    .clk(clk), .rst(rst), .start(st),
    .dst_base(cmd_rs1[39:0]), .nblocks(cmd_rs2[15:0]),
    .in_valid(pk_valid), .in_data(pk_word),
    .almost_full(hold), .overflow(s_ovf),
    .req_valid(s_rv), .req_ready(s_rr), .req_addr(s_addr), .req_source(s_src),
    .req_data(s_data), .req_last(s_last),
    .rsp_valid(ad_valid && ad_ack && (ad_source >= LDEPTH)),
    .rsp_source(ad_source - LDEPTH[3:0]),
    .busy(s_busy), .left_blocks(s_left));

  // ---- A-channel routing -----------------------------------------------------------------
  // Loads win on A: a stalled load stalls the array, a stalled store stalls nothing until
  // the FIFO fills.  A store burst, once started, holds the grant for its eight beats.
  reg st_hold;
  wire l_on_a = l_client_a && l_rv && allow;
  wire st_grant = st_hold || (!l_on_a && s_rv);
  always @(posedge clk) begin
    if (rst) st_hold <= 1'b0;
    else if (s_rv && s_rr) st_hold <= !s_last;
  end

  assign wa_valid  = !l_client_a && l_rv && allow;
  assign wa_addr   = l_addr;
  assign wa_source = l_src;

  assign aa_valid  = st_grant ? s_rv : l_on_a;
  assign aa_put    = st_grant;
  assign aa_addr   = st_grant ? s_addr : l_addr;
  assign aa_source = st_grant ? (s_src + LDEPTH[3:0]) : l_src;
  assign aa_data   = s_data;
  assign aa_last   = st_grant ? s_last : 1'b1;

  assign l_rr = allow && (l_client_a ? (aa_ready && !st_grant) : wa_ready);
  assign s_rr = aa_ready && st_grant;

  // ---- counters --------------------------------------------------------------------------
  reg [47:0] n_fill_beats, n_drain_beats, n_steps, n_cyc_fill, n_cyc_tseq, n_cyc_any;
  wire clr_stats = sta && cmd_rs2[0];
  always @(posedge clk) begin
    if (rst || clr_stats) begin
      n_fill_beats <= 48'd0; n_drain_beats <= 48'd0; n_steps <= 48'd0;
      n_cyc_fill <= 48'd0; n_cyc_tseq <= 48'd0; n_cyc_any <= 48'd0; err_sticky <= 1'b0;
    end else begin
      if (l_we)           n_fill_beats  <= n_fill_beats + 48'd1;
      if (s_rv && s_rr)   n_drain_beats <= n_drain_beats + 48'd1;
      if (s0_valid)       n_steps       <= n_steps + 48'd1;
      if (l_busy)         n_cyc_fill    <= n_cyc_fill + 48'd1;
      if (t_busy)         n_cyc_tseq    <= n_cyc_tseq + 48'd1;
      if (busy)           n_cyc_any     <= n_cyc_any + 48'd1;
      if ((wd_valid && wd_error) || (ad_valid && ad_error) || (l_we && pl_bad) || s_ovf)
        err_sticky <= 1'b1;
    end
  end

  reg [47:0] stat_sel;
  always @* begin
    case (cmd_rs1[2:0])
      3'd0: stat_sel = n_fill_beats;
      3'd1: stat_sel = n_drain_beats;
      3'd2: stat_sel = n_steps;
      3'd3: stat_sel = n_cyc_fill;
      3'd4: stat_sel = n_cyc_tseq;
      3'd5: stat_sel = n_cyc_any;
      default: stat_sel = {NCH[15:0], LDEPTH[7:0], SDEPTH[7:0], 16'h4D52};  // 'MR'
    endcase
  end

  // pipeline in motion: steps addressed but not yet packed, or a partial word held
  wire pipe_busy = s1_valid || s2_final || q_busy || pk_valid;

  assign busy = l_busy || t_busy || s_busy || pipe_busy;

  // fence: {err, overflow, pack fill[3:0], drain blocks left[15:0], inflight[7:0],
  //         pipe, drain busy, tseq busy, fill busy}
  wire [63:0] status = {16'd0, err_sticky, s_ovf, pk_fill[3:0], 2'd0,
                        s_left, l_inflight, 12'd0, pipe_busy, s_busy, t_busy, l_busy};

  assign resp_valid = (fen || sta) && cmd_xd;
  assign resp_data  = fen ? status : {16'd0, stat_sel};
endmodule
