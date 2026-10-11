import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/core/sample_store.dart';
import 'package:writing_recogniser/handwriting/gate_a_report_screen.dart';

class Store implements SampleStore {
  Store(this.samples);
  final List<LabeledSample> samples;
  @override
  Future<int> add(LabeledSample s) async => 0;
  @override
  Future<List<LabeledSample>> all() async => samples;
  @override
  Future<int> count() async => samples.length;
  @override
  Future<void> delete(int id) async {}
}

class Log implements EventLog {
  Log(this.events);
  final List<LoggedEvent> events;
  @override
  Future<void> log(LoggedEvent e) async => events.add(e);
  @override
  Future<List<LoggedEvent>> ofType(String t) async =>
      events.where((e) => e.type == t).toList();
}

class Engine implements Recognizer {
  Engine(this.name, this.answer, {this.ready = true, this.cloud = false});
  @override
  final String name;
  final String answer;
  final bool ready, cloud;
  @override
  bool get onDevice => !cloud;
  @override
  Future<RecognizerStatus> status() async => ready
      ? const RecognizerStatus(RecognizerState.ready)
      : const RecognizerStatus(RecognizerState.needsSetup, 'Needs keys');
  @override
  Future<void> prepare({void Function(double? p)? onProgress}) async {}
  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> s,
    RecognitionContext c,
  ) async => [Candidate(answer)];
}

LabeledSample sample(String text) => LabeledSample(
  text: text,
  strokes: const [
    InkStroke([InkPoint(0, 0, 0)]),
  ],
  createdAt: DateTime(2026),
);

void main() {
  testWidgets('runs an engine on the samples, reports, and copies', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 2560);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    final log = Log([
      LoggedEvent(
        type: 'recognition',
        at: DateTime(2026),
        engine: 'Alpha',
        latencyMs: 900,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: GateAReportScreen(
          samples: Store([sample('the cat'), sample('the dog')]),
          eventLog: log,
          engines: [
            Engine('Alpha', 'the cat'),
            Engine('Cloudy', 'x', ready: false, cloud: true),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('2 labelled samples'), findsOneWidget);
    expect(find.textContaining('Not ready: Needs keys'), findsOneWidget);
    expect(find.textContaining('MyScript monthly quota'), findsOneWidget);
    expect(find.textContaining('(1 times)'), findsOneWidget);

    await tester.tap(find.text('Run on 2 samples').first);
    await tester.pumpAndSettle();

    // "the cat" read perfectly; "the dog" read as "the cat": 3 of 14 chars.
    expect(find.text('50.0%'), findsWidgets); // perfect samples / word errors
    expect(find.text('Run again'), findsOneWidget);
    expect(log.events.where((e) => e.type == 'evaluation'), hasLength(1));

    await tester.tap(find.text('Copy report'));
    await tester.pumpAndSettle();
    expect(copied, contains('# GATE A report'));
    expect(copied, contains('## Alpha (on device)'));
    expect(copied, contains('"the dog" → "the cat"'));
    expect(copied, contains('## Cloudy (cloud)'));
    expect(copied, contains('Not run'));
    expect(copied, contains('## Writing position'));
    expect(copied, contains('## Per sample'));
    expect(copied, contains('1. "the cat"'));
    expect(copied, contains('- Alpha: "the cat" · perfect'));
    expect(copied, contains('- Alpha: "the cat" · 3 character errors'));
  });
}
