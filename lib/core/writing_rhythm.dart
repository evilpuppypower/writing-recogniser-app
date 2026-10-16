/// Learning how long the user pauses in the middle of a word (owner's
/// approved idea 5), so reading waits just long enough: a slow writer's
/// words aren't cut in half, and a quick writer doesn't wait. Pure Dart.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'stroke_grouping.dart';

class WritingRhythm {
  WritingRhythm({int? startMs}) : pauseMs = startMs ?? 800;

  static const minMs = 400, maxMs = 2500;

  /// How many recent mid-word pauses are kept.
  static const kept = 200;

  /// Mid-word pauses (pen up to pen down within a word), newest last.
  final gaps = <int>[];

  /// How long to wait after the pen lifts before reading.
  int pauseMs;

  /// [next] was written straight after [previous]: if it carries on the
  /// same word (close beside it on the same line, soon after), the pause
  /// between them is noted. Returns true when [pauseMs] changed.
  bool wrote(PageStroke previous, PageStroke next) {
    if (previous.points.isEmpty || next.points.isEmpty) return false;
    final gap = next.points.first.t - previous.points.last.t;
    if (gap <= 0 || gap > maxMs * 2) return false;
    final a = InkBox.of(previous), b = InkBox.of(next);
    final h = math.max(4.0, math.max(a.height, b.height));
    final apart = a.horizontalGap(b);
    final sameLine = b.verticalOverlap(a) > 0;
    // Close enough to be the same word: less than about half a letter
    // apart (the space between words is wider).
    if (!sameLine || apart > h * 0.5) return false;
    gaps.add(gap);
    if (gaps.length > kept) gaps.removeAt(0);
    return _update();
  }

  bool _update() {
    if (gaps.length < 20) return false; // not enough to go on yet
    final sorted = [...gaps]..sort();
    // Longer than nine in ten of the user's mid-word pauses, with room.
    final p90 =
        sorted[(sorted.length * 0.9).floor().clamp(0, sorted.length - 1)];
    final want = (p90 * 1.3 + 150).round().clamp(minMs, maxMs);
    // Moves a little at a time, so one odd pause doesn't swing it.
    final next = (pauseMs + (want - pauseMs) * 0.25).round();
    if ((next - pauseMs).abs() < 10) return false;
    pauseMs = next;
    return true;
  }
}
