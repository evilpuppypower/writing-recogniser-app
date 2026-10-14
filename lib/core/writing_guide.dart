/// The faint guide line under the line being written (owner's choice F2,
/// 2026-10-13), so a sentence stays straight and on one line. Pure Dart.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'stroke_grouping.dart';

/// Where the guide goes, in PDF page coordinates: along [baseline] from
/// [left] to [right].
typedef GuideLine = ({
  double left,
  double right,
  double baseline,
  double letter,
});

/// Whether the pen at ([x], [y]) (PDF page coordinates) is where the line
/// of [guide] would carry on: past its end, about at its height (owner's
/// report: carrying on a sentence after scrolling right).
bool nearLineEnd(GuideLine guide, double x, double y) =>
    x >= guide.right - guide.letter * 4 &&
    x <= guide.right + guide.letter * 12 &&
    y >= guide.baseline - guide.letter * 0.5 &&
    y <= guide.baseline + guide.letter * 2;

/// The guide for the line that stroke [strokeId] is on, among the page's
/// [strokes]: under the letters (the middle of their bottoms, so tails of
/// g, y and p don't pull it down), from the line's start to a little past
/// its end, where the next word goes. Null if the stroke isn't writing.
GuideLine? guideFor(List<PageStroke> page, String strokeId) {
  final stroke = page.where((s) => s.id == strokeId).firstOrNull;
  if (stroke == null || stroke.points.isEmpty) return null;
  // Only the writing at about the same height matters (quicker on a full
  // page): within a few of the stroke's own heights above and below.
  final at = InkBox.of(stroke);
  final reach = math.max(at.height, 10) * 3;
  final strokes = [
    for (final s in page)
      if (s.points.isNotEmpty)
        if (InkBox.of(s) case final b
            when b.top >= at.bottom - reach && b.bottom <= at.top + reach)
          s,
  ];
  final lines = groupStrokes(strokes);
  for (final line in lines) {
    final ids = [
      for (final w in line.words)
        for (final i in w.strokes) i,
    ];
    if (!ids.any((i) => strokes[i].id == strokeId)) continue;
    final bottoms = [
      for (final i in ids)
        if (InkBox.of(strokes[i]) case final b
            when math.max(b.width, b.height) > line.letterHeight * 0.4)
          b.bottom,
    ]..sort();
    final box = line.box;
    final baseline = bottoms.isEmpty
        ? box.bottom
        : bottoms[bottoms.length ~/ 2];
    return (
      left: box.left - line.letterHeight * 0.5,
      right: box.right + line.letterHeight * 4,
      baseline: baseline - line.letterHeight * 0.1,
      letter: line.letterHeight,
    );
  }
  return null;
}
