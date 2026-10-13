import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_classifier.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';

PageStroke stroke(List<(double, double)> pts) => PageStroke(
  points: [
    for (var i = 0; i < pts.length; i++)
      PageInkPoint(pts[i].$1, pts[i].$2, i * 10),
  ],
);

/// A letter about 10 pt tall.
PageStroke letter(double x) => stroke([(x, 700), (x + 3, 710), (x + 6, 700)]);

/// A joined-up word: one stroke wiggling up and down, [n] letters long.
PageStroke cursive(double x, int n) => stroke([
  for (var i = 0; i <= n * 4; i++)
    (x + i * 2.0, 700 + (i.isOdd ? 9.0 : 0) + (i % 8 == 3 ? 6 : 0)),
]);

void main() {
  const c = ShapeInkClassifier();

  test('letters and long joined-up words are writing', () {
    final strokes = [
      for (var i = 0; i < 6; i++) letter(100 + i * 8.0),
      cursive(200, 12), // ~100 pt long, one stroke
    ];
    expect(c.classifySync(strokes).toSet(), {InkKind.writing});
  });

  test('an underline and a strike-through are drawings', () {
    final strokes = [
      for (var i = 0; i < 6; i++) letter(100 + i * 8.0),
      stroke([(98, 696), (130, 695.5), (150, 696.5)]), // underline
      stroke([(98, 705), (150, 704)]), // strike-through
    ];
    final kinds = c.classifySync(strokes);
    expect(kinds.sublist(0, 6).toSet(), {InkKind.writing});
    expect(kinds.sublist(6), [InkKind.drawing, InkKind.drawing]);
  });

  test('a circle round a word and a tall bracket are drawings', () {
    final circle = stroke([
      for (var a = 0.0; a <= 2 * math.pi + 0.01; a += 0.2)
        (124 + 35 * math.cos(a), 705 + 18 * math.sin(a)),
    ]);
    final bracket = stroke([(80, 760), (75, 700), (80, 640)]);
    final strokes = [
      for (var i = 0; i < 6; i++) letter(100 + i * 8.0),
      circle,
      bracket,
    ];
    final kinds = c.classifySync(strokes);
    expect(kinds.sublist(6), [InkKind.drawing, InkKind.drawing]);
  });

  test('small loops like o and dots stay writing', () {
    final o = stroke([
      for (var a = 0.0; a <= 2 * math.pi + 0.01; a += 0.4)
        (200 + 3 * math.cos(a), 704 + 4 * math.sin(a)),
    ]);
    final dot = stroke([(210, 712)]);
    final strokes = [for (var i = 0; i < 6; i++) letter(100 + i * 8.0), o, dot];
    expect(c.classifySync(strokes).sublist(6), [
      InkKind.writing,
      InkKind.writing,
    ]);
  });

  test('highlighter and arrows are never writing', () {
    final kinds = c.classifySync([
      letter(100),
      const PageStroke(
        tool: InkTool.highlighter,
        points: [PageInkPoint(90, 702, 0), PageInkPoint(130, 702, 9)],
      ),
      const PageStroke(
        arrow: true,
        points: [PageInkPoint(90, 650, 0), PageInkPoint(95, 652, 9)],
      ),
    ]);
    expect(kinds, [InkKind.writing, InkKind.drawing, InkKind.drawing]);
  });

  test('big writing among small writing is writing', () {
    PageStroke big(double x) =>
        stroke([(x, 400), (x + 15, 450), (x + 30, 400)]);
    final strokes = [
      for (var i = 0; i < 12; i++) letter(100 + i * 8.0),
      for (var i = 0; i < 4; i++) big(100 + i * 35.0),
    ];
    expect(c.classifySync(strokes).toSet(), {InkKind.writing});
  });

  test('a bracket beside small writing is still a drawing', () {
    final strokes = [
      for (var i = 0; i < 6; i++) letter(100 + i * 8.0),
      stroke([(90, 740), (85, 700), (90, 660)]),
    ];
    expect(c.classifySync(strokes).last, InkKind.drawing);
  });

  test('a full page: same answers as checking every pair, and quick', () {
    final r = math.Random(7);
    // 3000 strokes: lines of small letters, a few big words, some lines.
    final strokes = <PageStroke>[
      for (var i = 0; i < 3000; i++)
        if (i % 50 == 0)
          stroke([(r.nextDouble() * 500, r.nextDouble() * 700), (550, 20)])
        else
          () {
            final x = r.nextDouble() * 560, y = r.nextDouble() * 760;
            final h = i % 7 == 0 ? 40.0 : 8 + r.nextDouble() * 4;
            return stroke([(x, y), (x + h / 3, y + h), (x + h / 2, y)]);
          }(),
    ];
    final boxes = [for (final s in strokes) InkBox.of(s)];
    // The old way: every stroke against every other.
    double? slow(int i) {
      final b = boxes[i];
      final reach = math.max(b.width, b.height);
      final near = [
        for (final o in boxes)
          if (o.bottom <= b.top &&
              o.top >= b.bottom &&
              b.horizontalGap(o) <= reach)
            o,
      ];
      return near.length < 2 ? null : typicalLetterHeight(near);
    }

    for (var i = 0; i < strokes.length; i += 37) {
      expect(
        ShapeInkClassifier.localLetterHeight(boxes, i),
        slow(i),
        reason: 'stroke $i',
      );
    }
    final watch = Stopwatch()..start();
    c.classifySync(strokes);
    expect(watch.elapsedMilliseconds, lessThan(3000));
  });
}
