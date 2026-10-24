# SPDX-License-Identifier: MIT
# Stage env: check / install packages, record environment.
. "$VMTESTS/lib.sh"
set -x
PKGS="cups cups-filters libcups2-dev libcupsimage2-dev build-essential zlib1g-dev qpdf poppler-utils
ghostscript hplip printer-driver-hpcups python3-pil python3-numpy valgrind time pkg-config
libjpeg-dev libusb-1.0-0-dev"
missing=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
if [ -n "$missing" ]; then
  while pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; do sleep 5; done
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing
fi
missing2=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing2="$missing2 $p"; done
if [ -z "$missing2" ]; then result env packages PASS "all installed"; else result env packages FAIL "missing:$missing2"; fi

set +x
{
  echo "date: $(date -u)"; uname -a; lsb_release -ds 2>/dev/null; nproc; free -m | head -2
  gcc --version | head -1
  for p in cups cups-filters libcups2t64 ghostscript hplip printer-driver-hpcups poppler-utils qpdf valgrind python3-numpy; do
    printf '%s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
  done
  python3 --version
} > "$OUT/environment.txt" 2>&1
set -x
result env environment INFO "$(lsb_release -ds 2>/dev/null), cups $(dpkg-query -W -f='${Version}' cups), gs $(gs --version), distro hplip $(dpkg-query -W -f='${Version}' hplip)"

mkdir -p "$WORK/ppd"
zcat "$HPLIP_SRC/ppd/hpcups/hp-laserjet_pro_mfp_m125r.ppd.gz" > "$HP_PPD" 2>/dev/null ||
  tar -xzOf "$HPLIP_TARBALL" hplip-3.26.6/ppd/hpcups/hp-laserjet_pro_mfp_m125r.ppd.gz | zcat > "$HP_PPD"
sed 's#@FILTER@#rastertopclms#' "$DRV/ppd/m125-pclms.ppd" > "$OUR_PPD"
[ -s "$HP_PPD" ] && result env hp_ppd PASS "$(grep NickName "$HP_PPD" | head -1)" || result env hp_ppd FAIL "HP PPD not found"
