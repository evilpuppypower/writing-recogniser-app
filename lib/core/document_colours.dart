/// Each PDF's own page colours (owner: dark pages are chosen when a PDF
/// comes in, at export and in Settings). Pure Dart.
library;

import 'app_settings.dart' show PageColours;

abstract class DocumentColoursStore {
  /// [documentId]'s own choice; null when it has none (Settings decides).
  Future<PageColours?> get(String documentId);

  /// Sets [documentId]'s own choice; null goes back to Settings' choice.
  Future<void> set(String documentId, PageColours? colours);
}

/// A [DocumentColoursStore] in memory (tests, or when the database can't
/// open).
class MemoryDocumentColoursStore implements DocumentColoursStore {
  final _colours = <String, PageColours>{};

  @override
  Future<PageColours?> get(String documentId) async => _colours[documentId];

  @override
  Future<void> set(String documentId, PageColours? colours) async {
    colours == null
        ? _colours.remove(documentId)
        : _colours[documentId] = colours;
  }
}
