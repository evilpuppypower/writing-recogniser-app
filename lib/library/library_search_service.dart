import 'dart:convert';

import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/feedback/personal_dictionary.dart';
import '../core/ink_store.dart';
import '../core/library_search.dart';
import '../core/page_layout.dart';
import '../core/printed_text_store.dart';
import '../storage/sqlite_ink_store.dart';
import '../storage/sqlite_page_layout_store.dart';
import '../storage/sqlite_printed_text_store.dart';

/// Reads a PDF's printed text, page by page ([onPage] after each, with the
/// page count); stops early (returning null) once [stop] says so.
typedef PrintedTextReader = Future<Map<int, String>?> Function(
  String path,
  void Function(int done, int total) onPage,
  bool Function() stop,
);

/// Gathers what the home screen's search looks through: each document's
/// handwriting and printed text, by where each page is shown.
class LibrarySearchService {
  LibrarySearchService({
    required this.ink,
    required this.layouts,
    required this.printed,
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
      dictionary: dictionary,
    );
  }

  final InkStore ink;
  final PageLayoutStore layouts;
  final PrintedTextStore printed;
  final PersonalDictionary? dictionary;
  final PrintedTextReader readPdf;

  Future<PageLayout?> _layout(String id) async {
    try {
      return PageLayout.fromJson(await layouts.load(id));
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
    final layout = await _layout(id);
    return [
      for (final e in printedByPosition(saved, layout).entries)
        (page: e.key, kind: FoundIn.printed, text: e.value),
    ];
  }

  /// Reads and keeps [id]'s printed text from its file at [path]. False if
  /// stopped first (nothing kept, read again next time).
  Future<bool> readPrinted(
    String id,
    String path,
    void Function(int done, int total) onPage,
    bool Function() stop,
  ) async {
    final pages = await readPdf(path, onPage, stop);
    if (pages == null) return false;
    await printed.save(id, pages);
    return true;
  }

  /// Marks [id] read with no printed text (a notebook's pages are blank).
  Future<void> noPrinted(String id) => printed.save(id, const {});

  /// Forgets the printed text of documents no longer in the library.
  Future<void> keepOnly(Set<String> ids) async {
    for (final id in await printed.documents()) {
      if (!ids.contains(id)) await printed.forget(id);
    }
  }
}

/// [PrintedTextReader] with PDFium (pdfrx).
Future<Map<int, String>?> readPrintedText(
  String path,
  void Function(int done, int total) onPage,
  bool Function() stop,
) async {
  final doc = await PdfDocument.openFile(path);
  try {
    final out = <int, String>{};
    final n = doc.pages.length;
    for (var i = 0; i < n; i++) {
      if (stop()) return null;
      try {
        final text = (await doc.pages[i].loadText())?.fullText ?? '';
        final tidy = text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (tidy.isNotEmpty) out[i + 1] = tidy;
      } catch (_) {
        // A page that can't be read is just not searched.
      }
      onPage(i + 1, n);
    }
    return out;
  } finally {
    await doc.dispose();
  }
}
