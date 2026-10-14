/// The diagnostic report the owner can save and send when something goes
/// wrong (owner's request, 2026-10-14). Pure Dart.
///
/// Only what helps find the problem: sizes, counts, timings and error
/// messages. No document names, recognised words or ink (the log never
/// records them), and times are UTC.
library;

import 'dart:convert';

import 'event_log.dart';

/// Keep the report to the most recent entries.
const diagnosticReportLimit = 300;

/// "diagnostics-20260131-0945.txt" (UTC).
String diagnosticReportFileName(DateTime now) {
  final d = now.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'diagnostics-${d.year}${two(d.month)}${two(d.day)}-'
      '${two(d.hour)}${two(d.minute)}.txt';
}

/// Just the build number from the app's build label ("41 · local time"):
/// the local time would hint at the owner's time zone.
String buildNumberOnly(String label) =>
    label.split('·').first.trim().isEmpty ? '?' : label.split('·').first.trim();

/// The report's text: a header, the last crash (if any), then the newest
/// [diagnosticReportLimit] diagnostic entries, newest first.
String diagnosticReport(
  List<LoggedEvent> diagnostics, {
  required String build,
  required DateTime now,
  String? lastCrash,
}) {
  final out = StringBuffer()
    ..writeln('Writing Recogniser diagnostic report')
    ..writeln('Build: ${buildNumberOnly(build)}')
    ..writeln('Made: ${now.toUtc().toIso8601String()} (UTC)')
    ..writeln(
      'Contains sizes, counts, timings and error messages only: no '
      'document names, words or handwriting.',
    )
    ..writeln();
  if (lastCrash != null && lastCrash.trim().isNotEmpty) {
    out
      ..writeln('== Last crash ==')
      ..writeln(lastCrash.trim())
      ..writeln();
  }
  final newest = diagnostics.reversed.take(diagnosticReportLimit).toList();
  out.writeln('== ${newest.length} most recent entries, newest first ==');
  for (final e in newest) {
    final data = Map<String, Object?>.of(e.data);
    final area = data.remove('area') ?? '?';
    final steps = data.remove('steps');
    out.writeln(
      '${e.at.toUtc().toIso8601String()}  $area  ${jsonEncode(data)}',
    );
    if (steps is List) {
      for (final s in steps) {
        out.writeln('    $s');
      }
    }
  }
  return out.toString();
}
