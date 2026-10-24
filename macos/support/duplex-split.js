// Split a PDF for manual two-sided printing on a printer with a face-down output bin that
// feeds from the top of the input stack (HP LaserJet Pro MFP M125/M126/M127/M128).
//
//   osascript -l JavaScript duplex-split.js IN.pdf FRONTS.pdf BACKS.pdf
//   prints the number of pages of IN.pdf
//
// Pass 1 (FRONTS): pages 1, 3, 5, ... in order. They land face-down, the last one on top.
// The user puts the stack back in the tray printed side down, top edge first, without
// changing the order, so the sheet with the last odd page is fed first.
// Pass 2 (BACKS): even pages in reverse order. If the page count is odd, a blank page comes
// first: it goes on the back of the last sheet (which has nothing on its back). The finished
// stack then comes out in reading order, page 1 on top.
// Uses only PDFKit, which is part of macOS.
// SPDX-License-Identifier: MIT
ObjC.import('Foundation');
ObjC.import('Quartz');

function run(argv) {
  if (argv.length !== 3) throw new Error('usage: duplex-split.js IN.pdf FRONTS.pdf BACKS.pdf');
  var src = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
  if (!src || src.isNil()) throw new Error('cannot read PDF: ' + argv[0]);
  var n = src.pageCount;
  var fronts = $.PDFDocument.alloc.init;
  var backs = $.PDFDocument.alloc.init;
  var MEDIABOX = 0; // kPDFDisplayBoxMediaBox

  for (var i = 0; i < n; i += 2) fronts.insertPageAtIndex(src.pageAtIndex(i).copy, fronts.pageCount);

  if (n % 2 === 1 && n > 1) {
    var blank = $.PDFPage.alloc.init;
    blank.setBoundsForBox(src.pageAtIndex(n - 1).boundsForBox(MEDIABOX), MEDIABOX);
    backs.insertPageAtIndex(blank, 0);
  }
  for (var k = (n % 2 === 0 ? n - 1 : n - 2); k >= 1; k -= 2) {
    backs.insertPageAtIndex(src.pageAtIndex(k).copy, backs.pageCount);
  }

  if (!fronts.writeToFile(argv[1])) throw new Error('cannot write ' + argv[1]);
  if (n > 1 && !backs.writeToFile(argv[2])) throw new Error('cannot write ' + argv[2]);
  return String(n);
}
