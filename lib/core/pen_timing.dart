/// How long the pen's ink takes to reach the screen, and whether strokes
/// lose points (owner, 2026-10-18: lag between the pen and the ink, and
/// parts of an "o" drawn as straight lines). Pure Dart: the viewer feeds
/// it pen times, frames and strokes; only numbers are kept.
///
/// Times are in microseconds on the clock pen events and frame timings
/// share (the tablet's time since it started).
library;

class PenTiming {
  /// Pen points handed to the screen, not yet in a frame.
  final _pending = <int>[];

  /// Frames that drew new pen points: their start, and the oldest and
  /// newest point in them.
  final _frames = <int, ({int oldest, int newest})>{};

  final _newestMs = <double>[], _oldestMs = <double>[];
  final _guessErrorPx = <double>[];
  final _writingFrameStarts = <int>[];
  int _strokes = 0, _gappy = 0, _points = 0, _straightened = 0;
  double _worstGapMs = 0;

  /// A pen point at [eventMicros] was added to the ink being drawn.
  void point(int eventMicros) {
    if (eventMicros > 0) _pending.add(eventMicros);
  }

  /// A frame starting at [startMicros] is being built: it draws the pen
  /// points added since the last one.
  void frameBegan(int startMicros) {
    if (_pending.isEmpty) return;
    var oldest = _pending.first, newest = _pending.first;
    for (final t in _pending) {
      if (t < oldest) oldest = t;
      if (t > newest) newest = t;
    }
    _pending.clear();
    _frames[startMicros] = (oldest: oldest, newest: newest);
    // Not kept for ever if a frame's timing never comes.
    if (_frames.length > 600) _frames.remove(_frames.keys.first);
  }

  /// A frame that started at [startMicros] finished drawing at
  /// [rasterFinishMicros] (it shows on the next screen refresh).
  void frameTimed(int startMicros, int rasterFinishMicros) {
    int? key;
    if (_frames.containsKey(startMicros)) {
      key = startMicros;
    } else {
      // The two clocks' readings of a frame's start can differ a little.
      for (final k in _frames.keys) {
        if ((k - startMicros).abs() <= 3000) {
          key = k;
          break;
        }
      }
    }
    if (key == null) return;
    final f = _frames.remove(key)!;
    _newestMs.add((rasterFinishMicros - f.newest) / 1000);
    _oldestMs.add((rasterFinishMicros - f.oldest) / 1000);
    _writingFrameStarts.add(startMicros);
  }

  /// A stroke ended; [timesMs] are its points' times. A gap of more than
  /// [gapMs] between two points means samples went missing (or the pen
  /// paused).
  void stroke(List<int> timesMs, {int gapMs = 20}) {
    if (timesMs.length < 2) return;
    _strokes++;
    _points += timesMs.length;
    var worst = 0;
    for (var i = 1; i < timesMs.length; i++) {
      final g = timesMs[i] - timesMs[i - 1];
      if (g > worst) worst = g;
    }
    if (worst > gapMs) _gappy++;
    if (worst > _worstGapMs) _worstGapMs = worst.toDouble();
  }

  /// The ink drawn ahead of the pen missed where the pen really went by
  /// [pixels] (see InkPredictor).
  void guessed(double pixels) {
    if (_guessErrorPx.length < 20000) _guessErrorPx.add(pixels);
  }

  /// A stroke was straightened (the pen held still, see snapHoldTime).
  void straightened() => _straightened++;

  /// The numbers since the last summary (and starts again), or null if
  /// nothing was written.
  Map<String, Object?>? summary() {
    if (_newestMs.isEmpty &&
        _strokes == 0 &&
        _straightened == 0 &&
        _guessErrorPx.isEmpty) {
      return null;
    }
    double at(List<double> v, double share) {
      final s = [...v]..sort();
      return s[((s.length - 1) * share).round()];
    }

    double r(double v) => (v * 10).roundToDouble() / 10;
    // The screen's rate while writing: frames drawn one after another.
    final starts = [..._writingFrameStarts]..sort();
    final gaps = <double>[
      for (var i = 1; i < starts.length; i++)
        if (starts[i] - starts[i - 1] < 100000)
          (starts[i] - starts[i - 1]) / 1000,
    ];
    final out = <String, Object?>{
      if (_newestMs.isNotEmpty) ...{
        'penFrames': _newestMs.length,
        // From the newest point in a frame to that frame being drawn (the
        // screen shows it at its next refresh, a few ms later).
        'penMedianMs': r(at(_newestMs, 0.5)),
        'penP90Ms': r(at(_newestMs, 0.9)),
        'penWorstMs': r(at(_newestMs, 1)),
        // From the oldest point in a frame: how long a point can wait.
        'penOldestP90Ms': r(at(_oldestMs, 0.9)),
      },
      if (gaps.length >= 5) 'writingHz': (1000 / at(gaps, 0.5)).round(),
      if (_strokes > 0) ...{
        'strokes': _strokes,
        'pointsPerStroke': (_points / _strokes).round(),
        'strokesWithGaps': _gappy,
        'worstGapMs': _worstGapMs.round(),
      },
      if (_straightened > 0) 'straightened': _straightened,
      if (_guessErrorPx.isNotEmpty) ...{
        // How far the ink drawn ahead of the pen was off, in pixels.
        'leadMissMedianPx': r(at(_guessErrorPx, 0.5)),
        'leadMissP90Px': r(at(_guessErrorPx, 0.9)),
      },
    };
    _newestMs.clear();
    _oldestMs.clear();
    _guessErrorPx.clear();
    _writingFrameStarts.clear();
    _strokes = _gappy = _points = _straightened = 0;
    _worstGapMs = 0;
    return out;
  }
}
