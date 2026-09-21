#!/usr/bin/env python3
"""Plot a post-route floorplan of the PYNQ-Z1/Z2 Rocket SoC (placement colored by block).

Zynq-7000 variant of the Arty-200T plotter in the riskybird tree: same contract, different
partition. There is no MIG block here -- the DDR controller is hard silicon in the PS and
places nothing in fabric -- and the TACIT trace logic is broken out of the tiles it lives
inside, because it is a bigger LUT block than the L2.

Consumes the directory produced by extract_floorplan_zynq.tcl -- meta.txt,
blocks_util.csv, cells_<block>.txt, and the optional crit_src/crit_dst.txt --
and renders a labeled PNG. All per-block LUT/FF/BRAM/DSP totals and the device
occupancy are read back from the extractor (re-derived from the checkpoint),
never hardcoded; the part/speed-grade in the title comes from meta.txt.

One marker per placed site over the device grid. SLICE sites use their native
X/Y; DSP/BRAM/IO columns are linearly scaled onto the SLICE X/Y reference grid
so the whole die overlays coherently.

Usage:  python3 plot_floorplan.py --indir <outdir> [--out <png>] [--title-note "..."]
"""
import argparse
import os
import re
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

# ---- block presentation (draw order = bottom..top; accelerators on top).
# Keep the ids in sync with the partition in extract_floorplan.tcl. ----
BLOCKS = [
    ("uncore", "Uncore / periphery (bootrom, CLINT, PLIC, UART, debug, AXI shim)", "#AEB4BE"),
    ("buses",  "TileLink interconnect (sbus, cbus, pbus, mbus, fbus)",             "#7E8AA2"),
    ("l2",     "L2 / coherence manager (inclusive, 64 KB, 4-way)",                 "#F2A541"),
    ("hart1",  "hart 1 \u00b7 LITTLE Rocket (4 KB L1s, no BTB, no MMU)",              "#4C9F70"),
    ("hart0",  "hart 0 \u00b7 big Rocket + packed-SIMD P-extension (16 KB L1s)",      "#2E86AB"),
    ("tacit",  "TACIT trace encoders + DMA sinks (one pair per hart)",             "#8E6FBF"),
    ("accel",  "Decoupled RoCC engine (MAC array, scratchpad, fill/drain) + RoCC shim", "#17BEBB"),
    ("mic",    "PDM microphone front end (CIC + FIR decimator)",                   "#E4572E"),
]
LEGEND_ORDER = ["mic", "accel", "tacit", "hart0", "hart1", "l2", "buses", "uncore"]
COLOR = {b: c for b, _, c in BLOCKS}
LABEL = {b: l for b, l, _ in BLOCKS}

SITE_RE = re.compile(r'^([A-Za-z0-9]+?)_X(\d+)Y(\d+)$')


def sclass(stype):
    if stype.startswith('SLICE'): return 'slice'
    if stype.startswith('DSP'):   return 'dsp'
    if stype.startswith('RAMB'):  return 'bram'
    return 'io'


def read_meta(indir):
    meta = {}
    p = os.path.join(indir, "meta.txt")
    if os.path.exists(p):
        for line in open(p):
            parts = line.split(None, 1)
            if len(parts) == 2:
                meta[parts[0]] = parts[1].strip()
    return meta


def read_util(indir):
    util, dev, dev_avail = {}, {}, {}
    p = os.path.join(indir, "blocks_util.csv")
    for line in open(p):
        f = line.strip().split(",")
        if len(f) < 5 or f[0] == "block":
            continue
        # BRAM tiles can be fractional on this device -- a lone RAMB18 is half a
        # RAMB36 tile, and the mic front end has exactly that. The Arty variant read
        # this as int because nothing there used a half tile.
        row = dict(luts=int(f[1]), ff=int(f[2]), bram=float(f[3]), dsp=int(f[4]))
        if f[0] == "DEVICE":
            dev = row
        elif f[0] == "DEVICE_AVAIL":
            dev_avail = row
        else:
            util[f[0]] = row
    return util, dev, dev_avail


def read_sites(indir):
    """Return per-block dict of site lists and the global per-site-type max X/Y."""
    per_block = {}
    tmaxx, tmaxy = {}, {}
    for b, _, _ in BLOCKS:
        p = os.path.join(indir, f"cells_{b}.txt")
        if not os.path.exists(p):
            continue
        recs = []  # (sclass, stype, x, y)
        for line in open(p):
            m = SITE_RE.match(line.strip())
            if not m:
                continue
            stype, x, y = m.group(1), int(m.group(2)), int(m.group(3))
            recs.append((sclass(stype), stype, x, y))
            tmaxx[stype] = max(tmaxx.get(stype, 0), x)
            tmaxy[stype] = max(tmaxy.get(stype, 0), y)
        if recs:
            per_block[b] = recs
    return per_block, tmaxx, tmaxy


def read_locs(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            m = SITE_RE.match(line.strip())
            if m:
                out.append((m.group(1), int(m.group(2)), int(m.group(3))))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--indir", required=True, help="extractor output directory")
    ap.add_argument("--out", default=None, help="output PNG (default <indir>/floorplan.png)")
    ap.add_argument("--title-note", default="", help="extra note appended to the subtitle")
    args = ap.parse_args()

    indir = args.indir
    out = args.out or os.path.join(indir, "floorplan.png")

    meta = read_meta(indir)
    util, dev, dev_avail = read_util(indir)
    per_block, tmaxx, tmaxy = read_sites(indir)
    if not per_block:
        print("ERROR: no placed sites found in", indir, file=sys.stderr)
        sys.exit(1)

    SX = tmaxx.get('SLICE', max((v for k, v in tmaxx.items()), default=1))
    SY = tmaxy.get('SLICE', max((v for k, v in tmaxy.items()), default=1))

    def norm(stype, x, y):
        mx = tmaxx.get(stype, 0) or 1
        my = tmaxy.get(stype, 0) or 1
        return x / mx * SX, y / my * SY

    part = meta.get("PART", "unknown-part")
    grade = part.split("-")[-1] if "-" in part else "?"
    config = meta.get("CONFIG", "unknown-config")

    # ---- figure ----
    fig, ax = plt.subplots(figsize=(13.6, 12.4))
    ax.set_facecolor("#0f1115")
    fig.patch.set_facecolor("white")
    ax.add_patch(plt.Rectangle((-2, -2), SX + 4, SY + 4, fill=False,
                               edgecolor="#3a3f4b", lw=1.2, zorder=0))

    mstyle = {
        'slice': dict(marker='s', s=6.5, lw=0),
        'io':    dict(marker='x', s=11, lw=0.7),
        'dsp':   dict(marker='^', s=15, lw=0.4, edgecolors='black'),
        'bram':  dict(marker='D', s=14, lw=0.4, edgecolors='black'),
    }
    draw_order = [b for b, _, _ in BLOCKS if b in per_block]

    def scatter_class(sc, zbase):
        for b in draw_order:
            xs, ys = [], []
            for rc, st, x, y in per_block[b]:
                if rc != sc:
                    continue
                nx, ny = norm(st, x, y)
                xs.append(nx); ys.append(ny)
            if xs:
                ax.scatter(xs, ys, c=COLOR[b], alpha=0.9, rasterized=(sc == 'slice'),
                           zorder=zbase, **mstyle[sc])

    scatter_class('slice', 2)
    scatter_class('io', 3)
    scatter_class('bram', 5)
    scatter_class('dsp', 5)

    # ---- optional critical-path overlay ----
    csrc = read_locs(os.path.join(indir, "crit_src.txt"))
    cdst = read_locs(os.path.join(indir, "crit_dst.txt"))
    if csrc:
        cs = np.array([norm(st, x, y) for st, x, y in csrc])
        sx, sy = cs[:, 0].mean(), cs[:, 1].mean()
        if cdst:
            cd = np.array([norm(st, x, y) for st, x, y in cdst])
            d = (cd[:, 0] - sx) ** 2 + (cd[:, 1] - sy) ** 2
            dx, dy = cd[d.argmin()]
        else:
            dx, dy = sx + 8, sy + 22
        ax.annotate("", xy=(dx, dy), xytext=(sx, sy),
                    arrowprops=dict(arrowstyle="-|>", color="#ffec3d", lw=2.2,
                                    shrinkA=6, shrinkB=6), zorder=8)
        ax.scatter([sx], [sy], marker='*', s=340, c="#ffec3d",
                   edgecolors='black', lw=0.8, zorder=9)
        ax.scatter([dx], [dy], marker='*', s=240, c="#fff59d",
                   edgecolors='black', lw=0.8, zorder=9)
        ax.text(sx + 3, sy - 10,
                f"-{grade} worst path\nspad reader bytesSent_reg\n-> acc-BRAM ADDRBWRADDR",
                fontsize=8.2, color="#ffec3d", zorder=10,
                bbox=dict(boxstyle="round,pad=0.3", fc="#1a1d24", ec="#ffec3d", lw=0.8))

    # ---- axes ----
    ax.set_xlim(-4, SX + 4); ax.set_ylim(-4, SY + 4); ax.set_aspect('equal')
    ax.set_xlabel("device column  (SLICE X; DSP/BRAM/IO columns scaled onto SLICE grid)", fontsize=9.5)
    ax.set_ylabel("device row  (SLICE Y)", fontsize=9.5)
    ax.tick_params(colors="#333", labelsize=8)
    for s in ax.spines.values():
        s.set_color("#888")

    # ---- titles (figure-level, centered => no clipping) ----
    occ = (100.0 * dev.get("luts", 0) / dev_avail["luts"]) if dev_avail.get("luts") else 0.0
    gs = util.get("hart0", {}).get("luts", 0) + util.get("hart1", {}).get("luts", 0)
    gs_pct = (100.0 * gs / dev_avail["luts"]) if dev_avail.get("luts") else 0.0
    tac = util.get("tacit", {}).get("luts", 0)
    fig.suptitle("PYNQ-Z1 Rocket SoC — post-route floorplan, placement colored by block",
                 fontsize=14, fontweight='bold', x=0.5, y=0.978)
    sub = (f"{part}  (speed -{grade})   ·   {occ:.1f}% Slice-LUT occupancy")
    if gs:
        sub += f"   ·   big+LITTLE tiles = {gs:,} LUT ({gs_pct:.0f}% of device)"
    if tac:
        sub += f"   ·   TACIT = {tac:,} LUT"
    acc = util.get("accel", {}).get("luts", 0)
    if acc:
        sub += f"   ·   RoCC engine = {acc:,} LUT"
    fig.text(0.5, 0.949, sub, ha='center', fontsize=10.3)
    # The note rides on the config line: appended to the subtitle it pushed that line past
    # the figure edges and clipped both ends.
    cfgline = f"config: {config}   —   source: {os.path.basename(meta.get('DCP',''))}"
    if args.title_note:
        cfgline += f"   —   {args.title_note}"
    fig.text(0.5, 0.930, cfgline, ha='center', fontsize=8.8, color='#555')

    # ---- block legend with re-derived tallies ----
    def nbram(v):
        return f"{v:g}"

    def fmt(u):
        return f"{u['luts']:,} LUT · {u['ff']:,} FF · {nbram(u['bram'])} BRAM · {u['dsp']} DSP"
    leg_blocks = [Patch(facecolor=COLOR[b], edgecolor='none',
                        label=f"{LABEL[b]}\n     {fmt(util[b])}")
                  for b in LEGEND_ORDER if b in util and b in per_block]
    l1 = ax.legend(handles=leg_blocks, loc='upper left', bbox_to_anchor=(1.01, 1.0),
                   fontsize=8.4, title="Block  —  Slice-LUT / FF / BRAM-tile / DSP",
                   title_fontsize=9.2, frameon=True, borderpad=0.9,
                   labelspacing=1.15, handlelength=1.4, handleheight=1.6)
    l1.get_title().set_fontweight('bold')
    ax.add_artist(l1)

    leg_sites = [
        Line2D([0], [0], marker='s', color='none', markerfacecolor='#555',
               markersize=6, label='SLICE (LUT/FF/CARRY/SRL/LUTRAM)'),
        Line2D([0], [0], marker='D', color='none', markerfacecolor='#555',
               markeredgecolor='black', markersize=8, label='RAMB18/RAMB36 (Block RAM)'),
        Line2D([0], [0], marker='^', color='none', markerfacecolor='#555',
               markeredgecolor='black', markersize=8, label='DSP48E1'),
        Line2D([0], [0], marker='x', color='#555', markersize=7, lw=0,
               label='IO / clocking (IOB, I/OLOGIC, IDELAY, BUFG, PHASER)'),
    ]
    if csrc:
        leg_sites.append(Line2D([0], [0], marker='*', color='none', markerfacecolor='#ffec3d',
                                markeredgecolor='black', markersize=13,
                                label=f'-{grade} critical-path endpoints'))
    l2 = ax.legend(handles=leg_sites, loc='lower left', bbox_to_anchor=(1.01, 0.0),
                   fontsize=8.2, title="Site type (marker)", title_fontsize=9.2,
                   frameon=True, borderpad=0.8, labelspacing=0.9)
    l2.get_title().set_fontweight('bold')

    fig.text(0.012, 0.022,
             f"device totals: {dev.get('luts',0):,} Slice-LUT ({occ:.1f}%)  ·  "
             f"{dev.get('ff',0):,} FF  ·  {dev.get('bram',0)} BRAM tiles  ·  {dev.get('dsp',0)} DSP.   "
             "Black areas = unplaced fabric. The PS (ARM cores, DDR controller) is hard silicon and places nothing here.",
             fontsize=7.4, color="#555")
    fig.text(0.012, 0.007,
             f"DCP: {meta.get('DCP','')}   ·   "
             "DSP/BRAM/IO columns linearly scaled onto the SLICE X/Y reference grid.",
             fontsize=7.0, color="#555")

    fig.subplots_adjust(left=0.06, right=0.63, top=0.905, bottom=0.06)
    fig.savefig(out, dpi=200, facecolor='white')
    print("saved", out)


if __name__ == "__main__":
    main()
