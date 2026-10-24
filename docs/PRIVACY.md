# Privacy Policy — m125-pclms printer driver

*Effective date: 24 October 2026. Applies to version 1.0 and later.*

**Summary: the driver collects no personal data, sends nothing over the internet, and keeps no
copies of what you print.**

## What the driver does with your documents
When you print, macOS converts the document into a page image and hands it to the driver
(`rastertopclms`). The driver converts that image into the printer's format and passes it
straight on to the printer over USB. It processes the pages in memory and doesn't save
them to disk, upload them or analyse them.

## Data that is processed
| Data | Why | Where it goes |
|---|---|---|
| Page images of the document you print | to produce the print job | only to your printer, through macOS's printing system |
| Job number, your macOS user name, document title | macOS passes these to every printer driver | the job number goes to the printer in the job header; the user name and title are not used |
| Paper size, tray, quality settings | to print correctly | to your printer |

## Network and tracking
The driver and its helper apps have **no network code**. They contain no analytics,
advertising, telemetry, crash reporting or update checks.

## Logs
- The driver writes short technical messages (page count, page size, errors) to the
  macOS printing log, `/var/log/cups/error_log`. This log is managed by macOS, stays on
  your Mac and does not contain the document's content.
- The installer and the "Set Up Printer" app write install steps (date, the printer's USB
  address, the printer name) to `/Library/Logs/m125-pclms-install.log` on your Mac.
- macOS itself keeps a history of completed print jobs (document name, date). This is a
  standard macOS feature and not part of the driver. You can clear it in the printer's queue window.

## Drag-and-drop printing ("Print with HP M125r")
When you drop an office document on this app, it asks the program that understands it
(Pages, Numbers, Keynote, Microsoft Word or LibreOffice) to save a PDF copy, then prints that
copy. macOS asks you once to allow this ("…wants access to control Pages"). You can withdraw the
permission at any time in **System Settings → Privacy & Security → Automation**. The PDF copy
is written to a private temporary folder on your Mac and deleted right after the print job is
handed to macOS. Nothing is uploaded.

## Permissions
Installing asks for an administrator password once, because printer drivers must be
installed in `/Library/Printers`. The helper apps ask for the password only to add or
remove the printer.

## Third parties
There are none. The driver is not made by, affiliated with or endorsed by HP Inc.
"HP" and "LaserJet" are trademarks of HP Inc. and are used here only to name the
printer the driver supports.

## Removing the driver
Open **Applications → HP M125r Driver → Uninstall**. It removes the driver, its helper
apps and the printer entries that use it.

## Children
The driver collects no data from anyone, including children.

## Changes and contact
Changes to this policy will be published together with new versions of the driver, in
this file. Questions: open an issue in the project's repository.
