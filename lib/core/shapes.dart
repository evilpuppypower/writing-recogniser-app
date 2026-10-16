/// Tidying a drawn shape (owner's choice: text & shapes, 2026-10-15): a
/// closed stroke held still at its end becomes the circle, ellipse,
/// rectangle or triangle it's closest to, at the tilt it was drawn at. Pure
/// Dart, PDF page points.
library;

import 'dart:math' as math;

import 'page_ink.dart';

enum ShapeKind { circle, ellipse, rectangle, triangle }

/// The tidy version of [points] if it's a closed shape close enough to one
/// of [ShapeKind] (within a twentieth of its size on average, both ways);
/// null otherwise (e.g. an open stroke, which snaps straight instead).
({ShapeKind kind, List<PageInkPoint> points})? tidyShape(
  List<PageInkPoint> points,
) {
  if (points.length < 8) return null;
  // Drawn at a tilt (owner: tilted shapes should be recognised): tidied
  // turned level, then turned back. The tilt is the one whose level box
  // fits the ink most tightly; within [_levelEnough] of level (or of
  // upright) it counts as level, as people mean it to be.
  var cx = 0.0, cy = 0.0;
  for (final p in points) {
    cx += p.x;
    cy += p.y;
  }
  cx /= points.length;
  cy /= points.length;
  _Tidy? best;
  // Two guesses at the tilt: the tightest box (rectangles), and the way
  // the ink stretches most (ellipses, whose tightest box is a poor guide).
  for (final tilt in {_tilt(points), _stretch(points, cx, cy)}) {
    final t = tilt == 0
        ? _tidyLevel(points)
        : _tidyLevel([for (final p in points) _turn(p, -tilt, cx, cy)]);
    if (t == null || (best != null && t.error >= best.error)) continue;
    best = tilt == 0
        ? t
        : (
            kind: t.kind,
            points: [for (final p in t.points) _turn(p, tilt, cx, cy)],
            error: t.error,
          );
  }
  if (best == null) return null;
  return (kind: best.kind, points: best.points);
}

typedef _Tidy = ({ShapeKind kind, List<PageInkPoint> points, double error});

/// The direction [points] stretch along most (radians, -90..90 degrees),
/// 0 when nearly level or upright, or when they hardly stretch (round).
double _stretch(List<PageInkPoint> points, double cx, double cy) {
  var sxx = 0.0, syy = 0.0, sxy = 0.0;
  for (final p in points) {
    sxx += (p.x - cx) * (p.x - cx);
    syy += (p.y - cy) * (p.y - cy);
    sxy += (p.x - cx) * (p.y - cy);
  }
  final half = (sxx - syy) / 2;
  final spread = math.sqrt(half * half + sxy * sxy);
  if (spread < (sxx + syy) / 2 * 0.15) return 0; // round
  var a = 0.5 * math.atan2(2 * sxy, sxx - syy);
  // Within a quarter turn either way: the shapes look the same turned 90.
  if (a > math.pi / 4) a -= math.pi / 2;
  if (a < -math.pi / 4) a += math.pi / 2;
  return a.abs() < _levelEnough ? 0 : a;
}

/// Tilts closer than this to level or upright count as level.
const _levelEnough = 6 * math.pi / 180;

/// The tilt (radians, -45..45 degrees) at which the level box round
/// [points] is smallest: a rectangle's or ellipse's own tilt. 0 when
/// nearly level.
double _tilt(List<PageInkPoint> points) {
  double area(double a) {
    final c = math.cos(a), s = math.sin(a);
    var l = double.infinity, r = -double.infinity;
    var b = double.infinity, t = -double.infinity;
    for (final p in points) {
      final x = p.x * c + p.y * s, y = -p.x * s + p.y * c;
      l = math.min(l, x);
      r = math.max(r, x);
      b = math.min(b, y);
      t = math.max(t, y);
    }
    return (r - l) * (t - b);
  }

  var best = 0.0, bestArea = area(0);
  for (var d = -45.0; d < 45; d += 1) {
    final a = area(d * math.pi / 180);
    if (a < bestArea) {
      bestArea = a;
      best = d * math.pi / 180;
    }
  }
  // A little finer round the best.
  for (var d = -1.0; d <= 1; d += 0.25) {
    final t = best + d * math.pi / 180;
    final a = area(t);
    if (a < bestArea) {
      bestArea = a;
      best = t;
    }
  }
  // A box that's barely smaller isn't a tilt (a circle fits any way).
  if (bestArea > area(0) * 0.97 || best.abs() < _levelEnough) return 0;
  return best;
}

PageInkPoint _turn(PageInkPoint p, double a, double cx, double cy) {
  final c = math.cos(a), s = math.sin(a);
  final dx = p.x - cx, dy = p.y - cy;
  return PageInkPoint(
    cx + dx * c - dy * s,
    cy + dx * s + dy * c,
    p.t,
    p.pressure,
  );
}

_Tidy? _tidyLevel(List<PageInkPoint> points) {
  var l = double.infinity, b = double.infinity;
  var r = -double.infinity, t = -double.infinity;
  for (final p in points) {
    l = math.min(l, p.x);
    r = math.max(r, p.x);
    b = math.min(b, p.y);
    t = math.max(t, p.y);
  }
  final w = r - l, h = t - b, size = math.max(w, h);
  if (size <= 0 || math.min(w, h) < size * 0.15) return null; // a line
  // Closed: it ends near where it started.
  final first = points.first, last = points.last;
  if (_dist(first.x, first.y, last.x, last.y) > size * 0.3) return null;

  final cx = (l + r) / 2, cy = (b + t) / 2, rx = w / 2, ry = h / 2;
  double mean(double Function(PageInkPoint) f) =>
      points.map(f).reduce((a, c) => a + c) / points.length;
  // Each fit: average distance from the ink to the shape, over its size.
  final ellipseError = mean((p) {
    final d = math.sqrt(
      math.pow((p.x - cx) / rx, 2) + math.pow((p.y - cy) / ry, 2),
    );
    return (d - 1).abs();
  });
  final rectError =
      mean(
        (p) => [
          (p.x - l).abs(),
          (p.x - r).abs(),
          (p.y - b).abs(),
          (p.y - t).abs(),
        ].reduce(math.min),
      ) /
      math.min(w, h);
  final tri = _triangle(points);
  final triError = tri == null
      ? double.infinity
      : mean(
              (p) => [
                for (var k = 0; k < 3; k++)
                  _segment(p.x, p.y, tri[k], tri[(k + 1) % 3]),
              ].reduce(math.min),
            ) /
            math.min(w, h);
  // And the other way round: every part of the shape near the ink (so a
  // zigzag inside a triangle isn't taken for one).
  final ink = [
    for (var i = 0; i < points.length; i += math.max(1, points.length ~/ 80))
      (points[i].x, points[i].y),
  ];
  double covered(List<(double, double)> outline) {
    var sum = 0.0;
    for (final (x, y) in outline) {
      sum += ink.map((q) => _dist(x, y, q.$1, q.$2)).reduce(math.min);
    }
    return sum / outline.length / math.min(w, h);
  }

  List<(double, double)> along(List<(double, double)> corners) => [
    for (var k = 0; k < corners.length; k++)
      for (var s = 0; s < 10; s++)
        (
          corners[k].$1 +
              (corners[(k + 1) % corners.length].$1 - corners[k].$1) * s / 10,
          corners[k].$2 +
              (corners[(k + 1) % corners.length].$2 - corners[k].$2) * s / 10,
        ),
  ];
  final best = [
    (
      ShapeKind.ellipse,
      math.max(
        ellipseError,
        covered([
          for (var i = 0; i < 40; i++)
            (
              cx + rx * math.cos(2 * math.pi * i / 40),
              cy + ry * math.sin(2 * math.pi * i / 40),
            ),
        ]),
      ),
    ),
    (
      ShapeKind.rectangle,
      math.max(rectError, covered(along([(l, t), (r, t), (r, b), (l, b)]))),
    ),
    (
      ShapeKind.triangle,
      tri == null ? double.infinity : math.max(triError, covered(along(tri))),
    ),
  ]..sort((a, c) => a.$2.compareTo(c.$2));
  if (best.first.$2 > 0.05) return null;
  final error = best.first.$2;

  final t0 = first.t, t1 = last.t;
  final pressures = [for (final p in points) p.pressure]..sort();
  final pressure = pressures[pressures.length ~/ 2];
  List<PageInkPoint> timed(List<(double, double)> xy) => [
    for (final (i, (x, y)) in xy.indexed)
      PageInkPoint(
        x,
        y,
        t0 + ((t1 - t0) * i / math.max(1, xy.length - 1)).round(),
        pressure,
      ),
  ];

  switch (best.first.$1) {
    case ShapeKind.ellipse:
      // Nearly round: a circle.
      final round = (rx - ry).abs() <= math.max(rx, ry) * 0.15;
      final ax = round ? (rx + ry) / 2 : rx, ay = round ? (rx + ry) / 2 : ry;
      // Starting where the pen started, the way it went round.
      final start = math.atan2((first.y - cy) / ay, (first.x - cx) / ax);
      final way = _turnsAnticlockwise(points, cx, cy) ? 1 : -1;
      return (
        kind: round ? ShapeKind.circle : ShapeKind.ellipse,
        error: error,
        points: timed([
          for (var i = 0; i <= 64; i++)
            (
              cx + ax * math.cos(start + way * 2 * math.pi * i / 64),
              cy + ay * math.sin(start + way * 2 * math.pi * i / 64),
            ),
        ]),
      );
    case ShapeKind.rectangle:
      return (
        kind: ShapeKind.rectangle,
        points: timed([(l, t), (r, t), (r, b), (l, b), (l, t)]),
        error: error,
      );
    case ShapeKind.triangle || ShapeKind.circle:
      return (
        kind: ShapeKind.triangle,
        points: timed([...tri!, tri.first]),
        error: error,
      );
  }
}

/// The three ink points spanning the biggest triangle (its corners).
List<(double, double)>? _triangle(List<PageInkPoint> points) {
  // A sample keeps this quick for long strokes.
  final step = math.max(1, points.length ~/ 60);
  final pts = [
    for (var i = 0; i < points.length; i += step) (points[i].x, points[i].y),
  ];
  var best = 0.0;
  List<(double, double)>? corners;
  for (var i = 0; i < pts.length; i++) {
    for (var j = i + 1; j < pts.length; j++) {
      for (var k = j + 1; k < pts.length; k++) {
        final a = pts[i], b = pts[j], c = pts[k];
        final area =
            ((b.$1 - a.$1) * (c.$2 - a.$2) - (c.$1 - a.$1) * (b.$2 - a.$2))
                .abs();
        if (area > best) {
          best = area;
          corners = [a, b, c];
        }
      }
    }
  }
  return corners;
}

bool _turnsAnticlockwise(List<PageInkPoint> points, double cx, double cy) {
  var sum = 0.0;
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1], b = points[i];
    sum += (a.x - cx) * (b.y - cy) - (b.x - cx) * (a.y - cy);
  }
  return sum > 0;
}

double _dist(double ax, double ay, double bx, double by) =>
    math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

double _segment(double x, double y, (double, double) a, (double, double) b) {
  final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return _dist(x, y, a.$1, a.$2);
  final u = (((x - a.$1) * dx + (y - a.$2) * dy) / len2).clamp(0.0, 1.0);
  return _dist(x, y, a.$1 + u * dx, a.$2 + u * dy);
}
