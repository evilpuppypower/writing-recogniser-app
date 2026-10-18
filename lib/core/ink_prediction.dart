/// Guesses where the pen is going next, so the ink can be drawn a little
/// ahead of the last point the tablet reported (owner, 2026-10-18: lag
/// between the pen and the ink). The guess is only drawn, never saved:
/// the stroke keeps the real points.
///
/// Pure Dart. Positions are in screen pixels, times in microseconds.
library;

import 'dart:math' as math;

class InkPredictor {
  InkPredictor({this.windowMicros = 24000, this.maxPixels = 24});

  /// How far back the points used for the guess go.
  final int windowMicros;

  /// The guess never runs further than this from the last real point.
  final double maxPixels;

  /// How far each guess was from where the pen really went (pixels), for
  /// the diagnostics.
  void Function(double errorPixels)? onError;

  final _x = <double>[], _y = <double>[];
  final _t = <int>[];

  /// The last guess, kept to check it against the next real point.
  _Guess? _guess;

  void reset() {
    _x.clear();
    _y.clear();
    _t.clear();
    _guess = null;
  }

  /// A real pen point.
  void add(double x, double y, int tMicros) {
    final g = _guess;
    _guess = null;
    if (g != null && tMicros > g.t0 && tMicros - g.t0 <= g.ahead) {
      final (gx, gy) = g.at((tMicros - g.t0).toDouble());
      final dx = gx - x, dy = gy - y;
      onError?.call(math.sqrt(dx * dx + dy * dy));
    }
    if (_t.isNotEmpty && tMicros <= _t.last) {
      // Same moment (or the clock stepped back): the newer position wins.
      _x.last = x;
      _y.last = y;
      return;
    }
    _x.add(x);
    _y.add(y);
    _t.add(tMicros);
    var drop = 0;
    while (drop < _t.length - 3 && _t.last - _t[drop] > windowMicros) {
      drop++;
    }
    if (drop > 0) {
      _x.removeRange(0, drop);
      _y.removeRange(0, drop);
      _t.removeRange(0, drop);
    }
  }

  /// Where the pen should be over the next [aheadMicros], as a few points
  /// after the last real one; empty when there's nothing sensible to guess
  /// (too few points, or the pen has stopped reporting).
  List<(double, double)> predict(int aheadMicros) {
    final n = _t.length;
    if (aheadMicros <= 0 || n < 3) return const [];
    final t0 = _t.last;
    // A long pause between points: the pen has stopped, don't guess.
    if (t0 - _t[n - 2] > 40000 || t0 - _t.first < 4000) return const [];
    // A curve through the recent points (x and y against time), so the
    // guess bends with an "o" instead of shooting off along a tangent.
    final fx = _fit(_x), fy = _fit(_y);
    final x0 = _x.last, y0 = _y.last;
    var ahead = aheadMicros.toDouble();
    // Only half the bend is trusted: a full curve overshoots when the pen
    // changes its mind.
    (double, double) at(double dt) {
      final s = dt / 1000;
      return (
        x0 + fx.$1 * s + 0.5 * fx.$2 * s * s,
        y0 + fy.$1 * s + 0.5 * fy.$2 * s * s,
      );
    }

    var (ex, ey) = at(ahead);
    final far = math.sqrt((ex - x0) * (ex - x0) + (ey - y0) * (ey - y0));
    if (far > maxPixels) {
      ahead *= maxPixels / far;
      (ex, ey) = at(ahead);
    }
    if (far < 0.5) return const []; // standing still
    _guess = _Guess(t0, ahead.round(), at);
    const step = 4000.0;
    return [for (var dt = step; dt < ahead; dt += step) at(dt), (ex, ey)];
  }

  /// Speed (pixels per ms) at the newest point, and the bend c of
  /// v = a + b s + c s² (s in ms).
  (double, double) _fit(List<double> v) {
    final n = v.length;
    final t0 = _t.last;
    // Times in ms before the newest point (0 or less).
    var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0;
    var b0 = 0.0, b1 = 0.0, b2 = 0.0;
    for (var i = 0; i < n; i++) {
      final s = (_t[i] - t0) / 1000;
      final s2i = s * s;
      s1 += s;
      s2 += s2i;
      s3 += s2i * s;
      s4 += s2i * s2i;
      b0 += v[i];
      b1 += v[i] * s;
      b2 += v[i] * s2i;
    }
    if (n >= 4) {
      // v = a + b s + c s², least squares.
      final det =
          n * (s2 * s4 - s3 * s3) -
          s1 * (s1 * s4 - s3 * s2) +
          s2 * (s1 * s3 - s2 * s2);
      if (det.abs() > 1e-9) {
        final db =
            n * (b1 * s4 - s3 * b2) -
            b0 * (s1 * s4 - s3 * s2) +
            s2 * (s1 * b2 - b1 * s2);
        final dc =
            n * (s2 * b2 - b1 * s3) -
            s1 * (s1 * b2 - b1 * s2) +
            b0 * (s1 * s3 - s2 * s2);
        return (db / det, dc / det);
      }
    }
    // A straight line through them.
    final mean = s1 / n, vm = b0 / n;
    final den = s2 - n * mean * mean;
    if (den.abs() < 1e-9) return (0, 0);
    return ((b1 - n * mean * vm) / den, 0);
  }
}

class _Guess {
  _Guess(this.t0, this.ahead, this.at);
  final int t0, ahead;
  final (double, double) Function(double dt) at;
}
