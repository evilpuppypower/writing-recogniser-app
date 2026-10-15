import 'dart:math' as math;

import '../core/ink.dart';
import '../core/recognition/recognizer.dart';

/// Turns MyScript's JIIX answer into candidates: the full text first, then
/// alternatives made by swapping in each word's next-best reading.
List<Candidate> jiixToCandidates(Map<String, Object?> jiix, {int max = 5}) {
  final label = (jiix['label'] as String?)?.trim() ?? '';
  if (label.isEmpty) return const [];
  final words = [
    for (final w in (jiix['words'] as List?) ?? const [])
      if (w is Map) w,
  ];
  final labels = [for (final w in words) '${w['label'] ?? ''}'];
  final result = <String>[label];
  for (var i = 0; i < words.length && result.length < max; i++) {
    final cands = [
      for (final c in (words[i]['candidates'] as List?) ?? const []) '$c',
    ];
    for (final c in cands) {
      if (result.length >= max) break;
      if (c == labels[i] || c.trim().isEmpty) continue;
      final alt = [...labels]..[i] = c;
      final text = alt.join().trim();
      if (!result.contains(text)) result.add(text);
    }
  }
  return [for (final t in result) Candidate(t)];
}

/// A line read whole: MyScript's words, each with the strokes (indexes into
/// [strokes]) inside its box. Boxes are in millimetres; [mmPerX], [mmPerY]
/// convert the strokes' points to match. Each stroke goes to the word whose
/// box it overlaps most (or the nearest). Null if a word has no box (the
/// line is then read word by word).
List<LineWord>? jiixLineWords(
  Map<String, Object?> jiix,
  List<InkStroke> strokes, {
  required double mmPerX,
  required double mmPerY,
}) {
  final words =
      <({List<String> readings, double l, double t, double r, double b})>[];
  for (final w in (jiix['words'] as List?) ?? const []) {
    if (w is! Map) continue;
    final label = '${w['label'] ?? ''}';
    if (label.trim().isEmpty) continue; // the spaces between words
    final box = w['bounding-box'];
    if (box is! Map) return null;
    num n(Object? v) => v is num ? v : 0;
    final x = n(box['x']).toDouble(), y = n(box['y']).toDouble();
    words.add((
      readings: {
        label.trim(),
        for (final c in (w['candidates'] as List?) ?? const [])
          if ('$c'.trim().isNotEmpty) '$c'.trim(),
      }.toList(),
      l: x,
      t: y,
      r: x + n(box['width']).toDouble(),
      b: y + n(box['height']).toDouble(),
    ));
  }
  if (words.isEmpty) return null;
  final of = _assign(words, strokes, mmPerX, mmPerY);
  if (of != null) return _lineWords(words, of);
  // The boxes don't sit on the ink as expected (other units or origin):
  // fit the boxes' overall extent onto the ink's, as the writing/drawing
  // sorting does, and try once more; else give up (read word by word).
  final ink = _extent([
    for (final s in strokes)
      for (final p in s.points) (p.x * mmPerX, p.y * mmPerY),
  ]);
  final boxes = _extent([
    for (final w in words) ...[(w.l, w.t), (w.r, w.b)],
  ]);
  if (ink == null || boxes == null) return null;
  double fx(double v) =>
      boxes.w <= 0 ? ink.l : ink.l + (v - boxes.l) * ink.w / boxes.w;
  double fy(double v) =>
      boxes.h <= 0 ? ink.t : ink.t + (v - boxes.t) * ink.h / boxes.h;
  final fitted = [
    for (final w in words)
      (readings: w.readings, l: fx(w.l), t: fy(w.t), r: fx(w.r), b: fy(w.b)),
  ];
  final again = _assign(fitted, strokes, mmPerX, mmPerY);
  return again == null ? null : _lineWords(fitted, again);
}

typedef _Box = ({
  List<String> readings,
  double l,
  double t,
  double r,
  double b,
});

List<LineWord> _lineWords(List<_Box> words, List<List<int>> of) => [
  for (var k = 0; k < words.length; k++)
    if (of[k].isNotEmpty) LineWord(words[k].readings, of[k]),
];

({double l, double t, double w, double h})? _extent(
  List<(double, double)> points,
) {
  if (points.isEmpty) return null;
  final xs = points.map((p) => p.$1), ys = points.map((p) => p.$2);
  final l = xs.reduce(math.min), t = ys.reduce(math.min);
  return (l: l, t: t, w: xs.reduce(math.max) - l, h: ys.reduce(math.max) - t);
}

/// Each stroke's word (the box it overlaps most, or the nearest); null if
/// fewer than 4 in 5 strokes overlap any box (the boxes don't fit the ink).
List<List<int>>? _assign(
  List<_Box> words,
  List<InkStroke> strokes,
  double mmPerX,
  double mmPerY,
) {
  final of = List.generate(words.length, (_) => <int>[]);
  var overlapping = 0, counted = 0;
  for (var i = 0; i < strokes.length; i++) {
    final pts = strokes[i].points;
    if (pts.isEmpty) continue;
    var l = double.infinity, t = double.infinity;
    var r = -double.infinity, b = -double.infinity;
    for (final p in pts) {
      l = math.min(l, p.x * mmPerX);
      r = math.max(r, p.x * mmPerX);
      t = math.min(t, p.y * mmPerY);
      b = math.max(b, p.y * mmPerY);
    }
    counted++;
    var best = -1;
    var bestScore = -double.infinity;
    for (var k = 0; k < words.length; k++) {
      final w = words[k];
      final ox = math.min(r, w.r) - math.max(l, w.l);
      final oy = math.min(b, w.b) - math.max(t, w.t);
      // Overlap when there is some; otherwise minus the distance between
      // middles (the nearest box wins).
      final score = ox >= 0 && oy >= 0
          ? (ox + 1e-3) * (oy + 1e-3)
          : -math.sqrt(
              math.pow((l + r) / 2 - (w.l + w.r) / 2, 2) +
                  math.pow((t + b) / 2 - (w.t + w.b) / 2, 2),
            );
      if (score > bestScore) {
        bestScore = score;
        best = k;
      }
    }
    if (bestScore > 0) overlapping++;
    of[best].add(i);
  }
  if (counted == 0 || overlapping * 5 < counted * 4) return null;
  return of;
}
