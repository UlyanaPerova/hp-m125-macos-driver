#!/bin/bash
# Removes the m125-pclms driver, its printer queues and helper apps. Runs as root.
# SPDX-License-Identifier: MIT
LOG="/Library/Logs/m125-pclms-install.log"
echo "$(date '+%F %T') uninstall" >> "$LOG"

# delete only the printer queues that use this driver
for ppd in /etc/cups/ppd/*.ppd /private/etc/cups/ppd/*.ppd; do
  [ -f "$ppd" ] || continue
  if grep -q "m125-pclms" "$ppd"; then
    q=$(basename "$ppd" .ppd)
    lpadmin -x "$q" >> "$LOG" 2>&1 && echo "$(date '+%F %T') removed queue $q" >> "$LOG"
  fi
done

rm -f "/Library/Printers/PPDs/Contents/Resources/HP LaserJet Pro MFP M125r PCLmS.gz"
rm -rf "/Applications/Printer Driver for HP M125r"
rm -rf "/Applications/HP M125r Driver"   # name used by version 1.0.0
rm -rf "/Library/Printers/m125-pclms"
pkgutil --forget org.m125-pclms.driver >/dev/null 2>&1
exit 0
