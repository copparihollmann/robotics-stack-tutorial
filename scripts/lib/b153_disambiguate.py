#!/usr/bin/env python3
"""Lab B153 -- make duplicated symbol names legible in the merged Perfetto timeline.

THE PROBLEM THIS SOLVES.  samples/tacit_duo compiles the ModelBlaster P-extension helpers
TWICE from one header: once with MB_PEXT_HW=1 for hart 0, which has the MBP datapath and
emits real custom-0 words, and once with MB_PEXT_HW=0 for hart 1, which has no MBP datapath
and gets pext.h's software model.  Both copies are `static` and GCC gives both the same
`.constprop.0` name, so the ELF carries two DIFFERENT functions at two addresses under one
string:

    0x8000147c  mb_pext_conv_gather.constprop.0   215 insns, 0 custom-0    (hart 0)
    0x8000190c  mb_pext_conv_pixel.constprop.0    279 insns, 48 custom-0   (hart 0)
    0x8000807c  mb_pext_conv_gather.constprop.0   215 insns, 0 custom-0    (hart 1)
    0x80008508  mb_pext_conv_pixel.constprop.0    470 insns, 0 custom-0    (hart 1)

The decoder resolves a PC to the enclosing symbol and prints that string, so the two lanes
come out looking like they are running identical code.  They are not -- and "the big hart
runs the instruction, the little hart runs the software model of the same instruction" is
the whole heterogeneity story the trace exists to show.  An attendee reading the Perfetto
UI cannot see the addresses; they see one name on two timelines.

WHAT IT DOES.  Renames ONLY the names that are ambiguous -- a symbol that occurs at exactly
one address is left exactly as it was, so the timeline does not fill up with noise:

    mb_pext_conv_pixel.constprop.0  ->  mb_pext_conv_pixel.constprop.0 [hw @0x8000190c]
                                    ->  mb_pext_conv_pixel.constprop.0 [sw @0x80008508]

The [hw]/[sw] tag is derived from the DISASSEMBLY, not from which lane the event landed on:
a copy containing custom-0 words (opcode 0x0b) is the hardware path, one containing none is
the software model.  Deriving it from the lane would make the label assume the very thing
the trace is evidence for.  Copies that cannot be told apart by their own bytes (conv_gather
compiles identically either way) inherit the label by copy order, and only when every
directly-readable name agrees on that order -- see build_renames.

E EVENTS CARRY NO ADDRESS, so they are matched to their B by a per-(pid,tid) stack.  An E
whose base name does not match the top of the stack is left alone rather than guessed at.
"""
import argparse
import collections
import json
import os
import re
import subprocess
import sys


def symbols(elf, objdump):
    """[(addr, name, n_insns, n_custom0)] sorted by address, from the disassembly."""
    out = subprocess.run([objdump, "-d", elf], capture_output=True, text=True,
                         errors="replace")
    if out.returncode != 0:
        sys.exit("objdump failed: %s" % out.stderr[:400])
    syms = []
    cur = addr = None
    n = c0 = 0
    head = re.compile(r"^([0-9a-f]{8,16}) <(.+)>:")
    insn = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s")
    for line in out.stdout.split("\n"):
        m = head.match(line)
        if m:
            if cur is not None:
                syms.append((addr, cur, n, c0))
            addr, cur, n, c0 = int(m.group(1), 16), m.group(2), 0, 0
            continue
        m = insn.match(line)
        if m and cur is not None:
            n += 1
            if (int(m.group(2), 16) & 0x7f) == 0x0b:
                c0 += 1
    if cur is not None:
        syms.append((addr, cur, n, c0))
    syms.sort()
    return syms


def build_renames(syms):
    """{start_addr: new_name} for every symbol whose NAME is not unique.

    TWO COPIES, AND ONLY ONE OF THEM CAN BE LABELLED FROM ITS OWN BYTES.
    mb_pext_conv_pixel differs between the two builds -- 48 custom-0 words in the
    MB_PEXT_HW=1 copy, none and 470 instructions in the software model -- so ITS label is
    read straight off the disassembly.  mb_pext_conv_gather is all loads and shuffles and
    compiles to the same 215 instructions with no custom-0 either way, so its two copies
    are indistinguishable by content.

    They are still distinguishable by POSITION: each translation unit's copies are emitted
    together, so for every duplicated name the copies sort into the same order.  The label
    is therefore propagated by COPY INDEX from the names that could be labelled directly --
    and only if every directly-labelled name agrees on that ordering.  If they disagree,
    nothing is inferred and the ambiguous copies get their address alone, because a
    confident wrong label is worse than an unlabelled address.

    scripts/lib/b153_gates.py then CHECKS the result against the lanes: hart 0 must execute
    only [hw] copies and hart 1 only [sw].  That is what turns this from an assumption into
    a claim the artefact itself can refute.
    """
    by_name = collections.defaultdict(list)
    for a, nm, n, c0 in syms:
        by_name[nm].append((a, n, c0))
    dups = {nm: sorted(rows) for nm, rows in by_name.items() if len(rows) > 1}

    # Which copy index is the hardware one, according to the names we can read directly?
    votes = set()
    for nm, rows in dups.items():
        if len({c0 > 0 for _, _, c0 in rows}) == 2:
            for i, (a, n, c0) in enumerate(rows):
                if c0 > 0:
                    votes.add(i)
    hw_idx = votes.pop() if len(votes) == 1 else None

    ren, how = {}, {}
    for nm, rows in dups.items():
        direct = len({c0 > 0 for _, _, c0 in rows}) == 2
        for i, (a, n, c0) in enumerate(rows):
            if direct:
                tag, why = ("hw" if c0 > 0 else "sw"), "custom-0 in this copy"
            elif hw_idx is not None and len(rows) == 2:
                tag, why = ("hw" if i == hw_idx else "sw"), "copy order"
            else:
                tag, why = None, "ambiguous"
            ren[a] = ("%s [%s @0x%08x]" % (nm, tag, a) if tag
                      else "%s [@0x%08x]" % (nm, a))
            how[a] = why
    return ren, how


def owner_index(syms):
    starts = [a for a, _, _, _ in syms]
    return starts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elf", required=True)
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--objdump", default=os.environ.get("OBJDUMP", "riscv64-zephyr-elf-objdump"))
    a = ap.parse_args()

    syms = symbols(a.elf, a.objdump)
    ren, how = build_renames(syms)
    starts = owner_index(syms)
    import bisect

    print("duplicated symbol names in %s: %d copies renamed"
          % (os.path.basename(a.elf), len(ren)))
    for addr in sorted(ren):
        print("    0x%08x -> %-52s (%s)" % (addr, ren[addr], how[addr]))
    if not ren:
        print("    (nothing ambiguous; copying through unchanged)")

    stacks = collections.defaultdict(list)
    ev = re.compile(r"^(\s*)(\{.*?\})(,?)(\s*)$")
    n_b = n_e = n_ren = 0
    tmp = a.out + ".tmp"
    with open(a.src) as fh, open(tmp, "w") as out:
        for line in fh:
            m = ev.match(line)
            if not m:
                out.write(line)
                continue
            e = json.loads(m.group(2))
            ph = e.get("ph")
            key = (e.get("pid"), e.get("tid"))
            changed = False
            if ph in ("B", "X"):
                n_b += 1
                ad = e.get("args", {}).get("addr")
                new = None
                if ad:
                    i = bisect.bisect_right(starts, int(ad, 16)) - 1
                    if i >= 0:
                        new = ren.get(starts[i])
                if new:
                    e["name"] = new
                    changed = True
                    n_ren += 1
                if ph == "B":
                    stacks[key].append((e.get("name"), new is not None))
            elif ph == "E":
                n_e += 1
                st = stacks[key]
                if st:
                    nm, was = st.pop()
                    # Only rewrite if the popped frame really is this E's frame.
                    if was and nm.startswith(e.get("name", "") + " ["):
                        e["name"] = nm
                        changed = True
                        n_ren += 1
            if changed:
                out.write("%s%s%s%s" % (m.group(1), json.dumps(e, sort_keys=True),
                                        m.group(3), m.group(4)))
            else:
                out.write(line)
    os.replace(tmp, a.out)
    print("  B/X events %d, E events %d, names rewritten %d" % (n_b, n_e, n_ren))
    return 0


if __name__ == "__main__":
    sys.exit(main())
