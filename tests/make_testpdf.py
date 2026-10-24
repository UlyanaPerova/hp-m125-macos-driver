#!/usr/bin/env python3
"""Write a printer test page as a small, valid PDF (no dependencies).

  make_testpdf.py OUT.pdf [--pages N] [--size a4|letter]
SPDX-License-Identifier: MIT
"""
import sys

SIZES = {"a4": (595, 842), "letter": (612, 792)}


def page_content(w, h, n, total):
    c = []
    c.append("0 g 0.6 w 20 20 %d %d re S" % (w - 40, h - 40))           # frame
    c.append("BT /F2 26 Tf 50 %d Td (Printer test page) Tj ET" % (h - 80))
    c.append("BT /F1 12 Tf 50 %d Td (HP LaserJet Pro MFP M125r - m125-pclms driver) Tj ET" % (h - 102))
    c.append("BT /F1 12 Tf 50 %d Td (If you can read this, printing works. Page %d of %d.) Tj ET"
             % (h - 120, n, total))
    for i in range(32):                                                # gray scale
        g = i / 31.0
        c.append("%.3f g %d %d 15 40 re f" % (g, 50 + i * 15, h - 200))
    c.append("0 g")
    for i in range(30):                                                # fine lines
        x = 50 + i * 5
        c.append("0.%d w %d %d m %d %d l S" % (1 + i % 9, x, h - 450, x, h - 230))
    for r in range(10, 120, 10):                                       # circles (Bezier)
        cx, cy, k = 400, h - 340, 0.5523 * r
        c.append("0.5 w %d %d m %.1f %.1f %.1f %.1f %d %d c %.1f %.1f %.1f %.1f %d %d c "
                 "%.1f %.1f %.1f %.1f %d %d c %.1f %.1f %.1f %.1f %d %d c S"
                 % (cx + r, cy, cx + r, cy + k, cx + k, cy + r, cx, cy + r,
                    cx - k, cy + r, cx - r, cy + k, cx - r, cy,
                    cx - r, cy - k, cx - k, cy - r, cx, cy - r,
                    cx + k, cy - r, cx + r, cy - k, cx + r, cy))
    for i in range(20):
        c.append("BT /F1 10 Tf 50 %d Td (The quick brown fox jumps over the lazy dog 0123456789) Tj ET"
                 % (h - 490 - i * 13))
    return "\n".join(c).encode()


def main():
    out = sys.argv[1]
    pages = int(sys.argv[sys.argv.index("--pages") + 1]) if "--pages" in sys.argv else 1
    size = sys.argv[sys.argv.index("--size") + 1] if "--size" in sys.argv else "a4"
    w, h = SIZES[size]
    objs = {}
    objs[1] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objs[3] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    objs[4] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>"
    kids = []
    num = 5
    for p in range(pages):
        data = page_content(w, h, p + 1, pages)
        objs[num] = b"<< /Length %d >>\nstream\n" % len(data) + data + b"\nendstream"
        objs[num + 1] = (b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R "
                         b"/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> >>" % (w, h, num))
        kids.append(num + 1)
        num += 2
    objs[2] = b"<< /Type /Pages /Count %d /Kids [%s] >>" % (
        pages, b" ".join(b"%d 0 R" % k for k in kids))
    buf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for i in sorted(objs):
        offsets[i] = len(buf)
        buf += b"%d 0 obj\n" % i + objs[i] + b"\nendobj\n"
    xref = len(buf)
    n = max(objs) + 1
    buf += b"xref\n0 %d\n0000000000 65535 f \n" % n
    for i in range(1, n):
        buf += b"%010d 00000 n \n" % offsets[i]
    buf += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (n, xref)
    open(out, "wb").write(buf)


if __name__ == "__main__":
    main()
