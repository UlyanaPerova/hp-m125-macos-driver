# SPDX-License-Identifier: MIT
# Stage robust: bad / unusual input, signals, valgrind, ASan+UBSan, TSan, determinism.
. "$VMTESTS/lib.sh"
set -x
L="$OUT/robust"; W="$WORK/robust"; mkdir -p "$L" "$W"
cd "$W" || exit 1
printf 'case\tbinary\texpect\trc\tsignal\tsanitizer\tpclm_valid\tpages\tsecs\tnote\n' > "$L/summary.tsv"

# rcase NAME ok|fail INPUTFILE|stdin:FILE|none [rascheck]
rcase() {
  local name=$1 expect=$2 input=$3 check=${4:-}
  local bin tag rc t0 t1 san valid pages note out
  for tag in release asan; do
    bin=$OURS; [ $tag = asan ] && bin=$OURS_ASAN
    out="$W/$name.$tag.pclm"
    t0=$(date +%s.%N)
    case "$input" in
      stdin:*) timeout -s KILL 120 env ASAN_OPTIONS=detect_leaks=1:abort_on_error=0 UBSAN_OPTIONS=print_stacktrace=1 \
                 "$bin" 9 tester robust 1 "" < "${input#stdin:}" > "$out" 2> "$L/$name.$tag.stderr" ;;
      none)    timeout -s KILL 120 "$bin" 9 tester robust 1 > "$out" 2> "$L/$name.$tag.stderr" ;;
      *)       timeout -s KILL 120 env ASAN_OPTIONS=detect_leaks=1:abort_on_error=0 UBSAN_OPTIONS=print_stacktrace=1 \
                 "$bin" 9 tester robust 1 "" "$input" > "$out" 2> "$L/$name.$tag.stderr" ;;
    esac
    rc=$?
    t1=$(date +%s.%N)
    san=$(grep -cE 'ERROR: (Address|Leak)Sanitizer|runtime error:' "$L/$name.$tag.stderr")
    pt info "$out" > "$L/$name.$tag.info.json" 2>/dev/null; valid=$?
    pages=$(json_get "$L/$name.$tag.info.json" 'len(r["pages"])' 2>/dev/null)
    note=""
    if [ -n "$check" ] && [ $rc -eq 0 ]; then
      pt rascheck "$out" "$check" > "$L/$name.$tag.rascheck.json" 2>&1 && note="pixels==raster" || note="PIXEL MISMATCH"
    fi
    sig=""; [ $rc -gt 128 ] && sig="SIG$(kill -l $((rc-128)) 2>/dev/null)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.2f\t%s\n' "$name" "$tag" "$expect" "$rc" "$sig" "$san" \
      "$([ $valid -eq 0 ] && echo yes || echo no)" "$pages" "$(echo "$t1 - $t0" | bc)" "$note" >> "$L/summary.tsv"
    local verdict=PASS why=""
    [ -n "$sig" ] && { verdict=FAIL; why="crashed/killed ($sig) "; }
    [ "$san" -gt 0 ] && { verdict=FAIL; why="${why}sanitizer report: $(grep -m1 -E 'ERROR: |runtime error:' "$L/$name.$tag.stderr" | head -c 160) "; }
    [ $expect = ok ] && [ $rc -ne 0 ] && { verdict=FAIL; why="${why}rc=$rc on valid input "; }
    [ $expect = fail ] && [ $rc -eq 0 ] && { verdict=FAIL; why="${why}rc=0 on bad input "; }
    [ $expect = any ] && [ $rc -ne 0 ] && [ $rc -ne 1 ] && { verdict=FAIL; why="${why}unexpected rc=$rc "; }
    [ $expect = ok ] && [ $valid -ne 0 ] && { verdict=FAIL; why="${why}invalid PCLm: $(json_get "$L/$name.$tag.info.json" 'r["errors"][:2]' 2>/dev/null) "; }
    [ "$note" = "PIXEL MISMATCH" ] && { verdict=FAIL; why="${why}pixels differ from raster "; }
    result robust "$name.$tag" $verdict "rc=$rc pages=$pages valid=$([ $valid -eq 0 ] && echo yes || echo no) $note $why$(grep -m1 -E '^ERROR' "$L/$name.$tag.stderr" | head -c 120)"
    [ "${KEEP:-0}" = 1 ] || rm -f "$out"
  done
}

# ---------- inputs ----------
make_raster "$OUR_PPD" "$DOCS/testpage.pdf" two.ras PageSize=A4
make_raster "$OUR_PPD" "$DOCS/long50.pdf" fifty.ras PageSize=A4
: > empty.ras
head -c 1048576 /dev/urandom > garbage.bin
{ printf 'RaS3'; head -c 200000 /dev/urandom; } > sync_garbage.ras
{ printf '3SaR'; head -c 200000 /dev/urandom; } > sync_garbage_le.ras
P=$(( (4 + 1796) ))
BPL=$(json_get <(pt rasinfo two.ras) 'r["pages"][0]["cupsBytesPerLine"]')
H=$(json_get <(pt rasinfo two.ras) 'r["pages"][0]["cupsHeight"]')
head -c 1000 two.ras > trunc_header.ras
head -c $(( P + BPL * H / 2 )) two.ras > trunc_mid_page1.ras
head -c $(( P + BPL * H + 1796 + BPL * H / 3 )) two.ras > trunc_mid_page2.ras
head -c $(( P + BPL * H + 900 )) two.ras > trunc_page2_header.ras

gsras() {  # name colorspace bits [res]
  gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=cups -r"${4:-600}" -dcupsColorSpace="$2" -dcupsBitsPerColor="$3" \
     -sPAPERSIZE=a4 -sOutputFile="$1" "$DOCS/testpage.pdf" > "$1.gs.log" 2>&1
}
gsras gs_w1.ras 0 1; gsras gs_k1.ras 3 1; gsras gs_w8.ras 0 8; gsras gs_k8.ras 3 8
gsras gs_w16.ras 0 16; gsras gs_k16.ras 3 16; gsras gs_rgb8.ras 1 8; gsras gs_srgb8.ras 19 8; gsras gs_rgbw8.ras 17 8; gsras gs_rgba8.ras 2 8
gsras gs_rgb16.ras 1 16; gsras gs_cmyk8.ras 6 8; gsras gs_w8_300.ras 0 8 300; gsras gs_w8_1200.ras 0 8 1200
for f in gs_*.ras; do pt rasinfo "$f" > "$L/rasinfo_$f.json" 2>&1; done

# crafted headers (pclmtool mkras, big-endian v3)
pt mkras hdr_width0.ras cupsWidth=0 cupsBytesPerLine=0
pt mkras hdr_height0.ras cupsHeight=0
pt mkras hdr_res0.ras HWResolution=0,0
pt mkras hdr_res7.ras HWResolution=7,7
pt mkras hdr_res_nonsquare.ras HWResolution=600,300
pt mkras hdr_bpl_mismatch.ras cupsBytesPerLine=50
pt mkras hdr_bpp24_gray.ras cupsBitsPerPixel=24 cupsBytesPerLine=600
pt mkras hdr_rgb_banded.ras cupsColorSpace=1 cupsBitsPerColor=8 cupsBitsPerPixel=8 cupsColorOrder=1 cupsNumColors=3
pt mkras hdr_pagesize0.ras PageSize=0,0 ImagingBoundingBox=0,0,0,0 Margins=0,0
pt mkras hdr_bbox_inverted.ras ImagingBoundingBox=581,828,14,14
pt mkras hdr_bbox_above_page.ras ImagingBoundingBox=14,14,581,5000
pt mkras hdr_margin_huge.ras Margins=4000000,14
pt mkras hdr_wide_raster.ras cupsWidth=20000 PageSize=595,842
pt mkras hdr_tall_page.ras PageSize=595,100000 ImagingBoundingBox=14,14,581,828
pt mkras hdr_huge_pagewidth.ras PageSize=3000000,842 ImagingBoundingBox=0,0,0,0
pt mkras hdr_int_overflow_pagesize.ras PageSize=4294967295,842
pt mkras hdr_noData.ras data=none
pt mkras hdr_random_data_ok.ras data=random cupsWidth=4725 cupsHeight=600
pt mkras hdr_many_pages.ras pages=300 cupsHeight=10 cupsWidth=100

# ---------- cases ----------
rcase empty_file fail empty.ras
rcase empty_stdin fail stdin:empty.ras
rcase missing_file fail /nonexistent/file.ras
rcase garbage fail garbage.bin
rcase sync_then_garbage_be fail sync_garbage.ras
rcase sync_then_garbage_le fail sync_garbage_le.ras
rcase truncated_header fail trunc_header.ras
rcase truncated_mid_page1 fail trunc_mid_page1.ras
rcase truncated_mid_page2 fail trunc_mid_page2.ras
rcase truncated_page2_header fail trunc_page2_header.ras
rcase valid_2page_file ok two.ras two.ras
rcase valid_2page_stdin ok stdin:two.ras
for f in w1 k1 w8 k8 w16 k16 rgb8 srgb8 rgba8 rgb16 w8_300 w8_1200; do rcase "gs_$f" ok "gs_$f.ras" "gs_$f.ras"; done
rcase gs_cmyk8_unsupported fail gs_cmyk8.ras
rcase gs_rgbw8 ok gs_rgbw8.ras gs_rgbw8.ras
for f in hdr_*.ras; do
  n=${f%.ras}
  case $n in
    hdr_res_nonsquare|hdr_bbox_inverted|hdr_pagesize0|hdr_wide_raster|hdr_random_data_ok|hdr_many_pages) e=ok ;;
    # round 2: check_header() rejects page size / margins / bbox > 3000 pt
    hdr_bbox_above_page|hdr_margin_huge|hdr_tall_page|hdr_huge_pagewidth|hdr_int_overflow_pagesize) e=fail ;;
    *) e=fail ;;
  esac
  rcase "$n" $e "$f"
done
"$OURS" 1 2 3 > /dev/null 2> "$L/argc_wrong.stderr"; rc=$?
[ $rc -ne 0 ] && result robust argc_wrong PASS "rc=$rc: $(head -1 "$L/argc_wrong.stderr")" || result robust argc_wrong FAIL "rc=0"

# 50-page job
rcase fifty_pages ok fifty.ras
pages=$(json_get "$L/fifty_pages.release.info.json" 'len(r["pages"])')
[ "$pages" = 50 ] && result robust fifty_pages_count PASS "50 pages" || result robust fifty_pages_count FAIL "pages=$pages"

# ---------- determinism across thread counts ----------
for t in 1 2 3 4 8 16 64; do
  for rep in 1 2 3; do
    PCLMS_THREADS=$t "$OURS" 1 u t 1 "" fifty.ras > det.pclm 2>/dev/null; pt digest det.pclm
  done
done > "$L/threads_md5.txt"
[ "$(sort -u "$L/threads_md5.txt" | wc -l)" = 1 ] && result robust thread_determinism PASS "identical output (masked structure + all stream bytes) for PCLMS_THREADS=1,2,3,4,8,16,64, 3 runs each" ||
  result robust thread_determinism FAIL "output depends on thread count (robust/threads_md5.txt)"

# ---------- SIGTERM ----------
# term_check NAME BIN DELAY INPUTSPEC : starts the filter, sends SIGTERM after DELAY s, checks
#   rc (expected 1), exit latency (< 1 s), and the file: after a mid-page cancel it must be valid
#   PCLm; after a cancel between pages the filter _exit(1)s by design (file may lack a trailer).
term_check() {
  local name=$1 bin=$2 delay=$3 spec=$4 out="$W/term_$1.pclm" rc t0 t1 dt v path verdict why=""
  case "$spec" in
    file:*)  "$bin" 1 u t 1 "" "${spec#file:}" > "$out" 2> "$L/sigterm_$name.stderr" & ;;
    stall:*) ( head -c "${spec#stall:}" two.ras; sleep 4; tail -c +$(( ${spec#stall:} + 1 )) two.ras ) |
               "$bin" 1 u t 1 "" > "$out" 2> "$L/sigterm_$name.stderr" & ;;
  esac
  local pid=$!
  sleep "$delay"
  local alive=1
  [ "$(awk '{print $3}' /proc/$pid/stat 2>/dev/null)" = Z ] || [ ! -e /proc/$pid ] && alive=0
  kill -TERM $pid 2>/dev/null; t0=$(date +%s.%N)
  # measure when the filter itself exits ('wait' on a pipeline member waits for the whole pipeline)
  local n=0
  while [ -e /proc/$pid ] && [ "$(awk '{print $3}' /proc/$pid/stat 2>/dev/null)" != Z ] && [ $n -lt 2000 ]; do
    sleep 0.005; n=$((n + 1))
  done
  t1=$(date +%s.%N)
  wait $pid; rc=$?
  dt=$(echo "$t1 - $t0" | bc); dt=$(printf '%.3f' "$dt")
  pt info "$out" > "$L/sigterm_$name.info.json" 2>/dev/null; v=$?
  python3 -I "$VERIFY" "$out" > "$L/sigterm_$name.verify.txt" 2>&1; vr=$?
  grep -q Traceback "$L/sigterm_$name.verify.txt" && why="verify_pclm.py crashed "
  if grep -q 'job canceled' "$L/sigterm_$name.stderr"; then path=mid-page; else path=between-pages; fi
  if [ $alive = 0 ]; then
    result robust "sigterm_$name" INFO "filter had already finished before SIGTERM was sent (rc=$rc, pages=$(json_get "$L/sigterm_$name.info.json" 'len(r["pages"])' 2>/dev/null)); not a cancel test"
    rm -f "$out"; return
  fi
  verdict=PASS
  [ $rc -ne 1 ] && { verdict=FAIL; why="${why}rc=$rc (expected 1) "; }
  awk -v d="$dt" 'BEGIN{exit !(d>1)}' && { verdict=FAIL; why="${why}slow exit ${dt}s "; }
  [ $path = mid-page ] && [ $v -ne 0 ] && { verdict=FAIL; why="${why}invalid file after mid-page cancel: $(json_get "$L/sigterm_$name.info.json" 'r["errors"][:1]' 2>/dev/null) "; }
  [ -n "$why" ] && [ $verdict = PASS ] && verdict=FAIL
  result robust "sigterm_$name" $verdict "path=$path rc=$rc exit ${dt}s after SIGTERM; file valid=$([ $v -eq 0 ] && echo yes || echo no) pages=$(json_get "$L/sigterm_$name.info.json" 'len(r["pages"])' 2>/dev/null) verify_pclm rc=$vr; $why$(grep -m1 -E 'INFO: rastertopclms: job canceled' "$L/sigterm_$name.stderr")"
  [ $path = between-pages ] && [ $v -ne 0 ] && result robust "sigterm_${name}_file" INFO "cancel between pages: filter _exit(1)s without trailer (by design); pclmtool: $(json_get "$L/sigterm_$name.info.json" 'r["errors"][:1]' 2>/dev/null); verify_pclm rc=$vr"
  rm -f "$out"
}
for dly in 0.05 0.1 0.2 0.3 0.5; do term_check "busy_$dly" "$OURS" $dly file:fifty.ras; done
term_check busy_asan_0.3 "$OURS_ASAN" 0.3 file:fifty.ras
term_check blocked_midpage "$OURS" 1.5 stall:$(( P + BPL * H / 2 ))
term_check blocked_midpage_asan "$OURS_ASAN" 1.5 stall:$(( P + BPL * H / 2 ))
term_check blocked_between_pages "$OURS" 1.5 stall:$(( P + BPL * H ))

# ---------- valgrind ----------
valgrind --tool=memcheck --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible \
  --track-origins=yes --error-exitcode=99 --log-file="$L/valgrind_2page.txt" "$OURS" 1 u t 1 "" two.ras > vg.pclm 2>/dev/null; rc=$?
es=$(grep -o 'ERROR SUMMARY: [0-9]*' "$L/valgrind_2page.txt" | awk '{print $3}')
lk=$(grep -E 'definitely lost|indirectly lost|possibly lost|still reachable' "$L/valgrind_2page.txt" | sed 's/==[0-9]*==//' | tr -s ' ' | tr '\n' ';')
[ "$rc" -eq 0 ] && [ "$es" = 0 ] && result robust valgrind_2page PASS "0 errors; $lk" || result robust valgrind_2page FAIL "rc=$rc errors=$es; $lk"
valgrind --tool=memcheck --leak-check=full --error-exitcode=99 --log-file="$L/valgrind_truncated.txt" "$OURS" 1 u t 1 "" trunc_mid_page1.ras > /dev/null 2>&1; rc=$?
es=$(grep -o 'ERROR SUMMARY: [0-9]*' "$L/valgrind_truncated.txt" | awk '{print $3}')
[ "$es" = 0 ] && result robust valgrind_truncated PASS "0 errors (rc=$rc)" || result robust valgrind_truncated FAIL "errors=$es"
PCLMS_THREADS=4 valgrind --tool=helgrind --error-exitcode=99 --log-file="$L/helgrind_2page.txt" "$OURS" 1 u t 1 "" two.ras > /dev/null 2>&1; rc=$?
es=$(grep -o 'ERROR SUMMARY: [0-9]*' "$L/helgrind_2page.txt" | awk '{print $3}')
result robust helgrind_2page "$([ "$es" = 0 ] && echo PASS || echo INFO)" "helgrind errors=$es (see robust/helgrind_2page.txt)"

# ---------- TSan ----------
for t in 2 8; do
  PCLMS_THREADS=$t TSAN_OPTIONS=halt_on_error=0 setarch "$(uname -m)" -R "$OURS_TSAN" 1 u t 1 "" fifty.ras > /dev/null 2> "$L/tsan_threads$t.txt"; rc=$?
  n=$(grep -c 'WARNING: ThreadSanitizer' "$L/tsan_threads$t.txt")
  [ "$n" = 0 ] && [ $rc -eq 0 ] && result robust "tsan_threads$t" PASS "no data races (50 pages)" ||
    result robust "tsan_threads$t" FAIL "rc=$rc, $n ThreadSanitizer warnings (robust/tsan_threads$t.txt)"
done
[ "${KEEP:-0}" = 1 ] || rm -f "$W"/*.ras "$W"/*.pclm
