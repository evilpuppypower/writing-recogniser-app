/// Saved ink, text and bookmarks seen through a [PageLayout] (owner: blank
/// pages like any notes app): the viewer counts pages as they're shown
/// (1 is the first shown), while everything is saved under each page's
/// lasting key, so adding, moving or removing pages never moves saved
/// data. Pages not shown keep what was saved for them. Pure Dart.
library;

import 'bookmarks.dart';
import 'ink_store.dart';
import 'page_ink.dart';
import 'page_layout.dart';

class LaidOutInkStore implements InkStore {
  LaidOutInkStore(this.inner, this.layout);

  final InkStore inner;
  final PageLayout Function() layout;

  @override
  Future<DocumentInk> load(String documentId) async {
    final saved = await inner.load(documentId);
    final l = layout();
    final out = DocumentInk();
    for (var p = 1; p <= l.length; p++) {
      final strokes = saved.strokesOn(l.keyAt(p));
      if (strokes.isNotEmpty) out.setPage(p, [...strokes]);
    }
    return out;
  }

  @override
  Future<void> savePage(
    String documentId,
    int page,
    List<PageStroke> strokes,
  ) async {
    final l = layout();
    if (page < 1 || page > l.length) return;
    await inner.savePage(documentId, l.keyAt(page), strokes);
  }

  @override
  Future<void> deleteDocument(String documentId) =>
      inner.deleteDocument(documentId);

  @override
  Future<Map<int, String>> loadText(String documentId) async {
    final saved = await inner.loadText(documentId);
    final l = layout();
    return {for (var p = 1; p <= l.length; p++) p: ?saved[l.keyAt(p)]};
  }

  @override
  Future<void> saveText(String documentId, int page, String? json) async {
    final l = layout();
    if (page < 1 || page > l.length) return;
    await inner.saveText(documentId, l.keyAt(page), json);
  }

  @override
  Future<Set<String>> documentsWithInk() => inner.documentsWithInk();
}

class LaidOutBookmarkStore implements BookmarkStore {
  LaidOutBookmarkStore(this.inner, this.layout);

  final BookmarkStore inner;
  final PageLayout Function() layout;

  @override
  Future<List<int>> pages(String documentId) async {
    final l = layout();
    return [for (final k in await inner.pages(documentId)) ?l.positionOf(k)]
      ..sort();
  }

  @override
  Future<void> set(String documentId, int page, {required bool on}) async {
    final l = layout();
    if (page < 1 || page > l.length) return;
    await inner.set(documentId, l.keyAt(page), on: on);
  }
}
