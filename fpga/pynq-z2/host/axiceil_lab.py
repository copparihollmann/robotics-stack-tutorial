#!/usr/bin/env python3
"""Workstation side of the interface-ceiling lab (scripts/47_axiceil_lab.sh). Never touches the board.

    python3 axiceil_lab.py plan <name[,name...]> --fmax 125      > plan.json
    python3 axiceil_lab.py rows run.jsonl --md5 M --build DIR   (appends to bwlab/results.csv;
                                                                 call under with_lock.sh results)
    python3 axiceil_lab.py table run.jsonl                      (human summary)

MEMORY_BANDWIDTH.md section 7.  One row per port per direction per point, plus an aggregate row
per direction whenever a point drives more than one port or both directions.  Every row carries
the SLCR-verified fabric clock, the DDR-controller/AFI QoS readback hash, and the data-integrity
verdict; a point with any error is logged with INTEGRITY FAIL, not dropped.

COLUMNS APPENDED TO results.csv (at the end, once, under the results lock; no existing row is
touched): burst_beats, hp_port_set, ddr_port_set, scope, hpr_state, ddrqos_hash.
"""
import argparse
import csv
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CSV_PATH = os.environ.get("BWLAB_CSV", os.path.join(REPO, "fpga/pynq-z2/bwlab/results.csv"))
NEW_COLS = ["burst_beats", "hp_port_set", "ddr_port_set", "scope", "hpr_state", "ddrqos_hash"]
CONFIG = "AxiCeil4HP"
# The board's own clock is not the workstation's (on 2026-09-17 it read 2025-05-04).  Record
# times in the runner's JSON are the board's, so rows add CLOCK_OFFSET, measured by the lab as
# workstation epoch minus board epoch just before the run.  See bwlab/errata.csv.
CLOCK_OFFSET = 0.0


def wall(t):
    return __import__("datetime").datetime.fromtimestamp(t + CLOCK_OFFSET).astimezone().isoformat(timespec="seconds")
MAGIC = "0x5A5A0020"
DDRC_PORT = {0: 3, 1: 3, 2: 2, 3: 2}
REGION_BYTES = 32 * 1024 * 1024

# FCLK0 = 1000 MHz / (D0 * D1): every clock below is exactly reachable.
CLOCKS = [10.0, 20.0, 25.0, 40.0, 50.0, 66.6667, 100.0, 125.0, 142.857, 166.667, 200.0]


def pt(pid, mhz, ports, direction, L, k, reps=1, window_s=0.5, k_rd=None, k_wr=None):
    return {"id": pid, "fclk_mhz": mhz, "repeat": reps, "window_s": window_s,
            "ports": {str(p): {"dir": direction, "len": L, "k_rd": k_rd or k, "k_wr": k_wr or k}
                      for p in ports}}


def hp(ports):
    return "+".join(f"HP{p}" for p in ports)


def ppass(pid, port, L, k, words, mhz="keep", verify_k=1):
    return {"type": "pass", "id": pid, "fclk_mhz": mhz, "port": port, "len": L, "k": k,
            "words": words, "verify_k": verify_k}


def plan(name, fmax):
    f = fmax
    P = []
    # After 2026-09-16 (BOARD_FINDINGS.md): the first run is the smallest shape and nothing else,
    # at the clock the board already has; the ladder widens one dimension per step and the
    # runner stops at the first anomaly.
    if name == "minimal":
        P.append(ppass("minimal_HP0_L8_k1_64KiB", 0, 8, 1, 8192))
    # The ladder, one step per plan name ("ladder" is all of them).  The coordinator's rule for the
    # board: steps that match known-safe Rocket traffic (8 beats, 1-2 outstanding, HP0) may share
    # a session; 16 beats, 8 outstanding, 32 MiB and every port other than HP0 get a session each,
    # each followed by a Lab 35 health check.
    steps = [("ladder1", ppass("ladder1_HP0_L8_k1_64KiB", 0, 8, 1, 8192)),
             ("ladder2", ppass("ladder2_HP0_L16_k1_64KiB", 0, 16, 1, 8192)),
             ("ladder3", ppass("ladder3_HP0_L8_k2_64KiB", 0, 8, 2, 8192, verify_k=2)),
             ("ladder4", ppass("ladder4_HP0_L8_k8_64KiB", 0, 8, 8, 8192, verify_k=8)),
             ("ladder5", ppass("ladder5_HP0_L16_k8_64KiB", 0, 16, 8, 8192, verify_k=8)),
             ("ladder6", ppass("ladder6_HP0_L1_k1_64KiB", 0, 1, 1, 8192)),
             ("ladder7", ppass("ladder7_HP0_L16_k8_32MiB", 0, 16, 8, 4194304, verify_k=8)),
             ("ladder8", ppass("ladder8_HP2_L8_k1_64KiB", 2, 8, 1, 8192)),
             ("ladder9", ppass("ladder9_HP1_L8_k1_64KiB", 1, 8, 1, 8192)),
             ("ladder10", ppass("ladder10_HP3_L8_k1_64KiB", 3, 8, 1, 8192))]
    for step, point in steps:
        if name in ("ladder", step):
            P.append(point)
    # After the ladder (coordinator, 2026-09-17): the clock hypothesis alone, then the per-port
    # ceiling at 100 MHz (the bypass memory domain's clock), then four ports.  Each is one board
    # session followed by Lab 35.  S9a also splits the fixed per-transaction cost into a part
    # constant in ns (PS/AFI/DDR) and a part constant in cycles (the instrument): k=1 at 1, 8 and
    # 16 beats, as at 34.4828 MHz in S5, S1 and S2.
    if name == "s9a":
        P.append(ppass("s9a_HP0_L8_k1_64KiB_100MHz", 0, 8, 1, 8192, mhz=100.0))
        P.append(ppass("s9a_HP0_L1_k1_64KiB_100MHz", 0, 1, 1, 8192, mhz=100.0))
        P.append(ppass("s9a_HP0_L16_k1_64KiB_100MHz", 0, 16, 1, 8192, mhz=100.0))
    if name == "s9b":
        P.append(ppass("s9b_HP0_L16_k8_64KiB_100MHz", 0, 16, 8, 8192, mhz=100.0, verify_k=8))
        P.append(ppass("s9b_HP0_L16_k8_32MiB_100MHz", 0, 16, 8, 4194304, mhz=100.0, verify_k=8))
    def win(pid, mhz, ports, d, L=16, k=8, reps=3):
        q = pt(pid, mhz, ports, d, L, k, reps=reps, window_s=0.5)
        q["prep"] = {"len": 16, "k": 8}
        return q
    if name == "s9c":      # the window path on one port before four
        P.append(win("s9c_HP0_rd_L16_k8_100MHz", 100.0, [0], "rd"))
        P.append(win("s9c_HP0_wr_L16_k8_100MHz", 100.0, [0], "wr"))
    # S10 (coordinator): the bend and the plateau, like for like with 0x5A5A0017's four bypass lanes
    # (8-beat Gets, k = 1/2/4/8 per lane), and the two port pairs.  S10a: 16-beat plateau, rd and wr.
    if name == "s10":
        for k in (1, 2, 4, 8):
            P.append(win(f"s10_HP0123_rd_L8_k{k}_100MHz", 100.0, [0, 1, 2, 3], "rd", L=8, k=k))
        P.append(win("s10_HP01_rd_L8_k8_100MHz", 100.0, [0, 1], "rd", L=8, k=8))
        P.append(win("s10_HP02_rd_L8_k8_100MHz", 100.0, [0, 2], "rd", L=8, k=8))
    if name in ("s10a", "s10a_plus"):
        P.append(win("s10a_HP0123_rd_L16_k8_100MHz", 100.0, [0, 1, 2, 3], "rd"))
        P.append(win("s10a_HP0123_wr_L16_k8_100MHz", 100.0, [0, 1, 2, 3], "wr"))
    if name == "s10a_plus":   # approved additions, novel shape last: (b) controller port 2 alone, then (a) k=16 on port 3
        P.append(win("s10a_HP23_rd_L8_k8_100MHz", 100.0, [2, 3], "rd", L=8, k=8))
        P.append(win("s10a_HP01_rd_L8_k16_100MHz", 100.0, [0, 1], "rd", L=8, k=16))
    if name == "pairloc":     # the pair discrepancy with the bypass: same DDR rows vs rows 64 MiB apart
        # the S10 control first (separate regions), then both HP0 and HP1 reading HP0's region
        # (the same rows at the same time, as the bypass's lanes do), then the control again;
        # then the same on controller port 2 (HP2+HP3)
        P.append(win("pairloc_HP01_sep_rd_L8_k8_100MHz", 100.0, [0, 1], "rd", L=8, k=8))
        q = win("pairloc_HP01_same_rd_L8_k8_100MHz", 100.0, [0, 1], "rd", L=8, k=8)
        q["ports"]["1"]["rd_region"] = 0
        P.append(q)
        P.append(win("pairloc_HP01_sep2_rd_L8_k8_100MHz", 100.0, [0, 1], "rd", L=8, k=8))
        q = win("pairloc_HP23_same_rd_L8_k8_100MHz", 100.0, [2, 3], "rd", L=8, k=8)
        q["ports"]["3"]["rd_region"] = 2
        P.append(q)
    if name == "s10c":        # 4-beat, k=8, four ports: the cap test (offers ~ 4*8*32/23.5 > 20 B/cycle)
        P.append(win("s10c_HP0123_rd_L4_k8_100MHz", 100.0, [0, 1, 2, 3], "rd", L=4, k=8))
        P.append(win("s10c_HP0123_wr_L4_k8_100MHz", 100.0, [0, 1, 2, 3], "wr", L=4, k=8))
        # 1-beat offers only ~11 B/cycle in total: below the cap, so it measures latency under load, not the cap
        P.append(win("s10c_belowcap_HP0123_rd_L1_k8_100MHz", 100.0, [0, 1, 2, 3], "rd", L=1, k=8))
    if name == "s10d":        # tests T(L) at lengths it was not fitted to (MEMORY_BANDWIDTH.md s7.7, 4809647)
        P.append(win("s10d_HP0123_rd_L2_k8_100MHz", 100.0, [0, 1, 2, 3], "rd", L=2, k=8))
        P.append(win("s10d_HP0123_rd_L12_k8_100MHz", 100.0, [0, 1, 2, 3], "rd", L=12, k=8))
        P.append(win("s10d_HP0123_wr_L2_k8_100MHz", 100.0, [0, 1, 2, 3], "wr", L=2, k=8))
    if name == "s10b":        # cancelled by the coordinator (the bypass showed the cap is clock-independent)
        P.append(win("s10b_HP0123_rd_L16_k8_125MHz", 125.0, [0, 1, 2, 3], "rd"))
        P.append(win("s10b_HP0123_wr_L16_k8_125MHz", 125.0, [0, 1, 2, 3], "wr"))
    if name == "ceilingkeep":
        for d in ("rd", "wr", "rw"):
            P.append(pt(f"ceilkeep_{d}_L16_k8", "keep", [0], d, 16, 8, reps=3))
    if name in ("ceiling1", "full"):
        for d in ("rd", "wr", "rw"):
            P.append(pt(f"ceil1_{d}_L16_k8", f, [0], d, 16, 8, reps=3))
        for d in ("rd", "wr"):
            P.append(pt(f"ceil1_{d}_L16_k16", f, [0], d, 16, 16, reps=2))
    if name in ("clock", "full"):
        for mhz in [c for c in CLOCKS if c <= f * 1.001]:
            for d in ("rd", "wr"):
                P.append(pt(f"clock_{mhz:g}_{d}_L16_k8", mhz, [0], d, 16, 8, reps=2))
    if name in ("burst", "full"):
        for k in (1, 8):
            for L in (1, 2, 4, 8, 16):
                for d in ("rd", "wr"):
                    P.append(pt(f"burst_{d}_L{L}_k{k}", f, [0], d, L, k, reps=2))
    if name in ("outstanding", "full"):
        for L in (16, 1):
            ks = (1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16) if L == 16 else (1, 2, 4, 8, 16)
            for k in ks:
                for d in ("rd", "wr"):
                    P.append(pt(f"out_{d}_L{L}_k{k}", f, [0], d, L, k, reps=2))
    if name == "portskey":
        for s in ([0], [0, 1], [0, 2], [0, 1, 2, 3]):
            for d in ("rd", "wr", "rw"):
                P.append(pt(f"ports_{hp(s)}_{d}_L16_k8", f, s, d, 16, 8, reps=2))
    if name in ("ports", "full"):
        sets = [[0], [1], [2], [3], [0, 1], [2, 3], [0, 2], [1, 3], [0, 3], [0, 1, 2, 3]]
        key = ([0], [0, 1], [0, 2], [0, 1, 2, 3])
        for s in sets:
            for d in ("rd", "wr", "rw"):
                P.append(pt(f"ports_{hp(s)}_{d}_L16_k8", f, s, d, 16, 8, reps=3 if s in key else 1))
    if name == "smoke":
        P.append(pt("smoke_rd", min(f, 50.0), [0], "rd", 16, 8, window_s=0.2))
        P.append(pt("smoke_wr", min(f, 50.0), [0], "wr", 16, 8, window_s=0.2))
        P.append(pt("smoke_4port_rw", min(f, 50.0), [0, 1, 2, 3], "rw", 16, 8, window_s=0.2))
    if not P:
        sys.exit(f"unknown plan '{name}'")
    return P


def plans(names, fmax):
    """`smoke,ceiling1,portskey`: plans run in order, in one board session."""
    P = []
    for n in names.split(","):
        P += plan(n, fmax)
    return {"magic": MAGIC, "fmax_mhz": fmax, "region_words": REGION_BYTES // 8, "points": P}


# ------------------------------------------------------------------------------ rows
def build_info(build, mhz=None):
    """Area from the build; WNS/WHS from the STA report (tcl/sta_axiceil.tcl) at the LONGEST
    analysed period that is not longer than the period the point ran at.  In a one-clock design
    setup slack only grows with the period, so that report is a lower bound on slack at the run
    clock.  Falls back to the build's own timing summary (its constraint period)."""
    info = {"lut": "", "ff": "", "bram": "", "dsp": "", "wns_ns": "", "whs_ns": "", "wns_at": ""}
    rdir = os.path.join(build, "reports")
    util = os.path.join(rdir, "post_route_util.rpt")
    tim = os.path.join(rdir, "timing_summary.rpt")
    if mhz and os.path.isdir(rdir):
        run_period = 1000.0 / mhz
        cands = []
        for fn in os.listdir(rdir):
            m = re.match(r"sta_period_([0-9.]+)[.]rpt$", fn)
            if m and float(m.group(1)) <= run_period + 1e-3:
                cands.append((float(m.group(1)), fn))
        if cands:
            per, fn = max(cands)
            tim = os.path.join(rdir, fn)
            info["wns_at"] = "%.3fns" % per
    if os.path.exists(util):
        for line in open(util):
            for key, col in (("Slice LUTs", "lut"), ("Slice Registers", "ff"),
                             ("Block RAM Tile", "bram"), ("DSPs", "dsp")):
                m = re.match(r"\|\s*" + re.escape(key) + r"\s*\|\s*([\d.]+)", line)
                if m and not info[col]:
                    info[col] = m.group(1)
    if os.path.exists(tim):
        lines = open(tim).read().splitlines()
        for i, line in enumerate(lines):
            if re.match(r"\s*WNS\(ns\)\s+TNS\(ns\)", line):
                vals = lines[i + 2].split()
                info["wns_ns"], info["whs_ns"] = vals[0], vals[4]
                break
    if not info["wns_at"]:
        info["wns_at"] = "build constraint"
    return info


def hpr_state(summary):
    m = re.search(r"hpr_rd_p0123=(\d{4}) lpr_entries_field=(\d+)", summary)
    if not m:
        return "unknown"
    return f"HPR rd p0123={m.group(1)}; lpr_num_entries={m.group(2)}"


def records(path):
    for line in open(path):
        line = line.strip()
        if line.startswith("{"):
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                pass


def rows_from(path, md5, build):
    infos = {}
    qos_summary, fabric = "", {}
    out = []
    for rec in records(path):
        if rec["kind"] == "ddrc_afi" and rec["when"] == "before":
            qos_summary = rec["summary"]
        if rec["kind"] == "clock":
            fabric[round(rec["slcr"]["fclk0"]["mhz"], 4)] = rec["fabric_mhz"]
        if rec["kind"] not in ("point", "prep", "pass"):
            continue
        ts = wall(rec["t"])
        if rec["kind"] == "prep":
            continue    # prep passes are reported in the JSONL and summarised in notes below
        if rec["kind"] == "pass":
            out += pass_rows(rec, md5, build, infos, qos_summary, fabric)
            continue
        mhz = rec["fclk_mhz"]
        if build and mhz not in infos:
            infos[mhz] = build_info(build, mhz)
        info = dict(infos.get(mhz, {}))
        wns_at = info.pop("wns_at", "")
        base = {"timestamp": ts, "bitstream_md5": md5, "soc_magic": MAGIC, "config": CONFIG,
                "level": "DRAM", "source": "silicon", "working_set_bytes": str(REGION_BYTES),
                "hpr_state": hpr_state(qos_summary), "ddrqos_hash": rec.get("qos_hash", ""), **info}
        cfg, res, ver = rec["cfg"], rec["result"], rec["verify"]
        window = res["window"]
        ports = sorted(int(p) for p in cfg["ports"])
        agg = {"rd": 0, "wr": 0}
        integ = []
        for p in ports:
            c, d = cfg["ports"][str(p)], res["ports"][str(p)]
            bad = []
            if d["rd_err"] or d["rd_proto"]:
                bad.append(f"rd_err={d['rd_err']} rd_proto={d['rd_proto']}")
            if d["wr_err"] or d["wr_proto"]:
                bad.append(f"wr_err={d['wr_err']} wr_proto={d['wr_proto']}")
            if d["pstat"] & 0x5C:
                bad.append(f"pstat=0x{d['pstat']:X}")
            v = ver.get(str(p))
            if c["dir"] in ("wr", "rw"):
                if v is None:
                    bad.append("write not verified")
                elif v["rd_err"] or v["rd_proto"] or v["rd_beats"] != v["words"]:
                    bad.append(f"verify rd_err={v['rd_err']} beats={v['rd_beats']}/{v['words']}")
            if res["timed_out"]:
                bad.append("timed out")
            integ += [f"HP{p}: {b}" for b in bad]
            L = c["len"]
            w = max(window, 1)
            diag = (f"ar_stall={d['ar_stall_win'] / w:.3f} r_gap={d['r_gap_win'] / w:.3f} "
                    f"aw_stall={d['aw_stall_win'] / w:.3f} w_stall={d['w_stall_win'] / w:.3f} "
                    f"w_idle={d['w_idle_win'] / w:.3f} avg_out_rd={d['rd_out_sum'] / w:.2f} "
                    f"avg_out_wr={d['wr_out_sum'] / w:.2f} peak_out=0x{d['peak_out']:04X} "
                    f"avg_racount={d['racount_sum'] / w:.2f} avg_rcount={d['rcount_sum'] / w:.2f} "
                    f"avg_wacount={d['wacount_sum'] / w:.2f} avg_wcount={d['wcount_sum'] / w:.2f} "
                    f"fifo_max=0x{d['fifo_max']:08X} b_beats_win={d['b_beats_win']} "
                    f"drain={d['drain_cycles']}")
            for direction in ("rd", "wr"):
                if c["dir"] not in (direction, "rw"):
                    continue
                beats = d["rd_beats_win"] if direction == "rd" else d["wr_beats_win"]
                agg[direction] += beats
                k = c["k_rd"] if direction == "rd" else c["k_wr"]
                bpc = beats * 8 / w
                verdict = "data ok" if not bad else "INTEGRITY FAIL: " + "; ".join(bad)
                vtxt = (f" verify={v['words']}w/{v['rd_err']}err" if v else "")
                out.append({**base, "fclk_core_mhz": f"{mhz:.4f}", "fclk_mem_mhz": f"{mhz:.4f}",
                            "n_hp_ports": str(len(ports)), "outstanding": str(k),
                            "burst_bytes": str(8 * L), "direction": direction,
                            "bytes_moved": str(beats * 8), "cycles": str(window),
                            "bytes_per_cycle": f"{bpc:.4f}", "mb_per_s": f"{bpc * mhz:.1f}",
                            "burst_beats": str(L), "hp_port_set": hp(ports),
                            "ddr_port_set": str(DDRC_PORT[p]), "scope": f"port:HP{p}",
                            "notes": (f"axiceil {rec['cfg']['id']} rep{rec['rep']} dir={c['dir']} "
                                      f"{verdict}{vtxt}; {diag}; fabric_mhz={fabric.get(round(mhz, 4), '')} "
                                      f"fclk0_ctrl={rec['fclk_ctrl']} run_cycles={res['run_cycles']} "
                                      f"wall_s={res['wall_s']} wns_whs_from_sta_at={wns_at}")})
        multi = len(ports) > 1 or any(cfg["ports"][str(p)]["dir"] == "rw" for p in ports)
        if multi:
            ddrs = "+".join(str(x) for x in sorted({DDRC_PORT[p] for p in ports}, reverse=True))
            c0 = cfg["ports"][str(ports[0])]
            verdict = "data ok" if not integ else "INTEGRITY FAIL: " + "; ".join(integ)
            dirs = [dd for dd in ("rd", "wr") if any(cfg["ports"][str(p)]["dir"] in (dd, "rw") for p in ports)]
            if len(dirs) == 2:
                dirs.append("rw")
            for direction in dirs:
                beats = agg["rd"] + agg["wr"] if direction == "rw" else agg[direction]
                bpc = beats * 8 / max(window, 1)
                out.append({**base, "fclk_core_mhz": f"{mhz:.4f}", "fclk_mem_mhz": f"{mhz:.4f}",
                            "n_hp_ports": str(len(ports)),
                            "outstanding": str(c0["k_rd"] if direction == "rd" else c0["k_wr"]),
                            "burst_bytes": str(8 * c0["len"]), "direction": direction,
                            "bytes_moved": str(beats * 8), "cycles": str(window),
                            "bytes_per_cycle": f"{bpc:.4f}", "mb_per_s": f"{bpc * mhz:.1f}",
                            "burst_beats": str(c0["len"]), "hp_port_set": hp(ports),
                            "ddr_port_set": ddrs, "scope": "aggregate",
                            "notes": (f"axiceil {cfg['id']} rep{rec['rep']} aggregate of {hp(ports)} "
                                      f"in one shared window; {verdict}")})
    return out


def pass_rows(rec, md5, build, infos, qos_summary, fabric):
    """A burst-count-bounded pass: one write row and one read-back row.  Not windowed: cycles are the
    run's own (start to drained), so B/cycle includes the start and drain latency."""
    mhz = rec["fclk_mhz"]
    if build and mhz not in infos:
        infos[mhz] = build_info(build, mhz)
    info = dict(infos.get(mhz, {}))
    wns_at = info.pop("wns_at", "")
    cfg = rec["cfg"]
    p = str(cfg["port"])
    ts = wall(rec["t"])
    rows = []
    for direction, res, k in (("wr", rec["write"], cfg["k"]), ("rd", rec["verify"], cfg.get("verify_k", 1))):
        d = res["ports"][p]
        beats = d["b_beats_tot"] if direction == "wr" else d["rd_beats_tot"]
        cyc = max(res["run_cycles"], 1)
        bpc = beats * 8 / cyc
        rows.append({"timestamp": ts, "bitstream_md5": md5, "soc_magic": MAGIC, "config": CONFIG,
                     "level": "DRAM", "source": "silicon", "working_set_bytes": str(cfg["words"] * 8),
                     "hpr_state": hpr_state(qos_summary), "ddrqos_hash": rec.get("qos_hash", ""), **info,
                     "fclk_core_mhz": f"{mhz:.4f}", "fclk_mem_mhz": f"{mhz:.4f}", "n_hp_ports": "1",
                     "outstanding": str(k), "burst_bytes": str(8 * cfg["len"]), "direction": direction,
                     "bytes_moved": str(beats * 8), "cycles": str(cyc), "bytes_per_cycle": f"{bpc:.4f}",
                     "mb_per_s": f"{bpc * mhz:.1f}", "burst_beats": str(cfg["len"]),
                     "hp_port_set": f"HP{p}", "ddr_port_set": str(DDRC_PORT[int(p)]), "scope": f"port:HP{p}",
                     "notes": (f"axiceil PASS {cfg['id']} ({'write' if direction == 'wr' else 'read-back of that write'}); "
                               f"burst-count bounded, not windowed: cycles run from start to drained; data ok "
                               f"(pins balanced, 0 errors, beat count as expected -- the runner stops otherwise); "
                               f"pins aw={d['pin_aw']} b={d['pin_b']} ar={d['pin_ar']} rlast={d['pin_rlast']}; "
                               f"fabric_mhz={fabric.get(round(mhz, 4), '')} fclk0_ctrl={rec['fclk_ctrl']} "
                               f"wall_s={res['wall_s']} wns_whs_from_sta_at={wns_at} "
                               f"board_clock_offset_s={CLOCK_OFFSET:.0f}")})
    return rows


def append_rows(rows):
    with open(CSV_PATH, newline="") as fh:
        text = fh.read()
    first, rest = text.split("\n", 1)
    header = next(csv.reader([first.rstrip("\r")]))
    missing = [c for c in NEW_COLS if c not in header]
    if missing:
        header = header + missing
        tmp = CSV_PATH + ".tmp"
        with open(tmp, "w", newline="") as fh:
            fh.write(",".join(header) + ("\r\n" if first.endswith("\r") else "\n") + rest)
        os.replace(tmp, CSV_PATH)
        print(f"results.csv: appended columns {missing}", file=sys.stderr)
    with open(CSV_PATH, "a", newline="") as fh:
        wr = csv.DictWriter(fh, fieldnames=header, extrasaction="raise", lineterminator="\n")
        for r in rows:
            wr.writerow({k: r.get(k, "") for k in header})
    print(f"results.csv: +{len(rows)} rows", file=sys.stderr)


def table(path):
    for rec in records(path):
        if rec["kind"] == "clock":
            print(f"# clock: SLCR {rec['slcr']['fclk0']['mhz']} MHz ({rec['slcr']['fclk0']['ctrl']}), "
                  f"fabric counts {rec['fabric_mhz']} MHz")
        elif rec["kind"] == "ddrc_afi":
            print(f"# ddrc/afi {rec['when']}: {rec['summary']}")
        elif rec["kind"] == "prep":
            print(f"# prep HP{rec['port']}: ok={rec['ok']}")
        elif rec["kind"] in ("PS_HOLDS", "MASTER_STALLED_PS_IDLE", "TIMEOUT_DRAINED", "stopped"):
            print(f"# {rec['kind']}: " + json.dumps({k: v for k, v in rec.items() if k not in ('kind', 't')}))
        elif rec["kind"] == "dump":
            print(f"# dump ({rec['why']}): status {rec['status']} ps_holds {rec['ps_holds']}")
    for r in rows_from(path, "-", None):
        print(f"{r['notes'].split()[1]:32s} {r['scope']:10s} {r['hp_port_set']:16s} {r['direction']} "
              f"L{r['burst_beats']:>2} k{r['outstanding']:>2} @{float(r['fclk_core_mhz']):8.4f} "
              f"{r['bytes_per_cycle']:>8} B/cyc {r['mb_per_s']:>7} MB/s  "
              f"{'ok' if 'data ok' in r['notes'] else 'FAIL'}")


def points(paths):
    """Every measured point in the given JSONL files, flattened: one dict per (point, rep)."""
    out = []
    for path in paths:
        for rec in records(path):
            if rec["kind"] != "point":
                continue
            cfg, res = rec["cfg"], rec["result"]
            w = max(res["window"], 1)
            mhz = rec["fclk_mhz"]
            ports = sorted(int(p) for p in cfg["ports"])
            pt = {"id": cfg["id"], "rep": rec["rep"], "mhz": mhz, "ports": ports, "window": w,
                  "file": os.path.basename(path), "ok": True, "per": {}}
            for p in ports:
                c, d = cfg["ports"][str(p)], res["ports"][str(p)]
                v = rec["verify"].get(str(p))
                bad = (d["rd_err"] or d["rd_proto"] or d["wr_err"] or d["wr_proto"] or d["pstat"] & 0x5C
                       or res["timed_out"] or (c["dir"] in ("wr", "rw") and (v is None or v["rd_err"]
                                                                           or v["rd_beats"] != v["words"])))
                pt["ok"] &= not bad
                rb, wb = d["rd_beats_win"], d["wr_beats_win"]
                pt["per"][p] = {
                    "dir": c["dir"], "L": c["len"], "k_rd": c["k_rd"], "k_wr": c["k_wr"],
                    "rd_bpc": rb * 8 / w, "wr_bpc": wb * 8 / w,
                    "rd_mbs": rb * 8 / w * mhz, "wr_mbs": wb * 8 / w * mhz,
                    "rd_cyc_per_burst": (w / (rb / c["len"])) if rb else None,
                    "wr_cyc_per_burst": (w / (wb / c["len"])) if wb else None,
                    "ar_stall": d["ar_stall_win"] / w, "aw_stall": d["aw_stall_win"] / w,
                    "w_stall": d["w_stall_win"] / w, "r_gap": d["r_gap_win"] / w, "w_idle": d["w_idle_win"] / w,
                    "out_rd": d["rd_out_sum"] / w, "out_wr": d["wr_out_sum"] / w,
                    "racount": d["racount_sum"] / w, "rcount": d["rcount_sum"] / w,
                    "wacount": d["wacount_sum"] / w, "wcount": d["wcount_sum"] / w,
                    "peak_rd": d["peak_out"] & 0xFF, "peak_wr": (d["peak_out"] >> 8) & 0xFF,
                    "fifo_max": d["fifo_max"], "b_bpc": d["b_beats_win"] * 8 / w}
            out.append(pt)
    return out


def _stats(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None, None, None, 0
    return sum(vals) / len(vals), min(vals), max(vals), len(vals)


def report(paths):
    """Markdown tables for MEMORY_BANDWIDTH.md s7: mean over reps (min-max), per point id."""
    pts = points(paths)
    by = {}
    for pt in pts:
        by.setdefault((pt["id"], pt["mhz"]), []).append(pt)
    print("| point | MHz | ports | dir | L | k | n | ok | per-port MB/s (mean, min-max) | aggregate MB/s | B/cycle per port | cyc/burst | r_gap | ar_stall | out_rd | RACOUNT | RCOUNT | w_stall | w_idle | out_wr | WACOUNT | WCOUNT |")
    print("|---|---:|---|---|---:|---:|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for (pid, mhz), group in by.items():
        ports = group[0]["ports"]
        for direction in ("rd", "wr"):
            if not any(pt["per"][p]["dir"] in (direction, "rw") for pt in group for p in ports):
                continue
            per_mbs, agg, bpc, cpb, diag = [], [], [], [], {}
            for pt in group:
                a = 0
                for p in ports:
                    q = pt["per"][p]
                    if q["dir"] not in (direction, "rw"):
                        continue
                    per_mbs.append(q[direction + "_mbs"]); bpc.append(q[direction + "_bpc"])
                    cpb.append(q[direction + "_cyc_per_burst"]); a += q[direction + "_mbs"]
                    keys = (("r_gap", "ar_stall", "out_rd", "racount", "rcount") if direction == "rd"
                            else ("w_stall", "w_idle", "out_wr", "wacount", "wcount"))
                    for kk in keys:
                        diag.setdefault(kk, []).append(q[kk])
                agg.append(a)
            m, lo, hi, n = _stats(per_mbs)
            am, alo, ahi, _ = _stats(agg)
            bm = _stats(bpc)[0]; cm = _stats(cpb)[0]
            q0 = group[0]["per"][ports[0]]
            k = q0["k_rd"] if direction == "rd" else q0["k_wr"]
            ok = all(pt["ok"] for pt in group)
            dcols = []
            for kk in ("r_gap", "ar_stall", "out_rd", "racount", "rcount", "w_stall", "w_idle", "out_wr", "wacount", "wcount"):
                dcols.append(f"{_stats(diag[kk])[0]:.3f}" if kk in diag else "")
            print(f"| {pid} | {mhz:.4f} | {hp(ports)} | {direction}{' (mixed)' if q0['dir'] == 'rw' else ''} | {q0['L']} | {k} | {len(group)} | "
                  f"{'ok' if ok else 'FAIL'} | {m:.1f} ({lo:.1f}-{hi:.1f}) | {am:.1f} ({alo:.1f}-{ahi:.1f}) | {bm:.4f} | "
                  f"{(f'{cm:.2f}' if cm else '')} | " + " | ".join(dcols) + " |")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a1 = sub.add_parser("plan"); a1.add_argument("name"); a1.add_argument("--fmax", type=float, required=True)
    a2 = sub.add_parser("rows"); a2.add_argument("jsonl"); a2.add_argument("--md5", required=True)
    a2.add_argument("--build", required=True); a2.add_argument("--dry-run", action="store_true")
    a2.add_argument("--clock-offset", type=float, default=None,
                    help="workstation epoch minus board epoch, seconds (required: the board's clock is wrong)")
    a3 = sub.add_parser("table"); a3.add_argument("jsonl")
    a4 = sub.add_parser("report"); a4.add_argument("jsonl", nargs="+")
    a = ap.parse_args()
    if a.cmd == "plan":
        print(json.dumps(plans(a.name, a.fmax), indent=1))
    elif a.cmd == "rows":
        global CLOCK_OFFSET
        if a.clock_offset is None:
            sys.exit("rows: --clock-offset is required (workstation epoch - board epoch)")
        CLOCK_OFFSET = a.clock_offset
        rows = rows_from(a.jsonl, a.md5, a.build)
        if a.dry_run:
            w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0].keys()) if rows else [])
            w.writeheader(); w.writerows(rows)
        else:
            append_rows(rows)
    elif a.cmd == "report":
        report(a.jsonl)
    else:
        table(a.jsonl)


if __name__ == "__main__":
    main()
