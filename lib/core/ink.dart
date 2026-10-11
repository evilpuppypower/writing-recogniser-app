/// Handwriting ink: strokes made of points with position, time and pressure.
/// Pure Dart so it can be stored, sent to any recognizer, replayed in tests
/// and reused on Windows (CLAUDE.md rules 3 and 4).
library;

import 'dart:math' as math;

/// One sampled pen position.
class InkPoint {
  const InkPoint(this.x, this.y, this.t, [this.pressure = 0.5]);

  /// Position in logical pixels on the writing surface.
  final double x;
  final double y;

  /// Time in milliseconds since the Unix epoch.
  final int t;

  /// Pen pressure, 0..1 (0.5 when the device doesn't report pressure).
  final double pressure;

  /// Compact form for storage: [x, y, t, pressure].
  List<num> toJson() => [_round(x), _round(y), t, _round(pressure, 1000)];

  factory InkPoint.fromJson(List<dynamic> j) => InkPoint(
    (j[0] as num).toDouble(),
    (j[1] as num).toDouble(),
    (j[2] as num).toInt(),
    j.length > 3 ? (j[3] as num).toDouble() : 0.5,
  );

  static double _round(double v, [int scale = 100]) =>
      (v * scale).roundToDouble() / scale;
}

/// The points from one pen-down to pen-up.
class InkStroke {
  const InkStroke(this.points);

  final List<InkPoint> points;

  int get startTime => points.first.t;
  int get endTime => points.last.t;

  List<List<num>> toJson() => [for (final p in points) p.toJson()];

  factory InkStroke.fromJson(List<dynamic> j) =>
      InkStroke([for (final p in j) InkPoint.fromJson(p as List<dynamic>)]);
}

/// Axis-aligned bounds of some strokes.
class InkBounds {
  const InkBounds(this.left, this.top, this.right, this.bottom);

  final double left, top, right, bottom;
  double get width => right - left;
  double get height => bottom - top;

  static InkBounds? of(Iterable<InkStroke> strokes) {
    var l = double.infinity, t = double.infinity;
    var r = double.negativeInfinity, b = double.negativeInfinity;
    for (final s in strokes) {
      for (final p in s.points) {
        l = math.min(l, p.x);
        t = math.min(t, p.y);
        r = math.max(r, p.x);
        b = math.max(b, p.y);
      }
    }
    return l.isFinite ? InkBounds(l, t, r, b) : null;
  }
}

/// Converts strokes to/from a JSON-friendly list (for storage and replay).
List<List<List<num>>> strokesToJson(List<InkStroke> strokes) => [
  for (final s in strokes) s.toJson(),
];

List<InkStroke> strokesFromJson(List<dynamic> j) => [
  for (final s in j) InkStroke.fromJson(s as List<dynamic>),
];

/// Hover points as [x, y, t] lists (pressure is always 0).
List<List<num>> hoverToJson(List<InkPoint> points) => [
  for (final p in points) p.toJson().take(3).toList(),
];

List<InkPoint> hoverFromJson(List<dynamic> j) => [
  for (final p in j)
    InkPoint(
      ((p as List)[0] as num).toDouble(),
      (p[1] as num).toDouble(),
      (p[2] as num).toInt(),
      0,
    ),
];
