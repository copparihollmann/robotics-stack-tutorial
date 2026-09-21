#!/usr/bin/env python3
"""Read the Zynq PS DDR controller's and the four AFIs' AS-RUN configuration. Never writes.

    sudo python3 ddrc_afi.py                      # on the board: JSON dump + decoded QoS + hashes
    sudo python3 ddrc_afi.py --summary            # one line, for a results.csv `notes` field
    python3 ddrc_afi.py --compare dump.json --ps7-init build/.../ps7_init.c
                                                  # on the workstation: as-run vs the preset

WHY THIS EXISTS.  The PS7 block in a Vivado project carries DDR controller QoS settings
(PCW_DDR_PORTn_HPR_ENABLE, PCW_DDR_HPRLPR_QUEUE_PARTITION, *_TO_CRITICAL_PRIORITY_LEVEL),
and they reach silicon only through ps7_init -- which the FSBL runs once at power-up.  On
PYNQ, loading a bitstream does not re-run it, and Linux is already living on that DDR.  So
the QoS in tcl/ps7_preset_pynqz1.tcl is what we ASKED for; the registers below are what
RUNS.  host/fclk.py exists because the same gap put a 100 MHz label on 21 rows measured at
142.8571 MHz (bwlab/errata.csv).  This is that tool for the DDR controller and the HP ports.

WHERE THE MAP COMES FROM.  Xilinx's own register database, the one UG585 Appendix B and the
XSDB register views are generated from:
  Vitis/2023.1/data/PS/7series/data/zynqconfig/2.0/ps7regs/sw_regs.xml   (offsets)
  Vitis/2023.1/data/PS/7series/data/zynqconfig/2.0/ps7regs/sw_param.xml  (fields)
  DDRC ("ps7_ddrc_*")  at 0xF800_6000
  AFI0..3 ("ps7_afiN_*") at 0xF800_8000, 0xF800_9000, 0xF800_A000, 0xF800_B000
The DDRC field names and bit ranges are cross-checked against the ps7_init.c Vivado
generates for our own preset, which spells out every field it writes.

WHAT IT DELIBERATELY DOES NOT READ.
  * AFI_RDDATAFIFO_LEVEL (+0x0C) and AFI_WRDATAFIFO_LEVEL (+0x20).  sw_regs.xml: "should
    only be read if a valid HP port clock is actively running. If no clock is running the
    APB access will hang."  A hung APB read is a hung CPU on this board -- no console, no
    ssh, a power cycle.  Whether an HP port is clocked depends on the bitstream, so these
    are never read here.
  * AFI_RDDEBUG / AFI_WRDEBUG (+0x10, +0x24): they report live FIFO state (in-flight
    commands, overflow) and the database does not say which clock they are on.  Same
    reasoning; the fabric-side S_AXI_HPn_RACOUNT/RCOUNT/WACOUNT/WCOUNT sidebands observe
    the same things with no risk, and the ceiling instrument records those instead.
  * Anything undocumented.  Every DDRC offset read is one ps7_init writes, plus the two
    documented read-only identification/status registers 0x054 and 0x200.

RUNTIME WRITES: NONE, AND WHY.  sw_param.xml's reg_ddrc_soft_rstb says: "Software changes
DRAM controller register values only when the controller is in the reset state, except for
bit fields that can be dymanically updated."  The fields it marks "Dynamic Bit Field" are
soft_rstb, powerdown_en, dis_auto_refresh, t_rfc_nom_x32, t_rfc_min, selfref_en,
refresh_update_level and deeppowerdown_en (plus PHY training selects).  NONE of the QoS
fields is among them: HPR_reg/LPR_reg/WR_reg (0x008-0x010), lpr_num_entries (0x060[6:1]),
go2critical (0x064) and the arbiter's per-port priorities and set_hpr_rd (0x208-0x224).
Resetting the controller Linux is running on is not an option.  So DDR QoS is not tunable
from a running PYNQ; changing it needs an FSBL (ps7_init) rebuild.
"""
import argparse
import hashlib
import json
import mmap
import os
import re
import struct
import sys

DDRC_BASE = 0xF8006000
AFI_BASE = {0: 0xF8008000, 1: 0xF8009000, 2: 0xF800A000, 3: 0xF800B000}
DEVCFG_MCTRL = 0xF8007080          # [31:28] PS_VERSION (ps7_init.c selects its tables by it)

# Every DDRC offset ps7_init.c (3_0 tables) writes -- all type="rw" in sw_regs.xml -- plus
# 0x054 mode_sts_reg (ro) and 0x200 reg_arb id (ro).
DDRC_OFFSETS = [
    0x000, 0x004, 0x008, 0x00C, 0x010, 0x014, 0x018, 0x01C, 0x020, 0x024, 0x028, 0x02C,
    0x030, 0x034, 0x038, 0x03C, 0x040, 0x044, 0x048, 0x050, 0x054, 0x058, 0x05C, 0x060,
    0x064, 0x068, 0x06C, 0x078, 0x07C, 0x0A4, 0x0A8, 0x0AC, 0x0B0, 0x0B4, 0x0B8, 0x0C4,
    0x0C8, 0x0DC, 0x0F0, 0x0F4, 0x114, 0x118, 0x11C, 0x120, 0x124, 0x12C, 0x130, 0x134,
    0x138, 0x140, 0x144, 0x148, 0x14C, 0x154, 0x158, 0x15C, 0x160, 0x168, 0x16C, 0x170,
    0x174, 0x17C, 0x180, 0x184, 0x188, 0x190, 0x194, 0x200, 0x204, 0x208, 0x20C, 0x210,
    0x214, 0x218, 0x21C, 0x220, 0x224, 0x2A8, 0x2AC, 0x2B0, 0x2B4,
]
# The registers that decide how the controller arbitrates and queues -- the QoS set.
DDRC_QOS_OFFSETS = [0x000, 0x008, 0x00C, 0x010, 0x060, 0x064, 0x204,
                    0x208, 0x20C, 0x210, 0x214, 0x218, 0x21C, 0x220, 0x224]
# Per AFI: RDCHAN_CTRL, RDCHAN_ISSUINGCAP, RDQOS, WRCHAN_CTRL, WRCHAN_ISSUINGCAP, WRQOS.
AFI_OFFSETS = [0x00, 0x04, 0x08, 0x14, 0x18, 0x1C]
# DDR controller AXI port n <- which masters (AMD Zynq-7000 SPA-UG tutorial, "Evaluating DDR
# Controller Settings": port 0 CPUs+ACP, port 1 central interconnect, port 2 HP2+HP3,
# port 3 HP0+HP1).
DDRC_PORT_MASTERS = {0: "CPUs/ACP", 1: "central interconnect (GP/DevC/...)",
                     2: "S_AXI_HP2 + S_AXI_HP3", 3: "S_AXI_HP0 + S_AXI_HP1"}


def f(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


def read_all():
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    try:
        def window(base, span=0x1000):
            return mmap.mmap(fd, span, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)

        def rd(m, off):
            return struct.unpack("<I", m[off:off + 4])[0]

        m = window(DDRC_BASE)
        ddrc = {off: rd(m, off) for off in DDRC_OFFSETS}
        m.close()
        afi = {}
        for n, base in AFI_BASE.items():
            m = window(base)
            afi[n] = {off: rd(m, off) for off in AFI_OFFSETS}
            m.close()
        m = window(DEVCFG_MCTRL & ~0xFFF)
        mctrl = rd(m, DEVCFG_MCTRL & 0xFFF)
        m.close()
        return ddrc, afi, mctrl
    finally:
        os.close(fd)


def decode_ddrc(r):
    d = {}
    c = r[0x000]
    d["ddrc_ctrl"] = {"soft_rstb": f(c, 0, 0), "powerdown_en": f(c, 1, 1),
                      "data_bus_width": {0: "32-bit", 1: "16-bit"}.get(f(c, 3, 2), "reserved"),
                      "burst8_refresh": f(c, 6, 4), "rdwr_idle_gap": f(c, 13, 7),
                      "dis_rd_bypass": f(c, 14, 14), "dis_act_bypass": f(c, 15, 15),
                      "dis_auto_refresh": f(c, 16, 16)}
    for name, off in (("hpr", 0x008), ("lpr", 0x00C)):
        v = r[off]
        d[f"{name}_reg"] = {"xact_run_length": f(v, 25, 22), "max_starve_x32": f(v, 21, 11),
                            "min_non_critical_x32": f(v, 10, 0)}
    v = r[0x010]   # NB: WR_reg's layout differs from HPR/LPR's (sw_param.xml, ps7_init.c)
    d["wr_reg"] = {"xact_run_length": f(v, 14, 11), "max_starve_x32": f(v, 25, 15),
                   "min_non_critical_x32": f(v, 10, 0)}
    v = r[0x060]
    d["ctrl_reg1"] = {"pageclose": f(v, 0, 0), "lpr_num_entries_field": f(v, 6, 1),
                      "auto_pre_en": f(v, 7, 7), "dis_wc": f(v, 9, 9),
                      "dis_collision_page_opt": f(v, 10, 10), "selfref_en": f(v, 12, 12)}
    v = r[0x064]
    d["ctrl_reg2"] = {"go2critical_hysteresis": f(v, 12, 5), "go2critical_en": f(v, 17, 17)}
    d["burst_rdwr"] = {2: 4, 4: 8, 8: 16}.get(f(r[0x034], 3, 0), f"reserved({f(r[0x034], 3, 0)})")
    d["page_addr_mask"] = f"0x{r[0x204]:08X}"
    ports = {}
    for n in range(4):
        w, rr = r[0x208 + 4 * n], r[0x218 + 4 * n]
        ports[n] = {"masters": DDRC_PORT_MASTERS[n],
                    "wr": {"pri": f(w, 9, 0), "disable_aging": f(w, 16, 16),
                           "disable_urgent": f(w, 17, 17), "dis_page_match": f(w, 18, 18)},
                    "rd": {"pri": f(rr, 9, 0), "disable_aging": f(rr, 16, 16),
                           "disable_urgent": f(rr, 17, 17), "dis_page_match": f(rr, 18, 18),
                           "set_hpr": f(rr, 19, 19)}}
    d["ports"] = ports
    ms = r[0x054]
    d["mode_sts_reg"] = {"raw": f"0x{ms:08X}", "operating_mode": f(ms, 2, 0),
                         "dbg_hpr_q_depth": f(ms, 20, 16)}
    return d


def decode_afi(a):
    rc, ri, rq, wc, wi, wq = (a[o] for o in AFI_OFFSETS)
    return {
        "rd": {"n32BitEn": f(rc, 0, 0), "FabricQosEn": f(rc, 1, 1), "FabricOutCmdEn": f(rc, 2, 2),
               "QosHeadOfCmdQEn": f(rc, 3, 3), "rdIssueCap0_cmds": f(ri, 2, 0) + 1,
               "rdIssueCap1_cmds": f(ri, 6, 4) + 1, "staticQos": f(rq, 3, 0)},
        "wr": {"n32BitEn": f(wc, 0, 0), "FabricQosEn": f(wc, 1, 1), "FabricOutCmdEn": f(wc, 2, 2),
               "QosHeadOfCmdQEn": f(wc, 3, 3),
               "WrCmdReleaseMode": {0: "on WLAST enqueue", 1: "on WrDataThreshold",
                                    2: "immediately", 3: "reserved"}[f(wc, 5, 4)],
               "WrDataThreshold_beats": f(wc, 11, 8) + 1,
               "wrIssueCap0_cmds": f(wi, 2, 0) + 1, "wrIssueCap1_cmds": f(wi, 6, 4) + 1,
               "staticQos": f(wq, 3, 0)},
    }


def hashes(ddrc, afi):
    def h(items):
        return hashlib.sha256("\n".join(f"{k}={v:08X}" for k, v in items).encode()).hexdigest()[:12]
    qos = [(f"ddrc+{o:03X}", ddrc[o]) for o in DDRC_QOS_OFFSETS]
    qos += [(f"afi{n}+{o:02X}", afi[n][o]) for n in range(4) for o in AFI_OFFSETS]
    cfg = [(f"ddrc+{o:03X}", ddrc[o]) for o in DDRC_OFFSETS if o != 0x054]
    cfg += [(f"afi{n}+{o:02X}", afi[n][o]) for n in range(4) for o in AFI_OFFSETS]
    return h(qos), h(cfg)


def dump():
    ddrc, afi, mctrl = read_all()
    qh, ch = hashes(ddrc, afi)
    return {
        "source": "APB readback via /dev/mem (read-only); DDRC 0xF8006000, AFI0-3 0xF8008000-0xF800B000",
        "ps_version": f(mctrl, 31, 28),
        "ddrc_raw": {f"0x{o:03X}": f"0x{v:08X}" for o, v in ddrc.items()},
        "afi_raw": {str(n): {f"0x{o:02X}": f"0x{v:08X}" for o, v in a.items()} for n, a in afi.items()},
        "ddrc": decode_ddrc(ddrc),
        "afi": {str(n): decode_afi(a) for n, a in afi.items()},
        "qos_hash": qh,
        "cfg_hash": ch,
    }


def summary(j):
    d = j["ddrc"]
    hpr_rd = "".join(str(d["ports"][n]["rd"]["set_hpr"]) for n in (0, 1, 2, 3))
    pri = lambda rw: "/".join(f"{d['ports'][n][rw]['pri']:x}" for n in (0, 1, 2, 3))
    afi = j["afi"]
    rcap = "/".join(str(afi[n]["rd"]["rdIssueCap0_cmds"]) for n in "0123")
    wcap = "/".join(str(afi[n]["wr"]["wrIssueCap0_cmds"]) for n in "0123")
    wrel = "/".join(str({"on WLAST enqueue": "wlast", "on WrDataThreshold": "thr",
                         "immediately": "imm"}.get(afi[n]["wr"]["WrCmdReleaseMode"], "?"))
                    for n in "0123")
    t = lambda r: f"{r['xact_run_length']},{r['max_starve_x32']},{r['min_non_critical_x32']}"
    return (f"ddrqos hpr_rd_p0123={hpr_rd} lpr_entries_field={d['ctrl_reg1']['lpr_num_entries_field']} "
            f"hpr(run,starve,min)={t(d['hpr_reg'])} lpr={t(d['lpr_reg'])} wr={t(d['wr_reg'])} "
            f"arb_pri_rd={pri('rd')} arb_pri_wr={pri('wr')} go2crit={d['ctrl_reg2']['go2critical_en']} "
            f"afi_rdcap={rcap} afi_wrcap={wcap} afi_wrrelease={wrel} qos_hash={j['qos_hash']}")


# ---- workstation side: compare a dump against the ps7_init.c of the preset ----------------
def parse_ps7_init(path):
    """Return {addr: [(field, hi, lo, value)]} and {addr: (mask, value)} for the 3_0 DDR table."""
    text = open(path).read()
    m = re.search(r"unsigned long ps7_ddr_init_data_3_0\[\] = \{(.*?)EMIT_EXIT", text, re.S)
    if not m:
        sys.exit(f"{path}: no ps7_ddr_init_data_3_0 table")
    fields, writes = {}, {}
    last = None
    for line in m.group(1).splitlines():
        fm = re.match(r"\s*// \.\. \.\. (\w+) = (0x[0-9A-Fa-f]+)\s*$", line)
        if fm:
            last = (fm.group(1), int(fm.group(2), 16))
            continue
        am = re.match(r"\s*// \.\. \.\. ==> 0X([0-9A-F]+)\[(\d+):(\d+)\] = 0x([0-9A-F]+)U", line)
        if am and last:
            addr = int(am.group(1), 16)
            fields.setdefault(addr, []).append((last[0], int(am.group(2)), int(am.group(3)),
                                                int(am.group(4), 16)))
            last = None
            continue
        wm = re.match(r"\s*EMIT_MASKWRITE\(0X([0-9A-F]+), 0x([0-9A-F]+)U ,0x([0-9A-F]+)U\)", line)
        if wm:
            writes[int(wm.group(1), 16)] = (int(wm.group(2), 16), int(wm.group(3), 16))
    return fields, writes


def compare(dump_path, ps7_init):
    j = json.load(open(dump_path))
    raw = {int(k, 16): int(v, 16) for k, v in j["ddrc_raw"].items()}
    fields, writes = parse_ps7_init(ps7_init)
    qos_names = re.compile(r"hpr|lpr|reg_ddrc_w_|arb|go2critical|rdwr_idle_gap|page")
    diffs = []
    for addr in sorted(fields):
        off = addr - DDRC_BASE
        if off not in raw:
            continue
        seen = set()
        # A register written twice (0x000: soft_rstb 0 then 1) is compared against its LAST write.
        for name, hi, lo, want in reversed(fields[addr]):
            if (name, hi, lo) in seen:
                continue
            seen.add((name, hi, lo))
            got = f(raw[off], hi, lo)
            if got != want:
                diffs.append((off, name, hi, lo, want, got, bool(qos_names.search(name))))
    out = {"ps7_init": ps7_init, "dump": dump_path, "qos_hash": j["qos_hash"],
           "fields_compared": sum(len(v) for v in fields.values()),
           "differences": [{"reg": f"0x{o:03X}", "field": n, "bits": f"[{hi}:{lo}]",
                            "preset": w, "as_run": g, "qos": q} for o, n, hi, lo, w, g, q in diffs]}
    print(json.dumps(out, indent=1))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--summary", action="store_true", help="one line instead of JSON")
    ap.add_argument("--compare", metavar="DUMP.json", help="workstation: compare a saved dump")
    ap.add_argument("--ps7-init", metavar="ps7_init.c", help="the preset's generated ps7_init.c")
    a = ap.parse_args()
    if a.compare:
        if not a.ps7_init:
            ap.error("--compare needs --ps7-init")
        return compare(a.compare, a.ps7_init)
    j = dump()
    print(summary(j) if a.summary else json.dumps(j, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
