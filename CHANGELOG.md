# Changelog

## 1.0.0 — 2026-10-24
- First release: PCLm-S CUPS filter `rastertopclms` for HP LaserJet Pro MFP M125r
  (and M125/M126/M127/M128).
- Universal macOS binary (Apple Silicon + Intel). Multi-threaded compression that uses the
  performance cores on Apple Silicon.
- Double-click installer (English/Russian) with automatic USB printer setup, the helper apps
  "Set Up Printer" and "Uninstall", and a test page.
- Privacy Policy, Terms of Use, third-party notices, security policy.
- GitHub Actions: build, install and print-pipeline tests on macOS 15 and macOS 26.
- Hardening after VM test round 1: corrupt, cut-off or impossible raster headers are rejected
  with exit code 1, and so are jobs with no valid pages. A cancelled job stops within
  milliseconds and still leaves a well-formed file. Custom page sizes are named like HP's
  driver names them. 32-bit RGB input is supported.
- Paper sizes regenerated from the PWG 5101.1 standard (`tools/gen_ppd_sizes.py`).
