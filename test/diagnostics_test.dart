import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/diagnostics_report.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/core/frame_summary.dart';

void main() {
  test('frame summaries: counts, slow frames, typical and worst', () {
    expect(summariseFrames(const []), isNull);
    final s = summariseFrames([
      for (var i = 0; i < 9; i++) (buildMs: 4.0, rasterMs: 6.0),
      (buildMs: 30.0, rasterMs: 12.0),
    ])!;
    expect(s['frames'], 10);
    expect(s['slow'], 1);
    expect(s['medianMs'], 6.0);
    expect(s['worstMs'], 30.0);
    expect(s['worstBuildMs'], 30.0);
    expect(s['worstDrawMs'], 12.0);
  });

  test('the report: build number only, UTC, newest first, with steps', () {
    final text = diagnosticReport(
      [
        LoggedEvent(
          type: 'diagnostic',
          at: DateTime.utc(2026, 1, 2, 3),
          data: {'area': 'frames', 'frames': 120, 'slow': 3},
        ),
        LoggedEvent(
          type: 'diagnostic',
          at: DateTime.utc(2026, 1, 2, 4),
          data: {
            'area': 'export',
            'result': 'failed',
            'steps': ['0 ms: opened: 12 pages', '9 ms: save (flags 0) failed'],
          },
        ),
      ],
      build: '41 · 2026-01-02 15:04',
      now: DateTime.utc(2026, 1, 2, 5),
      lastCrash: 'Boom at line 3',
    );
    expect(text, contains('Build: 41\n'));
    expect(text, isNot(contains('15:04')), reason: 'local time left out');
    expect(text, contains('Made: 2026-01-02T05:00:00.000Z'));
    expect(text, contains('Boom at line 3'));
    expect(
      text.indexOf('export'),
      lessThan(text.indexOf('frames')),
      reason: 'newest first',
    );
    expect(text, contains('    9 ms: save (flags 0) failed'));
    expect(
      diagnosticReportFileName(DateTime.utc(2026, 1, 2, 5, 7)),
      'diagnostics-20260102-0507.txt',
    );
  });
}
