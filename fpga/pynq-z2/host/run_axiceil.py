#!/usr/bin/env python3
"""Drive the interface-ceiling instrument (MAGIC 0x5A5A0020) through a plan of points.

    sudo python3 run_axiceil.py --bitstream axiceil.bit --plan plan.json > out.jsonl
    sudo python3 run_axiceil.py --no-load --plan plan.json > out.jsonl

MEMORY_BANDWIDTH.md section 7.  Run it through scripts/47_axiceil_lab.sh, which writes the plan,
copies this file, fclk.py, ddrc_afi.py and zynq_preflight.py to the board, and turns the JSON
lines this prints into rows of fpga/pynq-z2/bwlab/results.csv.

AFTER 2026-09-16 (docs/BOARD_FINDINGS.md, "An un-drained HP master wedges S_AXI_HP0").  Build 1's
first transfer never completed, abort did not drain it, and S_AXI_HP0 stayed wedged for every
later bitstream until the watchdog reset the PS.  This runner was rewritten around the question
it could not answer then: does the PS still hold transactions?  Builds >= v5 count handshakes at
the PS pins -- AW, W with WLAST, B, AR, R with RLAST -- and never clear them on start.  AW - B and
AR - RLAST are what the PS holds, whatever the master believes.  So:
  * any stop that is not a clean finish dumps every counter, the pins and the live state, aborts,
    dumps again, and classifies itself: PS_HOLDS (nothing further is touched: no reset, no clock,
    no point) or MASTER_STALLED_PS_IDLE / TIMEOUT_DRAINED (the plan still stops);
  * the pins must balance before a point starts, after it ends, and before any clock change;
  * FCLK0 changes only when a point asks for a different clock; "fclk_mhz": "keep" runs at what
    the board has, if this build closes there;
  * a plan runs in order and stops at its first anomaly: a timeout, a data or protocol error, a
    guard or configuration fault, a beat-count mismatch, or unbalanced pins.

WHAT EVERY RECORD CARRIES: FCLK0 read back from the SLCR (host/fclk.py) and counted by the fabric
over a host-timed second (they must agree within 1 %); the DDRC/AFI configuration read back by
host/ddrc_afi.py before and after (AFI offsets 0x0C/0x10/0x20/0x24 are never read); and the
kernel's memory map (nothing is written unless System RAM ends below 0x1000_0000).

READ REGION OF ANOTHER PORT.  A window point's port entry may carry "rd_region": q, and that port
then reads port q's prepared read region under q's seed (q must be in the same point and read).  Two
HP ports then read the same DDR rows at the same time, as the bypass's lanes do.

POINT TYPES
  "pass"    write a region in one direction, bounded by a burst count, then read it back: the
            ladder's steps.  Fields: port, len, k, words (whole 4 KiB pages), verify_k
  "window"  a measurement window over any ports and directions; reads need a prepared region
"""
import argparse
import json
import mmap
import os
import random
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zynq_preflight import preflight  # noqa: E402
import fclk as fclk_mod  # noqa: E402
import ddrc_afi  # noqa: E402

sys.stdout.reconfigure(line_buffering=True)

GP0 = 0x4000_0000
MAGIC_WANT = 0x5A5A_0020
MIN_VERSION = 5                 # pin counters, W after AW at the pins, 4 KiB pages
REGION_LO, REGION_HI = 0x1000_0000, 0x2000_0000
SLCR = 0xF800_0000
SLCR_UNLOCK, UNLOCK_KEY, FPGA_RST_CTRL = 0x008, 0xDF0D, 0x240
MAXB_ALL = 0x7FFF_FFFF
PAGE_WORDS = 512

CTRL, MAGIC, STATUS, RUNS, PORT_EN, WINDOW = 0x000, 0x004, 0x008, 0x00C, 0x010, 0x014
RUN_CYC, FREERUN, BUILD, RLO, RHI, WIN_EL = 0x018, 0x020, 0x028, 0x02C, 0x030, 0x034
MODE, RDB, RDW, WRB, WRW, RDS, WRS, RDM, WRM = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20
PSTAT = 0x40
STAT40 = {"rd_beats_win": 0x44, "wr_beats_win": 0x4C, "b_beats_win": 0x54, "rd_beats_tot": 0x5C,
          "b_beats_tot": 0x64, "rd_out_sum": 0x98, "wr_out_sum": 0xA0, "racount_sum": 0xAC,
          "rcount_sum": 0xB4, "wacount_sum": 0xBC, "wcount_sum": 0xC4}
STAT32 = {"rd_err": 0x6C, "rd_proto": 0x70, "wr_err": 0x74, "wr_proto": 0x78, "rd_bursts": 0x7C,
          "wr_bursts": 0x80, "ar_stall_win": 0x84, "aw_stall_win": 0x88, "w_stall_win": 0x8C,
          "r_gap_win": 0x90, "w_idle_win": 0x94, "peak_out": 0xA8, "fifo_max": 0xCC,
          "drain_cycles": 0xD0, "guard_addr": 0xD4}
PINS = {"pin_aw": 0xD8, "pin_wlast": 0xDC, "pin_b": 0xE0, "pin_ar": 0xE4, "pin_rlast": 0xE8}
LIVE = {"live_busy": 0xEC, "live": 0xF0, "live_pins": 0xF4}
# Build 5 (RTL v6) only: first non-OKAY BRESP/RRESP code and SLVERR/DECERR counts at the pins.
# Build 4 does not implement these offsets, so they are read only when this runner loaded a
# bitstream whose md5 is build 5's (never with --no-load).
RESP_MD5 = "15187f82890dd05f3428ff467ae5039b"
RESP = {"resp_first": 0xF8, "resp_counts": 0xFC}
READ_RESP = False


def decode_resp(first, counts):
    code = {0: "OKAY", 1: "EXOKAY", 2: "SLVERR", 3: "DECERR"}
    return {"first_bresp": code[(first >> 11) & 3] if (first >> 13) & 1 else None,
            "first_rresp": code[(first >> 5) & 3] if (first >> 7) & 1 else None,
            "b_slverr": (counts >> 24) & 0xFF, "b_decerr": (counts >> 16) & 0xFF,
            "r_slverr": (counts >> 8) & 0xFF, "r_decerr": counts & 0xFF}

REGION_BYTES = 32 * 1024 * 1024
def rd_base(p): return REGION_LO + p * 0x0400_0000
def wr_base(p): return REGION_LO + p * 0x0400_0000 + 0x0200_0000


def emit(kind, **kw):
    print(json.dumps({"kind": kind, "t": time.time(), **kw}, separators=(",", ":")))


class Stop(Exception):
    pass


class Regs:
    def __init__(self):
        self.f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.m = mmap.mmap(self.f, 0x1000, offset=GP0)

    def rd(self, off):
        return struct.unpack("<I", self.m[off:off + 4])[0]

    def wr(self, off, v):
        self.m[off:off + 4] = struct.pack("<I", v & 0xFFFF_FFFF)

    def rd40(self, off):
        return self.rd(off) | (self.rd(off + 4) << 32)

    def close(self):
        self.m.close(); os.close(self.f)


def P(p, off):
    return 0x100 * (p + 1) + off


def bursts_per_page(L):
    return PAGE_WORDS // L


def check_kernel_memory():
    cmdline = open("/proc/cmdline").read()
    top = 0
    for line in open("/proc/iomem"):
        if "System RAM" in line and not line.startswith(" "):
            lo, hi = line.split(":")[0].strip().split("-")
            top = max(top, int(hi, 16))
    emit("kernel", cmdline=cmdline.strip(), system_ram_top=f"0x{top:08X}")
    if top >= REGION_LO:
        sys.exit(f"/proc/iomem: System RAM reaches 0x{top:08X}, inside the PL's window: refusing")


def pins(r, p):
    return {k: r.rd(P(p, off)) for k, off in PINS.items()}


def ps_holds(r, ports=(0, 1, 2, 3)):
    """What the PS holds per port, from the pins: {p: (writes, reads, AWs whose WLAST has not crossed)}."""
    out = {}
    for p in ports:
        c = pins(r, p)
        out[p] = ((c["pin_aw"] - c["pin_b"]) & 0xFFFF_FFFF,
                  (c["pin_ar"] - c["pin_rlast"]) & 0xFFFF_FFFF,
                  (c["pin_aw"] - c["pin_wlast"]) & 0xFFFF_FFFF)
    return out


def unbalanced(r):
    return {p: v for p, v in ps_holds(r).items() if any(v)}


def dump(r, ports, why):
    d = {"status": f"0x{r.rd(STATUS):08X}", "runs": r.rd(RUNS), "run_cycles": r.rd40(RUN_CYC), "ports": {}}
    for p in ports:
        q = {"pstat": f"0x{r.rd(P(p, PSTAT)):08X}"}
        for k, off in STAT40.items():
            q[k] = r.rd40(P(p, off))
        for k, off in STAT32.items():
            q[k] = r.rd(P(p, off))
        q.update(pins(r, p))
        for k, off in LIVE.items():
            q[k] = f"0x{r.rd(P(p, off)):08X}"
        if READ_RESP:
            q.update(decode_resp(r.rd(P(p, RESP["resp_first"])), r.rd(P(p, RESP["resp_counts"]))))
        d["ports"][p] = q
    d["ps_holds"] = {p: {"writes": w, "reads": rr, "aw_without_wlast": ws}
                     for p, (w, rr, ws) in ps_holds(r, ports).items()}
    emit("dump", why=why, **d)
    return d


def fabric_clock(r, seconds=1.0):
    t0 = time.monotonic(); c0 = r.rd40(FREERUN)
    time.sleep(seconds)
    t1 = time.monotonic(); c1 = r.rd40(FREERUN)
    return (c1 - c0) / (t1 - t0) / 1e6


def set_fclk0(mhz):
    """Change FCLK0 with the PL held in reset; return the SLCR readback."""
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 0x1000, offset=SLCR)
    rd = lambda o: struct.unpack("<I", m[o:o + 4])[0]
    wr = lambda o, v: m.__setitem__(slice(o, o + 4), struct.pack("<I", v))
    try:
        wr(SLCR_UNLOCK, UNLOCK_KEY)
        wr(FPGA_RST_CTRL, rd(FPGA_RST_CTRL) | 0x1)
        time.sleep(0.05)
        if not rd(FPGA_RST_CTRL) & 0x1:
            raise Stop("FPGA_RST_CTRL did not take (SLCR locked?): not changing FCLK0 under a live PL")
        from pynq.ps import Clocks
        Clocks.fclk0_mhz = float(mhz)
        time.sleep(0.05)
        clocks = fclk_mod.read_fclks()
        got = clocks["fclk0"]["mhz"]
        if got is None or abs(got - mhz) > mhz * 0.005:
            raise Stop(f"FCLK0 reads {got} MHz after asking for {mhz} (PL left in reset)")
        wr(FPGA_RST_CTRL, rd(FPGA_RST_CTRL) & ~0x1)
        time.sleep(0.1)
        return clocks
    finally:
        m.close(); os.close(fd)


def wait_idle(r, timeout):
    t0 = time.monotonic()
    while True:
        st = r.rd(STATUS)
        if st & 0xF == 0:
            return st
        if time.monotonic() - t0 > timeout:
            return st | 0x8000_0000
        time.sleep(0.02)


def configure(r, p, rd=False, wr=False, length=8, k_rd=1, k_wr=1, rdb=None, rdw=None,
              wrb=None, wrw=None, rds=0, wrs=0, rdm=0, wrm=0):
    rdb = rd_base(p) if rdb is None else rdb
    wrb = wr_base(p) if wrb is None else wrb
    rdw = REGION_BYTES // 8 if rdw is None else rdw
    wrw = REGION_BYTES // 8 if wrw is None else wrw
    for base, words in ((rdb, rdw), (wrb, wrw)):
        if not (REGION_LO <= base and base + 8 * words <= REGION_HI and base % 4096 == 0
                and words % PAGE_WORDS == 0 and words > 0):
            raise Stop(f"region 0x{base:08X}+{words} words is not whole 4 KiB pages inside the PL's window")
    if not (1 <= length <= 16 and 1 <= k_rd <= 16 and 1 <= k_wr <= 16):
        raise Stop(f"bad shape L={length} k_rd={k_rd} k_wr={k_wr}")
    mode = int(rd) | (int(wr) << 1) | ((length - 1) << 4) | (k_rd << 8) | (k_wr << 16)
    for off, v in ((MODE, mode), (RDB, rdb), (RDW, rdw), (WRB, wrb), (WRW, wrw), (RDS, rds),
                   (WRS, wrs), (RDM, rdm), (WRM, wrm)):
        r.wr(P(p, off), v)
        if r.rd(P(p, off)) != v & 0xFFFF_FFFF:
            raise Stop(f"port {p} register +0x{off:02X} did not take 0x{v:08X}")


def run(r, ports, window, timeout, label):
    """Start, wait, return every counter.  Any stop that is not a clean finish raises Stop."""
    if r.rd(STATUS) & 0xF:
        raise Stop(f"{label}: instrument busy before start")
    if unbalanced(r):
        dump(r, ports, f"{label}: pins unbalanced before start")
        raise Stop(f"{label}: PS pins unbalanced before start")
    runs0 = r.rd(RUNS)
    r.wr(PORT_EN, sum(1 << p for p in ports))
    r.wr(WINDOW, window)
    t0 = time.monotonic()
    r.wr(CTRL, 1)
    st = wait_idle(r, timeout)
    wall = time.monotonic() - t0
    if st & 0x8000_0000:
        dump(r, ports, f"{label}: timeout after {timeout:.0f} s")
        r.wr(CTRL, 2)                                   # abort: stop issuing, drain
        st2 = wait_idle(r, 30)
        dump(r, ports, f"{label}: 30 s after abort")
        r.wr(CTRL, 0)
        holds = unbalanced(r)
        if holds:
            emit("PS_HOLDS", label=label, holds=holds, drained=not (st2 & 0x8000_0000))
            raise Stop(f"{label}: the PS holds transactions {holds}; touching nothing further")
        emit("MASTER_STALLED_PS_IDLE" if st2 & 0x8000_0000 else "TIMEOUT_DRAINED", label=label)
        raise Stop(f"{label}: timed out (the pins say the PS holds nothing)")
    res = {"status": f"0x{st:08X}", "runs_delta": r.rd(RUNS) - runs0, "window": r.rd(WINDOW),
           "win_elapsed": r.rd(WIN_EL), "run_cycles": r.rd40(RUN_CYC), "wall_s": round(wall, 4),
           "timed_out": False, "ports": {}}
    for p in ports:
        d = {"pstat": r.rd(P(p, PSTAT))}
        for k, off in STAT40.items():
            d[k] = r.rd40(P(p, off))
        for k, off in STAT32.items():
            d[k] = r.rd(P(p, off))
        d.update(pins(r, p))
        if READ_RESP:
            d.update(decode_resp(r.rd(P(p, RESP["resp_first"])), r.rd(P(p, RESP["resp_counts"]))))
        res["ports"][p] = d
    holds = unbalanced(r)
    if holds:
        dump(r, ports, f"{label}: finished with pins unbalanced")
        raise Stop(f"{label}: finished with the PS pins unbalanced {holds}")
    for p, d in res["ports"].items():
        bad = [(k, d[k]) for k in ("rd_err", "rd_proto", "wr_err", "wr_proto") if d[k]]
        if bad or d["pstat"] & 0x5C:
            dump(r, ports, f"{label}: errors")
            raise Stop(f"{label}: port {p} errors {bad} pstat 0x{d['pstat']:X}")
    return res


def transfer(r, p, direction, L, k, base, words, seed, nbursts, label, timeout=120):
    """One direction, bounded by a burst count; checks the beat count."""
    if direction == "wr":
        configure(r, p, wr=True, length=L, k_wr=k, wrb=base, wrw=words, wrs=seed, wrm=nbursts)
    else:
        configure(r, p, rd=True, length=L, k_rd=k, rdb=base, rdw=words, rds=seed, rdm=nbursts)
    res = run(r, [p], MAXB_ALL, timeout, label)
    d = res["ports"][p]
    got = d["b_beats_tot"] if direction == "wr" else d["rd_beats_tot"]
    if got != nbursts * L:
        dump(r, [p], f"{label}: beat count")
        raise Stop(f"{label}: {got} beats, expected {nbursts * L}")
    return res


def attach(want, fmax, r, clocks):
    """Make FCLK0 what the point needs and (re)attach to the instrument.  Returns (r, clocks, mhz)."""
    now_clocks = fclk_mod.read_fclks()
    now_mhz = now_clocks["fclk0"]["mhz"]
    target = now_mhz if want == "keep" else float(want)
    if target is None or target > fmax * 1.001:
        raise Stop(f"FCLK0 {target} MHz is above this build's closure ({fmax} MHz)")
    change = abs(target - now_mhz) > target * 0.005
    if r is not None and not change:
        return r, clocks, clocks["fclk0"]["mhz"]
    if r is not None:
        if wait_idle(r, 30) & 0x8000_0000:
            raise Stop("instrument not idle; not changing the clock")
        if unbalanced(r):
            dump(r, [0, 1, 2, 3], "before a clock change")
            raise Stop(f"PS holds {unbalanced(r)}; not changing the clock")
        r.close()
    clocks = set_fclk0(target) if change else now_clocks
    preflight()
    r = Regs()
    magic, build = r.rd(MAGIC), r.rd(BUILD)
    if magic != MAGIC_WANT or ((build >> 8) & 0xFF) < MIN_VERSION:
        raise Stop(f"MAGIC 0x{magic:08X} BUILD 0x{build:08X}: not an instrument build >= v{MIN_VERSION}")
    if (r.rd(RLO), r.rd(RHI)) != (REGION_LO, REGION_HI):
        raise Stop("the bitstream's region bounds differ from this runner's")
    if unbalanced(r):
        dump(r, [0, 1, 2, 3], "at attach")
        raise Stop(f"PS pins unbalanced at attach: {unbalanced(r)}")
    fab = fabric_clock(r)
    slcr = clocks["fclk0"]["mhz"]
    emit("clock", fclk_request=want, changed=change, slcr=clocks, fabric_mhz=round(fab, 4),
         build=f"0x{build:08X}")
    if abs(fab - slcr) > slcr * 0.01:
        raise Stop(f"fabric counts {fab:.4f} MHz, SLCR says {slcr}")
    return r, clocks, slcr


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bitstream")
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--plan", required=True)
    a = ap.parse_args()
    plan = json.load(open(a.plan))
    fmax = float(plan["fmax_mhz"])
    region_words = plan.get("region_words", REGION_BYTES // 8)
    global READ_RESP
    if not a.no_load:
        import hashlib
        md5 = hashlib.md5(open(a.bitstream, "rb").read()).hexdigest()
        READ_RESP = md5 == RESP_MD5
        from pynq import Bitstream
        Bitstream(os.path.abspath(a.bitstream)).download()
        emit("loaded", bitstream=a.bitstream, md5=md5, reads_resp_codes=READ_RESP)

    check_kernel_memory()
    qos0 = ddrc_afi.dump()
    emit("ddrc_afi", when="before", summary=ddrc_afi.summary(qos0), qos_hash=qos0["qos_hash"],
         cfg_hash=qos0["cfg_hash"], dump=qos0)

    session_seed = random.getrandbits(32) | 1
    prepared = {}
    r, clocks, mhz = None, None, None
    try:
        for pt in plan["points"]:
            prev = mhz
            r, clocks, mhz = attach(pt.get("fclk_mhz", "keep"), fmax, r, clocks)
            if mhz != prev:
                prepared = {}

            if pt.get("type", "window") == "pass":
                p, L, k, words = pt["port"], pt["len"], pt["k"], pt["words"]
                nb = (words // PAGE_WORDS) * bursts_per_page(L)
                seed = random.getrandbits(32)
                w = transfer(r, p, "wr", L, k, rd_base(p), words, seed, nb, f"{pt['id']} write")
                v = transfer(r, p, "rd", L, pt.get("verify_k", 1), rd_base(p), words, seed, nb,
                             f"{pt['id']} read-back")
                emit("pass", id=pt["id"], fclk_mhz=mhz, fclk_ctrl=clocks["fclk0"]["ctrl"], cfg=pt,
                     words=nb * L, write=w, verify=v, qos_hash=qos0["qos_hash"])
                continue

            ports = [int(p) for p in pt["ports"]]
            region_of = {p: int(pt["ports"][str(p)].get("rd_region", p)) for p in ports}
            for p in ports:
                q = region_of[p]
                if q != p and (q not in ports or pt["ports"][str(q)]["dir"] not in ("rd", "rw")):
                    raise Stop(f"{pt['id']}: HP{p} reads HP{q}'s region, which this point does not also read")
            for p in ports:
                if pt["ports"][str(p)]["dir"] in ("rd", "rw") and region_of[p] == p and p not in prepared:
                    prep = pt.get("prep", {"len": 8, "k": 1})
                    seed = session_seed ^ (p * 0x9E37_79B9 & 0xFFFF_FFFF)
                    nb = (region_words // PAGE_WORDS) * bursts_per_page(prep["len"])
                    w = transfer(r, p, "wr", prep["len"], prep["k"], rd_base(p), region_words, seed, nb,
                                 f"prep HP{p} write")
                    v = transfer(r, p, "rd", prep["len"], prep["k"], rd_base(p), region_words, seed, nb,
                                 f"prep HP{p} read-back")
                    emit("prep", port=p, seed=f"0x{seed:08X}", words=nb * prep["len"], ok=True, write=w, verify=v)
                    prepared[p] = seed
            window = pt.get("window") or int(round(pt.get("window_s", 0.5) * mhz * 1e6))
            for rep in range(pt.get("repeat", 1)):
                wseeds = {}
                for p in ports:
                    c = pt["ports"][str(p)]
                    wseeds[p] = random.getrandbits(32)
                    q = region_of[p]
                    configure(r, p, rd=c["dir"] in ("rd", "rw"), wr=c["dir"] in ("wr", "rw"),
                              length=c["len"], k_rd=c["k_rd"], k_wr=c["k_wr"], rdb=rd_base(q), rdw=region_words,
                              wrw=region_words, rds=prepared.get(q, 0), wrs=wseeds[p])
                label = f"{pt['id']} rep {rep}"
                res = run(r, ports, window, window / (mhz * 1e6) * 3 + 20, label)
                verify = {}
                for p in ports:
                    c = pt["ports"][str(p)]
                    if c["dir"] in ("wr", "rw"):
                        L = c["len"]
                        nb = min(res["ports"][p]["wr_bursts"], (region_words // PAGE_WORDS) * bursts_per_page(L))
                        if nb:
                            v = transfer(r, p, "rd", L, 1, wr_base(p), region_words, wseeds[p], nb,
                                         f"{label} verify HP{p}")
                            verify[p] = {"words": nb * L, "rd_beats": v["ports"][p]["rd_beats_tot"],
                                         "rd_err": v["ports"][p]["rd_err"], "rd_proto": v["ports"][p]["rd_proto"]}
                emit("point", id=pt["id"], rep=rep, fclk_mhz=mhz, fclk_ctrl=clocks["fclk0"]["ctrl"],
                     cfg=pt, result=res, verify=verify, qos_hash=qos0["qos_hash"])
    except Stop as e:
        emit("stopped", reason=str(e))
        if r is not None:
            r.close()
        qos1 = ddrc_afi.dump()
        emit("ddrc_afi", when="after", summary=ddrc_afi.summary(qos1), qos_hash=qos1["qos_hash"],
             cfg_hash=qos1["cfg_hash"])
        sys.exit(f"stopped: {e}")

    if r is not None:
        r.close()
    qos1 = ddrc_afi.dump()
    emit("ddrc_afi", when="after", summary=ddrc_afi.summary(qos1), qos_hash=qos1["qos_hash"],
         cfg_hash=qos1["cfg_hash"])
    if qos1["qos_hash"] != qos0["qos_hash"]:
        sys.exit("DDR controller / AFI QoS readback changed during the plan")
    emit("done")


if __name__ == "__main__":
    main()
