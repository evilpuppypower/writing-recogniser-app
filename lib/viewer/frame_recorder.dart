import 'dart:async';

import 'package:flutter/scheduler.dart';

import '../core/frame_summary.dart';

/// While a PDF is open, collects how long each screen update takes and,
/// every [every], hands a summary with what was on screen to [onSummary]
/// (only stretches where something was drawn).
class FrameRecorder {
  FrameRecorder({
    required this.onScreen,
    required this.onSummary,
    this.every = const Duration(seconds: 30),
  });

  /// What's on screen now (counts only), added to each summary.
  final Map<String, Object?> Function() onScreen;
  final void Function(Map<String, Object?> summary) onSummary;
  final Duration every;

  final _frames = <FrameTime>[];
  Timer? _timer;

  void start() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(every, (_) => flush());
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames.add((
        buildMs: t.buildDuration.inMicroseconds / 1000,
        rasterMs: t.rasterDuration.inMicroseconds / 1000,
      ));
    }
  }

  /// Sends the summary of the frames so far, if any.
  void flush() {
    final summary = summariseFrames(_frames);
    _frames.clear();
    if (summary != null) onSummary({...summary, ...onScreen()});
  }

  void stop() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    flush();
  }
}
