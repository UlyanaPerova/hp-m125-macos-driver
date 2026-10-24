#!/bin/bash
# Runs on a GitHub macOS runner AFTER "Install HP M125r Driver.pkg" was installed.
# Exercises the real macOS print pipeline (cgpdftoraster -> our filter, and cupsd).
# Usage: macos/ci/smoke_test.sh <log dir>
# SPDX-License-Identifier: MIT
set -uo pipefail
cd "$(dirname "$0")/../.."
LOGS="${1:-ci-logs}"; mkdir -p "$LOGS"
BASE="/Library/Printers/m125-pclms"
FILTER="$BASE/Filters/rastertopclms"
PPD="/Library/Printers/PPDs/Contents/Resources/HP LaserJet Pro MFP M125r PCLmS.gz"
FAIL=0
pass() { echo "PASS: $*" | tee -a "$LOGS/summary.txt"; }
fail() { echo "FAIL: $*" | tee -a "$LOGS/summary.txt"; FAIL=1; }
check() { local name="$1"; shift; if "$@" >>"$LOGS/detail.log" 2>&1; then pass "$name"; else fail "$name"; fi; }

{ sw_vers; uname -m; sysctl -n machdep.cpu.brand_string; sysctl hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu 2>/dev/null; cups-config --version; } > "$LOGS/environment.txt" 2>&1
cat "$LOGS/environment.txt"

# 1. installed files, ownership, signatures
check "package receipt"        pkgutil --pkg-info org.m125-pclms.driver
check "filter installed"       test -x "$FILTER"
check "filter owned by root"   test "$(stat -f '%Su:%Sg' "$FILTER")" = "root:wheel"
check "filter not writable by others" test -z "$(find "$FILTER" -perm -0002)"
check "filter signature valid" codesign --verify --strict --verbose=2 "$FILTER"
check "filter is universal"    sh -c "lipo -archs '$FILTER' | grep -q arm64 && lipo -archs '$FILTER' | grep -q x86_64"
check "PPD installed"          test -f "$PPD"
check "PPD passes cupstestppd" sh -c "gunzip -c '$PPD' > '$LOGS/installed.ppd' && cupstestppd -W none '$LOGS/installed.ppd'"
check "apps installed"         test -d "/Applications/HP M125r Driver/Set Up Printer.app" -a -d "/Applications/HP M125r Driver/Uninstall.app"
check "app signatures valid"   codesign --verify --deep --strict "/Applications/HP M125r Driver/Set Up Printer.app"
check "legal docs installed"   test -f "$BASE/PRIVACY.md" -a -f "$BASE/TERMS.md" -a -f "$BASE/LICENSE"
cp /Library/Logs/m125-pclms-install.log "$LOGS/" 2>/dev/null
check "postinstall ran"        grep -q "postinstall: setup-queue exit" /Library/Logs/m125-pclms-install.log
otool -L "$FILTER" > "$LOGS/linked-libraries.txt"
check "links only system libraries" sh -c "! grep -vE '^\S|/usr/lib/|/System/Library/' '$LOGS/linked-libraries.txt'"

# 2. macOS raster pipeline: PDF -> cgpdftoraster -> raster, then our filter
python3 -I tests/make_testpdf.py "$LOGS/test-a4.pdf" --pages 3
python3 -I tests/make_testpdf.py "$LOGS/test-letter.pdf" --pages 1 --size letter
T=$(mktemp -d)
check "macOS makes raster from PDF with our PPD" sh -c "cupsfilter -p '$PPD' -m application/vnd.cups-raster '$LOGS/test-a4.pdf' > '$T/a4.ras' 2>'$LOGS/cupsfilter-raster.log'"
check "filter converts macOS raster" sh -c "'$FILTER' 7 runner test 1 '' '$T/a4.ras' > '$T/a4.pclm' 2>'$LOGS/filter-direct.log'"
check "output valid + pixel-exact vs raster" python3 -I tests/verify_pclm.py "$T/a4.pclm" --raster "$T/a4.ras" --json
python3 -I tests/verify_pclm.py "$T/a4.pclm" --raster "$T/a4.ras" --json > "$LOGS/verify-a4.json" 2>&1
check "3 pages in output" sh -c "test \$(grep -c 'PCLmS-Job-Ticket-End' '$T/a4.pclm') -eq 3"
head -c 4000 "$T/a4.pclm" | LC_ALL=C tr -c '[:print:]\n' '.' > "$LOGS/a4-header-sample.txt"

# 3. full chain the way printing uses it (cupsfilter picks our filter from the PPD)
check "full chain PDF -> PCLm-S" sh -c "cupsfilter -p '$PPD' '$LOGS/test-a4.pdf' > '$T/chain.pclm' 2>'$LOGS/cupsfilter-chain.log'"
check "full chain output valid" python3 -I tests/verify_pclm.py "$T/chain.pclm"
for opt in "PageSize=Letter" "PageSize=A5" "PageSize=Legal" "EconoMode=True" "InputSlot=Manual" "OutputMode=Draft" "MediaType=Heavy"; do
  check "option $opt" sh -c "cupsfilter -p '$PPD' -o '$opt' '$LOGS/test-letter.pdf' > '$T/opt.pclm' 2>>'$LOGS/cupsfilter-options.log' && python3 -I tests/verify_pclm.py '$T/opt.pclm' >/dev/null"
  grep -a -E 'media-size-name|media-type|media-source|print-quality' "$T/opt.pclm" | sed "s/^/$opt: /" >> "$LOGS/option-tickets.txt"
done
check "Letter -> na_letter" grep -q "PageSize=Letter: %      media-size-name: na_letter_8.5x11in" "$LOGS/option-tickets.txt"
check "EconoMode -> draft" grep -q "EconoMode=True: %      print-quality: draft" "$LOGS/option-tickets.txt"
check "Manual feed -> manual" grep -q "InputSlot=Manual: %      media-source: manual" "$LOGS/option-tickets.txt"

# 4. through the real cupsd (sandboxed filter run), printing to a file
sudo sh -c "grep -q '^FileDevice Yes' /etc/cups/cups-files.conf || echo 'FileDevice Yes' >> /etc/cups/cups-files.conf"
sudo cupsctl --debug-logging
sudo launchctl kickstart -k system/org.cups.cupsd; sleep 3
OUTF=/private/tmp/ci-m125-out.pclm; sudo rm -f "$OUTF"
check "create queue with our PPD" sudo lpadmin -p CI_M125 -E -v "file://$OUTF" -P "$PPD"
check "submit job"   lp -d CI_M125 -n 2 "$LOGS/test-a4.pdf"
for i in $(seq 1 90); do [ -z "$(lpstat -o CI_M125 2>/dev/null)" ] && break; sleep 2; done
sudo cp /var/log/cups/error_log "$LOGS/cups-error_log.txt" 2>/dev/null; sudo chmod 644 "$LOGS/cups-error_log.txt" 2>/dev/null
check "job finished" sh -c "test -z \"\$(lpstat -o CI_M125 2>/dev/null)\""
check "cupsd ran our filter to the end" grep -q "rastertopclms: 6 page(s) done" "$LOGS/cups-error_log.txt"
check "no filter errors in cups log" sh -c "! grep -E '(E|ERROR).*rastertopclms' '$LOGS/cups-error_log.txt'"
if [ -s "$OUTF" ]; then
  check "cupsd output valid (6 pages: 3 x 2 copies)" sh -c "python3 -I tests/verify_pclm.py '$OUTF' && test \$(grep -ac 'PCLmS-Job-Ticket-End' '$OUTF') -eq 6"
fi
# 4b. drag-and-drop helper (the logic behind "Print with HP M125r.app")
PF="$BASE/print-files.sh"
D="$LOGS/dragdrop"; mkdir -p "$D"
cp "$LOGS/test-a4.pdf" "$D/Document.PDF"
sips -s format png "$LOGS/test-letter.pdf" --out "$D/photo.png" >/dev/null 2>&1
echo "Plain text printed by drag and drop" > "$D/note.txt"
echo "x" > "$D/archive.xyz"
printf 'Word document test\nSecond line\n' > "$D/word.txt"; textutil -convert docx "$D/word.txt" -output "$D/report.docx"
printf 'a,b,c\n1,2,3\n' > "$D/table.csv"
check "app installed: Print with HP M125r" test -d "/Applications/HP M125r Driver/Print with HP M125r.app"
check "app has Automation purpose text" sh -c "plutil -extract NSAppleEventsUsageDescription raw '/Applications/HP M125r Driver/Print with HP M125r.app/Contents/Info.plist' | grep -q PDF"
"$PF" -q CI_M125 "$D/Document.PDF" "$D/photo.png" "$D/note.txt" > "$D/direct.txt" 2>&1; rc=$?
check "drag-drop: PDF, PNG, text sent" sh -c "test $rc -eq 0 && test \$(grep -c '^OK' '$D/direct.txt') -eq 3"
"$PF" -q CI_M125 -l ru "$D/archive.xyz" > "$D/unknown.txt" 2>&1; rc=$?
check "drag-drop: unknown type explained (RU)" sh -c "test $rc -eq 1 && grep -q 'нельзя напечатать напрямую' '$D/unknown.txt'"
if [ "${INSTALL_LIBREOFFICE:-0}" = 1 ]; then
  brew install --cask --quiet libreoffice > "$D/brew.log" 2>&1
  "$PF" -q CI_M125 "$D/report.docx" "$D/table.csv" > "$D/office.txt" 2>&1; rc=$?
  check "drag-drop: Word .docx and .csv converted and sent (LibreOffice)" sh -c "test $rc -eq 0 && test \$(grep -c '^OK' '$D/office.txt') -eq 2"
else
  "$PF" -q CI_M125 "$D/report.docx" > "$D/office.txt" 2>&1; rc=$?
  check "drag-drop: .docx without an office app explained" sh -c "test $rc -eq 1 && grep -q 'needs Pages' '$D/office.txt'"
fi
for i in $(seq 1 120); do [ -z "$(lpstat -o CI_M125 2>/dev/null)" ] && break; sleep 2; done
sudo cp /var/log/cups/error_log "$LOGS/cups-error_log-dragdrop.txt" 2>/dev/null; sudo chmod 644 "$LOGS/cups-error_log-dragdrop.txt" 2>/dev/null
check "drag-drop jobs printed without filter errors" sh -c "! grep -E '(E|ERROR).*rastertopclms' '$LOGS/cups-error_log-dragdrop.txt'"
[ -s "$OUTF" ] && check "last drag-drop job output valid" python3 -I tests/verify_pclm.py "$OUTF"

# 4c. manual two-sided: 3-page document -> fronts p1,p3 ; backs: blank, p2 (reverse even + blank)
wait_queue() { for i in $(seq 1 90); do [ -z "$(lpstat -o CI_M125 2>/dev/null)" ] && return 0; sleep 2; done; return 1; }
pages_of() { python3 -I tests/verify_pclm.py "$1" --json --pgm "$2" | python3 -I -c "import json,sys; print(len(json.load(sys.stdin)['pages']))"; }
white_page() { python3 -I tests/pgm_is_white.py "$1"; }
wait_queue; sudo rm -f "$OUTF"
python3 -I tests/make_testpdf.py "$D/three.pdf" --pages 3
"$PF" -q CI_M125 -2 "$D/three.pdf" > "$D/duplex1.txt" 2>&1
check "two-sided pass 1 reports DUPLEX for 3 pages" sh -c "grep -q \"^DUPLEX.*three.pdf.*backs.pdf.3\" '$D/duplex1.txt'"
wait_queue; sudo cp "$OUTF" "$D/fronts.pclm"; sudo chmod 644 "$D/fronts.pclm"
check "two-sided pass 1 printed 2 front pages" test "$(pages_of "$D/fronts.pclm" "$D/fronts")" = 2
BACKS=$(awk -F'\t' '/^DUPLEX/ {print $3}' "$D/duplex1.txt")
sudo rm -f "$OUTF"
"$PF" -q CI_M125 -B "$BACKS" > "$D/duplex2.txt" 2>&1
check "two-sided pass 2 sent" grep -q "^OK" "$D/duplex2.txt"
wait_queue; sudo cp "$OUTF" "$D/backs.pclm"; sudo chmod 644 "$D/backs.pclm"
check "two-sided pass 2 printed 2 back pages" test "$(pages_of "$D/backs.pclm" "$D/backs")" = 2
check "two-sided: blank back first (odd page count)" test "$(white_page "$D/backs-1.pgm")" = white
check "two-sided: then page 2" test "$(white_page "$D/backs-2.pgm")" = ink
check "two-sided temp files removed" test ! -e "$(dirname "$BACKS")"
sudo lpadmin -x CI_M125

# 5. speed on this Mac: threads 1 vs automatic
python3 -I - "$FILTER" "$T/a4.ras" > "$LOGS/performance.txt" <<'EOF'
import os, subprocess, sys, time
f, ras = sys.argv[1], sys.argv[2]
for t in ("1", "2", "4", ""):
    env = dict(os.environ, PCLMS_THREADS=t)
    best = 9e9
    for _ in range(5):
        s = time.perf_counter()
        subprocess.run([f, "1", "u", "t", "1", "", ras], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, check=True)
        best = min(best, time.perf_counter() - s)
    print("threads=%-4s best of 5: %.1f ms for 3 A4 pages (%.1f ms/page)" % (t or "auto", best * 1000, best * 1000 / 3))
EOF
cat "$LOGS/performance.txt"

# 6. setup helper without a printer must explain, not crash (exit 2)
sudo "$BASE/setup-queue.sh" en > "$LOGS/setup-queue-noprinter.txt" 2>&1; rc=$?
check "setup helper without printer says 'not found'" sh -c "test $rc -eq 2 && grep -q 'Printer not found' '$LOGS/setup-queue-noprinter.txt'"

# 7. uninstall removes everything
check "uninstall" sudo "$BASE/uninstall.sh"
check "files removed" sh -c "test ! -e '$BASE' -a ! -e '$PPD' -a ! -e '/Applications/HP M125r Driver'"
check "receipt removed" sh -c "! pkgutil --pkg-info org.m125-pclms.driver"

echo; cat "$LOGS/summary.txt"
exit $FAIL
