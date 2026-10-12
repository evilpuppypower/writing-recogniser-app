/// Where corrections are kept (task 2.5). Pure Dart interface; the SQLite
/// version is in lib/storage.
library;

import 'correction.dart';

abstract class CorrectionStore {
  /// Saves one correction (each one keeps its own strokes).
  Future<void> add(CorrectionRecord correction);

  /// Every correction, oldest first, each with [CorrectionRecord.count] set
  /// to how many times that same correction (same word, same fix) has been
  /// made up to and including it.
  Future<List<CorrectionRecord>> all();
}
