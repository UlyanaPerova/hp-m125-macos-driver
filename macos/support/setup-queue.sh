#!/bin/bash
# Finds the HP LaserJet Pro MFP M125r (or M126-M128) on USB and connects it to the
# m125-pclms driver. Runs as root (from the installer or "Set Up Printer.app").
# Usage: setup-queue.sh [en|ru]      Exit codes: 0 ok, 2 printer not found, 1 error
# SPDX-License-Identifier: MIT
LANG_UI="${1:-en}"
PPD="/Library/Printers/PPDs/Contents/Resources/HP LaserJet Pro MFP M125r PCLmS.gz"
QUEUE="HP_LaserJet_Pro_MFP_M125r"
LOG="/Library/Logs/m125-pclms-install.log"

say() { if [ "$LANG_UI" = ru ]; then echo "$2"; else echo "$1"; fi; }
log() { echo "$(date '+%F %T') setup-queue: $*" >> "$LOG"; }

if [ ! -f "$PPD" ]; then
  say "The driver is not installed. Please run the installer first." \
      "Драйвер не установлен. Сначала запустите установщик."
  exit 1
fi

URI=""
for attempt in 1 2 3; do
  URI=$(lpinfo --include-schemes usb -v 2>/dev/null | awk '/usb:\/\/HP\/.*M12[5-8]/ {print $2; exit}')
  [ -n "$URI" ] && break
  sleep 2
done
log "usb device: ${URI:-none}"

if [ -z "$URI" ]; then
  say "Printer not found. Check that the USB cable is connected and the printer is switched on, then try again." \
      "Принтер не найден. Проверьте, что USB-кабель подключён и принтер включён, затем попробуйте ещё раз."
  exit 2
fi

# Queues that macOS may already have created for this printer: switch them to our driver.
EXISTING=$(lpstat -v 2>/dev/null | awk -v u="$URI" '$NF == u { n = $3; sub(":$", "", n); print n }')
if [ -n "$EXISTING" ]; then
  for q in $EXISTING; do
    lpadmin -p "$q" -P "$PPD" >> "$LOG" 2>&1 && log "updated queue $q"
    cupsenable "$q"; cupsaccept "$q"
    QUEUE="$q"
  done
else
  if ! lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD" -D "HP LaserJet Pro MFP M125r" -L "USB" \
       -o printer-is-shared=false >> "$LOG" 2>&1; then
    say "Could not add the printer. Details are in $LOG" "Не удалось добавить принтер. Подробности в $LOG"
    exit 1
  fi
  cupsenable "$QUEUE"; cupsaccept "$QUEUE"
  log "created queue $QUEUE"
fi

# Make it the default printer if there is none yet.
if ! lpstat -d 2>/dev/null | grep -q ':'; then
  lpadmin -d "$QUEUE" >> "$LOG" 2>&1
fi

echo "$QUEUE" > "/Library/Printers/m125-pclms/queue-name"; chmod 644 "/Library/Printers/m125-pclms/queue-name"
say "The printer is ready: \"HP LaserJet Pro MFP M125r\"." "Принтер готов: «HP LaserJet Pro MFP M125r»."
echo "QUEUE=$QUEUE"
exit 0
