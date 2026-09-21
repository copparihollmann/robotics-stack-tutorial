// axi3_hp_model -- a deliberately impolite model of one Zynq S_AXI_HP port, for
// tb_axiceil.sv.  SIMULATION ONLY.
//
// It is not a model of the AFI's timing.  It exists to make the instrument prove it does
// not depend on anything the real port is not obliged to do:
//
//   * an issuing capability (CAP outstanding per direction, like the AFI's 8), enforced by
//     withholding ARREADY / AWREADY;
//   * random latency before a burst's data, random gaps between beats, random READY stalls;
//   * responses to different IDs out of order, and (mode 2) READ DATA OF DIFFERENT IDs
//     INTERLEAVED beat by beat, which AXI3 permits;
//   * B responses out of order.
//
// mode 0 = random, mode 1 = ideal (no latency, never stalls: the fabric ceiling must then
// read exactly one beat per cycle), mode 2 = random + interleaved read data.
//
// Fault injection, for the abort and hang tests (all 0 in normal use):
//   hold_aw / hold_ar / hold_w   force that READY low
//   hold_b / hold_r              present no B / no R beats (responses stay outstanding)
//   id_hi                        OR these bits into BID[5:4] and RID[5:4] -- a port that does
//                                not echo the upper ID bits the master issued
// `inflight_rd` / `inflight_wr` are the transactions the model holds: accepted, not answered.
//
// strict = 1 adds two rules the HP port may rely on even though AXI3 permits the first:
//   * W AFTER AW.  No W beat before its burst's AW has been accepted (the same cycle counts).
//     The AFI releases a write command to the DDR controller "on WLAST enqueue"
//     (AFI_WRCHAN_CTRL.WrCmdReleaseMode, as run); a WLAST that arrives before its command has
//     nothing to release.  Every known-good master on this board -- the HP0 self-test, and
//     rocket-chip's TLToAXI4 behind the SoC's shim -- completes AW before or with W.
//     Build 2 does not (replay: sim/axiceil/run_axiceil_repro.sh).  Build 1, the bitstream that
//     was running when HP0 wedged, does in replay -- so this rule is a precaution, not the
//     established cause of that wedge.
//   * No burst crosses a 4 KiB boundary (AXI's own rule; nothing in this repo broke it).
// orphan_early = 1 additionally BEHAVES like a port with that release rule: a write burst any of
// whose W beats came before its AW is never answered.  That is a model of a hypothesis, used to
// reproduce the board's symptom (an abort that cannot drain), not a claim about the silicon.
// cap_lag = N keeps a write counted against CAP for N cycles after its B, so AWREADY stays low
// while the master already has the freed ID's next AW and W on the bus -- one way a real port's
// command accounting can trail its responses.  Also a model of a hypothesis.
//
// It also checks the MASTER: VALID held until READY with a stable payload, WLAST on the
// right beat, no ID reused while outstanding, and every address inside the PL's window --
// a request outside it reaching this model means the guard failed.
module axi3_hp_model #(
  parameter int CAP  = 8,
  parameter int SEED = 1,
  parameter logic [31:0] LO = 32'h1000_0000,
  parameter logic [32:0] HI = 33'h0_2000_0000
)(
  input  logic        clk,
  input  logic        rst,
  input  logic [1:0]  mode,
  input  logic        hold_aw, hold_ar, hold_w, hold_b, hold_r,
  input  logic [1:0]  id_hi,
  input  logic        strict,
  input  logic        orphan_early,
  input  int          cap_lag,
  input  logic [1:0]  resp_code,    // returned on every B and R when nonzero (SLVERR 2, DECERR 3)
  output int          early_w,      // W beats that arrived before their AW was accepted
  output int          inflight_rd, inflight_wr,
  input  logic [5:0]  awid,  input logic [31:0] awaddr, input logic [3:0] awlen,
  input  logic        awvalid, output logic awready,
  input  logic [5:0]  wid,   input logic [63:0] wdata, input logic wlast,
  input  logic        wvalid, output logic wready,
  output logic [5:0]  bid,   output logic [1:0] bresp, output logic bvalid, input logic bready,
  input  logic [5:0]  arid,  input logic [31:0] araddr, input logic [3:0] arlen,
  input  logic        arvalid, output logic arready,
  output logic [5:0]  rid,   output logic [63:0] rdata, output logic [1:0] rresp,
  output logic        rlast, output logic rvalid, input logic rready,
  output logic [2:0]  racount, output logic [7:0] rcount,
  output logic [5:0]  wacount, output logic [7:0] wcount,
  output int          errors,
  output int          oob          // requests outside [LO, HI) that reached the port
);
  localparam int N = 32;
  logic [63:0] mem [logic [28:0]];

  // read bursts
  logic       rq_v [N]; logic [5:0] rq_id [N]; logic [28:0] rq_a [N];
  int         rq_len [N], rq_sent [N]; longint rq_t [N];
  // write bursts
  logic       wq_v [N]; logic [5:0] wq_id [N]; logic [28:0] wq_a [N];
  int         wq_len [N], wq_recv [N]; logic wq_done [N], wq_bsent [N], wq_orphan [N]; longint wq_t [N], wq_seq [N];
  bit [63:0]  early_pending;        // per ID: a W beat arrived with no AW accepted for it
  longint     lag_until [$];        // release times of writes still counted after their B
  int nrd, nwr, rcur, bcur;
  longint now, seq;
  bit wready_rnd;

  // previous-cycle view, for VALID/payload stability checks
  logic p_arv, p_arr, p_awv, p_awr, p_wv, p_wr;
  logic [31:0] p_araddr, p_awaddr; logic [5:0] p_arid, p_awid, p_wid; logic [63:0] p_wdata;
  logic [3:0] p_arlen, p_awlen; logic p_wlast;

  function automatic int rnd(int m); return (m <= 1) ? 0 : int'($urandom % m); endfunction

  function automatic bit inside_window(logic [31:0] a, logic [3:0] len);
    logic [32:0] e; e = {1'b0, a} + ((33'(len) + 33'd1) << 3);
    return (a >= LO) && (e <= HI) && (a[2:0] == 3'd0);
  endfunction

  // W beats are matched to the oldest incomplete AW of the same ID.  AXI lets write data
  // arrive before its address, so beats with no AW yet wait in wbuf (in arrival order).
  function automatic int wmatch(logic [5:0] id);
    int best = -1;
    for (int i = 0; i < N; i++)
      if (wq_v[i] && !wq_done[i] && wq_id[i] == id && (best < 0 || wq_seq[i] < wq_seq[best])) best = i;
    return best;
  endfunction
  logic [70:0] wbuf [$];            // {id, last, data}
  assign wready = wready_rnd & ~hold_w;
  assign inflight_rd = nrd;
  assign inflight_wr = nwr;

  initial begin
    void'($urandom(SEED));
    errors = 0; oob = 0; nrd = 0; nwr = 0; rcur = -1; bcur = -1; now = 0; seq = 0; early_w = 0;
    early_pending = 0;
    for (int i = 0; i < N; i++) begin rq_v[i] = 0; wq_v[i] = 0; end
    arready = 0; awready = 0; wready_rnd = 0; rvalid = 0; bvalid = 0; rlast = 0;
    rid = 0; rdata = 0; rresp = 0; bid = 0; bresp = 0;
  end

  task automatic err(string s);
    errors++;
    if (errors <= 10) $display("[hp model %0d] ERROR t=%0d: %s", SEED, now, s);
  endtask

  always @(posedge clk) begin
    now++;
    if (rst) begin
      for (int i = 0; i < N; i++) begin rq_v[i] = 0; wq_v[i] = 0; end
      nrd = 0; nwr = 0; rcur = -1; bcur = -1; wbuf.delete(); early_pending = 0; lag_until.delete();
      arready <= 0; awready <= 0; wready_rnd <= 0; rvalid <= 0; bvalid <= 0;
    end else begin
      // ---------------- master-side protocol checks
      if (p_arv && !p_arr && (!arvalid || araddr != p_araddr || arid != p_arid || arlen != p_arlen))
        err("AR dropped or changed before ARREADY");
      if (p_awv && !p_awr && (!awvalid || awaddr != p_awaddr || awid != p_awid || awlen != p_awlen))
        err("AW dropped or changed before AWREADY");
      if (p_wv && !p_wr && (!wvalid || wdata != p_wdata || wid != p_wid || wlast != p_wlast))
        err("W dropped or changed before WREADY");

      // ---------------- read side
      if (rvalid && rready) begin
        rq_sent[rcur]++;
        if (rq_sent[rcur] == rq_len[rcur] + 1) begin rq_v[rcur] = 0; nrd--; rcur = -1; end
        else if (mode == 2) rcur = -1;          // may switch ID mid-burst
      end
      if (arvalid && arready) begin
        int s = -1;
        for (int i = 0; i < N; i++) if (rq_v[i] && rq_id[i] == arid) err($sformatf("AR reuses outstanding ID %0d", arid));
        for (int i = 0; i < N; i++) if (!rq_v[i]) begin s = i; break; end
        if (!inside_window(araddr, arlen)) begin oob++; err($sformatf("AR outside window: %h", araddr)); end
        if (strict && ({21'd0, araddr[11:0]} + ((33'(arlen) + 33'd1) << 3)) > 33'd4096)
          err($sformatf("AR burst crosses a 4 KiB boundary: %h len %0d", araddr, arlen));
        rq_v[s] = 1; rq_id[s] = arid; rq_a[s] = araddr[31:3]; rq_len[s] = arlen; rq_sent[s] = 0;
        rq_t[s] = now + ((mode == 1) ? 0 : rnd(24));
        nrd++;
      end
      begin
        bit present = 0; int pick = -1, cnt = 0;
        if (!(rvalid && !rready) && !hold_r) begin
          if (rcur >= 0) pick = rcur;
          else begin
            for (int i = 0; i < N; i++) if (rq_v[i] && rq_t[i] <= now) begin
              cnt++;
              if (rnd(cnt) == 0) pick = i;      // reservoir: uniform among ready bursts
            end
          end
          if (pick >= 0 && (mode == 1 || rnd(100) >= 20)) begin
            logic [28:0] a; a = rq_a[pick] + 29'(rq_sent[pick]);
            rid   <= rq_id[pick] | {id_hi, 4'b0000};
            rdata <= mem.exists(a) ? mem[a] : 64'hBADB_ADBA_DBAD_BAD0;
            rresp <= resp_code;
            rlast <= (rq_sent[pick] == rq_len[pick]);
            rvalid <= 1; present = 1;
            rcur = pick;
          end
          if (!present) rvalid <= 0;
        end else if (hold_r && !(rvalid && !rready)) rvalid <= 0;
        arready <= (nrd < CAP) && !hold_ar && (mode == 1 || rnd(100) >= 25);
      end

      // ---------------- write side
      if (bvalid && bready) begin
        wq_v[bcur] = 0; nwr--; bcur = -1;
        if (cap_lag > 0) lag_until.push_back(now + cap_lag);
      end
      while (lag_until.size() > 0 && lag_until[0] <= now) void'(lag_until.pop_front());
      if (awvalid && awready) begin
        int s = -1;
        for (int i = 0; i < N; i++) if (wq_v[i] && wq_id[i] == awid) err($sformatf("AW reuses outstanding ID %0d", awid));
        for (int i = 0; i < N; i++) if (!wq_v[i]) begin s = i; break; end
        if (!inside_window(awaddr, awlen)) begin oob++; err($sformatf("AW outside window: %h", awaddr)); end
        wq_v[s] = 1; wq_id[s] = awid; wq_a[s] = awaddr[31:3]; wq_len[s] = awlen; wq_recv[s] = 0;
        wq_done[s] = 0; wq_bsent[s] = 0; wq_seq[s] = seq++;
        wq_orphan[s] = orphan_early && early_pending[awid];
        early_pending[awid] = 0;
        nwr++;
        if (strict && ({21'd0, awaddr[11:0]} + ((33'(awlen) + 33'd1) << 3)) > 33'd4096)
          err($sformatf("AW burst crosses a 4 KiB boundary: %h len %0d", awaddr, awlen));
      end
      if (wvalid && wready) begin
        // strict: this beat's burst must already have an accepted AW, and no earlier beat of
        // this ID may still be waiting for one
        bit waiting = 0;
        foreach (wbuf[j]) if (wbuf[j][70:65] == wid) waiting = 1;
        if (wmatch(wid) < 0 || waiting) begin
          early_w++;
          early_pending[wid] = 1;
          if (strict) err($sformatf("W beat (WID %0d, WLAST %0d) before its AW was accepted", wid, wlast));
        end
        wbuf.push_back({wid, wlast, wdata});
      end
      begin   // apply buffered W beats whose AW is in hand; per-ID order is preserved
        bit [63:0] blocked = 0;
        int i = 0;
        while (i < wbuf.size()) begin
          logic [5:0] id; int m; id = wbuf[i][70:65]; m = wmatch(id);
          if (blocked[id] || m < 0) begin blocked[id] = 1; i++; end
          else begin
            mem[wq_a[m] + 29'(wq_recv[m])] = wbuf[i][63:0];
            if (wbuf[i][64] != (wq_recv[m] == wq_len[m]))
              err($sformatf("WLAST wrong: beat %0d of len %0d", wq_recv[m], wq_len[m]));
            wq_recv[m]++;
            if (wbuf[i][64] || wq_recv[m] == wq_len[m] + 1) begin
              wq_done[m] = 1; wq_t[m] = now + ((mode == 1) ? 0 : rnd(16));
            end
            wbuf.delete(i);
          end
        end
      end
      if (!(bvalid && !bready) && !hold_b) begin
        int pick = -1, cnt = 0;
        for (int i = 0; i < N; i++) if (wq_v[i] && wq_done[i] && !wq_bsent[i] && !wq_orphan[i] && wq_t[i] <= now) begin
          cnt++;
          if (rnd(cnt) == 0) pick = i;
        end
        if (pick >= 0 && (mode == 1 || rnd(100) >= 30)) begin
          bvalid <= 1; bid <= wq_id[pick] | {id_hi, 4'b0000}; bresp <= resp_code; wq_bsent[pick] = 1; bcur = pick;
        end else bvalid <= 0;
      end else if (hold_b && !(bvalid && !bready)) bvalid <= 0;
      awready    <= (nwr + lag_until.size() < CAP) && !hold_aw && (mode == 1 || rnd(100) >= 25);
      wready_rnd <= (wbuf.size() < 64) && ((mode == 1) || rnd(100) >= 20);
    end
    racount <= 3'(nrd > 7 ? 7 : nrd); rcount <= 8'(rvalid ? 1 : 0);
    wacount <= 6'(nwr); wcount <= 8'(wbuf.size());
    p_arv <= arvalid; p_arr <= arready; p_araddr <= araddr; p_arid <= arid; p_arlen <= arlen;
    p_awv <= awvalid; p_awr <= awready; p_awaddr <= awaddr; p_awid <= awid; p_awlen <= awlen;
    p_wv <= wvalid; p_wr <= wready; p_wdata <= wdata; p_wid <= wid; p_wlast <= wlast;
  end
endmodule
