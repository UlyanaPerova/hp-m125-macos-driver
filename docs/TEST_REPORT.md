# m125-pclms test report: VM run 1

Driver under test: `driver/src/rastertopclms.c` (992 lines) + `driver/ppd/m125-pclms.ppd`, as of 2026-10-24.
Reference: HP's own `hpcups` (HPLIP 3.26.6, built from source) with HP's `hp-laserjet_pro_mfp_m125r.ppd`.
Raw logs: `logs/vm-run-1/` (`results.tsv` holds every check, one per line; `summary.txt` has the counts).
Re-run: inside the VM, `~/driver/tests/vm/run_all.sh` (optional stage names: `env build hpref docs golden options e2e robust perf`).

**Bottom line.** Our output is structurally the same as HP's for every standard page size, document type and option tested. Only stream bytes, xref offsets and the job time differ. The one exception is the ticket's `media-size-name` for custom page sizes. Fed the same raster, the decoded pixels match HP's to within one gray level. The places that differ are a 1–4 px black column that hpcups itself adds, where our page is correctly white. The filter is fast (about 7 ms per A4 page, about 7× faster than hpcups). valgrind, ASan, UBSan and TSan found no problems. Three robustness bugs are real (B1–B3). None of them affects normal printing.

## 1. Environment

| Item | Value |
|---|---|
| VM | multipass `m125-test`, Ubuntu 24.04.5 LTS, kernel 6.8.0-147, 8 vCPU, 7.9 GB |
| Toolchain | gcc 13.3.0, CUPS 2.4.7 (libcups2t64), cups-filters 2.0.0, Ghostscript 10.02.1, poppler 24.02, qpdf 11.9, valgrind 3.22, Python 3.12 + numpy 1.26 |
| HP reference | `~/hplip-build/hplip-3.26.6/hpcups`, built with `./configure --disable-network-build --disable-scan-build --disable-gui-build --disable-fax-build --disable-dbus-build --disable-qt5 --disable-qt4 --enable-hpcups-install --disable-hpijs-install --disable-doc-build --disable-pp-build --disable-cups-drv-install --enable-cups-ppd-install && make hpcups`. It needs `LD_LIBRARY_PATH=.../prnt/hpcups` for the bundled `libImageProcessor.so`. |
| Distro hpcups | printer-driver-hpcups 3.23.12. This version needs **no plugin** for hbpl1: `Hbpl1.cpp` constructs `Hbpl1Wrapper` directly, and `models.dat` says `plugin=0`. Its output matched 3.26.6 exactly (masked structure and pixels; `golden/distro_hpcups_equivalent` PASS). It was used for the HP CUPS queue in the end-to-end tests. |
| Rasters | `cupsfilter -p <PPD> -m application/vnd.cups-raster -o PageSize=…` (pdftopdf + gs). This gives v3 little-endian rasters (`3SaR`). HP's PPD makes 8-bit RGB (`cupsColorSpace 1`); ours makes 8-bit W gray. |

## 2. Build (task 1)

* `make` gives a clean build with **0 warnings** under `-Wall -Wextra`. The binary is 34,856 bytes.
* **`-lcupsimage` is not needed on Ubuntu 24.04.** The binary imports only `cupsRasterOpen/ReadHeader2/ReadPixels/Close`, which have lived in libcups2 since CUPS 2.2. `-lcups -lpthread` is enough, so no Makefile change is needed for linking.
* `pkg-config --variable=cups_serverbin cups` returns `/usr/lib/cups`, so the filter installs to `/usr/lib/cups/filter/rastertopclms`. pkg-config was not installed at first; the Makefile's `|| echo /usr/lib/cups` fallback gives the same path.
* Minor (B5): `make` (target `all`) does **not** generate `ppd/m125-pclms.installed.ppd`. Only `make install` does. The substitution itself is correct.
* Stricter flags: 1 warning (`-Wdouble-promotion`, line 679), which is harmless. `gcc -fanalyzer` gave 0 warnings.
* Extra builds: ASan+UBSan (`-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all`) and TSan both built and ran. TSan must run under `setarch -R` on this kernel.
* `cupstestppd -W all` on our PPD: **PASS**. The only warnings are Adobe-name size warnings, which HP's PPD has too.

## 3. Results summary

535 checks: **422 PASS, 82 INFO, 31 FAIL**. The 31 FAILs come from 3 root causes plus one cosmetic difference:

| Area | Checks | Result |
|---|---|---|
| Build, link, PPD lint, sanitizer builds | 13 | PASS (Makefile note B5) |
| Golden vs HP: geometry (MediaBox, strip W/H, strip count, top-margin strips, every `cm` line), 6 docs × 7 sizes | 42 | **42/42 PASS** |
| Golden: masked text structure identical | 42 | 36 PASS; 6 FAIL = custom size `media-size-name` only (B4) |
| Golden: pixels, ours vs HP on the same RGB raster | 42 | **42/42 PASS** (max diff 1, or HP artefact column, see §4.3) |
| Golden: our output == input raster inside printable area | 42 | 42/42 PASS |
| Golden: job ticket equal | 42 | 36 PASS; 6 FAIL (B4) |
| `verify_pclm.py` accepts HP output (checker sanity) | 42 | 42/42 PASS |
| `verify_pclm.py --raster` on our output | 42 | 27 PASS; 15 checker false positives (C1, logged as INFO) |
| Options: ticket and structure vs HP (23 option sets) | 23 | **23/23 PASS** |
| End-to-end CUPS queues (13 jobs, ours + HP) | 32 | 30 PASS; 1 FAIL (B4, custom); 1 INFO |
| Robustness (release + ASan/UBSan, 50 inputs) | 103 | 83 PASS; 18 FAIL (B1 ×16, B2 ×2); 2 INFO |
| valgrind memcheck (2-page job and truncated job) | 2 | PASS: 0 errors, 0 bytes definitely/indirectly/possibly lost |
| TSan (50 pages, 2 and 8 threads); determinism across thread counts | 3 | PASS |
| Performance | 11 | INFO (§6) |

## 4. Golden comparison vs HP (task 3)

Documents: `testpage` (tests/testpage.ps, 2 pages), `text` (3 pages, 6–18 pt, 5 fonts), `photo` (full-bleed RGB axial and radial shading, colour patches, 16 gray patches, checkerboard), `black` (full page), `blank`, `landscape` (842×595 page). Sizes: A4, Letter, Legal, A5, A6, EnvDL, Custom.300x500. Each case is in `logs/vm-run-1/golden/<case>/`: `struct.diff`, `geometry.json`, `pixels.json`, `tickets.json`, `rascheck_*.json`, `summary.json`. The overview table is `golden/summary.tsv`.

### 4.1 Text structure differences (stream bytes removed)

After removing strip streams, every remaining difference is one of these:

| Difference | Explanation |
|---|---|
| `job-start-time` | Wall clock. The format is identical: HP uses `asctime` + `:%ld` ms unpadded + year (HPCupsFilter.cpp:565). |
| `/Length` of strip streams, xref offsets, `startxref` | Different pixel content (gray vs RGB raster) and a slightly different RLE encoder (§6.3). With the same raster, most strips are byte-identical. |
| `media-size-name` for **custom** sizes only | HP sends `cupsString0`, or if that is empty `cupsPageSizeName` (`105.83x176.38mm` via cupsfilter; inside a CUPS queue the stale default `na_letter_8.5x11in`). We send `custom_4.17x6.94in`. See B4. |

Everything else is byte-for-byte identical to HP. That covers header, ticket layout and all other keys, `genPCLm (Ver: 0.930000)`, object order and numbering, the `q /image Do Q` objects, `/Name /WhiteStrip|/ColorStrip` per strip, the content stream text and the xref/trailer layout.

### 4.2 Geometry (identical to HP in all 42 cases)

Example, A4 at 600 dpi:

* MediaBox `[0 0 595 842]`, CTM `0.120000 0 0 0.120000 0 0`.
* Strips are 4958 px wide, the full media width. There are 108 strips per page.
* Top margin: one injected white strip of 64 lines and one of 52 lines (116 lines in total).
* The first `cm` is `4958 0 0 64 0 6953`; the last is `4958 0 0 63 0 118`. The last image strip is 64 lines high, white-padded, and placed with height 63.
* The left margin is 116 px.

Both drivers derive the printable size from the *integer* `ImagingBoundingBox`, as hpcups does (HPCupsFilter.cpp:446-447 vs our lines 525-531). As a result:

* When the raster (`cupsWidth`, from the float bbox) is 1–2 px **wider**, both crop the last 1–2 columns. A4: 4727 → 4725. This is invisible, because the columns sit inside the 14 pt margin.
* When it is **narrower** (A5, A6, EnvDL, Custom: printable width 1–4 px larger than `cupsWidth`), see §4.3.

### 4.3 Pixels

Two comparisons were run:

* **(i) Same RGB raster** (HP's raster fed to both filters). This isolates the encoder.
* **(ii) Normal path** (each driver with its own PPD: HP renders RGB, we render gray directly).

| Case | (i) differing px / max | (ii) differing px / max | Notes |
|---|---|---|---|
| testpage A4 (2 p, 69.6 Mpx) | 544,086 / **1** | 544,116 / 255 | (ii): 30 px ≥64 at glyph or line edges, where gs rasterizes gray and RGB differently |
| text A4/Letter/Legal (3 p) | 0 | 0 | pure black text is identical |
| photo A4 (34.8 Mpx) | 377,253 / **1** | 26,962,525 / 71 | (ii) histogram: 8.57 M px off by 1, 5.26 M by 2–3, 8.59 M by 4–15, 4.32 M by 16–63, 0.22 M by 64+. gs renders smooth shading differently in DeviceGray than HP's RGB → gray. |
| black A4/Letter/Legal | 0 | 0 | |
| landscape A4 | 0 | 20 / 255 | |
| any A5/A6/EnvDL/Custom page | 1-level diffs, plus 3,348–25,227 px at 255 | same | the 255 diffs are **all in 1–3 columns right of the raster** (e.g. A5 cols 3379-3381) |

* **1-level differences** come from luma rounding. HP computes `(ubyte)(0.299r+0.587g+0.114b)` in double (genPCLm.cpp:176). For many neutral grays that truncates to v−1, for example 128,128,128 → 127. We use exact fixed-point weights that sum to 65536, so neutral gray stays v. HP is always the darker one (`a_darker` = all). It is not visible on a laser printer.
* **255-level columns at the right edge are an hpcups defect, not ours.** When the bbox-derived printable width is larger than `cupsWidth`, hpcups converts and copies `printable_width` pixels from a line that holds only `cupsWidth`. The extra 1–3 pixels per row come out **black (0)**. HP's driver would therefore print a 0.04–0.13 mm vertical black line along the right printable edge on A5, A6, EnvDL and custom pages, on every row, even for blank-ish text pages. Our driver keeps those columns white (copy_w, line 920). This is a deviation from HP that is in our favour.
* Our output equals the input raster inside the printable area in all 42 cases (`rascheck`). Outside the raster area our page is white.

### 4.4 Ticket values (options, 23 option sets, all identical to HP)

| Option | Ticket |
|---|---|
| OutputMode FastRes600 / FastRes1200 / Draft | `print-quality: 1 / 2 / 0` (the raw OutputType, same as HP); `printer-resolution: 600` in all cases. FastRes1200 is still a 600 dpi raster in both PPDs. |
| EconoMode=True (with any OutputMode) | `print-quality: draft` |
| InputSlot Manual / tray1 | `media-source: manual / tray_1` |
| MediaType: all 15 choices common to both PPDs | e.g. `Stationery`, `light`, `heavy`, `envelope`, `transparencyMonoLaser`, `stationery-letterhead` |
| Always | `copies: 1`, `orientation-requested: 0`, `sides: one-sided`, `output-bin: top_output`, `print-rendering-intent: none` (same as HP) |

PPD differences (`build/ppd_option_diff.txt`), informational:

* HP has MediaType `Auto`, `HPEcoSMARTLite`, `Vellum`, OutputMode `ImageREt2400`, and ColorModel `KGray`/`Mono`. We do not.
* We have an extra `Resolution` option (600 dpi only).
* The default page size is A4 for us and Letter for HP.
* We render W gray where HP renders RGB, as intended.
* Our 216x340mm ImageableArea/PaperDimension (612×964) fixes HP's copy-paste error (612×936).

## 5. End-to-end through CUPS (task 4)

Setup:

* Ran `sudo make install`; `lpinfo -m` lists `lsb/usr/m125-pclms/HP LaserJet Pro MFP M125r PCLmS.gz`.
* Added `FileDevice Yes` to cups-files.conf.
* Created queue `m125ours` with `file:///tmp/out-ours.pclm` and queue `m125hp` with HP's PPD and distro hpcups.

Note for the harness: CUPS 2.4.7 opens `file:` URIs with `O_WRONLY|O_EXCL`, without `O_CREAT` or `O_TRUNC`. The output file must already exist and must be emptied before each job; otherwise the job stops with "scheduler could not open the output file". `stage_e2e.sh` handles this.

| Job | Pages ours/HP | Result |
|---|---|---|
| text 3 p | 3/3 | PASS; structure identical to HP |
| testpage `-n 3` | 6/6 | PASS. Copies are made upstream (`cupsManualCopies`); the ticket says `copies: 1`, as HP's does. |
| text `-n 2 -o collate=true` | 6/6 | PASS, identical |
| text `-o landscape`; landscape.pdf | 3/3; 1/1 | PASS, identical (rotation is done by pdftopdf) |
| Letter, Legal, `media=A5`, EnvDL | 2/2 each | PASS, identical |
| Custom.300x500 | 2/2 | FAIL: only `media-size-name` differs (HP sends the stale `na_letter_8.5x11in`), B4 |
| EconoMode+Draft+Manual+Heavy | 2/2 | PASS, ticket identical |
| plain .txt (texttopdf), `page-ranges=2-4` of 50 p | 2/2, 3/3 | PASS |

The CUPS error_log (debug level) has **no ERROR/WARNING lines from rastertopclms**, no stopped or failed jobs, and the queue stayed enabled. HP's PPD defaults to Letter, so the HP queue was set to A4 to make the outputs comparable.

## 6. Performance (task 6)

Workload: 10-page mixed A4 job (testpage ×2, text ×3, photo ×2, black, blank, landscape), on rasters made in advance and already in page cache. Median of 3 runs. Wall time is measured with ns resolution.

| Filter | Input | ms/page | user s (10 p) | max RSS | bytes/page |
|---|---|---|---|---|---|
| ours, PCLMS_THREADS=1 | gray 8-bit | 12.2 | 0.08 | 8.0 MB | 1,109,580 |
| ours, 2 threads | gray | 8.9 | 0.08 | 8.9 MB | same |
| ours, 4 threads (default here) | gray | 7.2 | 0.10 | 10.0 MB | same |
| ours, 8 threads | gray | 6.5 | 0.11 | 12.4 MB | same |
| ours, 1 / 4 threads | HP's RGB raster | 30.0 / 26.0 | 0.26 / 0.27 | 8–10 MB | 1,112,351 |
| hpcups 3.26.6 | RGB | 52.2 | 0.46 | 20.2 MB | 1,107,144 |
| hpcups 3.23.12 (distro) | RGB | 51.0 | 0.45 | 20.1 MB | 1,107,144 |

* On the same input we are about 2× faster than hpcups. On our normal gray path we are about 7× faster, with half the memory.
* More than 4 threads gains little (the code clamps the default to 4).
* Output is the same for any thread count: PCLMS_THREADS=1, 2, 3, 4, 8, 16, 64, three runs each, gave the same digest of masked structure plus all stream bytes.

### 6.3 Output size

On the same raster, our total RLE size is 1.005× HP's (`perf/size_per_page.tsv`). Pages 2–10 are within ±15 bytes. The testpage gradient page is 1.038× (a slightly different run/literal split). Both encoders emit the same code set: repeat runs of 2–128, literals up to 128, EOD 128, runs crossing row boundaries. On the testpage, both have 1,884 two-byte repeats and 993 one-byte literals, so the firmware's decoder sees nothing new.

## 7. Robustness (task 5)

All inputs were run with the release and the ASan+UBSan binaries (`robust/summary.tsv`, stderr per case):

* There were **no crashes, no signals and no sanitizer reports** in any case.
* valgrind memcheck on the 2-page job: 0 errors, 0 leaks. Only 22,256 bytes are "still reachable", inside libcups/gnutls.
* helgrind's 2 reports are inside libp11-kit's destructor, not in our code.
* TSan found no races.

Correct behaviour:

* These exit 1 with a clear ERROR: empty file, empty stdin, missing file, random garbage, truncated in the middle of page 1 or 2 (the pages written so far stay valid PCLm), CMYK, RGBW, resolution 0 or 7, header with no data.
* These convert pixel-exactly:
  * 1-bit W/K;
  * 8-bit W/K/RGB/sRGB;
  * 16-bit W/K/RGB from `gs -sDEVICE=cups`;
  * 300 and 1200 dpi.
* These are handled without error: non-square resolution (with a WARNING), inverted or oversized bbox, huge Margins, PageSize 0, PageSize 2³²−1, a 100,000 pt tall page, a 3,000,000 pt wide page (0.95 s, 1 page), 300 small pages.
* The 50-page job: 50 pages, valid output.

## 8. Bugs

**B1 — Medium. Exit code 0 and an empty or short document when a page header is invalid.**

Repro (in the VM):

```
cd ~/m125-work && { printf 'RaS3'; head -c 200000 /dev/urandom; } > g.ras
~/driver/rastertopclms 1 u t 1 "" g.ras > o.pclm; echo $?
```

* **Observed:** `0`, stderr `WARNING: no pages in job`, and o.pclm is a valid PDF with `/Count 0`. The same happens with:
  * a raster cut inside the first header (`head -c 1000 two.ras`);
  * headers that libcups rejects (cupsHeight 0, cupsWidth 0, cupsBytesPerLine not matching, bpp 24 with 1 colour, banded RGB);
  * a file truncated inside page 2's header, which gives exit 0 with 1 page; page 2 is silently dropped.
* **Expected:** nonzero exit so CUPS marks the job failed, at least when no page was produced.
* **Cause:** the `while (!canceled && cupsRasterReadHeader2(...))` loop (line 848) treats every header failure as end of job. Lines 968-969 only log a WARNING, and `status` stays 0 (line 991).
* **Suggested fix:** `if (page == 0) status = 1;`. Optionally, treat a non-empty remainder after the last good page as an error.

**B2 — Medium. SIGTERM mid-job writes an invalid PDF, and the exit code is 0.**

Repro:

```
~/driver/rastertopclms 1 u t 1 "" fifty.ras > t.pclm & p=$!; sleep 0.15; kill -TERM $p; wait $p; echo $?
python3 -I ~/driver/tests/vm/pclmtool.py info t.pclm
```

* **Observed:** rc 0, and `page 23: image object 4837 missing (dangling reference)`. With stdin stalled in the middle of page 1, page 1 references objects that were never written.
* **Cause:**
  * `write_page_header()` (line 897) lists every strip of the page in `/XObject` up front (lines 670-671).
  * The strip loop stops on `canceled` (line 921) and the skip loop at 952 also stops.
  * `write_trailer()` still runs (lines 970-973), so the trailer points at a page whose images don't exist.
  * Cancel never sets `status`.
* **Why it matters:** over USB the partial file has already gone to the printer. A well-formed tail is what lets the firmware finish or eject cleanly instead of waiting or erroring.
* **Suggested fix:** on cancel, emit white strips for the rest of the current page (or drop the page from `/Kids`) before the trailer, and return 1. If CUPS convention for cancel is 0, document that choice.

**B3 — Low. Cancel latency while blocked on input.** With stdin stalled, the filter kept running 2.5 s after SIGTERM, until data arrived again. libcups retries `read()` on EINTR, and `canceled` is only checked between strip batches and pages (lines 848, 921). This is harmless for CUPS, which sends SIGKILL later. A fix is to also check `canceled` per line inside the read loop (line 931).

**B4 — Low/Medium (firmware unknown). `media-size-name` for custom sizes differs from HP.**

* Repro: `-o PageSize=Custom.300x500` (golden `*_Custom.300x500`, e2e `custom`).
* We send `custom_4.17x6.94in`, which comes from `media_name_from_size()` (line 489) when `cupsString0` is empty (lines 565-568).
* HP sends `cupsString0`, or else `cupsPageSizeName` (`105.83x176.38mm`); in a queue it sends a stale `na_letter_8.5x11in`.
* Our name also lacks the `<name>` part of the PWG 5101.1 self-describing form `custom_<name>_<W>x<H><unit>`.
* The firmware probably sizes from the MediaBox and only logs the name, but this is untested.
* Option for maximum HP compatibility: fall back to `h->cupsPageSizeName` as HP does.

**B5 — Cosmetic. The `make` default target doesn't build `ppd/m125-pclms.installed.ppd`.** The Makefile has `all: rastertopclms`. Add the PPD target to `all` if `make` is meant to produce it.

### Issues in the test checker `tests/verify_pclm.py` (not driver bugs; I did not edit it)

* **C1 — false failures.** It compares the full `cupsWidth` of each raster row, but HP and we both crop to the integer-bbox printable width (1–2 px). It also guesses the offset from the first non-white row with `row.find()`, so a cropped first row makes it lock onto a wrong offset. Examples: "page 2: 1753 rows differ" on testpage A4 and "6782 rows differ" on photo A4. Our own `pclmtool rascheck` (which checks HP's documented offset and searches) shows 0 differences inside the printable area.
* **C2.** For 16-bit little-endian rasters it takes the low byte. gs `w16` gives FAILED although the output is pixel-exact.
* **C3.** It crashes with `KeyError` on dangling references (B2 output) instead of reporting them.
* **C4.** It is quadratic: `buf[int(off):].startswith` copies the file for each xref entry, so a 50-page, 76 MB file takes 75 s.
* **C5.** It treats colorspace 17 (RGBW) as RGB. sRGB is 19.

## 9. Deviations from HP that might matter to the printer

1. **Custom-size `media-size-name`** (B4). This is the only ticket difference anywhere.
2. **Gray values:** with the same raster we are off by 1 level on about 1% of pixels, always one level *lighter* than HP for neutral grays. Through the normal path the gs gray rendering differs more on smooth shading (max 71 levels, photo). Neither should matter to firmware.
3. **Right-edge column on A5/A6/EnvDL/custom:** HP's driver produces a black 1–3 px column there; ours is white. Ours is the correct output.
4. **RLE stream bytes** differ slightly on some strips. Both are valid RunLengthDecode, use the same code repertoire, and decode to the same pixels.

Everything else the printer sees is byte-for-byte HP's layout: header, tickets, object order, strip sizes, margin injection and placement.

---

# Round 2 (after fixes for B1–B5)

**Result: 638 checks, 545 PASS, 92 INFO, 1 FAIL. The one FAIL is HP-side, not ours (see R2-1). No driver bugs remain from round 1.**

Logs are in `logs/vm-run-2/`. The robust stage was run a second time after I fixed how the test measured cancel latency (`NOTE.txt`); the first attempt is kept in `robust.first-attempt/`.

The driver was copied to the VM fresh (`src/rastertopclms.c` md5 8ae9af98…, `ppd/m125-pclms.ppd` bdaa76ea…, `tests/verify_pclm.py` ebd6d86d…). The round-1 copy is kept as `~/driver.round1`.

## What I changed in the tests

* **Golden:** added 12 sizes (testpage only): B5, B6, Postcard, DoublePostcardRotated, EnvChou3, EnvISOB5, 184x260mm, 195x270mm, plus renamed keywords mapped as ours=HP: `roc16k=Envroc16k`, `Oficio=216x340mm`, `FanFoldGermanLegal=8.5x13in`, `100x150mm=10x15`.
  * Each case compares the two PPD size entries (`golden/<case>/ppd_size_diff.txt`).
  * If geometry, structure or ticket differ and the PPD entries also differ, the result is INFO with the numbers. If the PPD entries match, it is FAIL.
* **Robust:** the expected results now follow the new rules:
  * a file truncated inside page 2's header must now fail;
  * page size, margins or bbox above 3000 pt must fail;
  * 32-bpp RGBW and RGBA must work, pixel-checked.
* **SIGTERM:** the checks are rewritten. Each one needs rc 1, exit within 1 s, and a valid file after a mid-page cancel.
  * Five delays on a 50-page file, an ASan run, a mid-page stall and a stall between pages.
  * Latency is now measured when the filter itself exits. Round 1 used `wait`, which also waited for the stalled feeding pipeline, so its 2.5 s figure was mostly a test artefact.

## Results

| Area | Round 2 |
|---|---|
| Build | `make` now also builds the installed PPD (B5 fixed). 0 warnings. cupstestppd PASS. |
| Golden, 54 cases (42 as in round 1 + 12 new sizes) | **0 FAIL.** Geometry identical to HP in 50 cases. Ticket and structure identical except where intended. Custom.300x500 now gives `105.83x176.38mm`, the same as HP (B4 fixed). |
| Golden pixels, same RGB raster | all PASS (luma ±1, plus HP's black right-edge column on A5, A6, DL and custom) |
| `verify_pclm.py --raster` on our output | **54/54 PASS.** All 15 round-1 false failures are gone, so those were checker issues, now fixed. It still accepts all HP output. |
| Options (23) | 23/23 identical to HP |
| E2E (13 jobs) | 30 PASS; 1 FAIL (R2-1) |
| Robust (release + ASan/UBSan) | **107 PASS, 0 FAIL.** All bad input exits 1 with no crash: garbage, header cut off, page-2 header cut off, invalid headers, sizes over 3000 pt. gs RGBW-32 and RGBA-32 are pixel-exact. valgrind shows 0 errors and 0 leaks. TSan is clean. Output is identical for any thread count. |
| SIGTERM | Mid-page cancel: rc 1, exit in 7 ms (ASan: 14 ms), the file is valid PCLm with the pages done so far; checked at 0.05, 0.1, 0.2 and 0.3 s and with stdin stalled mid-page. Cancel between pages: rc 1, exit in 1 ms, the file has no trailer (by design, INFO). The 0.5 s run had already finished before the signal was sent (INFO, not a cancel test). |

### Size changes vs HP (INFO, from the PPD regeneration)

| Size (ours / HP keyword) | PPD (pt) ours vs HP | Effect in PCLm (HP → ours) |
|---|---|---|
| 184x260mm | 521.57×737.01 vs HP PaperDimension 525×720 (HP's ImageableArea is 511×706) | MediaBox 525×720 → 522×737, strip width 4375 → 4350, strips 93 → 95; name prc_16k → om_16k_184x260mm |
| roc16k / Envroc16k | 558×774 vs HP PaperDimension 554×774 | MediaBox 554 → 558 wide, strip width 4617 → 4650; name prc_16k_197x273mm → roc_16k_7.75x10.75in |
| Oficio / 216x340mm | 612×964.8 vs HP 612×936 (HP PPD typo) | MediaBox 612×936 → 612×965, strips 121 → 124; name na_legal_216x340mm → na_oficio_8.5x13.4in |
| 100x150mm / 10x15 | 283.46×425.2 vs HP 288×432 (HP's "10x15" is really 4×6 in) | MediaBox 288×432 → 283×425, strip width 2400 → 2358, strips 55 → 54 |
| 195x270mm | name only | om_16k_195x270mm instead of prc_16k_195x270mm (structure diff = ticket name only) |

* **Same geometry as HP:** the A4, A5, A6, EnvDL, B5, B6, Postcard, DoublePostcard, EnvChou3, EnvISOB5 and FanFoldGermanLegal definitions changed by fractions of a point, but every one still produces PCLm geometry identical to HP's. CUPS rounds them to the same integer PageSize and bounding box.
* **Not visible in the tests:** the 1–2 mm printable-area changes that the coordinator listed for B5, B6, hagaki, oufuku, DL, ISO B5 and Chou3 don't show up, because both drivers truncate the bounding box to whole points.

### Remaining FAIL

**R2-1. E2E custom size via a CUPS queue (`custom.vs_hp`).**

* In HP's queue, the raster carries a stale `cupsString0 = na_letter_8.5x11in`. HP's PPD has `*RequiresPageRegion All: True` and a default of Letter, so the Letter PageRegion code runs before the custom size.
* Our queue's raster has an empty `cupsString0`, so we send `cupsPageSizeName` (`105.83x176.38mm`).
* Through `cupsfilter` both drivers give the same name. So the naming rule is the same as HP's, and the difference comes from the PPD, not the filter.
* No driver action needed. If anything, HP's value is the wrong one.

## Performance (round 2, 10-page A4 job, median of 3)

| Filter | ms/page | max RSS |
|---|---|---|
| ours, 1 / 2 / 4 / 8 threads, gray | 12.8 / 9.7 / 8.9 / 7.5 | 8.1–12.5 MB |
| ours, default (4 threads) | 8.3 | 10.0 MB |
| ours on HP's RGB raster, 1 / 4 threads | 31.8 / 28.1 | 8–10 MB |
| hpcups 3.26.6 / distro 3.23.12 | 61.3 / 61.3 | 20.2 MB |

These are about 10% slower than round 1 for every filter, hpcups included, so the VM was busier; ours vs HP is unchanged. Output is about 1.11 MB per page, the same as round 1.
