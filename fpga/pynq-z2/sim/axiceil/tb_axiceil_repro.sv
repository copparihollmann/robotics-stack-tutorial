// tb_axiceil_repro -- the board's first transfer, replayed against a strict HP-port model.
// SIMULATION ONLY.  sim/axiceil/run_axiceil_repro.sh runs it twice: on build 1's RTL (git
// 4ab15e4, the bitstream that hung S_AXI_HP0 on 2026-09-16) and on the current RTL.
//
// The transfer: HP0, write, 16-beat bursts, 8 outstanding, region at 0x1000_0000, bounded by
// a burst count -- run_axiceil.py's prep write, scaled from 262,144 bursts to 256.  The port
// model enforces an issuing capability of 8 and stalls AWREADY/WREADY at random, as a busy
// AFI does.  `strict` counts every W beat that reaches the port before its burst's AW has
// been accepted; `orphan_early` makes the model never answer such a burst, which is the
// hypothesised AFI behaviour (write command released on WLAST enqueue).
//
// It prints REPRO lines that the script checks: how many early W beats, whether the run
// finished, whether abort drained, and how many writes the port still holds.
`timescale 1ns/1ps
module tb_axiceil_repro;
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic orphan = 1;
  int lag = 0;
  initial begin
    if ($test$plusargs("no_orphan")) orphan = 0;
    void'($value$plusargs("lag=%d", lag));
  end

  logic [11:0] gawid = 0, garid = 0; logic [31:0] gawaddr = 0, garaddr = 0, gwdata = 0;
  logic [3:0] gawlen = 0, garlen = 0, gwstrb = 4'hF;
  logic gawvalid = 0, gwvalid = 0, gwlast = 1, garvalid = 0, gbready = 1, grready = 1;
  wire gawready, gwready, gbvalid, garready, grvalid, grlast;
  wire [11:0] gbid, grid; wire [1:0] gbresp, grresp; wire [31:0] grdata;

  wire [23:0]  hp_awid, hp_wid, hp_arid, hp_wacount_unused;
  wire [127:0] hp_awaddr, hp_araddr;
  wire [15:0]  hp_awlen, hp_arlen;
  wire [255:0] hp_wdata;
  wire [3:0]   hp_awvalid, hp_wlast, hp_wvalid, hp_bready, hp_arvalid, hp_rready, leds;
  // port 0 is modelled; ports 1-3 are never enabled and see an idle bus
  wire [5:0] bid0, rid0; wire [63:0] rdata0; wire [1:0] bresp0, rresp0;
  wire awready0, wready0, bvalid0, arready0, rvalid0, rlast0;
  wire [2:0] racount0; wire [7:0] rcount0, wcount0; wire [5:0] wacount0;
  int merr, moob, mir, miw, early;

  axiceil_core #(.N_PORTS(4)) dut (
    .clk(clk), .rstn(rstn),
    .s_awid(gawid), .s_awaddr(gawaddr), .s_awlen(gawlen), .s_awvalid(gawvalid), .s_awready(gawready),
    .s_wdata(gwdata), .s_wstrb(gwstrb), .s_wlast(gwlast), .s_wvalid(gwvalid), .s_wready(gwready),
    .s_bid(gbid), .s_bresp(gbresp), .s_bvalid(gbvalid), .s_bready(gbready),
    .s_arid(garid), .s_araddr(garaddr), .s_arlen(garlen), .s_arvalid(garvalid), .s_arready(garready),
    .s_rdata(grdata), .s_rresp(grresp), .s_rid(grid), .s_rlast(grlast), .s_rvalid(grvalid),
    .s_rready(grready),
    .hp_awid(hp_awid), .hp_awaddr(hp_awaddr), .hp_awlen(hp_awlen), .hp_awvalid(hp_awvalid),
    .hp_awready({3'b000, awready0}), .hp_wid(hp_wid), .hp_wdata(hp_wdata), .hp_wlast(hp_wlast),
    .hp_wvalid(hp_wvalid), .hp_wready({3'b000, wready0}), .hp_bid({18'd0, bid0}), .hp_bresp({6'd0, bresp0}),
    .hp_bvalid({3'b000, bvalid0}), .hp_bready(hp_bready), .hp_arid(hp_arid), .hp_araddr(hp_araddr),
    .hp_arlen(hp_arlen), .hp_arvalid(hp_arvalid), .hp_arready({3'b000, arready0}), .hp_rid({18'd0, rid0}),
    .hp_rdata({192'd0, rdata0}), .hp_rresp({6'd0, rresp0}), .hp_rlast({3'b000, rlast0}), .hp_rvalid({3'b000, rvalid0}),
    .hp_rready(hp_rready), .hp_racount({9'd0, racount0}), .hp_rcount({24'd0, rcount0}),
    .hp_wacount({18'd0, wacount0}), .hp_wcount({24'd0, wcount0}), .leds(leds)
  );

  axi3_hp_model #(.CAP(8), .SEED(7)) u_m (
    .clk(clk), .rst(!rstn), .mode(2'd0),
    .hold_aw(1'b0), .hold_ar(1'b0), .hold_w(1'b0), .hold_b(1'b0), .hold_r(1'b0), .id_hi(2'b00),
    .strict(1'b1), .orphan_early(orphan), .cap_lag(lag), .resp_code(2'b00), .early_w(early),
    .inflight_rd(mir), .inflight_wr(miw),
    .awid(hp_awid[5:0]), .awaddr(hp_awaddr[31:0]), .awlen(hp_awlen[3:0]), .awvalid(hp_awvalid[0]), .awready(awready0),
    .wid(hp_wid[5:0]), .wdata(hp_wdata[63:0]), .wlast(hp_wlast[0]), .wvalid(hp_wvalid[0]), .wready(wready0),
    .bid(bid0), .bresp(bresp0), .bvalid(bvalid0), .bready(hp_bready[0]),
    .arid(hp_arid[5:0]), .araddr(hp_araddr[31:0]), .arlen(hp_arlen[3:0]), .arvalid(hp_arvalid[0]), .arready(arready0),
    .rid(rid0), .rdata(rdata0), .rresp(rresp0), .rlast(rlast0), .rvalid(rvalid0), .rready(hp_rready[0]),
    .racount(racount0), .rcount(rcount0), .wacount(wacount0), .wcount(wcount0),
    .errors(merr), .oob(moob)
  );

  task automatic gp_write(input logic [11:0] off, input logic [31:0] data);
    bit aw_done = 0, w_done = 0, aw_hs, w_hs; int n = 0;
    @(negedge clk);
    gawaddr = 32'h4000_0000 | off; gawid = 12'h5A5; gwdata = data; gwvalid = 1; gawvalid = 1;
    while (!(aw_done && w_done)) begin
      aw_hs = gawvalid && gawready; w_hs = gwvalid && gwready;
      @(negedge clk);
      if (aw_hs) begin aw_done = 1; gawvalid = 0; end
      if (w_hs)  begin w_done = 1;  gwvalid = 0; end
      n = n + 1; if (n > 200) begin $display("REPRO_FAIL GP0 write hung"); $finish; end
    end
    n = 0;
    while (!gbvalid) begin @(negedge clk); n = n + 1; if (n > 200) begin $display("REPRO_FAIL no B"); $finish; end end
    @(negedge clk);
  endtask
  task automatic gp_read(input logic [11:0] off, output logic [31:0] data);
    int n = 0; bit hs;
    @(negedge clk);
    garaddr = 32'h4000_0000 | off; garid = 12'h3C3; garlen = 0; garvalid = 1;
    do begin hs = garvalid && garready; @(negedge clk); n = n + 1; if (n > 200) begin $display("REPRO_FAIL AR hung"); $finish; end end while (!hs);
    garvalid = 0; n = 0;
    while (!grvalid) begin @(negedge clk); n = n + 1; if (n > 200) begin $display("REPRO_FAIL no R"); $finish; end end
    data = grdata;
    @(negedge clk);
  endtask

  logic [31:0] st, bl, bh;
  int finished, drained;
  initial begin
    repeat (5) @(negedge clk); rstn = 1; repeat (5) @(negedge clk);
    // run_axiceil.py configure(): MODE = wr | (16-1)<<4 | 8<<8 | 8<<16
    gp_write(12'h100, 32'h0008_08F2);
    gp_write(12'h104, 32'h1000_0000); gp_write(12'h108, 4096);
    gp_write(12'h10C, 32'h1000_0000); gp_write(12'h110, 4096);
    gp_write(12'h114, 0); gp_write(12'h118, 32'h1357_9BDF);
    gp_write(12'h11C, 0); gp_write(12'h120, 256);
    gp_write(12'h010, 1); gp_write(12'h014, 32'h7FFF_FFFF); gp_write(12'h000, 1);
    finished = 0;
    for (int n = 0; n < 100; n++) begin
      repeat (1000) @(negedge clk);
      gp_read(12'h008, st); if (st[0] == 0) begin finished = 1; break; end
    end
    drained = finished;
    if (!finished) begin
      gp_write(12'h000, 2);                       // abort, as the runner did
      for (int n = 0; n < 30; n++) begin
        repeat (1000) @(negedge clk);
        gp_read(12'h008, st); if (st[0] == 0) begin drained = 1; break; end
      end
    end
    gp_read(12'h164, bl); gp_read(12'h168, bh);   // B_BEATS_TOT
    $display("REPRO: cap_lag=%0d orphan_early=%0d early_w=%0d finished=%0d abort_drained=%0d port_holds_writes=%0d b_beats=%0d model_errors=%0d oob=%0d",
             lag, orphan, early, finished, drained, miw, {bh, bl}, merr, moob);
    $finish;
  end
endmodule
