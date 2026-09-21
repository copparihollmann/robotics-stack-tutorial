// axiceil_core -- the interface-ceiling instrument without the PS7: GP0 register file, a
// shared measurement window, and N raw AXI3 masters, each behind its own address guard.
//
// MEMORY_BANDWIDTH.md section 7.  axiceil_top.v wires this to the PS7; sim/axiceil/ drives
// the same module from a testbench, so what is simulated is what is built.
//
// GP0 REGISTER MAP (offsets from 0x4000_0000; [11:2] decoded, the rest aliases)
//
//   0x000 CTRL        W  [0] start (pulse; refused while any port is busy)
//                     RW [1] abort (level: stop issuing, drain)
//   0x004 MAGIC       R  0x5A5A0020
//   0x008 STATUS      R  [3:0] busy  [7:4] done  [8] in window  [12:9] guard fault
//                        [16:13] cfg error (rd|wr)  [17] a start was refused
//   0x00C RUNS        R  completed runs since reset
//   0x010 PORT_EN     RW [3:0] ports that take part in the next start
//   0x014 WINDOW      RW measurement window, fabric cycles
//   0x018/01C RUN_CYCLES  R  cycles from start until every port drained (lo/hi)
//   0x020/024 FREERUN     R  free-running cycle count since reset (lo/hi): with two host
//                            timestamps it measures the fabric clock independently of SLCR
//   0x028 BUILD       R  {N_PORTS, 16 IDs, VERSION, counter width}
//   0x02C REGION_LO   R  hard lower bound the guards enforce (inclusive)
//   0x030 REGION_HI   R  hard upper bound (exclusive)
//   0x034 WIN_ELAPSED R  cycles the last window actually lasted
//   0x038 SCRATCH     RW GP0 self-test
//
//   Port p (HP p) at 0x100*(p+1):
//   +0x00 MODE   RW [0] rd_en [1] wr_en [7:4] len-1 [12:8] k_rd [20:16] k_wr
//   +0x04 RD_BASE  +0x08 RD_WORDS  +0x0C WR_BASE  +0x10 WR_WORDS      RW
//         (v5: a region starts on a 4 KiB boundary and is a whole number of 4 KiB pages; each
//          page holds floor(512/len) bursts, so no burst crosses a page)
//   +0x14 RD_SEED  +0x18 WR_SEED   +0x1C RD_MAXB  +0x20 WR_MAXB       RW
//   +0x40 PSTAT  R  [0] busy [1] done [2] cfg_err_rd [3] cfg_err_wr [4] guard fault
//                   [5] fault was a write [6] W queue overflow
//   +0x44/48 RD_BEATS_WIN  +0x4C/50 WR_BEATS_WIN  +0x54/58 B_BEATS_WIN
//   +0x5C/60 RD_BEATS_TOT  +0x64/68 B_BEATS_TOT                        (lo/hi)
//   +0x6C RD_ERR  +0x70 RD_PROTO  +0x74 WR_ERR  +0x78 WR_PROTO
//   +0x7C RD_BURSTS  +0x80 WR_BURSTS
//   +0x84 AR_STALL_WIN  +0x88 AW_STALL_WIN  +0x8C W_STALL_WIN
//   +0x90 R_GAP_WIN (reads outstanding, no R beat)  +0x94 W_IDLE_WIN (writing, no W beat)
//   +0x98/9C RD_OUT_SUM  +0xA0/A4 WR_OUT_SUM                            (lo/hi)
//   +0xA8 PEAK_OUT {wr[15:8], rd[7:0]}
//   +0xAC/B0 RACOUNT_SUM  +0xB4/B8 RCOUNT_SUM  +0xBC/C0 WACOUNT_SUM  +0xC4/C8 WCOUNT_SUM
//   +0xCC FIFO_MAX {rcount_max, wcount_max, wacount_max, racount_max}
//   +0xD0 DRAIN_CYCLES  +0xD4 GUARD_ADDR
//   HANDSHAKES AT THE PS PINS, cumulative since PL reset and NOT cleared by start (v5):
//   +0xD8 AW  +0xDC W with WLAST  +0xE0 B  +0xE4 AR  +0xE8 R with RLAST
//     AW - B and AR - RLAST are the transactions the PS holds, whatever the master believes;
//     the host may reset the PL or change its clock only when both are zero on every port.
//   +0xEC LIVE_BUSY {wbusy[15:0], rbusy[15:0]}
//   +0xF0 LIVE {bad_bid seen, bad_bid[5:0], bad_rid seen, bad_rid[5:0], run_wr, run_rd,
//               wq[4:0], wr_out[4:0], rd_out[4:0]}
//   +0xF4 LIVE_PINS {20'd0, awvalid, awready, wvalid, wready, wlast, bvalid, arvalid, arready,
//                    rvalid, rlast, guard fault, any master valid}
//   +0xF8 RESP_FIRST {18'd0, B seen, BRESP[1:0], 3'd0, R seen, RRESP[1:0], ...} (v6): the code of the
//         first non-OKAY B and of the first non-OKAY R beat at the pins since PL reset
//   +0xFC RESP_COUNTS {B SLVERR, B DECERR, R SLVERR, R DECERR}, 8 bits each, saturating, since PL reset
//   MODE[24] id_lo_only: match B/R on ID[3:0] only (diagnostic)
//
// The GP0 slave keeps axi_ctrl_regs.v's write handshake exactly -- W is held off until AW
// is in hand, RID/BID echo the PS's IDs -- because both of that file's bring-up bugs hung
// the CPU.  The read path adds two registered cycles between AR and R, so a 250-entry read
// mux is not a combinational path into the PS.  v2: a written word is captured on the W
// handshake and decoded one cycle later, with B one cycle after that, so the PS's WVALID is
// not a combinational path to 300 register enables (build 1's worst PS7-boundary path).

module axiceil_core #(
  parameter integer N_PORTS = 4,
  parameter [31:0]  MAGIC   = 32'h5A5A_0020,
  parameter [7:0]   VERSION = 8'd6
)(
  input  wire        clk,
  input  wire        rstn,           // FCLK_RESET0_N

  // M_AXI_GP0 (PS master -> PL registers), AXI3
  input  wire [11:0] s_awid,   input wire [31:0] s_awaddr, input wire [3:0] s_awlen,
  input  wire        s_awvalid, output reg s_awready,
  input  wire [31:0] s_wdata,  input wire [3:0] s_wstrb, input wire s_wlast,
  input  wire        s_wvalid, output reg s_wready,
  output reg  [11:0] s_bid,    output reg [1:0] s_bresp,
  output reg         s_bvalid, input wire s_bready,
  input  wire [11:0] s_arid,   input wire [31:0] s_araddr, input wire [3:0] s_arlen,
  input  wire        s_arvalid, output reg s_arready,
  output reg  [31:0] s_rdata,  output reg [1:0] s_rresp, output reg [11:0] s_rid,
  output reg         s_rlast,  output reg s_rvalid, input wire s_rready,

  // N x S_AXI_HP masters, flattened (port p occupies slice p)
  output wire [6*N_PORTS-1:0]  hp_awid,   output wire [32*N_PORTS-1:0] hp_awaddr,
  output wire [4*N_PORTS-1:0]  hp_awlen,  output wire [N_PORTS-1:0]    hp_awvalid,
  input  wire [N_PORTS-1:0]    hp_awready,
  output wire [6*N_PORTS-1:0]  hp_wid,    output wire [64*N_PORTS-1:0] hp_wdata,
  output wire [N_PORTS-1:0]    hp_wlast,  output wire [N_PORTS-1:0]    hp_wvalid,
  input  wire [N_PORTS-1:0]    hp_wready,
  input  wire [6*N_PORTS-1:0]  hp_bid,    input  wire [2*N_PORTS-1:0]  hp_bresp,
  input  wire [N_PORTS-1:0]    hp_bvalid, output wire [N_PORTS-1:0]    hp_bready,
  output wire [6*N_PORTS-1:0]  hp_arid,   output wire [32*N_PORTS-1:0] hp_araddr,
  output wire [4*N_PORTS-1:0]  hp_arlen,  output wire [N_PORTS-1:0]    hp_arvalid,
  input  wire [N_PORTS-1:0]    hp_arready,
  input  wire [6*N_PORTS-1:0]  hp_rid,    input  wire [64*N_PORTS-1:0] hp_rdata,
  input  wire [2*N_PORTS-1:0]  hp_rresp,  input  wire [N_PORTS-1:0]    hp_rlast,
  input  wire [N_PORTS-1:0]    hp_rvalid, output wire [N_PORTS-1:0]    hp_rready,
  input  wire [3*N_PORTS-1:0]  hp_racount, input wire [8*N_PORTS-1:0]  hp_rcount,
  input  wire [6*N_PORTS-1:0]  hp_wacount, input wire [8*N_PORTS-1:0]  hp_wcount,

  output wire [3:0]  leds
);
  localparam [31:0] REGION_LO = 32'h1000_0000;
  localparam [32:0] REGION_HI = 33'h0_2000_0000;
  localparam integer CW = 40;
  localparam [7:0] NP8 = N_PORTS;
  localparam [7:0] CW8 = CW;

  // ---- reset: synchronise FCLK_RESET0_N, then one registered copy per consumer
  reg [1:0] rsync = 2'b00;
  always @(posedge clk) rsync <= {rsync[0], rstn};
  (* max_fanout = 64 *) reg rst_reg = 1'b1;
  (* max_fanout = 64 *) reg rst_ports = 1'b1;
  always @(posedge clk) begin rst_reg <= ~rsync[1]; rst_ports <= ~rsync[1]; end

  // ---- global state
  reg         start_pulse = 1'b0, abort = 1'b0, start_refused = 1'b0;
  reg  [3:0]  port_en = 4'b0001;
  reg  [31:0] window = 32'd1000000, scratch = 32'd0;
  reg  [31:0] runs = 32'd0;
  reg  [CW-1:0] run_cycles = 0, freerun = 0;
  reg         in_win = 1'b0, any_busy_q = 1'b0;
  reg  [31:0] win_left = 32'd0, win_elapsed = 32'd0;

  reg  [31:0] c_mode [0:3], c_rdb [0:3], c_rdw [0:3], c_wrb [0:3], c_wrw [0:3];
  reg  [31:0] c_rds [0:3], c_wrs [0:3], c_rdm [0:3], c_wrm [0:3];
  integer q;
  initial for (q = 0; q < 4; q = q + 1) begin
    c_mode[q] = 32'h0001_0101; c_rdb[q] = 32'd0; c_rdw[q] = 32'd0; c_wrb[q] = 32'd0;
    c_wrw[q] = 32'd0; c_rds[q] = 32'd0; c_wrs[q] = 32'd0; c_rdm[q] = 32'd0; c_wrm[q] = 32'd0;
  end

  wire [N_PORTS-1:0] p_busy, p_done, p_cerr_rd, p_cerr_wr, p_fault, p_fault_wr, p_wqovf;
  // N_PORTS-wide vectors zero-extended to the 4 bits the register map reserves
  wire [3:0] busy4 = {4'b0000, p_busy};
  wire [3:0] done4 = {4'b0000, p_done};
  wire [3:0] fault4 = {4'b0000, p_fault};
  wire [3:0] cerr4 = {4'b0000, p_cerr_rd | p_cerr_wr};

  // ================================================================== GP0 register file
  reg        aw_full = 1'b0;
  reg [11:0] awaddr_q = 12'd0;
  reg        wq_v = 1'b0, b_pend = 1'b0;
  reg [11:0] wq_addr = 12'd0;
  reg [31:0] wq_data = 32'd0;

  always @(posedge clk) begin
    if (rst_reg) begin
      s_awready <= 1'b1; s_wready <= 1'b0; s_bvalid <= 1'b0; s_bresp <= 2'b00;
      s_bid <= 12'd0; aw_full <= 1'b0; awaddr_q <= 12'd0; wq_v <= 1'b0; b_pend <= 1'b0;
      start_pulse <= 1'b0; abort <= 1'b0; start_refused <= 1'b0;
      port_en <= 4'b0001; window <= 32'd1000000; scratch <= 32'd0;
      for (q = 0; q < 4; q = q + 1) begin
        c_mode[q] <= 32'h0001_0101; c_rdb[q] <= 32'd0; c_rdw[q] <= 32'd0; c_wrb[q] <= 32'd0;
        c_wrw[q] <= 32'd0; c_rds[q] <= 32'd0; c_wrs[q] <= 32'd0; c_rdm[q] <= 32'd0;
        c_wrm[q] <= 32'd0;
      end
    end else begin
      start_pulse <= 1'b0;
      wq_v <= 1'b0;
      if (b_pend) begin s_bvalid <= 1'b1; s_bresp <= 2'b00; b_pend <= 1'b0; end
      if (s_awvalid && s_awready) begin
        awaddr_q  <= s_awaddr[11:0];
        s_bid     <= s_awid;
        aw_full   <= 1'b1;
        s_awready <= 1'b0;          // one write outstanding at a time
        s_wready  <= 1'b1;          // only now will this write's data be taken
      end
      if (aw_full && s_wvalid && s_wready) begin
        wq_v    <= (s_wstrb == 4'hF);
        wq_addr <= awaddr_q;
        wq_data <= s_wdata;
        awaddr_q <= awaddr_q + 12'd4;       // INCR burst support
        if (s_wlast) begin
          s_wready <= 1'b0; aw_full <= 1'b0; b_pend <= 1'b1;
        end
      end
      if (wq_v) begin
        begin
          if (wq_addr[11:8] == 4'h0) begin
            case (wq_addr[7:2])
              6'h00: begin
                abort <= wq_data[1];
                if (wq_data[0]) begin
                  if (|busy4) start_refused <= 1'b1;
                  else begin start_pulse <= 1'b1; start_refused <= 1'b0; end
                end
              end
              6'h04: port_en <= wq_data[3:0];
              6'h05: window  <= wq_data;
              6'h0E: scratch <= wq_data;
              default: ;
            endcase
          end else if (wq_addr[11:8] >= 4'h1 && wq_addr[11:8] <= N_PORTS) begin
            case (wq_addr[7:2])
              6'h00: c_mode[wq_addr[11:8] - 4'h1] <= wq_data;
              6'h01: c_rdb [wq_addr[11:8] - 4'h1] <= wq_data;
              6'h02: c_rdw [wq_addr[11:8] - 4'h1] <= wq_data;
              6'h03: c_wrb [wq_addr[11:8] - 4'h1] <= wq_data;
              6'h04: c_wrw [wq_addr[11:8] - 4'h1] <= wq_data;
              6'h05: c_rds [wq_addr[11:8] - 4'h1] <= wq_data;
              6'h06: c_wrs [wq_addr[11:8] - 4'h1] <= wq_data;
              6'h07: c_rdm [wq_addr[11:8] - 4'h1] <= wq_data;
              6'h08: c_wrm [wq_addr[11:8] - 4'h1] <= wq_data;
              default: ;
            endcase
          end
        end
      end
      if (s_bvalid && s_bready) begin
        s_bvalid  <= 1'b0;
        s_awready <= 1'b1;
      end
    end
  end

  // ---- window, run and cycle counters
  always @(posedge clk) begin
    if (rst_reg) begin
      in_win <= 1'b0; win_left <= 32'd0; win_elapsed <= 32'd0; runs <= 32'd0;
      run_cycles <= 0; freerun <= 0;
    end else begin
      freerun <= freerun + 1'b1;
      if (start_pulse) begin
        in_win <= (window != 32'd0); win_left <= window; win_elapsed <= 32'd0; run_cycles <= 0;
      end else begin
        if (in_win) begin
          win_elapsed <= win_elapsed + 32'd1;
          win_left    <= win_left - 32'd1;
          if (win_left == 32'd1 || abort) in_win <= 1'b0;
        end
        if (|busy4) run_cycles <= run_cycles + 1'b1;
      end
      any_busy_q <= |busy4;
      if (any_busy_q && !(|busy4)) runs <= runs + 32'd1;
    end
  end

  // ========================================================================= the ports
  wire [31:0] pst [0:4*64-1];   // pst[p*64 + index] = port p's word at +index*4

  genvar p;
  generate for (p = 0; p < N_PORTS; p = p + 1) begin : g_port
    wire [5:0]  awid;  wire [31:0] awaddr; wire [3:0] awlen; wire awvalid, awready;
    wire [5:0]  arid;  wire [31:0] araddr; wire [3:0] arlen; wire arvalid, arready;
    wire [5:0]  e_wid; wire [63:0] e_wdata; wire e_wlast, e_wvalid, e_wready;

    // Run control, registered per port: `start` clears ~1,000 counter flops in every port.
    // start and the window move together, so a port's window is still exactly WINDOW cycles.
    (* max_fanout = 128 *) reg p_start = 1'b0;
    (* max_fanout = 128 *) reg p_in_win = 1'b0;
    reg p_abort = 1'b0;
    always @(posedge clk) begin p_start <= start_pulse; p_in_win <= in_win; p_abort <= abort; end
    wire [CW-1:0] rbw, wbw, bbw, rbt, bbt, ros, wos, racs, rcs, wacs, wcs;
    wire [31:0] rerr, rpro, werr, wpro, rbur, wbur, ars, aws, wss, rgap, widl, drn, gaddr;
    wire [4:0]  rpk, wpk;
    wire [2:0]  racm; wire [7:0] rcm; wire [5:0] wacm; wire [7:0] wcm;
    wire [15:0] lrb, lwb; wire [4:0] lro, lwo, lwq; wire lrr, lrw; wire [6:0] brid, bbid;

    // handshakes at the PS pins: never cleared by start, only by PL reset
    reg [31:0] pin_aw = 0, pin_wl = 0, pin_b = 0, pin_ar = 0, pin_rl = 0;
    // error responses at the PS pins, by code (v6): SLVERR = 2'b10, DECERR = 2'b11
    reg [2:0]  first_b = 3'd0, first_r = 3'd0;
    reg [7:0]  b_slv = 0, b_dec = 0, r_slv = 0, r_dec = 0;
    always @(posedge clk) begin
      if (rst_ports) begin
        first_b <= 3'd0; first_r <= 3'd0; b_slv <= 0; b_dec <= 0; r_slv <= 0; r_dec <= 0;
      end else begin
        if (hp_bvalid[p] & hp_bready[p] & (hp_bresp[2*p +: 2] != 2'b00)) begin
          if (!first_b[2]) first_b <= {1'b1, hp_bresp[2*p +: 2]};
          if (hp_bresp[2*p +: 2] == 2'b10 && b_slv != 8'hFF) b_slv <= b_slv + 8'd1;
          if (hp_bresp[2*p +: 2] == 2'b11 && b_dec != 8'hFF) b_dec <= b_dec + 8'd1;
        end
        if (hp_rvalid[p] & hp_rready[p] & (hp_rresp[2*p +: 2] != 2'b00)) begin
          if (!first_r[2]) first_r <= {1'b1, hp_rresp[2*p +: 2]};
          if (hp_rresp[2*p +: 2] == 2'b10 && r_slv != 8'hFF) r_slv <= r_slv + 8'd1;
          if (hp_rresp[2*p +: 2] == 2'b11 && r_dec != 8'hFF) r_dec <= r_dec + 8'd1;
        end
      end
    end
    always @(posedge clk) begin
      if (rst_ports) begin
        pin_aw <= 0; pin_wl <= 0; pin_b <= 0; pin_ar <= 0; pin_rl <= 0;
      end else begin
        if (hp_awvalid[p] & hp_awready[p]) pin_aw <= pin_aw + 32'd1;
        if (hp_wvalid[p] & hp_wready[p] & hp_wlast[p]) pin_wl <= pin_wl + 32'd1;
        if (hp_bvalid[p] & hp_bready[p]) pin_b <= pin_b + 32'd1;
        if (hp_arvalid[p] & hp_arready[p]) pin_ar <= pin_ar + 32'd1;
        if (hp_rvalid[p] & hp_rready[p] & hp_rlast[p]) pin_rl <= pin_rl + 32'd1;
      end
    end

    // AFI sidebands: two flops each; they are statistics, and nothing decides on them.
    reg [2:0] racount_s1 = 0, racount_s2 = 0;  reg [7:0] rcount_s1 = 0, rcount_s2 = 0;
    reg [5:0] wacount_s1 = 0, wacount_s2 = 0;  reg [7:0] wcount_s1 = 0, wcount_s2 = 0;
    always @(posedge clk) begin
      racount_s1 <= hp_racount[3*p +: 3]; racount_s2 <= racount_s1;
      rcount_s1  <= hp_rcount[8*p +: 8];  rcount_s2  <= rcount_s1;
      wacount_s1 <= hp_wacount[6*p +: 6]; wacount_s2 <= wacount_s1;
      wcount_s1  <= hp_wcount[8*p +: 8];  wcount_s2  <= wcount_s1;
    end

    axiceil_port #(.REGION_LO(REGION_LO), .REGION_HI(REGION_HI), .CW(CW)) u_port (
      .clk(clk), .rst(rst_ports),
      .start(p_start), .en(port_en[p]), .abort(p_abort), .in_win(p_in_win),
      .cfg_rd_en(c_mode[p][0]), .cfg_wr_en(c_mode[p][1]), .cfg_len_m1(c_mode[p][7:4]),
      .cfg_k_rd(c_mode[p][12:8]), .cfg_k_wr(c_mode[p][20:16]),
      .cfg_rd_base(c_rdb[p]), .cfg_rd_words(c_rdw[p]), .cfg_wr_base(c_wrb[p]),
      .cfg_wr_words(c_wrw[p]), .cfg_rd_seed(c_rds[p]), .cfg_wr_seed(c_wrs[p]),
      .cfg_rd_maxb(c_rdm[p]), .cfg_wr_maxb(c_wrm[p]), .cfg_id_lo_only(c_mode[p][24]),
      .busy(p_busy[p]), .done(p_done[p]), .cfg_err_rd(p_cerr_rd[p]), .cfg_err_wr(p_cerr_wr[p]),
      .wq_ovf(p_wqovf[p]),
      .rd_beats_win(rbw), .wr_beats_win(wbw), .b_beats_win(bbw), .rd_beats_tot(rbt), .b_beats_tot(bbt),
      .rd_err(rerr), .rd_proto(rpro), .wr_err(werr), .wr_proto(wpro),
      .rd_bursts(rbur), .wr_bursts(wbur),
      .ar_stall_win(ars), .aw_stall_win(aws), .w_stall_win(wss), .r_gap_win(rgap),
      .w_idle_win(widl), .drain_cycles(drn),
      .rd_out_sum(ros), .wr_out_sum(wos), .rd_out_peak(rpk), .wr_out_peak(wpk),
      .racount_sum(racs), .rcount_sum(rcs), .wacount_sum(wacs), .wcount_sum(wcs),
      .racount_max(racm), .rcount_max(rcm), .wacount_max(wacm), .wcount_max(wcm),
      .live_rbusy(lrb), .live_wbusy(lwb), .live_rd_out(lro), .live_wr_out(lwo), .live_wq_cnt(lwq),
      .live_run_rd(lrr), .live_run_wr(lrw), .bad_rid(brid), .bad_bid(bbid),
      .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awvalid(awvalid), .m_awready(awready),
      .m_wid(e_wid), .m_wdata(e_wdata), .m_wlast(e_wlast),
      .m_wvalid(e_wvalid), .m_wready(e_wready),
      .m_bid(hp_bid[6*p +: 6]), .m_bresp(hp_bresp[2*p +: 2]), .m_bvalid(hp_bvalid[p]),
      .m_bready(hp_bready[p]),
      .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arvalid(arvalid), .m_arready(arready),
      .m_rid(hp_rid[6*p +: 6]), .m_rdata(hp_rdata[64*p +: 64]), .m_rresp(hp_rresp[2*p +: 2]),
      .m_rlast(hp_rlast[p]), .m_rvalid(hp_rvalid[p]), .m_rready(hp_rready[p]),
      .st_aw_hs(hp_awvalid[p] & hp_awready[p]),
      .st_ar_stall(hp_arvalid[p] & ~hp_arready[p]), .st_aw_stall(hp_awvalid[p] & ~hp_awready[p]),
      .st_w_stall(hp_wvalid[p] & ~hp_wready[p]),
      .sb_racount(racount_s2), .sb_rcount(rcount_s2), .sb_wacount(wacount_s2), .sb_wcount(wcount_s2)
    );

    // W: a registered slice, so WREADY from the PS is not a path to the pattern generator
    axiceil_skid #(.W(71)) u_wslice (
      .clk(clk), .rst(rst_ports),
      .s_valid(e_wvalid), .s_ready(e_wready), .s_data({e_wid, e_wlast, e_wdata}),
      .m_valid(hp_wvalid[p]), .m_ready(hp_wready[p]),
      .m_data({hp_wid[6*p +: 6], hp_wlast[p], hp_wdata[64*p +: 64]}));

    axiceil_guard u_guard (
      .clk(clk), .rst(rst_ports),
      .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(3'b011), .s_awburst(2'b01),
      .s_awvalid(awvalid), .s_awready(awready),
      .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(3'b011), .s_arburst(2'b01),
      .s_arvalid(arvalid), .s_arready(arready),
      .m_awid(hp_awid[6*p +: 6]), .m_awaddr(hp_awaddr[32*p +: 32]), .m_awlen(hp_awlen[4*p +: 4]),
      .m_awvalid(hp_awvalid[p]), .m_awready(hp_awready[p]),
      .m_arid(hp_arid[6*p +: 6]), .m_araddr(hp_araddr[32*p +: 32]), .m_arlen(hp_arlen[4*p +: 4]),
      .m_arvalid(hp_arvalid[p]), .m_arready(hp_arready[p]),
      .fault(p_fault[p]), .fault_addr(gaddr), .fault_is_write(p_fault_wr[p])
    );

    // status words
    genvar k;
    for (k = 0; k < 64; k = k + 1) begin : g_unused
      if (!(k >= 0 && k <= 8) && !(k >= 16 && k <= 63))
        assign pst[p*64 + k] = 32'hDEAD_BEEF;
    end
    assign pst[p*64 + 0]  = c_mode[p];  assign pst[p*64 + 1] = c_rdb[p];
    assign pst[p*64 + 2]  = c_rdw[p];   assign pst[p*64 + 3] = c_wrb[p];
    assign pst[p*64 + 4]  = c_wrw[p];   assign pst[p*64 + 5] = c_rds[p];
    assign pst[p*64 + 6]  = c_wrs[p];   assign pst[p*64 + 7] = c_rdm[p];
    assign pst[p*64 + 8]  = c_wrm[p];
    assign pst[p*64 + 16] = {25'd0, p_wqovf[p], p_fault_wr[p], p_fault[p], p_cerr_wr[p],
                             p_cerr_rd[p], p_done[p], p_busy[p]};
    assign pst[p*64 + 17] = rbw[31:0];  assign pst[p*64 + 18] = {{(64-CW){1'b0}}, rbw[CW-1:32]};
    assign pst[p*64 + 19] = wbw[31:0];  assign pst[p*64 + 20] = {{(64-CW){1'b0}}, wbw[CW-1:32]};
    assign pst[p*64 + 21] = bbw[31:0];  assign pst[p*64 + 22] = {{(64-CW){1'b0}}, bbw[CW-1:32]};
    assign pst[p*64 + 23] = rbt[31:0];  assign pst[p*64 + 24] = {{(64-CW){1'b0}}, rbt[CW-1:32]};
    assign pst[p*64 + 25] = bbt[31:0];  assign pst[p*64 + 26] = {{(64-CW){1'b0}}, bbt[CW-1:32]};
    assign pst[p*64 + 27] = rerr;       assign pst[p*64 + 28] = rpro;
    assign pst[p*64 + 29] = werr;       assign pst[p*64 + 30] = wpro;
    assign pst[p*64 + 31] = rbur;       assign pst[p*64 + 32] = wbur;
    assign pst[p*64 + 33] = ars;        assign pst[p*64 + 34] = aws;
    assign pst[p*64 + 35] = wss;        assign pst[p*64 + 36] = rgap;
    assign pst[p*64 + 37] = widl;
    assign pst[p*64 + 38] = ros[31:0];  assign pst[p*64 + 39] = {{(64-CW){1'b0}}, ros[CW-1:32]};
    assign pst[p*64 + 40] = wos[31:0];  assign pst[p*64 + 41] = {{(64-CW){1'b0}}, wos[CW-1:32]};
    assign pst[p*64 + 42] = {16'd0, 3'd0, wpk, 3'd0, rpk};
    assign pst[p*64 + 43] = racs[31:0]; assign pst[p*64 + 44] = {{(64-CW){1'b0}}, racs[CW-1:32]};
    assign pst[p*64 + 45] = rcs[31:0];  assign pst[p*64 + 46] = {{(64-CW){1'b0}}, rcs[CW-1:32]};
    assign pst[p*64 + 47] = wacs[31:0]; assign pst[p*64 + 48] = {{(64-CW){1'b0}}, wacs[CW-1:32]};
    assign pst[p*64 + 49] = wcs[31:0];  assign pst[p*64 + 50] = {{(64-CW){1'b0}}, wcs[CW-1:32]};
    assign pst[p*64 + 51] = {rcm, wcm, 2'd0, wacm, 5'd0, racm};
    assign pst[p*64 + 52] = drn;
    assign pst[p*64 + 53] = gaddr;
    assign pst[p*64 + 54] = pin_aw;     assign pst[p*64 + 55] = pin_wl;
    assign pst[p*64 + 56] = pin_b;      assign pst[p*64 + 57] = pin_ar;
    assign pst[p*64 + 58] = pin_rl;
    assign pst[p*64 + 59] = {lwb, lrb};
    assign pst[p*64 + 60] = {bbid, brid, lrw, lrr, lwq, lwo, lro};
    assign pst[p*64 + 62] = {18'd0, first_b, 3'd0, first_r, 5'd0};
    assign pst[p*64 + 63] = {b_slv, b_dec, r_slv, r_dec};
    assign pst[p*64 + 61] = {20'd0, hp_awvalid[p], hp_awready[p], hp_wvalid[p], hp_wready[p],
                             hp_wlast[p], hp_bvalid[p], hp_arvalid[p], hp_arready[p], hp_rvalid[p],
                             hp_rlast[p], p_fault[p], awvalid | arvalid | e_wvalid};
  end endgenerate

  generate for (p = N_PORTS; p < 4; p = p + 1) begin : g_noport
    genvar k2;
    for (k2 = 0; k2 < 64; k2 = k2 + 1) begin : g_w
      assign pst[p*64 + k2] = 32'hDEAD_BEEF;
    end
  end endgenerate

  // ---- global status words
  wire [31:0] gst [0:15];
  assign gst[0]  = {30'd0, abort, 1'b0};
  assign gst[1]  = MAGIC;
  assign gst[2]  = {14'd0, start_refused, cerr4, fault4, in_win, done4, busy4};
  assign gst[3]  = runs;
  assign gst[4]  = {28'd0, port_en};
  assign gst[5]  = window;
  assign gst[6]  = run_cycles[31:0];
  assign gst[7]  = {{(64-CW){1'b0}}, run_cycles[CW-1:32]};
  assign gst[8]  = freerun[31:0];
  assign gst[9]  = {{(64-CW){1'b0}}, freerun[CW-1:32]};
  assign gst[10] = {NP8, 8'd16, VERSION, CW8};
  assign gst[11] = REGION_LO;
  assign gst[12] = REGION_HI[31:0];
  assign gst[13] = win_elapsed;
  assign gst[14] = scratch;
  assign gst[15] = 32'hDEAD_BEEF;

  // =========================================================== GP0 read path, registered
  localparam R_IDLE = 2'd0, R_PREP1 = 2'd1, R_PREP2 = 2'd2, R_VALID = 2'd3;
  reg  [1:0]  rd_state = R_IDLE;
  reg  [11:0] araddr_q = 12'd0;
  reg  [3:0]  arbeats_q = 4'd0;
  reg  [31:0] gmux_q = 32'd0;
  reg  [31:0] pmux_q [0:3];
  initial for (q = 0; q < 4; q = q + 1) pmux_q[q] = 32'd0;

  always @(posedge clk) begin
    if (rst_reg) begin
      s_arready <= 1'b0; s_rvalid <= 1'b0; s_rresp <= 2'b00; s_rlast <= 1'b0;
      s_rid <= 12'd0; s_rdata <= 32'd0; rd_state <= R_IDLE; araddr_q <= 12'd0; arbeats_q <= 4'd0;
    end else begin
      case (rd_state)
        R_IDLE: begin
          if (s_arvalid && s_arready) begin
            s_arready <= 1'b0;
            araddr_q  <= s_araddr[11:0];
            arbeats_q <= s_arlen;
            s_rid     <= s_arid;          // echoed on every beat of this burst
            rd_state <= R_PREP1;
          end else begin
            s_arready <= s_arvalid && !s_arready;
          end
        end
        R_PREP1: begin
          gmux_q <= (araddr_q[7:2] < 6'd16) ? gst[araddr_q[5:2]] : 32'hDEAD_BEEF;
          for (q = 0; q < 4; q = q + 1) pmux_q[q] <= pst[q*64 + araddr_q[7:2]];
          rd_state <= R_PREP2;
        end
        R_PREP2: begin
          case (araddr_q[11:8])
            4'h0: s_rdata <= gmux_q;
            4'h1: s_rdata <= pmux_q[0];
            4'h2: s_rdata <= pmux_q[1];
            4'h3: s_rdata <= pmux_q[2];
            4'h4: s_rdata <= pmux_q[3];
            default: s_rdata <= 32'hDEAD_BEEF;
          endcase
          s_rresp   <= 2'b00;
          s_rlast   <= (arbeats_q == 4'd0);
          s_rvalid  <= 1'b1;
          rd_state <= R_VALID;
        end
        R_VALID: begin
          if (s_rready) begin
            s_rvalid <= 1'b0;
            if (arbeats_q == 4'd0) begin
              s_rlast <= 1'b0; rd_state <= R_IDLE;
            end else begin
              arbeats_q <= arbeats_q - 4'd1;
              araddr_q  <= araddr_q + 12'd4;
              rd_state <= R_PREP1;
            end
          end
        end
      endcase
    end
  end

  // ---- LEDs: heartbeat, any busy, all done, any guard fault or data error
  reg [26:0] hb = 27'd0;
  always @(posedge clk) hb <= hb + 27'd1;
  assign leds = {|p_fault, (|p_done) & ~(|busy4), |busy4, hb[26]};
endmodule
