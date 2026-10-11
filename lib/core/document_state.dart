/// Per-PDF reading state (where the user was, how many pages), kept in the
/// library so a PDF reopens where it was left. Pure Dart.
library;

class DocumentState {
  const DocumentState({
    required this.id,
    required this.lastPage,
    required this.pageCount,
    required this.updatedAt,
  });

  /// The PDF's library id (the same id as its stored copy).
  final String id;

  /// 1-based page the user was on.
  final int lastPage;
  final int pageCount;
  final DateTime updatedAt;

  /// The page to reopen at: [lastPage], kept inside the document (the file
  /// may have changed since).
  int resumePageFor(int pages) => lastPage.clamp(1, pages < 1 ? 1 : pages);
}

abstract class DocumentStateStore {
  Future<DocumentState?> get(String id);
  Future<Map<String, DocumentState>> all();
  Future<void> save(DocumentState state);
}

/// Parses what the user typed in "Go to page"; null if it isn't a page of
/// a document with [pageCount] pages.
int? parsePageNumber(String text, int pageCount) {
  final n = int.tryParse(text.trim());
  if (n == null || n < 1 || n > pageCount) return null;
  return n;
}
