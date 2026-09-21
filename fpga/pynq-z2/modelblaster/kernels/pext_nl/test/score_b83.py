#!/usr/bin/env python3
"""Score Lab B83's arms against band.md, which was committed before the board.

    python3 archive/runs/b83_all_levers/score_b83.py

Every quantity is recomputed from each record's own rows -- the composer's quantity, cycles for
the measured mean 11.976 steps with the once-per-boot weight image removed from decoder step 0
-- so nothing here is copied from a headline.
"""
import collections
import json
import os
import sys

R = os.environ.get("IISWC_ROOT") or sys.exit("source env.sh first (IISWC_ROOT unset)")
MEAN = 11.976470588235294          # decoder_tokens_dev.json models.R.mean, NEVER a run record
W = 4.0
PERFECT = 29.0 / 24.0              # 34.4828 -> 41.6667, both 1000/N, no rounding


def rec(name):
    p = os.path.join(R, "out", name, "run.json")
    r = json.load(open(p))
    m = next(iter(r["models"].values()))
    return r, m


def dec_term(m):
    per = collections.Counter()
    for row in m["rows"]:
        per[row["step"]] += row["cycles"]
    steps = [per[k] for k in sorted(per)]
    img = (m.get("engine") or {}).get("image_cycles") or 0
    st = list(steps)
    st[0] -= img
    whole = int(MEAN)
    return float(sum(st[:whole])) + (MEAN - whole) * st[whole]


def enc_term(m):
    return float(m["cycles_per_iteration"])


def rtf(c, clk):
    return c / (clk * W)


def band(name, got, lo, hi, note=""):
    ok = lo <= got <= hi
    print("  %-52s %12.6f   [%.6f, %.6f]  %s %s"
          % (name, got, lo, hi, "HELD" if ok else "**MISSED**", note))
    return ok


def main():
    arms = {}
    for n in ("b83_enc2_ctl", "b83_enc2_f41667", "b83_dec_ctl", "b83_dec_f41667"):
        try:
            arms[n] = rec(n)
        except FileNotFoundError:
            sys.exit("missing arm: out/%s/run.json -- run the board session first" % n)

    print("== THE ARMS, and the fields every claim below rests on ==")
    print("  %-16s %-11s %-10s %-9s %-14s %-4s %-4s %s"
          % ("arm", "clock_hz", "MAGIC", "bit md5", "kernel digest", "mae", "fb", "profiled"))
    for n, (r, m) in arms.items():
        km = m.get("kernel_manifest") or {}
        eng = m.get("engine") or {}
        print("  %-16s %-11.0f %-10s %-9s %-14s %-4s %-4s %s/%s"
              % (n, m["clock_hz"], m.get("soc_magic"), (m.get("bitstream_md5") or "")[:8],
                 km.get("digest"), m.get("max_abs_err"), eng.get("calls_fallback"),
                 m.get("dispatches_profiled"), m.get("dispatches_in_ir")))

    ec, ef = enc_term(arms["b83_enc2_ctl"][1]), enc_term(arms["b83_enc2_f41667"][1])
    dc, df = dec_term(arms["b83_dec_ctl"][1]), dec_term(arms["b83_dec_f41667"][1])
    CS = arms["b83_enc2_ctl"][1]["clock_hz"]
    CF = arms["b83_enc2_f41667"][1]["clock_hz"]

    print("\n== P8: clock_hz reads the real clock in the emitted records ==")
    p8 = True
    for n, (r, m) in arms.items():
        want = 41666667.0 if n.endswith("f41667") else 34482759.0
        ok = abs(m["clock_hz"] - want) < 1.0
        p8 &= ok
        print("  %-16s clock_hz %12.0f  want %12.0f  %s"
              % (n, m["clock_hz"], want, "ok" if ok else "**WRONG**"))

    print("\n== P1 / P2: the clock scaling ratios (perfect = 29/24 = %.6f) ==" % PERFECT)
    print("  encoder cycles %12.0f -> %12.0f  x%.6f" % (ec, ef, ef / ec))
    print("  decoder cycles %12.0f -> %12.0f  x%.6f" % (dc, df, df / dc))
    s_enc = rtf(ec, CS) / rtf(ef, CF)
    s_dec = rtf(dc, CS) / rtf(df, CF)
    p1 = band("P1  s_enc", s_enc, 1.190, 1.2083)
    p2 = band("P2  s_dec (all levers on)", s_dec, 1.180, 1.2083)
    phi_d = (df / dc - 1) / (PERFECT - 1)
    phi_e = (ef / ec - 1) / (PERFECT - 1)
    print("  implied phi_enc %.5f   phi_dec %.5f  (B81 at int8: 0.01293 / 0.03063)"
          % (phi_e, phi_d))
    p2b = band("P2b phi_dec at int6", phi_d, 0.005, 0.035,
               "(<= 0.0306 = int6 is LESS wall-clock-exposed)")

    print("\n== P3 / P4: RTF_e2e, this session's own two clocks ==")
    slow_e2e = rtf(ec, CS) + rtf(dc, CS)
    fast_e2e = rtf(ef, CF) + rtf(df, CF)
    print("  34.4828 MHz  encoder %.6f + decoder %.6f = %.6f" % (rtf(ec, CS), rtf(dc, CS), slow_e2e))
    print("  41.6667 MHz  encoder %.6f + decoder %.6f = %.6f" % (rtf(ef, CF), rtf(df, CF), fast_e2e))
    p3 = band("P3  in-session ratio", fast_e2e / slow_e2e, 0.824, 0.842)
    p4 = band("P4  ** HEADLINE RTF_e2e at 41.6667 **", fast_e2e, 1.330, 1.366)

    print("\n== P5: the fill-placement draw on a THIRD build (tests L354's bimodality) ==")
    ref = 91110214.0            # b82_dec_unr_on, 0x5A5A002F, 34.4828, identical kernel set
    ratio = dc / ref
    print("  b83_dec_ctl %12.0f  vs  b82_dec_unr_on %12.0f   x%.6f" % (dc, ref, ratio))
    if 0.995 <= ratio <= 1.005:
        p5, which = True, "FAST draw (0.875) -- same state as 0x5A5A0030 and 0x5A5A002F"
    elif 1.012 <= ratio <= 1.025:
        p5, which = True, "SLOW draw (0.833) -- the state 0x5A5A002E drew"
    else:
        p5, which = False, "**BETWEEN THE TWO STATES -- L354's bimodality is FALSIFIED**"
    print("  P5  %s  %s" % ("HELD" if p5 else "**MISSED**", which))

    print("\n== P6: the engine does the same work at both clocks ==")
    p6 = True
    for half, a, b in (("encoder", "b83_enc2_ctl", "b83_enc2_f41667"),
                       ("decoder", "b83_dec_ctl", "b83_dec_f41667")):
        ea = arms[a][1].get("engine") or {}
        eb = arms[b][1].get("engine") or {}
        for k in ("fill_beats", "bytes_wgt", "bytes_act", "steps", "pairs", "calls_engine",
                  "loads_wgt", "loads_act", "image_bytes", "cyc_tseq"):
            va, vb = ea.get(k), eb.get(k)
            if va is None and vb is None:
                continue
            ok = va == vb
            p6 &= ok
            if not ok:
                print("  %s %-14s %s vs %s  **DIFFERS**" % (half, k, va, vb))
        print("  %s: all counters identical across the two clocks" % half
              if p6 else "  %s: see above" % half)

    print("\n== P7: correctness ==")
    p7 = True
    for n, (r, m) in arms.items():
        eng = m.get("engine") or {}
        ok = (m.get("max_abs_err") == 0 and m.get("max_abs_err_meaning") == "matched"
              and (eng.get("calls_fallback") in (0, None))
              and m.get("dispatches_profiled") == m.get("dispatches_in_ir"))
        p7 &= ok
        print("  %-16s max_abs_err %s (%s)  calls_fallback %s  %s"
              % (n, m.get("max_abs_err"), m.get("max_abs_err_meaning"),
                 eng.get("calls_fallback"), "ok" if ok else "**FAIL**"))

    print("\n== P9: DO THE LEVERS COMPOSE?  naive product vs the overlap-aware figure ==")
    naive = 1.334190
    aware = 1.344393
    print("  naive (every lever an independent multiplier)  %.6f" % naive)
    print("  overlap-aware (B82's measured joint int6+UNR8) %.6f" % aware)
    print("  MEASURED                                       %.6f" % fast_e2e)
    dn, da = fast_e2e - naive, fast_e2e - aware
    print("  distance from naive %+.6f (%+.2f %%),  from overlap-aware %+.6f (%+.2f %%)"
          % (dn, 100 * dn / naive, da, 100 * da / aware))
    p9 = fast_e2e > naive
    print("  P9  %s -- %s" % ("HELD" if p9 else "**MISSED**",
                              "the naive projection overstates the gain, as predicted"
                              if p9 else "the levers composed BETTER than independently"))

    print("\n== SUMMARY ==")
    res = [("P1", p1), ("P2", p2), ("P2b", p2b), ("P3", p3), ("P4", p4),
           ("P5", p5), ("P6", p6), ("P7", p7), ("P8", p8), ("P9", p9)]
    for k, v in res:
        print("  %-4s %s" % (k, "HELD" if v else "**MISSED**"))
    json.dump({"encoder_cycles": {"slow": ec, "fast": ef},
               "decoder_cycles": {"slow": dc, "fast": df},
               "clock_hz": {"slow": CS, "fast": CF},
               "rtf_e2e": {"slow": slow_e2e, "fast": fast_e2e},
               "s_enc": s_enc, "s_dec": s_dec, "phi_enc": phi_e, "phi_dec": phi_d,
               "draw_ratio_vs_b82_dec_unr_on": ratio,
               "verdicts": dict(res)},
              open(os.path.join(R, "archive/runs/b83_all_levers/score_b83.json"), "w"), indent=1)
    return 0 if all(v for _, v in res) else 1


if __name__ == "__main__":
    sys.exit(main())
