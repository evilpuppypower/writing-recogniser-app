/// Saving and loading the ink written on PDFs (task 1.3). Pure Dart: the
/// SQLite implementation lives in lib/storage, and Windows can reuse this.
library;

import 'dart:async';

import 'page_ink.dart';

/// Where each PDF's ink is kept, per page, in PDF page coordinates. The
/// source PDF is never changed (CLAUDE.md rule 6).
abstract class InkStore {
  /// All saved ink of [documentId] (empty if none).
  Future<DocumentInk> load(String documentId);

  /// Replaces [page]'s saved strokes; an empty list removes the page.
  Future<void> savePage(String documentId, int page, List<PageStroke> strokes);

  /// Forgets all ink of [documentId].
  Future<void> deleteDocument(String documentId);

  /// Ids of documents that have any ink.
  Future<Set<String>> documentsWithInk();
}

/// Saves changed pages shortly after each edit, so one eraser swipe (many
/// small edits) is one save, and [flush] saves anything pending at once
/// (when leaving the PDF or the app). Each save writes the page as it is
/// then, so a later edit is never lost to an earlier, slower save.
class InkAutosaver {
  InkAutosaver({
    required this.store,
    required this.documentId,
    required this.pageStrokes,
    this.delay = const Duration(milliseconds: 400),
    this.onError,
  });

  final InkStore store;
  final String documentId;

  /// Current strokes of a page (read when saving).
  final List<PageStroke> Function(int page) pageStrokes;
  final Duration delay;

  /// Called when a save fails (e.g. storage full).
  final void Function(Object error)? onError;

  final _dirty = <int>{};
  Timer? _timer;
  Future<void> _saving = Future.value();

  bool get hasPending => _dirty.isNotEmpty;

  /// Marks [page] as changed; it is saved after [delay].
  void changed(int page) {
    _dirty.add(page);
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  /// Saves every changed page now. Saves run one after another.
  Future<void> flush() {
    _timer?.cancel();
    if (_dirty.isEmpty) return _saving;
    final pages = _dirty.toList()..sort();
    _dirty.clear();
    final snapshot = {for (final p in pages) p: pageStrokes(p)};
    _saving = _saving.then((_) async {
      for (final e in snapshot.entries) {
        try {
          await store.savePage(documentId, e.key, e.value);
        } catch (err) {
          onError?.call(err);
        }
      }
    });
    return _saving;
  }

  void dispose() => _timer?.cancel();
}
