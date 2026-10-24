#!/bin/bash
# Remove the m125-pclms driver from macOS.  Usage: sudo ./macos/uninstall.sh
# SPDX-License-Identifier: MIT
set -u
[ "$(id -u)" = 0 ] || { echo "Please run with sudo"; exit 1; }
lpadmin -x HP_LaserJet_Pro_MFP_M125r 2>/dev/null || true
rm -rf "/Library/Printers/m125-pclms"
rm -f "/Library/Printers/PPDs/Contents/Resources/HP LaserJet Pro MFP M125r PCLmS.gz"
pkgutil --forget org.m125-pclms.driver >/dev/null 2>&1 || true
echo "m125-pclms removed."
