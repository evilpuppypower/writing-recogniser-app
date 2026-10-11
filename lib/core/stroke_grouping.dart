/// Groups handwriting on a PDF page into lines and words (task 2.2), so each
/// word can be recognised on its own and the words before it passed as
/// context. Pure Dart (CLAUDE.md rule 3): works on saved strokes in PDF page
/// coordinates and doesn't depend on any engine.
library;

import 'dart:math' as math;

import 'ink.dart';
import 'page_ink.dart';

/// Tuning for [groupStrokes]. Distances are in multiples of the writing's
/// typical letter height, so they work at any handwriting size.
class GroupingParams {
  const GroupingParams({
    this.wordGap = 0.6,
    this.lineOverlap = 0.4,
    this.lineReach = 8,
    this.newSessionMs = 60000,
  });

  /// A horizontal gap wider than this (x letter height) starts a new word.
  final double wordGap;

  /// Two strokes are on the same line when their heights overlap by at
  /// least this share of the shorter one.
  final double lineOverlap;

  /// A stroke further than this (x letter height) to the side of a line is
  /// not part of it (e.g. a note in the other margin at the same height).
  final double lineReach;

  /// Strokes written this long apart only join the same word if they touch
  /// (e.g. coming back later to dot an i still works).
  final int newSessionMs;
}

/// A box in PDF page coordinates (y grows upward).
class InkBox {
  const InkBox(this.left, this.bottom, this.right, this.top);

  final double left, bottom, right, top;

  double get width => right - left;
  double get height => top - bottom;
  double get centerY => (top + bottom) / 2;

  InkBox union(InkBox o) => InkBox(
    math.min(left, o.left),
    math.min(bottom, o.bottom),
    math.max(right, o.right),
    math.max(top, o.top),
  );

  /// Gap between the two boxes side by side (negative when they overlap).
  double horizontalGap(InkBox o) =>
      math.max(left, o.left) - math.min(right, o.right);

  /// How much of the shorter box's height the two share (0..1).
  double verticalOverlap(InkBox o) {
    final shared = math.min(top, o.top) - math.max(bottom, o.bottom);
    final shorter = math.max(math.min(height, o.height), 1e-6);
    return (shared / shorter).clamp(0.0, 1.0);
  }

  static InkBox of(PageStroke s) {
    var l = double.infinity, b = double.infinity;
    var r = -double.infinity, t = -double.infinity;
    for (final p in s.points) {
      l = math.min(l, p.x);
      r = math.max(r, p.x);
      b = math.min(b, p.y);
      t = math.max(t, p.y);
    }
    return InkBox(l, b, r, t);
  }

  @override
  String toString() => 'InkBox($left, $bottom, $right, $top)';
}

/// One handwritten word: indexes into the page's stroke list, in writing
/// order.
class InkWord {
  InkWord(this.strokes, this.box, this.start, this.end);

  final List<int> strokes;
  InkBox box;

  /// First pen-down and last pen-up, ms since epoch.
  int start, end;
}

/// One line of handwriting, words left to right.
class InkLine {
  InkLine(this.words);

  final List<InkWord> words;

  InkBox get box => words.map((w) => w.box).reduce((a, b) => a.union(b));
}

/// Whether [s] is handwriting to recognise: pen strokes, not highlighter,
/// arrows or erased-to-nothing strokes.
bool isWriting(PageStroke s) =>
    s.tool == InkTool.pen && !s.arrow && s.points.isNotEmpty;

/// Groups the handwriting in [strokes] (one page) into lines, top to
/// bottom, each with its words left to right. Other strokes (highlighter,
/// arrows, and any [include] says no to, e.g. drawings) are left out.
List<InkLine> groupStrokes(
  List<PageStroke> strokes, {
  GroupingParams params = const GroupingParams(),
  bool Function(int index)? include,
}) {
  final idx = [
    for (var i = 0; i < strokes.length; i++)
      if (isWriting(strokes[i]) && (include?.call(i) ?? true)) i,
  ];
  if (idx.isEmpty) return const [];
  final boxes = {for (final i in idx) i: InkBox.of(strokes[i])};
  final letter = typicalLetterHeight(boxes.values);

  // Lines: each stroke joins the line it overlaps most in height (and is
  // near enough to sideways), in writing order.
  final lines = <_Line>[];
  for (final i in idx) {
    final b = boxes[i]!;
    _Line? best;
    var bestOverlap = params.lineOverlap;
    // Dots and small marks (the dot of an i, an accent) sit just above or
    // below the letters: they join the line they hover over.
    if (math.max(b.width, b.height) < letter * 0.4) {
      for (final line in lines) {
        final l = line.box;
        if (b.horizontalGap(l) <= 0 &&
            b.centerY > l.bottom - letter * 0.8 &&
            b.centerY < l.top + letter * 0.8) {
          best = line;
          break;
        }
      }
    }
    for (final line in best == null ? lines : const <_Line>[]) {
      if (b.horizontalGap(line.box) > params.lineReach * letter) continue;
      final o = b.verticalOverlap(line.band(letter));
      if (o >= bestOverlap) {
        bestOverlap = o;
        best = line;
      }
    }
    if (best == null) {
      lines.add(_Line(i, b));
    } else {
      best.add(i, b);
    }
  }

  // Words: within a line, left to right, split at wide gaps.
  final result = <InkLine>[];
  for (final line in lines) {
    final order = [...line.strokes]
      ..sort((a, c) => boxes[a]!.left.compareTo(boxes[c]!.left));
    final words = <InkWord>[];
    for (final i in order) {
      final b = boxes[i]!, s = strokes[i];
      final start = s.points.first.t, end = s.points.last.t;
      InkWord? join;
      for (final w in words.reversed) {
        final gap = b.horizontalGap(w.box);
        final apart = math.max(start - w.end, w.start - end);
        final touching = gap <= 0;
        if (touching ||
            (gap < params.wordGap * letter && apart < params.newSessionMs)) {
          join = w;
          break;
        }
      }
      if (join == null) {
        words.add(InkWord([i], b, start, end));
      } else {
        join
          ..strokes.add(i)
          ..box = join.box.union(b)
          ..start = math.min(join.start, start)
          ..end = math.max(join.end, end);
      }
    }
    for (final w in words) {
      w.strokes.sort(
        (a, c) =>
            strokes[a].points.first.t.compareTo(strokes[c].points.first.t),
      );
    }
    words.sort((a, c) => a.box.left.compareTo(c.box.left));
    result.add(InkLine(words));
  }
  // Top of the page first (PDF y grows upward).
  result.sort((a, c) => c.box.centerY.compareTo(a.box.centerY));
  return result;
}

/// The typical height of a letter in this writing: the median height of the
/// strokes, ignoring dots and stray marks. At least 4 pt.
double typicalLetterHeight(Iterable<InkBox> boxes) {
  final h = [
    for (final b in boxes)
      if (math.max(b.width, b.height) > 1.5) b.height,
  ]..sort();
  if (h.isEmpty) return 4;
  return math.max(4.0, h[h.length ~/ 2]);
}

/// The strokes of [word] in the recognisers' format: y grows downward (as
/// on screen) so engines see the writing the right way up, positions start
/// near the origin, and sizes are multiplied by [scale] (engines expect
/// writing about the size it is on screen, not in PDF points).
List<InkStroke> wordInk(
  List<PageStroke> strokes,
  InkWord word, {
  double scale = 1,
}) => [
  for (final i in word.strokes)
    InkStroke([
      for (final p in strokes[i].points)
        InkPoint(
          (p.x - word.box.left) * scale,
          (word.box.top - p.y) * scale,
          p.t,
          p.pressure,
        ),
    ]),
];

class _Line {
  _Line(int i, InkBox b) : strokes = [i], box = b;

  final List<int> strokes;
  InkBox box;

  void add(int i, InkBox b) {
    strokes.add(i);
    box = box.union(b);
  }

  /// The height band this line's letters sit in: its box, but at least one
  /// letter high around its centre (so a first short stroke like "o" still
  /// catches the tall letters that follow).
  InkBox band(double letter) {
    if (box.height >= letter) return box;
    final c = box.centerY;
    return InkBox(box.left, c - letter / 2, box.right, c + letter / 2);
  }
}
