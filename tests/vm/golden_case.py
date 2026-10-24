#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare one golden case: HP output vs ours.

  golden_case.py HP.pclm OURS.pclm OURS_ON_HP_RASTER.pclm OURS.ras HP.ras OUTDIR

Writes OUTDIR/{struct.diff,geometry.json,pixels.json,tickets.json,rascheck_*.json,summary.json}
and prints summary.json on stdout.
"""
import difflib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pclmtool as T  # noqa: E402

GEOM_KEYS = ["MediaBox", "ctm", "cm", "nstrips", "strip_W", "strip_H", "placed_H"]


def main():
    hp, ours, ours_rgb, ras_ours, ras_hp, od = sys.argv[1:7]
    os.makedirs(od, exist_ok=True)
    bh, bo, br = (open(p, "rb").read() for p in (hp, ours, ours_rgb))
    s = {}
    # (a) text structure, masked
    th = T.struct_text(bh, True).splitlines(True)
    to = T.struct_text(bo, True).splitlines(True)
    diff = list(difflib.unified_diff(th, to, "hp", "ours", n=1))
    open(os.path.join(od, "struct.diff"), "w").writelines(diff)
    s["struct_diff_lines"] = sum(1 for l in diff if l[:1] in "+-" and l[:3] not in ("+++", "---"))
    # raw (unmasked) differences that are not lengths/offsets: list them
    raw = [l for l in difflib.unified_diff(T.struct_text(bh).splitlines(True), T.struct_text(bo).splitlines(True), n=0)
           if l[:1] in "+-" and l[:3] not in ("+++", "---")]
    import re
    kinds = {}
    for l in raw:
        k = re.sub(r"\d+", "N", l[1:].strip())[:60]
        kinds[k] = kinds.get(k, 0) + 1
    s["raw_diff_kinds"] = kinds
    # (b) geometry
    rh, ro, rr = T.analyze(bh), T.analyze(bo), T.analyze(br)
    s["errors_hp"], s["errors_ours"], s["errors_ours_rgb"] = rh["errors"], ro["errors"], rr["errors"]
    s["pages_hp"], s["pages_ours"] = len(rh["pages"]), len(ro["pages"])
    geo = []
    for i, (ph, po) in enumerate(zip(rh["pages"], ro["pages"])):
        g = {"page": i + 1}
        for k in GEOM_KEYS:
            if ph.get(k) != po.get(k):
                g[k] = {"hp": ph.get(k), "ours": po.get(k)}
        g["hp_summary"] = {k: ph.get(k) for k in ("MediaBox", "nstrips", "strip_W", "leading_white")}
        g["hp_summary"]["first_cm"] = ph.get("cm", [])[:3]
        g["hp_summary"]["last_cm"] = ph.get("cm", [])[-1:]
        g["names_equal"] = ph.get("names") == po.get("names")
        g["rle_bytes"] = {"hp": ph.get("rle_bytes"), "ours": po.get("rle_bytes")}
        geo.append(g)
    json.dump(T.strip_private({"pages": geo}), open(os.path.join(od, "geometry.json"), "w"), indent=1)
    s["geometry_equal"] = s["pages_hp"] == s["pages_ours"] and all(
        not any(k in g for k in GEOM_KEYS) for g in geo)
    s["whitestrip_names_equal"] = all(g["names_equal"] for g in geo)
    s["bytes"] = {"hp": len(bh), "ours": len(bo), "ours_rgb": len(br)}
    # (c) pixels
    px = {}
    for tag, rb in (("gray_path", ro), ("same_rgb_raster", rr)):
        pages = []
        for i in range(min(len(rh["pages"]), len(rb["pages"]))):
            a, b = T.render(rh, i), T.render(rb, i)
            if a is None or b is None:
                pages.append({"page": i + 1, "error": "render failed"})
                continue
            st = T.diff_stats(a, b)
            st["page"] = i + 1
            pages.append(st)
        # where are the differences larger than the 1-level luma rounding?
        big_cols = set()
        for i in range(min(len(rh["pages"]), len(rb["pages"]))):
            a, b = T.render(rh, i), T.render(rb, i)
            if a is not None and b is not None and a.shape == b.shape:
                d = abs(a.astype(int) - b.astype(int)) > 1
                big_cols |= {int(x) for x in T.np.nonzero(d.any(axis=0))[0]}
        px[tag + "_big_diff_columns"] = sorted(big_cols)[:50]
        s["px_" + tag + "_big_diff_columns"] = sorted(big_cols)[:20]
        px[tag] = pages
        s["px_" + tag] = {"diff_pixels": sum(p.get("diff_pixels", 0) for p in pages),
                          "max_abs": max([p.get("max_abs_diff", 0) for p in pages] or [0]),
                          "pixels": sum(p.get("pixels", 0) for p in pages),
                          "hist": {k: sum(p.get("hist", {}).get(k, 0) for p in pages)
                                   for k in ["1", "2-3", "4-15", "16-63", "64-255"]}}
    json.dump(px, open(os.path.join(od, "pixels.json"), "w"), indent=1)
    # (d) tickets
    th_, to_ = T.tickets(bh), T.tickets(bo)
    td = [{"page": i + 1, "key": k, "hp": x.get(k), "ours": y.get(k)}
          for i, (x, y) in enumerate(zip(th_, to_)) for k in sorted(set(x) | set(y))
          if x.get(k) != y.get(k) and k not in ("job-start-time",)]
    json.dump({"hp": th_[:1], "ours": to_[:1], "diffs": td}, open(os.path.join(od, "tickets.json"), "w"), indent=1)
    s["ticket_diffs"] = sorted({"%s: hp=%s ours=%s" % (d["key"], d["hp"], d["ours"]) for d in td})
    # raster checks
    for tag, rep, ras, luma in (("ours", ro, ras_ours, "ours"), ("hp", rh, ras_hp, "hp")):
        raw = T._raw_pages(ras)
        sync = open(ras, "rb").read(4).decode("latin-1")
        end = ">" if sync in ("RaSt", "RaS2", "RaS3") else "<"
        rp = [(h, T.to_gray(r, h, end, luma)) for h, r in raw]
        res = T.rascheck(rep, rp)
        json.dump(res, open(os.path.join(od, "rascheck_%s.json" % tag), "w"), indent=1)
        s["rascheck_" + tag] = {
            "pages": len(rp),
            "diff_in_printable": sum(p.get("diff_in_printable", 0) for p in res),
            "nonwhite_beyond_printable": sum(p.get("nonwhite_beyond_printable", 0) for p in res),
            "nonwhite_outside_raster": sum(p.get("nonwhite_outside_raster", 0) for p in res),
            "errors": [p["error"] for p in res if "error" in p],
            "offsets": sorted({tuple(p["offset_top_left"]) for p in res if "offset_top_left" in p})}
    json.dump(s, open(os.path.join(od, "summary.json"), "w"), indent=1, default=list)
    print(json.dumps(s, default=list))


if __name__ == "__main__":
    main()
