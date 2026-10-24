#!/usr/bin/env python3
"""Generate the paper-size part of the PPD from PWG 5101.1 media names.

  gen_ppd_sizes.py ppd/m125-pclms.ppd      (rewrites the block between the markers)

Sizes are the papers the M125/M126/M127/M128 accept (input tray: 76x127 mm to 216x356 mm).
Dimensions come from the PWG self-describing names; the printable area is the page minus the
printer's 14 pt (about 5 mm) hardware margins on every side.
SPDX-License-Identifier: MIT
"""
import re
import sys

MARGIN = 14.0
BEGIN = "*% === BEGIN generated page sizes (tools/gen_ppd_sizes.py) ===\n"
END = "*% === END generated page sizes ===\n"

# (PPD keyword, display name, PWG 5101.1 name)
SIZES = [
    ("Letter", "Letter 8.5x11in", "na_letter_8.5x11in"),
    ("A4", "A4 210x297mm", "iso_a4_210x297mm"),
    ("Legal", "Legal 8.5x14in", "na_legal_8.5x14in"),
    ("Executive", "Executive 7.25x10.5in", "na_executive_7.25x10.5in"),
    ("Statement", "Statement 5.5x8.5in", "na_invoice_5.5x8.5in"),
    ("FanFoldGermanLegal", "Oficio 8.5x13in", "na_foolscap_8.5x13in"),
    ("Oficio", "Oficio 8.5x13.4in", "na_oficio_8.5x13.4in"),
    ("A5", "A5 148x210mm", "iso_a5_148x210mm"),
    ("A6", "A6 105x148mm", "iso_a6_105x148mm"),
    ("B5", "JIS B5 182x257mm", "jis_b5_182x257mm"),
    ("B6", "JIS B6 128x182mm", "jis_b6_128x182mm"),
    ("195x270mm", "16K 195x270mm", "om_16k_195x270mm"),
    ("184x260mm", "16K 184x260mm", "om_16k_184x260mm"),
    ("roc16k", "16K 7.75x10.75in", "roc_16k_7.75x10.75in"),
    ("Postcard", "Postcard 100x148mm", "jpn_hagaki_100x148mm"),
    ("DoublePostcardRotated", "Double Postcard 148x200mm", "jpn_oufuku_148x200mm"),
    ("4x6", "Index card 4x6in", "na_index-4x6_4x6in"),
    ("5x7", "Photo 5x7in", "na_5x7_5x7in"),
    ("100x150mm", "Photo 10x15cm", "om_small-photo_100x150mm"),
    ("EnvMonarch", "Envelope Monarch", "na_monarch_3.875x7.5in"),
    ("Env10", "Envelope #10", "na_number-10_4.125x9.5in"),
    ("EnvDL", "Envelope DL", "iso_dl_110x220mm"),
    ("EnvC5", "Envelope C5", "iso_c5_162x229mm"),
    ("EnvC6", "Envelope C6", "iso_c6_114x162mm"),
    ("EnvISOB5", "Envelope B5", "iso_b5_176x250mm"),
    ("EnvChou3", "Envelope Chou #3", "jpn_chou3_120x235mm"),
]


def dims(pwg):
    m = re.search(r"_([\d.]+)x([\d.]+)(mm|in)$", pwg)
    w, h, unit = float(m.group(1)), float(m.group(2)), m.group(3)
    k = 72.0 if unit == "in" else 72.0 / 25.4
    return w * k, h * k


def fmt(v):
    return ("%.2f" % v).rstrip("0").rstrip(".")


def block():
    ps, pr, ia, pd = [], [], [], []
    for kw, label, pwg in SIZES:
        w, h = dims(pwg)
        code = "<</cupsString0(%s)/PageSize[%s %s]/ImagingBBox null>>setpagedevice" % (pwg, fmt(w), fmt(h))
        ps.append('*PageSize %s/%s: "%s"\n' % (kw, label, code))
        pr.append('*PageRegion %s/%s: "%s"\n' % (kw, label, code))
        ia.append('*ImageableArea %s/%s: "%s %s %s %s"\n' % (kw, label, fmt(MARGIN), fmt(MARGIN),
                                                          fmt(w - MARGIN), fmt(h - MARGIN)))
        pd.append('*PaperDimension %s/%s: "%s %s"\n' % (kw, label, fmt(w), fmt(h)))
    out = [BEGIN,
           "*OpenUI *PageSize/Media Size: PickOne\n*OrderDependency: 10 AnySetup *PageSize\n*DefaultPageSize: A4\n",
           *ps, "*CloseUI: *PageSize\n\n",
           "*OpenUI *PageRegion/Media Size: PickOne\n*OrderDependency: 10 AnySetup *PageRegion\n*DefaultPageRegion: A4\n",
           *pr, "*CloseUI: *PageRegion\n\n",
           "*DefaultImageableArea: A4\n", *ia, "\n",
           "*DefaultPaperDimension: A4\n", *pd, END]
    return "".join(out)


def main():
    path = sys.argv[1]
    text = open(path).read()
    if BEGIN in text:
        pre, rest = text.split(BEGIN, 1)
        post = rest.split(END, 1)[1]
    else:  # first run: replace from the PageSize UI to the last PaperDimension line
        start = text.index("*OpenUI *PageSize/")
        last = [m.end() for m in re.finditer(r"(?m)^\*PaperDimension .*\n", text)][-1]
        pre, post = text[:start], text[last:]
    open(path, "w").write(pre + block() + post)


if __name__ == "__main__":
    main()
