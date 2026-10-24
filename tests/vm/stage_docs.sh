# SPDX-License-Identifier: MIT
# Stage docs: generate the test PDFs into $DOCS.
. "$VMTESTS/lib.sh"
set -x
mkdir -p "$DOCS"; cd "$DOCS" || exit 1

cat > text.ps <<'EOF'
%!PS
<< /PageSize [595 842] >> setpagedevice
/lines [(Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.)
        (Pack my box with five dozen liquor jugs. 0123456789 !@#$%^&*()_+-=[]{};:,./<>?)
        (The quick brown fox jumps over the lazy dog. THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG.)] def
/fonts [/Times-Roman /Helvetica /Courier /Times-Bold /Helvetica-Oblique] def
1 1 NPAGES {
  /pg exch def
  /Helvetica-Bold findfont 16 scalefont setfont 40 800 moveto (Text test page ) show pg 3 string cvs show
  /y 780 def /i 0 def
  { y 30 lt {exit} if
    fonts i fonts length mod get findfont 6 i 7 mod 2 mul add scalefont setfont
    40 y moveto lines i 3 mod get show
    /y y 8 i 7 mod 2 mul add 1.2 mul sub def /i i 1 add def } loop
  showpage
} for
EOF
sed 's/NPAGES/3/' text.ps > text3.ps;  ps2pdf -dAutoRotatePages=/None text3.ps text.pdf
sed 's/NPAGES/50/' text.ps > text50.ps; ps2pdf -dAutoRotatePages=/None text50.ps long50.pdf

cat > photo.ps <<'EOF'
%!PS
<< /PageSize [595 842] >> setpagedevice
% full-bleed RGB axial shading
<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 595 842] /Extend [true true]
   /Function << /FunctionType 2 /Domain [0 1] /C0 [0.05 0.1 0.6] /C1 [1 0.85 0.2] /N 1 >> >> shfill
% radial "sun"
<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [300 500 0 300 500 220] /Extend [false false]
   /Function << /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0.8 0.1 0.1] /N 1.5 >> >> shfill
% saturated colour patches (RGB->gray conversion test)
0 1 11 { /i exch def i 12 div 1 1 sethsbcolor 30 i 45 mul add 120 40 80 rectfill } for
0 1 15 { /i exch def i 15 div setgray 30 i 34 mul add 40 30 60 rectfill } for
% fine checkerboard (halftone-like detail)
0 2 98 { /x exch def 0 2 98 { /y exch def x y add 4 mod 0 eq {0 0 0 setrgbcolor} {1 1 0 setrgbcolor} ifelse
  440 x add 700 y add 2 2 rectfill } for } for
showpage
EOF
ps2pdf photo.ps photo.pdf

printf '%%!PS\n<< /PageSize [595 842] >> setpagedevice\n0 setgray 0 0 595 842 rectfill showpage\n' > black.ps; ps2pdf black.ps black.pdf
printf '%%!PS\n<< /PageSize [595 842] >> setpagedevice\nshowpage\n' > blank.ps; ps2pdf blank.ps blank.pdf

cat > landscape.ps <<'EOF'
%!PS
<< /PageSize [842 595] >> setpagedevice
0.5 setlinewidth 20 20 802 555 rectstroke
/Helvetica-Bold findfont 36 scalefont setfont 60 500 moveto (LANDSCAPE  842 x 595  - top edge) show
/Helvetica findfont 14 scalefont setfont
0 1 25 { /i exch def 60 460 i 16 mul sub moveto (Landscape line ) show i 3 string cvs show
  (  The quick brown fox jumps over the lazy dog.) show } for
0 0 moveto 842 595 lineto stroke 700 60 moveto (bottom-right) show
showpage
EOF
ps2pdf -dAutoRotatePages=/None landscape.ps landscape.pdf

ps2pdf -sPAPERSIZE=a4 "$DRV/tests/testpage.ps" testpage.pdf
# 10-page mixed job for performance
qpdf --empty --pages testpage.pdf text.pdf photo.pdf black.pdf blank.pdf landscape.pdf photo.pdf -- mixed10.pdf
printf 'Plain text job for texttopdf\n%.0s' $(seq 1 120) > plain.txt

for f in testpage text photo black blank landscape mixed10 long50; do
  n=$(qpdf --show-npages "$f.pdf" 2>/dev/null)
  [ -n "$n" ] && result docs "$f" PASS "$n page(s), $(stat -c %s "$f.pdf") bytes" || result docs "$f" FAIL "not generated"
done
