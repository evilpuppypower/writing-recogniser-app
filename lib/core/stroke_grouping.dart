/// Groups handwriting on a PDF page into lines and words (task 2.2), so each
/// word can be recognised on its own and the words before it passed as
/// context. Pure Dart (CLAUDE.md rule 3): works on saved strokes in PDF page
/// coordinates and doesn't depend on any engine.
library;

import 'dart:math' as math;

import 'ink.dart';
import 'page_ink.dart';

/// Tuning for [groupStrokes]. Distances are in multiples of the writing's
/// typical letter height (each line's own, so big and small writing on the
/// same page both work).
class GroupingParams {
  const GroupingParams({
    this.wordGap = 0.6,
    this.lineOverlap = 0.4,
    this.lineReach = 8,
    this.newSessionMs = 60000,
    this.lineDrift = 0.75,
  });

  /// Writing that carries on to the right of a line's end joins it when its
  /// middle is within this (x letter height) of the line's middle.
  final double lineDrift;

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

/// Writing at a slant (owner's report: words written at an angle confused
/// the engine): its line runs at [angle] (radians, anticlockwise from
/// left-to-right, PDF y up) through ([cx], [cy]). [box] is the word's box
/// with its strokes turned level about that point (see [levelPoint]).
typedef Slant = ({double angle, double cx, double cy, InkBox box});

/// One handwritten word: indexes into the page's stroke list, in writing
/// order.
class InkWord {
  InkWord(this.strokes, this.box, this.start, this.end, {this.slant});

  final List<int> strokes;

  /// The word's box on the page.
  InkBox box;

  /// Set when the word's line is written at a slant.
  Slant? slant;

  /// First pen-down and last pen-up, ms since epoch.
  int start, end;
}

/// One line of handwriting, words left to right (along the line, when it's
/// written at a slant).
class InkLine {
  InkLine(this.words, {this.letterHeight = 4, this.angle = 0});

  final List<InkWord> words;

  /// The line's slant in radians (0: level; see [Slant]).
  final double angle;

  /// Typical letter height of this line's writing, in PDF points.
  final double letterHeight;

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
  final slanted = _slantedRuns(strokes, idx, boxes, letter, params);
  final inRun = {for (final r in slanted) ...r.strokes};
  final result = _group(
    strokes,
    [
      for (final i in idx)
        if (!inRun.contains(i)) i,
    ],
    boxes,
    letter,
    params,
  );
  // Writing at a slant: grouped turned level, so its words and lines are
  // found the usual way, and the engine is sent it level.
  for (final run in slanted) {
    final level = [...strokes];
    for (final i in run.strokes) {
      level[i] = strokes[i].copyWith(
        points: [
          for (final p in strokes[i].points)
            levelPoint(p, run.angle, run.cx, run.cy),
        ],
      );
    }
    final levelBoxes = {for (final i in run.strokes) i: InkBox.of(level[i])};
    for (final line in _group(
      level,
      run.strokes,
      levelBoxes,
      typicalLetterHeight(levelBoxes.values),
      params,
    )) {
      for (final w in line.words) {
        w.slant = (angle: run.angle, cx: run.cx, cy: run.cy, box: w.box);
        w.box = _boxOf(w.strokes, boxes);
      }
      result.add(
        InkLine(line.words, letterHeight: line.letterHeight, angle: run.angle),
      );
    }
  }
  // Top of the page first (PDF y grows upward).
  result.sort((a, c) => c.box.centerY.compareTo(a.box.centerY));
  return result;
}

/// [p] turned by -[angle] about ([cx], [cy]): writing at that slant comes
/// out level.
PageInkPoint levelPoint(PageInkPoint p, double angle, double cx, double cy) {
  final c = math.cos(angle), s = math.sin(angle);
  final dx = p.x - cx, dy = p.y - cy;
  return PageInkPoint(
    cx + dx * c + dy * s,
    cy - dx * s + dy * c,
    p.t,
    p.pressure,
  );
}

/// The smallest slant that counts (owner: "> 10 deg"); below it writing is
/// taken as level, as before.
const minSlant = 10 * math.pi / 180;
const _maxSlant = 60 * math.pi / 180;

typedef _Run = ({List<int> strokes, double angle, double cx, double cy});

/// A straight line through the middles of strokes [idx]: its direction
/// (radians), a point on it, how far the middles stray from it (rms,
/// points), and where along it they start and end (from that point).
typedef _Fit = ({
  double angle,
  double cx,
  double cy,
  double spread,
  double start,
  double end,
});

_Fit _fit(List<int> idx, Map<int, InkBox> boxes) {
  double cxOf(int i) => (boxes[i]!.left + boxes[i]!.right) / 2;
  double cyOf(int i) => boxes[i]!.centerY;
  final mx = idx.map(cxOf).reduce((a, b) => a + b) / idx.length;
  final my = idx.map(cyOf).reduce((a, b) => a + b) / idx.length;
  var sxx = 0.0, syy = 0.0, sxy = 0.0;
  for (final i in idx) {
    final dx = cxOf(i) - mx, dy = cyOf(i) - my;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  // The direction the middles spread along most.
  final angle = 0.5 * math.atan2(2 * sxy, sxx - syy);
  final c = math.cos(angle), s = math.sin(angle);
  var lo = double.infinity, hi = -double.infinity, sq = 0.0;
  for (final i in idx) {
    final dx = cxOf(i) - mx, dy = cyOf(i) - my;
    final along = dx * c + dy * s, across = -dx * s + dy * c;
    lo = math.min(lo, along);
    hi = math.max(hi, along);
    sq += across * across;
  }
  return (
    angle: angle,
    cx: mx,
    cy: my,
    spread: math.sqrt(sq / idx.length),
    start: lo,
    end: hi,
  );
}

/// The difference between two line directions (radians, 0..pi/2).
double _turn(double a, double b) {
  final d = (a - b).abs() % math.pi;
  return math.min(d, math.pi - d);
}

/// [chain] (letters, in writing order) split where the writing changes
/// direction, e.g. a level word followed straight away by a note at a
/// slant: each piece gets its own line.
List<List<int>> _straightPieces(List<int> chain, Map<int, InkBox> boxes) {
  if (chain.length < 8) return [chain];
  final whole = _fit(chain, boxes);
  var best = -1;
  var bestSq = double.infinity;
  for (var k = 4; k <= chain.length - 4; k++) {
    final a = _fit(chain.sublist(0, k), boxes);
    final b = _fit(chain.sublist(k), boxes);
    final sq =
        a.spread * a.spread * k + b.spread * b.spread * (chain.length - k);
    if (sq < bestSq && _turn(a.angle, b.angle) > 8 * math.pi / 180) {
      bestSq = sq;
      best = k;
    }
  }
  if (best < 0 || math.sqrt(bestSq / chain.length) > whole.spread * 0.6) {
    return [chain];
  }
  return [
    ..._straightPieces(chain.sublist(0, best), boxes),
    ..._straightPieces(chain.sublist(best), boxes),
  ];
}

/// Runs of writing at a slant: letters written one after another, each
/// near one just before it, whose middles lie along a straight line
/// between [minSlant] and 60 degrees from level, at least 4 letters long.
/// Dots, crossbars and strokes added later join the run whose line they
/// sit on.
List<_Run> _slantedRuns(
  List<PageStroke> strokes,
  List<int> idx,
  Map<int, InkBox> boxes,
  double letter,
  GroupingParams params,
) {
  bool small(int i) =>
      math.max(boxes[i]!.width, boxes[i]!.height) < letter * 0.4;
  final order =
      [
        for (final i in idx)
          if (!small(i)) i,
      ]..sort(
        (a, c) =>
            strokes[a].points.first.t.compareTo(strokes[c].points.first.t),
      );
  final chains = <List<int>>[];
  for (final i in order) {
    final b = boxes[i]!;
    final chain = chains.lastOrNull;
    if (chain != null &&
        strokes[i].points.first.t - strokes[chain.last].points.last.t <
            params.newSessionMs ~/ 6) {
      // Near the letter before (or the one before that, so a crossbar in
      // between doesn't break the chain); not any letter on the line
      // above, so the next line isn't chained on.
      final near = chain.reversed.take(2).any((j) {
        final l = boxes[j]!;
        final dx = math.max(0.0, b.horizontalGap(l));
        final dy = math.max(
          0.0,
          math.max(b.bottom, l.bottom) - math.min(b.top, l.top),
        );
        return math.sqrt(dx * dx + dy * dy) < letter * 2.5;
      });
      if (near) {
        chain.add(i);
        continue;
      }
    }
    chains.add([i]);
  }
  final found = <({List<int> strokes, _Fit fit, double letter})>[];
  for (final chain in chains) {
    for (final piece in _straightPieces(chain, boxes)) {
      if (piece.length < 4) continue;
      final f = _fit(piece, boxes);
      if (f.angle.abs() < minSlant || f.angle.abs() > _maxSlant) continue;
      // Sizes measured with the run turned level.
      final level = typicalLetterHeight([
        for (final i in piece)
          InkBox.of(
            strokes[i].copyWith(
              points: [
                for (final p in strokes[i].points)
                  levelPoint(p, f.angle, f.cx, f.cy),
              ],
            ),
          ),
      ]);
      if (f.end - f.start < level * 4 || f.spread > level * 0.6) continue;
      found.add((strokes: [...piece], fit: f, letter: level));
    }
  }
  if (found.isEmpty) return const [];
  // Everything else on a run's line joins it: dots and crossbars (just
  // above or on the letters), and writing added later carrying it on.
  final taken = {for (final r in found) ...r.strokes};
  for (final i in idx) {
    if (taken.contains(i)) continue;
    final b = boxes[i]!;
    final mid = PageInkPoint((b.left + b.right) / 2, b.centerY, 0);
    ({List<int> strokes, _Fit fit, double letter})? best;
    var bestAcross = double.infinity;
    for (final r in found) {
      final f = r.fit, h = r.letter;
      final q = levelPoint(mid, f.angle, f.cx, f.cy);
      final across = q.y - f.cy, along = q.x - f.cx;
      if (across < -h || across > h * 1.3) continue;
      if (along < f.start - h || along > f.end + params.lineReach * h) {
        continue;
      }
      if (across.abs() < bestAcross) {
        bestAcross = across.abs();
        best = r;
      }
    }
    best?.strokes.add(i);
  }
  return [
    for (final r in found)
      (strokes: r.strokes, angle: r.fit.angle, cx: r.fit.cx, cy: r.fit.cy),
  ];
}

/// Lines and words among the strokes [idx] (see [groupStrokes]), in the
/// order found.
List<InkLine> _group(
  List<PageStroke> strokes,
  List<int> idx,
  Map<int, InkBox> boxes,
  double letter,
  GroupingParams params,
) {
  // Lines: each stroke joins the line it overlaps most in height (and is
  // near enough to sideways), in writing order. Sizes are measured against
  // each line's own letters, so big writing next to small writing works.
  final lines = <_Line>[];
  for (final i in idx) {
    final b = boxes[i]!;
    _Line? best;
    var bestOverlap = params.lineOverlap;
    // Dots and small marks (the dot of an i, an accent, a full stop) join
    // the line they belong to.
    for (final line in lines) {
      final l = line.box, h = line.letter ?? letter;
      // Above the letters (dots, accents) or right at their foot (full
      // stops, commas); not well below, where smaller writing under big
      // writing would be taken for its dots.
      if (math.max(b.width, b.height) < h * 0.4 &&
          b.horizontalGap(l) <= 0 &&
          b.centerY > l.bottom - h * 0.25 &&
          b.centerY < l.top + h * 0.8) {
        best = line;
        break;
      }
    }
    for (final line in best == null ? lines : const <_Line>[]) {
      final h = math.max(letter, line.letter ?? letter);
      if (b.horizontalGap(line.box) > params.lineReach * h) continue;
      final o = b.verticalOverlap(line.band(line.letter ?? letter));
      if (o >= bestOverlap) {
        bestOverlap = o;
        best = line;
      }
    }
    // Carrying on a line after scrolling (owner's report): writing just to
    // the right of where a line ends joins it even if it drifts a little up
    // or down, as long as it stays within most of a letter of the line.
    if (best == null) {
      var bestGap = double.infinity;
      for (final line in lines) {
        final h = line.letter ?? letter;
        final l = line.box;
        final gap = b.left - l.right;
        if (gap < -h || gap > params.lineReach * h) continue;
        if ((b.centerY - l.centerY).abs() > h * params.lineDrift) continue;
        if (gap < bestGap) {
          bestGap = gap;
          best = line;
        }
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
    final lineLetter = line.letter ?? letter;
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
            (gap < params.wordGap * lineLetter &&
                apart < params.newSessionMs)) {
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
    result.add(InkLine(words, letterHeight: lineLetter));
  }
  _joinManualWords(strokes, boxes, result);
  return result;
}

/// Strokes the user said are one word ([PageStroke.manualWord]) end up in
/// one word: the one holding most of them; the others give theirs up.
void _joinManualWords(
  List<PageStroke> strokes,
  Map<int, InkBox> boxes,
  List<InkLine> lines,
) {
  final groups = <String, List<InkWord>>{};
  for (final line in lines) {
    for (final w in line.words) {
      for (final i in w.strokes) {
        final g = strokes[i].manualWord;
        if (g != null) groups.putIfAbsent(g, () => []).add(w);
      }
    }
  }
  for (final e in groups.entries) {
    final words = e.value.toSet();
    if (words.length < 2) continue;
    int count(InkWord w) =>
        w.strokes.where((i) => strokes[i].manualWord == e.key).length;
    final target = words.reduce((a, b) => count(b) > count(a) ? b : a);
    for (final w in words) {
      if (identical(w, target)) continue;
      final moving = [
        for (final i in w.strokes)
          if (strokes[i].manualWord == e.key) i,
      ];
      w.strokes.removeWhere(moving.contains);
      target.strokes.addAll(moving);
      if (w.strokes.isNotEmpty) w.box = _boxOf(w.strokes, boxes);
    }
    target
      ..box = _boxOf(target.strokes, boxes)
      ..strokes.sort(
        (a, c) =>
            strokes[a].points.first.t.compareTo(strokes[c].points.first.t),
      )
      ..start = target.strokes
          .map((i) => strokes[i].points.first.t)
          .reduce(math.min)
      ..end = target.strokes
          .map((i) => strokes[i].points.last.t)
          .reduce(math.max);
  }
  for (final line in lines) {
    line.words.removeWhere((w) => w.strokes.isEmpty);
  }
  lines.removeWhere((l) => l.words.isEmpty);
}

InkBox _boxOf(List<int> idx, Map<int, InkBox> boxes) =>
    idx.map((i) => boxes[i]!).reduce((a, b) => a.union(b));

/// The typical height of a letter in this writing: the median height of the
/// strokes, ignoring dots and stray marks. At least 4 pt.
double typicalLetterHeight(Iterable<InkBox> boxes) => _medianLetter(boxes) ?? 4;

/// Like [typicalLetterHeight], but null when there are only dots.
double? _medianLetter(Iterable<InkBox> boxes) {
  final h = [
    for (final b in boxes)
      if (math.max(b.width, b.height) > 1.5) b.height,
  ]..sort();
  if (h.isEmpty) return null;
  return math.max(4.0, h[h.length ~/ 2]);
}

/// The strokes of [word] in the recognisers' format: y grows downward (as
/// on screen) so engines see the writing the right way up, positions start
/// near the origin, and sizes are multiplied by [scale] (engines expect
/// writing about the size it is on screen, not in PDF points).
/// Writing at a slant is turned level first.
List<InkStroke> wordInk(
  List<PageStroke> strokes,
  InkWord word, {
  double scale = 1,
}) {
  final slant = word.slant;
  final box = slant?.box ?? word.box;
  return [
    for (final i in word.strokes)
      InkStroke([
        for (final p in strokes[i].points)
          if (slant == null ? p : levelPoint(p, slant.angle, slant.cx, slant.cy)
              case final q)
            InkPoint(
              (q.x - box.left) * scale,
              (box.top - q.y) * scale,
              q.t,
              q.pressure,
            ),
      ]),
  ];
}

class _Line {
  _Line(int i, InkBox b) : strokes = [i], box = b, _boxes = [b] {
    letter = _medianLetter(_boxes);
  }

  final List<int> strokes;
  final List<InkBox> _boxes;
  InkBox box;

  /// Typical letter height of this line so far (null while it has only
  /// dots).
  double? letter;

  void add(int i, InkBox b) {
    strokes.add(i);
    _boxes.add(b);
    box = box.union(b);
    letter = _medianLetter(_boxes);
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
