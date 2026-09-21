#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Arithmetic intensity, and what a scratchpad-fed tiled engine would do to the frame.

ROCC_STUDY.md r1 rejected a memory-fed MAC engine on an operand-bandwidth argument that
is true of the memory ports and false of the device: 76 of 140 BRAM36 are free in the
shipped bitstream, and a 7-series BRAM36 in SDP mode reads 72 bits per cycle.  r2 redoes
the ladder with a scratchpad as the operand source.  This is the model, so the numbers
are reproducible rather than asserted.

Everything here is derived from measured inputs:
  - layer shapes: out/rocket_mb_lenet_int8_pext/icount.txt (LeNet) and
    PEXT_SPEC.md section 1.1 (DroNet), both exported by ModelBlaster
  - per-dispatch cycles: PEXT_VALIDATION.md section 2, measured on the routed bitstream
  - fill bandwidth F: MEMORY_HIERARCHY.md section 2, measured, plus a derived
    line-Get figure that is labelled as derived
The engine model itself is arithmetic, and every assumption in it is named below.
"""
from __future__ import annotations

NCH   = 4        # channels per MAC pass -> 8*NCH = 32 MACs/cycle
LANES = 8

# Measured per-dispatch cycles on the shipped bitstream, PEXT_VALIDATION.md section 2.
MEASURED = {"conv1": 256814, "pool1": 9658, "conv2": 154812, "pool2": 4567,
            "fc1": 35758, "fc2": 13225, "fc3": 2841}
FRAME = 477675

# Fill bandwidth, bytes per cycle.
#   2.0  what mbx_dma as measured achieves: it issues 8-byte requests, and 4 outstanding
#        8-byte Gets over a ~16-cycle L2 hit is 4*8/16.  This is the honest "as built".
#   5.6  derived, NOT measured: 64-byte TileLink Gets, 4 outstanding, 16-cycle L2 latency,
#        8 beats each.  Needs a bigger reorder buffer than the measured DMA has.
#   8.0  the 64-bit memory port at the core clock -- an upper bound nothing can pass.
#   5.10 SIMULATED, not derived: rtl_study/rocc/tb_mbxd_bw.sv runs mbxd_dma.v against a
#        memory model answering 64-byte Gets after the MEASURED 41-cycle miss latency,
#        one 64-bit beat per cycle on D, with four transactions in flight.  The same
#        model at ONE transaction in flight reproduces the board's own 1.34 B/cycle
#        (it simulates 1.28) and the L2's 2.48 (it simulates 2.56 at L = 16), neither
#        of which it was fitted to -- which is the reason to believe the rest of it.
#   7.89 the same, with eight in flight, which needs more of the L2's seven MSHRs than
#        a well-behaved client should assume.  At MSHR = 4 it falls back to 5.09.
F_CASES = [("as built, 8 B Gets", 2.0),
           ("mbxd, 64 B Gets, 4 outstanding (simulated)", 5.10),
           ("mbxd, 64 B Gets, 8 outstanding (simulated)", 7.89),
           ("bus peak", 8.0)]


def ceil(a, b):
    return -(-a // b)


class Conv:
    def __init__(self, name, IC, IH, IW, OC, KH, KW, OH, OW):
        self.name, self.IC, self.IH, self.IW = name, IC, IH, IW
        self.OC, self.KH, self.KW, self.OH, self.OW = OC, KH, KW, OH, OW
        self.K = IC * KH * KW
        self.KP = ceil(self.K, 8) * 8
        self.G = self.KP // 8
        self.pix = OH * OW
        self.macs = self.pix * OC * self.K

    def bytes_in(self):
        """What must reach the scratchpad once: the input tensor and the packed weights.
        The im2col expansion is NOT a load -- it is produced inside the scratchpad from
        the input tensor, which is the whole point of holding the tensor rather than the
        patches."""
        return self.IC * self.IH * self.IW + self.OC * self.KP

    def spad_bytes(self):
        """Peak scratchpad occupancy: input tensor + weights + im2col tile + output."""
        return (self.IC * self.IH * self.IW + self.OC * self.KP
                + self.pix * self.KP + self.pix * self.OC)

    def engine(self, F, gather_overlaps=True):
        quads = ceil(self.OC, NCH)
        mac = self.pix * quads * self.G            # one group-of-NCH per cycle
        # im2col: IC*KH source rows per pixel, ~1.5 cycles each because a KW-byte run
        # crosses an 8-byte patch-word boundary about half the time
        gat = int(self.pix * self.IC * self.KH * 1.5)
        qnt = self.pix * quads                      # overlaps the MAC tail
        fill = self.bytes_in() / F
        compute = max(mac, gat) if gather_overlaps else mac + gat
        return max(compute, fill), dict(mac=mac, gather=gat, quant=qnt, fill=int(fill))

    def ai(self):
        return self.macs / self.bytes_in()


class Linear:
    def __init__(self, name, K, N):
        self.name, self.K, self.N = name, K, N
        self.KP = ceil(K, 8) * 8
        self.G = self.KP // 8
        self.macs = K * N

    def bytes_in(self):
        return self.K + self.N * self.K

    def spad_bytes(self):
        return self.K + self.N * self.K + self.N

    def engine(self, F, gather_overlaps=True):
        mac = ceil(self.N, NCH) * self.G
        fill = self.bytes_in() / F
        return max(mac, fill), dict(mac=mac, gather=0, quant=ceil(self.N, NCH),
                                    fill=int(fill))

    def ai(self):
        return self.macs / self.bytes_in()


LENET = [
    Conv("conv1", 1, 28, 28, 6, 5, 5, 24, 24),
    Conv("conv2", 6, 12, 12, 16, 5, 5, 8, 8),
    Linear("fc1", 256, 120),
    Linear("fc2", 120, 84),
    Linear("fc3", 84, 10),
]

# PEXT_SPEC.md section 1.1, the exported DroNet int8 graph
DRONET = [
    Conv("conv_modules.0", 3, 112, 112, 32, 3, 3, 56, 56),
    Conv("conv_modules.1", 32, 27, 27, 32, 3, 3, 14, 14),
    Conv("conv_modules.2", 32, 14, 14, 32, 3, 3, 14, 14),
    Conv("conv_modules.3", 32, 27, 27, 32, 1, 1, 14, 14),
    Conv("conv_modules.4", 32, 14, 14, 64, 3, 3, 7, 7),
    Conv("conv_modules.5", 64, 7, 7, 64, 3, 3, 7, 7),
    Conv("conv_modules.6", 32, 14, 14, 64, 1, 1, 7, 7),
    Conv("conv_modules.7", 64, 7, 7, 128, 3, 3, 4, 4),
    Conv("conv_modules.8", 128, 4, 4, 128, 3, 3, 4, 4),
    Conv("conv_modules.9", 64, 7, 7, 128, 1, 1, 4, 4),
    Linear("head_a", 2048, 1), Linear("head_b", 2048, 1),
]

# Software that stays on the core, in instructions, from
# rtl_study/rocc/ooc_out/where_the_time_goes.txt, converted at the measured per-dispatch
# CPI.  Two models:
#   A  the engine does conv and linear only.  Pooling, the weight repack and the drivers
#      stay in software.
#   B  the engine also folds pooling (a MAX8 tree is 96 LUT, PEXT_FEASIBILITY 1.2) and the
#      weight repack becomes a strided DMA descriptor.
SW_A = 13893 + 11838 + 550 + 80      # pools + repack/dispatch setup + wrappers + tile issue
SW_B = 550 + 80
ENG_B_EXTRA = 850 + 328              # pooling in the engine + the repack as a DMA


def report(net, name, frame=None, measured=None):
    print(f"\n===== {name} =====")
    print(f"{'layer':<18}{'MACs':>12}{'bytes in':>11}{'AI':>8}{'spad B':>10}"
          f"{'mac cyc':>9}{'gat cyc':>9}")
    tot_macs = tot_bytes = 0
    for L in net:
        _, d = L.engine(5.6)
        tot_macs += L.macs
        tot_bytes += L.bytes_in()
        print(f"{L.name:<18}{L.macs:>12,}{L.bytes_in():>11,}{L.ai():>8.1f}"
              f"{L.spad_bytes():>10,}{d['mac']:>9,}{d['gather']:>9,}")
    print(f"{'TOTAL':<18}{tot_macs:>12,}{tot_bytes:>11,}{tot_macs/tot_bytes:>8.1f}")
    print(f"  engine is compute-bound where AI >= {8*NCH}/F : "
          + ", ".join(f"{lab} -> {8*NCH/F:.1f}" for lab, F in F_CASES))

    if frame is None:
        return
    print(f"\n  {'fill B/cyc':<36}{'engine cyc':>12}{'+ sw A':>10}{'x':>7}"
          f"{'+ sw B':>10}{'x':>7}")
    for lab, F in F_CASES:
        eng = sum(L.engine(F)[0] for L in net)
        a = eng + SW_A
        b = eng + ENG_B_EXTRA + SW_B
        print(f"  {lab:<36}{int(eng):>12,}{int(a):>10,}{frame/a:>7.1f}"
              f"{int(b):>10,}{frame/b:>7.1f}")


def main():
    report(LENET, "LeNet int8 -- shapes from out/rocket_mb_lenet_int8_pext/icount.txt",
           frame=FRAME)
    print("\n  per-layer, at F = 5.6 B/cycle, against the measured cycles:")
    print(f"  {'layer':<10}{'measured':>10}{'engine':>10}{'speedup':>9}")
    for L in LENET:
        e, _ = L.engine(5.6)
        m = MEASURED[L.name]
        print(f"  {L.name:<10}{m:>10,}{int(e):>10,}{m/e:>9.1f}")
    print(f"  {'pools':<10}{MEASURED['pool1']+MEASURED['pool2']:>10,}"
          f"{'(sw or 850)':>10}")

    report(DRONET, "DroNet int8 -- shapes from PEXT_SPEC.md section 1.1")
    big = max(DRONET[:10], key=lambda L: L.spad_bytes())
    print(f"\n  largest single-layer scratchpad demand: {big.name} at "
          f"{big.spad_bytes():,} B")
    print( "  BRAM36 is 4 KB of data: 5 banks = 20 KB, 15 = 60 KB, 30 = 120 KB, "
           "75 = 300 KB")
    print( "  a layer that does not fit is tiled by SOFTWARE, which is the whole "
           "design point")


if __name__ == "__main__":
    raise SystemExit(main())
