// axiceil_port -- one raw AXI3 master for one Zynq S_AXI_HP port: the ceiling instrument.
//
// MEMORY_BANDWIDTH.md section 7.  Derived from src/axi_dram_selftest.v (the day-one HP0
// self-test: position-dependent pattern, write then verify, AXI3 written directly), which
// is left untouched because other builds gate on its simulation.  What this adds is what
// that one deliberately left out, "correctness of the path is the question here, not
// bandwidth":
//
//   * concurrent transactions by ID.  Up to 16 outstanding per direction (AXI ID 0..15 of
//     the HP port's 6 bits).  The AFI's own issuing capability is 3 bits -- at most 8
//     commands in flight to the DDR controller (sw_param.xml, AFI_RDCHAN_ISSUINGCAP) --
//     so 16 is enough to see it bind.  Responses may come back in any order and read data
//     of different IDs may interleave; every beat is checked against its own ID's state.
//   * burst length 1..16 beats (AXI3's limit), per run.
//   * reads, writes, or both at once, into separate regions.
//   * a MEASUREMENT WINDOW counted in fabric cycles.  The master issues for exactly
//     `in_win` cycles, counts beats that cross the port during them, then drains.  B/cycle
//     is beats*8 / window from silicon; MB/s needs only the (read-back) clock.  All ports of
//     a multi-port run share one window, so an aggregate is simultaneous, not summed.
//   * the data check is kept: every R beat is compared with pattern(address, seed); a seed
//     per region makes a stale read from an earlier run a mismatch, not a pass.
//   * diagnostic counters that say WHAT BINDS: AR/AW/W backpressure, cycles the PS left R
//     idle while commands were outstanding, cycles the fabric failed to present W data,
//     average outstanding, and the AFI's own FIFO occupancy sidebands (RACOUNT, RCOUNT,
//     WACOUNT, WCOUNT) summed and peaked over the window.
//
// v2 (build 2) moves configuration, wrap limits, ID allocation (one-hot) and the per-ID
// write-back off the per-transaction paths, and splits the read check over four stages.  The
// behaviour at the port is unchanged; axiceil_guard now registers AW/AR and core registers W.
//
// rready and bready are tied high: the fabric never backpressures the PS, so a read
// ceiling is the PS's delivery, or one beat per fabric cycle, whichever is lower -- and
// the counters say which.
//
// ADDRESS SAFETY is not this module's job alone: every AW and AR also passes through
// axiceil_guard, a separate hard check on the one window this board lets the PL write.
// This module refuses to start a direction whose configured region is outside it too, so a
// host mistake is a status bit rather than a guard fault -- but the guard does not trust it.

module axiceil_port #(
  parameter [31:0] REGION_LO = 32'h1000_0000,   // inclusive
  parameter [32:0] REGION_HI = 33'h0_2000_0000, // exclusive
  parameter integer CW = 40                     // counter width
)(
  input  wire         clk,
  input  wire         rst,            // synchronous, active high

  // run control (from axiceil_core)
  input  wire         start,          // one-cycle pulse; clears every counter
  input  wire         en,             // this port takes part in the run
  input  wire         abort,          // level: stop issuing now and drain
  input  wire         in_win,         // high for exactly WINDOW cycles after start

  // configuration: host-written, must be stable from start until !busy
  input  wire         cfg_rd_en,
  input  wire         cfg_wr_en,
  input  wire [3:0]   cfg_len_m1,     // AXI3 AxLEN: beats-1
  input  wire [4:0]   cfg_k_rd,       // outstanding read transactions, 1..16 (0 reads as 1)
  input  wire [4:0]   cfg_k_wr,
  input  wire [31:0]  cfg_rd_base,
  input  wire [31:0]  cfg_rd_words,
  input  wire [31:0]  cfg_wr_base,
  input  wire [31:0]  cfg_wr_words,
  input  wire [31:0]  cfg_rd_seed,
  input  wire [31:0]  cfg_wr_seed,
  input  wire [31:0]  cfg_rd_maxb,    // stop after this many read bursts (0: window only)
  input  wire [31:0]  cfg_wr_maxb,
  input  wire         cfg_id_lo_only, // match responses on ID[3:0] only (diagnostic; default 0)

  // status
  output reg          busy = 1'b0,
  output reg          done = 1'b0,
  output reg          cfg_err_rd = 1'b0,
  output reg          cfg_err_wr = 1'b0,
  output reg          wq_ovf = 1'b0,
  output reg [CW-1:0] rd_beats_win = 0, wr_beats_win = 0, b_beats_win = 0,
  output reg [CW-1:0] rd_beats_tot = 0, b_beats_tot = 0,
  output reg [31:0]   rd_err = 0, rd_proto = 0, wr_err = 0, wr_proto = 0,
  output reg [31:0]   rd_bursts = 0, wr_bursts = 0,
  output reg [31:0]   ar_stall_win = 0, aw_stall_win = 0, w_stall_win = 0,
  output reg [31:0]   r_gap_win = 0, w_idle_win = 0, drain_cycles = 0,
  output reg [CW-1:0] rd_out_sum = 0, wr_out_sum = 0,
  output reg [4:0]    rd_out_peak = 0, wr_out_peak = 0,
  output reg [CW-1:0] racount_sum = 0, rcount_sum = 0, wacount_sum = 0, wcount_sum = 0,
  output reg [2:0]    racount_max = 0,
  output reg [7:0]    rcount_max = 0,
  output reg [5:0]    wacount_max = 0,
  output reg [7:0]    wcount_max = 0,

  // live state, for a host that has to decide whether a stall is the master's or the PS's
  output wire [15:0]  live_rbusy,
  output wire [15:0]  live_wbusy,
  output wire [4:0]   live_rd_out,
  output wire [4:0]   live_wr_out,
  output wire [4:0]   live_wq_cnt,
  output wire         live_run_rd,
  output wire         live_run_wr,
  output reg  [6:0]   bad_rid = 7'd0,   // {seen, raw RID} of the first R beat no outstanding ID claimed
  output reg  [6:0]   bad_bid = 7'd0,   // {seen, raw BID} of the first unclaimed B

  // AXI3 master, 64-bit, toward axiceil_guard and S_AXI_HPn
  output reg  [5:0]   m_awid = 6'd0,
  output reg  [31:0]  m_awaddr = 32'd0,
  output reg  [3:0]   m_awlen = 4'd0,
  output reg          m_awvalid = 1'b0,
  input  wire         m_awready,
  output reg  [5:0]   m_wid = 6'd0,
  output reg  [63:0]  m_wdata = 64'd0,
  output reg          m_wlast = 1'b0,
  output reg          m_wvalid = 1'b0,
  input  wire         m_wready,
  input  wire [5:0]   m_bid,
  input  wire [1:0]   m_bresp,
  input  wire         m_bvalid,
  output wire         m_bready,
  output reg  [5:0]   m_arid = 6'd0,
  output reg  [31:0]  m_araddr = 32'd0,
  output reg  [3:0]   m_arlen = 4'd0,
  output reg          m_arvalid = 1'b0,
  input  wire         m_arready,
  input  wire [5:0]   m_rid,
  input  wire [63:0]  m_rdata,
  input  wire [1:0]   m_rresp,
  input  wire         m_rlast,
  input  wire         m_rvalid,
  output wire         m_rready,

  // backpressure AT THE PS PINS (after the guard's slice), for the stall counters
  input  wire         st_aw_hs,       // an AW handshake at the PS pins
  input  wire         st_ar_stall,
  input  wire         st_aw_stall,
  input  wire         st_w_stall,

  // AFI FIFO occupancy sidebands (S_AXI_HPn_RACOUNT/RCOUNT/WACOUNT/WCOUNT)
  input  wire [2:0]   sb_racount,
  input  wire [7:0]   sb_rcount,
  input  wire [5:0]   sb_wacount,
  input  wire [7:0]   sb_wcount
);
  assign m_rready = 1'b1;
  assign m_bready = 1'b1;

  // The data every word in DDR should hold: a function of its ADDRESS and the region's
  // seed, so the checker needs no golden copy, a beat read from the wrong address fails,
  // and a region last written under another seed fails.
  function [63:0] pattern(input [28:0] addrw, input [31:0] seed);
    reg [31:0] x;
    begin
      x = {3'b000, addrw} ^ seed;
      pattern = {~x, x ^ 32'h5A5A_C3C3};
    end
  endfunction

  // ---------------------------------------------------------------- configuration
  // Everything below uses REGISTERED copies of the configuration, and every quantity that is
  // a function of configuration alone is precomputed here, off the per-transaction paths.
  // The host writes configuration long before it starts a run, so a few cycles of lag cost
  // nothing.  (Build 1 closed at 7.402 ns with exactly these as its worst paths.)
  reg [3:0]  q_len_m1 = 4'd0;
  reg [31:0] q_rd_base = 0, q_rd_words = 0, q_wr_base = 0, q_wr_words = 0;
  reg [31:0] q_rd_seed = 0, q_wr_seed = 0, q_rd_maxb = 0, q_wr_maxb = 0;
  reg [4:0]  L = 5'd1;
  reg [8:0]  bpp_m1 = 9'd511;                 // bursts per 4 KiB page, minus one
  reg [19:0] rd_pages_m1 = 0, wr_pages_m1 = 0; // pages in the region, minus one
  reg        rd_cfg_ok = 1'b0, wr_cfg_ok = 1'b0;
  reg [32:0] rd_end = 0, wr_end = 0;
  reg [15:0] rd_lim = 16'h0001, wr_lim = 16'h0001;
  reg        rd_maxb_nz = 1'b0, wr_maxb_nz = 1'b0;
  always @(posedge clk) begin
    q_len_m1 <= cfg_len_m1;
    q_rd_base <= cfg_rd_base; q_rd_words <= cfg_rd_words; q_wr_base <= cfg_wr_base; q_wr_words <= cfg_wr_words;
    q_rd_seed <= cfg_rd_seed; q_wr_seed <= cfg_wr_seed; q_rd_maxb <= cfg_rd_maxb; q_wr_maxb <= cfg_wr_maxb;
    L <= {1'b0, q_len_m1} + 5'd1;
    // PAGES (v5).  AXI forbids a burst crossing a 4 KiB boundary.  A region is a whole number of
    // 4 KiB pages starting on a page boundary, and each page holds floor(512 / L) bursts laid
    // out from its start; words a length leaves at the end of a page are skipped.  So every
    // length 1..16 is legal, and a region read back with the length it was written with covers
    // exactly the words that were written.
    case (L)
      5'd1: bpp_m1 <= 9'd511;  5'd2: bpp_m1 <= 9'd255;  5'd3: bpp_m1 <= 9'd169;  5'd4: bpp_m1 <= 9'd127;
      5'd5: bpp_m1 <= 9'd101;  5'd6: bpp_m1 <= 9'd84;   5'd7: bpp_m1 <= 9'd72;   5'd8: bpp_m1 <= 9'd63;
      5'd9: bpp_m1 <= 9'd55;   5'd10: bpp_m1 <= 9'd50;  5'd11: bpp_m1 <= 9'd45;  5'd12: bpp_m1 <= 9'd41;
      5'd13: bpp_m1 <= 9'd38;  5'd14: bpp_m1 <= 9'd35;  5'd15: bpp_m1 <= 9'd33;  default: bpp_m1 <= 9'd31;
    endcase
    rd_pages_m1 <= q_rd_words[28:9] - 20'd1;
    wr_pages_m1 <= q_wr_words[28:9] - 20'd1;
    rd_end <= {1'b0, q_rd_base} + {q_rd_words[29:0], 3'b000};
    wr_end <= {1'b0, q_wr_base} + {q_wr_words[29:0], 3'b000};
    rd_cfg_ok <= (q_rd_base >= REGION_LO) && (rd_end <= REGION_HI) && (q_rd_base[11:0] == 12'd0)
                 && (q_rd_words[31:29] == 3'd0) && (q_rd_words[8:0] == 9'd0) && (q_rd_words[28:9] != 20'd0);
    wr_cfg_ok <= (q_wr_base >= REGION_LO) && (wr_end <= REGION_HI) && (q_wr_base[11:0] == 12'd0)
                 && (q_wr_words[31:29] == 3'd0) && (q_wr_words[8:0] == 9'd0) && (q_wr_words[28:9] != 20'd0);
    rd_maxb_nz <= (q_rd_maxb != 32'd0);
    wr_maxb_nz <= (q_wr_maxb != 32'd0);
    rd_lim <= (cfg_k_rd >= 5'd16) ? 16'hFFFF : ((cfg_k_rd == 5'd0) ? 16'h0001 : ((16'd1 << cfg_k_rd) - 16'd1));
    wr_lim <= (cfg_k_wr >= 5'd16) ? 16'hFFFF : ((cfg_k_wr == 5'd0) ? 16'h0001 : ((16'd1 << cfg_k_wr) - 16'd1));
  end

  // one-hot index of a 16-bit one-hot vector
  function [3:0] enc16(input [15:0] oh);
    integer i;
    begin
      enc16 = 4'd0;
      for (i = 0; i < 16; i = i + 1)
        if (oh[i]) enc16 = enc16 | i[3:0];
    end
  endfunction

  reg run_rd = 1'b0, run_wr = 1'b0;

  // ====================================================================== read direction
  reg  [15:0] rbusy = 16'd0;
  reg  [28:0] rcur [0:15];        // absolute word address of each ID's FIRST beat
  reg  [4:0]  rbeat [0:15];       // beats seen in each ID's current burst
  reg  [4:0]  rd_out = 5'd0;      // loaded, not yet fully answered
  reg  [19:0] r_page = 20'd0;     // next burst's page in the region
  reg  [8:0]  r_pb = 9'd0;        // ... its index within that page
  reg  [28:0] r_page_w = 29'd0;   // ... the page's first word address
  reg  [28:0] r_addrw = 29'd0;    // ... and the burst's own word address
  integer ii;
  initial for (ii = 0; ii < 16; ii = ii + 1) begin rcur[ii] = 29'd0; rbeat[ii] = 5'd0; end

  wire [15:0] r_free   = ~rbusy & rd_lim;
  wire [15:0] r_oh     = r_free & (~r_free + 16'd1);      // lowest free ID, one-hot
  wire        r_any    = |r_free;
  wire        r_maxhit = rd_maxb_nz && (rd_bursts == q_rd_maxb);
  wire        r_go     = run_rd & in_win & ~abort & ~r_maxhit;
  wire        r_load   = r_go & r_any & (~m_arvalid | m_arready);

  // R pipeline: S1 registers the port; S2 looks up the ID (a 5-bit write-back only);
  // S3 forms the expected word; S4 compares.
  reg         rv1 = 1'b0, rl1 = 1'b0, rwin1 = 1'b0;
  reg  [5:0]  rid1 = 6'd0;
  reg  [63:0] rd1 = 64'd0;
  reg  [1:0]  rr1 = 2'd0;
  reg         rv2 = 1'b0, rk2 = 1'b0, rl2 = 1'b0, rlx2 = 1'b0, rbad2 = 1'b0;
  reg  [28:0] rs2 = 29'd0;
  reg  [4:0]  rb2 = 5'd0;
  reg  [63:0] rd2 = 64'd0;
  reg         rv3 = 1'b0, rbad3 = 1'b0, rpro3 = 1'b0;
  reg  [63:0] rd3 = 64'd0, rp3 = 64'd0;

  wire [3:0]  s2_id    = rid1[3:0];
  wire        s2_known = rv1 & (cfg_id_lo_only | (rid1[5:4] == 2'd0)) & rbusy[s2_id];
  wire [4:0]  s2_beat  = rbeat[s2_id];
  wire        s2_free  = s2_known & rl1;

  always @(posedge clk) begin
    if (rst) begin
      rbusy <= 16'd0; rd_out <= 5'd0; m_arvalid <= 1'b0;
      rv1 <= 1'b0; rv2 <= 1'b0;
    end else begin
      // -- AR issue
      if (start) begin
        r_page <= 20'd0; r_pb <= 9'd0; r_page_w <= q_rd_base[31:3]; r_addrw <= q_rd_base[31:3];
      end else if (r_load) begin
        m_arvalid <= 1'b1;
        m_arid    <= {2'b00, enc16(r_oh)};
        m_araddr  <= {r_addrw, 3'b000};
        m_arlen   <= q_len_m1;
        if (r_pb != bpp_m1) begin
          r_pb <= r_pb + 9'd1; r_addrw <= r_addrw + {24'd0, L};
        end else if (r_page != rd_pages_m1) begin
          r_pb <= 9'd0; r_page <= r_page + 20'd1;
          r_page_w <= r_page_w + 29'd512; r_addrw <= r_page_w + 29'd512;
        end else begin
          r_pb <= 9'd0; r_page <= 20'd0; r_page_w <= q_rd_base[31:3]; r_addrw <= q_rd_base[31:3];
        end
      end else if (m_arvalid && m_arready) begin
        m_arvalid <= 1'b0;
      end
      if (start) rbusy <= 16'd0;
      else rbusy <= (rbusy | (r_load ? r_oh : 16'd0))
                          & ~(s2_free ? (16'd1 << s2_id) : 16'd0);
      if (start) rd_out <= 5'd0;
      else rd_out <= rd_out + {4'd0, r_load} - {4'd0, s2_free};

      // -- S1
      rv1 <= m_rvalid; rid1 <= m_rid; rd1 <= m_rdata; rl1 <= m_rlast; rr1 <= m_rresp;
      rwin1 <= in_win;
      // -- S2
      rv2 <= rv1; rd2 <= rd1; rk2 <= s2_known; rl2 <= rl1;
      rs2 <= rcur[s2_id]; rb2 <= s2_beat;
      rlx2 <= (s2_beat == {1'b0, q_len_m1});
      rbad2 <= (rr1 != 2'b00);
      // -- S3
      rv3 <= rv2; rd3 <= rd2;
      rp3 <= pattern(rs2 + {24'd0, rb2}, q_rd_seed);
      rbad3 <= rbad2 | ~rk2;
      rpro3 <= ~rk2 | (rl2 != rlx2);
    end
  end

  // per-ID state writes: the load writes the ID it allocates; S2 advances the ID it saw.
  // They are never the same ID -- one is free, the other busy.
  integer gi;
  always @(posedge clk) begin
    for (gi = 0; gi < 16; gi = gi + 1) begin
      if (!rst && !start && r_load && r_oh[gi]) begin
        rcur[gi]  <= r_addrw;
        rbeat[gi] <= 5'd0;
      end else if (!rst && s2_known && s2_id == gi) begin
        rbeat[gi] <= rl1 ? 5'd0 : s2_beat + 5'd1;
      end
    end
  end

  // ===================================================================== write direction
  reg  [15:0] wbusy = 16'd0;
  reg  [4:0]  wr_out = 5'd0;
  reg  [19:0] w_page = 20'd0;
  reg  [8:0]  w_pb = 9'd0;
  reg  [28:0] w_page_w = 29'd0, w_addrw = 29'd0;
  wire [15:0] w_free   = ~wbusy & wr_lim;
  wire [15:0] w_oh     = w_free & (~w_free + 16'd1);
  wire        w_any    = |w_free;
  wire [3:0]  w_idx    = enc16(w_oh);
  wire        w_maxhit = wr_maxb_nz && (wr_bursts == q_wr_maxb);
  wire        w_go     = run_wr & in_win & ~abort & ~w_maxhit;
  wire        w_load   = w_go & w_any & (~m_awvalid | m_awready);


  // W order queue: one entry per loaded AW, in AW order.  At most 16 are ever pending
  // (one per ID), so a 16-entry queue cannot overflow; wq_ovf latches if it ever does.
  reg  [32:0] wq [0:15];          // {id[3:0], addrw[28:0]}
  reg  [4:0]  wq_wp = 5'd0, wq_rp = 5'd0;
  wire        wq_empty = (wq_wp == wq_rp);
  wire [32:0] wq_head  = wq[wq_rp[3:0]];

  reg  [28:0] wg_addrw = 29'd0;   // next beat's word address in the burst being sent
  reg  [4:0]  wg_beat  = 5'd0;
  wire        w_hs   = m_wvalid & m_wready;
  wire        w_need = ~m_wvalid | (w_hs & m_wlast);
  // W AFTER AW, AT THE PINS (v5).  A write burst's first W beat is released only once the PS
  // has accepted that burst's AW.  AXI3 lets write data lead its address; nothing that is known
  // to work on this board's HP ports does -- the HP0 self-test completes AW before W, and
  // TLToAXI4 behind the SoC holds W until AW is accepted -- and the AFI releases a write command
  // "on WLAST enqueue".  AWs reach the pins in load order and W bursts start in load order, so
  // two 5-bit counts are enough: bursts whose AW the PS took, and bursts whose W has started.
  reg  [4:0]  aw_taken = 5'd0, w_started = 5'd0;
  wire        w_pop  = w_need & ~wq_empty & (aw_taken != w_started);

  reg         bv1 = 1'b0, bwin1 = 1'b0;
  reg  [5:0]  bid1 = 6'd0;
  reg  [1:0]  br1 = 2'd0;
  wire        b_known = bv1 & (cfg_id_lo_only | (bid1[5:4] == 2'd0)) & wbusy[bid1[3:0]];

  always @(posedge clk) begin
    if (rst) begin
      wbusy <= 16'd0; wr_out <= 5'd0; m_awvalid <= 1'b0; m_wvalid <= 1'b0; m_wlast <= 1'b0;
      wq_wp <= 5'd0; wq_rp <= 5'd0; bv1 <= 1'b0; wq_ovf <= 1'b0;
    end else begin
      // -- AW issue
      if (start) begin
        w_page <= 20'd0; w_pb <= 9'd0; w_page_w <= q_wr_base[31:3]; w_addrw <= q_wr_base[31:3];
        wq_ovf <= 1'b0;
      end else if (w_load) begin
        m_awvalid <= 1'b1;
        m_awid    <= {2'b00, w_idx};
        m_awaddr  <= {w_addrw, 3'b000};
        m_awlen   <= q_len_m1;
        wq[wq_wp[3:0]] <= {w_idx, w_addrw};
        if (wq_wp - wq_rp == 5'd16) wq_ovf <= 1'b1;
        if (w_pb != bpp_m1) begin
          w_pb <= w_pb + 9'd1; w_addrw <= w_addrw + {24'd0, L};
        end else if (w_page != wr_pages_m1) begin
          w_pb <= 9'd0; w_page <= w_page + 20'd1;
          w_page_w <= w_page_w + 29'd512; w_addrw <= w_page_w + 29'd512;
        end else begin
          w_pb <= 9'd0; w_page <= 20'd0; w_page_w <= q_wr_base[31:3]; w_addrw <= q_wr_base[31:3];
        end
      end else if (m_awvalid && m_awready) begin
        m_awvalid <= 1'b0;
      end
      if (start) wq_wp <= 5'd0; else if (w_load) wq_wp <= wq_wp + 5'd1;

      if (start) aw_taken <= 5'd0; else if (st_aw_hs) aw_taken <= aw_taken + 5'd1;
      if (start) w_started <= 5'd0; else if (w_pop) w_started <= w_started + 5'd1;
      // -- W generator: bursts in AW order, back to back
      if (start) begin
        wq_rp <= 5'd0;
      end else if (w_pop) begin
        wq_rp    <= wq_rp + 5'd1;
        m_wvalid <= 1'b1;
        m_wid    <= {2'b00, wq_head[32:29]};
        m_wdata  <= pattern(wq_head[28:0], q_wr_seed);
        m_wlast  <= (q_len_m1 == 4'd0);
        wg_addrw <= wq_head[28:0] + 29'd1;
        wg_beat  <= 5'd1;
      end else if (w_hs && !m_wlast) begin
        m_wdata  <= pattern(wg_addrw, q_wr_seed);
        m_wlast  <= (wg_beat == {1'b0, q_len_m1});
        wg_addrw <= wg_addrw + 29'd1;
        wg_beat  <= wg_beat + 5'd1;
      end else if (w_hs) begin
        m_wvalid <= 1'b0; m_wlast <= 1'b0;
      end

      // -- B
      bv1 <= m_bvalid; bid1 <= m_bid; br1 <= m_bresp; bwin1 <= in_win;
      if (start) wbusy <= 16'd0;
      else wbusy <= (wbusy | (w_load ? w_oh : 16'd0))
                          & ~(b_known ? (16'd1 << bid1[3:0]) : 16'd0);
      if (start) wr_out <= 5'd0;
      else wr_out <= wr_out + {4'd0, w_load} - {4'd0, b_known};
    end
  end

  // ================================================================ run control, counters
  assign live_rbusy = rbusy;
  assign live_wbusy = wbusy;
  assign live_rd_out = rd_out;
  assign live_wr_out = wr_out;
  assign live_wq_cnt = wq_wp - wq_rp;
  assign live_run_rd = run_rd;
  assign live_run_wr = run_wr;

  wire idle = ~run_rd & ~run_wr & (rd_out == 5'd0) & (wr_out == 5'd0) & ~rv1 & ~rv2 & ~rv3 & ~bv1
              & ~m_wvalid & wq_empty;

  always @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0; done <= 1'b0; run_rd <= 1'b0; run_wr <= 1'b0;
      cfg_err_rd <= 1'b0; cfg_err_wr <= 1'b0;
    end else if (start) begin
      busy <= en; done <= 1'b0;
      run_rd <= en & cfg_rd_en & rd_cfg_ok;
      run_wr <= en & cfg_wr_en & wr_cfg_ok;
      cfg_err_rd <= en & cfg_rd_en & ~rd_cfg_ok;
      cfg_err_wr <= en & cfg_wr_en & ~wr_cfg_ok;
      rd_beats_win <= 0; wr_beats_win <= 0; b_beats_win <= 0; rd_beats_tot <= 0; b_beats_tot <= 0;
      rd_err <= 0; rd_proto <= 0; wr_err <= 0; wr_proto <= 0; rd_bursts <= 0; wr_bursts <= 0;
      ar_stall_win <= 0; aw_stall_win <= 0; w_stall_win <= 0; r_gap_win <= 0; w_idle_win <= 0;
      drain_cycles <= 0; rd_out_sum <= 0; wr_out_sum <= 0; rd_out_peak <= 0; wr_out_peak <= 0;
      bad_rid <= 7'd0; bad_bid <= 7'd0;
      racount_sum <= 0; rcount_sum <= 0; wacount_sum <= 0; wcount_sum <= 0;
      racount_max <= 0; rcount_max <= 0; wacount_max <= 0; wcount_max <= 0;
    end else begin
      if (run_rd && !r_go) run_rd <= 1'b0;
      if (run_wr && !w_go) run_wr <= 1'b0;
      if (busy && idle && !run_rd && !run_wr) begin busy <= 1'b0; done <= 1'b1; end
      if (busy && !in_win) drain_cycles <= drain_cycles + 32'd1;

      if (r_load) rd_bursts <= rd_bursts + 32'd1;
      if (w_load) wr_bursts <= wr_bursts + 32'd1;

      // read beats: counted where they cross the port (S1), windowed by the cycle they crossed
      if (rv1) begin
        rd_beats_tot <= rd_beats_tot + 1'b1;
        if (rwin1) rd_beats_win <= rd_beats_win + 1'b1;
      end
      if (rv3 && rpro3) rd_proto <= rd_proto + 32'd1;
      if (rv1 && !s2_known && !bad_rid[6]) bad_rid <= {1'b1, rid1};
      if (rv3 && (rbad3 || (rd3 != rp3))) rd_err <= rd_err + 32'd1;

      if (w_hs && in_win) wr_beats_win <= wr_beats_win + 1'b1;
      if (bv1) begin
        if (b_known) begin
          b_beats_tot <= b_beats_tot + L;
          if (bwin1) b_beats_win <= b_beats_win + L;
          if (br1 != 2'b00) wr_err <= wr_err + 32'd1;
        end else begin
          wr_proto <= wr_proto + 32'd1;
          if (!bad_bid[6]) bad_bid <= {1'b1, bid1};
        end
      end

      if (in_win) begin
        if (st_ar_stall) ar_stall_win <= ar_stall_win + 32'd1;
        if (st_aw_stall) aw_stall_win <= aw_stall_win + 32'd1;
        if (st_w_stall)  w_stall_win  <= w_stall_win + 32'd1;
        if (run_rd && rd_out != 5'd0 && !m_rvalid) r_gap_win <= r_gap_win + 32'd1;
        if (run_wr && !m_wvalid) w_idle_win <= w_idle_win + 32'd1;
        rd_out_sum <= rd_out_sum + rd_out;
        wr_out_sum <= wr_out_sum + wr_out;
        if (rd_out > rd_out_peak) rd_out_peak <= rd_out;
        if (wr_out > wr_out_peak) wr_out_peak <= wr_out;
        racount_sum <= racount_sum + sb_racount;
        rcount_sum  <= rcount_sum + sb_rcount;
        wacount_sum <= wacount_sum + sb_wacount;
        wcount_sum  <= wcount_sum + sb_wcount;
        if (sb_racount > racount_max) racount_max <= sb_racount;
        if (sb_rcount  > rcount_max)  rcount_max  <= sb_rcount;
        if (sb_wacount > wacount_max) wacount_max <= sb_wacount;
        if (sb_wcount  > wcount_max)  wcount_max  <= sb_wcount;
      end
    end
  end
endmodule
