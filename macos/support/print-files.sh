#!/bin/bash
# Print any files on the HP M125r: PDF, images and text go straight to the printer;
# office documents are first turned into PDF by an app that understands them.
# Used by "Print with HP M125r.app" (drag-and-drop) and usable from Terminal:
#   print-files.sh [-q queue] [-l en|ru] [-2] FILE...
#   print-files.sh [-q queue] [-l en|ru] -B BACKS.pdf      (second pass of -2)
# Output: one line per file, "OK<TAB>name" or "FAIL<TAB>name<TAB>reason".
# With -2 (manual two-sided) the front sides are printed and the line is
# "DUPLEX<TAB>name<TAB>BACKS.pdf<TAB>pages"; after the user has put the paper back,
# call again with -B BACKS.pdf to print the back sides.
# Exit code: 0 if every file was sent, 1 otherwise.
# Nothing leaves the Mac: converted PDFs are written to a private temporary folder and
# deleted as soon as the print system has taken the job.
# SPDX-License-Identifier: MIT
set -u
BASE="/Library/Printers/m125-pclms"
QUEUE=""
LANG_UI="en"
DUPLEX=0
BACKS=""
while getopts "q:l:2B:" o; do
  case "$o" in q) QUEUE="$OPTARG" ;; l) LANG_UI="$OPTARG" ;; 2) DUPLEX=1 ;; B) BACKS="$OPTARG" ;; *) ;; esac
done
shift $((OPTIND - 1))

t() { if [ "$LANG_UI" = ru ]; then echo "$2"; else echo "$1"; fi; }

# Which printer: the one set up by the installer, else the default printer.
if [ -z "$QUEUE" ] && [ -r "$BASE/queue-name" ]; then QUEUE=$(head -1 "$BASE/queue-name"); fi
if [ -n "$QUEUE" ] && ! lpstat -p "$QUEUE" >/dev/null 2>&1; then QUEUE=""; fi
if [ -z "$QUEUE" ]; then QUEUE=$(lpstat -d 2>/dev/null | awk -F': ' '/:/ {print $2}'); fi
if [ -z "$QUEUE" ]; then
  printf "%b\n" "FAIL\t-\t$(t 'No printer is set up. Open "Set Up Printer" first.' 'Принтер не настроен. Сначала откройте «Set Up Printer».')"
  exit 1
fi

# second pass of manual two-sided printing
if [ -n "$BACKS" ]; then
  case "$BACKS" in "${TMPDIR:-/tmp}"/m125duplex.*/backs.pdf|/tmp/m125duplex.*/backs.pdf) ;; *)
    printf "%b\n" "FAIL\t-\tbad backs file"; exit 1 ;; esac
  name=$(cat "$(dirname "$BACKS")/name" 2>/dev/null)
  if lp -d "$QUEUE" -t "${name:-document} (2)" -- "$BACKS" >/dev/null 2>"$(dirname "$BACKS")/lp.err"; then
    printf "%b\n" "OK\t${name:-document}"; rc=0
  else
    printf "%b\n" "FAIL\t${name:-document}\t$(head -1 "$(dirname "$BACKS")/lp.err")"; rc=1
  fi
  rm -rf "$(dirname "$BACKS")"
  exit $rc
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/m125print.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

app_installed() { # bundle id
  [ -n "$(mdfind "kMDItemCFBundleIdentifier == '$1'" 2>/dev/null | head -1)" ] && return 0
  case "$1" in
    com.apple.iWork.Pages)    [ -d "/Applications/Pages.app" ] ;;
    com.apple.iWork.Numbers)  [ -d "/Applications/Numbers.app" ] ;;
    com.apple.iWork.Keynote)  [ -d "/Applications/Keynote.app" ] ;;
    com.microsoft.Word)       [ -d "/Applications/Microsoft Word.app" ] ;;
    *) return 1 ;;
  esac
}

soffice_bin() {
  for s in "/Applications/LibreOffice.app/Contents/MacOS/soffice" "$(command -v soffice 2>/dev/null)"; do
    [ -n "$s" ] && [ -x "$s" ] && { echo "$s"; return 0; }
  done
  return 1
}

# iWork: open the file in Pages/Numbers/Keynote (they also read Word/Excel/PowerPoint) and
# export it as PDF. The scripts are compiled at run time so this works whether or not the
# app is installed on the machine that built the package.
iwork_pdf() { # app-name in out
  osascript - "$1" "$2" "$3" <<'EOF' >/dev/null 2>"$TMP/osa.err"
on run argv
  set appName to item 1 of argv
  set inFile to POSIX file (item 2 of argv)
  set outFile to POSIX file (item 3 of argv)
  run script "on run {inFile, outFile}
    set wasRunning to application \"" & appName & "\" is running
    tell application \"" & appName & "\"
      set d to open inFile
      export d to outFile as PDF
      close d saving no
      if not wasRunning then quit
    end tell
  end run" with parameters {inFile, outFile}
end run
EOF
}

word_pdf() { # in out
  osascript - "$1" "$2" <<'EOF' >/dev/null 2>"$TMP/osa.err"
on run argv
  set inFile to POSIX file (item 1 of argv)
  set outPath to item 2 of argv
  run script "on run {inFile, outPath}
    tell application \"Microsoft Word\"
      open inFile
      set d to active document
      save as d file name outPath file format format PDF
      close d saving no
    end tell
  end run" with parameters {inFile, outPath}
end run
EOF
}

office_pdf() { # in out
  local s; s=$(soffice_bin) || return 1
  "$s" --headless --norestore --convert-to pdf --outdir "$TMP/lo" "$1" >/dev/null 2>"$TMP/lo.err" || return 1
  local made="$TMP/lo/$(basename "${1%.*}").pdf"
  [ -s "$made" ] && mv "$made" "$2"
}

# Convert $1 to PDF $2 with the first suitable app that is installed.
to_pdf() { # kind in out
  local kind="$1" in="$2" out="$3"
  case "$kind" in
    word)
      if app_installed com.microsoft.Word && word_pdf "$in" "$out" && [ -s "$out" ]; then return 0; fi
      if app_installed com.apple.iWork.Pages && iwork_pdf Pages "$in" "$out" && [ -s "$out" ]; then return 0; fi ;;
    pages)
      if app_installed com.apple.iWork.Pages && iwork_pdf Pages "$in" "$out" && [ -s "$out" ]; then return 0; fi ;;
    sheet)
      if app_installed com.apple.iWork.Numbers && iwork_pdf Numbers "$in" "$out" && [ -s "$out" ]; then return 0; fi ;;
    slides)
      if app_installed com.apple.iWork.Keynote && iwork_pdf Keynote "$in" "$out" && [ -s "$out" ]; then return 0; fi ;;
  esac
  case "$kind" in word|sheet|slides) office_pdf "$in" "$out" && return 0 ;; esac
  return 1
}

need_app_msg() { # kind
  case "$1" in
    pages)  t 'needs Pages (free in the App Store)' 'нужна программа Pages (бесплатно в App Store)' ;;
    word)   t 'needs Pages (free in the App Store), Microsoft Word or LibreOffice' 'нужна программа Pages (бесплатно в App Store), Microsoft Word или LibreOffice' ;;
    sheet)  t 'needs Numbers (free in the App Store) or LibreOffice' 'нужна программа Numbers (бесплатно в App Store) или LibreOffice' ;;
    slides) t 'needs Keynote (free in the App Store) or LibreOffice' 'нужна программа Keynote (бесплатно в App Store) или LibreOffice' ;;
  esac
}

# Send a PDF either one-sided or as the first pass of manual two-sided printing.
send_pdf() { # pdf name
  if [ "$DUPLEX" != 1 ]; then
    if lp -d "$QUEUE" -t "$2" -- "$1" >/dev/null 2>"$TMP/lp.err"; then printf "%b\n" "OK\t$2"; return 0; fi
    printf "%b\n" "FAIL\t$2\t$(head -1 "$TMP/lp.err")"; return 1
  fi
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/m125duplex.XXXXXX") || return 1
  printf "%s" "$2" > "$d/name"
  local n; n=$(osascript -l JavaScript "$BASE/duplex-split.js" "$1" "$d/fronts.pdf" "$d/backs.pdf" 2>"$d/split.err")
  if [ -z "$n" ] || [ ! -s "$d/fronts.pdf" ]; then
    printf "%b\n" "FAIL\t$2\t$(t 'could not prepare two-sided printing' 'не удалось подготовить двустороннюю печать')"
    rm -rf "$d"; return 1
  fi
  if ! lp -d "$QUEUE" -t "$2 (1)" -- "$d/fronts.pdf" >/dev/null 2>"$d/lp.err"; then
    printf "%b\n" "FAIL\t$2\t$(head -1 "$d/lp.err")"; rm -rf "$d"; return 1
  fi
  if [ "$n" -le 1 ]; then printf "%b\n" "OK\t$2"; rm -rf "$d"; return 0; fi
  printf "%b\n" "DUPLEX\t$2\t$d/backs.pdf\t$n"
}

FAILED=0
for f in "$@"; do
  name=$(basename "$f")
  if [ ! -f "$f" ] && [ ! -d "$f" ]; then
    printf "%b\n" "FAIL\t$name\t$(t 'file not found' 'файл не найден')"; FAILED=1; continue
  fi
  ext=$(echo "${name##*.}" | tr '[:upper:]' '[:lower:]')
  [ "$ext" = "$name" ] && ext=""
  case "$ext" in
    pdf|jpg|jpeg|png|gif|tif|tiff|bmp|heic|heif|txt|text) kind=direct ;;
    pages) kind=pages ;;
    doc|docx|docm|dot|dotx|rtf|odt|wpd) kind=word ;;
    numbers|xls|xlsx|xlsm|ods|csv) kind=sheet ;;
    key|ppt|pptx|pps|ppsx|odp) kind=slides ;;
    *) kind=unknown ;;
  esac
  # iWork documents can be folders (packages): only the iWork path handles those
  if [ -d "$f" ] && [ "$kind" != pages ] && [ "$kind" != sheet ] && [ "$kind" != slides ]; then
    kind=unknown
  fi

  case "$kind" in
    direct)
      if [ "$DUPLEX" = 1 ] && [ "$ext" != pdf ]; then
        # pictures and text: let macOS make a PDF first so the pages can be split
        pdf="$TMP/direct-$$.pdf"
        if cupsfilter -m application/pdf "$f" > "$pdf" 2>"$TMP/cf.err" && [ -s "$pdf" ]; then
          send_pdf "$pdf" "$name" || FAILED=1
        else
          printf "%b\n" "FAIL\t$name\t$(t 'could not convert to PDF' 'не удалось преобразовать в PDF')"; FAILED=1
        fi
      elif [ "$DUPLEX" = 1 ]; then
        send_pdf "$f" "$name" || FAILED=1
      elif lp -d "$QUEUE" -t "$name" -- "$f" >/dev/null 2>"$TMP/lp.err"; then printf "%b\n" "OK\t$name"
      else printf "%b\n" "FAIL\t$name\t$(head -1 "$TMP/lp.err")"; FAILED=1; fi ;;
    unknown)
      printf "%b\n" "FAIL\t$name\t$(t 'this file type can'"'"'t be printed directly; open it and use File > Print' 'этот тип файла нельзя напечатать напрямую; откройте его и выберите Файл > Напечатать')"
      FAILED=1 ;;
    *)
      N=$((${N:-0} + 1)); pdf="$TMP/$N-${name%.*}.pdf"
      if to_pdf "$kind" "$f" "$pdf"; then
        send_pdf "$pdf" "$name" || FAILED=1
        rm -f "$pdf"
      else
        printf "%b\n" "FAIL\t$name\t$(need_app_msg "$kind")"; FAILED=1
      fi ;;
  esac
done
exit $FAILED
