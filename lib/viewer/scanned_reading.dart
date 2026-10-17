import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../core/scanned_text.dart';
import '../platform/ocr_channel.dart';

/// A page drawn as an image: blue, green, red, alpha bytes.
typedef PageImage = ({int width, int height, Uint8List bgra});

/// The longer side of a page drawn for reading: enough for ordinary print
/// (about 240 dots per inch on A4) without using much memory.
const scannedPageSide = 2800;

/// Reads [pages] (the PDF's own page numbers) of [documentId] with
/// [reader]'s model [modelId]: each page is drawn by [render], read, and
/// kept in [store] straight away, so stopping (or closing the PDF) loses
/// at most the page being read. [onPage] gets pages done, the total and
/// how long the page took; stops before the next page once [stop] says
/// so. True if every page was read.
Future<bool> readScannedPages({
  required String documentId,
  required List<int> pages,
  required ScannedTextStore store,
  required TextReaderService reader,
  required String modelId,
  required Future<PageImage?> Function(int page) render,
  required void Function(int done, int total, Duration took) onPage,
  required bool Function() stop,
}) async {
  var done = 0;
  for (final page in pages) {
    if (stop()) return false;
    final started = DateTime.now();
    final image = await render(page);
    if (stop()) return false;
    var lines = const <ScannedLine>[];
    if (image != null) {
      final read = await reader.read(
        modelId,
        image.width,
        image.height,
        image.bgra,
      );
      lines = scannedLines(read, image.width, image.height);
    }
    await store.savePage(documentId, page, lines);
    done++;
    onPage(done, pages.length, DateTime.now().difference(started));
  }
  return true;
}

/// Draws [document]'s page [page] (1-based) for reading, white behind it,
/// with its longer side [scannedPageSide] pixels (smaller pages aren't
/// made larger than that). Null if it can't be drawn.
Future<PageImage?> renderForReading(PdfDocument document, int page) async {
  if (page < 1 || page > document.pages.length) return null;
  final p = document.pages[page - 1];
  final longer = p.width > p.height ? p.width : p.height;
  if (longer <= 0) return null;
  final scale = scannedPageSide / longer;
  final w = (p.width * scale).round(), h = (p.height * scale).round();
  final image = await p.render(
    width: w,
    height: h,
    fullWidth: w.toDouble(),
    fullHeight: h.toDouble(),
    backgroundColor: 0xFFFFFFFF,
    annotationRenderingMode: PdfAnnotationRenderingMode.none,
  );
  if (image == null) return null;
  try {
    return (
      width: image.width,
      height: image.height,
      bgra: Uint8List.fromList(image.pixels),
    );
  } finally {
    image.dispose();
  }
}

/// How many letters or digits PDFium finds as printed text on the first
/// [sample] pages of [document], for [looksScanned].
Future<List<int>> printedCharsOnFirstPages(
  PdfDocument document, {
  int sample = 5,
}) async {
  final n = document.pages.length < sample ? document.pages.length : sample;
  return [
    for (var i = 0; i < n; i++)
      textChars((await document.pages[i].loadText())?.fullText ?? ''),
  ];
}
