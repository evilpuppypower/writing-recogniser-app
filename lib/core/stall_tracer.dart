/// What the app was doing when the screen stuttered (owner, 2026-10-24:
/// "get better diagnostics … the periodic spikes"). The heavy jobs on the
/// screen's thread are timed by name ([StallTracer.time]); a slow frame or
/// a stall of the thread is then put down to the jobs that ran during it,
/// and the diagnostics count spikes by cause. Pure Dart; times are
/// microseconds on the same clock as Flutter's frame timings.
library;

import 'dart:collection';
import 'dart:developer' show Timeline;

/// A stretch of time (microseconds).
typedef Span = ({int start, int end});

/// A named job that ran on the screen's thread.
typedef Job = ({String what, int start, int end});

class StallTracer {
  StallTracer({int Function()? now}) : _now = now ?? (() => Timeline.now);

  /// The app's tracer.
  static final instance = StallTracer();

  final int Function() _now;

  /// Jobs this long or longer are kept (microseconds): shorter ones can't
  /// make a frame late.
  static const keepMicros = 2000;

  /// Jobs kept, oldest first (a few seconds' worth is plenty).
  final _jobs = ListQueue<Job>();
  static const _maxJobs = 3000;

  int get now => _now();

  /// Runs [f], timed as [what] when it takes long enough to matter.
  T time<T>(String what, T Function() f) {
    final start = _now();
    try {
      return f();
    } finally {
      final end = _now();
      if (end - start >= keepMicros) add(what, start, end);
    }
  }

  /// Notes a job (e.g. one timed elsewhere).
  void add(String what, int start, int end) {
    _jobs.addLast((what: what, start: start, end: end));
    while (_jobs.length > _maxJobs) {
      _jobs.removeFirst();
    }
  }

  /// The jobs that ran during [span] (any overlap).
  List<Job> during(Span span) => [
    for (final j in _jobs)
      if (j.start < span.end && j.end > span.start) j,
  ];

  /// Forgets jobs that ended before [micros].
  void forgetBefore(int micros) {
    while (_jobs.isNotEmpty && _jobs.first.end < micros) {
      _jobs.removeFirst();
    }
  }
}

/// Counts of spikes by cause, for the diagnostics: each spike ([spikes],
/// with how long it was, ms) is put down to the jobs [tracer] saw during
/// it, the longest first; a spike with no job in it counts as
/// "unexplained" (e.g. the system, or memory being tidied).
Map<String, Object?> spikeCauses(
  List<({Span span, double ms})> spikes,
  StallTracer tracer, {
  String name = 'spikes',
}) {
  final count = <String, int>{};
  final worst = <String, double>{};
  var unexplained = 0;
  for (final s in spikes) {
    final jobs = tracer.during(s.span);
    if (jobs.isEmpty) {
      unexplained++;
      continue;
    }
    // The job that took most of the spike.
    int overlap(Job j) =>
        (j.end < s.span.end ? j.end : s.span.end) -
        (j.start > s.span.start ? j.start : s.span.start);
    final main = jobs.reduce((a, b) => overlap(b) > overlap(a) ? b : a);
    count[main.what] = (count[main.what] ?? 0) + 1;
    final ms = (main.end - main.start) / 1000;
    if (ms > (worst[main.what] ?? 0)) worst[main.what] = ms;
  }
  if (spikes.isEmpty) return const {};
  double r(double v) => (v * 10).roundToDouble() / 10;
  return {
    name: spikes.length,
    '${name}Unexplained': unexplained,
    '${name}WorstMs': r(
      spikes.map((s) => s.ms).reduce((a, b) => a > b ? a : b),
    ),
    if (count.isNotEmpty)
      '${name}Causes': {
        for (final e
            in (count.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value))))
          e.key: {'n': e.value, 'worstMs': r(worst[e.key]!)},
      },
  };
}

/// Finds stalls of the screen's thread between frames: [tick] is called
/// about every [every]; a gap much longer than that means the thread was
/// busy (or the app was asleep: gaps longer than [ignoreOver] are left
/// out).
class StallWatch {
  StallWatch({
    this.every = const Duration(milliseconds: 100),
    this.slowerBy = const Duration(milliseconds: 150),
    this.ignoreOver = const Duration(seconds: 5),
  });

  final Duration every, slowerBy, ignoreOver;
  int? _last;
  final stalls = <({Span span, double ms})>[];

  void tick(int nowMicros) {
    final last = _last;
    _last = nowMicros;
    if (last == null) return;
    final gap = nowMicros - last;
    if (gap > (every + slowerBy).inMicroseconds &&
        gap < ignoreOver.inMicroseconds) {
      final busy = gap - every.inMicroseconds;
      stalls.add((
        span: (start: last + every.inMicroseconds, end: nowMicros),
        ms: busy / 1000,
      ));
    }
  }

  void reset() => _last = null;
}
