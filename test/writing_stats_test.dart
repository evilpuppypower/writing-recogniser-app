import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/writing_stats.dart';

void main() {
  test('size, position, time and pressure of a sample', () {
    final s = LabeledSample(
      text: 'hi',
      strokes: const [
        InkStroke([InkPoint(100, 50, 1000, 0.2), InkPoint(200, 90, 1500, 0.4)]),
        InkStroke([InkPoint(700, 60, 3000, 0.6)]),
      ],
      createdAt: DateTime(2026),
      canvasWidth: 1000,
      canvasHeight: 400,
    );
    final w = WritingStats.of(s);
    expect(w.strokes, 2);
    expect(w.points, 3);
    expect(w.writingMs, 2000);
    expect(w.meanPressure, closeTo(0.4, 1e-9));
    expect(w.leftPct, closeTo(0.1, 1e-9));
    expect(w.rightPct, closeTo(0.7, 1e-9));
    expect(w.inkHeight, 40);
    expect(
      w.describe(),
      '2 strokes, 2.0 s, ink across 10%–70% of the box width, 40 px tall, '
      'pressure 0.40',
    );
  });

  test('no box size recorded: position left out', () {
    final s = LabeledSample(
      text: 'a',
      strokes: const [
        InkStroke([InkPoint(1, 1, 0)]),
      ],
      createdAt: DateTime(2026),
    );
    expect(WritingStats.of(s).describe(), isNot(contains('box width')));
  });
}
