# SPDX-License-Identifier: MIT
# Stage build: make, warnings, link check, sanitizer builds, PPD checks.
. "$VMTESTS/lib.sh"
set -x
cd "$DRV" || exit 1
L="$OUT/build"; mkdir -p "$L" "$WORK/bin"

make clean > /dev/null 2>&1
make > "$L/make.log" 2>&1; rc=$?
nw=$(grep -c 'warning:' "$L/make.log")
if [ $rc -eq 0 ] && [ -x rastertopclms ]; then
  [ "$nw" -eq 0 ] && result build make PASS "no warnings" || result build make FAIL "$nw warnings (see build/make.log)"
else
  result build make FAIL "make rc=$rc"; exit 1
fi
[ -f ppd/m125-pclms.installed.ppd ] && result build make_generates_ppd PASS "" ||
  result build make_generates_ppd INFO "'make' (target all) does not build ppd/m125-pclms.installed.ppd; only 'make install' does"
make ppd/m125-pclms.installed.ppd >> "$L/make.log" 2>&1
grep -q '^\*cupsFilter: "application/vnd.cups-raster 0 rastertopclms"' ppd/m125-pclms.installed.ppd &&
  result build installed_ppd PASS "@FILTER@ -> rastertopclms" || result build installed_ppd FAIL "cupsFilter not substituted"

# link check: which libraries are really needed
ldd rastertopclms > "$L/ldd.txt"
nm -D --undefined-only rastertopclms | grep -i cups > "$L/cups_symbols.txt"
grep -q cupsimage "$L/ldd.txt" && result build link INFO "links libcupsimage" ||
  result build link PASS "links with -lcups -lpthread only; -lcupsimage not needed on Ubuntu 24.04 (raster API is in libcups2 >= 2.2): $(tr '\n' ' ' < "$L/cups_symbols.txt" | awk '{for(i=2;i<=NF;i+=2) printf "%s ",$i}')"
make -n install > "$L/make_install_dryrun.txt" 2>&1
result build install_paths INFO "$(grep -E '^install -m' "$L/make_install_dryrun.txt" | tr '\n' ';')"
ls -l rastertopclms > "$L/size.txt"; result build binary_size INFO "$(stat -c %s rastertopclms) bytes"

# stricter warnings (informational)
cc -O2 -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wcast-align -Wstrict-prototypes \
   -Wmissing-prototypes -Wnull-dereference -Wdouble-promotion -o /dev/null src/rastertopclms.c -lcups -lpthread > "$L/strict_warnings.log" 2>&1
result build strict_warnings INFO "$(grep -c 'warning:' "$L/strict_warnings.log") warnings with -Wpedantic -Wshadow -Wformat=2 ... (build/strict_warnings.log)"
gcc -O2 -std=c99 -D_DEFAULT_SOURCE -fanalyzer -c -o /dev/null src/rastertopclms.c > "$L/fanalyzer.log" 2>&1
result build gcc_fanalyzer INFO "$(grep -c 'warning:' "$L/fanalyzer.log") -fanalyzer warnings (build/fanalyzer.log)"

# sanitizer builds
SAN="-O1 -g -fno-omit-frame-pointer -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -Wno-deprecated-declarations"
cc $SAN -fsanitize=address,undefined -fno-sanitize-recover=all -o "$OURS_ASAN" src/rastertopclms.c -lcups -lpthread > "$L/asan_build.log" 2>&1 &&
  result build asan_ubsan PASS "$OURS_ASAN" || result build asan_ubsan FAIL "see build/asan_build.log"
cc $SAN -fsanitize=thread -o "$OURS_TSAN" src/rastertopclms.c -lcups -lpthread > "$L/tsan_build.log" 2>&1 &&
  result build tsan PASS "$OURS_TSAN" || result build tsan FAIL "see build/tsan_build.log"

# PPD checks
for p in "$OUR_PPD" "$HP_PPD"; do
  n=$(basename "$p" .ppd)
  cupstestppd -W all "$p" > "$L/cupstestppd_$n.txt" 2>&1; rc=$?
  [ "$n" = "m125-pclms" ] && { [ $rc -eq 0 ] && result build cupstestppd_ours PASS "$(head -1 "$L/cupstestppd_$n.txt")" ||
    result build cupstestppd_ours FAIL "rc=$rc: $(grep -E 'FAIL|WARN|\*\*' "$L/cupstestppd_$n.txt" | head -5 | tr '\n' ' ')"; }
  [ "$n" != "m125-pclms" ] && result build cupstestppd_hp INFO "rc=$rc $(grep -cE 'WARN' "$L/cupstestppd_$n.txt") warnings (reference)"
done

# option-by-option PPD comparison (ours vs HP)
python3 -I - "$OUR_PPD" "$HP_PPD" > "$L/ppd_option_diff.txt" <<'EOF'
import re, sys
def opts(p):
    d = {}; cur = None
    for line in open(p, encoding="latin-1"):
        m = re.match(r"\*OpenUI \*(\w+)", line)
        if m: cur = m.group(1); d[cur] = {}; continue
        if line.startswith("*CloseUI"): cur = None; continue
        m = re.match(r"\*(\w+) ([^/:]+)(?:/[^:]*)?: \"(.*)\"", line)
        if m and cur and m.group(1) == cur: d[cur][m.group(2)] = m.group(3)
        m = re.match(r"\*Default(\w+): (\S+)", line)
        if m and m.group(1) in d: d[m.group(1)]["<default>"] = m.group(2)
    return d
a, b = opts(sys.argv[1]), opts(sys.argv[2])
for k in sorted(set(a) | set(b)):
    if k not in a: print("only in HP  : option %s %s" % (k, sorted(b[k]))); continue
    if k not in b: print("only in ours: option %s %s" % (k, sorted(a[k]))); continue
    for c in sorted(set(a[k]) | set(b[k])):
        if a[k].get(c) != b[k].get(c):
            print("%-10s %-22s ours=%r\n%-10s %-22s HP  =%r" % (k, c, a[k].get(c), "", "", b[k].get(c)))
EOF
result build ppd_vs_hp INFO "$(wc -l < "$L/ppd_option_diff.txt") lines of option differences (build/ppd_option_diff.txt)"
