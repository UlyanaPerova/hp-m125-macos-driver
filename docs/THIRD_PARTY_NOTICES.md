# Third-party components and notices

This file lists everything from outside the project that the Software uses, at each stage.

## Shipped in the installer (`.pkg`)
| Component | Source | License | Notes |
|---|---|---|---|
| `rastertopclms` filter | this project | MIT | original code |
| PPD file | this project | MIT | paper sizes are from the public PWG 5101.1 media standard |
| Installer pages, helper apps, scripts | this project | MIT | local files only, no remote content |

**Nothing from anyone else is bundled.** The installer contains no fonts, images, web
scripts, SDKs, analytics or advertising libraries. The installer pages load no remote
content (no `http(s)://` references; checked automatically in CI).

## Used from macOS at run time (not distributed)
| Component | Provider | How it is used |
|---|---|---|
| libcups (CUPS raster API) | Apple Inc. (CUPS: Apache License 2.0) | dynamic link to the system library |
| libSystem / pthreads | Apple Inc. | dynamic link to the system library |
| `cgpdftoraster`, `usb` backend, `cupsd` | Apple Inc. | the macOS printing system runs the filter |
| AppleScript / `osascript` | Apple Inc. | helper apps |

## Used only to build and test (not distributed)
| Component | License | Use |
|---|---|---|
| Xcode Command Line Tools (clang, codesign, pkgbuild, productbuild) | Apple SDK terms | compiling and packaging on the GitHub macOS runner |
| GitHub Actions: `actions/checkout`, `actions/upload-artifact` | MIT | CI workflow |
| Python 3 standard library | PSF | test scripts (`tests/*.py`) |
| HPLIP 3.26.6 (hpcups, genPCLm) | GPL-2.0 / BSD (HP) | **reference only**: run as a separate program in the test VM so its output can be compared with ours. No HPLIP code is copied into this project. |
| Ghostscript, poppler-utils, qpdf, CUPS (Linux) | AGPL / GPL / Apache | test VM only |

## Interoperability note
The output format (PCLm, and HP's PCLm-S job-ticket comment layout) is reproduced so the
printer firmware accepts the jobs. Matching a data format for interoperability does not
copy any program code.

## Trademarks
HP and LaserJet are trademarks of HP Inc. Apple, macOS, MacBook and AirPrint are trademarks
of Apple Inc. They are used only to say what this Software works with. No endorsement is
implied.
