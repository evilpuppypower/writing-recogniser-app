/// A handwriting sample with the text the writer intended, used to measure
/// and later improve recognition. Pure Dart.
library;

import 'ink.dart';

class LabeledSample {
  const LabeledSample({
    this.id,
    required this.text,
    required this.strokes,
    required this.createdAt,
    this.canvasWidth,
    this.canvasHeight,
    this.hover = const [],
  });

  /// Database id, null until saved.
  final int? id;

  /// What the writer was asked to write.
  final String text;
  final List<InkStroke> strokes;
  final DateTime createdAt;

  /// Size of the writing area when it was recorded.
  final double? canvasWidth;
  final double? canvasHeight;

  /// Where the pen hovered over the box without touching (x, y, time;
  /// pressure 0), from before the first stroke until saving. Engines don't
  /// use it; it's kept for later tuning to the writer (owner, 2026-10-11).
  final List<InkPoint> hover;

  int get pointCount => strokes.fold(0, (n, s) => n + s.points.length);
}
