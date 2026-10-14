/// Summaries of how long the screen took to draw (owner's request: record
/// drawing times with what was on screen, to find what makes it stutter).
/// Pure Dart: the viewer collects the times, this sums them up.
library;

/// One screen update: building the widgets and drawing them (milliseconds).
typedef FrameTime = ({double buildMs, double rasterMs});

/// A frame slower than this (ms) shows as a stutter at 60 updates a
/// second.
const slowFrameMs = 1000 / 60;

/// The numbers kept for a stretch of [frames]: how many, how many were
/// slow, the typical and worst times. Null when there were none.
Map<String, Object?>? summariseFrames(List<FrameTime> frames) {
  if (frames.isEmpty) return null;
  double total(FrameTime f) =>
      f.buildMs > f.rasterMs ? f.buildMs : f.rasterMs; // they overlap
  final times = [for (final f in frames) total(f)]..sort();
  double at(double share) => times[((times.length - 1) * share).round()];
  double worst(double Function(FrameTime) part) =>
      frames.map(part).reduce((a, b) => a > b ? a : b);
  double r(double v) => (v * 10).roundToDouble() / 10;
  return {
    'frames': frames.length,
    'slow': times.where((t) => t > slowFrameMs).length,
    'medianMs': r(at(0.5)),
    'p90Ms': r(at(0.9)),
    'worstMs': r(times.last),
    'worstBuildMs': r(worst((f) => f.buildMs)),
    'worstDrawMs': r(worst((f) => f.rasterMs)),
  };
}
