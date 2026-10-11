/// Local event log (CLAUDE.md rule 5): recognitions, corrections, accepts
/// and pen-lift-to-text latency. Stays on the device. Pure Dart interface.
library;

class LoggedEvent {
  const LoggedEvent({
    required this.type,
    required this.at,
    this.engine,
    this.latencyMs,
    this.data = const {},
  });

  /// e.g. "recognition", "correction", "accept".
  final String type;
  final DateTime at;

  /// Recognizer name, when relevant.
  final String? engine;

  /// Pen-lift-to-text latency in ms, when relevant.
  final int? latencyMs;

  /// Anything else worth keeping (small, JSON-encodable).
  final Map<String, Object?> data;
}

abstract class EventLog {
  Future<void> log(LoggedEvent event);

  /// Events of [type], oldest first.
  Future<List<LoggedEvent>> ofType(String type);
}
