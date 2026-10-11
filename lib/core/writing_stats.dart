/// Plain facts about how a sample was written (size, position, speed,
/// pressure), for the per-sample part of the GATE A report. Pure Dart.
library;

import 'ink.dart';
import 'labeled_sample.dart';

class WritingStats {
  const WritingStats({
    required this.strokes,
    required this.points,
    required this.writingMs,
    required this.meanPressure,
    this.leftPct,
    this.rightPct,
    this.inkHeight,
  });

  final int strokes;
  final int points;

  /// First pen-down to last pen-up.
  final int writingMs;
  final double meanPressure;

  /// Where the ink starts and ends across the writing box, as a share of
  /// its width (0 = left edge, 1 = right edge). Null if the box size wasn't
  /// recorded.
  final double? leftPct;
  final double? rightPct;

  /// Height of the ink in logical pixels.
  final double? inkHeight;

  factory WritingStats.of(LabeledSample s) {
    final pts = [for (final st in s.strokes) ...st.points];
    final bounds = InkBounds.of(s.strokes);
    final w = s.canvasWidth;
    final start = s.strokes.isEmpty ? 0 : s.strokes.first.startTime;
    final end = s.strokes.isEmpty ? 0 : s.strokes.last.endTime;
    return WritingStats(
      strokes: s.strokes.length,
      points: pts.length,
      writingMs: end - start < 0 ? 0 : end - start,
      meanPressure: pts.isEmpty
          ? 0
          : pts.fold<double>(0, (a, p) => a + p.pressure) / pts.length,
      leftPct: bounds == null || w == null || w <= 0 ? null : bounds.left / w,
      rightPct: bounds == null || w == null || w <= 0 ? null : bounds.right / w,
      inkHeight: bounds?.height,
    );
  }

  /// One line for the report.
  String describe() {
    final parts = <String>[
      '$strokes strokes',
      '${(writingMs / 1000).toStringAsFixed(1)} s',
      if (leftPct != null && rightPct != null)
        'ink across ${_pct(leftPct!)}–${_pct(rightPct!)} of the box width',
      if (inkHeight != null) '${inkHeight!.round()} px tall',
      'pressure ${meanPressure.toStringAsFixed(2)}',
    ];
    return parts.join(', ');
  }

  static String _pct(double v) => '${(v * 100).round()}%';
}
