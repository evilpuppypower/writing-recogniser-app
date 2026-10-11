/// Telling a pen tap from writing, and two taps from a double-tap (task
/// 2.4b: double-tap a word's label with the pen to correct it, as with a
/// finger). Pure Dart; distances are in screen pixels, times in ms.
library;

import 'dart:math' as math;

/// A pen tap: where it touched (screen pixels) and when it touched and
/// lifted (ms since epoch).
class PenTap {
  const PenTap(this.x, this.y, this.downMs, this.upMs);

  final double x, y;
  final int downMs, upMs;
}

class PenTapRules {
  const PenTapRules({
    this.maxTapMs = 250,
    this.maxTapMove = 8,
    this.maxGapMs = 400,
    this.maxDoubleDistance = 24,
  });

  /// A touch longer than this is writing, not a tap.
  final int maxTapMs;

  /// A touch that moves further than this (pixels) is writing.
  final double maxTapMove;

  /// Longest pause between the first tap lifting and the second touching.
  final int maxGapMs;

  /// Furthest apart (pixels) the two taps of a double-tap can be.
  final double maxDoubleDistance;

  /// How long to hold a first tap back while waiting for a second one.
  Duration get holdFor => Duration(milliseconds: maxGapMs + maxTapMs);

  /// Whether a touch that moved [movedPx] at most and lasted [durationMs]
  /// is a tap.
  bool isTap(double movedPx, int durationMs) =>
      movedPx <= maxTapMove && durationMs <= maxTapMs;

  /// Whether [second] follows [first] closely enough to make a double-tap.
  bool isDouble(PenTap first, PenTap second) {
    final gap = second.downMs - first.upMs;
    if (gap < 0 || gap > maxGapMs) return false;
    final dx = second.x - first.x, dy = second.y - first.y;
    return math.sqrt(dx * dx + dy * dy) <= maxDoubleDistance;
  }
}
