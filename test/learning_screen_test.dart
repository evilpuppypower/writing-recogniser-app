import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/training_data.dart';
import 'package:writing_recogniser/settings/learning_screen.dart';

class _Log implements EventLog {
  _Log(this.events);
  final List<LoggedEvent> events;
  @override
  Future<void> log(LoggedEvent e) async => events.add(e);
  @override
  Future<List<LoggedEvent>> ofType(String type) async =>
      events.where((e) => e.type == type).toList();
}

LoggedEvent read(String word, DateTime at, String engine, String shown) =>
    LoggedEvent(
      type: 'recognition',
      at: at,
      latencyMs: 500,
      data: {
        'page': 1,
        'doc': 'd',
        'word': word,
        'engineText': engine,
        'text': shown,
        'autoReplaced': engine != shown,
      },
    );

void main() {
  Future<void> pump(
    WidgetTester tester,
    List<LoggedEvent> events, {
    List<(String, List<int>)>? saved,
    List<CorrectionRecord> corrections = const [],
  }) async {
    tester.view.physicalSize = const Size(1600, 3000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LearningScreen(
          openEventLog: () async => _Log(events),
          saveFile: (name, mime, bytes) async {
            saved?.add((name, bytes));
            return true;
          },
          loadTrainingData: () async =>
              (corrections, const <LabeledSample>[], const <SavedPageText>[]),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('says what to do when there is nothing yet', (tester) async {
    await pump(tester, []);
    expect(find.textContaining('Nothing yet'), findsOneWidget);
  });

  testWidgets('shows engine alone vs with corrections, and saves a CSV', (
    tester,
  ) async {
    final t = DateTime(2026, 1, 5, 12);
    final saved = <(String, List<int>)>[];
    await pump(tester, [
      read('a', t, 'mad', 'mad'),
      LoggedEvent(
        type: 'correction',
        at: t.add(const Duration(seconds: 5)),
        data: const {'page': 1, 'doc': 'd', 'word': 'a', 'corrected': 'moved'},
      ),
      read('b', t.add(const Duration(minutes: 1)), 'mad', 'moved'),
    ], saved: saved);
    expect(find.text('2 words read'), findsOneWidget);
    // Engine alone wrong on both; shown wrong only on the first.
    expect(find.text('100%'), findsWidgets);
    expect(find.text('50%'), findsWidgets);
    expect(find.text('Fewer fixes on words written before'), findsOneWidget);
    expect(find.text('Week of 5/1'), findsOneWidget);
    await tester.tap(find.byTooltip('Save every word as a spreadsheet (CSV)'));
    await tester.pumpAndSettle();
    expect(saved.single.$1, startsWith('Handwriting learning'));
    expect(utf8.decode(saved.single.$2), contains('mad,moved,moved'));
  });

  testWidgets('Save training data explains first, then saves a zip', (
    tester,
  ) async {
    final saved = <(String, List<int>)>[];
    await pump(
      tester,
      [],
      saved: saved,
      corrections: [
        CorrectionRecord(
          recognized: 'mad',
          corrected: 'moved',
          at: DateTime.utc(2026, 1, 5),
        ),
      ],
    );
    await tester.tap(
      find.byTooltip('Save training data (corrections and samples, with ink)'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('keep the file private'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pump(); // the question closes
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Gathering'), findsOneWidget);
    // The file is packed on a background isolate: let real time pass.
    for (var i = 0; i < 50 && saved.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('Gathering'), findsNothing);
    expect(saved.single.$1, startsWith('training-data-'));
    expect(find.textContaining('1 corrections, 0 samples'), findsOneWidget);
  });
}
