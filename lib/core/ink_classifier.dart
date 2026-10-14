/// Tells handwriting apart from drawings (underlines, arrows, boxes,
/// circles, diagrams) so only writing goes to the recognizer (task 2.2b).
/// Pure Dart. Length alone can't decide it: joined-up words are often one
/// long stroke, so the shape is looked at instead.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'stroke_grouping.dart';

enum InkKind { writing, drawing }

/// Sorts strokes into writing and drawings. Engines can do this better
/// (MyScript's "Raw Content" sorting); this is the fallback that always
/// works, and the second opinion when an engine is unsure.
abstract class InkClassifier {
  Future<List<InkKind>> classify(List<PageStroke> strokes);
}

/// Shape rules, measured in the typical letter height h of the writing
/// around each stroke:
///  - much taller than a line of writing (> 3.5 h), or
///  - a nearly straight line longer than 4 h (underline, strike-through,
///    arrow shaft), or
///  - a large closed loop (circle or box round something)
/// is a drawing. Everything else, including long joined-up words (which
/// wiggle up and down within about one line), counts as writing. When
/// unsure it says writing, so nothing written is ever dropped.
class ShapeInkClassifier implements InkClassifier {
  const ShapeInkClassifier();

  @override
  Future<List<InkKind>> classify(List<PageStroke> strokes) async =>
      classifySync(strokes);

  List<InkKind> classifySync(List<PageStroke> strokes) {
    final boxes = [
      for (final s in strokes) s.points.isEmpty ? null : InkBox.of(s),
    ];
    final page = typicalLetterHeight(boxes.nonNulls);
    final index = _BoxIndex(boxes);
    return [
      for (var i = 0; i < strokes.length; i++)
        kindOf(strokes[i], _localLetterHeight(boxes, i, index) ?? page),
    ];
  }

  /// The letter height around stroke [i]: the typical height of the
  /// strokes beside it (sharing some of its height, no further to the side
  /// than its own size; itself included), so big writing is measured
  /// against big writing, while a circle or bracket drawn round small
  /// writing is measured against the small writing. Null when nothing is
  /// beside it (the page's letter height is used then).
  static double? localLetterHeight(List<InkBox?> boxes, int i) =>
      _localLetterHeight(boxes, i, _BoxIndex(boxes));

  static double? _localLetterHeight(
    List<InkBox?> boxes,
    int i,
    _BoxIndex index,
  ) {
    final b = boxes[i];
    if (b == null) return null;
    final reach = math.max(b.width, b.height);
    final near = <InkBox>[];
    // Only strokes near enough sideways are looked at (quick on a full
    // page: not every stroke against every other).
    for (final o in index.within(b.left - reach, b.right + reach)) {
      final dx = b.horizontalGap(o);
      final sharesHeight = o.bottom <= b.top && o.top >= b.bottom;
      if (sharesHeight && dx <= reach) near.add(o);
    }
    if (near.length < 2) return null;
    return typicalLetterHeight(near);
  }

  /// The kind of one stroke, given the letter height [h] (PDF points).
  static InkKind kindOf(PageStroke s, double h) {
    if (s.tool != InkTool.pen || s.arrow) return InkKind.drawing;
    final p = s.points;
    if (p.length < 2) return InkKind.writing; // dots: i, j, full stops
    final box = InkBox.of(s);
    if (box.height > 3.5 * h) return InkKind.drawing;

    var length = 0.0;
    for (var i = 1; i < p.length; i++) {
      length += _dist(p[i - 1], p[i]);
    }
    final chord = _dist(p.first, p.last);
    // Straight: the path is hardly longer than the line between its ends.
    if (length > 4 * h && chord > 0 && length / chord < 1.08) {
      return InkKind.drawing;
    }
    // Closed loop round something: ends meet, and it's big both ways.
    if (chord < 0.15 * length &&
        math.min(box.width, box.height) > 1.8 * h &&
        length > 6 * h) {
      return InkKind.drawing;
    }
    return InkKind.writing;
  }

  static double _dist(PageInkPoint a, PageInkPoint b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

/// A second look at how strokes were sorted (owner's report: the crossbar
/// of a "t" was read on its own as a dash, the rest of the word having been
/// taken for a drawing). A pen stroke sorted as a drawing counts as writing
/// when the user said it is part of a word ([PageStroke.manualWord]), or
/// when the shape check says it looks like writing and it touches writing.
List<InkKind> reconcileKinds(List<PageStroke> strokes, List<InkKind> kinds) {
  if (kinds.length != strokes.length) return kinds;
  final out = [...kinds];
  final boxes = [
    for (final s in strokes) s.points.isEmpty ? null : InkBox.of(s),
  ];
  final shape = const ShapeInkClassifier().classifySync(strokes);
  final index = _BoxIndex(boxes);
  // Boxes have no equality of their own, so this map goes by identity.
  final indexOf = <InkBox, int>{
    for (var i = 0; i < boxes.length; i++)
      if (boxes[i] != null) boxes[i]!: i,
  };
  final page = typicalLetterHeight(boxes.nonNulls);
  bool candidate(int i) =>
      out[i] == InkKind.drawing &&
      strokes[i].tool == InkTool.pen &&
      !strokes[i].arrow &&
      !strokes[i].notWriting &&
      boxes[i] != null;
  for (var i = 0; i < strokes.length; i++) {
    if (candidate(i) && strokes[i].manualWord != null) out[i] = InkKind.writing;
  }
  // A few rounds, so a word whose strokes touch one after another is
  // taken back whole.
  for (var round = 0; round < 3; round++) {
    var changed = false;
    for (var i = 0; i < strokes.length; i++) {
      if (!candidate(i) || shape[i] != InkKind.writing) continue;
      final b = boxes[i]!;
      final margin = page * 0.1;
      final touches = index
          .within(b.left - margin, b.right + margin)
          .any(
            (o) =>
                !identical(o, b) &&
                o.bottom <= b.top + margin &&
                o.top >= b.bottom - margin &&
                out[indexOf[o]!] == InkKind.writing,
          );
      if (touches) {
        out[i] = InkKind.writing;
        changed = true;
      }
    }
    if (!changed) break;
  }
  return out;
}

/// The boxes of a page's strokes sorted by their left edge, to find those
/// overlapping a stretch of the page sideways without checking them all.
class _BoxIndex {
  _BoxIndex(List<InkBox?> boxes)
    : _sorted = boxes.nonNulls.toList()
        ..sort((a, b) => a.left.compareTo(b.left)) {
    for (final b in _sorted) {
      if (b.width > _widest) _widest = b.width;
    }
  }

  final List<InkBox> _sorted;
  double _widest = 0;

  /// The boxes reaching into [from]..[to] sideways (some may be just
  /// outside; callers check exactly).
  Iterable<InkBox> within(double from, double to) sync* {
    // First box whose left edge could still reach [from].
    var lo = 0, hi = _sorted.length;
    final start = from - _widest;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_sorted[mid].left < start) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var k = lo; k < _sorted.length && _sorted[k].left <= to; k++) {
      if (_sorted[k].right >= from) yield _sorted[k];
    }
  }
}
