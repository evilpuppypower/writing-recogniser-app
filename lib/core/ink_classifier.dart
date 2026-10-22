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
    for (final o in index.near(
      b.left - reach,
      b.right + reach,
      b.bottom,
      b.top,
    )) {
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
/// [shape] is the shape check's answer for [strokes] when the caller
/// already has it (it's worked out again otherwise).
List<InkKind> reconcileKinds(
  List<PageStroke> strokes,
  List<InkKind> kinds, {
  List<InkKind>? shape,
}) {
  if (kinds.length != strokes.length) return kinds;
  final out = [...kinds];
  final boxes = [
    for (final s in strokes) s.points.isEmpty ? null : InkBox.of(s),
  ];
  if (shape == null || shape.length != strokes.length) {
    shape = const ShapeInkClassifier().classifySync(strokes);
  }
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
    if (candidate(i) &&
        (strokes[i].manualWord != null || strokes[i].manualLine != null)) {
      out[i] = InkKind.writing;
    }
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
          .near(
            b.left - margin,
            b.right + margin,
            b.bottom - margin,
            b.top + margin,
          )
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

/// The boxes of a page's strokes in a grid of squares, to find those near
/// a spot without checking every stroke on the page (on a page of 1000
/// words, checking a whole column of lines for every stroke was the
/// slowest step).
class _BoxIndex {
  _BoxIndex(List<InkBox?> boxes) {
    final all = boxes.nonNulls.toList();
    final sizes = [for (final b in all) math.max(b.width, b.height)]..sort();
    _cell = sizes.isEmpty ? 1.0 : math.max(1.0, sizes[sizes.length ~/ 2] * 4);
    for (final b in all) {
      // Very big boxes (a long underline, a frame round the page) are kept
      // apart and always checked, not put in hundreds of squares.
      if (math.max(b.width, b.height) > _cell * 8) {
        _big.add(b);
        continue;
      }
      for (var cx = _col(b.left); cx <= _col(b.right); cx++) {
        for (var cy = _col(b.bottom); cy <= _col(b.top); cy++) {
          (_cells[(cx, cy)] ??= []).add(b);
        }
      }
    }
  }

  late final double _cell;
  final _cells = <(int, int), List<InkBox>>{};
  final _big = <InkBox>[];

  int _col(double v) => (v / _cell).floor();

  /// The boxes reaching into [left]..[right] sideways and [bottom]..[top]
  /// up and down (some may be just outside; callers check exactly).
  Iterable<InkBox> near(
    double left,
    double right,
    double bottom,
    double top,
  ) sync* {
    for (final b in _big) {
      if (b.left <= right &&
          b.right >= left &&
          b.bottom <= top &&
          b.top >= bottom) {
        yield b;
      }
    }
    final seen = Set<InkBox>.identity();
    for (var cx = _col(left); cx <= _col(right); cx++) {
      for (var cy = _col(bottom); cy <= _col(top); cy++) {
        for (final b in _cells[(cx, cy)] ?? const <InkBox>[]) {
          if (b.left <= right &&
              b.right >= left &&
              b.bottom <= top &&
              b.top >= bottom &&
              seen.add(b)) {
            yield b;
          }
        }
      }
    }
  }
}

/// A classifier that can answer with a fallback, and says why it did (an
/// error message, for the diagnostic log).
abstract interface class ExplainsFallback {
  String? get problem;
}
