# SPDX-License-Identifier: MIT
# Stage options: job-ticket values for PPD options, ours vs HP.
. "$VMTESTS/lib.sh"
set -x
L="$OUT/options"; W="$WORK/options"; mkdir -p "$L" "$W"
DOC="$DOCS/text.pdf"
printf 'options\tticket_diffs\tstruct_diff_lines\tours: media-type|media-source|print-quality|printer-resolution\n' > "$L/summary.tsv"
CASES=(
  "OutputMode=FastRes600" "OutputMode=FastRes1200" "OutputMode=Draft"
  "EconoMode=True" "EconoMode=True OutputMode=FastRes1200"
  "InputSlot=Manual" "InputSlot=tray1"
  "MediaType=Plain" "MediaType=Light" "MediaType=Mid-Weight" "MediaType=Heavy" "MediaType=ExtraHeavy"
  "MediaType=Transparency" "MediaType=Labels" "MediaType=Letterhead" "MediaType=Envelope"
  "MediaType=Preprinted" "MediaType=Prepunched" "MediaType=Colored" "MediaType=Bond"
  "MediaType=Recycled" "MediaType=Rough"
  "InputSlot=Manual MediaType=Envelope PageSize=EnvDL EconoMode=True"
)
for opts in "${CASES[@]}"; do
  n=$(echo "$opts" | tr ' =' '_-'); d="$W/$n"; mkdir -p "$d"
  # shellcheck disable=SC2086
  make_raster "$HP_PPD"  "$DOC" "$d/hp.ras"   PageSize=A4 $opts
  # shellcheck disable=SC2086
  make_raster "$OUR_PPD" "$DOC" "$d/ours.ras" PageSize=A4 $opts
  run_hp "$d/hp.ras" "$d/hp.pclm" "$opts"; run_ours "$d/ours.ras" "$d/ours.pclm" "$opts"
  pt ticketdiff "$d/hp.pclm" "$d/ours.pclm" > "$L/$n.ticketdiff.json"
  pt struct --mask "$d/hp.pclm" > "$d/hp.txt"; pt struct --mask "$d/ours.pclm" > "$d/ours.txt"
  diff "$d/hp.txt" "$d/ours.txt" > "$L/$n.struct.diff"; sd=$(grep -c '^[<>]' "$L/$n.struct.diff")
  sed -n '/PCLmS-Job-Ticket$/,/Ticket-End/p' "$d/ours.txt" | head -25 > "$L/$n.ticket_ours.txt"
  sed -n '/PCLmS-Job-Ticket$/,/Ticket-End/p' "$d/hp.txt" | head -25 > "$L/$n.ticket_hp.txt"
  td=$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print("; ".join(sorted({"%s: hp=%s ours=%s"%(d["key"],d["a"],d["b"]) for d in r["diffs"] if d["key"]!="job-start-time"})) or "none")' "$L/$n.ticketdiff.json")
  tv=$(grep -E 'media-type|media-source|print-quality|printer-resolution' "$L/$n.ticket_ours.txt" | awk '{print $NF}' | tr '\n' '|')
  printf '%s\t%s\t%s\t%s\n' "$opts" "$td" "$sd" "$tv" >> "$L/summary.tsv"
  [ "$td" = none ] && [ "$sd" = 0 ] && result options "$n" PASS "ticket $tv identical to HP" ||
    result options "$n" FAIL "ticket diffs: $td; struct diff lines $sd"
  rm -f "$d"/*.ras
done
# HP-only media types (not in our PPD): record what HP sends
for mt in Auto HPEcoSMARTLite Vellum; do
  d="$W/hponly_$mt"; mkdir -p "$d"
  make_raster "$HP_PPD" "$DOC" "$d/hp.ras" PageSize=A4 MediaType=$mt
  run_hp "$d/hp.ras" "$d/hp.pclm" ""
  result options "hp_only_MediaType_$mt" INFO "HP PPD has it, ours not; HP ticket: $(grep -a -m1 'media-type:' "$d/hp.pclm" | tr -d '%')"
  rm -f "$d"/*.ras
done
