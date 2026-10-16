/// Each PDF's printed text, read once and kept, so searching every
/// document (owner, 2026-10-16) doesn't read every PDF again each time.
/// Pure Dart: the SQLite implementation lives in lib/storage.
library;

abstract class PrintedTextStore {
  /// [documentId]'s printed text by its own page numbers (pages without
  /// any left out), or null if it hasn't been read yet.
  Future<Map<int, String>?> load(String documentId);

  /// Keeps [documentId]'s printed text (marks it read, even if empty).
  Future<void> save(String documentId, Map<int, String> pages);

  /// The documents read so far.
  Future<Set<String>> documents();

  /// Forgets [documentId]'s printed text.
  Future<void> forget(String documentId);
}

class MemoryPrintedTextStore implements PrintedTextStore {
  final _docs = <String, Map<int, String>>{};

  @override
  Future<Map<int, String>?> load(String documentId) async =>
      _docs[documentId] == null ? null : {..._docs[documentId]!};

  @override
  Future<void> save(String documentId, Map<int, String> pages) async =>
      _docs[documentId] = {...pages};

  @override
  Future<Set<String>> documents() async => _docs.keys.toSet();

  @override
  Future<void> forget(String documentId) async => _docs.remove(documentId);
}
