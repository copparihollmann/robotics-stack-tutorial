"""The two keyword-spotting networks, and why there are two.

Both take the SAME input -- 1 x 49 x 10 int8 MFCC from fpga/pynq-z2/sw/audio_fe.c at the
"kws" geometry (30 ms window, 20 ms hop, MLPerf Tiny's framing) -- and both are trained
on the same 12-class Google Speech Commands v2 split.  They differ in one thing:

  DSCNN   the MLPerf Tiny / Hello Edge DS-CNN-S, depthwise-separable, 2,656,768 MACs.
          The published reference. 22,604 int8 parameters, 92.2 % fp32 / 91.6 % int8.

  CNN     the same MAC budget spent on DENSE convolutions, 2,729,728 MACs, built out of
          conv2d + maxpool2d + linear and nothing else.

THE REASON THE SECOND ONE EXISTS.  Depthwise-separable convolution is the standard way
to make a keyword spotter cheap, and on this SoC it is the wrong move.  MBP.DOT8 does
eight int8 multiply-accumulates in one cycle by reducing along the input-channel axis --
and a depthwise convolution has NO input-channel axis to reduce along: each output
channel sees exactly one input channel.  So DS-CNN's 288,000 depthwise MACs run at the
scalar rate while the dense network's equivalent MACs run at the MBP rate, and the model
with FEWER operations can be the SLOWER one.  That is a co-design result, not a modelling
choice, and fpga/pynq-z2/docs/SPEECH_ON_ROCKET.md has it measured on the board.

Batch norm is folded into the preceding convolution before export.  It is not a
convenience: ModelBlaster's batchnorm2d_s8 reference dequantizes to float, which on this
FPU-less core is 649 libgcc instructions per element (DRONET_INTEGER.md), and folding
removes the op from the graph entirely rather than making it cheap.
"""
from __future__ import annotations

import torch
from torch import nn

NFRAMES = 49
NCOEF = 10
NCLASS = 12


def _cbr(cin, cout, k, s=1, p=0, groups=1):
    return nn.Sequential(
        nn.Conv2d(cin, cout, k, stride=s, padding=p, groups=groups, bias=False),
        nn.BatchNorm2d(cout),
        nn.ReLU(),
    )


class KwsDSCNN(nn.Module):
    """MLPerf Tiny DS-CNN-S.  conv(10x4,s2) then 4 x [depthwise 3x3, pointwise 1x1]."""

    MACS = 2656768

    def __init__(self, nclass=NCLASS, ch=64, nblocks=4):
        super().__init__()
        self.stem = _cbr(1, ch, (10, 4), s=(2, 2), p=(5, 1))
        blocks = []
        for _ in range(nblocks):
            blocks.append(_cbr(ch, ch, 3, p=1, groups=ch))   # depthwise
            blocks.append(_cbr(ch, ch, 1))                   # pointwise
        self.blocks = nn.Sequential(*blocks)
        self.pool = nn.AvgPool2d((25, 5))
        self.fc = nn.Linear(ch, nclass)

    def forward(self, x):
        x = self.blocks(self.stem(x))
        x = self.pool(x)
        x = torch.flatten(x, start_dim=1)
        return self.fc(x)


class KwsCNN(nn.Module):
    """The same budget in dense convolutions: conv2d + maxpool2d + linear only.

    Every op here has a curated MBP kernel (fpga/pynq-z2/modelblaster/kernels/pext/).
    Channel counts are multiples of 8 so the DOT8 patch gather never has a ragged tail --
    PEXT_SPEC.md section 6 on why IC % 8 costs more than it looks.
    """

    MACS = 2729728

    def __init__(self, nclass=NCLASS):
        super().__init__()
        self.c1 = _cbr(1, 32, (10, 4), s=(2, 2), p=(5, 1))    # -> 32 x 25 x 5
        self.c2 = _cbr(32, 40, 3, p=1)                        # -> 40 x 25 x 5
        self.p2 = nn.MaxPool2d((2, 1))                        # -> 40 x 12 x 5
        self.c3 = _cbr(40, 48, 3, p=1)                        # -> 48 x 12 x 5
        self.p3 = nn.MaxPool2d((2, 1))                        # -> 48 x  6 x 5
        self.fc1 = nn.Linear(48 * 6 * 5, 64)
        self.fc2 = nn.Linear(64, nclass)

    def forward(self, x):
        x = self.p2(self.c2(self.c1(x)))
        x = self.p3(self.c3(x))
        x = torch.flatten(x, start_dim=1)
        x = torch.relu(self.fc1(x))
        return self.fc2(x)


class KwsCNNTiny(nn.Module):
    """A quarter of the budget, for the duty-cycle end of the table.  679,616 MACs."""

    MACS = 679616

    def __init__(self, nclass=NCLASS):
        super().__init__()
        self.c1 = _cbr(1, 16, (10, 4), s=(2, 2), p=(5, 1))    # -> 16 x 25 x 5
        self.p1 = nn.MaxPool2d((2, 1))                        # -> 16 x 12 x 5
        self.c2 = _cbr(16, 32, 3, p=1)                        # -> 32 x 12 x 5
        self.p2 = nn.MaxPool2d((2, 1))                        # -> 32 x  6 x 5
        self.c3 = _cbr(32, 32, 3, p=1)                        # -> 32 x  6 x 5
        self.fc1 = nn.Linear(32 * 6 * 5, 48)
        self.fc2 = nn.Linear(48, nclass)

    def forward(self, x):
        x = self.p1(self.c1(x))
        x = self.p2(self.c2(x))
        x = self.c3(x)
        x = torch.flatten(x, start_dim=1)
        x = torch.relu(self.fc1(x))
        return self.fc2(x)


ARCHS = {"dscnn": KwsDSCNN, "cnn": KwsCNN, "cnn_tiny": KwsCNNTiny}


def count_macs(model, shape=(1, 1, NFRAMES, NCOEF)):
    """Exact MAC count by walking the modules with a forward hook. No estimate."""
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


def fold_bn(model: nn.Module) -> nn.Module:
    """Fold every BatchNorm2d into the Conv2d immediately before it, in place.

    Returns a model whose graph is conv/relu/pool/linear only -- no batchnorm2d_s8, which
    on this core would be 649 soft-float instructions per element.
    """
    # The BatchNorm is DELETED, not replaced by an Identity. ModelBlaster's int8
    # frontend walks modules by isinstance and raises NotImplementedError on nn.Identity
    # -- a graph with a no-op in it is still a graph with an unsupported op in it.
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


# ---------------------------------------------------------------------------------
# Connected-digit transcription
# ---------------------------------------------------------------------------------
#
# Labs B17/B18 classify: the output is one of twelve slots. This TRANSCRIBES -- a
# variable-length digit string out of a 4.01 s utterance, decoded with CTC and scored
# with edit distance. It is the smallest task on this SoC that is honestly transcription
# rather than classification.
#
# THE REASON IT FITS AND A TRANSFORMER DOES NOT is the operator set, not the MAC count.
# Every layer here is conv2d + relu, which are two of the fifteen ModelBlaster `_s8`
# kernels that are float-free -- and conv2d is one of the three with a curated MBP
# kernel. There is no softmax, no LayerNorm and no attention anywhere in the graph:
#
#   * a GREEDY CTC decode needs no softmax at all. argmax over the logits is the same
#     argmax as over their softmax, because softmax is monotonic. The normalisation
#     exists only to make a probability, and a greedy decoder never reads one.
#   * the encoder is a stack of 1-D temporal convolutions, expressed as Conv2d with a
#     (k, 1) kernel over a C x T x 1 tensor. nn.Conv1d is NOT supported by the int8
#     frontend (SPEECH_ON_ROCKET.md section 3.1); this costs nothing and sidesteps it.
#
# So the whole network runs on the MBP path at the rate section 1.2 measures, and none
# of the 28 float-tainted kernels is reachable from it.

NDIGIT_CLASS = 11       # ten digits plus the CTC blank
DIG_FRAMES = 200        # 4.01 s at the "kws" geometry (30 ms window, 20 ms hop)


class DigitCTC(nn.Module):
    """1 x 200 x 10 int8 MFCC -> 11 logits x 50 frames. 2,067,200 MACs."""

    MACS = 2067200

    def __init__(self, nclass=NDIGIT_CLASS):
        super().__init__()
        # (5,10) over the full 10-coefficient width collapses frequency in one step and
        # halves time; everything after it is a pure temporal convolution.
        self.c1 = _cbr(1, 48, (5, 10), s=(2, 1), p=(2, 0))     # -> 48 x 100 x 1
        self.c2 = _cbr(48, 64, (5, 1), s=(2, 1), p=(2, 0))     # -> 64 x  50 x 1
        self.c3 = _cbr(64, 64, (5, 1), s=(1, 1), p=(2, 0))     # -> 64 x  50 x 1
        # The classifier is a 1x1 convolution rather than a Linear so the output stays
        # [N, C, T, 1] and the time axis survives. A Linear would need a transpose, and
        # a bare .permute() is one of the call_methods extract_int8 refuses.
        self.head = nn.Conv2d(64, nclass, 1)                   # -> 11 x  50 x 1

    def forward(self, x):
        x = self.c3(self.c2(self.c1(x)))
        return self.head(x)


class DigitCTCWide(DigitCTC):
    """The same graph with more channels.  7,718,400 MACs.

    Worth having because the MAC budget is not what constrains this task: at 2.07 MMAC
    the small model is RTF 0.02 for the acoustic model and the front end is 5x its cost,
    so capacity is nearly free here in a way it is not for a keyword spotter that has to
    run ten times a second.
    """

    MACS = 7718400

    def __init__(self, nclass=NDIGIT_CLASS):
        nn.Module.__init__(self)
        self.c1 = _cbr(1, 96, (5, 10), s=(2, 1), p=(2, 0))     # -> 96 x 100 x 1
        self.c2 = _cbr(96, 128, (5, 1), s=(2, 1), p=(2, 0))    # -> 128 x 50 x 1
        self.c3 = _cbr(128, 128, (5, 1), s=(1, 1), p=(2, 0))   # -> 128 x 50 x 1
        self.head = nn.Conv2d(128, nclass, 1)                  # -> 11 x 50 x 1


class DigitCTCT(nn.Module):
    """The same network with TIME ON THE WIDTH AXIS, which is worth 4x on this ISA.

    DigitCTCWide is a stack of 1-D temporal convolutions written the obvious way: a
    C x T x 1 tensor with (k, 1) kernels.  It measures 20.92 cycles per MAC on the board
    against kws_cnn's 1.30, and the reason is the layout, not the arithmetic.

    The curated MBP conv kernel materialises each output pixel's K-long reduction vector
    by walking (ic, kh, kw), and in NCHW the only CONTIGUOUS run in that walk is the kw
    one -- so the run length is KW.  With KW = 1 the gather degenerates to K separate
    single-byte loads: c3 does 640 of them per output pixel to feed 80 DOT8s.  kws_cnn's
    3x3 convolutions gather 120 runs of 3 bytes for the same K and measure 16x better per
    MAC.

    Transposing the feature map so that time is W and frequency is H turns every (k, 1)
    kernel into a (1, k) one.  The arithmetic is identical -- same MACs, same receptive
    field, same model -- and the gather run length goes from 1 byte to k.  That is the
    same NHWC argument PEXT_SPEC.md section 1.6 makes from DroNet, arriving here from a
    third direction, and it needs no new kernel and no new instruction.
    """

    MACS = 7718400
    TRANSPOSED = True          # input is [N, 1, NCOEF, FRAMES]

    def __init__(self, nclass=NDIGIT_CLASS):
        super().__init__()
        self.c1 = _cbr(1, 96, (10, 5), s=(1, 2), p=(0, 2))     # -> 96 x 1 x 100
        self.c2 = _cbr(96, 128, (1, 5), s=(1, 2), p=(0, 2))    # -> 128 x 1 x 50
        self.c3 = _cbr(128, 128, (1, 5), s=(1, 1), p=(0, 2))   # -> 128 x 1 x 50
        self.head = nn.Conv2d(128, nclass, 1)                  # -> 11 x 1 x 50

    def forward(self, x):
        return self.head(self.c3(self.c2(self.c1(x))))


ARCHS["digit_ctc"] = DigitCTC
ARCHS["digit_ctc_wide"] = DigitCTCWide
ARCHS["digit_ctc_t"] = DigitCTCT
