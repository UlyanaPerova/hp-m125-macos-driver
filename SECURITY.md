# Security policy

## Reporting
Please report security problems **privately**, using the repository's
*Security → Report a vulnerability* page (GitHub private advisories), not public issues.
Expect a reply within 14 days.

## Design
- The filter runs inside the macOS printing system (`cupsd`) as the unprivileged printing
  user, under Apple's CUPS sandbox. It is never setuid.
- It reads one print job from standard input (or a file named by CUPS) and writes the
  printer data to standard output. It has no network code, starts no other programs and
  writes no other files.
- All sizes from the input are range-checked before use. The CI and VM tests include
  truncated and garbage input, AddressSanitizer/UBSan builds and valgrind.
- Root privileges are used only by the installer's `postinstall`, and by the helper apps
  after the standard macOS password prompt, to add or remove the printer queue and files.
