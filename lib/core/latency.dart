/// How the time from lifting the pen to seeing text was spent.
/// Pure Dart so the numbers can be logged and tested anywhere.
class LatencyBreakdown {
  const LatencyBreakdown({
    required this.waitMs,
    required this.engineMs,
    required this.displayMs,
  });

  /// Pen lift until the ink was sent to the engine. Mostly the
  /// "pause before recognising" setting.
  final int waitMs;

  /// Ink sent until the engine's answer came back (includes passing the
  /// ink to and from the Android side).
  final int engineMs;

  /// Answer back until it was drawn on screen.
  final int displayMs;

  int get totalMs => waitMs + engineMs + displayMs;

  /// Builds a breakdown from the moments each step happened (ms since epoch).
  /// Clamps at zero so a clock hiccup can't show negative time.
  factory LatencyBreakdown.fromTimes({
    required int penLift,
    required int sent,
    required int answered,
    required int shown,
  }) {
    int gap(int a, int b) => b - a < 0 ? 0 : b - a;
    return LatencyBreakdown(
      waitMs: gap(penLift, sent),
      engineMs: gap(sent, answered),
      displayMs: gap(answered, shown),
    );
  }

  Map<String, int> toJson() => {
    'waitMs': waitMs,
    'engineMs': engineMs,
    'displayMs': displayMs,
    'totalMs': totalMs,
  };
}

/// Median of [values], or null when empty.
int? medianMs(Iterable<int> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return null;
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : ((sorted[mid - 1] + sorted[mid]) / 2).round();
}

/// "0.42 s" or "85 ms".
String formatMs(int ms) =>
    ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(2)} s';
