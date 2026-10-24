#!/bin/bash
# SPDX-License-Identifier: MIT
#
# m125-pclms VM test suite - main entry point.  Run inside the Ubuntu 24.04 VM:
#
#   tests/vm/run_all.sh                 # all stages
#   tests/vm/run_all.sh golden robust   # selected stages
#
# Stages (in order): env build hpref docs golden options e2e robust perf
#
# Environment:
#   OUT=dir        where logs go          (default ~/m125-results/<date-time>)
#   WORK=dir       big scratch files      (default ~/m125-work)
#   HPCUPS=path    HP reference filter    (default: hpcups built from HPLIP 3.26.6)
#   QUICK=1        smaller matrices (A4/Letter only, fewer repeats)
#   KEEP=1         keep all .pclm/.ras files under $WORK
#
# Every check appends a line "stage<TAB>name<TAB>PASS|FAIL|INFO|SKIP<TAB>detail" to
# $OUT/results.tsv; the summary at the end counts them.  Exit code = number of FAILs (max 99).

set -u
export OUT="${OUT:-$HOME/m125-results/$(date +%Y%m%d-%H%M%S)}"
VMTESTS="$(cd "$(dirname "$0")" && pwd)"
export VMTESTS
. "$VMTESTS/lib.sh"

ALL=(env build hpref docs golden options e2e robust perf)
STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=("${ALL[@]}")

: > "$RESULTS"
log "m125-pclms VM tests: stages=${STAGES[*]} OUT=$OUT WORK=$WORK DRV=$DRV"

for s in "${STAGES[@]}"; do
  f="$VMTESTS/stage_$s.sh"
  if [ ! -f "$f" ]; then log "unknown stage $s"; continue; fi
  log "===== stage $s ====="
  t0=$(date +%s)
  bash "$f" > "$OUT/stage_$s.log" 2>&1
  rc=$?
  log "===== stage $s done rc=$rc ($(( $(date +%s) - t0 ))s) ====="
done

# summary
{
  echo "== summary =="
  awk -F'\t' '{c[$3]++} END {for (k in c) printf "%s %d\n", k, c[k]}' "$RESULTS" | sort
  echo
  echo "== FAIL lines =="
  awk -F'\t' '$3=="FAIL"' "$RESULTS"
} | tee "$OUT/summary.txt"
nf=$(awk -F'\t' '$3=="FAIL"' "$RESULTS" | wc -l)
[ "$nf" -gt 99 ] && nf=99
exit "$nf"
