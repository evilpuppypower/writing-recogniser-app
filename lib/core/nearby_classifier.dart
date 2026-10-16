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
  NearbyClassifier(this.inner, {this.reach = 3, this.trusted});

  final InkClassifier inner;

  /// Whether [inner]'s last answer can be kept (an engine that hit an
  /// error and answered with a fallback says no): if not, those strokes
  /// are sorted again next time instead of keeping a stand-in answer.
  final bool Function()? trusted;

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
    return [for (final s in strokes) _kinds[s] ?? _stand[s] ?? InkKind.writing];
  }

  /// This time's answers that aren't kept (see [trusted]).
  Map<PageStroke, InkKind> _stand = const {};

  Future<void> _sort(List<PageStroke> strokes) async {
    lastSent = strokes.length;
    final kinds = await inner.classify(strokes);
    if (!(trusted?.call() ?? true)) {
      _stand = {
        for (var i = 0; i < strokes.length && i < kinds.length; i++)
          strokes[i]: kinds[i],
      };
      return;
    }
    _stand = const {};
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

/// Reading times after pauses, gathered into one diagnostic entry every
/// [every] reads (sizes and times only), so the log doesn't grow by one
/// entry per pause.
class ReadSummary {
  ReadSummary({this.every = 20});

  final int every;
  final _total = <int>[], _sort = <int>[];
  int _strokes = 0, _sorted = 0, _calls = 0, _queued = 0;

  /// Adds one read's timings (see InkTextController.onRead); returns the
  /// summary to log once [every] reads are in, else null.
  Map<String, Object?>? add(Map<String, Object?> t) {
    _total.add((t['totalMs'] as int?) ?? 0);
    _sort.add((t['sortMs'] as int?) ?? 0);
    _strokes = (t['strokes'] as int?) ?? _strokes;
    _sorted = _sorted > ((t['sorted'] as int?) ?? 0)
        ? _sorted
        : (t['sorted'] as int?) ?? 0;
    _calls += (t['engineCalls'] as int?) ?? 0;
    if (t['queued'] == true) _queued++;
    if (_total.length < every) return null;
    int median(List<int> v) => ([...v]..sort())[v.length ~/ 2];
    int worst(List<int> v) => v.reduce((a, b) => a > b ? a : b);
    final out = {
      'reads': _total.length,
      'medianMs': median(_total),
      'worstMs': worst(_total),
      'medianSortMs': median(_sort),
      'worstSortMs': worst(_sort),
      'mostSorted': _sorted,
      'strokesOnPage': _strokes,
      'engineCalls': _calls,
      'queued': _queued,
    };
    _total.clear();
    _sort.clear();
    _sorted = _calls = _queued = 0;
    return out;
  }
}
