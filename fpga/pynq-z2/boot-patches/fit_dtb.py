#!/usr/bin/env python3
"""Extract and replace the kernel DTB inside a U-Boot FIT image (image.ub).

Why this exists: the PYNQ image boots via a FIT, so /boot/system.dtb is ignored --
U-Boot takes the DTB embedded in image.ub ("## Loading fdt from FIT Image"). Editing it
normally means dumpimage + mkimage from u-boot-tools, which is not installed on every
build host. A FIT *is* a flat devicetree, so this does the surgery directly.

    ./fit_dtb.py extract image.ub base.dtb
    fdtput -ts base.dtb /axi/serial@e0001000 status okay     # edit however you like
    ./fit_dtb.py replace image.ub base.dtb image_new.ub

replace recomputes the fdt image's hash, which U-Boot verifies at boot and will refuse
to boot without ("Bad hash value"). Everything else in the FIT -- the 7 MB kernel payload,
load/entry addresses, the configurations node -- is carried through untouched and checked
byte-for-byte afterwards.

Only stock Python is needed. Verified on PYNQ v3.1.1 (Zynq-7000, U-Boot 2023.01).
"""
import hashlib, struct, sys

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
HDR = '>10I'   # magic totalsize off_struct off_strings off_rsvmap ver last_ver \
               # boot_cpu size_strings size_struct


def header(d):
    f = struct.unpack(HDR, d[:40])
    if f[0] != 0xd00dfeed:
        raise ValueError(f"not a flat devicetree (magic {f[0]:#x})")
    return dict(zip(('magic', 'totalsize', 'off_struct', 'off_strings', 'off_rsvmap',
                     'version', 'last_comp_version', 'boot_cpuid',
                     'size_strings', 'size_struct'), f))


def walk(d):
    """Yield (path, name, value_offset, value_len) for every property in the blob."""
    h = header(d)
    off, path = h['off_struct'], []
    end = h['off_struct'] + h['size_struct']
    while off < end:
        (tok,) = struct.unpack('>I', d[off:off + 4]); off += 4
        if tok == FDT_BEGIN_NODE:
            z = d.index(b'\0', off)
            path.append(d[off:z].decode())
            off = (z + 1 + 3) & ~3
        elif tok == FDT_END_NODE:
            path.pop()
        elif tok == FDT_PROP:
            plen, noff = struct.unpack('>II', d[off:off + 8]); off += 8
            z = d.index(b'\0', h['off_strings'] + noff)
            name = d[h['off_strings'] + noff:z].decode()
            p = '/' + '/'.join(path[1:])
            yield p, name, off, plen
            off = (off + plen + 3) & ~3
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise ValueError(f"unexpected token {tok} at offset {off - 4}")


def getprop(d, path, name):
    for p, n, o, l in walk(d):
        if p == path and n == name:
            return d[o:o + l]
    raise KeyError(f"{path}:{name} not found")


def setprop(d, path, name, value):
    """Return a new blob with one property's value replaced, resizing the struct block.

    Property data lives in the struct block, so a length change shifts the strings block
    that follows it and three header fields have to move with it.
    """
    for p, n, o, l in walk(d):
        if p == path and n == name:
            break
    else:
        raise KeyError(f"{path}:{name} not found")

    h = header(d)
    old_pad = (l + 3) & ~3
    new_pad = (len(value) + 3) & ~3
    delta = new_pad - old_pad

    out = bytearray(d[:o - 8])                       # up to the FDT_PROP len/nameoff
    out += struct.pack('>II', len(value), struct.unpack('>I', d[o - 4:o])[0])
    out += value + b'\0' * (new_pad - len(value))
    out += d[o + old_pad:]                           # rest of struct + strings block

    out[4:8]   = struct.pack('>I', h['totalsize'] + delta)
    out[12:16] = struct.pack('>I', h['off_strings'] + delta)
    out[36:40] = struct.pack('>I', h['size_struct'] + delta)
    return bytes(out)


def fdt_node(fit):
    """Name of the /images child holding the flat_dt payload."""
    for p, n, o, l in walk(fit):
        if p.startswith('/images/') and p.count('/') == 2 and n == 'type':
            if fit[o:o + l].rstrip(b'\0') == b'flat_dt':
                return p
    raise KeyError("no image of type flat_dt in this FIT")


def main():
    argc = {'extract': 4, 'replace': 5}.get(sys.argv[1] if len(sys.argv) > 1 else None)
    if argc is None or len(sys.argv) != argc:
        sys.exit(__doc__)
    cmd, fit_path, *rest = sys.argv[1:]
    fit = open(fit_path, 'rb').read()
    node = fdt_node(fit)

    if cmd == 'extract':
        dtb = getprop(fit, node, 'data')
        open(rest[0], 'wb').write(dtb)
        print(f"{node}: {len(dtb):,} bytes -> {rest[0]}")

    elif cmd == 'replace':
        dtb = open(rest[0], 'rb').read()
        header(dtb)                                   # reject a non-DTB early
        out = setprop(fit, node, 'data', dtb)
        out = setprop(out, node + '/hash-1', 'value', hashlib.sha1(dtb).digest())

        # Verify before writing: every payload must read back intact and hash correctly.
        assert getprop(out, node, 'data') == dtb, "fdt payload did not round-trip"
        for p, n, o, l in walk(out):
            if p.startswith('/images/') and n == 'data':
                img = p
                got = getprop(out, img + '/hash-1', 'value')
                want = hashlib.sha1(out[o:o + l]).digest()
                assert got == want, f"{img}: hash mismatch after repack"
                if img != node:
                    assert out[o:o + l] == getprop(fit, img, 'data'), f"{img}: payload changed"
        open(rest[1], 'wb').write(out)
        print(f"{node}: replaced with {len(dtb):,} bytes, sha1 updated")
        print(f"wrote {rest[1]} ({len(out):,} bytes; was {len(fit):,})")
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
