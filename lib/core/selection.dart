/// What the Select tool picked, and copies for Paste (owner, 2026-10-14).
/// Pure Dart.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'stroke_grouping.dart';

/// Strokes [ids] picked on [page].
class InkSelection {
  const InkSelection(this.page, this.ids);

  final int page;
  final Set<String> ids;
}

/// Copies of [strokes] to paste: moved [dx], [dy] points (so they don't
/// sit exactly over the originals) and given new times from [nowMs] (a
/// stroke's id comes from its start time, so copies need their own).
/// Copies are plain ink: not converted, and a "one word" mark gets a mark of
/// its own, so copies and originals aren't read as one word.
List<PageStroke> pastedCopies(
  List<PageStroke> strokes,
  int nowMs, {
  double dx = 12,
  double dy = -12,
}) {
  if (strokes.isEmpty) return const [];
  final first = strokes
      .map((s) => s.points.first.t)
      .reduce((a, b) => a < b ? a : b);
  return [
    for (final s in strokes)
      PageStroke(
        points: [
          for (final p in s.points)
            PageInkPoint(p.x + dx, p.y + dy, p.t - first + nowMs, p.pressure),
        ],
        colorArgb: s.colorArgb,
        width: s.width,
        tool: s.tool,
        arrow: s.arrow,
        notWriting: s.notWriting,
        manualWord: s.manualWord == null ? null : '${s.manualWord}@$nowMs',
      ),
  ];
}

/// [strokes] (a selection) with each line of writing in them turned level
/// about its middle ("Straighten"): same ids, so recognised words stay
/// with them. Lines already level (within half a degree) are left out.
List<PageStroke> straightened(List<PageStroke> strokes) {
  final out = <PageStroke>[];
  for (final line in groupStrokes(strokes)) {
    final idx = [for (final w in line.words) ...w.strokes];
    final slant = line.words.first.slant;
    final dir = slant == null
        ? lineDirection(strokes, idx)
        : (angle: slant.angle, cx: slant.cx, cy: slant.cy);
    if (dir == null || dir.angle.abs() < 0.5 * math.pi / 180) {
      continue;
    }
    for (final i in idx) {
      out.add(
        strokes[i].copyWith(
          points: [
            for (final p in strokes[i].points)
              levelPoint(p, dir.angle, dir.cx, dir.cy),
          ],
        ),
      );
    }
  }
  return out;
}

/// The words read in a selection, as text to paste elsewhere ("Copy as
/// text"): lines on their own lines, words in order. [words] are the
/// page's words in reading order, each with its line number and stroke
/// ids; a word counts when at least half its strokes are selected.
String selectionText(
  Iterable<({int line, List<String> strokeIds, String text})> words,
  Set<String> selected,
) {
  final lines = <int, List<String>>{};
  for (final w in words) {
    final inside = w.strokeIds.where(selected.contains).length;
    if (w.text.trim().isEmpty || inside * 2 < w.strokeIds.length) continue;
    lines.putIfAbsent(w.line, () => []).add(w.text.trim());
  }
  final keys = lines.keys.toList()..sort();
  return [for (final l in keys) lines[l]!.join(' ')].join('\n');
}
