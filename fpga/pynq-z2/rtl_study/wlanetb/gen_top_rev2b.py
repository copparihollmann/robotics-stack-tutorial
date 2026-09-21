#!/usr/bin/env python3
"""SIMULATION ONLY.  The FINAL W-lane gate bench: rtl/gen2b/ around the GENERATED revision-2b design of
PynqZ2RocketBigLittlePextTacitMicRgbRoccMoon2bCheckConfig (MEMORY_BANDWIDTH.md s9.9, design (ii'), P4 at 433898d).

Real, generated, unmodified:
  RoccMoonEngine2b       mbxr_engine_core (W_ASYNC = 1) on the engine clock, its RoCC command ports driven by the bench
                         exactly as RoccMoonShim drives them (one cycle per custom-1 instruction)
  wlaneClockSinkDomain   RoccMoonWHalf (mbxr_whalf, W_WIN_LO/HI from the lane) -> TLBuffer -> TLToAXI4 ->
                         AXI4IdIndexer -> AXI4UserYanker, on the lane clock
Real, generated, and instantiated by the bench exactly as the generated subsystem instantiates it (checked against the
generated DigitalTop*.sv, see check_wiring()):
  WLaneResetHold         the lane domain's reset: the SoC (PRCI) lane reset, held until quiet, through ResetCatchAndSync
Real (rev2 Verilog), hand-instantiated as the generated subsystem wires it (checked the same way):
  mbxr_wquiet            on the lane's AXI4 master pins, aclk = lane clock, no reset
Not real: the AXI4 memory standing in for S_AXI_HP2, and the engine's client A (idle for weight loads; the bench flags
any A request).  BlackBox Verilog: rtl_study/roccmoon (rev2), rtl_study/rocc, from the archived 433898d tree.

Testbench-only edits (rtl/gen2b/, never the copy):
  wlaneClockSinkDomain_tb.sv  + tb_dhold: stalls the D handshake TLToAXI4 -> TLBuffer (valid and ready gated), so
                              RREADY falls at the pins through the generated chain.  Revision 2b's weight half never
                              stalls its D channel, so this is an injected back-pressure, not a modelled one.
  wlanetb2b_top.sv            + tb_rdrop  (negative control: RREADY forced low at the pins),
                              + tb_mut_rfirst (negative control: mbxr_wquiet counts a burst's FIRST beat, not RLAST),
                              + tb_mut_noquiet (mutant for finding (a): w_quiet forced high, no quiet hold)
                              + tb_mut_noresethold (mutant for the reset hold: the lane domain takes the SoC reset
                                directly, as before the fix)
  WLaneResetHold_mut_holdfromquiet.sv  --mutant holdfromquiet only: hold <= !quiet, set outside any reset (must trip
                                the bench's "lane reset only inside a SoC reset" assertion)
  mbxd_dma2_mut_nowindow.v    --mutant nowindow only: mbxd_dma2 with in_win forced true (mutant for finding (b))
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.environ.get('WLANETB2B_CFG', 'PynqZ2RocketBigLittlePextTacitMicRgbRoccMoon2bCheckConfig')
import glob as _g
DEFAULT_ROOT = sorted(_g.glob(os.path.normpath(os.path.join(HERE, '..', '..', '..', '..', 'archive', 'rtl_study', 'wlanetb', 'gate_rev2b*'))))[-1]

def ports(txt, mod):
    m = re.search(r'^module %s\((.*?)^\);' % re.escape(mod), txt, re.S | re.M)
    out = []
    for line in m.group(1).split('\n'):
        line = line.split('//')[0]
        mm = re.match(r'\s*(input|output)\s*(\[[^\]]+\])?\s*(\w+)', line)
        if mm: out.append((mm.group(1), mm.group(2) or '', mm.group(3)))
    return out

def sub1(pat, rep, txt, what):
    new, n = re.subn(pat, rep, txt, flags=re.M)
    if n != 1: raise SystemExit('gen_top_rev2b.py: expected exactly one match for %s, got %d' % (what, n))
    return new

args = sys.argv[1:]
if args[:1] == ['--config']: print(CFG); sys.exit(0)
mutant = args[1] if args[:1] == ['--mutant'] else 'none'
root = os.environ.get('WLANETB2B_ROOT', DEFAULT_ROOT)
gen = os.path.join(root, 'gensrc', 'chipyard.harness.TestHarness.' + CFG, 'gen-collateral')
import glob as _glob
_rtl = os.environ.get('WLANETB2B_RTL') or sorted(os.path.basename(d) for d in _glob.glob(os.path.join(root, 'rtl_*')))[-1]
rtl = os.path.join(root, _rtl, 'fpga', 'pynq-z2', 'rtl_study')
dst = os.path.join(HERE, 'rtl', 'gen2b'); os.makedirs(dst, exist_ok=True)

def check_wiring():
    """The generated subsystem's mbxr_wquiet and WLaneResetHold must be wired as this bench wires them."""
    import glob
    tops = [f for f in glob.glob(os.path.join(gen, 'DigitalTop*.sv')) if 'mbxr_wquiet ' in open(f).read()]
    assert len(tops) == 1, tops
    t = open(tops[0]).read()
    m = re.search(r'^\s*mbxr_wquiet (\w+) \((.*?)\);', t, re.S | re.M)
    if not m: raise SystemExit('no mbxr_wquiet instance in the generated DigitalTop.sv')
    c = {k: v.strip() for k, v in re.findall(r'\.(\w+)\s*\(([^)]*)\)', re.sub(r'//[^\n]*', '', m.group(2)))}
    assert sorted(c) == ['aclk', 'ar_fire', 'quiet', 'r_last_fire'], c
    ar = re.fullmatch(r'_domain_auto_axi4yank_out_ar_valid & (\w+)_ar_ready', c['ar_fire'])
    rl = re.fullmatch(r'(\w+)_r_valid & _domain_auto_axi4yank_out_r_ready & (\w+)_r_bits_last', c['r_last_fire'])
    assert ar and rl and ar.group(1) == rl.group(1) == rl.group(2), c
    # aclk: an output of the lane's clock broadcast, whose other output clocks the domain
    b = re.search(r'FixedClockBroadcast\w* clockNode \((.*?)\);', t, re.S)
    bc = dict(re.findall(r'\.(\w+)\s*\(([^)]*)\)', re.sub(r'//[^\n]*', '', b.group(1))))
    lane_in = bc.get('auto_anon_in_clock', '')
    outs = {v.strip() for k, v in bc.items() if k.endswith('_clock') and k.startswith('auto_anon_out')}
    assert c['aclk'] in outs and 'wlane' in lane_in, (c['aclk'], bc)
    d = re.search(r'wlaneClockSinkDomain domain \((.*?)\);', t, re.S)
    dc = dict(re.findall(r'\.(\w+)\s*\(([^)]*)\)', re.sub(r'//[^\n]*', '', d.group(1))))
    assert dc['auto_wh_quiet_in'].strip() == c['quiet'], (dc['auto_wh_quiet_in'], c['quiet'])
    # the reset hold: lane clock and SoC lane reset in, quiet from mbxr_wquiet, its reset out is the domain's reset
    h = re.search(r'^\s*WLaneResetHold (\w+) \((.*?)\);', t, re.S | re.M)
    assert h, 'no WLaneResetHold instance'
    hc = {k: v.strip() for k, v in re.findall(r'\.(\w+)\s*\(([^)]*)\)', re.sub(r'//[^\n]*', '', h.group(2)))}
    assert hc['io_quiet'] == c['quiet'], hc
    assert hc['auto_in_clock'] in outs, (hc, outs)
    assert hc['auto_in_reset'] == re.sub(r'_clock$', '_reset', hc['auto_in_clock']), hc
    assert dc['auto_clock_in_reset'].strip() == hc['auto_out_reset'], (dc['auto_clock_in_reset'], hc)
    assert dc['auto_clock_in_clock'].strip() == hc['auto_out_clock'] or dc['auto_clock_in_clock'].strip() in outs, dc
    hv = open(os.path.join(gen, 'WLaneResetHold.sv')).read()
    body = re.search(r'^module WLaneResetHold\(.*?^endmodule', hv, re.S | re.M).group(0)
    assert re.search(r'always @\(posedge auto_in_clock\) begin\s*if \(auto_in_reset\)\s*hold <= 1\'h1;\s*else\s*hold <= ~io_quiet & hold;', re.sub(r'//[^\n]*', '', body)), 'hold logic not as specified'
    assert 'negedge' not in body and 'posedge auto_in_reset' not in body, 'hold must have no asynchronous reset'
    return m.group(1), c, lane_in, h.group(1)

# ---- the domain module, with the D-hold injection ---------------------------------------------------------------
dom_txt = open(os.path.join(gen, 'wlaneClockSinkDomain.sv')).read()
d = sub1(r'^(module wlaneClockSinkDomain\()', r'\1\n  input         tb_dhold,\t// TESTBENCH ONLY: stall the D handshake TLToAXI4 -> TLBuffer', dom_txt, 'module header')
d = sub1(r'(\.auto_out_d_valid\s*\()(_tl2axi4_auto_in_d_valid)(\))', r'\1\2 & ~tb_dhold\3', d, 'buffer.auto_out_d_valid')
d = sub1(r'(\.auto_in_d_ready\s*\()(_buffer_auto_out_d_ready)(\))', r'\1\2 & ~tb_dhold\3', d, 'tl2axi4.auto_in_d_ready')
open(os.path.join(dst, 'wlaneClockSinkDomain_tb.sv'), 'w').write('// TESTBENCH COPY (gen_top_rev2b.py): tb_dhold added\n' + d)

# ---- mutant: no window check in mbxd_dma2 ---------------------------------------------------------------------------
if mutant == 'nowindow':
    t = open(os.path.join(rtl, 'roccmoon', 'rev2', 'mbxd_dma2.v')).read()
    t = sub1(r'^(\s*wire\s+in_win\s*=\s*)\(blk_lo >= WIN_LO\) && \(blk_hi <= WIN_HI\);', r"\g<1>1'b1;  // MUTANT nowindow", t, 'in_win')
    open(os.path.join(dst, 'mbxd_dma2_mut_nowindow.v'), 'w').write('// MUTANT nowindow (gen_top_rev2b.py)\n' + t)
elif mutant == 'holdfromquiet':
    t = open(os.path.join(gen, 'WLaneResetHold.sv')).read()
    t = sub1(r"if \(auto_in_reset\)[^\n]*\n\s*hold <= 1'h1;[^\n]*\n\s*else[^\n]*\n\s*hold <= ~io_quiet & hold;", "hold <= ~io_quiet;  // MUTANT holdfromquiet", t, 'hold logic')
    open(os.path.join(dst, 'WLaneResetHold_mut_holdfromquiet.sv'), 'w').write('// MUTANT holdfromquiet (gen_top_rev2b.py)\n' + t)
elif mutant != 'none':
    raise SystemExit('unknown mutant ' + mutant)

inst, conns, lane_in, hold_inst = check_wiring()

# ---- the wrapper ------------------------------------------------------------------------------------------------------
eng = ports(open(os.path.join(gen, 'RoccMoonEngine2b.sv')).read(), 'RoccMoonEngine2b')
dom = ports(d, 'wlaneClockSinkDomain')
top = ['input clk0', 'input rst0', 'input clk1', 'input rst1', 'input tb_dhold', 'input tb_rdrop',
       'input tb_mut_rfirst', 'input tb_mut_noquiet', 'input tb_mut_noresethold', 'output tb_quiet', 'output tb_lane_rst',
       'output tb_ww_en', 'output [15:0] tb_ww_word', 'output [63:0] tb_ww_data']
decl, ce, cd, assigns = [], [], [], []
dom_names = {p for _, _, p in dom}
for dr, w, p in eng:
    if p == 'clock': ce.append('.clock(clk0)'); continue
    if p == 'reset': ce.append('.reset(rst0)'); continue
    m = re.match(r'auto_w_req_out_(\w+)', p)
    if m:
        peer = 'auto_wh_w_req_in_' + m.group(1); assert peer in dom_names, peer
        decl.append('  wire %s wreq_%s;' % (w, m.group(1))); ce.append('.%s(wreq_%s)' % (p, m.group(1))); continue
    m = re.match(r'auto_w_rsp_in_(\w+)', p)
    if m:
        peer = 'auto_wh_w_rsp_out_' + m.group(1); assert peer in dom_names, peer
        decl.append('  wire %s wrsp_%s;' % (w, m.group(1))); ce.append('.%s(wrsp_%s)' % (p, m.group(1))); continue
    n = p.replace('auto_cmd_in_', 'cmd_').replace('auto_rsp_out_', 'rsp_').replace('auto_a_out_', 'a_')
    top.append('%s %s %s' % (dr, w, n)); ce.append('.%s(%s)' % (p, n))
for dr, w, p in dom:
    if p == 'tb_dhold': cd.append('.tb_dhold(tb_dhold)'); continue
    if p == 'auto_clock_in_clock': cd.append('.%s(clk1)' % p); continue
    if p == 'auto_clock_in_reset': cd.append('.%s(lane_rst)' % p); continue
    if p == 'auto_wh_quiet_in': cd.append('.%s(wq_quiet | tb_mut_noquiet)' % p); continue
    m = re.match(r'auto_wh_w_req_in_(\w+)', p)
    if m: cd.append('.%s(wreq_%s)' % (p, m.group(1))); continue
    m = re.match(r'auto_wh_w_rsp_out_(\w+)', p)
    if m: cd.append('.%s(wrsp_%s)' % (p, m.group(1))); continue
    if p.startswith('auto_axi4yank_out_'):
        n = 'axi_' + p[len('auto_axi4yank_out_'):]
        top.append('%s %s %s' % (dr, w, n))
        if n == 'axi_r_ready':
            decl.append('  wire dut_r_ready;'); cd.append('.%s(dut_r_ready)' % p)
            assigns.append('  assign axi_r_ready = dut_r_ready & ~tb_rdrop;')
        elif n == 'axi_r_valid':
            cd.append('.%s(axi_r_valid & ~tb_rdrop)' % p)
        else:
            cd.append('.%s(%s)' % (p, n))
        continue
    raise SystemExit('unhandled port ' + p)
assigns += [
    '  // mbxr_wquiet, wired as the generated subsystem wires %s (checked): pins, lane clock, no reset' % inst,
    '  wire r_fire = axi_r_valid & axi_r_ready;',
    '  reg  in_burst = 1\'b0;   // TESTBENCH ONLY, for the rfirst negative control',
    '  always @(posedge clk1) if (r_fire) in_burst <= ~axi_r_bits_last;',
    '  wire wq_quiet;',
    '  mbxr_wquiet %s (.aclk(clk1), .ar_fire(axi_ar_valid & axi_ar_ready),' % inst,
    '    .r_last_fire(tb_mut_rfirst ? (r_fire & ~in_burst) : (r_fire & axi_r_bits_last)), .quiet(wq_quiet));',
    '  assign tb_quiet = wq_quiet;',
    '  // WLaneResetHold, wired as the generated subsystem wires %s (checked): lane clock, SoC lane reset, quiet' % hold_inst,
    '  wire held_rst;',
    '  WLaneResetHold %s (.auto_in_clock(clk1), .auto_in_reset(rst1), .auto_out_clock(), .auto_out_reset(held_rst), .io_quiet(wq_quiet));' % hold_inst,
    '  wire lane_rst = tb_mut_noresethold ? rst1 : held_rst;',
    '  assign tb_lane_rst = lane_rst;',
    '  assign tb_ww_en = wrsp_wwEn; assign tb_ww_word = wrsp_wwWord; assign tb_ww_data = wrsp_wwData;',
]
out = ['// GENERATED by gen_top_rev2b.py for %s -- SIMULATION ONLY, the final W-lane gate' % CFG,
       'module wlanetb2b_top (', ',\n'.join('  ' + x for x in top), ');'] + decl + assigns + [
       '  RoccMoonEngine2b eng (', ',\n'.join('    ' + c for c in ce), '  );',
       '  wlaneClockSinkDomain dom (', ',\n'.join('    ' + c for c in cd), '  );', 'endmodule', '']
open(os.path.join(dst, 'wlanetb2b_top.sv'), 'w').write('\n'.join(out))
print(os.path.join(dst, 'wlanetb2b_top.sv'))
print('wiring checked against the generated subsystem: %s and %s, lane clock %s, %s' % (inst, hold_inst, lane_in, conns), file=sys.stderr)
