#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Second, independent PCLm-S / CUPS-raster analysis tool for the VM test suite.

Written separately from tests/verify_pclm.py so the two checkers can catch each
other's mistakes.  Needs python3-numpy.

  pclmtool.py struct  OUT.pclm [--mask]       text skeleton (stream bytes removed)
  pclmtool.py info    OUT.pclm                JSON: validity checks, tickets, geometry
  pclmtool.py render  OUT.pclm PREFIX         PGM per page (strips placed by their cm)
  pclmtool.py cmp     A.pclm B.pclm           JSON: pixel diff of rendered pages
  pclmtool.py rasinfo IN.ras                  JSON: raster page headers
  pclmtool.py rascheck OUT.pclm IN.ras        JSON: rendered page vs raster pixels
  pclmtool.py mkras   OUT.ras key=val ...     craft a v3 raster (fuzz/robustness)
  pclmtool.py ticketdiff A.pclm B.pclm        JSON: ticket keys that differ

--mask (struct): replaces job-id, job-start-time, genPCLm version, xref offsets,
startxref and strip /Length values, so only real structure differences remain.
"""
import json
import re
import struct
import sys

try:
    import numpy as np
except ImportError:  # pragma: no cover
    np = None

STRIP_RE = re.compile(rb"(?m)^(\d+) 0 obj\n")


# --------------------------------------------------------------------------
# PDF / PCLm parsing
# --------------------------------------------------------------------------

def rle_decode(data):
    """PDF RunLengthDecode. Returns (bytes, eod_seen, trailing_bytes, error)."""
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        c = data[i]
        i += 1
        if c == 128:
            return bytes(out), True, n - i, None
        if c < 128:
            if i + c + 1 > n:
                return bytes(out), False, 0, "literal run past end"
            out += data[i:i + c + 1]
            i += c + 1
        else:
            if i >= n:
                return bytes(out), False, 0, "repeat run past end"
            out += bytes([data[i]]) * (257 - c)
            i += 1
    return bytes(out), False, 0, None


def parse(buf):
    """Return dict objnum -> {'off','dict','stream'} ; streams cut by /Length."""
    objs = {}
    pos = 0
    for m in STRIP_RE.finditer(buf):
        if m.start() < pos:
            continue  # inside a stream
        num = int(m.group(1))
        start = m.end()
        ep = buf.find(b"endobj", start)
        sp = buf.find(b"stream\n", start)
        stream = None
        d = buf[start:ep if ep != -1 else len(buf)]
        if sp != -1 and (ep == -1 or sp < ep):
            d = buf[start:sp]
            lm = re.search(rb"/Length (\d+)", d)
            s0 = sp + len(b"stream\n")
            if lm:
                L = int(lm.group(1))
                stream = buf[s0:s0 + L]
                pos = s0 + L
                ep2 = buf.find(b"endobj", pos)
                ep = ep2
        objs[num] = {"off": m.start(), "dict": d, "stream": stream}
        if ep != -1:
            pos = max(pos, ep)
    return objs


def tickets(buf):
    out = []
    for blk in re.findall(rb"%  PCLmS-Job-Ticket\n(.*?)%  PCLmS-Job-Ticket-End", buf, re.S):
        t = {}
        for line in blk.decode("latin-1").splitlines():
            m = re.match(r"%\s+([\w-]+):\s?(.*)$", line)
            if m:
                t[m.group(1)] = m.group(2)
        out.append(t)
    return out


def num(s):
    f = float(s)
    return int(f) if f == int(f) else f


def analyze(buf):
    """Validity checks + geometry. Never raises on malformed input."""
    rep = {"bytes": len(buf), "errors": [], "pages": []}
    E = rep["errors"]
    if not buf.startswith(b"%PDF-1.7\n%PCLm 1.0\n"):
        E.append("bad header")
    if not buf.endswith(b"%%EOF\n"):
        E.append("no %%EOF at end")
    objs = parse(buf)
    rep["objects"] = len(objs)
    # xref
    m = re.search(rb"startxref\n(\d+)\n%%EOF\n?$", buf)
    if not m:
        E.append("no startxref")
    else:
        xp = int(m.group(1))
        if not buf.startswith(b"xref\n", xp):
            E.append("startxref does not point at xref")
        else:
            sect = buf[xp + 5:buf.find(b"trailer", xp)].decode("latin-1").split("\n")
            i, seen = 0, 0
            while i < len(sect):
                ln = sect[i].strip()
                if not ln or ln.startswith("%"):
                    i += 1
                    continue
                parts = ln.split()
                if len(parts) != 2:
                    E.append("bad xref subsection line %r" % ln)
                    break
                first, cnt = int(parts[0]), int(parts[1])
                for k in range(cnt):
                    ent = sect[i + 1 + k].split()
                    if len(sect[i + 1 + k]) not in (18, 19, 20):
                        E.append("xref entry length %d" % len(sect[i + 1 + k]))
                    if ent[2] == "n":
                        seen += 1
                        off = int(ent[0])
                        if not buf.startswith(b"%d 0 obj\n" % (first + k), off):
                            E.append("xref offset wrong for obj %d" % (first + k))
                i += 1 + cnt
            sm = re.search(rb"/Size (\d+)", buf[xp:])
            if sm and int(sm.group(1)) != seen + 1:
                E.append("trailer /Size %s != %d" % (sm.group(1).decode(), seen + 1))
            if seen != len(objs):
                E.append("xref has %d in-use entries, file has %d objects" % (seen, len(objs)))
    if 2 not in objs:
        E.append("no page tree object 2")
        return rep
    km = re.search(rb"/Kids \[([^\]]*)\]", objs[2]["dict"])
    kids = [int(x) for x in re.findall(rb"(\d+) 0 R", km.group(1))] if km else []
    cm_ = re.search(rb"/Count (\d+)", objs[2]["dict"])
    if not cm_ or int(cm_.group(1)) != len(kids):
        E.append("/Count does not match /Kids")
    tks = tickets(buf)
    rep["tickets"] = tks
    if len(tks) != len(kids):
        E.append("%d tickets for %d pages" % (len(tks), len(kids)))
    for pi, pn in enumerate(kids):
        pg = {"page": pi + 1}
        rep["pages"].append(pg)
        if pn not in objs:
            E.append("page %d: object %d missing" % (pi + 1, pn))
            continue
        pd = objs[pn]["dict"]
        imgs = [(int(a), int(b)) for a, b in re.findall(rb"/Image(\d+) (\d+) 0 R", pd)]
        mb = re.search(rb"/MediaBox \[ ?([\d. ]+?) ?\]", pd)
        pg["MediaBox"] = [num(x) for x in mb.group(1).split()] if mb else None
        cn = re.search(rb"/Contents \[ ?(\d+) 0 R ?\]", pd)
        content = objs.get(int(cn.group(1)), {}).get("stream") if cn else None
        if content is None:
            E.append("page %d: no content stream" % (pi + 1))
            continue
        ctext = content.decode("latin-1")
        pg["ctm"] = re.findall(r"^([\d.]+ 0 0 [\d.]+ 0 0) cm", ctext, re.M)[:1]
        placed = re.findall(r"(-?[\d.]+) 0 0 (-?[\d.]+) 0 (-?[\d.]+) cm\n/Image(\d+) Do", ctext)
        pg["cm"] = [[num(a), num(b), num(c), int(d)] for a, b, c, d in placed]
        if [p[3] for p in pg["cm"]] != [i for i, _ in imgs]:
            E.append("page %d: content stream does not place every image once, in order" % (pi + 1))
        strips = []
        for idx, on in imgs:
            o = objs.get(on)
            if o is None:
                E.append("page %d: image object %d missing (dangling reference)" % (pi + 1, on))
                strips.append(None)
                continue
            d = o["dict"]
            g = lambda k: (lambda mm: mm.group(1).decode() if mm else None)(re.search(rb"/" + k + rb" /?(\w+)", d))
            s = {"obj": on, "W": int(g(b"Width") or -1), "H": int(g(b"Height") or -1),
                 "name": g(b"Name"), "filter": g(b"Filter"), "cs": g(b"ColorSpace"),
                 "bpc": g(b"BitsPerComponent"), "len": len(o["stream"] or b"")}
            dec, eod, trail, err = rle_decode(o["stream"] or b"")
            if err or not eod or trail:
                E.append("obj %d: RLE %s eod=%s trailing=%d" % (on, err, eod, trail))
            if len(dec) != s["W"] * s["H"]:
                E.append("obj %d: decoded %d bytes != %dx%d" % (on, len(dec), s["W"], s["H"]))
            white = dec.count(255) == len(dec)
            s["white"] = white
            if (s["name"] == "WhiteStrip") != white:
                E.append("obj %d: /Name %s but all-white=%s" % (on, s["name"], white))
            # each strip is followed by its 'q /image Do Q' object in HP's layout
            nxt = objs.get(on + 1)
            s["followed_by_image_q"] = bool(nxt and nxt["stream"] == b"q /image Do Q\n")
            s["_stream"] = o["stream"] or b""   # decoded again lazily by render()
            del dec
            strips.append(s)
        pg["_strips"] = strips
        pg["nstrips"] = len(strips)
        pg["strip_W"] = sorted({s["W"] for s in strips if s})
        pg["strip_H"] = [s["H"] for s in strips if s]
        pg["placed_H"] = [p[1] for p in pg["cm"]]
        pg["leading_white"] = next((i for i, s in enumerate(strips) if s and not s["white"]), len(strips))
        pg["names"] = "".join("W" if s and s["name"] == "WhiteStrip" else "C" for s in strips)
        pg["rle_bytes"] = sum(s["len"] for s in strips if s)
    return rep


def render(rep, pi):
    """Compose page pi as a numpy gray image using the cm placements.

    Canvas height = first yAnchor (top of page); a strip placed with height h at
    yAnchor y covers canvas rows [top-y-h, top-y) and receives the first h rows of
    the strip image (cropping model - HP pads the last strip to 64 lines and places
    only the real lines)."""
    pg = rep["pages"][pi]
    strips = pg.get("_strips") or []
    if not strips or not pg["cm"]:
        return None
    W = max(s["W"] for s in strips if s)
    tops = [p[2] + p[1] for p in pg["cm"]]
    top = max(tops)
    img = np.full((top, W), 255, np.uint8)
    for s, p in zip(strips, pg["cm"]):
        if s is None:
            continue
        a = np.frombuffer(rle_decode(s["_stream"])[0][:s["W"] * s["H"]], np.uint8)
        if a.size != s["W"] * s["H"]:
            continue
        a = a.reshape(s["H"], s["W"])
        h = int(p[1])
        y0 = top - int(p[2]) - h
        if y0 < 0:
            h += y0
            a = a[-y0:]
            y0 = 0
        img[y0:y0 + h, :s["W"]] = a[:h]
    return img


def strip_private(rep):
    for pg in rep["pages"]:
        pg.pop("_strips", None)
    return rep


def write_pgm(path, a):
    with open(path, "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % (a.shape[1], a.shape[0]))
        f.write(a.tobytes())


def diff_stats(a, b):
    r = {"shape_a": list(a.shape), "shape_b": list(b.shape)}
    h, w = min(a.shape[0], b.shape[0]), min(a.shape[1], b.shape[1])
    if a.shape != b.shape:
        # extra area must be white for the comparison to be meaningful
        r["extra_nonwhite_a"] = int((a[h:, :] != 255).sum() + (a[:h, w:] != 255).sum())
        r["extra_nonwhite_b"] = int((b[h:, :] != 255).sum() + (b[:h, w:] != 255).sum())
    a2, b2 = a[:h, :w].astype(np.int16), b[:h, :w].astype(np.int16)
    d = np.abs(a2 - b2)
    nz = d > 0
    r["pixels"] = int(h * w)
    r["diff_pixels"] = int(nz.sum())
    r["max_abs_diff"] = int(d.max()) if d.size else 0
    r["mean_abs_diff_of_differing"] = round(float(d[nz].mean()), 3) if nz.any() else 0
    r["hist"] = {k: int(v) for k, v in zip(
        ["1", "2-3", "4-15", "16-63", "64-255"],
        [((d == 1)).sum(), ((d >= 2) & (d <= 3)).sum(), ((d >= 4) & (d <= 15)).sum(),
         ((d >= 16) & (d <= 63)).sum(), (d >= 64).sum()])}
    sd = (a2 - b2)[nz]
    r["a_darker"] = int((sd < 0).sum())
    r["b_darker"] = int((sd > 0).sum())
    if nz.any():
        ys, xs = np.nonzero(nz)
        r["diff_bbox_yx"] = [int(ys.min()), int(xs.min()), int(ys.max()), int(xs.max())]
        r["diff_rows"] = int(np.unique(ys).size)
        r["diff_cols"] = int(np.unique(xs).size)
    r["nonwhite_a"] = int((a != 255).sum())
    r["nonwhite_b"] = int((b != 255).sum())
    return r


# --------------------------------------------------------------------------
# CUPS raster
# --------------------------------------------------------------------------

HDR_FIELDS = {  # name: (offset, fmt)
    "MediaType": (128, "64s"), "OutputType": (192, "64s"),
    "HWResolution": (276, "2I"), "ImagingBoundingBox": (284, "4I"), "Margins": (312, "2I"),
    "ManualFeed": (320, "I"), "MediaPosition": (324, "I"), "NumCopies": (340, "I"),
    "Orientation": (344, "I"), "PageSize": (352, "2I"),
    "cupsWidth": (372, "I"), "cupsHeight": (376, "I"), "cupsMediaType": (380, "I"),
    "cupsBitsPerColor": (384, "I"), "cupsBitsPerPixel": (388, "I"), "cupsBytesPerLine": (392, "I"),
    "cupsColorOrder": (396, "I"), "cupsColorSpace": (400, "I"), "cupsCompression": (404, "I"),
    "cupsNumColors": (420, "I"), "cupsPageSize": (428, "2f"), "cupsImagingBBox": (436, "4f"),
    "cupsInteger": (452, "16I"), "cupsString0": (580, "64s"), "cupsPageSizeName": (1732, "64s"),
}


def parse_header(h, end):
    r = {}
    for k, (off, f) in HDR_FIELDS.items():
        v = struct.unpack_from(end + f, h, off)
        if f.endswith("s"):
            v = v[0].split(b"\0")[0].decode("latin-1")
        elif len(v) == 1:
            v = v[0]
        else:
            v = [round(x, 3) if isinstance(x, float) else x for x in v]
        r[k] = v
    return r


def read_raster(path, want_pixels=True, max_pages=None):
    data = open(path, "rb").read()
    sync = data[:4]
    kinds = {b"RaSt": (">", 1), b"tSaR": ("<", 1), b"RaS2": (">", 2), b"2SaR": ("<", 2),
             b"RaS3": (">", 3), b"3SaR": ("<", 3)}
    if sync not in kinds:
        raise ValueError("not a CUPS raster (sync %r)" % sync)
    end, ver = kinds[sync]
    pos = 4
    pages = []
    while pos + 1796 <= len(data):
        hdr = parse_header(data[pos:pos + 1796], end)
        pos += 1796
        bpl, H = hdr["cupsBytesPerLine"], hdr["cupsHeight"]
        bpp = hdr["cupsBitsPerPixel"]
        if ver == 2:
            raw, pos = decompress_v2(data, pos, bpl, H, max(1, bpp // 8), hdr["cupsColorSpace"])
        else:
            raw = data[pos:pos + bpl * H]
            pos += bpl * H
        hdr["_complete"] = len(raw) == bpl * H
        gray = to_gray(raw, hdr, end) if want_pixels else None
        pages.append((hdr, gray))
        if max_pages and len(pages) >= max_pages:
            break
    return sync.decode("latin-1"), pages


def decompress_v2(data, pos, bpl, H, unit, cs):
    out = bytearray()
    white = 0xFF if cs in (0, 1, 17, 18, 19, 20) else 0x00
    y = 0
    n = len(data)
    while y < H and pos < n:
        rep = data[pos] + 1
        pos += 1
        line = bytearray()
        while len(line) < bpl and pos < n:
            c = data[pos]
            pos += 1
            if c == 128:
                line += bytes([white]) * (bpl - len(line))
            elif c < 128:
                line += data[pos:pos + unit] * (c + 1)
                pos += unit
            else:
                cnt = (257 - c) * unit
                line += data[pos:pos + cnt]
                pos += cnt
        line = bytes(line[:bpl])
        for _ in range(min(rep, H - y)):
            out += line
        y += rep
    return bytes(out), pos


def to_gray(raw, hdr, end, luma="ours"):
    W, H, bpl = hdr["cupsWidth"], hdr["cupsHeight"], hdr["cupsBytesPerLine"]
    cs, bpp = hdr["cupsColorSpace"], hdr["cupsBitsPerPixel"]
    rows = len(raw) // bpl if bpl else 0
    a = np.frombuffer(raw[:rows * bpl], np.uint8).reshape(rows, bpl)
    if cs in (0, 18, 3):  # W, SW, K
        if bpp == 8:
            g = a[:, :W].copy()
        elif bpp == 16:
            g = a[:, :2 * W].reshape(rows, W, 2)[:, :, 0 if end == ">" else 1].copy()
        elif bpp == 1:
            g = np.unpackbits(a, axis=1)[:, :W]
            g = np.where(g == 1, 255, 0).astype(np.uint8)
        else:
            raise ValueError("unsupported gray bpp %d" % bpp)
        if cs == 3:
            g = 255 - g
        return g
    if cs in (1, 2, 17, 19, 20) and bpp == 32:  # RGBX / RGBA / RGBW: 4th byte ignored
        p = a[:, :4 * W].reshape(rows, W, 4)[:, :, :3].astype(np.uint32)
        if luma == "hp":
            return (0.299 * p[:, :, 0] + 0.587 * p[:, :, 1] + 0.114 * p[:, :, 2]).astype(np.uint8)
        return ((19595 * p[:, :, 0] + 38470 * p[:, :, 1] + 7471 * p[:, :, 2]) >> 16).astype(np.uint8)
    if cs in (1, 19, 20) and bpp in (24, 48):
        if bpp == 24:
            p = a[:, :3 * W].reshape(rows, W, 3).astype(np.uint32)
        else:
            p = a[:, :6 * W].reshape(rows, W, 3, 2)[:, :, :, 0 if end == ">" else 1].astype(np.uint32)
        if luma == "hp":  # genPCLm.cpp rgb_2_gray: (ubyte)(0.299r+0.587g+0.114b)
            return (0.299 * p[:, :, 0] + 0.587 * p[:, :, 1] + 0.114 * p[:, :, 2]).astype(np.uint8)
        return ((19595 * p[:, :, 0] + 38470 * p[:, :, 1] + 7471 * p[:, :, 2]) >> 16).astype(np.uint8)
    raise ValueError("unsupported colorspace %d / %d bpp" % (cs, bpp))


def find_offset(page, ras, search=400):
    """Locate the raster inside the rendered page: exact match of a few rows."""
    rows = [y for y in range(ras.shape[0]) if (ras[y] != 255).any()]
    if not rows:
        return None
    probe = rows[len(rows) // 2]
    # compare only the left part of the row: the right edge may be cropped
    w = max(16, ras.shape[1] - 16)
    best = None
    for top in range(0, min(search, page.shape[0] - probe)):
        prow = page[probe + top]
        for left in range(0, min(search, max(1, page.shape[1] - 16))):
            seg = prow[left:left + w]
            n = min(seg.size, w)
            if n < w:
                break
            if n and np.array_equal(seg[:n], ras[probe, :n]):
                best = (top, left)
                break
        if best:
            break
    return best


def rascheck(rep, pages, expect_top=None, expect_left=None):
    out = []
    for i, (hdr, g) in enumerate(pages):
        r = {"page": i + 1, "raster": [hdr["cupsWidth"], hdr["cupsHeight"]]}
        if i >= len(rep["pages"]):
            r["error"] = "page missing in PCLm"
            out.append(r)
            continue
        img = render(rep, i)
        if img is None:
            r["error"] = "page could not be rendered"
            out.append(r)
            continue
        r["page_px"] = [img.shape[1], img.shape[0]]
        if (g != 255).sum() == 0:
            r["blank_raster"] = True
            r["page_nonwhite"] = int((img != 255).sum())
            out.append(r)
            continue
        # candidate offsets: HP's documented placement (top = page height - bbox top,
        # left = Margins[0], both truncated to pixels) and a pixel search; keep the best
        bb, res = hdr["ImagingBoundingBox"], hdr["HWResolution"][0] or 1
        cands = []
        if bb[2] > bb[0] and bb[3] > bb[1] and bb[3] <= hdr["PageSize"][1]:
            cands.append(((hdr["PageSize"][1] - bb[3]) * res // 72, hdr["Margins"][0] * res // 72))
        else:
            cands.append((0, 0))
        fo = find_offset(img, g) if expect_top is None else (expect_top, expect_left)
        if fo and fo not in cands:
            cands.append(fo)
        def score(o):
            t, l = o
            hh = min(g.shape[0], img.shape[0] - t)
            ww = min(g.shape[1], img.shape[1] - l)
            if hh <= 0 or ww <= 0:
                return 1 << 62
            return int((img[t:t + hh, l:l + ww] != g[:hh, :ww]).sum())
        off = min(cands, key=score) if cands else None
        r["offset_candidates"] = [list(c) for c in cands]
        if off is None:
            r["error"] = "raster not found in page"
            out.append(r)
            continue
        top, left = off
        r["offset_top_left"] = [top, left]
        h = min(g.shape[0], img.shape[0] - top)
        w = min(g.shape[1], img.shape[1] - left)
        sub = img[top:top + h, left:left + w]
        d = sub != g[:h, :w]
        r["compared"] = [w, h]
        r["cropped_cols"] = int(g.shape[1] - w)
        r["cropped_rows"] = int(g.shape[0] - h)
        r["lost_nonwhite_cropped"] = int((g[:, w:] != 255).sum() + (g[h:, :w] != 255).sum())
        r["diff_pixels"] = int(d.sum())
        # HP (and ours) take the printable width/height from the integer
        # ImagingBoundingBox, which can be 1-2 px smaller than cupsWidth/Height.
        bb, res = hdr["ImagingBoundingBox"], hdr["HWResolution"][0] or 1
        if bb[2] > bb[0] and bb[3] > bb[1]:
            pw, ph = (bb[2] - bb[0]) * res // 72, (bb[3] - bb[1]) * res // 72
        else:
            pw, ph = hdr["cupsWidth"], hdr["cupsHeight"]
        r["printable_px"] = [pw, ph]
        r["diff_in_printable"] = int(d[:ph, :pw].sum())
        r["nonwhite_beyond_printable"] = int((g[:, pw:] != 255).sum() + (g[ph:, :pw] != 255).sum())
        if d.any():
            ys, xs = np.nonzero(d)
            r["diff_bbox_yx"] = [int(ys.min()), int(xs.min()), int(ys.max()), int(xs.max())]
            r["diff_cols_list"] = sorted({int(x) for x in xs})[:20]
        mask = np.ones(img.shape, bool)
        mask[top:top + h, left:left + w] = False
        r["nonwhite_outside_raster"] = int((img[mask] != 255).sum())
        out.append(r)
    return out


# --------------------------------------------------------------------------
# raster crafting (for robustness tests)
# --------------------------------------------------------------------------

def mkras(path, kv):
    """Write a big-endian v3 raster. kv: field=value; pages=N; data=white|gray|random|none;
    rows=N (number of rows of data actually written, to make truncated files)."""
    end = ">"
    pages = int(kv.pop("pages", 1))
    data = kv.pop("data", "gray")
    rows_written = kv.pop("rows", None)
    sync = kv.pop("sync", "RaS3").encode()
    hdr = bytearray(1796)
    d = {"HWResolution": [600, 600], "PageSize": [595, 842], "ImagingBoundingBox": [14, 14, 581, 828],
         "Margins": [14, 14], "cupsWidth": 200, "cupsHeight": 100, "cupsBitsPerColor": 8,
         "cupsBitsPerPixel": 8, "cupsColorSpace": 0, "cupsColorOrder": 0, "cupsNumColors": 1,
         "MediaType": "Stationery", "OutputType": "1", "cupsString0": "iso_a4_210x297mm",
         "MediaPosition": 19}
    for k, v in kv.items():
        d[k] = [int(x) for x in v.split(",")] if "," in v else (v if not re.fullmatch(r"-?\d+", v) else int(v))
    if "cupsBytesPerLine" not in d:
        d["cupsBytesPerLine"] = (d["cupsWidth"] * d["cupsBitsPerPixel"] + 7) // 8
    for k, val in d.items():
        off, f = HDR_FIELDS[k]
        if f.endswith("s"):
            struct.pack_into(end + f, hdr, off, str(val).encode())
        elif isinstance(val, list):
            struct.pack_into(end + f, hdr, off, *[x & 0xFFFFFFFF for x in val])
        else:
            struct.pack_into(end + f, hdr, off, val & 0xFFFFFFFF)
    import random
    rnd = random.Random(1234)
    with open(path, "wb") as f:
        f.write(sync)
        for p in range(pages):
            f.write(hdr)
            bpl, H = d["cupsBytesPerLine"], d["cupsHeight"]
            nrows = H if rows_written is None else int(rows_written)
            for y in range(nrows):
                if data == "none":
                    break
                if data == "white":
                    f.write(b"\xff" * bpl)
                elif data == "random":
                    f.write(bytes(rnd.getrandbits(8) for _ in range(bpl)))
                else:
                    f.write(bytes(((x + y) & 0xFF) for x in range(bpl)))


# --------------------------------------------------------------------------
# struct text
# --------------------------------------------------------------------------

def struct_text(buf, mask=False):
    out = []
    objs = parse(buf)
    # Replace binary strip streams by a placeholder
    pos = 0
    spans = []
    for n, o in objs.items():
        if o["stream"] is not None and b"/Subtype /Image" in o["dict"]:
            s0 = buf.find(b"stream\n", o["off"]) + 7
            spans.append((s0, s0 + len(o["stream"])))
    spans.sort()
    parts = []
    for a, b in spans:
        parts.append(buf[pos:a])
        parts.append(b"<binary strip data>")
        pos = b
    parts.append(buf[pos:])
    txt = b"".join(parts).decode("latin-1")
    if mask:
        txt = re.sub(r"(job-id: ).*", r"\1<masked>", txt)
        txt = re.sub(r"(job-start-time: ).*", r"\1<masked>", txt)
        txt = re.sub(r"(genPCLm \(Ver: ).*?\)", r"\1<masked>)", txt)
        txt = re.sub(r"(?m)^\d{10} (\d{5}) n$", r"<offset> \1 n", txt)
        txt = re.sub(r"(startxref\n)\d+", r"\1<masked>", txt)
        txt = re.sub(r"(/Filter /RunLengthDecode\n/Subtype /Image\n/Length )\d+", r"\1<masked>", txt)
    return txt


# --------------------------------------------------------------------------

def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 2
    cmd = a[0]
    flags = [x for x in a[1:] if x.startswith("--")]
    a = [cmd] + [x for x in a[1:] if not x.startswith("--")] + flags
    if cmd == "struct":
        sys.stdout.write(struct_text(open(a[1], "rb").read(), "--mask" in a))
        return 0
    if cmd == "info":
        rep = analyze(open(a[1], "rb").read())
        print(json.dumps(strip_private(rep), indent=1))
        return 0 if not rep["errors"] else 1
    if cmd == "render":
        rep = analyze(open(a[1], "rb").read())
        for i in range(len(rep["pages"])):
            img = render(rep, i)
            if img is not None:
                write_pgm("%s-%d.pgm" % (a[2], i + 1), img)
        return 0
    if cmd == "cmp":
        ra = analyze(open(a[1], "rb").read())
        rb = analyze(open(a[2], "rb").read())
        res = {"pages_a": len(ra["pages"]), "pages_b": len(rb["pages"]), "per_page": []}
        for i in range(min(len(ra["pages"]), len(rb["pages"]))):
            ia, ib = render(ra, i), render(rb, i)
            if ia is None or ib is None:
                res["per_page"].append({"page": i + 1, "error": "render failed"})
                continue
            st = diff_stats(ia, ib)
            st["page"] = i + 1
            res["per_page"].append(st)
        tot = sum(p.get("diff_pixels", 0) for p in res["per_page"])
        res["total_diff_pixels"] = tot
        res["max_abs_diff"] = max([p.get("max_abs_diff", 0) for p in res["per_page"]] or [0])
        res["identical"] = (tot == 0 and res["pages_a"] == res["pages_b"] and
                            all(p.get("shape_a") == p.get("shape_b") for p in res["per_page"]))
        print(json.dumps(res, indent=1))
        return 0
    if cmd == "rasinfo":
        sync, pages = read_raster(a[1], want_pixels=False)
        print(json.dumps({"sync": sync, "pages": [{k: v for k, v in h.items()} for h, _ in pages]}, indent=1))
        return 0
    if cmd == "rascheck":
        rep = analyze(open(a[1], "rb").read())
        luma = "hp" if "--hp-luma" in a else "ours"
        sync, pages = read_raster(a[2], want_pixels=False)
        # re-read with pixels, page by page conversion with chosen luma
        data_pages = []
        sync, rp = read_raster(a[2])
        if luma == "hp":
            end = ">" if sync in ("RaSt", "RaS2", "RaS3") else "<"
            raw_pages = _raw_pages(a[2])
            rp = [(h, to_gray(raw, h, end, "hp")) for h, raw in raw_pages]
        res = {"sync": sync, "luma": luma, "pclm_errors": rep["errors"],
               "raster_pages": len(rp), "pclm_pages": len(rep["pages"]), "pages": rascheck(rep, rp)}
        res["ok"] = (not rep["errors"] and len(rp) == len(rep["pages"]) and
                     all(p.get("diff_in_printable", 0) == 0 and "error" not in p and
                         p.get("nonwhite_outside_raster", 0) == 0 and
                         p.get("lost_nonwhite_cropped", 0) == 0 for p in res["pages"]))
        print(json.dumps(res, indent=1))
        return 0 if res["ok"] else 1
    if cmd == "digest":  # md5 of masked structure + all stream bytes (job-time independent)
        import hashlib
        buf = open(a[1], "rb").read()
        h = hashlib.md5(struct_text(buf, True).encode("latin-1"))
        for n, o in sorted(parse(buf).items()):
            h.update(o["stream"] or b"")
        print(h.hexdigest())
        return 0
    if cmd == "mkras":
        kv = dict(x.split("=", 1) for x in a[2:])
        mkras(a[1], kv)
        return 0
    if cmd == "ticketdiff":
        ta = tickets(open(a[1], "rb").read())
        tb = tickets(open(a[2], "rb").read())
        res = []
        for i, (x, y) in enumerate(zip(ta, tb)):
            for k in sorted(set(x) | set(y)):
                if x.get(k) != y.get(k):
                    res.append({"page": i + 1, "key": k, "a": x.get(k), "b": y.get(k)})
        print(json.dumps({"pages_a": len(ta), "pages_b": len(tb), "diffs": res}, indent=1))
        return 0
    print(__doc__)
    return 2


def _raw_pages(path):
    data = open(path, "rb").read()
    sync = data[:4]
    end = ">" if sync in (b"RaSt", b"RaS2", b"RaS3") else "<"
    ver = 2 if sync in (b"RaS2", b"2SaR") else 3
    pos, out = 4, []
    while pos + 1796 <= len(data):
        hdr = parse_header(data[pos:pos + 1796], end)
        pos += 1796
        bpl, H = hdr["cupsBytesPerLine"], hdr["cupsHeight"]
        if ver == 2:
            raw, pos = decompress_v2(data, pos, bpl, H, max(1, hdr["cupsBitsPerPixel"] // 8), hdr["cupsColorSpace"])
        else:
            raw = data[pos:pos + bpl * H]
            pos += bpl * H
        out.append((hdr, raw))
    return out


if __name__ == "__main__":
    sys.exit(main())
