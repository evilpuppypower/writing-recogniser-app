/// Sorting writing from drawing without sending the whole page every time
/// (owner: "insane lag after writing 50 words"). An engine that sorts a
/// whole page at a time (MyScript's Raw Content) took longer with every
/// stroke, and each pause waited for it before reading the new word. Now
/// only new strokes and the ink around them are sent; the rest keep the
/// answer they had. Works with any classifier. Pure Dart.
library;

import 'ink_classifier.dart';
import 'page_ink.dart';
import 'stroke_grouping.dart';

class NearbyClassifier implements InkClassifier {
  NearbyClassifier(this.inner, {this.reach = 3});

  final InkClassifier inner;

  /// How far round the new strokes is sorted again with them, in letter
  /// heights (a word finished, a stroke that turns a letter into a box).
  final double reach;

  /// Each stroke's last answer (a changed stroke is a new object, so it's
  /// sorted again).
  final _kinds = Expando<InkKind>();

  /// How many strokes the last call sent to [inner] (for the diagnostic
  /// log).
  int lastSent = 0;

  @override
  Future<List<InkKind>> classify(List<PageStroke> strokes) async {
    final fresh = [
      for (final s in strokes)
        if (_kinds[s] == null) s,
    ];
    lastSent = 0;
    if (fresh.isEmpty) return [for (final s in strokes) _kinds[s]!];
    // Mostly new (a page opened for the first time): the whole page.
    if (fresh.length * 2 >= strokes.length) {
      await _sort(strokes);
    } else {
      final boxes = [
        for (final s in strokes)
          if (s.points.isNotEmpty) InkBox.of(s),
      ];
      final margin = typicalLetterHeight(boxes) * reach;
      InkBox? around;
      for (final s in fresh) {
        if (s.points.isEmpty) continue;
        final b = InkBox.of(s);
        around = around == null ? b : around.union(b);
      }
      final area = around == null
          ? null
          : InkBox(
              around.left - margin,
              around.bottom - margin,
              around.right + margin,
              around.top + margin,
            );
      await _sort([
        for (final s in strokes)
          if (_kinds[s] == null ||
              (area != null &&
                  s.points.isNotEmpty &&
                  _overlaps(InkBox.of(s), area)))
            s,
      ]);
    }
    return [for (final s in strokes) _kinds[s] ?? InkKind.writing];
  }

  Future<void> _sort(List<PageStroke> strokes) async {
    lastSent = strokes.length;
    final kinds = await inner.classify(strokes);
    for (var i = 0; i < strokes.length && i < kinds.length; i++) {
      _kinds[strokes[i]] = kinds[i];
    }
  }

  static bool _overlaps(InkBox a, InkBox b) =>
      a.left <= b.right &&
      a.right >= b.left &&
      a.bottom <= b.top &&
      a.top >= b.bottom;
}
