#!/usr/bin/env python3
"""Independent checker for PCLm-S output (SPDX-License-Identifier: MIT).

  verify_pclm.py OUT.pclm [--raster IN.ras] [--pgm PREFIX] [--json]

Checks:
  * header, per-page job ticket, xref table: every offset must point at "N 0 obj"
  * every strip: RunLengthDecode must give exactly Width*Height bytes, end with EOD
  * page content stream references every strip once, in order
  * with --raster: decoded page pixels == input raster pixels (converted to gray)
Writes decoded pages as PGM with --pgm.
"""
import json
import re
import struct
import sys


def rle_decode(data):
    out = bytearray()
    i, n = 0, len(data)
    eod = False
    while i < n:
        c = data[i]
        i += 1
        if c == 128:
            eod = True
            break
        if c < 128:
            out += data[i:i + c + 1]
            i += c + 1
        else:
            out += bytes([data[i]]) * (257 - c)
            i += 1
    return bytes(out), eod, n - i


def parse_objects(buf):
    objs = {}
    for m in re.finditer(rb"(?m)^(\d+) 0 obj\n", buf):
        num = int(m.group(1))
        start = m.end()
        sp = buf.find(b">>\nstream\n", start)
        ep = buf.find(b"endobj\n", start)
        stream = None
        if sp != -1 and sp < ep:
            d = buf[start:sp + 3]
            lm = re.search(rb"/Length (\d+)", d)
            s0 = sp + 3 + 7
            stream = buf[s0:s0 + int(lm.group(1))]
        else:
            d = buf[start:ep]
        objs[num] = (m.start(), d, stream)
    return objs


def read_raster(path):
    """Yield (header dict, list of gray rows) per page from a CUPS raster v1/v2/v3 file."""
    data = open(path, "rb").read()
    sync = data[:4]
    if sync not in (b"RaS3", b"RaS2", b"RaSt", b"3SaR", b"2SaR", b"tSaR"):
        raise SystemExit("unsupported raster sync %r" % sync)
    be = sync in (b"RaS3", b"RaS2", b"RaSt")
    end = ">" if be else "<"
    pos = 4
    pages = []
    while pos + 1796 <= len(data):
        h = data[pos:pos + 1796]
        pos += 1796
        u = lambda off: struct.unpack(end + "I", h[off:off + 4])[0]
        hdr = {
            "res": u(276), "w": u(372), "h": u(376), "bpc": u(384), "bpp": u(388),
            "bpl": u(392), "order": u(396), "cs": u(400), "comp": u(404),
            "bbox": [u(284 + 4 * k) for k in range(4)], "margins": [u(312), u(316)],
            "pagesize": [u(352), u(356)], "be": be,
        }
        if sync[:3] == b"RaS" and sync[3:] == b"2" or sync == b"2SaR":
            raise SystemExit("compressed v2 raster not supported by checker; use v3")
        size = hdr["bpl"] * hdr["h"]
        raw = data[pos:pos + size]
        pos += size
        rows = []
        for y in range(hdr["h"]):
            line = raw[y * hdr["bpl"]:(y + 1) * hdr["bpl"]]
            rows.append(to_gray(line, hdr))
        pages.append((hdr, rows))
    return pages


def to_gray(line, hdr):
    cs, bpp, w = hdr["cs"], hdr["bpp"], hdr["w"]
    if cs in (0, 18, 3):  # W, SW, K
        if bpp == 8:
            g = line[:w]
        elif bpp == 16:  # samples are in the byte order of the writer (see sync word)
            g = line[0:2 * w:2] if hdr["be"] else line[1:2 * w:2]
        elif bpp == 1:
            g = bytes(255 if (line[i >> 3] >> (7 - (i & 7))) & 1 else 0 for i in range(w))
        else:
            raise SystemExit("bpp %d" % bpp)
        if cs == 3:
            g = bytes(255 - x for x in g)
        return bytes(g)
    if cs in (1, 17, 2, 4) and bpp in (24, 32):
        n = bpp // 8
        return bytes((19595 * line[n * i] + 38470 * line[n * i + 1] + 7471 * line[n * i + 2]) >> 16
                     for i in range(w))
    raise SystemExit("colorspace %d/%d bpp not supported by checker" % (cs, bpp))


def main():
    args = sys.argv[1:]
    path = args[0]
    raster = args[args.index("--raster") + 1] if "--raster" in args else None
    pgm = args[args.index("--pgm") + 1] if "--pgm" in args else None
    buf = open(path, "rb").read()
    errors = []
    report = {"file": path, "bytes": len(buf)}

    if not buf.startswith(b"%PDF-1.7\n%PCLm 1.0\n"):
        errors.append("bad header")
    if not buf.endswith(b"%%EOF\n"):
        errors.append("missing %%EOF")

    objs = parse_objects(buf)

    # xref
    m = re.search(rb"startxref\n(\d+)\n%%EOF\n$", buf)
    xref_pos = int(m.group(1)) if m else -1
    if not buf[xref_pos:].startswith(b"xref\n"):
        errors.append("startxref does not point to xref")
    xref = buf[xref_pos:].split(b"trailer")[0].decode().split("\n")[1:]
    i = 0
    nentries = 0
    while i < len(xref) and xref[i].strip():
        if xref[i].startswith("%"):
            i += 1
            continue
        first, count = map(int, xref[i].split())
        for k in range(count):
            off, gen, kind = xref[i + 1 + k].split()
            num = first + k
            if kind == "n":
                nentries += 1
                if not buf[int(off):].startswith(("%d 0 obj\n" % num).encode()):
                    errors.append("xref offset wrong for obj %d" % num)
        i += 1 + count
    size = int(re.search(rb"/Size (\d+)", buf[xref_pos:]).group(1))
    if size != nentries + 1:
        errors.append("trailer /Size %d != %d" % (size, nentries + 1))

    # pages
    kids = [int(x) for x in re.findall(rb"(\d+) 0 R", re.search(rb"/Kids \[([^\]]*)\]", objs[2][1]).group(1))]
    count = int(re.search(rb"/Count (\d+)", objs[2][1]).group(1))
    if count != len(kids):
        errors.append("page count mismatch")
    tickets = buf.count(b"%  PCLmS-Job-Ticket\n")
    if tickets != len(kids):
        errors.append("tickets %d != pages %d" % (tickets, len(kids)))

    pages_out = []
    for pi, pnum in enumerate(kids):
        pd = objs[pnum][1]
        images = [(int(a), int(b)) for a, b in re.findall(rb"/Image(\d+) (\d+) 0 R", pd)]
        mb = [int(x) for x in re.search(rb"/MediaBox \[ 0 0 (\d+) (\d+) \]", pd).groups()]
        cnum = int(re.search(rb"/Contents \[ (\d+) 0 R \]", pd).group(1))
        content = objs[cnum][2].decode()
        placed = re.findall(r"(\d+) 0 0 (\d+) 0 (-?\d+) cm\n/Image(\d+) Do Q", content)
        if [int(p[3]) for p in placed] != [a for a, _ in images]:
            errors.append("page %d: content order mismatch" % (pi + 1))
        rows = []
        width = None
        for idx, onum in images:
            if onum not in objs or objs[onum][2] is None:
                errors.append("page %d: image object %d missing" % (pi + 1, onum))
                continue
            d, s = objs[onum][1], objs[onum][2]
            w = int(re.search(rb"/Width (\d+)", d).group(1))
            h = int(re.search(rb"/Height (\d+)", d).group(1))
            width = width or w
            if w != width:
                errors.append("strip width changes")
            dec, eod, trailing = rle_decode(s)
            if not eod or trailing:
                errors.append("strip obj %d: missing EOD or trailing bytes" % onum)
            if len(dec) != w * h:
                errors.append("strip obj %d: %d bytes, expected %d" % (onum, len(dec), w * h))
            white = dec.count(255) == len(dec)
            name = re.search(rb"/Name /(\w+)", d).group(1).decode()
            if (name == "WhiteStrip") != white:
                errors.append("strip obj %d: /Name %s but white=%s" % (onum, name, white))
            for y in range(h):
                rows.append(dec[y * w:(y + 1) * w])
        placed_h = sum(int(x[1]) for x in placed)
        pages_out.append({"media_pt": mb, "width_px": width, "rows": len(rows),
                          "placed_rows": placed_h, "strips": len(images), "_rows": rows})

    report["pages"] = [{k: v for k, v in p.items() if not k.startswith("_")} for p in pages_out]

    if pgm:
        for i, p in enumerate(pages_out):
            with open("%s-%d.pgm" % (pgm, i + 1), "wb") as f:
                f.write(b"P5\n%d %d\n255\n" % (p["width_px"], p["rows"]))
                f.write(b"".join(p["_rows"]))

    if raster:
        rp = read_raster(raster)
        if len(rp) != len(pages_out):
            errors.append("raster pages %d != pclm pages %d" % (len(rp), len(pages_out)))
        for i, ((hdr, rrows), p) in enumerate(zip(rp, pages_out)):
            # locate the printable area inside the decoded page: ticket says margins pre-applied
            diff = compare(hdr, rrows, p["_rows"])
            report.setdefault("pixel_check", []).append(diff)
            if diff["mismatched_rows"]:
                errors.append("page %d: %d rows differ" % (i + 1, diff["mismatched_rows"]))

    report["errors"] = errors
    report["ok"] = not errors
    if "--json" in args:
        print(json.dumps(report, indent=1))
    else:
        for e in errors:
            print("ERROR:", e)
        print("OK" if not errors else "FAILED", json.dumps(report["pages"]))
    sys.exit(0 if not errors else 1)


def compare(hdr, rrows, prows):
    """Place the raster where the page geometry says (same rules as the PCLm-S spec/HP)
    and compare every printable row; the rest of each page row must be white."""
    res = hdr["res"]
    bb, ps = hdr["bbox"], hdr["pagesize"]
    if bb[2] > bb[0] and bb[3] > bb[1] and bb[3] <= ps[1]:
        top = (ps[1] - bb[3]) * res // 72
        left = hdr["margins"][0] * res // 72
        src_w = (bb[2] - bb[0]) * res // 72
        src_h = (bb[3] - bb[1]) * res // 72
    else:
        top, left, src_w, src_h = 0, 0, hdr["w"], hdr["h"]
    width = len(prows[0]) if prows else 0
    if left + src_w > width:
        left = 0
    cw = min(src_w, hdr["w"], width - left)
    bad = 0
    compared = 0
    for y in range(min(src_h, len(rrows))):
        py = y + top
        if py >= len(prows):
            break
        compared += 1
        row = prows[py]
        if row[left:left + cw] != rrows[y][:cw] or \
           row[:left].count(255) != left or row[left + cw:].count(255) != width - left - cw:
            bad += 1
    return {"top": top, "left": left, "mismatched_rows": bad, "rows_compared": compared}


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, AttributeError, IndexError, struct.error) as e:
        print("FAILED: file is malformed, checker stopped: %r" % (e,))
        sys.exit(1)
