// tb_axiceil -- self-checking testbench for the interface-ceiling instrument.  SIMULATION ONLY.
//
// Drives axiceil_core (the exact module axiceil_top.v puts in the bitstream) over a GP0
// bus-functional model that does what the PS does -- write data before its address, non-zero
// and varying AXI IDs -- and puts one axi3_hp_model on each HP port.
//
// What has to hold before this goes near a board, because the board's DDR is shared with
// Linux and its GP0 port has no timeout:
//   * the register file: MAGIC, RID/BID echo, W-before-AW, read-back of every config word;
//   * the guard: every boundary of 0x1000_0000..0x2000_0000, on its own, exhaustively around
//     the edges; and a mis-configured region never reaches a model;
//   * the data path: write a region, read it back with 0 errors, under random latency,
//     out-of-order responses and interleaved read data, on four ports at once, for every
//     burst length and outstanding count the lab sweeps;
//   * the checker catches what it must: a wrong seed reads as errors;
//   * the measurement: against an ideal port (no latency, never stalls) a read-only, a
//     write-only and a mixed window must each read one beat per fabric cycle -- 8.00 B/cycle
//     per direction.  That is the instrument's own ceiling, so a board number below it is a
//     number about the PS.
//   * abort drains; a start while busy is refused.
`timescale 1ns/1ps
module tb_axiceil;
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;

  // ---------------- GP0 BFM signals
  logic [11:0] gawid = 0, garid = 0; logic [31:0] gawaddr = 0, garaddr = 0, gwdata = 0;
  logic [3:0] gawlen = 0, garlen = 0, gwstrb = 4'hF;
  logic gawvalid = 0, gwvalid = 0, gwlast = 1, garvalid = 0, gbready = 1, grready = 1;
  wire gawready, gwready, gbvalid, garready, grvalid, grlast;
  wire [11:0] gbid, grid; wire [1:0] gbresp, grresp; wire [31:0] grdata;

  // ---------------- HP ports
  wire [23:0]  hp_awid, hp_wid, hp_bid, hp_arid, hp_rid, hp_wacount;
  wire [127:0] hp_awaddr, hp_araddr;
  wire [15:0]  hp_awlen, hp_arlen;
  wire [255:0] hp_wdata, hp_rdata;
  wire [7:0]   hp_bresp, hp_rresp;
  wire [3:0]   hp_awvalid, hp_awready, hp_wlast, hp_wvalid, hp_wready, hp_bvalid, hp_bready;
  wire [3:0]   hp_arvalid, hp_arready, hp_rlast, hp_rvalid, hp_rready;
  wire [11:0]  hp_racount;
  wire [31:0]  hp_rcount, hp_wcount;
  wire [3:0]   leds;
  logic [1:0]  mmode [4];
  int          merr [4], moob [4], mir [4], miw [4], mearly [4];
  logic        h_aw [4], h_ar [4], h_w [4], h_b [4], h_r [4];
  logic [1:0]  idhi [4], rcode [4];

  axiceil_core #(.N_PORTS(4)) dut (
    .clk(clk), .rstn(rstn),
    .s_awid(gawid), .s_awaddr(gawaddr), .s_awlen(gawlen), .s_awvalid(gawvalid), .s_awready(gawready),
    .s_wdata(gwdata), .s_wstrb(gwstrb), .s_wlast(gwlast), .s_wvalid(gwvalid), .s_wready(gwready),
    .s_bid(gbid), .s_bresp(gbresp), .s_bvalid(gbvalid), .s_bready(gbready),
    .s_arid(garid), .s_araddr(garaddr), .s_arlen(garlen), .s_arvalid(garvalid), .s_arready(garready),
    .s_rdata(grdata), .s_rresp(grresp), .s_rid(grid), .s_rlast(grlast), .s_rvalid(grvalid),
    .s_rready(grready),
    .hp_awid(hp_awid), .hp_awaddr(hp_awaddr), .hp_awlen(hp_awlen), .hp_awvalid(hp_awvalid),
    .hp_awready(hp_awready), .hp_wid(hp_wid), .hp_wdata(hp_wdata), .hp_wlast(hp_wlast),
    .hp_wvalid(hp_wvalid), .hp_wready(hp_wready), .hp_bid(hp_bid), .hp_bresp(hp_bresp),
    .hp_bvalid(hp_bvalid), .hp_bready(hp_bready), .hp_arid(hp_arid), .hp_araddr(hp_araddr),
    .hp_arlen(hp_arlen), .hp_arvalid(hp_arvalid), .hp_arready(hp_arready), .hp_rid(hp_rid),
    .hp_rdata(hp_rdata), .hp_rresp(hp_rresp), .hp_rlast(hp_rlast), .hp_rvalid(hp_rvalid),
    .hp_rready(hp_rready), .hp_racount(hp_racount), .hp_rcount(hp_rcount),
    .hp_wacount(hp_wacount), .hp_wcount(hp_wcount), .leds(leds)
  );

  genvar g;
  generate for (g = 0; g < 4; g++) begin : m
    axi3_hp_model #(.CAP(8), .SEED(g + 11)) u (
      .clk(clk), .rst(!rstn), .mode(mmode[g]),
      .hold_aw(h_aw[g]), .hold_ar(h_ar[g]), .hold_w(h_w[g]), .hold_b(h_b[g]), .hold_r(h_r[g]),
      .id_hi(idhi[g]), .inflight_rd(mir[g]), .inflight_wr(miw[g]),
      .strict(1'b1), .orphan_early(1'b0), .cap_lag(g == 3 ? 24 : 0), .resp_code(rcode[g]), .early_w(mearly[g]),
      .awid(hp_awid[6*g +: 6]), .awaddr(hp_awaddr[32*g +: 32]), .awlen(hp_awlen[4*g +: 4]),
      .awvalid(hp_awvalid[g]), .awready(hp_awready[g]),
      .wid(hp_wid[6*g +: 6]), .wdata(hp_wdata[64*g +: 64]), .wlast(hp_wlast[g]),
      .wvalid(hp_wvalid[g]), .wready(hp_wready[g]),
      .bid(hp_bid[6*g +: 6]), .bresp(hp_bresp[2*g +: 2]), .bvalid(hp_bvalid[g]), .bready(hp_bready[g]),
      .arid(hp_arid[6*g +: 6]), .araddr(hp_araddr[32*g +: 32]), .arlen(hp_arlen[4*g +: 4]),
      .arvalid(hp_arvalid[g]), .arready(hp_arready[g]),
      .rid(hp_rid[6*g +: 6]), .rdata(hp_rdata[64*g +: 64]), .rresp(hp_rresp[2*g +: 2]),
      .rlast(hp_rlast[g]), .rvalid(hp_rvalid[g]), .rready(hp_rready[g]),
      .racount(hp_racount[3*g +: 3]), .rcount(hp_rcount[8*g +: 8]),
      .wacount(hp_wacount[6*g +: 6]), .wcount(hp_wcount[8*g +: 8]),
      .errors(merr[g]), .oob(moob[g])
    );
  end endgenerate

  int errors = 0;
  task automatic chk(input bit cond, input string what);
    if (!cond) begin $display("  FAIL  %s", what); errors++; end
    else         $display("  pass  %s", what);
  endtask

  // ---------------- GP0 BFM (drives on negedge, so handshakes are unambiguous at posedge)
  int order_ctr = 0;
  task automatic gp_write(input logic [11:0] off, input logic [31:0] data);
    bit aw_done = 0, w_done = 0, aw_hs, w_hs; int n = 0; int order; logic [11:0] id;
    order = order_ctr % 3; order_ctr = order_ctr + 1;          // 0 together, 1 AW first, 2 W first (the PS's habit)
    id = 12'($urandom);
    @(negedge clk);
    gawaddr = 32'h4000_0000 | off; gawid = id; gwdata = data; gwlast = 1; gwstrb = 4'hF;
    if (order != 2) gawvalid = 1;
    if (order != 1) gwvalid = 1;
    while (!(aw_done && w_done)) begin
      aw_hs = gawvalid && gawready; w_hs = gwvalid && gwready;
      @(negedge clk);
      if (aw_hs) begin aw_done = 1; gawvalid = 0; end
      if (w_hs)  begin w_done = 1;  gwvalid = 0; end
      n++;
      if (order == 1 && aw_done && !w_done && !gwvalid) gwvalid = 1;
      if (order == 2 && n >= 3 && !aw_done && !gawvalid) gawvalid = 1;
      if (n > 200) begin $display("  FAIL  GP0 write handshake hung at %h", off); errors++; $finish; end
    end
    n = 0;
    while (!gbvalid) begin @(negedge clk); n = n + 1; if (n > 200) begin $display("  FAIL  no B"); errors++; $finish; end end
    if (gbid != id) begin $display("  FAIL  BID %h != AWID %h", gbid, id); errors++; end
    @(negedge clk);
  endtask

  task automatic gp_read(input logic [11:0] off, output logic [31:0] data);
    int n = 0; logic [11:0] id; bit hs;
    id = 12'($urandom);
    @(negedge clk);
    garaddr = 32'h4000_0000 | off; garid = id; garlen = 0; garvalid = 1;
    do begin hs = garvalid && garready; @(negedge clk); n = n + 1; if (n > 200) begin $display("  FAIL  AR hung"); errors++; $finish; end end while (!hs);
    garvalid = 0;
    n = 0;
    while (!grvalid) begin @(negedge clk); n = n + 1; if (n > 200) begin $display("  FAIL  no R"); errors++; $finish; end end
    data = grdata;
    if (grid != id) begin $display("  FAIL  RID %h != ARID %h", grid, id); errors++; end
    if (!grlast) begin $display("  FAIL  RLAST low on a single-beat read"); errors++; end
    @(negedge clk);
  endtask

  function automatic logic [11:0] P(input int port, input int idx); return 12'((port + 1) * 256 + idx); endfunction

  task automatic cfg_port(input int p, input bit rd, input bit wr, input int len, input int krd,
                          input int kwr, input logic [31:0] rdb, input int rdw, input logic [31:0] wrb,
                          input int wrw, input logic [31:0] rds, input logic [31:0] wrs,
                          input int rdm, input int wrm);
    gp_write(P(p, 'h00), {11'd0, 5'(kwr), 3'd0, 5'(krd), 4'(len - 1), 2'd0, wr, rd});
    gp_write(P(p, 'h04), rdb);  gp_write(P(p, 'h08), rdw);
    gp_write(P(p, 'h0C), wrb);  gp_write(P(p, 'h10), wrw);
    gp_write(P(p, 'h14), rds);  gp_write(P(p, 'h18), wrs);
    gp_write(P(p, 'h1C), rdm);  gp_write(P(p, 'h20), wrm);
  endtask

  task automatic run(input logic [3:0] ports, input int window, input int timeout);
    logic [31:0] st; int n = 0;
    gp_write('h010, ports); gp_write('h014, window); gp_write('h000, 1);
    do begin
      repeat (200) @(negedge clk);
      gp_read('h008, st);
      n = n + 1; if (n * 200 > timeout) begin $display("  FAIL  run timed out, status %h", st); errors++; return; end
    end while (st[3:0] != 0);
  endtask

  function automatic longint lohi(input logic [31:0] lo, input logic [31:0] hi); return {hi, lo}; endfunction

  logic [31:0] pa, pw, pb, pr, prl, pa0, pw0, pb0, pr0, prl0;
  task automatic pins(input int p, output logic [31:0] aw, output logic [31:0] wl, output logic [31:0] b,
                      output logic [31:0] ar, output logic [31:0] rl);
    gp_read(P(p, 'hD8), aw); gp_read(P(p, 'hDC), wl); gp_read(P(p, 'hE0), b);
    gp_read(P(p, 'hE4), ar); gp_read(P(p, 'hE8), rl);
  endtask
  // read through hierarchical references, so a function need not wait on the bus
  wire [3:0] bal;
  generate for (g = 0; g < 4; g++) begin : gbal
    assign bal[g] = dut.g_port[g].pin_aw == dut.g_port[g].pin_b && dut.g_port[g].pin_aw == dut.g_port[g].pin_wl
                    && dut.g_port[g].pin_ar == dut.g_port[g].pin_rl;
  end endgenerate
  function automatic bit pins_balanced(input int p);
    return bal[p];
  endfunction
  task automatic drained(input int p, input string what);
    logic [31:0] st, e1, e2, e3, e4, lv; int n = 0;
    do begin repeat (200) @(negedge clk); gp_read('h008, st); n++; end while (st[3:0] != 0 && n < 200);
    gp_write('h000, 0);
    stat(p, 'h6C, e1); stat(p, 'h70, e2); stat(p, 'h74, e3); stat(p, 'h78, e4); gp_read(P(p, 'hF0), lv);
    chk(st[3:0] == 0 && e1 == 0 && e2 == 0 && e3 == 0 && e4 == 0 && lv[14:0] == 0 && pins_balanced(p)
        && miw[p] == 0 && mir[p] == 0, $sformatf("%s (STATUS %h, LIVE %h)", what, st, lv));
  endtask

  task automatic stat(input int p, input int idx, output logic [31:0] v); gp_read(P(p, idx), v); endtask
  task automatic stat40(input int p, input int idx, output longint v);
    logic [31:0] lo, hi; gp_read(P(p, idx), lo); gp_read(P(p, idx + 4), hi); v = lohi(lo, hi);
  endtask

  // ---------------- guard, standalone and exhaustive at the edges
  logic [31:0] ga; logic [3:0] gl; logic gv; logic grst = 1;
  wire g_awv, g_awr, g_arv, g_arr, g_fault, g_fw; wire [31:0] g_fa;
  // With m_awready tied high the guard's slice never fills, so s_awready is exactly the check.
  axiceil_guard u_g (.clk(clk), .rst(grst), .s_awid(6'd0), .s_awaddr(ga), .s_awlen(gl), .s_awsize(3'b011),
    .s_awburst(2'b01), .s_awvalid(gv), .s_awready(g_awr), .s_arid(6'd0), .s_araddr(32'h1000_0000), .s_arlen(4'd0),
    .s_arsize(3'b011), .s_arburst(2'b01), .s_arvalid(1'b0), .s_arready(),
    .m_awid(), .m_awaddr(), .m_awlen(), .m_awvalid(g_awv), .m_awready(1'b1),
    .m_arid(), .m_araddr(), .m_arlen(), .m_arvalid(), .m_arready(1'b1),
    .fault(g_fault), .fault_addr(g_fa), .fault_is_write(g_fw));

  function automatic bit ref_ok(input logic [31:0] a, input logic [3:0] l);
    longint e; e = longint'(a) + (longint'(l) + 1) * 8;
    return (a >= 32'h1000_0000) && (e <= 64'h2000_0000) && (a[2:0] == 0) && (int'(a[11:0]) + (int'(l) + 1) * 8 <= 4096);
  endfunction

  logic [31:0] v, v2; longint w0, w1, w2, w3;
  int bad;
  localparam logic [31:0] BASE = 32'h1000_0000;

  initial begin
    for (int i = 0; i < 4; i++) begin
      mmode[i] = 0; h_aw[i] = 0; h_ar[i] = 0; h_w[i] = 0; h_b[i] = 0; h_r[i] = 0; idhi[i] = 0; rcode[i] = 0;
    end
    gv = 0; ga = 0; gl = 0;
    repeat (5) @(negedge clk);
    rstn = 1;
    repeat (5) @(negedge clk);

    $display("== guard, standalone");
    bad = 0;
    for (longint a = 32'h0FFF_FF00; a <= 32'h1000_0100; a += 4)
      for (int l = 0; l < 16; l++) begin
        ga = 32'(a); gl = 4'(l); gv = 1; #1;
        if (g_awr != ref_ok(ga, gl)) bad++;
      end
    for (longint a = 32'h1FFF_FE00; a <= 32'h2000_0100; a += 4)
      for (int l = 0; l < 16; l++) begin
        ga = 32'(a); gl = 4'(l); gv = 1; #1;
        if (g_awr != ref_ok(ga, gl)) bad++;
      end
    for (int i = 0; i < 200000; i++) begin
      ga = $urandom; if (i % 2) ga[31:28] = 4'h1; if (i % 3) ga[2:0] = 0; gl = 4'($urandom); gv = 1; #1;
      if (g_awr != ref_ok(ga, gl)) bad++;
    end
    chk(bad == 0, $sformatf("guard agrees with the reference at both edges and 200k random points (%0d disagreements)", bad));
    gv = 0; grst = 1; @(negedge clk); grst = 0; @(negedge clk);
    chk(!g_fault, "guard fault clears on reset");
    ga = 32'h1FFF_FF80; gl = 4'd15; gv = 1; @(negedge clk);
    chk(!g_fault, "a 16-beat burst ending exactly at 0x2000_0000 is not a fault");
    ga = 32'h1FFF_FF88; gl = 4'd15; gv = 1; @(negedge clk);
    chk(g_fault && g_fw && g_fa == 32'h1FFF_FF88, "guard latches fault + address for a burst ending 8 bytes past 0x2000_0000");
    gv = 0;

    $display("== GP0 register file");
    gp_read('h004, v);  chk(v == 32'h5A5A_0020, $sformatf("MAGIC reads 0x5A5A0020 (%h)", v));
    gp_read('h02C, v);  chk(v == 32'h1000_0000, "REGION_LO = 0x1000_0000");
    gp_read('h030, v);  chk(v == 32'h2000_0000, "REGION_HI = 0x2000_0000");
    gp_read('h028, v);  chk(v[31:24] == 4 && v[23:16] == 16 && v[15:8] == 6, $sformatf("BUILD = %h (4 ports, 16 IDs, version 6)", v));
    bad = 0;
    for (int i = 0; i < 6; i++) begin
      gp_write('h038, 32'hC0DE_0000 + i); gp_read('h038, v); if (v != 32'hC0DE_0000 + i) bad++;
    end
    chk(bad == 0, "SCRATCH round-trips under all three AW/W orderings");
    cfg_port(2, 1, 1, 7, 5, 6, 32'h1234_5678, 11, 32'h2345_6789, 12, 32'h3456_789A, 32'h4567_89AB, 13, 14);
    bad = 0;
    begin
      logic [31:0] want [9];
      want = '{{11'd0, 5'd6, 3'd0, 5'd5, 4'd6, 2'd0, 1'b1, 1'b1}, 32'h1234_5678, 11, 32'h2345_6789, 12,
               32'h3456_789A, 32'h4567_89AB, 13, 14};
      for (int i = 0; i < 9; i++) begin gp_read(P(2, 4 * i), v); if (v != want[i]) begin bad++; $display("    +%0h = %h want %h", 4*i, v, want[i]); end end
    end
    chk(bad == 0, "port 2's nine config words read back");
    gp_read(P(0, 'h30), v); chk(v == 32'hDEAD_BEEF, "an unmapped port offset reads 0xDEADBEEF");

    $display("== a region outside the window is refused before it reaches the port");
    cfg_port(1, 0, 1, 16, 1, 4, BASE, 64, 32'h0FFF_F000, 512, 0, 1, 0, 4);
    run(4'b0010, 1000, 100000);
    gp_read(P(1, 'h40), v);
    chk(v[3] == 1 && v[4] == 0, $sformatf("cfg_err_wr set, guard untouched (PSTAT %h)", v));
    cfg_port(1, 0, 1, 16, 1, 4, BASE, 64, 32'h1FFF_F000, 1024, 0, 1, 0, 1);
    run(4'b0010, 1000, 100000);
    gp_read(P(1, 'h40), v);
    chk(v[3] == 1, $sformatf("a region a page past 0x2000_0000 is refused (PSTAT %h)", v));
    cfg_port(1, 0, 1, 16, 1, 4, BASE, 64, 32'h1FFF_F000, 512, 0, 7, 0, 32);
    run(4'b0010, 1000, 100000);
    gp_read(P(1, 'h40), v); stat(1, 'h74, v2);
    chk(v[3] == 0 && v[4] == 0 && v2 == 0, $sformatf("a burst ending exactly at 0x2000_0000 is accepted (PSTAT %h)", v));
    chk(moob[0] + moob[1] + moob[2] + moob[3] == 0, "no request outside the window ever reached a model");

    $display("== write a region, read it back: 4 ports at once, random ports, every burst length");
    for (int i = 0; i < 4; i++) mmode[i] = (i == 3) ? 2 : 0;
    begin
      int lens [4] = '{1, 4, 8, 16};
      int ks [4]   = '{1, 3, 8, 16};
      for (int i = 0; i < 4; i++)
        cfg_port(i, 0, 1, lens[i], ks[i], ks[i], BASE + i * 32'h0100_0000, 4096,
                 BASE + i * 32'h0100_0000, 4096, 32'h1111 * (i + 1), 32'h1111 * (i + 1),
                 0, 4096 / lens[i]);
      run(4'b1111, 32'h7FFF_FFFF, 5000000);
      bad = 0;
      for (int i = 0; i < 4; i++) begin
        stat40(i, 'h64, w0); stat(i, 'h74, v); stat(i, 'h78, v2);
        if (w0 != 4096 || v != 0 || v2 != 0) begin bad++; $display("    port %0d: b_beats %0d wr_err %0d wr_proto %0d", i, w0, v, v2); end
      end
      chk(bad == 0, "every port wrote 4096 words, all B OKAY, no protocol errors");
      for (int i = 0; i < 4; i++)
        cfg_port(i, 1, 0, lens[3 - i], ks[3 - i], 1, BASE + i * 32'h0100_0000, 4096, BASE, 64,
                 32'h1111 * (i + 1), 0, 4096 / lens[3 - i], 0);
      run(4'b1111, 32'h7FFF_FFFF, 5000000);
      bad = 0;
      for (int i = 0; i < 4; i++) begin
        stat40(i, 'h5C, w0); stat(i, 'h6C, v); stat(i, 'h70, v2);
        if (w0 != 4096 || v != 0 || v2 != 0) begin bad++; $display("    port %0d: rd_beats %0d rd_err %0d rd_proto %0d", i, w0, v, v2); end
        stat(i, 'hA8, v);
        // The model withholds ARREADY at CAP = 8; requests queued in front of it (the master's
        // output register, the guard's slice) count as outstanding too, so the peak lies
        // between min(asked, 8) and asked.
        if (v[4:0] > ks[3 - i] || v[4:0] < ((ks[3 - i] < 8) ? ks[3 - i] : 8)) begin bad++; $display("    port %0d: peak outstanding %0d, asked %0d", i, v[4:0], ks[3 - i]); end
      end
      chk(bad == 0, "every port read 4096 words back with 0 errors, min(asked, 8) <= peak outstanding <= asked");
      // the checker must catch a wrong seed
      cfg_port(0, 1, 0, 16, 8, 1, BASE, 4096, BASE, 64, 32'h9999, 0, 256, 0);
      run(4'b0001, 32'h7FFF_FFFF, 5000000);
      stat(0, 'h6C, v);
      chk(v == 4096, $sformatf("a wrong seed reads as 4096 errors (%0d)", v));
    end

    $display("== mixed read+write on each port under windows that wrap, then verify");
    for (int i = 0; i < 4; i++) mmode[i] = 2;
    for (int i = 0; i < 4; i++)
      cfg_port(i, 1, 1, 8, 6, 5, BASE + i * 32'h0100_0000, 4096, BASE + i * 32'h0100_0000 + 32'h0010_0000, 512,
               32'h1111 * (i + 1), 32'hABC0 + i, 0, 0);
    run(4'b1111, 60000, 5000000);
    bad = 0;
    for (int i = 0; i < 4; i++) begin
      stat(i, 'h6C, v); stat(i, 'h70, v2); if (v || v2) bad++;
      stat(i, 'h74, v); stat(i, 'h78, v2); if (v || v2) bad++;
      stat(i, 'h80, v); if (v < 64) begin bad++; $display("    port %0d: only %0d write bursts, region not wrapped", i, v); end
    end
    chk(bad == 0, "mixed windows: 0 read errors, 0 write errors, every write region wrapped at least once");
    for (int i = 0; i < 4; i++)
      cfg_port(i, 1, 0, 16, 16, 1, BASE + i * 32'h0100_0000 + 32'h0010_0000, 512, BASE, 64, 32'hABC0 + i, 0, 32, 0);
    run(4'b1111, 32'h7FFF_FFFF, 5000000);
    bad = 0;
    for (int i = 0; i < 4; i++) begin
      stat40(i, 'h5C, w0); stat(i, 'h6C, v); if (w0 != 512 || v != 0) begin bad++; $display("    port %0d: %0d beats, %0d errors", i, w0, v); end
    end
    chk(bad == 0, "the regions written during those windows verify with 0 errors");

    $display("== the instrument's own ceiling: an ideal port reads one beat per cycle");
    for (int i = 0; i < 4; i++) mmode[i] = 1;
    cfg_port(0, 1, 0, 16, 8, 1, BASE, 4096, BASE, 64, 32'h1111, 0, 0, 0);
    run(4'b0001, 100000, 5000000);
    stat40(0, 'h44, w0); stat(0, 'h6C, v);
    chk(w0 >= 99900 && w0 <= 100000 && v == 0, $sformatf("read-only, 16 beats x 8 out: %0d beats in 100000 cycles = %.4f B/cycle", w0, 8.0 * w0 / 100000));
    cfg_port(0, 0, 1, 16, 1, 8, BASE, 4096, BASE + 32'h0020_0000, 4096, 0, 32'h7777, 0, 0);
    run(4'b0001, 100000, 5000000);
    stat40(0, 'h4C, w0); stat40(0, 'h54, w1); stat(0, 'h74, v);
    chk(w0 >= 99900 && w1 >= 99800 && v == 0, $sformatf("write-only: %0d W beats, %0d B-acked beats in 100000 cycles = %.4f B/cycle", w0, w1, 8.0 * w0 / 100000));
    cfg_port(0, 1, 1, 16, 8, 8, BASE, 4096, BASE + 32'h0020_0000, 4096, 32'h1111, 32'h7777, 0, 0);
    cfg_port(2, 1, 1, 1, 16, 16, BASE + 32'h0200_0000, 4096, BASE + 32'h0220_0000, 4096, 32'h3333, 32'h5555, 0, 0);
    run(4'b0101, 100000, 5000000);
    stat40(0, 'h44, w0); stat40(0, 'h4C, w1); stat40(2, 'h44, w2); stat40(2, 'h4C, w3);
    chk(w0 >= 99900 && w1 >= 99900, $sformatf("mixed, 16-beat bursts: rd %0d + wr %0d beats = %.3f B/cycle on one port", w0, w1, 8.0 * (w0 + w1) / 100000));
    chk(w2 >= 99000 && w3 >= 99000, $sformatf("mixed, 1-beat bursts, 16 out: rd %0d + wr %0d beats (%.3f B/cycle)", w2, w3, 8.0 * (w2 + w3) / 100000));
    stat(0, 'h84, v); stat(0, 'h90, v2);
    $display("    port 0 ideal: AR stalls %0d, R gaps %0d", v, v2);

    $display("== abort drains, and a start while busy is refused");
    for (int i = 0; i < 4; i++) mmode[i] = 0;
    cfg_port(0, 1, 1, 8, 8, 8, BASE, 4096, BASE + 32'h0020_0000, 4096, 32'h1111, 32'h7777, 0, 0);
    gp_write('h010, 1); gp_write('h014, 32'h7FFF_FFFF); gp_write('h000, 1);
    repeat (500) @(negedge clk);
    gp_write('h000, 1);
    gp_read('h008, v); chk(v[17] == 1 && v[0] == 1, $sformatf("second start refused while busy (STATUS %h)", v));
    gp_write('h000, 2);
    bad = 0;
    for (int n = 0; n < 50; n++) begin repeat (200) @(negedge clk); gp_read('h008, v); if (v[3:0] == 0) break; end
    chk(v[3:0] == 0 && v[4] == 1, $sformatf("abort drained to done (STATUS %h)", v));
    stat(0, 'h6C, v); stat(0, 'h74, v2);
    chk(v == 0 && v2 == 0, "no errors across the abort");
    gp_write('h000, 0);

    $display("== every burst length the instrument issues, both directions, random, interleaved and lagging ports");
    for (int i = 0; i < 4; i++) mmode[i] = (i % 2) ? 2 : 0;
    // a region that is not a whole number of 4 KiB pages is refused
    cfg_port(0, 0, 1, 3, 1, 1, BASE, 64, BASE + 32'h0040_0000, 300, 0, 32'h5003, 0, 100);
    run(4'b0001, 1000, 100000);
    gp_read(P(0, 'h40), v);
    chk(v[3] == 1, $sformatf("a region of 300 words (not whole pages) is refused (cfg_err_wr; PSTAT %h)", v));
    bad = 0;
    for (int L = 1; L <= 16; L++) begin
      int ks [5] = '{1, 2, 3, 8, 16};
      int k = ks[L % 5];
      for (int i = 0; i < 2; i++)
        cfg_port(i, 0, 1, L, k, k, BASE, 64, BASE + 32'h0040_0000 + i * 32'h0010_0000, 2048,
                 0, 32'h5000 + L, 0, 50);
      cfg_port(3, 0, 1, L, k, k, BASE, 64, BASE + 32'h0340_0000, 2048, 0, 32'h5000 + L, 0, 50);
      run(4'b1011, 32'h7FFF_FFFF, 5000000);
      for (int i = 0; i < 2; i++)
        cfg_port(i, 1, 0, L, k, 1, BASE + 32'h0040_0000 + i * 32'h0010_0000, 2048, BASE, 64,
                 32'h5000 + L, 0, 50, 0);
      cfg_port(3, 1, 0, L, k, 1, BASE + 32'h0340_0000, 2048, BASE, 64, 32'h5000 + L, 0, 50, 0);
      run(4'b1011, 32'h7FFF_FFFF, 5000000);
      for (int i = 0; i < 4; i++) begin
        if (i == 2) continue;
        stat40(i, 'h5C, w0); stat(i, 'h6C, v); stat(i, 'h70, v2);
        if (w0 != 50 * L || v != 0 || v2 != 0) begin bad++; $display("    L=%0d k=%0d port %0d: rd_beats %0d err %0d proto %0d", L, k, i, w0, v, v2); end
        if (!pins_balanced(i)) begin bad++; $display("    L=%0d port %0d: pin counters unbalanced", L, i); end
      end
    end
    chk(bad == 0, "L = 1..16 (k cycling 1,2,3,8,16): 50 bursts written and read back on a random, an interleaving and a capability-lagging port, 0 errors, PS pins balanced");

    $display("== abort drains: mid-address, mid-burst, and with responses withheld");
    for (int i = 0; i < 4; i++) mmode[i] = 0;
    // (a) mid-address: the port never takes AW or AR until released
    h_aw[0] = 1; h_ar[0] = 1;
    cfg_port(0, 1, 1, 16, 4, 4, BASE, 4096, BASE + 32'h0020_0000, 4096, 32'h1111, 32'h7A00, 0, 0);
    pins(0, pa0, pw0, pb0, pr0, prl0);          // the pin counters are cumulative: compare deltas
    gp_write('h010, 1); gp_write('h014, 32'h7FFF_FFFF); gp_write('h000, 1);
    repeat (300) @(negedge clk);
    gp_write('h000, 2);
    repeat (300) @(negedge clk);
    gp_read('h008, v); pins(0, pa, pw, pb, pr, prl);
    chk(v[0] == 1 && pa == pa0 && pr == pr0, $sformatf("(a) abort with AW/AR refused: still busy, nothing reached the port (STATUS %h)", v));
    h_aw[0] = 0; h_ar[0] = 0;
    drained(0, "(a) released: drains to done, PS pins balanced, 0 errors");
    // (b) mid-burst: W stops being accepted part-way through bursts
    cfg_port(0, 0, 1, 16, 4, 4, BASE, 4096, BASE + 32'h0020_0000, 4096, 0, 32'h7B00, 0, 0);
    gp_write('h000, 1);
    repeat (137) @(negedge clk);
    h_w[0] = 1;
    repeat (50) @(negedge clk);
    gp_write('h000, 2);
    repeat (300) @(negedge clk);
    gp_read('h008, v); pins(0, pa, pw, pb, pr, prl);
    chk(v[0] == 1 && pa > pw, $sformatf("(b) abort mid-burst: still busy, AWs accepted %0d > bursts completed %0d", pa, pw));
    h_w[0] = 0;
    drained(0, "(b) released: drains to done, PS pins balanced, 0 errors");
    // (c) responses withheld: the port has taken commands and answers none
    cfg_port(0, 1, 1, 8, 8, 8, BASE, 4096, BASE + 32'h0020_0000, 4096, 32'h1111, 32'h7C00, 0, 0);
    gp_write('h000, 1);
    repeat (200) @(negedge clk);
    h_b[0] = 1; h_r[0] = 1;
    repeat (200) @(negedge clk);
    gp_write('h000, 2);
    repeat (2000) @(negedge clk);
    gp_read('h008, v); pins(0, pa, pw, pb, pr, prl);
    chk(v[0] == 1 && (pa != pb || pr != prl) && (pa - pb) == miw[0] && (pr - prl) == mir[0],
        $sformatf("(c) abort with responses withheld: still busy; the pins say the PS holds %0d writes + %0d reads, and so does the model", pa - pb, pr - prl));
    h_b[0] = 0; h_r[0] = 0;
    drained(0, "(c) released: drains to done, PS pins balanced, 0 errors");

    $display("== the two hang signatures, told apart by the pins");
    // (d) a port that does not echo ID[5:4]: every transaction retires at the PS, none at the master
    idhi[1] = 2'b01;
    cfg_port(1, 0, 1, 8, 2, 2, BASE, 64, BASE + 32'h0110_0000, 1024, 0, 32'h7D00, 0, 100);
    pins(1, pa0, pw0, pb0, pr0, prl0);
    gp_write('h010, 2); gp_write('h014, 32'h7FFF_FFFF); gp_write('h000, 1);
    repeat (3000) @(negedge clk);
    gp_write('h000, 2);
    repeat (1000) @(negedge clk);
    gp_read('h008, v); pins(1, pa, pw, pb, pr, prl); gp_read(P(1, 'hF0), v2);
    chk(v[1] == 1 && pa - pa0 == 2 && pb - pb0 == 2 && pw - pw0 == 2 && miw[1] == 0 && v2[30] == 1 && v2[29:24] == 6'h10,
        $sformatf("(d) ID[5:4] not echoed: master stuck, PS idle (AW +%0d = B +%0d), first unclaimed BID 0x%0h", pa - pa0, pb - pb0, v2[29:24]));
    gp_write('h000, 0);
    rstn = 0; repeat (5) @(negedge clk); rstn = 1; repeat (5) @(negedge clk);
    cfg_port(1, 0, 1, 8, 2, 2, BASE, 64, BASE + 32'h0110_0000, 1024, 0, 32'h7D00, 0, 100);
    gp_read(P(1, 'h00), v); gp_write(P(1, 'h00), v | 32'h0100_0000);
    run(4'b0010, 32'h7FFF_FFFF, 5000000);
    cfg_port(1, 1, 0, 8, 2, 2, BASE + 32'h0110_0000, 1024, BASE, 64, 32'h7D00, 0, 100, 0);
    gp_read(P(1, 'h00), v); gp_write(P(1, 'h00), v | 32'h0100_0000);
    run(4'b0010, 32'h7FFF_FFFF, 5000000);
    stat40(1, 'h5C, w0); stat(1, 'h6C, v); stat(1, 'h70, v2);
    chk(w0 == 800 && v == 0 && v2 == 0 && pins_balanced(1), "(d) after PL reset, MODE[24] id_lo_only: 800 words written and read back, 0 errors");
    idhi[1] = 0; gp_write(P(1, 'h00), 32'h0001_0101);
    // (e) a port that holds B forever: abort cannot drain, and the pins say why
    h_b[2] = 1;
    cfg_port(2, 0, 1, 8, 3, 3, BASE, 64, BASE + 32'h0210_0000, 1024, 0, 32'h7E00, 0, 100);
    pins(2, pa0, pw0, pb0, pr0, prl0);
    gp_write('h010, 4); gp_write('h014, 32'h7FFF_FFFF); gp_write('h000, 1);
    repeat (2000) @(negedge clk);
    gp_write('h000, 2);
    repeat (2000) @(negedge clk);
    gp_read('h008, v); pins(2, pa, pw, pb, pr, prl);
    chk(v[2] == 1 && pa - pa0 == 3 && pb == pb0 && miw[2] == 3, $sformatf("(e) B withheld: abort cannot drain; the pins say the PS holds %0d", pa - pb));
    h_b[2] = 0;
    drained(2, "(e) released: drains to done, PS pins balanced, 0 errors");

    $display("== error responses: the exact code is kept, the run still finishes");
    rcode[2] = 2'b11; rcode[3] = 2'b10;
    for (int i = 2; i < 4; i++)
      cfg_port(i, 0, 1, 4, 2, 2, BASE, 64, BASE + i * 32'h0100_0000 + 32'h0060_0000, 512, 0, 32'h7F00, 0, 5);
    run(4'b1100, 32'h7FFF_FFFF, 5000000);
    stat(2, 'h74, pa0); stat(3, 'h74, pb0);      // write errors, before the read run clears them
    for (int i = 2; i < 4; i++)
      cfg_port(i, 1, 0, 4, 2, 1, BASE + i * 32'h0100_0000 + 32'h0060_0000, 512, BASE, 64, 32'h7F00, 0, 5, 0);
    run(4'b1100, 32'h7FFF_FFFF, 5000000);
    bad = 0;
    for (int i = 2; i < 4; i++) begin
      logic [31:0] first, counts, we, re;
      gp_read(P(i, 'hF8), first); gp_read(P(i, 'hFC), counts); stat(i, 'h74, we); stat(i, 'h6C, re);
      if (first[13] != 1 || first[12:11] != rcode[i] || first[7] != 1 || first[6:5] != rcode[i]) bad++;
      if (rcode[i] == 2'b11 && counts != {8'd0, 8'd5, 8'd0, 8'd20}) bad++;
      if (rcode[i] == 2'b10 && counts != {8'd5, 8'd0, 8'd20, 8'd0}) bad++;
      we = (i == 2) ? pa0 : pb0;
      if (we != 5 || re != 20) bad++;
      $display("    port %0d: RESP_FIRST %h RESP_COUNTS %h wr_err %0d rd_err %0d", i, first, counts, we, re);
    end
    chk(bad == 0 && pins_balanced(2) && pins_balanced(3), "DECERR on HP2 and SLVERR on HP3: first codes kept, 5 B + 20 R counted per code, runs finish, pins balanced");
    rcode[2] = 0; rcode[3] = 0;

    $display("== models");
    chk(merr[0] + merr[1] + merr[2] + merr[3] == 0, $sformatf("strict port models saw no protocol violations (%0d/%0d/%0d/%0d)", merr[0], merr[1], merr[2], merr[3]));
    chk(mearly[0] + mearly[1] + mearly[2] + mearly[3] == 0, $sformatf("no W beat ever reached a port before its AW was accepted (%0d/%0d/%0d/%0d)", mearly[0], mearly[1], mearly[2], mearly[3]));
    chk(moob[0] + moob[1] + moob[2] + moob[3] == 0, "and no out-of-window request, ever");

    if (errors == 0) $display("ALL CHECKS PASSED");
    else $display("%0d CHECK(S) FAILED", errors);
    $finish;
  end

  initial begin #2000000000; $display("  FAIL  global timeout"); $finish; end
endmodule
