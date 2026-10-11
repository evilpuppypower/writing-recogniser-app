/// Where labeled handwriting samples are kept. Pure Dart interface; the
/// SQLite implementation is in `lib/storage/`.
library;

import 'labeled_sample.dart';

abstract class SampleStore {
  /// Saves [sample] and returns its new id.
  Future<int> add(LabeledSample sample);

  /// All samples, oldest first.
  Future<List<LabeledSample>> all();

  Future<int> count();

  Future<void> delete(int id);
}
