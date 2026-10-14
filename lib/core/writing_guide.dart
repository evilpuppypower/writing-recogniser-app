/// The faint guide line under the line being written (owner's choice F2,
/// 2026-10-13), so a sentence stays straight and on one line. Pure Dart.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'stroke_grouping.dart';

/// Where the guide goes, in PDF page coordinates: along [baseline] from
/// [left] to [right]. For a line written at a slant, those are measured
/// with the line turned level ([angle] radians about ([cx], [cy]), see
/// [levelPoint]); [ends] gives the guide's two ends on the page.
typedef GuideLine = ({
  double left,
  double right,
  double baseline,
  double letter,
  double angle,
  double cx,
  double cy,
});

/// The guide's start and end on the page (PDF page coordinates).
(PageInkPoint, PageInkPoint) ends(GuideLine g) {
  PageInkPoint onPage(double x) =>
      levelPoint(PageInkPoint(x, g.baseline, 0), -g.angle, g.cx, g.cy);
  return (onPage(g.left), onPage(g.right));
}

/// Whether the pen at ([x], [y]) (PDF page coordinates) is where the line
/// of [guide] would carry on: past its end, about at its height (owner's
/// report: carrying on a sentence after scrolling right).
bool nearLineEnd(GuideLine guide, double x, double y) {
  final p = levelPoint(PageInkPoint(x, y, 0), guide.angle, guide.cx, guide.cy);
  return p.x >= guide.right - guide.letter * 4 &&
      p.x <= guide.right + guide.letter * 12 &&
      p.y >= guide.baseline - guide.letter * 0.5 &&
      p.y <= guide.baseline + guide.letter * 2;
}

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
    // Measured level: a line written at a slant gets a guide at that slant.
    final slant = line.words.first.slant;
    InkBox levelBox(PageStroke s) => slant == null
        ? InkBox.of(s)
        : InkBox.of(
            s.copyWith(
              points: [
                for (final p in s.points)
                  levelPoint(p, slant.angle, slant.cx, slant.cy),
              ],
            ),
          );
    final levelBoxes = [for (final i in ids) levelBox(strokes[i])];
    final bottoms = [
      for (final b in levelBoxes)
        if (math.max(b.width, b.height) > line.letterHeight * 0.4) b.bottom,
    ]..sort();
    final box = levelBoxes.reduce((a, b) => a.union(b));
    final baseline = bottoms.isEmpty
        ? box.bottom
        : bottoms[bottoms.length ~/ 2];
    return (
      left: box.left - line.letterHeight * 0.5,
      right: box.right + line.letterHeight * 4,
      baseline: baseline - line.letterHeight * 0.1,
      letter: line.letterHeight,
      angle: slant?.angle ?? 0.0,
      cx: slant?.cx ?? 0.0,
      cy: slant?.cy ?? 0.0,
    );
  }
  return null;
}
