# SPDX-License-Identifier: MIT
# Shared helpers for the VM test suite.  Sourced by run_all.sh and the stage scripts.

: "${VMTESTS:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${DRV:=$(cd "$VMTESTS/../.." && pwd)}"
: "${OUT:=$HOME/m125-results/latest}"        # logs (small, copied back to the host)
: "${WORK:=$HOME/m125-work}"                 # big scratch files (rasters, outputs)
: "${HPLIP_SRC:=$HOME/hplip-build/hplip-3.26.6}"
: "${HPLIP_TARBALL:=$HOME/hplip-3.26.6.tar.gz}"
: "${HPCUPS:=$HPLIP_SRC/hpcups}"             # HP reference (built from 3.26.6)
: "${HPCUPS_DISTRO:=/usr/lib/cups/filter/hpcups}"
: "${HP_PPD:=$WORK/ppd/hp-laserjet_pro_mfp_m125r.ppd}"
: "${OUR_PPD:=$WORK/ppd/m125-pclms.ppd}"
: "${OURS:=$DRV/rastertopclms}"
: "${OURS_ASAN:=$WORK/bin/rastertopclms-asan}"
: "${OURS_TSAN:=$WORK/bin/rastertopclms-tsan}"
: "${DOCS:=$WORK/docs}"
PCLMTOOL="$VMTESTS/pclmtool.py"
VERIFY="$DRV/tests/verify_pclm.py"
export LC_ALL=C.UTF-8

mkdir -p "$OUT" "$WORK"
RESULTS="$OUT/results.tsv"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/run.log" >&2; }

# result STAGE NAME PASS|FAIL|INFO|SKIP "detail"
result() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"
  log "$3  $1/$2  $4"
}

pt() { python3 -I "$PCLMTOOL" "$@"; }

# json_get FILE python-expression-on-r  -> prints value
json_get() { python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# make_raster PPD DOC OUTRAS [cupsfilter -o options...]
make_raster() {
  local ppd=$1 doc=$2 ras=$3; shift 3
  local o=() x
  for x in "$@"; do o+=(-o "$x"); done
  cupsfilter -p "$ppd" -m application/vnd.cups-raster "${o[@]}" "$doc" > "$ras" 2> "$ras.cupsfilter.log"
}

# run_hp RAS OUT.pclm "options" [binary]
run_hp() {
  local bin=${4:-$HPCUPS}
  PPD="$HP_PPD" LD_LIBRARY_PATH="$HPLIP_SRC/prnt/hpcups" "$bin" 77 tester "m125 test" 1 "$3" "$1" > "$2" 2> "$2.stderr"
}

# run_ours RAS OUT.pclm "options" [binary]
run_ours() {
  local bin=${4:-$OURS}
  "$bin" 77 tester "m125 test" 1 "$3" "$1" > "$2" 2> "$2.stderr"
}
