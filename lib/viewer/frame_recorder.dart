import 'dart:async';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';

import '../core/frame_summary.dart';
import '../core/pen_timing.dart';
import '../core/stall_tracer.dart';

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

  /// What made screen updates and the screen's thread slow, by cause
  /// (owner, 2026-10-24: "better diagnostics" for the periodic spikes).
  final _tracer = StallTracer.instance;
  final _watch = StallWatch();
  Timer? _ticker;
  final _buildSpikes = <({Span span, double ms})>[];
  final _drawSpikes = <({Span span, double ms})>[];

  /// A part of a frame slower than this (ms) counts as a spike: more than
  /// two refreshes at 90 a second.
  static const spikeMs = 24.0;
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
    _watch.reset();
    _ticker = Timer.periodic(_watch.every, (_) => _watch.tick(_tracer.now));
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final buildMs = t.buildDuration.inMicroseconds / 1000;
      final rasterMs = t.rasterDuration.inMicroseconds / 1000;
      _frames.add((buildMs: buildMs, rasterMs: rasterMs));
      if (buildMs > spikeMs) {
        _buildSpikes.add((
          span: (
            start: t.timestampInMicroseconds(FramePhase.buildStart),
            end: t.timestampInMicroseconds(FramePhase.buildFinish),
          ),
          ms: buildMs,
        ));
      }
      if (rasterMs > spikeMs) {
        // Drawing is slow because of what the frame was built with.
        _drawSpikes.add((
          span: (
            start: t.timestampInMicroseconds(FramePhase.buildStart),
            end: t.timestampInMicroseconds(FramePhase.rasterFinish),
          ),
          ms: rasterMs,
        ));
      }
      pen.frameTimed(
        t.timestampInMicroseconds(FramePhase.vsyncStart),
        t.timestampInMicroseconds(FramePhase.rasterFinish),
      );
    }
  }

  /// The summary of the frames so far (and starts again), or null.
  Map<String, Object?>? _take() {
    final summary = summariseFrames(_frames);
    _frames.clear();
    final writing = pen.summary();
    // Stalls between frames (a slow frame's build counts as its spike).
    final stalls = [
      for (final s in _watch.stalls)
        if (!_buildSpikes.any(
          (b) => b.span.start < s.span.end && b.span.end > s.span.start,
        ))
          s,
    ];
    final causes = {
      ...spikeCauses(_buildSpikes, _tracer),
      ...spikeCauses(_drawSpikes, _tracer, name: 'drawSpikes'),
      ...spikeCauses(stalls, _tracer, name: 'stalls'),
    };
    _buildSpikes.clear();
    _drawSpikes.clear();
    _watch.stalls.clear();
    if (summary == null && writing == null && causes.isEmpty) return null;
    return {
      ...?summary,
      ...?writing,
      ...causes,
      ..._tracer.time('diagnostics', onScreen),
    };
  }

  /// Sends the summary of the frames so far, if any, with the screen's
  /// refresh rate.
  Future<void> flush() async {
    final taken = _take();
    if (taken == null) return;
    Map<String, Object?> shown = const {};
    try {
      shown = await display?.call() ?? const {};
    } catch (_) {}
    onSummary({...taken, ...shown});
  }

  void stop() {
    _running = false;
    if (identical(_current, this)) _current = null;
    _timer?.cancel();
    _ticker?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    // Sent now, while the PDF is closing (no waiting for the refresh rate).
    final taken = _take();
    if (taken != null) onSummary(taken);
  }
}
