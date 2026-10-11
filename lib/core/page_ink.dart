/// Ink written on PDF pages, stored in PDF page coordinates (points, origin
/// bottom-left, unrotated) so it stays locked to the page at any zoom and is
/// independent of the screen (CLAUDE.md rule 6). Pure Dart.
library;

import 'dart:math' as math;

/// One pen sample on a PDF page.
class PageInkPoint {
  const PageInkPoint(this.x, this.y, this.t, [this.pressure = 0.5]);

  /// PDF page coordinates in points.
  final double x;
  final double y;

  /// Milliseconds since the Unix epoch.
  final int t;

  /// 0..1 (0.5 when the pen doesn't report pressure).
  final double pressure;

  List<num> toJson() => [_r(x), _r(y), t, _r(pressure, 1000)];

  factory PageInkPoint.fromJson(List<dynamic> j) => PageInkPoint(
    (j[0] as num).toDouble(),
    (j[1] as num).toDouble(),
    (j[2] as num).toInt(),
    j.length > 3 ? (j[3] as num).toDouble() : 0.5,
  );

  static double _r(double v, [int scale = 100]) =>
      (v * scale).roundToDouble() / scale;
}

enum InkTool { pen, highlighter }

/// A finished stroke on one page.
class PageStroke {
  const PageStroke({
    required this.points,
    this.colorArgb = 0xFF1A1A1A,
    this.width = 1.2,
    this.tool = InkTool.pen,
    this.arrow = false,
  });

  final List<PageInkPoint> points;
  final int colorArgb;

  /// Line width in PDF points (1/72 inch), at normal pressure.
  final double width;
  final InkTool tool;

  /// Draw an arrowhead at the end of the stroke.
  final bool arrow;

  Map<String, Object?> toJson() => {
    'color': colorArgb,
    'width': width,
    'tool': tool.name,
    if (arrow) 'arrow': true,
    'points': [for (final p in points) p.toJson()],
  };

  factory PageStroke.fromJson(Map<String, Object?> j) => PageStroke(
    colorArgb: (j['color'] as num?)?.toInt() ?? 0xFF1A1A1A,
    width: (j['width'] as num?)?.toDouble() ?? 1.2,
    tool: InkTool.values.asNameMap()[j['tool']] ?? InkTool.pen,
    arrow: j['arrow'] == true,
    points: [
      for (final p in (j['points'] as List? ?? const []))
        PageInkPoint.fromJson(p as List<dynamic>),
    ],
  );

  /// Distance in points from (x, y) to the nearest part of this stroke.
  double distanceTo(double x, double y) {
    if (points.isEmpty) return double.infinity;
    var best = _dist(x, y, points.first.x, points.first.y);
    for (var i = 1; i < points.length; i++) {
      best = math.min(best, _segmentDistance(x, y, points[i - 1], points[i]));
    }
    return best;
  }

  static double _dist(double ax, double ay, double bx, double by) =>
      math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

  static double _segmentDistance(
    double x,
    double y,
    PageInkPoint a,
    PageInkPoint b,
  ) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return _dist(x, y, a.x, a.y);
    final t = (((x - a.x) * dx + (y - a.y) * dy) / len2).clamp(0.0, 1.0);
    return _dist(x, y, a.x + t * dx, a.y + t * dy);
  }
}

/// A straight line from [from] to [to] (used when a stroke snaps straight),
/// keeping their times and pressures.
List<PageInkPoint> straightLine(PageInkPoint from, PageInkPoint to) => [
  from,
  to,
];

/// Length of each arrowhead side: about four line widths, at least 6 pt.
double arrowheadSize(double width) => math.max(6.0, width * 4);

/// Removes the little hook a pen often makes as it lifts off (e.g. a
/// right-handed writer flicking right at the end of a leftward arrow), so the
/// arrowhead follows the line, not the flick. Looks at the end of the stroke:
/// the last [withinMs] milliseconds before the pen lifted when given (the
/// flick is quick, so a slow, deliberate bend is kept), otherwise the last
/// [maxTail] of its length. If that end turns more than about 45 degrees away
/// from the [maxTail] of line before it, the stroke is cut at the sharpest
/// turn. [withinMs] of 0 never trims.
List<PageInkPoint> trimLiftHook(
  List<PageInkPoint> points,
  double maxTail, {
  int? withinMs,
}) {
  if (points.length < 3 || maxTail <= 0) return points;
  if (withinMs != null && withinMs <= 0) return points;
  double dist(PageInkPoint a, PageInkPoint b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
  final last = points.last;
  var tail = 0.0;
  var bestK = -1;
  var bestCos = math.cos(math.pi / 4); // turns sharper than 45 degrees only
  for (var k = points.length - 2; k > 0; k--) {
    tail += dist(points[k], points[k + 1]);
    if (withinMs != null ? last.t - points[k].t > withinMs : tail > maxTail) {
      break;
    }
    // Direction of the line before k, over about maxTail of length.
    var j = k, body = 0.0;
    while (j > 0 && body < maxTail) {
      body += dist(points[j - 1], points[j]);
      j--;
    }
    final bx = points[k].x - points[j].x, by = points[k].y - points[j].y;
    final tx = last.x - points[k].x, ty = last.y - points[k].y;
    final bl = math.sqrt(bx * bx + by * by), tl = math.sqrt(tx * tx + ty * ty);
    if (bl < maxTail / 2 || tl == 0) continue;
    final cos = (bx * tx + by * ty) / (bl * tl);
    if (cos < bestCos) {
      bestCos = cos;
      bestK = k;
    }
  }
  return bestK < 0 ? points : points.sublist(0, bestK + 1);
}

/// The arrowhead's two side lines for a stroke ending at the last point of
/// [points], as pairs of (x, y) in the same coordinates; empty if the stroke
/// is too short to have a direction. [size] is the length of each side.
List<(double, double)> arrowheadPoints(List<PageInkPoint> points, double size) {
  if (points.length < 2) return const [];
  final tip = points.last;
  // Direction from a point a little way back, so a wobble at the very end
  // doesn't twist the head.
  var back = points[points.length - 2];
  for (var i = points.length - 2; i >= 0; i--) {
    back = points[i];
    final d = math.sqrt(
      (tip.x - back.x) * (tip.x - back.x) + (tip.y - back.y) * (tip.y - back.y),
    );
    if (d >= size) break;
  }
  final dx = tip.x - back.x, dy = tip.y - back.y;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len == 0) return const [];
  final ux = dx / len, uy = dy / len;
  const spread = 0.5; // about 27 degrees each side
  final c = math.cos(spread), s = math.sin(spread);
  // Rotate the backwards direction by +/- spread.
  final bx = -ux, by = -uy;
  return [
    (tip.x + size * (bx * c - by * s), tip.y + size * (bx * s + by * c)),
    (tip.x + size * (bx * c + by * s), tip.y + size * (-bx * s + by * c)),
  ];
}

/// All ink in one PDF, per page (1-based page numbers). Edits return a new
/// list for the page so painters can compare cheaply.
class DocumentInk {
  final Map<int, List<PageStroke>> _pages = {};

  List<PageStroke> strokesOn(int page) => _pages[page] ?? const [];

  Iterable<int> get pagesWithInk =>
      _pages.entries.where((e) => e.value.isNotEmpty).map((e) => e.key);

  bool get isEmpty => pagesWithInk.isEmpty;

  void add(int page, PageStroke stroke) {
    _pages[page] = [...strokesOn(page), stroke];
  }

  /// Replaces all of [page]'s strokes (used by undo and redo).
  void setPage(int page, List<PageStroke> strokes) {
    _pages[page] = strokes;
  }

  /// Removes whole strokes within [radius] points of (x, y) on [page];
  /// returns the removed strokes (empty if none were close enough).
  List<PageStroke> eraseAt(int page, double x, double y, double radius) {
    final strokes = strokesOn(page);
    final removed = [
      for (final s in strokes)
        if (s.distanceTo(x, y) <= radius + s.width / 2) s,
    ];
    if (removed.isNotEmpty) {
      _pages[page] = [
        for (final s in strokes)
          if (!removed.contains(s)) s,
      ];
    }
    return removed;
  }

  /// Partial erase: removes only the parts of strokes within [radius]
  /// points of (x, y) on [page], splitting strokes where they are cut.
  /// Returns true if anything changed.
  bool eraseArea(int page, double x, double y, double radius) {
    final strokes = strokesOn(page);
    var changed = false;
    final next = <PageStroke>[];
    for (final s in strokes) {
      final reach = radius + s.width / 2;
      if (s.distanceTo(x, y) > reach) {
        next.add(s);
        continue;
      }
      changed = true;
      next.addAll(_cut(s, x, y, reach));
    }
    if (changed) _pages[page] = next;
    return changed;
  }

  /// The pieces of [s] left after removing everything within [reach] of
  /// (x, y). Long segments are subdivided first so a cut through the
  /// middle of a segment is precise.
  static List<PageStroke> _cut(PageStroke s, double x, double y, double reach) {
    bool inside(PageInkPoint p) =>
        (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y) <= reach * reach;
    final step = reach / 2;
    final dense = <PageInkPoint>[];
    for (var i = 0; i < s.points.length; i++) {
      final b = s.points[i];
      if (i > 0) {
        final a = s.points[i - 1];
        final len = math.sqrt(
          (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y),
        );
        final n = (len / step).floor();
        for (var k = 1; k < n; k++) {
          final f = k / n;
          dense.add(
            PageInkPoint(
              a.x + (b.x - a.x) * f,
              a.y + (b.y - a.y) * f,
              a.t + ((b.t - a.t) * f).round(),
              a.pressure + (b.pressure - a.pressure) * f,
            ),
          );
        }
      }
      dense.add(b);
    }
    final pieces = <PageStroke>[];
    var run = <PageInkPoint>[];
    void flush() {
      if (run.length >= 2) {
        pieces.add(
          PageStroke(
            points: run,
            colorArgb: s.colorArgb,
            width: s.width,
            tool: s.tool,
            // The arrowhead stays only if the stroke's end survived.
            arrow: s.arrow && identical(run.last, dense.last),
          ),
        );
      }
      run = [];
    }

    for (final p in dense) {
      if (inside(p)) {
        flush();
      } else {
        run.add(p);
      }
    }
    flush();
    return pieces;
  }

  Map<String, Object?> toJson() => {
    for (final page in pagesWithInk)
      '$page': [for (final s in strokesOn(page)) s.toJson()],
  };

  static DocumentInk fromJson(Map<String, Object?> j) {
    final ink = DocumentInk();
    j.forEach((page, strokes) {
      final n = int.tryParse(page);
      if (n == null) return;
      for (final s in strokes as List) {
        ink.add(n, PageStroke.fromJson((s as Map).cast<String, Object?>()));
      }
    });
    return ink;
  }
}
