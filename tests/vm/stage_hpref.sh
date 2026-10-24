# SPDX-License-Identifier: MIT
# Stage hpref: make sure the HP reference filter exists (hpcups built from HPLIP 3.26.6)
# and record which binary/version is used.  Also smoke-test the distro hpcups.
. "$VMTESTS/lib.sh"
set -x
L="$OUT/hpref"; mkdir -p "$L"
if [ ! -x "$HPCUPS" ]; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q libjpeg-dev libusb-1.0-0-dev > /dev/null
  mkdir -p "$(dirname "$HPLIP_SRC")" && tar -m -C "$(dirname "$HPLIP_SRC")" -xzf "$HPLIP_TARBALL"
  ( cd "$HPLIP_SRC" && ./configure --disable-network-build --disable-scan-build --disable-gui-build \
      --disable-fax-build --disable-dbus-build --disable-qt5 --disable-qt4 --enable-hpcups-install \
      --disable-hpijs-install --disable-doc-build --disable-pp-build --disable-cups-drv-install \
      --enable-cups-ppd-install && make -j"$(nproc)" hpcups ) > "$L/build_hpcups.log" 2>&1
fi
if [ -x "$HPCUPS" ]; then
  result hpref hpcups_3266 PASS "$HPCUPS ($(stat -c %s "$HPCUPS") bytes, sha256 $(sha256sum "$HPCUPS" | cut -c1-16)), needs LD_LIBRARY_PATH=$HPLIP_SRC/prnt/hpcups for libImageProcessor.so"
else
  result hpref hpcups_3266 FAIL "could not build hpcups from $HPLIP_TARBALL"
fi
grep -n "plugin\|Hbpl1Wrapper(this)" "$HPLIP_SRC/prnt/hpcups/Hbpl1.cpp" > "$L/hbpl1_plugin_lines.txt" 2>/dev/null
ldd "$HPCUPS" > "$L/ldd_hpcups_3266.txt" 2>&1
{ echo "distro: $(dpkg-query -W -f='${Package} ${Version}' printer-driver-hpcups)"; ls -l "$HPCUPS_DISTRO"; } > "$L/distro_hpcups.txt"

# smoke test both on a tiny job; compare masked structure
mkdir -p "$WORK/hpref"
pt mkras "$WORK/hpref/rgb.ras" cupsColorSpace=1 cupsBitsPerColor=8 cupsBitsPerPixel=24 cupsNumColors=3 \
   cupsWidth=4725 cupsHeight=6783 PageSize=595,842 ImagingBoundingBox=14,14,581,828 data=white
run_hp "$WORK/hpref/rgb.ras" "$WORK/hpref/hp3266.pclm" "" "$HPCUPS"; r1=$?
run_hp "$WORK/hpref/rgb.ras" "$WORK/hpref/hpdistro.pclm" "" "$HPCUPS_DISTRO"; r2=$?
cp "$WORK/hpref/hp3266.pclm.stderr" "$L/hp3266.stderr"; cp "$WORK/hpref/hpdistro.pclm.stderr" "$L/hpdistro.stderr"
if grep -qi plugin "$L/hpdistro.stderr"; then
  result hpref hpcups_distro INFO "distro hpcups asks for the HP plugin"
fi
pt struct --mask "$WORK/hpref/hp3266.pclm" > "$L/hp3266.struct"
pt struct --mask "$WORK/hpref/hpdistro.pclm" > "$L/hpdistro.struct"
if [ $r1 -eq 0 ] && [ $r2 -eq 0 ] && cmp -s "$L/hp3266.struct" "$L/hpdistro.struct"; then
  result hpref distro_vs_3266 PASS "distro hpcups $(dpkg-query -W -f='${Version}' printer-driver-hpcups) needs no plugin for hbpl1 and gives the same structure as 3.26.6"
else
  result hpref distro_vs_3266 INFO "rc 3.26.6=$r1 distro=$r2; structures differ (see hpref/*.struct)"
fi
