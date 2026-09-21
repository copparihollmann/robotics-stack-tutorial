#!/usr/bin/env python3
"""The memory-port contract: every width on the path ChipTop.axi4_mem_* (and, where a variant has
one, ChipTop.axi4_wlane_*) -> top-level wire -> axi4_to_axi3 -> S_AXI_HPn must agree, for the exact
define set a variant builds with.

WHY THIS EXISTS.  The first builds of 0x5A5A0018/0019 (md5 f271cf9f, 0d449ffd) elaborated a
128-bit ExtMem, so ChipTop's axi4_mem_0 data ports were [127:0]; src/pynqz2_rocket_top.v wires
64-bit nets to them.  Verilog connects mismatched widths silently: Vivado warned about the two
ChipTop OUTPUTS (Synth 8-689, w data and w strb) and said nothing about the r data INPUT, the
bitstream met timing, and the board printed 0 console bytes.  This check runs before Vivado
starts, on the generated Verilog and the top level as the preprocessor will see them, and
refuses on any mismatch.  tcl/build_rocket.tcl runs it for every variant; Synth 8-689 is also
promoted to an error there, as a second, as-built line.

What is checked, per variant (defines taken from tcl/build_rocket.tcl's own variant block and
its has_* -> -verilog_define lines, so the two cannot drift):

  1. every ChipTop port named axi4_mem_<n>_* or axi4_wlane_<n>_* is connected in the ChipTop
     instance -- an input left out or left empty is a failure, an output left empty is allowed
     only for the port's _clock -- and the instance names no such port ChipTop lacks.  The weight
     lane (MEMORY_BANDWIDTH.md 9.9) is a plain AXI4 master like a memory channel, on its own clock
     and its own HP port, so it is sized exactly the same way -- the defect this file exists to
     catch (a width mismatch Verilog connects silently) is no different there;
  2. each connection's width (identifier, part-select, sized literal, concatenation)
     equals the port's width; an expression this cannot size is a failure, not a pass;
  3. the same for every connection on the axi4_to_axi3 instances (parameters applied) and on
     the S_AXI_HP* pins of the PS7 instance (widths from the PS7 IP's stub when a previous
     build has generated one, else from the table below, which was copied from that stub).

  check_mem_contract.py --variant bwl2skip [--gensrc DIR]    # one variant; exit 1 on mismatch
  check_mem_contract.py --all                                 # every variant with a MAGIC

Exit status: 0 clean, 1 mismatch, 2 cannot check (no generated sources, parse failure).
"""
import argparse
import glob
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
REPO = os.path.normpath(os.path.join(ROOT, "..", ".."))
TCL = os.path.join(ROOT, "tcl", "build_rocket.tcl")
TOP = os.path.join(ROOT, "src", "pynqz2_rocket_top.v")

# S_AXI_HPn pin widths of processing_system7 (5.5), from
# build_rocket_micrgb_bwl2skip_z1/proj/.../ip/ps7_0/ps7_0_stub.v.  Used only when no stub exists.
HP_WIDTHS = {
    "ARADDR": 32, "AWADDR": 32, "ARID": 6, "AWID": 6, "WID": 6, "BID": 6, "RID": 6,
    "ARLEN": 4, "AWLEN": 4, "ARSIZE": 3, "AWSIZE": 3, "ARBURST": 2, "AWBURST": 2,
    "ARLOCK": 2, "AWLOCK": 2, "ARCACHE": 4, "AWCACHE": 4, "ARPROT": 3, "AWPROT": 3,
    "ARQOS": 4, "AWQOS": 4, "WDATA": 64, "RDATA": 64, "WSTRB": 8, "BRESP": 2, "RRESP": 2,
    "ARVALID": 1, "AWVALID": 1, "WVALID": 1, "BVALID": 1, "RVALID": 1, "ARREADY": 1,
    "AWREADY": 1, "WREADY": 1, "BREADY": 1, "RREADY": 1, "WLAST": 1, "RLAST": 1,
    "ACLK": 1, "RDISSUECAP1_EN": 1, "WRISSUECAP1_EN": 1, "RCOUNT": 8, "WCOUNT": 8,
    "RACOUNT": 3, "WACOUNT": 6,
}


class CheckError(Exception):
    pass


# ---------------------------------------------------------------------------------------------
# build_rocket.tcl: variants, their config, MAGIC and define set
# ---------------------------------------------------------------------------------------------
def tcl_variants(tcl_path=TCL):
    text = open(tcl_path).read()
    m = re.search(r"switch -- \$variant \{", text)
    if not m:
        raise CheckError("no `switch -- $variant` in %s" % tcl_path)
    i, depth, blocks = m.end(), 1, []
    name, start = None, None
    # Walk the switch body tracking braces; a top-level `name {` opens a variant block.
    while i < len(text) and depth > 0:
        c = text[i]
        if c == "#" and depth == 1 and (i == 0 or text[i - 1] in "\n \t"):
            i = text.index("\n", i)
            continue
        if c == "{":
            if depth == 1:
                name = re.findall(r"([A-Za-z0-9_]+)\s*$", text[:i])[-1]
                start = i + 1
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 1 and name is not None:
                blocks.append((name, text[start:i]))
                name = None
        elif c == "#" and depth >= 2:
            # comments inside a block may contain braces
            j = text.rfind("\n", 0, i)
            if text[j + 1:i].strip() == "":
                i = text.index("\n", i)
                continue
        i += 1
    flag2def = dict(re.findall(r"if \{\$(has_\w+)\}\s*\{\s*lappend synth_args -verilog_define (\w+)=1",
                               text))
    if not flag2def:
        raise CheckError("no has_* -> -verilog_define lines in %s" % tcl_path)
    out = {}
    for name, body in blocks:
        if name == "default":
            continue
        cfg = re.search(r'set\s+cfg\s+"([^"]+)"', body)
        magic = re.search(r"set\s+soc_magic\s+\"32'h([0-9A-Fa-f_]+)\"", body)
        flags = {f for f, v in re.findall(r"set\s+(has_\w+)\s+(\d+)", body) if v != "0"}
        out[name] = {
            "cfg": cfg.group(1) if cfg else None,
            "magic": ("0x" + magic.group(1).replace("_", "").upper()) if magic else None,
            "defines": sorted(flag2def[f] for f in flags if f in flag2def),
        }
    return out


def resolve_gensrc(cfg, explicit=None):
    if explicit:
        return explicit
    if os.environ.get("CHIPYARD_GENSRC"):
        return os.environ["CHIPYARD_GENSRC"]
    cands = []
    if os.environ.get("CHIPYARD_DIR"):
        cands.append(os.path.join(os.environ["CHIPYARD_DIR"], "sims", "verilator",
                                  "generated-src", "chipyard.harness.TestHarness." + cfg))
    cands.append(os.path.join(REPO, "out", "gensrc", "chipyard.harness.TestHarness." + cfg))
    for c in cands:
        if os.path.isdir(c):
            return c
    return None


# ---------------------------------------------------------------------------------------------
# Verilog, just enough of it
# ---------------------------------------------------------------------------------------------
def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def preprocess(src, defines):
    defs = set(defines)
    out, stack = [], []   # stack of (taking, any_branch_taken)
    for line in src.split("\n"):
        t = line.strip()
        m = re.match(r"`(ifdef|ifndef|elsif)\s+(\w+)", t)
        if m:
            kind, sym = m.groups()
            active = all(s[0] for s in stack)
            if kind == "elsif":
                if not stack:
                    raise CheckError("`elsif without `ifdef")
                taking, taken = stack.pop()
                cond = (sym in defs) and not taken
                stack.append((cond, taken or cond))
            else:
                cond = (sym in defs) if kind == "ifdef" else (sym not in defs)
                stack.append((cond, cond))
            out.append("")
            continue
        if re.match(r"`else\b", t):
            taking, taken = stack.pop()
            stack.append((not taken, True))
            out.append("")
            continue
        if re.match(r"`endif\b", t):
            if not stack:
                raise CheckError("`endif without `ifdef")
            stack.pop()
            out.append("")
            continue
        if all(s[0] for s in stack):
            m = re.match(r"`define\s+(\w+)", t)
            if m:
                defs.add(m.group(1))
                out.append("")
                continue
            m = re.match(r"`undef\s+(\w+)", t)
            if m:
                defs.discard(m.group(1))
                out.append("")
                continue
            out.append(line)
        else:
            out.append("")
    if stack:
        raise CheckError("unterminated `ifdef")
    return "\n".join(out)


def eval_int(expr, params):
    e = expr.strip()
    e = re.sub(r"\$clog2\s*\(", "_clog2(", e)
    e = re.sub(r"(\d+)'[dD](\d+)", r"\2", e)
    for k in sorted(params, key=len, reverse=True):
        e = re.sub(r"\b%s\b" % re.escape(k), "(%d)" % params[k], e)
    if not re.fullmatch(r"[0-9()+\-*/%<> _clog2]*", e):
        raise CheckError("cannot evaluate '%s'" % expr)
    e = e.replace("/", "//")

    def _clog2(v):
        return max(0, (int(v) - 1).bit_length())
    return int(eval(e, {"__builtins__": {}}, {"_clog2": _clog2}))


def range_width(rng, params):
    if rng is None:
        return 1
    a, b = rng.split(":")
    return abs(eval_int(a, params) - eval_int(b, params)) + 1


def split_top(s, sep=","):
    parts, depth, cur = [], 0, []
    for c in s:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def module_header(text, name):
    """(params {name: default}, ports {name: (dir, range_str)}) of `module name ...);`."""
    m = re.search(r"\bmodule\s+%s\b" % re.escape(name), text)
    if not m:
        raise CheckError("module %s not found" % name)
    i = m.end()
    params = {}
    j = text.index("(", i)
    if "#" in text[i:j]:
        k, depth = j, 0
        while True:
            if text[k] == "(":
                depth += 1
            elif text[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        for p in split_top(text[j + 1:k]):
            pm = re.search(r"(\w+)\s*=\s*(.+)$", p.strip(), flags=re.S)
            if pm:
                try:
                    params[pm.group(1)] = eval_int(pm.group(2), params)
                except CheckError:
                    pass
        j = text.index("(", k + 1)
    k, depth = j, 0
    while True:
        if text[k] == "(":
            depth += 1
        elif text[k] == ")":
            depth -= 1
            if depth == 0:
                break
        k += 1
    ports = {}
    cur_dir, cur_rng = None, None
    for p in split_top(text[j + 1:k]):
        p = p.strip()
        if not p:
            continue
        pm = re.match(r"(input|output|inout)\b\s*(?:wire|reg|logic)?\s*(?:signed)?\s*(\[[^\]]+\])?\s*(\w+)$",
                      p, flags=re.S)
        if pm:
            cur_dir = pm.group(1)
            cur_rng = pm.group(2)[1:-1] if pm.group(2) else None
            ports[pm.group(3)] = (cur_dir, cur_rng)
            continue
        pm = re.match(r"(\w+)$", p)
        if pm and cur_dir:
            ports[pm.group(1)] = (cur_dir, cur_rng)
            continue
        raise CheckError("cannot parse port '%s' of %s" % (p[:60], name))
    return params, ports


def declarations(body, params):
    """Net widths declared anywhere in a module body (wire/reg/logic, with or without a port
    direction, with or without an initialiser)."""
    widths = {}
    for m in re.finditer(r"\b(wire|reg|logic)\b\s*(?:signed\b)?\s*(\[[^\]]+\])?\s*([^;]+);", body):
        rng = m.group(2)[1:-1] if m.group(2) else None
        try:
            w = range_width(rng, params)
        except CheckError:
            w = None
        for name in split_top(m.group(3)):
            nm = re.match(r"\s*([A-Za-z_]\w*)\s*(=.*)?$", name, flags=re.S)
            if nm:
                widths.setdefault(nm.group(1), w)
    return widths


def instances(body, modname):
    """[(instname, param_text, [(port, expr)])] for every instance of modname."""
    out = []
    for m in re.finditer(r"\b%s\b\s*(#\s*\()?" % re.escape(modname), body):
        i = m.end()
        ptxt = ""
        if m.group(1):
            depth, k = 1, i
            while depth:
                if body[k] == "(":
                    depth += 1
                elif body[k] == ")":
                    depth -= 1
                k += 1
            ptxt = body[i:k - 1]
            i = k
        im = re.match(r"\s*(\w+)\s*\(", body[i:])
        if not im:
            continue
        j = i + im.end()
        depth, k = 1, j
        while depth:
            if body[k] == "(":
                depth += 1
            elif body[k] == ")":
                depth -= 1
            k += 1
        conns = []
        for c in split_top(body[j:k - 1]):
            c = c.strip()
            if not c:
                continue
            cm = re.match(r"\.(\w+)\s*\((.*)\)$", c, flags=re.S)
            if not cm:
                raise CheckError("%s %s: cannot parse connection '%s'" % (modname, im.group(1), c[:60]))
            conns.append((cm.group(1), cm.group(2).strip()))
        out.append((im.group(1), ptxt, conns))
    return out


def expr_width(e, nets, params):
    e = e.strip()
    if e == "":
        return None
    if e.startswith("{") and e.endswith("}"):
        inner = e[1:-1].strip()
        rm = re.match(r"(\d+)\s*(\{.*\})$", inner, flags=re.S)
        if rm:
            return int(rm.group(1)) * expr_width(rm.group(2), nets, params)
        return sum(expr_width(p, nets, params) for p in split_top(inner))
    m = re.fullmatch(r"(\d+)\s*'\s*[sS]?[bBdDhHoO][0-9a-fA-FxXzZ_]+", e)
    if m:
        return int(m.group(1))
    m = re.fullmatch(r"([A-Za-z_]\w*)\s*\[([^\]:]+):([^\]]+)\]", e)
    if m:
        return abs(eval_int(m.group(2), params) - eval_int(m.group(3), params)) + 1
    m = re.fullmatch(r"([A-Za-z_]\w*)\s*\[[^\]:]+\]", e)
    if m:
        return 1
    m = re.fullmatch(r"[A-Za-z_]\w*", e)
    if m:
        if e in nets and nets[e] is not None:
            return nets[e]
        if e in params:
            return None
        raise CheckError("net '%s' has no declaration this can size" % e)
    raise CheckError("cannot size expression '%s'" % e)


# ---------------------------------------------------------------------------------------------
def check(variant, info, gensrc, top_path=TOP, ps7_stub=None, verbose=False):
    """Returns (problems, notes).  Raises CheckError when it cannot check."""
    cfg = info["cfg"]
    chiptop = os.path.join(gensrc, "gen-collateral", "ChipTop.sv")
    if not os.path.isfile(chiptop):
        raise CheckError("no %s" % chiptop)
    ct_text = strip_comments(open(chiptop).read())
    _, ct_ports = module_header(ct_text, "ChipTop")
    top_text = preprocess(strip_comments(open(top_path).read()), info["defines"])
    mm = re.search(r"\bmodule\s+pynqz2_rocket_top\b", top_text)
    em = re.search(r"\bendmodule\b", top_text[mm.end():])
    top_params, top_ports = module_header(top_text, "pynqz2_rocket_top")
    body = top_text[mm.end():mm.end() + em.start()]
    nets = declarations(body, top_params)
    for p, (_, rng) in top_ports.items():
        nets.setdefault(p, range_width(rng, top_params))

    problems, notes = [], []
    mem_ports = {p: v for p, v in ct_ports.items() if re.match(r"axi4_(?:mem|wlane)_\d+_", p)}
    chans = sorted({int(re.match(r"axi4_mem_(\d+)_", p).group(1))
                    for p in mem_ports if p.startswith("axi4_mem_")})
    lanes = sorted({int(re.match(r"axi4_wlane_(\d+)_", p).group(1))
                    for p in mem_ports if p.startswith("axi4_wlane_")})
    ct_inst = instances(body, "ChipTop")
    if len(ct_inst) != 1:
        raise CheckError("expected one ChipTop instance, found %d" % len(ct_inst))
    conns = dict(ct_inst[0][2])
    for p in sorted(conns):
        if p.startswith(("axi4_mem_", "axi4_wlane_")) and p not in ct_ports:
            problems.append("ChipTop has no port %s, but the top level connects it" % p)
    checked = 0
    for p, (d, rng) in sorted(mem_ports.items()):
        pw = range_width(rng, {})
        if p not in conns:
            problems.append("ChipTop %s %s [%d bits] is not connected at all" % (d, p, pw))
            continue
        e = conns[p]
        if e == "":
            if d == "output" and p.endswith("_clock"):
                continue
            problems.append("ChipTop %s %s [%d bits] is connected to nothing" % (d, p, pw))
            continue
        try:
            ew = expr_width(e, nets, top_params)
        except CheckError as ex:
            problems.append("ChipTop %s: %s" % (p, ex))
            continue
        checked += 1
        if ew != pw:
            problems.append("ChipTop %s %s is %d bits; the top level wires '%s', %d bits" % (d, p, pw, e, ew))

    # axi4_to_axi3 shims
    shim_text = strip_comments(open(os.path.join(ROOT, "src", "axi4_to_axi3.v")).read())
    shim_defaults, shim_ports = module_header(shim_text, "axi4_to_axi3")
    shims = instances(body, "axi4_to_axi3")
    for inst, ptxt, sconns in shims:
        params = dict(shim_defaults)
        for pm in re.finditer(r"\.(\w+)\s*\(([^()]*)\)", ptxt):
            params[pm.group(1)] = eval_int(pm.group(2), top_params)
        for port, e in sconns:
            if port not in shim_ports:
                problems.append("%s: axi4_to_axi3 has no port %s" % (inst, port))
                continue
            d, rng = shim_ports[port]
            pw = range_width(rng, params)
            if e == "":
                if d == "input":
                    problems.append("%s.%s: input connected to nothing" % (inst, port))
                continue
            try:
                ew = expr_width(e, nets, top_params)
            except CheckError as ex:
                problems.append("%s.%s: %s" % (inst, port, ex))
                continue
            checked += 1
            if ew != pw:
                problems.append("%s.%s is %d bits; wired '%s', %d bits" % (inst, port, pw, e, ew))

    # PS7 S_AXI_HP pins
    hp = dict(("S_AXI_HP%d_%s" % (n, k), w) for n in range(4) for k, w in HP_WIDTHS.items())
    src = "table"
    if ps7_stub and os.path.isfile(ps7_stub):
        stext = strip_comments(open(ps7_stub).read())
        for d, rng, name in re.findall(r"(input|output)\s+(?:wire\s+)?(\[[^\]]+\])?\s*(S_AXI_HP\d_\w+)\s*;", stext):
            hp[name] = range_width(rng[1:-1], {}) if rng else 1
        src = "stub"
    ps7 = instances(body, "ps7_0")
    if len(ps7) != 1:
        raise CheckError("expected one ps7_0 instance, found %d" % len(ps7))
    hp_used = set()
    for port, e in ps7[0][2]:
        if not port.startswith("S_AXI_HP"):
            continue
        if port not in hp:
            problems.append("u_ps7.%s: not a PS7 pin this knows" % port)
            continue
        hp_used.add(int(port[8]))
        if e == "":
            continue
        try:
            ew = expr_width(e, nets, top_params)
        except CheckError as ex:
            problems.append("u_ps7.%s: %s" % (port, ex))
            continue
        checked += 1
        if ew != hp[port]:
            problems.append("u_ps7.%s is %d bits; wired '%s', %d bits" % (port, hp[port], e, ew))

    datas = sorted({range_width(mem_ports[p][1], {}) for p in mem_ports if p.endswith("_r_bits_data")})
    ids = sorted({range_width(mem_ports[p][1], {}) for p in mem_ports if p.endswith("_ar_bits_id")})
    notes.append("channels %s, weight lanes %s, ChipTop data %s-bit, IDs %s-bit; %d shim(s); HP ports %s; "
                 "%d connections sized (PS7 widths from %s)"
                 % (",".join(map(str, chans)) or "none", ",".join(map(str, lanes)) or "none",
                    "/".join(map(str, datas)), "/".join(map(str, ids)), len(shims),
                    ",".join("HP%d" % n for n in sorted(hp_used)) or "none", checked, src))
    # One shim per AXI4 master out of ChipTop: the memory channels and the weight lane alike.
    if len(chans) + len(lanes) != len(shims):
        problems.append("ChipTop has %d memory channel(s) and %d weight lane(s) but the top level has "
                        "%d axi4_to_axi3 shim(s)" % (len(chans), len(lanes), len(shims)))
    return problems, notes


def find_ps7_stub(variant):
    g = glob.glob(os.path.join(ROOT, "build_rocket*_%s_z1" % variant, "proj", "*.gen", "sources_1",
                               "ip", "ps7_0", "ps7_0_stub.v"))
    g += glob.glob(os.path.join(ROOT, "build_rocket_micrgb_bw_z1", "proj", "*.gen", "sources_1",
                                "ip", "ps7_0", "ps7_0_stub.v"))
    return g[0] if g else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--variant")
    g.add_argument("--all", action="store_true")
    ap.add_argument("--gensrc")
    ap.add_argument("--top", default=TOP)
    ap.add_argument("--tcl", default=TCL)
    args = ap.parse_args()
    try:
        variants = tcl_variants(args.tcl)
    except CheckError as ex:
        print("MEM_PORT_CONTRACT: cannot read %s: %s" % (args.tcl, ex))
        return 2
    todo = sorted(variants) if args.all else [args.variant]
    mismatch = cannot = False
    for v in todo:
        if v not in variants:
            print("MEM_PORT_CONTRACT: no variant '%s' in %s" % (v, args.tcl))
            return 2
        info = variants[v]
        gs = resolve_gensrc(info["cfg"], args.gensrc if not args.all else None)
        tag = "%-11s %-10s %s" % (v, info["magic"], info["cfg"])
        if gs is None:
            print("NO_BUNDLE  %s -- no generated sources (scripts/08_gensrc.sh --unpack %s)" % (tag, info["cfg"]))
            cannot = True
            continue
        try:
            problems, notes = check(v, info, gs, args.top, find_ps7_stub(v))
        except (CheckError, ValueError, IndexError) as ex:
            print("CANNOT     %s -- %s" % (tag, ex))
            cannot = True
            continue
        if problems:
            print("MISMATCH   %s  [defines: %s]" % (tag, " ".join(info["defines"]) or "none"))
            for p in problems:
                print("    " + p)
            mismatch = True
        else:
            print("OK         %s  [defines: %s]" % (tag, " ".join(info["defines"]) or "none"))
        for n in notes:
            print("    " + n)
        print("    gensrc: %s" % gs)
    worst = 1 if mismatch else (2 if cannot else 0)
    if not args.all:
        print("MEM_PORT_CONTRACT_%s" % {0: "OK", 1: "MISMATCH", 2: "CANNOT_CHECK"}[worst])
    return worst


if __name__ == "__main__":
    sys.exit(main())
