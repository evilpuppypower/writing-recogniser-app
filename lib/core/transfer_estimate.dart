/// Progress and time-remaining estimates for long-running copies, such as
/// importing a large PDF. Pure Dart so it can be unit-tested and reused on
/// Windows.
library;

/// Tracks how many bytes have been processed over time and estimates how long
/// is left.
///
/// The speed is smoothed so the estimate doesn't jump around, and no estimate
/// is given until there's enough data ([minElapsed]) to be meaningful.
class TransferEstimator {
  TransferEstimator({
    required this.totalBytes,
    this.minElapsed = const Duration(milliseconds: 500),
    this.smoothing = 0.3,
  }) : assert(smoothing > 0 && smoothing <= 1);

  /// Total size in bytes, or a negative number if unknown.
  final int totalBytes;

  /// No time estimate is given before this much time has passed.
  final Duration minElapsed;

  /// Weight of the newest speed sample (0..1). Higher reacts faster.
  final double smoothing;

  int _bytes = 0;
  Duration _elapsed = Duration.zero;
  double? _bytesPerSecond;

  int get bytesDone => _bytes;
  bool get sizeKnown => totalBytes > 0;

  /// Current smoothed speed in bytes per second, if known.
  double? get bytesPerSecond => _bytesPerSecond;

  /// Records that [bytesDone] bytes had been processed after [elapsed].
  void update({required int bytesDone, required Duration elapsed}) {
    final dt = (elapsed - _elapsed).inMicroseconds / 1e6;
    final db = bytesDone - _bytes;
    if (dt > 0 && db >= 0) {
      final sample = db / dt;
      final previous = _bytesPerSecond;
      _bytesPerSecond = previous == null
          ? sample
          : previous + smoothing * (sample - previous);
    }
    _bytes = bytesDone;
    _elapsed = elapsed;
  }

  /// Fraction complete (0..1), or null if the total size is unknown.
  double? get fraction =>
      sizeKnown ? (_bytes / totalBytes).clamp(0.0, 1.0) : null;

  /// Estimated time left, or null if it can't be estimated yet.
  Duration? get remaining {
    final speed = _bytesPerSecond;
    if (!sizeKnown || speed == null || speed <= 0) return null;
    if (_elapsed < minElapsed) return null;
    final left = (totalBytes - _bytes).clamp(0, totalBytes);
    return Duration(milliseconds: (left / speed * 1000).round());
  }
}

/// "about 12 s left", "about 2 min left", "almost done".
String formatRemaining(Duration remaining) {
  final s = remaining.inMilliseconds / 1000;
  if (s < 1.5) return 'almost done';
  if (s < 60) return 'about ${s.round()} s left';
  final minutes = (s / 60).round();
  return 'about $minutes min left';
}

/// "820 KB", "3.4 MB", "1.2 GB" (powers of 1024, like Android's Files app).
String formatBytes(int bytes) {
  const units = ['bytes', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes bytes';
  final text = value >= 100 || unit == 1
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
