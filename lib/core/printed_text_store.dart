/// Each PDF's printed text, read once and kept, so searching every
/// document (owner, 2026-10-16) doesn't read every PDF again each time.
/// Pure Dart: the SQLite implementation lives in lib/storage.
library;

/// A PDF's printed text by its own page numbers (pages without any left
/// out), and how many pages it has (0 if it couldn't be opened), so saved
/// page changes are checked against the file as the viewer does.
typedef PrintedPages = ({Map<int, String> pages, int pageCount});

abstract class PrintedTextStore {
  /// [documentId]'s printed text, or null if it hasn't been read yet.
  Future<PrintedPages?> load(String documentId);

  /// Keeps [documentId]'s printed text (marks it read, even if empty).
  Future<void> save(String documentId, PrintedPages printed);

  /// The documents read so far.
  Future<Set<String>> documents();

  /// Forgets [documentId]'s printed text.
  Future<void> forget(String documentId);
}

class MemoryPrintedTextStore implements PrintedTextStore {
  final _docs = <String, PrintedPages>{};

  @override
  Future<PrintedPages?> load(String documentId) async => _docs[documentId];

  @override
  Future<void> save(String documentId, PrintedPages printed) async =>
      _docs[documentId] = (
        pages: {...printed.pages},
        pageCount: printed.pageCount,
      );

  @override
  Future<Set<String>> documents() async => _docs.keys.toSet();

  @override
  Future<void> forget(String documentId) async => _docs.remove(documentId);
}
