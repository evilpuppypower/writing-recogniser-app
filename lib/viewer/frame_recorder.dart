import 'dart:async';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';

import '../core/frame_summary.dart';
import '../core/pen_timing.dart';

/// While a PDF is open, collects how long each screen update takes, how
/// long pen ink takes to reach the screen ([pen]) and, every [every],
/// hands a summary with what was on screen to [onSummary] (only stretches
/// where something was drawn).
class FrameRecorder {
  FrameRecorder({
    required this.onScreen,
    required this.onSummary,
    this.display,
    this.every = const Duration(seconds: 30),
  });

  /// What's on screen now (counts only), added to each summary.
  final Map<String, Object?> Function() onScreen;
  final void Function(Map<String, Object?> summary) onSummary;

  /// The screen's refresh rate and power saving now (from Android), added
  /// to each summary.
  final Future<Map<String, Object?>> Function()? display;
  final Duration every;

  /// Pen ink's way to the screen (fed by the ink layer).
  final pen = PenTiming();

  final _frames = <FrameTime>[];
  Timer? _timer;
  var _running = false;
  static var _callbackAdded = false;
  static FrameRecorder? _current;

  void start() {
    _running = true;
    _current = this;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // Each frame notes which pen points it draws (a persistent callback
    // can't be removed, so there's one for the app, for the open PDF).
    if (!_callbackAdded) {
      _callbackAdded = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        final r = _current;
        if (r == null || !r._running) return;
        r.pen.frameBegan(
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds,
        );
      });
    }
    _timer = Timer.periodic(every, (_) => flush());
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames.add((
        buildMs: t.buildDuration.inMicroseconds / 1000,
        rasterMs: t.rasterDuration.inMicroseconds / 1000,
      ));
      pen.frameTimed(
        t.timestampInMicroseconds(FramePhase.vsyncStart),
        t.timestampInMicroseconds(FramePhase.rasterFinish),
      );
    }
  }

  /// Sends the summary of the frames so far, if any.
  Future<void> flush() async {
    final summary = summariseFrames(_frames);
    _frames.clear();
    final writing = pen.summary();
    if (summary == null && writing == null) return;
    final screen = onScreen();
    Map<String, Object?> shown = const {};
    try {
      shown = await display?.call() ?? const {};
    } catch (_) {}
    onSummary({...?summary, ...?writing, ...screen, ...shown});
  }

  void stop() {
    _running = false;
    if (identical(_current, this)) _current = null;
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    unawaited(flush());
  }
}
