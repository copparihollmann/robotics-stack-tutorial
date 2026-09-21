"""The Visual Wake Words networks, and why there are five of them.

All five answer the SAME question -- is there a person in this frame -- on the MLPerf Tiny
Visual Wake Words corpus (`vw_coco2014_96`, 109,619 images, 96x96).  They differ in two
axes, and each axis is a decision this SoC makes differently from a general-purpose part:

  ARCHITECTURE.  `mbnet` is the MLPerf Tiny reference shape -- MobileNetV1 alpha=0.25 --
  which is depthwise-separable.  `cnn` spends the SAME MAC budget on DENSE convolutions.
  On this machine that is not a stylistic choice: MBP.DOT8 retires eight int8 MACs in one
  cycle by reducing along the INPUT-CHANNEL axis, and a depthwise convolution has no such
  axis.  SPEECH_ON_ROCKET.md section 5 measured 3.42x on the audio version of exactly this
  pair; CAMERA_TASK.md measures the vision version.

  SENSOR COLOUR.  `cnn` takes one 96x96 monochrome plane.  `cnn_rgb` takes three.
  `cnn_bayer` takes the sensor's raw Bayer mosaic de-interleaved into four 48x48 planes
  with NO demosaic at all.  The reason to care is also DOT8: it consumes eight int8 lanes
  per instruction, so a single-channel first layer wastes seven of them, and the first
  layer of a vision network is where the pixels are.  IC = 1 vs 3 vs 4 at layer 1 is
  therefore a measurable property of the ISA, not a preference.

Every architecture here is built from conv2d, maxpool2d, avgpool2d, relu and linear.
Those are five of the fifteen ModelBlaster `_s8` reference kernels that are float-free
(SPEECH_ON_ROCKET.md section 3.2), and three of them -- conv2d, maxpool2d, linear -- are
the three with curated MBP kernels.  Batch norm is folded into the preceding convolution
before export: `batchnorm2d_s8` dequantizes to float, which on this FPU-less core is 649
libgcc instructions per element.

INPUT CONVENTION.  Every model takes int8-valued floats in [-127, 127].  The device
produces them with one subtract and one clamp from the 8-bit sensor pixel -- `x = clamp(p
- 128, -127, 127)` -- and nothing else.  There is deliberately no per-image mean/variance
normalisation anywhere in this file: that would need a float pass over the frame on a core
with no FPU, and it would have to run before every inference.
"""
from __future__ import annotations

import torch
from torch import nn

RES = 96            # the MLPerf Tiny Visual Wake Words input side
NCLASS = 2          # person / no person


def _cbr(cin, cout, k, s=1, p=0, groups=1):
    return nn.Sequential(
        nn.Conv2d(cin, cout, k, stride=s, padding=p, groups=groups, bias=False),
        nn.BatchNorm2d(cout),
        nn.ReLU(),
    )


# ---------------------------------------------------------------------------------
# The MLPerf Tiny reference shape
# ---------------------------------------------------------------------------------
class VwwMobileNet(nn.Module):
    """MobileNetV1 alpha=0.25 at 96x96, the MLPerf Tiny Visual Wake Words reference.

    Thirteen depthwise-separable blocks after a strided 3x3 stem, global average pool,
    one linear head.  The layer widths are the reference's (32/64/128/128/256/256/512x5/
    1024/1024 scaled by 0.25 -> 8/16/32/32/64/64/128x5/256/256).

    With a ONE-channel input the stem is 9 MACs per output pixel instead of 27, so the
    whole network is 7,157,888 MACs rather than the 7,489,664 the published RGB figure
    gives.  `cnn` below is matched to THIS number, not to the published one, because the
    comparison that means anything is two networks taking the same input.
    """

    MACS = 7157888
    IN_CH = 1

    def __init__(self, nclass=NCLASS, cin=1):
        super().__init__()
        # (out_channels, stride) of each depthwise-separable block.
        cfg = [(16, 1), (32, 2), (32, 1), (64, 2), (64, 1), (128, 2),
               (128, 1), (128, 1), (128, 1), (128, 1), (128, 1),
               (256, 2), (256, 1)]
        layers = [_cbr(cin, 8, 3, s=2, p=1)]          # 96 -> 48
        c = 8
        for cout, s in cfg:
            layers.append(_cbr(c, c, 3, s=s, p=1, groups=c))   # depthwise
            layers.append(_cbr(c, cout, 1))                    # pointwise
            c = cout
        self.body = nn.Sequential(*layers)
        self.pool = nn.AvgPool2d(3)                   # 3x3 -> 1x1
        self.fc = nn.Linear(c, nclass)

    def forward(self, x):
        x = self.pool(self.body(x))
        x = torch.flatten(x, start_dim=1)
        return self.fc(x)


# ---------------------------------------------------------------------------------
# The same budget in dense convolutions
# ---------------------------------------------------------------------------------
class VwwCNN(nn.Module):
    """The same MAC budget spent on DENSE 3x3 convolutions.  7,154,048 MACs.

    Matched to VwwMobileNet's 7,157,888 to within 0.054 %, so the two differ in what their
    arithmetic IS and not in how much of it there is.  Channel counts are multiples of 8
    so the DOT8 patch gather never has a ragged tail, and every kernel is 3x3 so the
    gather's contiguous run is 3 bytes rather than the 1 byte a (k,1) kernel gives --
    SPEECH_ON_ROCKET.md section 11.4 measured 16.93x on exactly that distinction.
    """

    MACS = 7154048
    IN_CH = 1

    def __init__(self, nclass=NCLASS, cin=1):
        super().__init__()
        self.c1 = _cbr(cin, 8, 3, s=2, p=1)      # 96 -> 48x48x8
        self.c2 = _cbr(8, 16, 3, s=2, p=1)       # 48 -> 24x24x16
        self.c3 = _cbr(16, 32, 3, p=1)           #       24x24x32
        self.p3 = nn.MaxPool2d(2)                #       12x12x32
        self.c4 = _cbr(32, 56, 3, p=1)           #       12x12x56
        self.p4 = nn.MaxPool2d(2)                #        6x6x56
        self.c5 = _cbr(56, 72, 3, p=1)           #        6x6x72
        self.p5 = nn.MaxPool2d(2)                #        3x3x72
        self.fc1 = nn.Linear(72 * 3 * 3, 64)
        self.fc2 = nn.Linear(64, nclass)

    def forward(self, x):
        x = self.c3(self.c2(self.c1(x)))
        x = self.c5(self.p4(self.c4(self.p3(x))))
        x = torch.flatten(self.p5(x), start_dim=1)
        return self.fc2(torch.relu(self.fc1(x)))


class VwwCNNTiny(nn.Module):
    """A quarter of the budget, for the frame-rate end of the table.  1,843,328 MACs."""

    MACS = 1843328
    IN_CH = 1

    def __init__(self, nclass=NCLASS, cin=1):
        super().__init__()
        self.c1 = _cbr(cin, 8, 3, s=2, p=1)      # 96 -> 48x48x8
        self.p1 = nn.MaxPool2d(2)                #       24x24x8
        self.c2 = _cbr(8, 16, 3, p=1)            #       24x24x16
        self.p2 = nn.MaxPool2d(2)                #       12x12x16
        self.c3 = _cbr(16, 32, 3, p=1)           #       12x12x32
        self.p3 = nn.MaxPool2d(2)                #        6x6x32
        self.c4 = _cbr(32, 32, 3, p=1)           #        6x6x32
        self.p4 = nn.MaxPool2d(2)                #        3x3x32
        self.fc1 = nn.Linear(32 * 3 * 3, 64)
        self.fc2 = nn.Linear(64, nclass)

    def forward(self, x):
        x = self.p2(self.c2(self.p1(self.c1(x))))
        x = self.p4(self.c4(self.p3(self.c3(x))))
        x = torch.flatten(x, start_dim=1)
        return self.fc2(torch.relu(self.fc1(x)))


# ---------------------------------------------------------------------------------
# The sensor-colour axis
# ---------------------------------------------------------------------------------
class VwwCNNRgb(VwwCNN):
    """VwwCNN with a THREE-channel first layer: a demosaiced colour frame.

    Only layer 1 changes.  Everything from c2 onwards is bit-for-bit the same shape as
    the monochrome model, so the cycle difference between the two IS the first layer, and
    the accuracy difference IS the colour information.  c1 goes from 165,888 MACs to
    497,664 -- three times the arithmetic, and the question this model exists to answer
    is whether it costs three times the cycles, given that DOT8 was only using one of its
    eight lanes at IC = 1.
    """

    MACS = 7485824
    IN_CH = 3

    def __init__(self, nclass=NCLASS):
        super().__init__(nclass=nclass, cin=3)


class VwwCNNBayer(nn.Module):
    """VwwCNN fed the sensor's RAW BAYER MOSAIC, de-interleaved, with no demosaic.

    A colour HM01B0 emits one byte per pixel exactly like the monochrome part -- the
    colour lives in a 2x2 RGGB colour-filter array, not in extra bytes.  Demosaicing is a
    software step that turns 1 byte/pixel into 3 and costs a pass over the frame.  This
    model skips it: the mosaic is split into its four sub-lattices (R, G1, G2, B), each of
    which is a half-resolution image, and those four planes ARE the input tensor.

    The result is IC = 4 at layer 1 -- four of DOT8's eight lanes instead of one -- at
    monochrome's byte count and with no demosaic anywhere.  What it gives up is spatial
    resolution: 48x48 per plane against 96x96 of luma.  That trade is the measurement.

    The stem is stride 1 rather than stride 2, because the mosaic's sub-lattice is already
    at half resolution, so the tensor entering c2 is 48x48x8 -- identical to every other
    model here from that point on.
    """

    MACS = 7651712
    IN_CH = 4

    def __init__(self, nclass=NCLASS):
        super().__init__()
        self.c1 = _cbr(4, 8, 3, s=1, p=1)        # 4x48x48 -> 48x48x8
        self.c2 = _cbr(8, 16, 3, s=2, p=1)       #            24x24x16
        self.c3 = _cbr(16, 32, 3, p=1)
        self.p3 = nn.MaxPool2d(2)
        self.c4 = _cbr(32, 56, 3, p=1)
        self.p4 = nn.MaxPool2d(2)
        self.c5 = _cbr(56, 72, 3, p=1)
        self.p5 = nn.MaxPool2d(2)
        self.fc1 = nn.Linear(72 * 3 * 3, 64)
        self.fc2 = nn.Linear(64, nclass)

    forward = VwwCNN.forward


ARCHS = {
    "mbnet": VwwMobileNet,
    "cnn": VwwCNN,
    "cnn_tiny": VwwCNNTiny,
    "cnn_rgb": VwwCNNRgb,
    "cnn_bayer": VwwCNNBayer,
}

# The input tensor each architecture wants, as (C, H, W). The featuriser writes one
# array per FEED, not per architecture, and several architectures share a feed.
FEED = {
    "mbnet": "mono", "cnn": "mono", "cnn_tiny": "mono",
    "cnn_rgb": "rgb", "cnn_bayer": "bayer4",
}
FEED_SHAPE = {"mono": (1, 96, 96), "rgb": (3, 96, 96), "bayer4": (4, 48, 48)}


def count_macs(model, shape=None):
    """Exact MAC count by walking the modules with a forward hook.  No estimate."""
    if shape is None:
        shape = (1,) + FEED_SHAPE[FEED.get(
            next(k for k, v in ARCHS.items() if isinstance(model, v)), "mono")]
    total = [0]
    hooks = []

    def conv_hook(m, i, o):
        total[0] += (o.numel() * m.in_channels // m.groups
                     * m.kernel_size[0] * m.kernel_size[1])

    def lin_hook(m, i, o):
        total[0] += m.in_features * m.out_features

    for m in model.modules():
        if isinstance(m, nn.Conv2d):
            hooks.append(m.register_forward_hook(conv_hook))
        elif isinstance(m, nn.Linear):
            hooks.append(m.register_forward_hook(lin_hook))
    was = model.training
    model.eval()
    with torch.no_grad():
        model(torch.zeros(shape))
    for h in hooks:
        h.remove()
    model.train(was)
    return total[0]


def macs_by_layer(model, shape):
    """Per-convolution MAC counts, in execution order -- what the per-dispatch table
    on the board has to be divided by to get cycles/MAC for one layer."""
    rows = []

    def hook(name, m):
        def f(mod, i, o):
            if isinstance(mod, torch.nn.Conv2d):
                k = mod.kernel_size[0] * mod.kernel_size[1]
                rows.append((name, tuple(i[0].shape[1:]), tuple(o.shape[1:]),
                             mod.in_channels // mod.groups, k,
                             o.numel() * mod.in_channels // mod.groups * k))
            else:
                rows.append((name, tuple(i[0].shape[1:]), tuple(o.shape[1:]),
                             mod.in_features, 1, mod.in_features * mod.out_features))
        return f

    hs = [m.register_forward_hook(hook(n, m)) for n, m in model.named_modules()
          if isinstance(m, (torch.nn.Conv2d, torch.nn.Linear))]
    model.eval()
    with torch.no_grad():
        model(torch.zeros((1,) + tuple(shape)))
    for h in hs:
        h.remove()
    return rows


def fold_bn(model: nn.Module) -> nn.Module:
    """Fold every BatchNorm2d into the Conv2d immediately before it, in place.

    Identical to kws_models.fold_bn -- the BatchNorm is DELETED rather than replaced by an
    nn.Identity, because ModelBlaster's int8 frontend walks modules by isinstance and
    raises NotImplementedError on nn.Identity: a graph with a no-op in it is still a graph
    with an unsupported op in it.
    """
    for mod in model.modules():
        if not isinstance(mod, nn.Sequential):
            continue
        kids, keep = list(mod), []
        i = 0
        while i < len(kids):
            conv = kids[i]
            bn = kids[i + 1] if i + 1 < len(kids) else None
            if isinstance(conv, nn.Conv2d) and isinstance(bn, nn.BatchNorm2d):
                w = conv.weight.data
                g = bn.weight.data / torch.sqrt(bn.running_var + bn.eps)
                conv.weight.data = w * g.reshape(-1, 1, 1, 1)
                b = (torch.zeros(w.shape[0], device=w.device)
                     if conv.bias is None else conv.bias.data)
                newb = (b - bn.running_mean) * g + bn.bias.data
                if conv.bias is None:
                    conv.bias = nn.Parameter(newb)
                else:
                    conv.bias.data = newb
                keep.append(conv)
                i += 2
            else:
                keep.append(conv)
                i += 1
        if len(keep) != len(kids):
            for k in list(mod._modules):
                del mod._modules[k]
            for j, m in enumerate(keep):
                mod.add_module(str(j), m)
    return model
