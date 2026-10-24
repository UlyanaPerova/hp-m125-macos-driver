# SPDX-License-Identifier: MIT
# Stage e2e: install the driver, print through real CUPS queues with file: devices.
. "$VMTESTS/lib.sh"
set -x
L="$OUT/e2e"; W="$WORK/e2e"; mkdir -p "$L" "$W"
cd "$DRV" || exit 1
sudo make install > "$L/make_install.log" 2>&1 && result e2e make_install PASS "$(grep -E '^install -m|gzip' "$L/make_install.log" | tr '\n' ' ' | head -c 300)" ||
  { result e2e make_install FAIL "see e2e/make_install.log"; exit 1; }
IPPD="/usr/share/ppd/m125-pclms/HP LaserJet Pro MFP M125r PCLmS.gz"
lpinfo -m 2>/dev/null | grep -i 'm125' > "$L/lpinfo_m.txt"
grep -q 'm125-pclms' "$L/lpinfo_m.txt" && result e2e lpinfo_lists_ppd PASS "$(grep m125-pclms "$L/lpinfo_m.txt" | head -1)" ||
  result e2e lpinfo_lists_ppd FAIL "installed PPD not listed by lpinfo -m"

grep -q '^FileDevice Yes' /etc/cups/cups-files.conf || echo 'FileDevice Yes' | sudo tee -a /etc/cups/cups-files.conf > /dev/null
sudo cupsctl --debug-logging
sudo systemctl restart cups; sleep 2
sudo truncate -s 0 /var/log/cups/error_log
sudo cancel -a -x 2>/dev/null
for q in m125ours m125hp; do sudo lpadmin -x $q 2>/dev/null; done
sudo lpadmin -p m125ours -E -v file:///tmp/out-ours.pclm -P "$IPPD" 2> "$L/lpadmin_ours.txt"
sudo lpadmin -p m125hp   -E -v file:///tmp/out-hp.pclm   -P "$HP_PPD" 2> "$L/lpadmin_hp.txt"
# HP's PPD defaults to Letter, ours to A4: give the HP queue the same default so outputs compare
sudo lpadmin -p m125hp -o PageSize=A4 -o PageRegion=A4
result e2e default_pagesize INFO "PPD defaults differ: ours *DefaultPageSize A4, HP Letter (HP queue set to A4 for comparison)"
lpstat -v > "$L/lpstat_v.txt"

# job name | document | lp options | expected pages
JOBS=(
  "multipage|text.pdf||3"
  "copies3|testpage.pdf|-n 3|6"
  "copies2_collate|text.pdf|-n 2 -o collate=true|6"
  "landscape|text.pdf|-o landscape|3"
  "landscape_doc|landscape.pdf||1"
  "letter|testpage.pdf|-o PageSize=Letter|2"
  "legal|testpage.pdf|-o PageSize=Legal|2"
  "a5|testpage.pdf|-o media=A5|2"
  "envdl|testpage.pdf|-o PageSize=EnvDL|2"
  "custom|testpage.pdf|-o PageSize=Custom.300x500|2"
  "options|testpage.pdf|-o EconoMode=True -o OutputMode=Draft -o InputSlot=Manual -o MediaType=Heavy|2"
  "plaintext|plain.txt||-"
  "pages_range|long50.pdf|-o page-ranges=2-4|3"
)
wait_job() {  # queue
  local i
  for i in $(seq 1 240); do
    [ -z "$(lpstat -o "$1" 2>/dev/null)" ] && return 0
    sleep 0.5
  done
  return 1
}
printf 'job\tqueue\texpected\tpages\tverify\terrors\n' > "$L/summary.tsv"
for j in "${JOBS[@]}"; do
  IFS='|' read -r name doc opts exp <<< "$j"
  for q in m125ours m125hp; do
    f=/tmp/out-${q#m125}.pclm
    # CUPS 2.4 opens file: device URIs with O_WRONLY|O_EXCL (no O_CREAT, no O_TRUNC):
    # the file must already exist and must be emptied before every job.
    sudo install -m 644 -o root -g root /dev/null "$f"
    # shellcheck disable=SC2086
    id=$(lp -d $q $opts -t "e2e-$name" "$DOCS/$doc" 2>&1)
    if ! wait_job $q; then
      result e2e "$name.$q" FAIL "job did not finish in 120 s: $id"
      sudo cancel -a -x $q; sudo cupsenable $q
    fi
    sleep 0.3
    st=$(lpstat -W completed -o $q 2>/dev/null | tail -1)
    sudo cp "$f" "$W/${name}_$q.pclm" 2>/dev/null; sudo chown "$USER" "$W/${name}_$q.pclm" 2>/dev/null
    if [ ! -s "$W/${name}_$q.pclm" ]; then
      result e2e "$name.$q" FAIL "no output ($id)"; continue
    fi
    pt info "$W/${name}_$q.pclm" > "$L/${name}_$q.info.json"; ok=$?
    np=$(json_get "$L/${name}_$q.info.json" 'len(r["pages"])')
    python3 -I "$VERIFY" "$W/${name}_$q.pclm" > "$L/${name}_$q.verify.txt" 2>&1; vr=$?
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$q" "$exp" "$np" "$vr" "$(json_get "$L/${name}_$q.info.json" 'r["errors"][:2]')" >> "$L/summary.tsv"
    if [ "$q" = m125ours ]; then
      if [ $ok -eq 0 ] && [ $vr -eq 0 ] && { [ "$exp" = - ] || [ "$np" = "$exp" ]; }; then
        result e2e "$name" PASS "$np page(s), valid PCLm ($opts)"
      else
        result e2e "$name" FAIL "pages=$np expected=$exp pclmtool_rc=$ok verify_rc=$vr ($opts)"
      fi
    fi
  done
  # compare with HP queue output
  if [ -s "$W/${name}_m125ours.pclm" ] && [ -s "$W/${name}_m125hp.pclm" ]; then
    pt struct --mask "$W/${name}_m125hp.pclm" > "$W/h.txt"; pt struct --mask "$W/${name}_m125ours.pclm" > "$W/o.txt"
    diff "$W/h.txt" "$W/o.txt" > "$L/${name}.struct_vs_hp.diff"; sd=$(grep -c '^[<>]' "$L/${name}.struct_vs_hp.diff")
    pt cmp "$W/${name}_m125hp.pclm" "$W/${name}_m125ours.pclm" > "$L/${name}.pixels_vs_hp.json"
    px=$(json_get "$L/${name}.pixels_vs_hp.json" '"pages %d/%d diff_px=%d max=%d" % (r["pages_a"], r["pages_b"], r["total_diff_pixels"], r["max_abs_diff"])')
    [ "$sd" = 0 ] && result e2e "$name.vs_hp" PASS "structure identical to HP queue; $px" ||
      result e2e "$name.vs_hp" FAIL "$sd struct diff lines vs HP queue (e2e/$name.struct_vs_hp.diff); $px"
  fi
done
cp "$W/multipage_m125ours.pclm" "$OUT/samples/e2e_multipage_ours.pclm" 2>/dev/null

sudo cp /var/log/cups/error_log "$L/cups_error_log.txt"; sudo chown "$USER" "$L/cups_error_log.txt"
grep -E 'rastertopclms' "$L/cups_error_log.txt" > "$L/our_filter_lines.txt"
ne=$(grep -E '^E |\[Job [0-9]+\] (ERROR|WARNING): rastertopclms|rastertopclms.*(ERROR|WARNING)' "$L/cups_error_log.txt" | grep -c rastertopclms)
[ "$ne" -eq 0 ] && result e2e error_log PASS "no ERROR/WARNING lines from rastertopclms in error_log" ||
  result e2e error_log FAIL "$ne ERROR/WARNING lines from rastertopclms (e2e/cups_error_log.txt)"
grep -E 'Job [0-9]+.*(stopped|aborted|failed|crashed)|exited on signal|stopped with status' "$L/cups_error_log.txt" > "$L/job_failures.txt"
[ -s "$L/job_failures.txt" ] && result e2e job_failures INFO "$(wc -l < "$L/job_failures.txt") failure lines (see e2e/job_failures.txt)" ||
  result e2e job_failures PASS "no stopped/failed jobs"
lpstat -p m125ours | grep -q 'disabled' && result e2e queue_state FAIL "queue got disabled" || result e2e queue_state PASS "$(lpstat -p m125ours | head -1)"
sudo cupsctl --no-debug-logging
