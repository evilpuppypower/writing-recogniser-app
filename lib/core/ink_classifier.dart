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
    return [
      for (var i = 0; i < strokes.length; i++)
        kindOf(strokes[i], localLetterHeight(boxes, i) ?? page),
    ];
  }

  /// The letter height around stroke [i]: the typical height of the
  /// strokes beside it (sharing some of its height, no further to the side
  /// than its own size; itself included), so big writing is measured
  /// against big writing, while a circle or bracket drawn round small
  /// writing is measured against the small writing. Null when nothing is
  /// beside it (the page's letter height is used then).
  static double? localLetterHeight(List<InkBox?> boxes, int i) {
    final b = boxes[i];
    if (b == null) return null;
    final reach = math.max(b.width, b.height);
    final near = <InkBox>[];
    for (final o in boxes) {
      if (o == null) continue;
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
