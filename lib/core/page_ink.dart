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

enum InkTool {
  pen,
  highlighter,

  /// A typed text box placed anywhere (owner's choice, 2026-10-15): not
  /// ink. Its two points are the box's top-left and bottom-right corners,
  /// [PageStroke.typedText] its text and [PageStroke.width] its text size
  /// (points). Never read as handwriting.
  text,
}

/// A finished stroke on one page.
class PageStroke {
  const PageStroke({
    required this.points,
    this.colorArgb = 0xFF1A1A1A,
    this.width = 1.2,
    this.tool = InkTool.pen,
    this.arrow = false,
    this.notWriting = false,
    this.typedGroup,
    this.typedText,
    this.manualWord,
  });

  final List<PageInkPoint> points;
  final int colorArgb;

  /// Line width in PDF points (1/72 inch), at normal pressure.
  final double width;
  final InkTool tool;

  /// Draw an arrowhead at the end of the stroke.
  final bool arrow;

  /// The user said this ink isn't writing (a drawing, a tick), so it's
  /// never read as text. Saved with the ink, so it lasts (task 2.4c).
  final bool notWriting;

  /// Converted to typed text (task 2.3b): the strokes of one converted word
  /// share a [typedGroup], and the first of them carries the [typedText].
  /// The ink itself is kept (owner, 2026-10-12), so the user can switch
  /// between the handwriting and the typed text.
  final String? typedGroup;
  final String? typedText;

  /// The user said these strokes are one word ("Read as one word" in the
  /// selection bar): strokes sharing it are always read together, as
  /// writing. Also a lesson for a future word-finding model.
  final String? manualWord;

  /// Identifies the stroke on its page: when it started and how many
  /// points it has (stable across saving and reopening).
  String get id => '${points.first.t}/${points.length}';

  PageStroke copyWith({
    bool? notWriting,
    List<PageInkPoint>? points,
    int? colorArgb,
    double? width,
    Object? manualWord = _keep,
  }) => PageStroke(
    points: points ?? this.points,
    colorArgb: colorArgb ?? this.colorArgb,
    width: width ?? this.width,
    tool: tool,
    arrow: arrow,
    notWriting: notWriting ?? this.notWriting,
    typedGroup: typedGroup,
    typedText: typedText,
    manualWord: identical(manualWord, _keep)
        ? this.manualWord
        : manualWord as String?,
  );

  static const _keep = Object();

  /// This stroke as part of converted word [group] (null: not converted),
  /// carrying [text] if it's the word's first stroke.
  PageStroke withTyped(String? group, String? text) => PageStroke(
    points: points,
    colorArgb: colorArgb,
    width: width,
    tool: tool,
    arrow: arrow,
    notWriting: notWriting,
    typedGroup: group,
    typedText: group == null ? null : text,
    manualWord: manualWord,
  );

  Map<String, Object?> toJson() => {
    'color': colorArgb,
    'width': width,
    'tool': tool.name,
    if (arrow) 'arrow': true,
    if (notWriting) 'notWriting': true,
    'typedGroup': ?typedGroup,
    'typedText': ?typedText,
    'manualWord': ?manualWord,
    'points': [for (final p in points) p.toJson()],
  };

  factory PageStroke.fromJson(Map<String, Object?> j) => PageStroke(
    colorArgb: (j['color'] as num?)?.toInt() ?? 0xFF1A1A1A,
    width: (j['width'] as num?)?.toDouble() ?? 1.2,
    tool: InkTool.values.asNameMap()[j['tool']] ?? InkTool.pen,
    arrow: j['arrow'] == true,
    notWriting: j['notWriting'] == true,
    typedGroup: j['typedGroup'] as String?,
    typedText: j['typedText'] as String?,
    manualWord: j['manualWord'] as String?,
    points: [
      for (final p in (j['points'] as List? ?? const []))
        PageInkPoint.fromJson(p as List<dynamic>),
    ],
  );

  /// Distance in points from (x, y) to the nearest part of this stroke.
  /// Whether this is a typed text box (see [InkTool.text]).
  bool get isTextBox => tool == InkTool.text;

  double distanceTo(double x, double y) {
    if (points.isEmpty) return double.infinity;
    if (isTextBox) {
      // Distance to the box (0 inside it).
      final l = math.min(points.first.x, points.last.x);
      final r = math.max(points.first.x, points.last.x);
      final b = math.min(points.first.y, points.last.y);
      final t = math.max(points.first.y, points.last.y);
      final dx = x < l ? l - x : (x > r ? x - r : 0.0);
      final dy = y < b ? b - y : (y > t ? y - t : 0.0);
      return math.sqrt(dx * dx + dy * dy);
    }
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

  /// Marks the strokes with these [PageStroke.id]s on [page] as not
  /// writing. Returns whether anything changed.
  bool markNotWriting(int page, Set<String> ids) =>
      _setNotWriting(page, ids, true);

  /// Undoes [markNotWriting] for these strokes (task 2.4d): they're read
  /// as writing again. Returns whether anything changed.
  bool markWriting(int page, Set<String> ids) =>
      _setNotWriting(page, ids, false);

  bool _setNotWriting(int page, Set<String> ids, bool value) {
    var changed = false;
    _pages[page] = [
      for (final s in strokesOn(page))
        if (s.notWriting != value && s.points.isNotEmpty && ids.contains(s.id))
          () {
            changed = true;
            return s.copyWith(notWriting: value);
          }()
        else
          s,
    ];
    return changed;
  }

  /// Converts words on [page] to typed text (task 2.3b): each entry is a
  /// word's [PageStroke.id]s and its text. Each word's strokes get a group
  /// (named after its stroke ids), and the first carries the text. The ink
  /// stays. Strokes already converted keep their (perhaps edited) text.
  /// Returns whether anything changed.
  bool convert(int page, Map<Set<String>, String> words) {
    final byId = <String, ({String group, String text})>{};
    for (final e in words.entries) {
      final text = e.value.trim();
      if (e.key.isEmpty || text.isEmpty) continue;
      final group = (e.key.toList()..sort()).join(',');
      for (final id in e.key) {
        byId[id] = (group: group, text: text);
      }
    }
    if (byId.isEmpty) return false;
    final seen = <String>{};
    var changed = false;
    final next = <PageStroke>[];
    for (final s in strokesOn(page)) {
      // Already converted (perhaps edited since): kept as it is.
      final w = s.points.isEmpty || s.typedGroup != null ? null : byId[s.id];
      if (w == null) {
        next.add(s);
        continue;
      }
      final first = seen.add(w.group);
      final c = s.withTyped(w.group, first ? w.text : null);
      if (c.typedGroup != s.typedGroup || c.typedText != s.typedText) {
        changed = true;
      }
      next.add(c);
    }
    _pages[page] = next;
    return changed;
  }

  /// Changes the typed text of converted word [group] on [page] (the user
  /// edited it). Groups in [merge] (others shown on the same line) join
  /// [group], so the line is one piece of typed text from then on. Returns
  /// whether anything changed.
  bool setTypedText(
    int page,
    String group,
    String text, {
    Set<String> merge = const {},
  }) {
    final t = text.trim();
    if (t.isEmpty) return false;
    var changed = false;
    var first = true;
    _pages[page] = [
      for (final s in strokesOn(page))
        if (s.typedGroup == group || merge.contains(s.typedGroup))
          () {
            final next = s.withTyped(group, first ? t : null);
            first = false;
            if (next.typedText != s.typedText ||
                next.typedGroup != s.typedGroup) {
              changed = true;
            }
            return next;
          }()
        else
          s,
    ];
    return changed;
  }

  /// Moves and resizes strokes [ids] on [page] (the selection tool): each
  /// point goes to origin + (point - origin) x [scale] + ([dx], [dy]), and
  /// line widths are scaled too. Returns whether anything changed.
  bool moveScale(
    int page,
    Set<String> ids, {
    double dx = 0,
    double dy = 0,
    double scale = 1,
    double originX = 0,
    double originY = 0,
  }) {
    if (ids.isEmpty || (dx == 0 && dy == 0 && scale == 1)) return false;
    var changed = false;
    _pages[page] = [
      for (final s in strokesOn(page))
        if (ids.contains(s.id))
          () {
            changed = true;
            return s.copyWith(
              width: s.width * scale,
              points: [
                for (final p in s.points)
                  PageInkPoint(
                    originX + (p.x - originX) * scale + dx,
                    originY + (p.y - originY) * scale + dy,
                    p.t,
                    p.pressure,
                  ),
              ],
            );
          }()
        else
          s,
    ];
    return changed;
  }

  /// Gives strokes [ids] on [page] the colour [argb].
  bool recolour(int page, Set<String> ids, int argb) {
    var changed = false;
    _pages[page] = [
      for (final s in strokesOn(page))
        if (ids.contains(s.id) && s.colorArgb != argb)
          () {
            changed = true;
            return s.copyWith(colorArgb: argb);
          }()
        else
          s,
    ];
    return changed;
  }

  /// Line widths of strokes [ids] on [page] times [factor], each kept
  /// within [limits] for its tool (Select tool, "Thickness"). Returns
  /// whether anything changed.
  bool scaleWidth(
    int page,
    Set<String> ids,
    double factor,
    (double, double) Function(InkTool tool) limits,
  ) {
    var changed = false;
    _pages[page] = [
      for (final s in strokesOn(page))
        // Not a text box: its "width" is its text size.
        if (ids.contains(s.id) && !s.isTextBox)
          () {
            final (lo, hi) = limits(s.tool);
            final w = (s.width * factor).clamp(lo, hi);
            if (w == s.width) return s;
            changed = true;
            return s.copyWith(width: w);
          }()
        else
          s,
    ];
    return changed;
  }

  /// Strokes on [page] replaced by those in [moved] with the same id (e.g.
  /// straightened by the Select tool). Returns whether anything changed.
  bool replace(int page, List<PageStroke> moved) {
    final byId = {for (final s in moved) s.id: s};
    var changed = false;
    _pages[page] = [
      for (final s in strokesOn(page))
        if (byId[s.id] case final m?)
          () {
            changed = true;
            return m;
          }()
        else
          s,
    ];
    return changed;
  }

  /// Removes strokes [ids] from [page]; returns them.
  List<PageStroke> remove(int page, Set<String> ids) {
    final gone = [
      for (final s in strokesOn(page))
        if (ids.contains(s.id)) s,
    ];
    if (gone.isNotEmpty) {
      _pages[page] = [
        for (final s in strokesOn(page))
          if (!ids.contains(s.id)) s,
      ];
    }
    return gone;
  }

  /// Adds [strokes] to [page] (e.g. pasted), keeping their order.
  void addAll(int page, List<PageStroke> strokes) {
    if (strokes.isEmpty) return;
    _pages[page] = [...strokesOn(page), ...strokes];
  }

  /// The user says strokes [ids] on [page] are one word: they're always
  /// read together, as writing (no longer "not writing").
  bool markOneWord(int page, Set<String> ids) {
    if (ids.isEmpty) return false;
    final word = (ids.toList()..sort()).join(',');
    var changed = false;
    _pages[page] = [
      for (final s in strokesOn(page))
        if (ids.contains(s.id) && (s.manualWord != word || s.notWriting))
          () {
            changed = true;
            return s.copyWith(manualWord: word, notWriting: false);
          }()
        else
          s,
    ];
    return changed;
  }

  /// Replaces all of [page]'s strokes (used by undo and redo).
  void setPage(int page, List<PageStroke> strokes) {
    _pages[page] = strokes;
  }

  /// Removes whole strokes within [radius] points of (x, y) on [page];
  /// returns the removed strokes (empty if none were close enough).
  /// Strokes [protect] says yes to are left alone (e.g. ink hidden behind
  /// typed text, task 2.3c).
  List<PageStroke> eraseAt(
    int page,
    double x,
    double y,
    double radius, {
    bool Function(PageStroke s)? protect,
  }) {
    final strokes = strokesOn(page);
    final removed = [
      for (final s in strokes)
        // A text box's "width" is its text size: only the box counts.
        if (s.distanceTo(x, y) <= radius + (s.isTextBox ? 0 : s.width / 2) &&
            !(protect?.call(s) ?? false))
          s,
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
  bool eraseArea(
    int page,
    double x,
    double y,
    double radius, {
    bool Function(PageStroke s)? protect,
  }) {
    final strokes = strokesOn(page);
    var changed = false;
    final next = <PageStroke>[];
    for (final s in strokes) {
      final reach = radius + (s.isTextBox ? 0 : s.width / 2);
      if (s.distanceTo(x, y) > reach || (protect?.call(s) ?? false)) {
        next.add(s);
        continue;
      }
      changed = true;
      // A text box goes whole (its corners aren't ink to cut).
      if (!s.isTextBox) next.addAll(_cut(s, x, y, reach));
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
            notWriting: s.notWriting,
            typedGroup: s.typedGroup,
            // Only one piece keeps the text, so it isn't shown twice.
            typedText: pieces.isEmpty ? s.typedText : null,
            manualWord: s.manualWord,
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

/// A new text box (see [InkTool.text]) with its top-left corner at ([x], [y])
/// (PDF page coordinates), sized to fit [text] at [size] points.
PageStroke textBox(
  String text,
  double x,
  double y, {
  required double size,
  required int colorArgb,
  required int nowMs,
  (double, double)? measured,
}) {
  final (w, h) = measured ?? textBoxSize(text, size);
  return PageStroke(
    points: [PageInkPoint(x, y, nowMs), PageInkPoint(x + w, y - h, nowMs + 1)],
    tool: InkTool.text,
    width: size,
    colorArgb: colorArgb,
    typedText: text,
  );
}

/// About how much room [text] takes at [size] points: its longest line at
/// 0.55 of the size per character, and 1.25 of the size per line.
(double, double) textBoxSize(String text, double size) {
  final lines = text.split('\n');
  final longest = lines.map((l) => l.length).fold(1, math.max);
  return (longest * size * 0.55, lines.length * size * 1.25);
}
