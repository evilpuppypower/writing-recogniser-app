/// Learning what this user draws and what they write (owner's approved
/// idea 7). Each "This isn't writing" (or "This is writing") keeps a few
/// numbers about the shape of the strokes marked: size against the
/// writing round it, length, how straight. A new stroke whose shape
/// closely matches several marked the same way is sorted that way too.
/// Only the numbers are kept, never the ink. Pure Dart.
library;

import 'dart:math' as math;

import 'ink_classifier.dart';
import 'page_ink.dart';
import 'stroke_grouping.dart';

typedef _Example = ({List<double> f, InkKind kind, int mark});

class PersonalInkKinds {
  PersonalInkKinds({this.near = 0.5, this.agree = 3});

  /// How close (in the numbers' own units) a marked stroke must be to
  /// count.
  final double near;

  /// How many separate marks (the newest) must agree before a stroke is
  /// sorted their way: one mark of a few strokes is never enough alone.
  final int agree;

  /// Most examples kept (the oldest make room), and most kept from one
  /// mark (a big selection can't push out everything learned before).
  static const kept = 400, perMark = 5;

  /// Letter height is only measured on pages with this much writing:
  /// on a page that's mostly a sketch, a circle would look letter-sized.
  static const minWriting = 10;

  final _examples = <_Example>[];
  int _marks = 0;

  int get count => _examples.length;

  /// The shape numbers of [s], measured against letters [h] tall: height,
  /// width and length (as powers of two of a letter), how straight it is
  /// (1: a straight line; near 0: it comes back to where it started), and
  /// its height in points (so a big circle and a letter "o" differ).
  static List<double>? features(PageStroke s, double h) {
    final p = s.points;
    if (p.length < 2 || h <= 0) return null;
    final b = InkBox.of(s);
    var length = 0.0;
    for (var i = 1; i < p.length; i++) {
      length += math.sqrt(
        math.pow(p[i].x - p[i - 1].x, 2) + math.pow(p[i].y - p[i - 1].y, 2),
      );
    }
    if (length <= 0) return null;
    final chord = math.sqrt(
      math.pow(p.last.x - p.first.x, 2) + math.pow(p.last.y - p.first.y, 2),
    );
    double log2(double v) => math.log(math.max(v, 0.05)) / math.ln2;
    return [
      log2(b.height / h),
      log2(b.width / h),
      log2(length / h),
      2 * chord / length, // weighted: straightness tells a lot
      0.5 * log2(math.max(b.height, b.width) / 6), // size in points
    ];
  }

  /// Strokes that can teach or be sorted: plain pen strokes (arrows are
  /// always drawings, so they'd teach that straight lines are).
  static bool _counts(PageStroke s) =>
      s.tool == InkTool.pen && !s.arrow && s.points.isNotEmpty;

  /// The letter height of the writing in [strokes] (null when there's too
  /// little writing to tell).
  static double? _letterOf(Iterable<PageStroke> strokes) {
    final boxes = [for (final s in strokes) InkBox.of(s)];
    if (boxes.length < minWriting) return null;
    return typicalLetterHeight(boxes);
  }

  /// The user marked the strokes [ids] on a page of [page] strokes as
  /// [kind].
  void learn(List<PageStroke> page, Set<String> ids, InkKind kind) {
    // Measured against the writing round them, never against what was
    // marked.
    final h = _letterOf([
      for (final s in page)
        if (_counts(s) && !s.notWriting && !ids.contains(s.id)) s,
    ]);
    if (h == null) return;
    final mark = ++_marks;
    var added = 0;
    for (final s in page) {
      if (added >= perMark) break;
      if (!ids.contains(s.id) || !_counts(s)) continue;
      final f = features(s, h);
      if (f == null) continue;
      _examples.add((f: f, kind: kind, mark: mark));
      added++;
    }
    if (_examples.length > kept) {
      _examples.removeRange(0, _examples.length - kept);
    }
  }

  /// [kinds] (one per stroke of [page]) with strokes that closely match
  /// the user's own marks sorted their way. Strokes the user marked
  /// themselves are left as they are.
  List<InkKind> apply(List<PageStroke> page, List<InkKind> kinds) {
    if (_examples.length < agree || kinds.length != page.length) return kinds;
    final h = _letterOf([
      for (var i = 0; i < page.length; i++)
        if (kinds[i] == InkKind.writing &&
            _counts(page[i]) &&
            !page[i].notWriting)
          page[i],
    ]);
    if (h == null) return kinds;
    final out = [...kinds];
    for (var i = 0; i < page.length; i++) {
      final s = page[i];
      if (!_counts(s) || s.notWriting || s.manualWord != null) continue;
      final f = features(s, h);
      if (f == null) continue;
      // The newest close examples, from [agree] separate marks, decide
      // (the user may have changed their mind): sorted their way if they
      // all agree.
      final verdicts = <InkKind>{};
      final marks = <int>{};
      for (var k = _examples.length - 1; k >= 0 && marks.length < agree; k--) {
        final e = _examples[k];
        if (marks.contains(e.mark)) continue;
        var d = 0.0;
        for (var j = 0; j < f.length; j++) {
          d += (f[j] - e.f[j]) * (f[j] - e.f[j]);
        }
        if (math.sqrt(d) > near) continue;
        marks.add(e.mark);
        verdicts.add(e.kind);
      }
      if (marks.length < agree) continue;
      if (verdicts.length == 1) out[i] = verdicts.single;
    }
    return out;
  }

  List<Object?> toJson() => [
    for (final e in _examples)
      [e.kind.name, e.mark, for (final v in e.f) (v * 1000).round() / 1000],
  ];

  void load(Object? j) {
    if (j is! List) return;
    for (final e in j) {
      if (e is! List || e.length != 7) continue; // older layouts: dropped
      final kind = InkKind.values.asNameMap()[e[0]];
      final mark = e[1];
      final f = [
        for (final v in e.skip(2))
          if (v is num) v.toDouble(),
      ];
      if (kind == null || mark is! int || f.length != 5) continue;
      _examples.add((f: f, kind: kind, mark: mark));
      if (mark > _marks) _marks = mark;
    }
    if (_examples.length > kept) {
      _examples.removeRange(0, _examples.length - kept);
    }
  }
}
