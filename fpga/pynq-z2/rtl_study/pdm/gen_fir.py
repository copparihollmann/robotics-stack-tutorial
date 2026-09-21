#!/usr/bin/env python3
"""Design the decimation FIR for the PDM microphone chain, and emit it three ways:
a Verilog $readmemh ROM, a C header for the golden model, and a report of what the
filter actually achieves.

The chain this filter sits in is fixed by the board clock, not by taste:

    FCLK0        = 1000 MHz / 29        = 34.482759 MHz   (the P-ext bitstream clock)
    f_pdm        = FCLK0 / (2*PDM_HALF) = 2.462911 MHz    PDM_HALF = 7
    f_cic        = f_pdm / CIC_R        = 111.9505 kHz    CIC_R = 22
    f_pcm        = f_cic / FIR_DECIM    = 15.9929 kHz     FIR_DECIM = 7

15992.9 Hz is 0.044% below 16 kHz.  Exactly 16 kHz is NOT reachable: it would need
FCLK0/(2*PDM_HALF*CIC_R*FIR_DECIM) = 16000, i.e. an integer divisor of 2155.17.

The FIR has to stop everything that decimation-by-7 would fold into 0-7 kHz, i.e.
everything from f_pcm - 7000 = 8993 Hz upwards.  It also inverts the CIC's passband
droop, which at CIC_R=22 is only 0.22 dB at 7 kHz -- small, but free to correct.
"""
import os

import numpy as np
from scipy import signal

HERE     = os.path.dirname(os.path.abspath(__file__))
SRC      = os.path.normpath(os.path.join(HERE, "..", "..", "src"))
OUT_VH   = os.path.join(SRC,  "pdm_fir_coeffs.vh")
OUT_H    = os.path.join(HERE, "fir_coeffs.h")
OUT_JSON = os.path.join(HERE, "fir_design.json")

FCLK      = 1000e6 / 29.0
PDM_HALF  = 7
CIC_R     = 22
CIC_N     = 4
FIR_DECIM = 7
NTAPS     = 289          # odd -> integer group delay
COEF_W    = 18           # signed, fits the DSP48E1 B port
OUT_SHIFT = 22

F_PDM = FCLK / (2 * PDM_HALF)
F_CIC = F_PDM / CIC_R
F_PCM = F_CIC / FIR_DECIM

FPASS = 7000.0
FSTOP = F_PCM - FPASS    # 8992.9 Hz -- the first band that folds into the passband


def cic_response(f):
    """|H(f)| of an R-to-1, N-stage, M=1 CIC, normalised to 1 at DC, evaluated at the
    CIC *input* rate."""
    x = np.pi * f / F_PDM
    num = np.sin(x * CIC_R)
    den = CIC_R * np.sin(x)
    r = np.where(np.abs(x) < 1e-12, 1.0, num / np.where(den == 0, 1e-30, den))
    return np.abs(r) ** CIC_N


def design():
    # Least-squares design against a desired response of 1/CIC-droop in the passband
    # and 0 in the stopband.  firls wants band edges in units of the Nyquist rate.
    nyq = F_CIC / 2.0
    fp = np.linspace(0.0, FPASS, 32)
    desired_p = 1.0 / cic_response(fp)
    bands, desired, weight = [], [], []
    for i in range(len(fp) - 1):
        bands += [fp[i] / nyq, fp[i + 1] / nyq]
        desired += [desired_p[i], desired_p[i + 1]]
        weight.append(1.0)
    bands += [FSTOP / nyq, 1.0]
    desired += [0.0, 0.0]
    weight.append(40.0)          # buy stopband depth at the cost of passband ripple
    h = signal.firls(NTAPS, bands, desired, weight=weight)
    return h / h.sum()           # unity DC gain before quantisation


def quantise(h):
    # Scale so the whole chain (PDM density +-1 -> PCM) has a DC gain of 32768.
    scale = 32768.0 * (2.0 ** OUT_SHIFT) / (CIC_R ** CIC_N)
    q = np.round(h * scale).astype(np.int64)
    assert np.abs(q).max() < 2 ** (COEF_W - 1), "coefficient overflows %d bits: %d" % (
        COEF_W, np.abs(q).max())
    return q, scale


def report(h, q, scale):
    w = np.linspace(0.0, F_CIC / 2.0, 20001)
    Hf = np.abs(np.polyval(q[::-1].astype(float), np.exp(-2j * np.pi * w / F_CIC)))
    Hf /= q.sum()
    cic = cic_response(w)
    tot = 20 * np.log10(Hf * cic + 1e-30)
    fir = 20 * np.log10(Hf + 1e-30)
    pb = w <= FPASS
    sb = w >= FSTOP
    out = {
        "f_pdm_hz": F_PDM, "f_cic_hz": F_CIC, "f_pcm_hz": F_PCM,
        "pcm_rate_err_pct": 100.0 * (F_PCM - 16000.0) / 16000.0,
        "ntaps": NTAPS, "coef_bits": COEF_W, "out_shift": OUT_SHIFT,
        "coef_scale": scale, "coef_sum": int(q.sum()), "coef_absmax": int(np.abs(q).max()),
        "coef_abssum": int(np.abs(q).sum()),
        "fir_pb_ripple_db": float(fir[pb].max() - fir[pb].min()),
        "fir_sb_max_db": float(fir[sb].max()),
        "chain_pb_ripple_db": float(tot[pb].max() - tot[pb].min()),
        "chain_sb_max_db": float(tot[sb].max()),
        "cic_droop_7k_db": float(20 * np.log10(cic_response(np.array([7000.0]))[0])),
        "dc_gain_pdm_to_pcm": float((CIC_R ** CIC_N) * q.sum() / 2.0 ** OUT_SHIFT),
    }
    # CIC alias rejection: worst point of the band that folds into 0-7 kHz after the
    # CIC's own decimate-by-22, i.e. k*F_CIC +- 7 kHz for k >= 1.
    worst = 0.0
    for k in range(1, CIC_R):
        for f in (k * F_CIC - FPASS, k * F_CIC + FPASS):
            if 0 < f < F_PDM / 2:
                worst = max(worst, cic_response(np.array([f]))[0])
    out["cic_alias_worst_db"] = float(20 * np.log10(worst))
    return out


if __name__ == "__main__":
    import json, sys
    h = design()
    q, scale = quantise(h)
    rep = report(h, q, scale)
    # An `include of explicit assignments, not a $readmemh .mem file.  The
    # coefficients then travel inside the RTL and there is no relative-path question
    # for Vivado (whose cwd during a bitstream build is fpga/pynq-z2, not src/), for
    # the OOC study, or for Verilator.  289 lines of Verilog buys that outright.
    with open(OUT_VH, "w") as f:
        f.write("// %d taps, %d-bit signed.  GENERATED by rtl_study/pdm/gen_fir.py --\n"
                "// do not edit.  Included inside an initial block in pdm_fir_mac.v.\n"
                % (NTAPS, COEF_W))
        for i, c in enumerate(q):
            f.write("coef[%d] = %d'sh%05x;\n" % (i, COEF_W, int(c) & ((1 << COEF_W) - 1)))
    with open(OUT_H, "w") as f:
        f.write("/* Generated by gen_fir.py -- do not edit. */\n")
        f.write("#define PDM_FIR_NTAPS %d\n#define PDM_FIR_SHIFT %d\n" % (NTAPS, OUT_SHIFT))
        f.write("#define PDM_CIC_R %d\n#define PDM_CIC_N %d\n#define PDM_FIR_DECIM %d\n"
                % (CIC_R, CIC_N, FIR_DECIM))
        f.write("static const int pdm_fir_coeffs[%d] = {\n" % NTAPS)
        for i in range(0, NTAPS, 8):
            f.write("  " + ", ".join("%d" % c for c in q[i:i + 8]) + ",\n")
        f.write("};\n")
    json.dump(rep, open(OUT_JSON, "w"), indent=2)
    for k, v in rep.items():
        print("%-22s %s" % (k, ("%.4f" % v) if isinstance(v, float) else v))
