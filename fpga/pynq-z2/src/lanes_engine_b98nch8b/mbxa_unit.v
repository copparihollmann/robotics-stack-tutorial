// SPDX-License-Identifier: Apache-2.0
//
// mbxa_unit -- the attention unit of ROCC_DECOUPLED.md s8.14's T2, out of context.
// AN OUT-OF-CONTEXT STUDY (ATTENTION_UNIT.md).  No SoC, no MAGIC, no bitstream.
//
// It computes ONE HEAD of Moonshine's self-attention per dispatch: T query rows of
// q.k^T, softmax, and p.v, with the scores never leaving the block.  It is designed to be
// merged INTO mbxr_engine rather than to stand beside it, and it therefore adds nothing
// that the engine already has:
//
//   REUSED UNCHANGED   mbxr_mac (the 32 MAC/cycle array), mbxd_spad2 (80 KB, 20 BRAM36),
//                      both mbxd_dma fill paths, mbxr_st (the drain), and mbxr_smx (the
//                      softmax lane of s8.15.8, instantiated verbatim).
//   ADDED             this sequencer and its two-phase FSM, mbxa_rq (the requantiser that
//                      matmul_b_s8 needs and mbxr_quant is not), the score serialiser, the
//                      p ring, and the byte packer.
//
// WHY NO K/V RAM.  Per (layer, head) Moonshine's q, k and v are 5,940 bytes each.  Padded
// into the engine's own layouts that is q = 825 of the activation port's 1,024 live words,
// and k + v^T = 450 of the 512 words each weight plane holds.  ONE HEAD FITS IN THE
// ENGINE'S EXISTING SCRATCHPAD; a whole layer (8 heads = 102 kB against 32 kB) does not.
// So s8.14's 22 BRAM36 of dedicated storage buys nothing, and the dispatch granularity is
// one head.
//
// THE OPERAND LAYOUTS, which software stages (ATTENTION_UNIT.md s1.5).  k needs no
// transpose -- the IR has transpose_b = 1 on .qk, so key row j is already contiguous along
// d.  v does, because .av has transpose_b = 0 and reads v by column; today's
// pext_dot8_exact kernel already gathers exactly that, so it is a relabel, not a new cost.
//
//   activation buffer   q[t] at qbase + t*gs, gs words, tail bytes past K ZEROED
//   weight plane c      scores: qs quads of [ bias word = 0 | gs words of k row 4j+c ]
//                          at kbase
//                       p.v:    qp quads of [ bias word = 0 | gp words of v^T row 4j+c ]
//                          at vtbase
//
// The bias word is ZERO, which is the whole reason mbxr_mac needs no edit: its existing
// `clr` step loads acc[c] <= w[c][31:0].  It costs one step per quad -- 12.8 % of the row
// time at Moonshine's shapes -- and buys a merge that touches nothing in the array.
//
// THE SCHEDULE.  The softmax lane's latency at K = 165 is 509 cycles, so the two phases are
// interleaved one row apart with a three-row lookahead:
//
//     S0 S1 S2 P0 S3 P1 S4 P2 ... S(T-1) P(T-3) P(T-2) P(T-1)
//
// In steady state that is gs-and-gp-bound with no softmax bubble.  p lives in a four-slot
// ring inside this block and is muxed onto the array's activation input during phase P, so
// the scratchpad needs no second write port.  Four slots suffice because the FSM never lets
// the score row run more than three ahead of the p.v row.
//
// THE THREE SURPLUS SCORES.  qs quads produce 4*qs >= N scores; only the first N (`nsc`) go
// to the softmax lane.  They are DROPPED, not zeroed: a zero score can be the row maximum,
// and the lane's K is N.  Same for `nout` on the p.v side.
//
// Configuration (cfg_we while idle; a write while busy sets err[1]):
//   0x000..0x0ff  softmax ex[d]      0x100 om   0x101 s   0x102 K (= nsc)   0x103 clear
//   0x200 qbase   0x201 kbase   0x202 vtbase
//   0x203 gs      0x204 qs      0x205 gp       0x206 qp
//   0x207 nrows   0x208 nsc     0x209 nout
//   0x20a mt (scores)   0x20b {amax[23:16], amin[15:8], sh[5:0]} (scores)
//   0x20c mt (p.v)      0x20d {amax, amin, sh} (p.v)
//   0x20e clear err[3:1]
// err[0] configuration unusable   err[1] written while busy
// err[2] |acc| >= 2^24 (outside the requantiser's exact domain)
// err[3] the softmax lane raised an error

`default_nettype none

// ---- the in-tile sequencer, one job at a time -----------------------------------------
// mbxr_tseq's loop with npix fixed at 1: for q in 0..Q-1 { step 0 = bias; steps 1..G }.
// Every address is a running counter plus a constant; no multiplier.
module mbxa_seq #(
  parameter AW = 10
) (
  input  wire          clk,
  input  wire          rst,
  input  wire          start,
  input  wire [7:0]    ngroups,      // G  >= 2
  input  wire [15:0]   nquads,       // Q  >= 1
  input  wire [AW-1:0] act_base,
  input  wire [AW-1:0] wgt_base,
  input  wire          hold,
  output wire [AW-1:0] a_addr,
  output wire [AW-1:0] w_addr,
  output wire          s0_valid,
  output wire          s0_clr,
  output wire          s0_last,
  output wire          busy
);
  reg          run;
  reg [7:0]    g, G_q;
  reg [15:0]   q, Q_q;
  reg [AW-1:0] a_base, a_ptr, w_ptr;

  wire last_g = (g == G_q);
  wire last_q = (q + 16'd1 == Q_q);
  wire go     = run && !hold;

  assign a_addr   = a_ptr;
  assign w_addr   = w_ptr;
  assign s0_valid = go;
  assign s0_clr   = (g == 8'd0);
  assign s0_last  = last_g;
  assign busy     = run;

  always @(posedge clk) begin
    if (rst) begin
      run <= 1'b0; g <= 8'd0; q <= 16'd0;
      G_q <= 8'd0; Q_q <= 16'd0;
      a_base <= {AW{1'b0}}; a_ptr <= {AW{1'b0}}; w_ptr <= {AW{1'b0}};
    end else if (start && !run) begin
      run    <= (ngroups != 8'd0) && (nquads != 16'd0);
      g      <= 8'd0; q <= 16'd0;
      G_q    <= ngroups; Q_q <= nquads;
      a_base <= act_base; a_ptr <= act_base;
      w_ptr  <= wgt_base;
    end else if (go) begin
      w_ptr <= w_ptr + 1'b1;
      if (!last_g) begin
        g <= g + 8'd1;
        if (g != 8'd0) a_ptr <= a_ptr + 1'b1;   // step 0 -> 1 keeps the row's first word
      end else begin
        g     <= 8'd0;
        a_ptr <= a_base;
        if (!last_q) q <= q + 16'd1;
        else         run <= 1'b0;
      end
    end
  end
endmodule


// ---- eight bytes into a little-endian word, with a zero-filled tail --------------------
// `in_last` closes the word INCLUDING the byte presented with it -- the softmax lane raises
// its last byte and its row end in the same cycle, and the next row's first byte can follow
// immediately, so a flush that waits a cycle would lose the tail and then mix two rows.
// `flush` closes a word with no byte, which is what the end of a whole dispatch needs.
module mbxa_pack8 (
  input  wire        clk,
  input  wire        rst,
  input  wire        in_valid,
  input  wire [7:0]  in_byte,
  input  wire        in_last,
  input  wire        flush,
  output reg         out_valid,
  output reg  [63:0] out_word
);
  reg  [63:0] sh;
  reg  [2:0]  cnt;
  wire [63:0] nsh = {in_byte, sh[63:8]};
  always @(posedge clk) begin
    out_valid <= 1'b0;
    if (rst) begin
      cnt <= 3'd0; sh <= 64'd0;
    end else if (in_valid) begin
      if (cnt == 3'd7) begin
        out_valid <= 1'b1;
        out_word  <= nsh;
        cnt       <= 3'd0;
        sh        <= 64'd0;
      end else if (in_last) begin
        out_valid <= 1'b1;
        // cnt + 1 bytes sit in the top of nsh; bring the oldest down to byte 0
        out_word  <= nsh >> {(3'd7 - cnt), 3'd0};
        cnt       <= 3'd0;
        sh        <= 64'd0;
      end else begin
        sh  <= nsh;
        cnt <= cnt + 3'd1;
      end
    end else if (flush && (cnt != 3'd0)) begin
      out_valid <= 1'b1;
      out_word  <= sh >> {(~cnt + 3'd1), 3'd0};
      cnt       <= 3'd0;
      sh        <= 64'd0;
    end
  end
endmodule


// ---- everything the engine does not already have --------------------------------------
module mbxa_core #(
  parameter NCH  = 4,          // B96: lanes in the engine's MAC array; acc is 32*NCH wide.
                               // DEFAULT 4, so every existing instantiation is unchanged.
  parameter AW   = 10,
  parameter PRAW = 7,          // log2 words in the p ring: four slots of gp, so gp <= 32
  parameter DIV_BPC = 6
) (
  input  wire          clk,
  input  wire          rst,
  // configuration and command
  input  wire          cfg_we,
  input  wire [9:0]    cfg_addr,
  input  wire [31:0]   cfg_wdata,
  input  wire          start,
  // to the array and the scratchpad
  output wire [AW-1:0] a_addr,
  output wire [AW-1:0] w_addr,
  output wire          s0_valid,
  output wire          s0_clr,
  output wire          s0_last,
  output wire          act_sel,      // 1 = take the activation word from p_rdata
  output wire [63:0]   p_rdata,
  // from the array
  input  wire [32*NCH-1:0] acc,
  input  wire          acc_valid,    // the engine's s2_final: acc holds a quad's NCH finals
  // to the drain
  output wire          out_valid,
  output wire [63:0]   out_data,
  input  wire          out_hold,     // mbxr_st's almost_full
  // status
  output wire          busy,
  output wire          idle,
  output wire [3:0]    err
);
  localparam PDEPTH = (1 << PRAW);            // PRAW is 3..8
  localparam [7:0] GPMAX = PDEPTH / 4;

  // forward declarations, so every net is explicit under `default_nettype none
  wire          seq_busy, pipe_busy, ser_hold, ser_v;
  reg  [31:0]   ser_word;
  wire          rq_v, rq_tag, rq_ovf;
  wire [7:0]    rq_y;
  wire          pw_v, p_row_done;
  wire [63:0]   pw_word;
  wire          ow_v, pad_v;
  wire [63:0]   ow_word;
  wire          go_s, go_p, fin;
  wire [PRAW-1:0] gp_w;

  // ======================================================================================
  // configuration
  // ======================================================================================
  reg  [AW-1:0] c_qbase, c_kbase, c_vtbase;
  reg  [7:0]    c_gs, c_gp;
  reg  [15:0]   c_qs, c_qp, c_rows, c_nsc, c_nout;
  localparam QSH = $clog2(NCH);        // bytes a quad produces = NCH = 1 << QSH
  reg  [23:0]   c_mt_s, c_mt_p;
  reg  [5:0]    c_sh_s, c_sh_p;
  reg  [7:0]    c_lo_s, c_hi_s, c_lo_p, c_hi_p;
  reg           e_busy, e_ovf;
  wire          smx_we = cfg_we & ~cfg_addr[9];

  // A job's Q quads produce NCH*Q bytes, and nsc / nout must fit inside that.  IT WAS 4Q --
  // `{c_qs[13:0], 2'd0}` -- until 2026-09-19, a baked-in NCH = 4 in the one module B96
  // parameterised for NCH, and the hardware half of the same contract the weight-image
  // builder states as `row 4j+c`.  At NCH = 8 it refuses every valid configuration.
  // QSH is $clog2(NCH), so at NCH = 4 this is the identical qs*4 comparison.  gp is capped so
  // four rows of p fit the ring.  G < 2 is refused: the serialiser needs a quad's finals at
  // least three cycles apart, and G + 1 is that spacing.
  wire cfg_ok = (c_gs >= 8'd2) && (c_gp >= 8'd2) && (c_gp <= GPMAX) &&
                (c_qs != 16'd0) && (c_qp != 16'd0) && (c_rows != 16'd0) &&
                (c_nsc != 16'd0) && (c_nout != 16'd0) &&
                ((({16'd0, c_qs} << QSH) >= {16'd0, c_nsc})) &&
                ((({16'd0, c_qp} << QSH) >= {16'd0, c_nout})) &&
                (c_qs[15:14] == 2'd0) && (c_qp[15:14] == 2'd0) &&
                (c_sh_s != 6'd0) && (c_sh_p != 6'd0);

  always @(posedge clk) begin
    if (rst) begin
      c_qbase <= {AW{1'b0}}; c_kbase <= {AW{1'b0}}; c_vtbase <= {AW{1'b0}};
      c_gs <= 8'd0; c_gp <= 8'd0; c_qs <= 16'd0; c_qp <= 16'd0;
      c_rows <= 16'd0; c_nsc <= 16'd0; c_nout <= 16'd0;
      c_mt_s <= 24'd0; c_mt_p <= 24'd0; c_sh_s <= 6'd0; c_sh_p <= 6'd0;
      c_lo_s <= 8'h80; c_hi_s <= 8'h7f; c_lo_p <= 8'h80; c_hi_p <= 8'h7f;
      e_busy <= 1'b0;
    end else if (cfg_we) begin
      if (!idle) e_busy <= 1'b1;
      case (cfg_addr)
        10'h200: c_qbase  <= cfg_wdata[AW-1:0];
        10'h201: c_kbase  <= cfg_wdata[AW-1:0];
        10'h202: c_vtbase <= cfg_wdata[AW-1:0];
        10'h203: c_gs     <= cfg_wdata[7:0];
        10'h204: c_qs     <= cfg_wdata[15:0];
        10'h205: c_gp     <= cfg_wdata[7:0];
        10'h206: c_qp     <= cfg_wdata[15:0];
        10'h207: c_rows   <= cfg_wdata[15:0];
        10'h208: c_nsc    <= cfg_wdata[15:0];
        10'h209: c_nout   <= cfg_wdata[15:0];
        10'h20a: c_mt_s   <= cfg_wdata[23:0];
        10'h20b: begin c_sh_s <= cfg_wdata[5:0]; c_lo_s <= cfg_wdata[15:8];
                       c_hi_s <= cfg_wdata[23:16]; end
        10'h20c: c_mt_p   <= cfg_wdata[23:0];
        10'h20d: begin c_sh_p <= cfg_wdata[5:0]; c_lo_p <= cfg_wdata[15:8];
                       c_hi_p <= cfg_wdata[23:16]; end
        10'h20e: e_busy   <= 1'b0;
        default: ;
      endcase
    end
  end
  /* verilator lint_off UNUSEDSIGNAL */   // gp8[7]: gp is capped at PDEPTH/4 <= 64
  wire [7:0] gp8 = c_gp;
  /* verilator lint_on UNUSEDSIGNAL */
  assign gp_w = gp8[PRAW-1:0];

  wire err_clr = cfg_we && (cfg_addr == 10'h20e);

  // ======================================================================================
  // the two-phase FSM
  // ======================================================================================
  reg             run, phase;
  reg  [15:0]     rs, rp, p_done;
  reg  [AW-1:0]   a_row;             // qbase + rs*gs, kept incrementally
  reg  [PRAW-1:0] p_rd;              // (rp mod 4) * gp, kept incrementally
  reg  [1:0]      p_rd_slot;

  wire can_start = run && !seq_busy && !pipe_busy;
  wire want_s    = (rs < c_rows) && ((rs - rp) < 16'd3);
  wire want_p    = (rp < rs) && (rp < p_done);
  assign go_s = can_start && want_s;
  assign go_p = can_start && !want_s && want_p;
  assign fin  = can_start && (rp == c_rows);

  wire [7:0]    j_g = go_s ? c_gs : c_gp;
  wire [15:0]   j_q = go_s ? c_qs : c_qp;
  wire [AW-1:0] j_a = go_s ? a_row : {{(AW-PRAW){1'b0}}, p_rd};
  wire [AW-1:0] j_w = go_s ? c_kbase : c_vtbase;

  always @(posedge clk) begin
    if (rst) begin
      run <= 1'b0; phase <= 1'b0; rs <= 16'd0; rp <= 16'd0; p_done <= 16'd0;
      a_row <= {AW{1'b0}}; p_rd <= {PRAW{1'b0}}; p_rd_slot <= 2'd0;
    end else if (start && !run && cfg_ok) begin
      run <= 1'b1; phase <= 1'b0; rs <= 16'd0; rp <= 16'd0; p_done <= 16'd0;
      a_row <= c_qbase; p_rd <= {PRAW{1'b0}}; p_rd_slot <= 2'd0;
    end else begin
      if (go_s) begin
        phase <= 1'b0;
        rs    <= rs + 16'd1;
        a_row <= a_row + {{(AW-8){1'b0}}, c_gs};
      end else if (go_p) begin
        phase     <= 1'b1;
        rp        <= rp + 16'd1;
        p_rd_slot <= p_rd_slot + 2'd1;
        p_rd      <= (p_rd_slot == 2'd3) ? {PRAW{1'b0}}
                                         : (p_rd + gp_w);
      end
      if (fin) run <= 1'b0;
      if (p_row_done) p_done <= p_done + 16'd1;
    end
  end

  mbxa_seq #(.AW(AW)) u_seq (
    .clk(clk), .rst(rst), .start(go_s | go_p),
    .ngroups(j_g), .nquads(j_q), .act_base(j_a), .wgt_base(j_w),
    .hold(out_hold | ser_hold | smx_hold),
    .a_addr(a_addr), .w_addr(w_addr),
    .s0_valid(s0_valid), .s0_clr(s0_clr), .s0_last(s0_last), .busy(seq_busy));

  assign act_sel = phase;

  // ======================================================================================
  // the accumulator serialiser: a quad's four 32-bit finals, one per cycle
  // ======================================================================================
  // Two slots.  At G >= 2 a quad's finals are G + 1 >= 3 cycles apart and serialising takes
  // four, so the second slot fills only at G = 2 and `ser_hold` never rises at Moonshine's
  // shapes (G = 5 and 21).  It exists so the block is correct at any G >= 2.
  localparam SCW = $clog2(NCH+1);             // B96: counts NCH..0, so 3 bits at NCH = 4
  reg  [32*NCH-1:0] sq0, sq1;
  reg          sv0, sv1;
  reg  [SCW-1:0] scnt;
  assign ser_hold = sv1;
  assign ser_v    = sv0;
  // scnt counts DOWN from NCH to 1, so final i sits at scnt == NCH - i.  Written as the
  // original's comparison chain rather than a variable part-select: the subtract that
  // `sq0[32*(NCH-scnt) +: 32]` implies cost +77 LUT AT NCH = 4, i.e. it was a regression on
  // the shipping configuration.  This form generates the identical 4:1 mux at NCH = 4.
  integer k;
  always @* begin
    ser_word = sq0[32*(NCH-1) +: 32];                        // the original's final `else`
    for (k = 0; k < NCH-1; k = k + 1)
      if (scnt == (NCH - k)) ser_word = sq0[32*k +: 32];
  end

  wire ser_take = sv0 && (scnt == {{SCW-1{1'b0}}, 1'b1});  // the last of the NCH leaves now
  always @(posedge clk) begin
    if (rst) begin
      sv0 <= 1'b0; sv1 <= 1'b0; scnt <= {SCW{1'b0}};
    end else begin
      if (ser_take) begin
        if (sv1) begin sq0 <= sq1; sv1 <= 1'b0; scnt <= NCH[SCW-1:0]; end
        else if (acc_valid) begin sq0 <= acc; scnt <= NCH[SCW-1:0]; end
        else begin sv0 <= 1'b0; scnt <= {SCW{1'b0}}; end
      end else if (sv0) begin
        scnt <= scnt - {{SCW-1{1'b0}}, 1'b1};
        if (acc_valid) begin sq1 <= acc; sv1 <= 1'b1; end
      end else if (acc_valid) begin
        sq0 <= acc; sv0 <= 1'b1; scnt <= NCH[SCW-1:0];
      end
    end
  end

  // ======================================================================================
  // the requantiser
  // ======================================================================================
  // Jobs never overlap in the pipeline (the FSM waits for it to drain), so the phase of the
  // quad being serialised is simply the running job's.
  mbxa_rq u_rq (
    .clk(clk), .rst(rst), .in_valid(ser_v), .acc(ser_word), .in_tag(phase),
    .mt(phase ? c_mt_p : c_mt_s), .sh(phase ? c_sh_p : c_sh_s),
    .amin(phase ? c_lo_p : c_lo_s), .amax(phase ? c_hi_p : c_hi_s),
    .out_valid(rq_v), .y(rq_y), .out_tag(rq_tag), .ovf(rq_ovf));

  // ======================================================================================
  // the score stream into the softmax lane, and the output stream into the packer
  // ======================================================================================
  reg  [15:0] sn, on;
  wire        sc_v    = rq_v && !rq_tag;
  wire        ou_v    = rq_v &&  rq_tag;
  wire        sc_ok   = sc_v && (sn < c_nsc);
  wire        ou_ok   = ou_v && (on < c_nout);
  wire        sc_last = sc_ok && (sn + 16'd1 == c_nsc);

  always @(posedge clk) begin
    if (rst) begin
      sn <= 16'd0; on <= 16'd0;
    end else begin
      if (go_s)      sn <= 16'd0;
      else if (sc_v) sn <= sn + 16'd1;
      if (go_p)      on <= 16'd0;
      else if (ou_v) on <= on + 16'd1;
    end
  end

  // A skid between the requantiser and the lane.  With this schedule the lane never holds
  // the source off -- at most three rows are in flight against its four-deep row queue and
  // its 2,048-byte ring, and once a row has started `in_ready` is unconditional -- but the
  // handshake is honoured rather than assumed: `smx_hold` stops the sequencer and the FIFO
  // absorbs what the nine pipeline stages behind it still deliver.  An overflow would be a
  // dropped score, so it is an error bit, not a comment.
  reg  [8:0] sf_mem [0:15];
  reg  [4:0] sf_wp, sf_rp;
  wire [4:0] sf_cnt  = sf_wp - sf_rp;
  wire       sf_full = sf_cnt[4];
  wire       sf_v    = (sf_wp != sf_rp);
  wire [8:0] sf_q    = sf_mem[sf_rp[3:0]];
  wire       smx_hold = (sf_cnt >= 5'd8);

  wire       smx_in_ready, smx_out_v, smx_out_last, smx_idle;
  wire [7:0] smx_out_d;
  wire [3:0] smx_err;
  wire       sf_pop = sf_v & smx_in_ready;
  always @(posedge clk) begin
    if (rst) begin
      sf_wp <= 5'd0; sf_rp <= 5'd0;
    end else begin
      if (sc_ok && !sf_full) begin
        sf_mem[sf_wp[3:0]] <= {sc_last, rq_y};
        sf_wp <= sf_wp + 5'd1;
      end
      if (sf_pop) sf_rp <= sf_rp + 5'd1;
    end
  end

  mbxr_smx #(.RAW(11), .DIV_BPC(DIV_BPC), .OFW(3)) u_smx (
    .clk(clk), .rst(rst),
    .cfg_we(smx_we), .cfg_addr(cfg_addr[8:0]), .cfg_wdata(cfg_wdata),
    .in_valid(sf_v), .in_ready(smx_in_ready), .in_data(sf_q[7:0]), .in_last(sf_q[8]),
    .out_valid(smx_out_v), .out_ready(1'b1), .out_data(smx_out_d), .out_last(smx_out_last),
    .idle(smx_idle), .err(smx_err));

  // ======================================================================================
  // the p ring: the lane's bytes packed into words, four rows deep
  // ======================================================================================
  mbxa_pack8 u_ppk (
    .clk(clk), .rst(rst), .in_valid(smx_out_v), .in_byte(smx_out_d),
    .in_last(smx_out_last), .flush(1'b0), .out_valid(pw_v), .out_word(pw_word));

  reg  [7:0]      p_wcnt;
  reg  [1:0]      p_wr_slot;
  reg  [PRAW-1:0] p_wr_base;
  wire [PRAW-1:0] p_wa = p_wr_base + p_wcnt[PRAW-1:0];
  assign p_row_done = pw_v && (p_wcnt + 8'd1 == c_gp);

  always @(posedge clk) begin
    if (rst || (start && !run)) begin
      p_wcnt <= 8'd0; p_wr_slot <= 2'd0; p_wr_base <= {PRAW{1'b0}};
    end else if (pw_v) begin
      if (p_wcnt + 8'd1 == c_gp) begin
        p_wcnt    <= 8'd0;
        p_wr_slot <= p_wr_slot + 2'd1;
        p_wr_base <= (p_wr_slot == 2'd3) ? {PRAW{1'b0}}
                                         : (p_wr_base + gp_w);
      end else begin
        p_wcnt <= p_wcnt + 8'd1;
      end
    end
  end

  (* ram_style = "distributed" *) reg [63:0] p_mem [0:PDEPTH-1];
  reg [63:0] p_q;
  always @(posedge clk) begin
    if (pw_v) p_mem[p_wa] <= pw_word;
    p_q <= p_mem[a_addr[PRAW-1:0]];
  end
  assign p_rdata = p_q;

  // ======================================================================================
  // the output stream: bytes to words, zero-padded to a 64-byte block at the end
  // ======================================================================================
  mbxa_pack8 u_opk (
    .clk(clk), .rst(rst), .in_valid(ou_ok), .in_byte(rq_y),
    .in_last(1'b0), .flush(fin), .out_valid(ow_v), .out_word(ow_word));

  reg [1:0] fst;                   // 0 running, 1 the flush word, 2 padding to a block
  reg [2:0] o_blk;
  assign pad_v     = (fst == 2'd2) && (o_blk != 3'd0) && !out_hold;
  assign out_valid = ow_v | pad_v;
  assign out_data  = ow_v ? ow_word : 64'd0;

  always @(posedge clk) begin
    if (rst || (start && !run)) begin
      fst <= 2'd0; o_blk <= 3'd0;
    end else begin
      if (out_valid) o_blk <= o_blk + 3'd1;
      case (fst)
        2'd0: if (fin) fst <= 2'd1;
        2'd1: fst <= 2'd2;
        default: if (o_blk == 3'd0) fst <= 2'd0;
      endcase
    end
  end

  // ======================================================================================
  // status
  // ======================================================================================
  // a step is in flight from the cycle it is addressed until its byte leaves the
  // requantiser: two cycles to the array's final accumulator, then the serialiser, then
  // five requantiser stages
  reg [1:0] s0_sh;
  reg [4:0] rq_sh;
  always @(posedge clk) begin
    if (rst) begin
      s0_sh <= 2'd0; rq_sh <= 5'd0;
    end else begin
      s0_sh <= {s0_sh[0], s0_valid};
      rq_sh <= {rq_sh[3:0], ser_v};
    end
  end
  assign pipe_busy = (|s0_sh) | sv0 | sv1 | (|rq_sh) | sf_v;

  // The p ring's invariant, checked rather than only argued: the FSM lets the score row run
  // at most three ahead of the p.v row, and p_done <= rs, so the softmax lane can never be
  // writing the slot phase P is reading.  A silent overwrite would be a wrong byte.
  reg e_drop, e_ring;
  always @(posedge clk) begin
    if (rst || err_clr) begin
      e_ovf <= 1'b0; e_drop <= 1'b0; e_ring <= 1'b0;
    end else begin
      if (rq_ovf)                       e_ovf  <= 1'b1;
      if (sc_ok && sf_full)             e_drop <= 1'b1;
      if (run && ((p_done - rp) > 16'd3)) e_ring <= 1'b1;
    end
  end

  assign err  = {(|smx_err) | e_drop | e_ring, e_ovf, e_busy, ~cfg_ok};
  assign busy = run | seq_busy | pipe_busy | (fst != 2'd0) | ~smx_idle;
  assign idle = ~busy;
endmodule


// ---- the unit: the core plus the array it drives ---------------------------------------
// mbxr_mac, mbxr_datapath.v's, verbatim.  The scratchpad read ports are module ports, so
// this is exactly what plugs into mbxr_engine beside its own tile sequencer.
module mbxa_unit #(
  parameter NCH  = 4,
  parameter AW   = 10,
  parameter PRAW = 7,
  parameter DIV_BPC = 6
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,
  input  wire [9:0]  cfg_addr,
  input  wire [31:0] cfg_wdata,
  input  wire        start,
  // the engine's scratchpad, addressed and read exactly as mbxr_engine addresses it
  output wire [(NCH+1)*16-1:0] rd_addr,
  input  wire [(NCH+1)*64-1:0] rd_data,
  input  wire        abuf,          // the activation buffer cfg named
  input  wire        wbuf,
  // the engine's drain
  output wire        out_valid,
  output wire [63:0] out_data,
  input  wire        out_hold,
  output wire        busy,
  output wire        idle,
  output wire [3:0]  err
);
  localparam NRD = NCH + 1;

  wire [AW-1:0] a_addr, w_addr;
  wire          s0_valid, s0_clr, s0_last, act_sel;
  wire [63:0]   p_rdata;
  wire [32*NCH-1:0] acc;

  assign rd_addr[0 +: 16] = {5'd0, abuf, a_addr};
  genvar gp;
  generate
    for (gp = 1; gp < NRD; gp = gp + 1) begin : g_wport
      assign rd_addr[gp*16 +: 16] = {5'd0, wbuf, w_addr};
    end
  endgenerate

  // the block RAM read is registered, so the select must be too
  reg s1_valid, s1_clr, s1_last, s1_sel;
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
    s1_sel <= act_sel;
  end

  wire [63:0] a_word = s1_sel ? p_rdata : rd_data[63:0];

  mbxr_mac #(.NCH(NCH)) u_mac (
    .clk(clk), .valid(s1_valid), .clr(s1_clr),
    .a(a_word), .w(rd_data[64*NRD-1:64]), .acc(acc));

  mbxa_core #(.NCH(NCH), .AW(AW), .PRAW(PRAW), .DIV_BPC(DIV_BPC)) u_core (
    .clk(clk), .rst(rst), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
    .start(start),
    .a_addr(a_addr), .w_addr(w_addr), .s0_valid(s0_valid), .s0_clr(s0_clr),
    .s0_last(s0_last), .act_sel(act_sel), .p_rdata(p_rdata),
    .acc(acc), .acc_valid(s2_final),
    .out_valid(out_valid), .out_data(out_data), .out_hold(out_hold),
    .busy(busy), .idle(idle), .err(err));
endmodule

`default_nettype wire

// ---- out-of-context wrappers -------------------------------------------------------------
// Every port registered, so the numbers are register to register.  (A registered ready/valid
// is not a protocol-correct wrapper; it exists only for timing, as smx_lane's does.)
//
//   mbxa_core_ooc   what the attention unit ADDS to mbxr_engine: the sequencer, the FSM, the
//                   requantiser, the serialiser, the softmax lane, the p ring and the
//                   packers.  This is the figure to compare with s8.14's estimate.
//   mbxa_unit_ooc   the same plus mbxr_mac, which the engine already has: a sanity check,
//                   not an area claim.
`default_nettype none

module mbxa_core_ooc #(
  parameter AW = 10,
  parameter PRAW = 7,
  parameter DIV_BPC = 6
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,
  input  wire [9:0]  cfg_addr,
  input  wire [31:0] cfg_wdata,
  input  wire        start,
  input  wire [127:0] acc,
  input  wire        acc_valid,
  input  wire        out_hold,
  output reg  [AW-1:0] a_addr,
  output reg  [AW-1:0] w_addr,
  output reg         s0_valid,
  output reg         s0_clr,
  output reg         s0_last,
  output reg         act_sel,
  output reg  [63:0] p_rdata,
  output reg         out_valid,
  output reg  [63:0] out_data,
  output reg         busy,
  output reg         idle,
  output reg  [3:0]  err
);
  reg         rst_q, cfg_we_q, start_q, acc_valid_q, out_hold_q;
  reg  [9:0]  cfg_addr_q;
  reg  [31:0] cfg_wdata_q;
  reg  [127:0] acc_q;
  wire [AW-1:0] w_a, w_w;
  wire        w_sv, w_sc, w_sl, w_as, w_ov, w_busy, w_idle;
  wire [63:0] w_p, w_od;
  wire [3:0]  w_err;
  always @(posedge clk) begin
    rst_q <= rst; cfg_we_q <= cfg_we; cfg_addr_q <= cfg_addr; cfg_wdata_q <= cfg_wdata;
    start_q <= start; acc_q <= acc; acc_valid_q <= acc_valid; out_hold_q <= out_hold;
    a_addr <= w_a; w_addr <= w_w; s0_valid <= w_sv; s0_clr <= w_sc; s0_last <= w_sl;
    act_sel <= w_as; p_rdata <= w_p; out_valid <= w_ov; out_data <= w_od;
    busy <= w_busy; idle <= w_idle; err <= w_err;
  end
  mbxa_core #(.AW(AW), .PRAW(PRAW), .DIV_BPC(DIV_BPC)) u (
    .clk(clk), .rst(rst_q), .cfg_we(cfg_we_q), .cfg_addr(cfg_addr_q),
    .cfg_wdata(cfg_wdata_q), .start(start_q),
    .a_addr(w_a), .w_addr(w_w), .s0_valid(w_sv), .s0_clr(w_sc), .s0_last(w_sl),
    .act_sel(w_as), .p_rdata(w_p), .acc(acc_q), .acc_valid(acc_valid_q),
    .out_valid(w_ov), .out_data(w_od), .out_hold(out_hold_q),
    .busy(w_busy), .idle(w_idle), .err(w_err));
endmodule

module mbxa_unit_ooc #(
  parameter NCH = 4,
  parameter AW = 10,
  parameter PRAW = 7,
  parameter DIV_BPC = 6
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,
  input  wire [9:0]  cfg_addr,
  input  wire [31:0] cfg_wdata,
  input  wire        start,
  input  wire [(NCH+1)*64-1:0] rd_data,
  input  wire        abuf,
  input  wire        wbuf,
  input  wire        out_hold,
  output reg  [(NCH+1)*16-1:0] rd_addr,
  output reg         out_valid,
  output reg  [63:0] out_data,
  output reg         busy,
  output reg         idle,
  output reg  [3:0]  err
);
  reg         rst_q, cfg_we_q, start_q, abuf_q, wbuf_q, out_hold_q;
  reg  [9:0]  cfg_addr_q;
  reg  [31:0] cfg_wdata_q;
  reg  [(NCH+1)*64-1:0] rd_data_q;
  wire [(NCH+1)*16-1:0] w_ra;
  wire        w_ov, w_busy, w_idle;
  wire [63:0] w_od;
  wire [3:0]  w_err;
  always @(posedge clk) begin
    rst_q <= rst; cfg_we_q <= cfg_we; cfg_addr_q <= cfg_addr; cfg_wdata_q <= cfg_wdata;
    start_q <= start; rd_data_q <= rd_data; abuf_q <= abuf; wbuf_q <= wbuf;
    out_hold_q <= out_hold;
    rd_addr <= w_ra; out_valid <= w_ov; out_data <= w_od;
    busy <= w_busy; idle <= w_idle; err <= w_err;
  end
  mbxa_unit #(.NCH(NCH), .AW(AW), .PRAW(PRAW), .DIV_BPC(DIV_BPC)) u (
    .clk(clk), .rst(rst_q), .cfg_we(cfg_we_q), .cfg_addr(cfg_addr_q),
    .cfg_wdata(cfg_wdata_q), .start(start_q),
    .rd_addr(w_ra), .rd_data(rd_data_q), .abuf(abuf_q), .wbuf(wbuf_q),
    .out_valid(w_ov), .out_data(w_od), .out_hold(out_hold_q),
    .busy(w_busy), .idle(w_idle), .err(w_err));
endmodule

`default_nettype wire
