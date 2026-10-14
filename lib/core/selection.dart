/// What the Select tool picked, and copies for Paste (owner, 2026-10-14).
/// Pure Dart.
library;

import 'page_ink.dart';

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
