# SPDX-License-Identifier: MIT
# Stage perf: filter-only time per page, max RSS, output size; ours (1/2/4/8 threads) vs hpcups.
. "$VMTESTS/lib.sh"
set -x
L="$OUT/perf"; W="$WORK/perf"; mkdir -p "$L" "$W"
REPS=${REPS:-3}; [ "${QUICK:-0}" = 1 ] && REPS=1
DOC="$DOCS/mixed10.pdf"
t0=$(date +%s.%N); make_raster "$OUR_PPD" "$DOC" "$W/gray.ras" PageSize=A4; t1=$(date +%s.%N)
make_raster "$HP_PPD" "$DOC" "$W/rgb.ras" PageSize=A4
NP=$(json_get <(pt rasinfo "$W/gray.ras") 'len(r["pages"])')
result perf rasterize_context INFO "cupsfilter (pdftopdf+gs) for the $NP-page gray job took $(echo "$t1-$t0" | bc | cut -c1-5)s, for comparison"
cat "$W/gray.ras" "$W/rgb.ras" > /dev/null   # warm page cache

printf 'filter\tinput\trep\twall_s\tuser_s\tsys_s\tmaxrss_kb\tout_bytes\tms_per_page\n' > "$L/perf_raw.tsv"
bench() {  # label input env... -- cmd...
  local label=$1 input=$2; shift 2
  local r
  for r in $(seq 1 "$REPS"); do
    local s0 s1
    s0=$(date +%s%N)
    /usr/bin/time -f '%e %U %S %M' -o "$W/time.txt" "$@" > "$W/out.pclm" 2> /dev/null
    s1=$(date +%s%N)
    read -r e u s m < "$W/time.txt"
    e=$(echo "scale=4; ($s1 - $s0) / 1000000000" | bc)   # ns-resolution wall time (time(1) has 10 ms)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.1f\n' "$label" "$input" "$r" "$e" "$u" "$s" "$m" "$(stat -c %s "$W/out.pclm")" \
      "$(echo "$e * 1000 / $NP" | bc -l)" >> "$L/perf_raw.tsv"
  done
}
for t in 1 2 4 8; do
  bench "ours_threads$t" gray env PCLMS_THREADS=$t "$OURS" 1 u t 1 "" "$W/gray.ras"
done
bench ours_default gray "$OURS" 1 u t 1 "" "$W/gray.ras"
bench ours_threads4 rgb env PCLMS_THREADS=4 "$OURS" 1 u t 1 "" "$W/rgb.ras"
bench ours_threads1 rgb env PCLMS_THREADS=1 "$OURS" 1 u t 1 "" "$W/rgb.ras"
bench hpcups_3.26.6 rgb env PPD="$HP_PPD" LD_LIBRARY_PATH="$HPLIP_SRC/prnt/hpcups" "$HPCUPS" 1 u t 1 "" "$W/rgb.ras"
bench hpcups_distro rgb env PPD="$HP_PPD" "$HPCUPS_DISTRO" 1 u t 1 "" "$W/rgb.ras"

# median per configuration
python3 -I - "$L/perf_raw.tsv" "$NP" > "$L/perf_summary.tsv" <<'EOF'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t")); np_ = int(sys.argv[2])
groups = {}
for r in rows: groups.setdefault((r["filter"], r["input"]), []).append(r)
print("filter\tinput\tmedian_wall_s\tms_per_page\tmedian_user_s\tmax_rss_MB\tbytes_per_page")
for (f, i), g in groups.items():
    w = statistics.median(float(x["wall_s"]) for x in g)
    print("%s\t%s\t%.4f\t%.2f\t%.3f\t%.1f\t%d" % (f, i, w, w * 1000 / np_, statistics.median(float(x["user_s"]) for x in g),
          max(int(x["maxrss_kb"]) for x in g) / 1024, int(g[0]["out_bytes"]) // np_))
EOF
while IFS=$'\t' read -r f i w ms u rss bpp; do
  [ "$f" = filter ] && continue
  result perf "$f.$i" INFO "${ms} ms/page (median of $REPS, $NP pages), user ${u}s, maxRSS ${rss} MB, ${bpp} bytes/page"
done < "$L/perf_summary.tsv"

# per-page output size, ours vs HP on the same RGB raster
run_hp "$W/rgb.ras" "$W/hp.pclm" ""; run_ours "$W/rgb.ras" "$W/ours.pclm" ""
python3 -I - "$W/hp.pclm" "$W/ours.pclm" "$VMTESTS" > "$L/size_per_page.tsv" <<'EOF'
import sys
sys.path.insert(0, sys.argv[3]); import pclmtool as T
a, b = (T.analyze(open(p, "rb").read()) for p in sys.argv[1:3])
print("page\thp_rle_bytes\tours_rle_bytes\tratio")
for i, (x, y) in enumerate(zip(a["pages"], b["pages"])):
    print("%d\t%d\t%d\t%.3f" % (i + 1, x["rle_bytes"], y["rle_bytes"], y["rle_bytes"] / max(1, x["rle_bytes"])))
print("total\t%d\t%d\t%.3f" % (sum(p["rle_bytes"] for p in a["pages"]), sum(p["rle_bytes"] for p in b["pages"]),
      sum(p["rle_bytes"] for p in b["pages"]) / sum(p["rle_bytes"] for p in a["pages"])))
EOF
result perf output_size_vs_hp INFO "$(tail -1 "$L/size_per_page.tsv" | awk '{printf "total RLE bytes HP=%s ours=%s ratio=%s", $2, $3, $4}')"
[ "${KEEP:-0}" = 1 ] || rm -f "$W"/*.ras "$W"/*.pclm
