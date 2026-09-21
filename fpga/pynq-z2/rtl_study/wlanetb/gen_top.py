#!/usr/bin/env python3
"""SIMULATION ONLY.  rtl/gen/ around the GENERATED private weight channel of
PynqZ2RocketBigLittlePextTacitMicRgbBwWLaneProbeConfig (MEMORY_BANDWIDTH.md s9.9, design (ii')).
PROBE-LEVEL, PRE-REV2B: the lane is BwBypass (mbxd_dma, one lane), standing in for the rev2b weight DMA.

Real (generated, unmodified): wlaneClockSinkDomain's contents -- BwBypass, TLBuffer, TLToAXI4, AXI4IdIndexer,
AXI4UserYanker, the MMIO crossing sink -- and the pbus-side TLAsyncCrossingSource.  Not real: the AXI4 memory
(csrc/main.cpp).  Two clocks: the lane on clk1 (FCLK1-like), the MMIO source on clk0 (FCLK0-like).

The RTL comes from a COPY of the elaboration (archive/rtl_study/wlanetb/gensrc/), never the shared Chipyard tree.
Testbench-only edits, all written to rtl/gen/ and none to the copy:

  wlaneClockSinkDomain_tb.sv   the domain module with one added input, tb_dhold, that stalls the TileLink D handshake
                               between TLToAXI4 and the lane's TLBuffer (valid and ready both gated, so no beat is
                               lost or duplicated).  It stands in for the rev2b W-DMA's scratchpad write port being
                               busy: the TLBuffer fills and RREADY falls at the AXI pins through the generated
                               TLToAXI4 / AXI4IdIndexer / AXI4UserYanker, which is the back-pressure under test.
  wlanetb_top.sv               the wrapper.  tb_rdrop forces RREADY low at the pins and hides RVALID from the DUT
                               (negative control "drops RREADY during drain"); tb_inflight reads BwBypass's
                               in-flight counter by hierarchical reference (the lane's own drain-complete signal).
  BwBypass_mut_skip_rlast.sv   --mutant skip_rlast only: BwBypass with its in-flight decrement taken on the FIRST
                               D beat of a burst instead of the last (negative control "skips waiting for RLAST").
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
CFG = 'PynqZ2RocketBigLittlePextTacitMicRgbBwWLaneProbeConfig'
XSRC = 'TLAsyncCrossingSource_a29d64s11k1z2u'
DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..', '..', 'archive', 'rtl_study', 'wlanetb', 'gensrc'))

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
    if n != 1: raise SystemExit('gen_top.py: expected exactly one match for %s, got %d' % (what, n))
    return new

args = sys.argv[1:]
if args[:1] == ['--config']: print(CFG); sys.exit(0)
mutant = None
if args[:1] == ['--mutant']: mutant = args[1]
root = os.environ.get('WLANETB_GENSRC_ROOT', DEFAULT_ROOT)
gen = os.path.join(root, 'chipyard.harness.TestHarness.' + CFG, 'gen-collateral')
dst_dir = os.path.join(HERE, 'rtl', 'gen'); os.makedirs(dst_dir, exist_ok=True)

# ---- the domain module, with the D-hold injection ---------------------------------------------------------
dom_txt = open(os.path.join(gen, 'wlaneClockSinkDomain.sv')).read()
d = sub1(r'^(module wlaneClockSinkDomain\()', r'\1\n  input         tb_dhold,\t// TESTBENCH ONLY: stall the D handshake TLToAXI4 -> TLBuffer', dom_txt, 'module header')
d = sub1(r'(\.auto_out_d_valid\s*\()(_tl2axi4_auto_in_d_valid)(\))', r'\1\2 & ~tb_dhold\3', d, 'buffer.auto_out_d_valid')
d = sub1(r'(\.auto_in_d_ready\s*\()(_buffer_auto_out_d_ready)(\))', r'\1\2 & ~tb_dhold\3', d, 'tl2axi4.auto_in_d_ready')
open(os.path.join(dst_dir, 'wlaneClockSinkDomain_tb.sv'), 'w').write('// TESTBENCH COPY (gen_top.py): tb_dhold added\n' + d)

# ---- the mutant --------------------------------------------------------------------------------------------
if mutant == 'skip_rlast':
    bw = open(os.path.join(gen, 'BwBypass.sv')).read()
    bw = sub1(r'^(\s*wire\s+dLast = auto_clients_out_d_valid & \(dLast_counter == )3\'h1( \|)', r"\g<1>3'h0\2", bw, 'dLast last->first')
    open(os.path.join(dst_dir, 'BwBypass_mut_skip_rlast.sv'), 'w').write('// MUTANT skip_rlast (gen_top.py): in-flight decrement on the FIRST D beat\n' + bw)
elif mutant not in (None, 'none'):
    raise SystemExit('unknown mutant ' + mutant)

# ---- the wrapper -------------------------------------------------------------------------------------------
dom = ports(d, 'wlaneClockSinkDomain')
xs = ports(open(os.path.join(gen, XSRC + '.sv')).read(), XSRC)
top = ['input clk0', 'input rst0', 'input clk1', 'input rst1', 'input tb_rdrop', 'output [7:0] tb_inflight']
decl, cd, cx, assigns = [], [], [], []
xs_out = {p for _, _, p in xs if p.startswith('auto_out_')}
for dr, w, p in dom:
    if p == 'tb_dhold': top.append('input tb_dhold'); cd.append('.tb_dhold(tb_dhold)'); continue
    if p == 'auto_clock_in_clock': cd.append('.%s(clk1)' % p); continue
    if p == 'auto_clock_in_reset': cd.append('.%s(rst1)' % p); continue
    if p.startswith('auto_xsink_in_'):
        peer = 'auto_out_' + p[len('auto_xsink_in_'):]
        assert peer in xs_out, peer
        decl.append('  wire %s x_%s;' % (w, peer)); cd.append('.%s(x_%s)' % (p, peer)); continue
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
for dr, w, p in xs:
    if p == 'clock': cx.append('.clock(clk0)'); continue
    if p == 'reset': cx.append('.reset(rst0)'); continue
    if p.startswith('auto_out_'): cx.append('.%s(x_%s)' % (p, p)); continue
    n = p.replace('auto_in_', 'mmio_')
    top.append('%s %s %s' % (dr, w, n)); cx.append('.%s(%s)' % (p, n))
assigns.append('  assign tb_inflight = dom.probe.inflight;   // hierarchical reference, read only')
out = ['// GENERATED by gen_top.py for %s -- SIMULATION ONLY, probe-level, pre-rev2b' % CFG, 'module wlanetb_top (',
       ',\n'.join('  ' + x for x in top), ');'] + decl + assigns + [
       '  wlaneClockSinkDomain dom (', ',\n'.join('    ' + c for c in cd), '  );',
       '  %s xsrc (' % XSRC, ',\n'.join('    ' + c for c in cx), '  );', 'endmodule', '']
dst = os.path.join(dst_dir, 'wlanetb_top.sv'); open(dst, 'w').write('\n'.join(out))
print(dst)
