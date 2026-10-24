# SPDX-License-Identifier: MIT
# Stage golden: same document + page size through HP's PPD/hpcups and through ours; compare.
. "$VMTESTS/lib.sh"
set -x
L="$OUT/golden"; W="$WORK/golden"; mkdir -p "$L" "$W" "$OUT/samples"
DOCLIST=${DOCLIST:-"testpage text photo black blank landscape"}
SIZES=${SIZES:-"A4 Letter Legal A5 A6 EnvDL Custom.300x500"}
# extra sizes (testpage only).  "ours=hp" when the PPD keywords differ.
EXTRA_SIZES=${EXTRA_SIZES:-"B5 B6 Postcard DoublePostcardRotated EnvChou3 EnvISOB5 184x260mm 195x270mm roc16k=Envroc16k Oficio=216x340mm FanFoldGermanLegal=8.5x13in 100x150mm=10x15"}
EXTRA_DOCS=${EXTRA_DOCS:-"testpage"}
[ "${QUICK:-0}" = 1 ] && SIZES="A4 Letter" && EXTRA_SIZES=""

# ppd_diff OURKEY HPKEY -> "same" or a description of how the two PPD size entries differ
ppd_diff() {
  python3 -I - "$OUR_PPD" "$HP_PPD" "$1" "$2" <<'PY'
import re, sys
def get(ppd, key):
    t = open(ppd, encoding="latin-1").read()
    r = {}
    for k in ("PageSize", "ImageableArea", "PaperDimension"):
        m = re.search(r"^\*%s %s[/:][^\n]*" % (k, re.escape(key)), t, re.M)
        if m:
            line = m.group(0)
            if k == "PageSize":
                pm = re.search(r"PageSize\s*\[([\d. ]+)\]", line); nm = re.search(r"cupsString0\s*\(([^)]*)\)", line)
                r["PageSize"] = [float(x) for x in pm.group(1).split()] if pm else None
                r["name"] = nm.group(1) if nm else None
            else:
                r[k] = [float(x) for x in re.search(r'"([^"]*)"', line).group(1).split()]
    return r
a, b = get(sys.argv[1], sys.argv[3]), get(sys.argv[2], sys.argv[4])
if sys.argv[3].startswith("Custom"):
    print("same"); sys.exit()
d = []
for k in ("PageSize", "ImageableArea", "PaperDimension"):
    x, y = a.get(k), b.get(k)
    if x is None or y is None or any(abs(p - q) > 0.005 for p, q in zip(x, y)):
        d.append("%s ours=%s hp=%s" % (k, x, y))
if a.get("name") != b.get("name"):
    d.append("name ours=%s hp=%s" % (a.get("name"), b.get("name")))
print("; ".join(d) if d else "same")
PY
}
printf 'case\tpages\tgeom\tstruct_diff\tpx_gray(diff/max)\tpx_samergb(diff/max)\tverify_hp\tverify_ours\trascheck_ours\ttickets\n' > "$L/summary.tsv"

CASES=()
for doc in $DOCLIST; do for size in $SIZES; do CASES+=("$doc:$size"); done; done
for doc in $EXTRA_DOCS; do for size in $EXTRA_SIZES; do CASES+=("$doc:$size"); done; done
for cs in "${CASES[@]}"; do
    doc=${cs%%:*}; size=${cs#*:}
    osize=${size%%=*}; hsize=${size#*=}
    c="${doc}_${osize}"; d="$W/$c"; mkdir -p "$d" "$L/$c"
    pdiff=$(ppd_diff "$osize" "$hsize")
    echo "$pdiff" > "$L/$c/ppd_size_diff.txt"
    make_raster "$HP_PPD"  "$DOCS/$doc.pdf" "$d/hp.ras"   "PageSize=$hsize"
    make_raster "$OUR_PPD" "$DOCS/$doc.pdf" "$d/ours.ras" "PageSize=$osize"
    run_hp   "$d/hp.ras"   "$d/hp.pclm"       "PageSize=$hsize"; rh=$?
    run_ours "$d/ours.ras" "$d/ours.pclm"     "PageSize=$osize"; ro=$?
    run_ours "$d/hp.ras"   "$d/ours_rgb.pclm" "PageSize=$hsize"; rr=$?
    cp "$d/ours.pclm.stderr" "$L/$c/ours.stderr"; cp "$d/hp.pclm.stderr" "$L/$c/hp.stderr"
    pt rasinfo "$d/ours.ras" > "$L/$c/rasinfo_ours.json"; pt rasinfo "$d/hp.ras" > "$L/$c/rasinfo_hp.json"
    pt struct "$d/hp.pclm" > "$L/$c/hp.struct.txt"; pt struct "$d/ours.pclm" > "$L/$c/ours.struct.txt"
    if [ $rh -ne 0 ] || [ $ro -ne 0 ] || [ $rr -ne 0 ]; then
      result golden "$c" FAIL "exit codes hp=$rh ours=$ro ours_rgb=$rr"; continue
    fi
    python3 -I "$VMTESTS/golden_case.py" "$d/hp.pclm" "$d/ours.pclm" "$d/ours_rgb.pclm" "$d/ours.ras" "$d/hp.ras" "$L/$c" > /dev/null
    S="$L/$c/summary.json"
    python3 -I "$VERIFY" "$d/hp.pclm" --json > "$L/$c/verify_hp.json" 2>&1; vh=$?
    python3 -I "$VERIFY" "$d/ours.pclm" --raster "$d/ours.ras" --json > "$L/$c/verify_ours.json" 2>&1; vo=$?
    python3 -I "$VERIFY" "$d/ours.pclm" --json > "$L/$c/verify_ours_noraster.json" 2>&1; vn=$?
    pages=$(json_get "$S" 'r["pages_ours"]')
    geom=$(json_get "$S" 'r["geometry_equal"] and r["pages_hp"]==r["pages_ours"]')
    sd=$(json_get "$S" 'r["struct_diff_lines"]')
    pg=$(json_get "$S" '"%d/%d" % (r["px_gray_path"]["diff_pixels"], r["px_gray_path"]["max_abs"])')
    pr=$(json_get "$S" '"%d/%d" % (r["px_same_rgb_raster"]["diff_pixels"], r["px_same_rgb_raster"]["max_abs"])')
    prmax=$(json_get "$S" 'r["px_same_rgb_raster"]["max_abs"]')
    rc_ok=$(json_get "$S" 'r["rascheck_ours"]["diff_in_printable"]==0 and r["rascheck_ours"]["nonwhite_outside_raster"]==0 and not r["rascheck_ours"]["errors"]')
    tk=$(json_get "$S" '"; ".join(r["ticket_diffs"]) or "same"')
    errs=$(json_get "$S" 'r["errors_ours"][:3]')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$pages" "$geom" "$sd" "$pg" "$pr" "$vh" "$vo/$vn" "$rc_ok" "$tk" >> "$L/summary.tsv"

    gnum=$(python3 -I -c 'import json,sys
g=json.load(open(sys.argv[1]))["pages"][0]
def v(k):
    x=g.get(k); return "%s->%s" % (x["hp"], x["ours"]) if isinstance(x, dict) else None
out=[]
for k in ("MediaBox","strip_W","nstrips"):
    if v(k): out.append("%s hp->ours %s" % (k, v(k)))
if "cm" in g:
    h, o = g["cm"]["hp"], g["cm"]["ours"]
    out.append("first cm hp=%s ours=%s; last cm hp=%s ours=%s" % (h[0][:3], o[0][:3], h[-1][:3], o[-1][:3]))
print("; ".join(out) or "-")' "$L/$c/geometry.json")
    if [ "$geom" = True ]; then
      result golden "$c.geometry" PASS "MediaBox/strips/cm identical to HP ($pages p)${pdiff:+ [PPD: $pdiff]}"
    elif [ "$pdiff" != same ]; then
      result golden "$c.geometry" INFO "size definition changed vs HP PPD ($pdiff); geometry: $gnum"
    else
      result golden "$c.geometry" FAIL "geometry differs from HP although the PPD size entries match: $gnum"
    fi
    if [ "$sd" = 0 ]; then result golden "$c.structure" PASS "masked text identical"
    elif [ "$pdiff" != same ]; then result golden "$c.structure" INFO "$sd differing lines, expected from the changed size definition (golden/$c/struct.diff)"
    else result golden "$c.structure" FAIL "$sd differing lines (golden/$c/struct.diff)"; fi
    # differences >1 level are accepted only right of the raster (HP artefact: when the
    # integer ImagingBoundingBox is 1 px wider than cupsWidth hpcups emits a black column there)
    bigc=$(json_get "$S" 'r["px_same_rgb_raster_big_diff_columns"]')
    hpart=$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); ri=json.load(open(sys.argv[2]))["pages"][0]
cols=s["px_same_rgb_raster_big_diff_columns"]; off=s["rascheck_hp"]["offsets"]; left=off[0][1] if off else 116
print(bool(cols) and all(c >= left + ri["cupsWidth"] for c in cols))' "$S" "$L/$c/rasinfo_hp.json")
    if [ "$prmax" -le 1 ]; then
      result golden "$c.pixels_same_raster" PASS "ours on HP's RGB raster vs HP: diff px/max=$pr (luma rounding only)"
    elif [ "$hpart" = True ]; then
      result golden "$c.pixels_same_raster" PASS "diff px/max=$pr; >1-level diffs only in column(s) $bigc right of the raster = hpcups artefact (black 1-px column), ours white"
    else
      result golden "$c.pixels_same_raster" FAIL "ours on HP's RGB raster vs HP: diff px/max=$pr, big-diff columns $bigc"
    fi
    result golden "$c.pixels_gray_path" INFO "ours(gray PPD) vs HP(RGB PPD): diff px/max=$pg"
    [ "$errs" = "[]" ] && [ "$rc_ok" = True ] && result golden "$c.raster_fidelity" PASS "ours == input raster inside printable area" ||
      result golden "$c.raster_fidelity" FAIL "errors=$errs rascheck_ok=$rc_ok"
    if [ "$tk" = same ]; then result golden "$c.ticket" PASS ""
    elif [ "$pdiff" != same ] && [ -z "$(echo "$tk" | tr ';' '\n' | sed 's/^ *//' | grep -v '^media-size-name')" ] && echo "$pdiff" | grep -q 'name ours'; then
      result golden "$c.ticket" INFO "intentional PWG media name change: $tk"
    else result golden "$c.ticket" FAIL "$tk"; fi
    [ $vh -eq 0 ] && result golden "$c.verify_on_hp" PASS "verify_pclm.py accepts HP output" ||
      result golden "$c.verify_on_hp" FAIL "verify_pclm.py rejects HP output: $(grep -o '"errors": \[[^]]*' "$L/$c/verify_hp.json" | head -c 200)"
    if [ $vo -ne 0 ] && [ $vn -eq 0 ] && [ "$rc_ok" = True ]; then
      result golden "$c.verify_ours" INFO "verify_pclm.py --raster reports '$(tr -d '\n' < "$L/$c/verify_ours.json" | grep -o '"errors": \[[^]]*' | head -c 120)' but structure checks pass and pclmtool rascheck finds the page == raster: checker false positive (see report, checker issue C1)"
    else
    [ $vo -eq 0 ] && result golden "$c.verify_ours" PASS "" ||
      result golden "$c.verify_ours" FAIL "verify_pclm.py --raster rc=$vo (no-raster rc=$vn): $(tr -d '\n' < "$L/$c/verify_ours.json" | grep -o '"errors": \[[^]]*' | head -c 200)"

    fi
    if [ "$c" = testpage_A4 ]; then
      cp "$d/hp.pclm" "$OUT/samples/testpage_A4_hp.pclm"; cp "$d/ours.pclm" "$OUT/samples/testpage_A4_ours.pclm"
      pt render "$d/ours.pclm" "$W/ours_testpage"; pt render "$d/hp.pclm" "$W/hp_testpage"
      python3 -I -c 'import sys; from PIL import Image; [Image.open(a).reduce(8).save(b) for a,b in zip(sys.argv[1::2],sys.argv[2::2])]' \
        "$W/ours_testpage-1.pgm" "$OUT/samples/testpage_A4_ours_p1.png" "$W/hp_testpage-1.pgm" "$OUT/samples/testpage_A4_hp_p1.png"
    fi
    [ "${KEEP:-0}" = 1 ] || rm -f "$d"/*.ras "$d"/*.pclm
done

# distro hpcups (3.23.12) vs built 3.26.6 on one case
d="$W/distro"; mkdir -p "$d"
make_raster "$HP_PPD" "$DOCS/testpage.pdf" "$d/hp.ras" PageSize=A4
run_hp "$d/hp.ras" "$d/a.pclm" PageSize=A4 "$HPCUPS"; run_hp "$d/hp.ras" "$d/b.pclm" PageSize=A4 "$HPCUPS_DISTRO"
pt struct --mask "$d/a.pclm" > "$d/a.txt"; pt struct --mask "$d/b.pclm" > "$d/b.txt"
pc=$(pt cmp "$d/a.pclm" "$d/b.pclm" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["identical"])')
cmp -s "$d/a.txt" "$d/b.txt" && [ "$pc" = True ] && result golden distro_hpcups_equivalent PASS "hpcups 3.23.12 (distro) == 3.26.6 (built) for testpage A4" ||
  result golden distro_hpcups_equivalent INFO "distro and 3.26.6 hpcups differ (pixels identical=$pc)"
rm -f "$d"/*.ras
