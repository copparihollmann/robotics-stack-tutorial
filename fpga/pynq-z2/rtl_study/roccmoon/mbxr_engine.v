// SPDX-License-Identifier: Apache-2.0
//
// mbxr_engine -- the decoupled accelerator as it is built into silicon (ROCC_DECOUPLED.md 8).
//
// REVISION 2a (a proposal copy in rtl_study/roccmoon/rev2; the measured file is unchanged).
// Same ports, same instruction set, same driver protocol.  Three changes:
//   * ACKNOWLEDGED WATERMARK: fence bits 63:48 count the drain blocks every one of which has
//     had its AccessAck (mbxr_st); incremental placement reads below it (8.15.5).
//   * ONE DMA PER CLIENT (MEMORY_BANDWIDTH.md 9.9, P1): client W's DMA takes weight loads and
//     writes only the weight banks; client A's takes activation loads and writes only the
//     activation bank, through mbxd_spad2's two write ports.  One clock in 2a; 2b moves W's DMA
//     and write port to the memory-bus clock.  Loads still run one at a time (FILL covers both).
//   * THE WEIGHT HALF IS ITS OWN MODULE (mbxr_whalf: W's DMA, the plane mapper, the weight-bank
//     write port) with a clean port set -- clock, TileLink W master, write port, and a load
//     descriptor/status interface -- so revision 2b can place it in another clock domain
//     without editing inside it.  mbxr_engine_core is everything else; mbxr_engine (below)
//     joins the two on one clock with revision 1's exact port list.
//   * PROTOCOL CHECKS, sticky in the fence's error bit, the command refused:
//       - a load whose mode does not match its client (weights on A, activations on W);
//       - a load into the buffer the running tile reads (the double-buffer rule the
//         cross-clock scratchpad relies on);
//       - mm on a buffer a load is still filling.
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
//   5      st    0   dst_base[39:0]                          {stride[63:32], row_bytes[31:16], nrows[15:0]}
//                    nrows IS IN rs2[15:0] SO A PRE-002E ENGINE, WHICH READS EXACTLY THOSE BITS AS
//                    nblocks AND IGNORES THE REST, SEES A FLAT DESCRIPTOR MEAN THE SAME THING.
//   6      fence 1   -                                       -        rd = status
//   7      stat  1   counter index[2:0]                      clear[0] rd = counter
//   8      cap   0   -                                       max outstanding Gets [3:0]

module mbxr_engine_core #(
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

  // ---- the weight half (mbxr_whalf); in revision 2b it sits in the memory-bus domain ---
  output wire        wh_start,       // a weight load accepted: one cycle
  output wire [39:0] wh_base,
  output wire [15:0] wh_rblk,
  output wire [15:0] wh_rows,
  output wire [31:0] wh_stride,
  output wire        wh_fbuf,        // held from wh_start until the next accepted weight load
  output wire [3:0]  wh_lgpw,
  output wire [3:0]  wh_cap,
  input  wire        wh_busy,
  input  wire [7:0]  wh_inflight,
  input  wire        wh_beat,        // one word delivered by W (counted as a fill beat)
  input  wire        wh_err,         // a TileLink error on W, or a word past NCH planes
  input  wire        ww_clk,         // the weight banks' write port
  input  wire        ww_en,
  input  wire [15:0] ww_word,
  input  wire [63:0] ww_data,

  // ---- client A: Gets and Puts -----------------------------------------------------------
  output wire        aa_valid,
  input  wire        aa_ready,
  output wire        aa_put,         // 1 = PutFullData beat, 0 = Get
  output wire [1:0]  aa_size,      // PutFullData size: 0 = 8 B, 1 = 16, 2 = 32, 3 = 64
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
  reg          lw_fbuf, la_fbuf;           // each DMA's destination buffer
  reg [3:0]    lw_lgpw;                    // weight planes: log2 words per plane
  reg [3:0]    l_cap;
  reg [15:0]   t_g, t_q, t_p, t_s;
  reg [AW-1:0] t_ab, t_wb;
  reg          t_abuf, t_wbuf;
  reg [31:0]   q_mult;
  reg [5:0]    q_shift;
  reg [7:0]    q_amin, q_amax;
  reg          err_sticky;

  wire lw_busy, la_busy, t_busy, s_busy;
  wire l_busy = lw_busy || la_busy;

  // ---- load and mm acceptance, and the protocol checks ------------------------------------
  wire ld_a      = cmd_rs1[18];
  wire ld_mode_bad = ld && (cmd_rs1[17] == ld_a);                     // weights must be on W
  wire ld_buf_bad  = ld && t_busy && (cmd_rs1[16] == (ld_a ? t_abuf : t_wbuf));
  wire ld_ok     = ld && !l_busy && !ld_mode_bad && !ld_buf_bad;
  wire ld_w      = ld_ok && !ld_a;
  wire ld_a_ok   = ld_ok && ld_a;
  // mm reads the buffers cfg named; neither may be under a fill
  wire mm_buf_bad = mm && ((lw_busy && lw_fbuf == t_wbuf) || (la_busy && la_fbuf == t_abuf));
  wire mm_ok      = mm && !mm_buf_bad;

  always @(posedge clk) begin
    if (rst) begin
      d_base <= 40'd0; d_rblk <= 16'd0; d_rows <= 16'd0; d_stride <= 32'd0;
      lw_fbuf <= 1'b0; la_fbuf <= 1'b0; lw_lgpw <= 4'd10;
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
      if (ld_w) begin
        lw_fbuf <= cmd_rs1[16];
        lw_lgpw <= cmd_rs1[11:8];
      end
      if (ld_a_ok) la_fbuf <= cmd_rs1[16];
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

  // ---- fill: one DMA per client -----------------------------------------------------------
  wire        la_rv, la_rr, la_we;
  wire [39:0] la_addr;
  wire [3:0]  la_src;
  wire [15:0] la_word;
  wire [63:0] la_wdata;
  wire [7:0]  lw_inflight, la_inflight;
  wire [7:0]  l_inflight = lw_inflight + la_inflight;

  assign lw_busy     = wh_busy;
  assign lw_inflight = wh_inflight;
  assign wh_start = ld_w;
  assign wh_base = d_base; assign wh_rblk = d_rblk; assign wh_rows = d_rows; assign wh_stride = d_stride;
  assign wh_fbuf = lw_fbuf; assign wh_lgpw = lw_lgpw; assign wh_cap = l_cap;

  mbxd_dma #(.DEPTH(LDEPTH), .LGBEATS(3)) u_dma_a (
    .clk(clk), .rst(rst), .start(ld_a_ok),
    .src_base(d_base), .row_blocks(d_rblk), .nrows(d_rows),
    .row_stride(d_stride), .dst_word(16'd0),
    .req_valid(la_rv), .req_ready(la_rr), .req_addr(la_addr), .req_source(la_src),
    .rsp_valid(ad_valid && !ad_ack), .rsp_ready(), .rsp_source(ad_source), .rsp_data(ad_data),
    .sp_we(la_we), .sp_word(la_word), .sp_data(la_wdata),
    .busy(la_busy), .inflight(la_inflight));

  wire allow_a = (la_inflight < {4'd0, l_cap});

  // activation mapper: port 0, one buffer of 2^AW words
  wire          pa_bad  = (la_word >> AW) != 16'd0;
  wire [15:0]   wa_word = {2'd0, 3'd0, la_fbuf, la_word[AW-1:0]};

  // ---- scratchpad ------------------------------------------------------------------------
  wire [NRD*16-1:0] rd_addr;
  wire [NRD*64-1:0] rd_data;

  mbxd_spad2 #(.NRD(NRD), .GRP(4), .DEPTH(512)) u_sp (
    .clk(clk), .rd_addr(rd_addr), .rd_data(rd_data),
    .wa_clk(clk), .wa_en(la_we && !pa_bad), .wa_word(wa_word), .wa_data(la_wdata),
    .ww_clk(ww_clk), .ww_en(ww_en), .ww_word(ww_word), .ww_data(ww_data));

  // ---- sequencer -------------------------------------------------------------------------
  wire [AW-1:0] a_addr, w_addr;
  wire          s0_valid, s0_clr, s0_last, hold;

  mbxr_tseq #(.NCH(NCH), .AW(AW)) u_ts (
    .clk(clk), .rst(rst), .start(mm_ok),
    .ngroups(t_g), .nquads(t_q), .npix(t_p), .astride(t_s),
    .act_base(t_ab), .wgt_base(t_wb), .hold(hold), .wpack(1'b0),
    .a_addr(a_addr), .w_addr(w_addr),
    .s0_valid(s0_valid), .s0_clr(s0_clr), .s0_last(s0_last), .s0_ph(), .busy(t_busy));

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
  wire [15:0] s_left, s_acked;
  wire [1:0]  s_size;
  wire        s_dbad;

  mbxr_st #(.DEPTH(SDEPTH), .LGFIFO(5), .MARGIN(4)) u_st (
    .clk(clk), .rst(rst), .start(st),
    .dst_base(cmd_rs1[39:0]), .row_bytes(cmd_rs2[31:16]), .nrows(cmd_rs2[15:0]),
    .row_stride(cmd_rs2[63:32]),
    .in_valid(pk_valid), .in_data(pk_word),
    .almost_full(hold), .overflow(s_ovf), .desc_bad(s_dbad),
    .req_valid(s_rv), .req_ready(s_rr), .req_addr(s_addr), .req_size(s_size),
    .req_source(s_src),
    .req_data(s_data), .req_last(s_last),
    .rsp_valid(ad_valid && ad_ack && (ad_source >= LDEPTH)),
    .rsp_source(ad_source - LDEPTH[3:0]),
    .busy(s_busy), .left_rows(s_left), .acked_blocks(s_acked));

  // ---- A-channel routing -----------------------------------------------------------------
  // Loads win on A: a stalled load stalls the array, a stalled store stalls nothing until
  // the FIFO fills.  A store burst, once started, holds the grant for its eight beats.
  reg st_hold;
  wire l_on_a = la_rv && allow_a;
  wire st_grant = st_hold || (!l_on_a && s_rv);
  always @(posedge clk) begin
    if (rst) st_hold <= 1'b0;
    else if (s_rv && s_rr) st_hold <= !s_last;
  end


  assign aa_valid  = st_grant ? s_rv : l_on_a;
  assign aa_put    = st_grant;
  assign aa_size   = st_grant ? s_size : 2'd3;   // a Get is always a 64-byte block
  assign aa_addr   = st_grant ? s_addr : la_addr;
  assign aa_source = st_grant ? (s_src + LDEPTH[3:0]) : la_src;
  assign aa_data   = s_data;
  assign aa_last   = st_grant ? s_last : 1'b1;

  assign la_rr = allow_a && aa_ready && !st_grant;
  assign s_rr = aa_ready && st_grant;

  // ---- counters --------------------------------------------------------------------------
  reg [47:0] n_fill_beats, n_drain_beats, n_steps, n_cyc_fill, n_cyc_tseq, n_cyc_any;
  wire clr_stats = sta && cmd_rs2[0];
  always @(posedge clk) begin
    if (rst || clr_stats) begin
      n_fill_beats <= 48'd0; n_drain_beats <= 48'd0; n_steps <= 48'd0;
      n_cyc_fill <= 48'd0; n_cyc_tseq <= 48'd0; n_cyc_any <= 48'd0; err_sticky <= 1'b0;
    end else begin
      n_fill_beats <= n_fill_beats + {47'd0, wh_beat} + {47'd0, la_we};
      if (s_rv && s_rr)   n_drain_beats <= n_drain_beats + 48'd1;
      if (s0_valid)       n_steps       <= n_steps + 48'd1;
      if (l_busy)         n_cyc_fill    <= n_cyc_fill + 48'd1;
      if (t_busy)         n_cyc_tseq    <= n_cyc_tseq + 48'd1;
      if (busy)           n_cyc_any     <= n_cyc_any + 48'd1;
      if (wh_err || (ad_valid && ad_error) || (la_we && pa_bad) ||
          s_ovf || s_dbad || ld_mode_bad || ld_buf_bad || mm_buf_bad)
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
      default: stat_sel = {NCH[15:0], LDEPTH[7:0], SDEPTH[7:0], 16'h4D53};  // 'MR'
    endcase
  end

  // pipeline in motion: steps addressed but not yet packed, or a partial word held
  wire pipe_busy = s1_valid || s2_final || q_busy || pk_valid;

  assign busy = l_busy || t_busy || s_busy || pipe_busy;

  // fence: {drain blocks acknowledged[15:0] (revision 2), err, overflow, pack fill[3:0],
  //         drain blocks left[15:0], inflight[7:0], pipe, drain busy, tseq busy, fill busy}
  wire [63:0] status = {s_acked, err_sticky, s_ovf, pk_fill[3:0], 2'd0,
                        s_left, l_inflight, 12'd0, pipe_busy, s_busy, t_busy, l_busy};

  assign resp_valid = (fen || sta) && cmd_xd;
  assign resp_data  = fen ? status : {16'd0, stat_sel};
endmodule


// ---- the weight half: W's DMA, the weight plane mapper, the weight-bank write port ------------
// Every signal here is on `clk`.  In revision 2a that is the engine clock; in 2b the SoC gives
// it the memory-bus clock and the load descriptor/status crossing (P3) sits at this boundary.
module mbxr_whalf #(
  parameter NCH    = 4,
  parameter LDEPTH = 4
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  input  wire [39:0] base,
  input  wire [15:0] rblk,
  input  wire [15:0] rows,
  input  wire [31:0] stride,
  input  wire        fbuf,
  input  wire [3:0]  lgpw,
  input  wire [3:0]  cap,
  output wire        busy,
  output wire [7:0]  inflight,
  output wire        beat,
  output wire        err,
  output wire        wa_valid,
  input  wire        wa_ready,
  output wire [39:0] wa_addr,
  output wire [3:0]  wa_source,
  input  wire        wd_valid,
  input  wire [3:0]  wd_source,
  input  wire [63:0] wd_data,
  input  wire        wd_error,
  output wire        ww_en,
  output wire [15:0] ww_word,
  output wire [63:0] ww_data
);
  localparam AW = 10;
  wire        rv, rr, we;
  wire [15:0] word;

  mbxd_dma #(.DEPTH(LDEPTH), .LGBEATS(3)) u_dma (
    .clk(clk), .rst(rst), .start(start),
    .src_base(base), .row_blocks(rblk), .nrows(rows), .row_stride(stride), .dst_word(16'd0),
    .req_valid(rv), .req_ready(rr), .req_addr(wa_addr), .req_source(wa_source),
    .rsp_valid(wd_valid), .rsp_ready(), .rsp_source(wd_source), .rsp_data(wd_data),
    .sp_we(we), .sp_word(word), .sp_data(ww_data),
    .busy(busy), .inflight(inflight));

  wire allow = (inflight < {4'd0, cap});
  assign wa_valid = rv && allow;
  assign rr       = allow && wa_ready;

  // flat word index -> {port 1..NCH, buffer, bank bit, word}
  wire [15:0]   pr    = word >> lgpw;
  wire [15:0]   pmask = (16'd1 << lgpw) - 16'd1;
  wire [AW-1:0] poff  = word[AW-1:0] & pmask[AW-1:0];
  wire [2:0]    pport = pr[2:0] + 3'd1;
  wire          pbad  = (pr >= NCH);
  assign ww_word = {2'd0, pport, fbuf, poff};
  assign ww_en   = we && !pbad;
  assign beat    = we;
  assign err     = (wd_valid && wd_error) || (we && pbad);
endmodule

// ---- revision 2a as one module, with revision 1's port list ------------------------------------
module mbxr_engine #(
  parameter NCH    = 4,
  parameter LDEPTH = 4,
  parameter SDEPTH = 2
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cmd_valid,
  input  wire [6:0]  cmd_funct,
  input  wire [63:0] cmd_rs1,
  input  wire [63:0] cmd_rs2,
  input  wire        cmd_xd,
  output wire        resp_valid,
  output wire [63:0] resp_data,
  output wire        busy,
  output wire        wa_valid,
  input  wire        wa_ready,
  output wire [39:0] wa_addr,
  output wire [3:0]  wa_source,
  input  wire        wd_valid,
  input  wire [3:0]  wd_source,
  input  wire [63:0] wd_data,
  input  wire        wd_error,
  output wire        aa_valid,
  input  wire        aa_ready,
  output wire        aa_put,
  output wire [1:0]  aa_size,      // PutFullData size: 0 = 8 B, 1 = 16, 2 = 32, 3 = 64
  output wire [39:0] aa_addr,
  output wire [3:0]  aa_source,
  output wire [63:0] aa_data,
  output wire        aa_last,
  input  wire        ad_valid,
  input  wire        ad_ack,
  input  wire [3:0]  ad_source,
  input  wire [63:0] ad_data,
  input  wire        ad_error
);
  wire        wh_start, wh_fbuf, wh_busy, wh_beat, wh_err, ww_en;
  wire [39:0] wh_base;
  wire [15:0] wh_rblk, wh_rows, ww_word;
  wire [31:0] wh_stride;
  wire [3:0]  wh_lgpw, wh_cap;
  wire [7:0]  wh_inflight;
  wire [63:0] ww_data;

  mbxr_engine_core #(.NCH(NCH), .LDEPTH(LDEPTH), .SDEPTH(SDEPTH)) u_core (
    .clk(clk), .rst(rst), .cmd_valid(cmd_valid), .cmd_funct(cmd_funct), .cmd_rs1(cmd_rs1),
    .cmd_rs2(cmd_rs2), .cmd_xd(cmd_xd), .resp_valid(resp_valid), .resp_data(resp_data), .busy(busy),
    .wh_start(wh_start), .wh_base(wh_base), .wh_rblk(wh_rblk), .wh_rows(wh_rows), .wh_stride(wh_stride),
    .wh_fbuf(wh_fbuf), .wh_lgpw(wh_lgpw), .wh_cap(wh_cap), .wh_busy(wh_busy), .wh_inflight(wh_inflight),
    .wh_beat(wh_beat), .wh_err(wh_err), .ww_clk(clk), .ww_en(ww_en), .ww_word(ww_word), .ww_data(ww_data),
    .aa_valid(aa_valid), .aa_ready(aa_ready), .aa_put(aa_put), .aa_size(aa_size), .aa_addr(aa_addr), .aa_source(aa_source),
    .aa_data(aa_data), .aa_last(aa_last), .ad_valid(ad_valid), .ad_ack(ad_ack), .ad_source(ad_source),
    .ad_data(ad_data), .ad_error(ad_error));

  mbxr_whalf #(.NCH(NCH), .LDEPTH(LDEPTH)) u_whalf (
    .clk(clk), .rst(rst), .start(wh_start), .base(wh_base), .rblk(wh_rblk), .rows(wh_rows),
    .stride(wh_stride), .fbuf(wh_fbuf), .lgpw(wh_lgpw), .cap(wh_cap), .busy(wh_busy),
    .inflight(wh_inflight), .beat(wh_beat), .err(wh_err), .wa_valid(wa_valid), .wa_ready(wa_ready),
    .wa_addr(wa_addr), .wa_source(wa_source), .wd_valid(wd_valid), .wd_source(wd_source),
    .wd_data(wd_data), .wd_error(wd_error), .ww_en(ww_en), .ww_word(ww_word), .ww_data(ww_data));
endmodule
