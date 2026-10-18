import 'dart:convert';

import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/feedback/personal_dictionary.dart';
import '../core/ink_store.dart';
import '../core/library_search.dart';
import '../core/page_layout.dart';
import '../core/printed_text_store.dart';
import '../core/scanned_text.dart';
import '../storage/sqlite_ink_store.dart';
import '../storage/sqlite_page_layout_store.dart';
import '../storage/sqlite_printed_text_store.dart';
import '../storage/sqlite_scanned_text_store.dart';

/// Reads a PDF's printed text, page by page ([onPage] after each, with the
/// page count), waiting on [pause] before each page; stops early
/// (returning null) once [stop] says so.
typedef PrintedTextReader = Future<PrintedPages?> Function(
  String path,
  void Function(int done, int total) onPage,
  bool Function() stop,
  Future<void> Function() pause,
);

/// Gathers what the home screen's search looks through: each document's
/// handwriting and printed text, by where each page is shown.
class LibrarySearchService {
  LibrarySearchService({
    required this.ink,
    required this.layouts,
    required this.printed,
    this.scanned,
    this.dictionary,
    this.readPdf = readPrintedText,
  });

  /// The app's own stores.
  static Future<LibrarySearchService> open() async {
    final dictionary = PersonalDictionary();
    try {
      final raw = await SharedPreferencesAsync().getString(
        PersonalDictionary.prefsKey,
      );
      if (raw != null) dictionary.load(jsonDecode(raw));
    } catch (_) {}
    return LibrarySearchService(
      ink: await SqliteInkStore.open(),
      layouts: await SqlitePageLayoutStore.open(),
      printed: await SqlitePrintedTextStore.open(),
      scanned: await SqliteScannedTextStore.open(),
      dictionary: dictionary,
    );
  }

  final InkStore ink;
  final PageLayoutStore layouts;
  final PrintedTextStore printed;

  /// Text read from scanned pages (owner, 2026-10-17), searched like
  /// printed text where a page has none of its own.
  final ScannedTextStore? scanned;
  final PersonalDictionary? dictionary;
  final PrintedTextReader readPdf;

  /// [id]'s own pages, checked against the PDF's page count when it's
  /// known, as the viewer does (saved pages that don't fit the file are
  /// ignored and the PDF is shown as it is).
  Future<PageLayout?> _layout(String id, {PrintedPages? saved}) async {
    try {
      final count = (saved ?? await printed.load(id))?.pageCount ?? 0;
      return PageLayout.fromJson(
        await layouts.load(id),
        count == 0 ? null : count,
      );
    } catch (_) {
      return null;
    }
  }

  /// [id]'s handwriting, page by page.
  Future<List<PageText>> handwriting(String id) async {
    final layout = await _layout(id);
    final text = await ink.loadText(id);
    final strokes = await ink.load(id);
    final keys = {...text.keys, ...strokes.pagesWithInk};
    final byKey = <int, String>{
      for (final k in keys)
        k: pageHandwriting(
          wordsJson: text[k],
          strokes: strokes.strokesOn(k),
          expand: dictionary?.expand,
        ),
    };
    return [
      for (final e in byPosition(byKey, layout).entries)
        if (e.value.isNotEmpty)
          (page: e.key, kind: FoundIn.handwriting, text: e.value),
    ];
  }

  /// [id]'s printed text, page by page, or null if it hasn't been read.
  Future<List<PageText>?> savedPrinted(String id) async {
    final saved = await printed.load(id);
    if (saved == null) return null;
    final layout = await _layout(id, saved: saved);
    final pages = {...saved.pages};
    final read =
        await scanned?.load(id).catchError((_) => <int, List<ScannedLine>>{}) ??
        const <int, List<ScannedLine>>{};
    for (final e in read.entries) {
      final text = tidySearch(scannedPageText(e.value));
      if (text.isEmpty) continue;
      final own = pages[e.key] ?? '';
      // A scan's page number or stamp doesn't hide what was read on it; a
      // page with real printed text keeps only its own.
      if (textChars(own) < scannedPageTextChars) {
        pages[e.key] = own.isEmpty ? text : '$own\n$text';
      }
    }
    return [
      for (final e in printedByPosition(pages, layout).entries)
        (page: e.key, kind: FoundIn.printed, text: e.value),
    ];
  }

  /// Reads and keeps [id]'s printed text from its file at [path]. False if
  /// stopped first (nothing kept, read again next time).
  Future<bool> readPrinted(
    String id,
    String path,
    void Function(int done, int total) onPage,
    bool Function() stop, {
    Future<void> Function()? pause,
  }) async {
    final pages = await readPdf(path, onPage, stop, pause ?? () async {});
    if (pages == null) return false;
    await printed.save(id, pages);
    return true;
  }

  /// Marks [id] read with no printed text (a notebook's pages are blank).
  Future<void> noPrinted(String id) =>
      printed.save(id, (pages: const {}, pageCount: 0));

  /// Forgets the printed text of documents no longer in the library.
  Future<void> keepOnly(Set<String> ids) async {
    for (final id in await printed.documents()) {
      if (!ids.contains(id)) await printed.forget(id);
    }
    final s = scanned;
    if (s != null) {
      for (final id in await s.documents()) {
        if (!ids.contains(id)) await s.forget(id);
      }
    }
  }
}

/// [PrintedTextReader] with PDFium (pdfrx), which reads PDFs in its own
/// background worker. A PDF that can't be opened (damaged, or locked with
/// a password) counts as having no printed text, so it isn't tried again
/// every time.
Future<PrintedPages?> readPrintedText(
  String path,
  void Function(int done, int total) onPage,
  bool Function() stop,
  Future<void> Function() pause,
) async {
  final PdfDocument doc;
  try {
    doc = await PdfDocument.openFile(path);
  } catch (_) {
    return (pages: const <int, String>{}, pageCount: 0);
  }
  try {
    final out = <int, String>{};
    final n = doc.pages.length;
    for (var i = 0; i < n; i++) {
      await pause();
      if (stop()) return null;
      try {
        final text = (await doc.pages[i].loadText())?.fullText ?? '';
        final tidy = tidySearch(text);
        if (tidy.isNotEmpty) out[i + 1] = tidy;
      } catch (_) {
        // A page that can't be read is just not searched.
      }
      onPage(i + 1, n);
    }
    return (pages: out, pageCount: n);
  } finally {
    await doc.dispose();
  }
}
