"""SignDetLite -- Lab B144's anchor-free sign detector, shaped by KERNEL COVERAGE.

THE OP SET IS THE DESIGN CONSTRAINT, not an afterthought.  This SoC's curated kernels are
fpga/pynq-z2/modelblaster/kernels/{pext,pext_nl,roccmoon} plus kernels_t1/pext_nl, and an op
with no kernel there is lowered to reference C with soft-float in it.  So this network uses
only ops that are already curated:

    conv2d_s8     pext/pext_conv2d_s8_pext_patch_dot8.c      (and the roccmoon engine, which
                  declines 3x3 by its IH==1 && KH==1 && PH==0 guard and hands it to pext)
    permute4_s8   kernels_t1/pext_nl/pext_nl_permute4_s8_pext_block.c
    softmax_s8    pext_nl/pext_nl_softmax_s8_pext_int_memo2.c

WHAT IS DELIBERATELY ABSENT.  An anchor-based detector wants concat, reshape-to-anchors and a
SIGMOID objectness; there is NO curated sigmoid for this target, and concat exists only as
cat2/cat3/cat4_c1_s8.  So objectness is not a sigmoid here: every cell runs a 3-way SOFTMAX
over {background, stop, yield} and objectness is 1 - P(background).  That is one curated op
instead of two uncurated ones, AND it is the background class the old GTSRB classifier never
had -- the thing that let it answer "PRIORITY ROAD, 100.0%" to a picture of a yield sign.

BUDGET.  7,532,544 MAC against SignNetLite's 10,788,224.  At the 1.2755 cyc/MAC that Lab B121
measured for that network through the same pext DOT8 kernel, ~9.61 M cycles ~= 240 ms at
40 MHz, inside the ~350 ms the XPU-RT co-location schedule leaves for this model.
"""
from __future__ import annotations
import torch
from torch import nn

GRID, OUTPX, NCLS = 8, 64, 3


class SignDetLite(nn.Module):
    def __init__(self, ncls: int = NCLS):
        super().__init__()
        self.conv1 = nn.Conv2d(3, 16, 3, stride=2, padding=1)    # 64 -> 32
        self.conv2 = nn.Conv2d(16, 32, 3, stride=2, padding=1)   # 32 -> 16
        self.conv3 = nn.Conv2d(32, 32, 3, stride=1, padding=1)   # 16
        self.conv4 = nn.Conv2d(32, 64, 3, stride=2, padding=1)   # 16 -> 8
        self.conv5 = nn.Conv2d(64, 64, 3, stride=1, padding=1)   # 8
        self.head = nn.Conv2d(64, ncls, 1)                       # 8x8x3 logits
        self.ncls = ncls

    def features(self, x):
        x = torch.relu(self.conv1(x))
        x = torch.relu(self.conv2(x))
        x = torch.relu(self.conv3(x))
        x = torch.relu(self.conv4(x))
        x = torch.relu(self.conv5(x))
        return self.head(x)                                      # (N, ncls, 8, 8)

    def forward(self, x):
        x = self.features(x)
        x = x.permute(0, 2, 3, 1)                                # -> permute4_s8, NHWC
        x = x.reshape(GRID * GRID, self.ncls)                    # view (free: already NHWC)
        return torch.softmax(x, dim=1)                           # -> softmax_s8  M=64 K=3


def macs(ncls: int = NCLS) -> int:
    def c(oh, ow, oc, ic, k):
        return oh * ow * oc * ic * k * k
    return (c(32, 32, 16, 3, 3) + c(16, 16, 32, 16, 3) + c(16, 16, 32, 32, 3)
            + c(8, 8, 64, 32, 3) + c(8, 8, 64, 64, 3) + c(8, 8, ncls, 64, 1))


def get_model(seed: int = 0) -> SignDetLite:
    torch.manual_seed(seed)
    m = SignDetLite()
    m.eval()
    return m


def get_sample_input(seed: int = 1) -> torch.Tensor:
    g = torch.Generator().manual_seed(seed)
    return torch.randn(1, 3, OUTPX, OUTPX, generator=g)


if __name__ == "__main__":
    m = SignDetLite()
    y = m(torch.zeros(1, 3, 64, 64))
    print("out", tuple(y.shape), "sum/row", float(y[0].sum()))
    print("MAC %,d  vs SignNetLite 10,788,224".replace(",d", "d") % macs())
    print("est cycles %.2f M  est ms @40MHz %.1f" % (macs() * 1.2755 / 1e6, macs() * 1.2755 / 40e6 * 1e3))
    print("params", sum(p.numel() for p in m.parameters()))
