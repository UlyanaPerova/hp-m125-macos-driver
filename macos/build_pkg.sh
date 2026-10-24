#!/bin/bash
# Build the double-click installer "Install Printer Driver for HP M125r.pkg". Runs on macOS
# (locally or on the GitHub Actions macOS runner).
#
# Optional, for Gatekeeper-approved packages (needs Apple Developer Program):
#   APP_IDENTITY="Developer ID Application: Name (TEAMID)"   signs binaries and apps
#   PKG_IDENTITY="Developer ID Installer: Name (TEAMID)"     signs the .pkg
#   NOTARY_PROFILE=name   (xcrun notarytool store-credentials name ...) notarizes + staples
# Without them, binaries get an ad-hoc signature and the .pkg is unsigned.
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
ID="org.m125-pclms.driver"
OUT="dist"
ROOT="$OUT/root"
BASE="/Library/Printers/m125-pclms"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
PPD_NAME="HP LaserJet Pro MFP M125r PCLmS.gz"
APPS="/Applications/Printer Driver for HP M125r"
PKG="$OUT/Install Printer Driver for HP M125r.pkg"
SIGN="${APP_IDENTITY:--}"

sign() { # sign <path>; ad-hoc unless APP_IDENTITY is set
  if [ "$SIGN" = "-" ]; then codesign --force --sign - "$@"
  else codesign --force --options runtime --timestamp --sign "$SIGN" "$@"; fi
}

rm -rf "$OUT"
mkdir -p "$ROOT$BASE/Filters" "$ROOT$PPD_DIR" "$ROOT$APPS" "$OUT/resources" "$OUT/scripts"

echo "== build filter (universal arm64 + x86_64)"
make clean >/dev/null
make ARCHS="-arch arm64 -arch x86_64" || make ARCHS="-arch arm64 -arch x86_64" LIBS="-lcups -lcupsimage"
lipo -info rastertopclms
sign rastertopclms
codesign --verify --strict rastertopclms

echo "== stage files"
install -m 755 rastertopclms "$ROOT$BASE/Filters/rastertopclms"
install -m 755 macos/support/setup-queue.sh "$ROOT$BASE/setup-queue.sh"
install -m 755 macos/support/uninstall.sh "$ROOT$BASE/uninstall.sh"
install -m 755 macos/support/print-files.sh "$ROOT$BASE/print-files.sh"
install -m 644 macos/support/duplex-split.js "$ROOT$BASE/duplex-split.js"
python3 -I tests/make_testpdf.py "$ROOT$BASE/testpage.pdf"
for f in LICENSE docs/PRIVACY.md docs/TERMS.md docs/THIRD_PARTY_NOTICES.md; do
  install -m 644 "$f" "$ROOT$BASE/"
done
sed "s#@FILTER@#$BASE/Filters/rastertopclms#" ppd/m125-pclms.ppd | gzip -9n > "$ROOT$PPD_DIR/$PPD_NAME"
chmod 644 "$ROOT$PPD_DIR/$PPD_NAME"

echo "== helper apps"
make_app() { # make_app <script> <app name> <bundle id>
  local app="$ROOT$APPS/$2.app"
  osacompile -o "$app" "macos/apps/$1"
  plutil -replace CFBundleIdentifier -string "$3" "$app/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
  plutil -replace NSHumanReadableCopyright -string "MIT License. Not affiliated with HP Inc." "$app/Contents/Info.plist"
  sign --deep "$app"
}
make_app SetUpPrinter.applescript "Set Up Printer" "org.m125-pclms.setup"
# drag-and-drop printing apps; they ask once for permission to let Pages/Numbers/Keynote/Word make a PDF
make_droplet() { # make_droplet <app name> <bundle id> <two-sided true|false>
  local PW="$ROOT$APPS/$1.app" SRC="$OUT/$2.applescript"
  sed "s/^property twoSided : false/property twoSided : $3/" macos/apps/PrintWith.applescript > "$SRC"
  osacompile -o "$PW" "$SRC"
  plutil -replace CFBundleIdentifier -string "$2" "$PW/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$PW/Contents/Info.plist"
  plutil -replace NSHumanReadableCopyright -string "MIT License. Not affiliated with HP Inc." "$PW/Contents/Info.plist"
  plutil -replace NSAppleEventsUsageDescription -string "To print a Pages, Word, Numbers, Excel, Keynote or PowerPoint document, the app opens it in that program and saves a PDF copy. The copy stays on this Mac and is deleted after printing." "$PW/Contents/Info.plist"
  mkdir -p "$PW/Contents/Resources/ru.lproj" "$PW/Contents/Resources/en.lproj"
  printf '"NSAppleEventsUsageDescription" = "Чтобы напечатать документ Pages, Word, Numbers, Excel, Keynote или PowerPoint, программа открывает его в этой программе и сохраняет копию в PDF. Копия остаётся на этом Mac и удаляется после печати.";\n' > "$PW/Contents/Resources/ru.lproj/InfoPlist.strings"
  printf '"NSAppleEventsUsageDescription" = "To print a Pages, Word, Numbers, Excel, Keynote or PowerPoint document, the app opens it in that program and saves a PDF copy. The copy stays on this Mac and is deleted after printing.";\n' > "$PW/Contents/Resources/en.lproj/InfoPlist.strings"
  plutil -lint "$PW/Contents/Info.plist"
  sign --deep "$PW"
}
make_droplet "Print with HP M125r" "org.m125-pclms.printwith" false
make_droplet "Print two-sided with HP M125r" "org.m125-pclms.printwith2" true
make_app Uninstall.applescript "Uninstall" "org.m125-pclms.uninstall"
cp macos/pkg/resources/en.lproj/readme.html  "$ROOT$APPS/Privacy Policy.html"
cp macos/pkg/resources/en.lproj/license.html "$ROOT$APPS/Terms of Use.html"
cp macos/pkg/resources/ru.lproj/readme.html  "$ROOT$APPS/Политика конфиденциальности.html"
cp macos/pkg/resources/ru.lproj/license.html "$ROOT$APPS/Условия использования.html"

echo "== installer resources"
if grep -rIlE 'https?://' macos/pkg/resources; then
  echo "installer pages must not load remote content"; exit 1
fi
cp -R macos/pkg/resources/. "$OUT/resources/"
install -m 755 macos/pkg/scripts/postinstall "$OUT/scripts/postinstall"
sed "s/@VERSION@/$VERSION/" macos/pkg/distribution.xml > "$OUT/distribution.xml"

echo "== component package"
pkgbuild --analyze --root "$ROOT" "$OUT/component.plist"
i=0
while /usr/libexec/PlistBuddy -c "Print :$i" "$OUT/component.plist" >/dev/null 2>&1; do
  /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$OUT/component.plist"
  i=$((i + 1))
done
pkgbuild --root "$ROOT" --component-plist "$OUT/component.plist" --identifier "$ID" \
  --version "$VERSION" --scripts "$OUT/scripts" --install-location / --ownership recommended \
  "$OUT/m125-pclms-component.pkg"

echo "== product package"
if [ -n "${PKG_IDENTITY:-}" ]; then SIGNPKG=(--sign "$PKG_IDENTITY" --timestamp); else SIGNPKG=(); fi
productbuild --distribution "$OUT/distribution.xml" --resources "$OUT/resources" \
  --package-path "$OUT" ${SIGNPKG[@]+"${SIGNPKG[@]}"} "$PKG"

if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "${PKG_IDENTITY:-}" ]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
  spctl --assess --type install --verbose=2 "$PKG"
fi

pkgutil --payload-files "$PKG" > "$OUT/payload-files.txt"
( cd "$OUT" && shasum -a 256 "Install Printer Driver for HP M125r.pkg" > SHA256SUMS.txt )
echo "== built: $PKG ($(du -h "$PKG" | cut -f1))"
cat "$OUT/SHA256SUMS.txt"
