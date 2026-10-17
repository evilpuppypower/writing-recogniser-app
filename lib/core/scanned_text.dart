/// Text read from scanned PDFs (owner, 2026-10-17: asked once per PDF,
/// read on the tablet), kept by the PDF's own page numbers with each
/// line's box, so it can be searched and shown where it is. Pure Dart:
/// the SQLite store lives in lib/storage.
library;

import 'dart:convert';

/// A line of text read from a scanned page. Its box is a share (0..1) of
/// the page's width and height as the page is shown, from the top left.
typedef ScannedLine = ({
  double left,
  double top,
  double right,
  double bottom,
  String text,
  double confidence,
});

/// What to do when a PDF looks scanned: ask (the default), read it, or
/// leave it.
enum ScannedChoice { ask, read, leave }

/// Lines the reader is less sure of than this are left out: on a scan
/// they're nearly always smudges or pictures read as letters.
const scannedMinConfidence = 0.5;

/// A page counts as having printed text with at least this many letters
/// or digits.
const scannedPageTextChars = 20;

/// Whether a PDF looks scanned, from how many letters or digits PDFium
/// found as printed text on some of its pages ([charsPerPage], usually
/// the first few): most of them have almost none. (A scanned page is a
/// picture, so PDFium finds no text; a PDF already read by another app
/// has text, and isn't asked about.)
bool looksScanned(List<int> charsPerPage) {
  if (charsPerPage.isEmpty) return false;
  final empty = charsPerPage.where((c) => c < scannedPageTextChars).length;
  return empty * 5 >= charsPerPage.length * 4;
}

/// How many letters or digits [text] has.
int textChars(String text) =>
    RegExp(r'[\p{L}\p{N}]', unicode: true).allMatches(text).length;

/// The reader's lines from an image of a page [width] x [height] pixels,
/// as shares of the page, without empty or doubtful ones.
List<ScannedLine> scannedLines(
  Iterable<
    ({int left, int top, int right, int bottom, String text, double confidence})
  >
  read,
  int width,
  int height,
) => [
  for (final l in read)
    if (l.text.trim().isNotEmpty && l.confidence >= scannedMinConfidence)
      (
        left: (l.left / width).clamp(0.0, 1.0),
        top: (l.top / height).clamp(0.0, 1.0),
        right: (l.right / width).clamp(0.0, 1.0),
        bottom: (l.bottom / height).clamp(0.0, 1.0),
        text: l.text.trim(),
        confidence: l.confidence,
      ),
];

/// A page's scanned text for searching, line by line.
String scannedPageText(List<ScannedLine> lines) =>
    lines.map((l) => l.text).join('\n');

String encodeScannedLines(List<ScannedLine> lines) => jsonEncode([
  for (final l in lines)
    [
      _round(l.left),
      _round(l.top),
      _round(l.right),
      _round(l.bottom),
      l.text,
      _round(l.confidence),
    ],
]);

double _round(double v) => (v * 10000).roundToDouble() / 10000;

/// Lines from [encodeScannedLines]; anything that doesn't fit is left out.
List<ScannedLine> decodeScannedLines(String json) {
  final out = <ScannedLine>[];
  try {
    for (final e in jsonDecode(json) as List) {
      if (e is! List || e.length != 6) continue;
      final [l, t, r, b, text, c] = e;
      if (l is! num || t is! num || r is! num || b is! num) continue;
      if (text is! String || c is! num) continue;
      out.add((
        left: l.toDouble(),
        top: t.toDouble(),
        right: r.toDouble(),
        bottom: b.toDouble(),
        text: text,
        confidence: c.toDouble(),
      ));
    }
  } catch (_) {}
  return out;
}

/// Each PDF's scanned pages read so far (a page read with nothing on it
/// is kept too, so it isn't read again).
abstract class ScannedTextStore {
  /// [documentId]'s pages read so far, by the PDF's own page number.
  Future<Map<int, List<ScannedLine>>> load(String documentId);

  /// [documentId]'s pages read so far (without their text).
  Future<Set<int>> pagesRead(String documentId);

  Future<void> savePage(String documentId, int page, List<ScannedLine> lines);

  Future<Set<String>> documents();

  Future<void> forget(String documentId);
}

class MemoryScannedTextStore implements ScannedTextStore {
  final _docs = <String, Map<int, List<ScannedLine>>>{};

  @override
  Future<Map<int, List<ScannedLine>>> load(String documentId) async => {
    ...?_docs[documentId],
  };

  @override
  Future<Set<int>> pagesRead(String documentId) async => {
    ...?_docs[documentId]?.keys,
  };

  @override
  Future<void> savePage(
    String documentId,
    int page,
    List<ScannedLine> lines,
  ) async => (_docs[documentId] ??= {})[page] = [...lines];

  @override
  Future<Set<String>> documents() async => _docs.keys.toSet();

  @override
  Future<void> forget(String documentId) async => _docs.remove(documentId);
}
