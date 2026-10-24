#!/bin/bash
# Build, sign and install the m125-pclms driver on macOS (Apple Silicon or Intel).
# Usage:  sudo ./macos/install.sh            (from the driver folder)
# Optional environment:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  sign with a real certificate
#                                             (default: ad-hoc signature "-")
#   ADD_QUEUE=0                               only install files, don't create a printer queue
# SPDX-License-Identifier: MIT
set -euo pipefail

cd "$(dirname "$0")/.."
FILTER_DIR="/Library/Printers/m125-pclms/Filters"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
PPD_NAME="HP LaserJet Pro MFP M125r PCLmS.gz"
QUEUE="HP_LaserJet_Pro_MFP_M125r"
LOG="/Library/Logs/m125-pclms-install.log"

if [ "$(id -u)" != 0 ]; then
  echo "Please run with sudo:  sudo $0"; exit 1
fi
exec > >(tee -a "$LOG") 2>&1
echo "== m125-pclms install $(date)  macOS $(sw_vers -productVersion) $(uname -m)"

# 1. Compiler: Xcode Command Line Tools
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Command Line Tools are missing. A window will open; install them, then run this script again."
  xcode-select --install || true
  exit 1
fi

# 2. Build (universal binary: arm64 + x86_64)
make clean >/dev/null
make ARCHS="-arch arm64 -arch x86_64"
lipo -info rastertopclms

# 3. Code signature. Apple Silicon only runs signed code; locally built files
#    are not quarantined, so Gatekeeper accepts an ad-hoc signature here.
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - rastertopclms
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" rastertopclms
fi
codesign --verify --strict --verbose=2 rastertopclms

# 4. Install. cupsd refuses filters that are not owned by root or are writable by others.
install -d -o root -g wheel -m 755 "/Library/Printers/m125-pclms" "$FILTER_DIR"
install -o root -g wheel -m 755 rastertopclms "$FILTER_DIR/rastertopclms"
sed "s#@FILTER@#$FILTER_DIR/rastertopclms#" ppd/m125-pclms.ppd | gzip -9n > "$PPD_DIR/$PPD_NAME"
chown root:wheel "$PPD_DIR/$PPD_NAME"; chmod 644 "$PPD_DIR/$PPD_NAME"
xattr -dr com.apple.quarantine "/Library/Printers/m125-pclms" 2>/dev/null || true
echo "Installed filter: $FILTER_DIR/rastertopclms"
echo "Installed PPD:    $PPD_DIR/$PPD_NAME"

# 5. Self-test: feed a blank page through the filter, check the output starts as PCLm
if command -v cupsfilter >/dev/null; then
  T=$(mktemp -d)
  echo "m125-pclms self-test" > "$T/test.txt"
  if cupsfilter -p "$PPD_DIR/$PPD_NAME" -m application/vnd.cups-raster "$T/test.txt" > "$T/blank.ras" 2>"$T/err1" \
     && "$FILTER_DIR/rastertopclms" 1 test test 1 "" "$T/blank.ras" > "$T/out.pclm" 2>"$T/err2" \
     && head -c 8 "$T/out.pclm" | grep -q '%PDF-1.7'; then
    echo "Self-test: OK ($(wc -c < "$T/out.pclm") bytes)"
  else
    echo "Self-test: could not run fully (see $T); continuing."
  fi
fi

# 6. Printer queue on the USB port (skip with ADD_QUEUE=0)
if [ "${ADD_QUEUE:-1}" = 1 ]; then
  URI=$(lpinfo -v 2>/dev/null | awk '/usb:\/\/HP\/.*M12[5-8]/ {print $2; exit}')
  if [ -n "${URI:-}" ]; then
    lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD_DIR/$PPD_NAME" \
      -D "HP LaserJet Pro MFP M125r" -o printer-is-shared=false
    cupsenable "$QUEUE"; cupsaccept "$QUEUE"
    echo "Printer queue '$QUEUE' created on $URI"
  else
    echo "Printer not found on USB. Connect and power it on, then either run this script again"
    echo "or add it in System Settings > Printers & Scanners > Add Printer, and under 'Use'"
    echo "choose 'Select Software...' > 'HP LaserJet Pro MFP M125r, m125-pclms 1.0 (open driver)'."
  fi
fi
echo "Done. Log: $LOG"
