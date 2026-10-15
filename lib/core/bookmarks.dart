/// Pages the user bookmarked in a PDF (owner's choice, 2026-10-15). Pure
/// Dart.
library;

abstract class BookmarkStore {
  /// The bookmarked pages of [documentId], first page first.
  Future<List<int>> pages(String documentId);

  /// Bookmarks [page] (or removes its bookmark when [on] is false).
  Future<void> set(String documentId, int page, {required bool on});
}

/// A [BookmarkStore] in memory (tests, or when the database can't open).
class MemoryBookmarkStore implements BookmarkStore {
  final _pages = <String, Set<int>>{};

  @override
  Future<List<int>> pages(String documentId) async =>
      (_pages[documentId]?.toList() ?? <int>[])..sort();

  @override
  Future<void> set(String documentId, int page, {required bool on}) async {
    final pages = _pages.putIfAbsent(documentId, () => {});
    on ? pages.add(page) : pages.remove(page);
  }
}
