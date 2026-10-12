import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/feedback/feedback_layer.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/core/replay.dart';
import 'package:writing_recogniser/core/replay_cases.dart';
import 'package:writing_recogniser/settings/replay_screen.dart';

/// A word-sized squiggle at [x] on a writing box (y grows downward), its
/// points stamped from [t] so the fake engine can tell words apart.
InkStroke squiggle(double x, int t, {double y = 40}) => InkStroke([
  for (var i = 0; i < 10; i++)
    InkPoint(x + i * 4, y + (i.isEven ? 0 : 20), t + i * 10),
]);

/// Reads each word by its first point's time, as told by [words].
class FakeEngine implements Recognizer {
  FakeEngine(this.words, {this.ready = true});

  final Map<int, String> words;
  final bool ready;
  final contexts = <String>[];

  @override
  String get name => 'Fake';

  @override
  bool get onDevice => true;

  @override
  Future<RecognizerStatus> status() async => ready
      ? const RecognizerStatus(RecognizerState.ready)
      : const RecognizerStatus(RecognizerState.unavailable, 'No keys.');

  @override
  Future<void> prepare({void Function(double? progress)? onProgress}) async {}

  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    contexts.add(context.preContext);
    return [Candidate(words[strokes.first.points.first.t] ?? '?')];
  }
}

LabeledSample sample(String text, List<InkStroke> strokes, int day) =>
    LabeledSample(
      text: text,
      strokes: strokes,
      createdAt: DateTime.utc(2026, 10, day),
    );

void main() {
  group('wordsFromSamples', () {
    test('splits a sentence into its words, in reading order', () {
      final words = wordsFromSamples([
        // Written right to left, to check the order comes from position.
        sample('hello world', [squiggle(200, 2000), squiggle(20, 1000)], 1),
      ]);
      expect(words.samplesUsed, 1);
      expect(words.samplesSkipped, 0);
      expect(words.cases.map((c) => c.truth), ['hello', 'world']);
      expect(words.cases.map((c) => c.previousWord), ['', 'hello']);
      // The engine gets each word on its own, the right way up, near the
      // origin.
      final first = words.cases.first.strokes.single.points;
      expect(first.first.t, 1000);
      expect(first.first.x, 0);
      expect(first.first.y, 0, reason: 'top of the word');
      expect(first[1].y, 20, reason: 'y still grows downward');
    });

    test('leaves out sentences whose ink has a different word count', () {
      final words = wordsFromSamples([
        sample('one two three', [squiggle(20, 1000), squiggle(200, 2000)], 2),
        sample('ok', [squiggle(20, 3000)], 1),
      ]);
      expect(words.samplesUsed, 1);
      expect(words.samplesSkipped, 1);
      expect(words.cases.single.truth, 'ok');
    });

    test('oldest sentence first', () {
      final words = wordsFromSamples([
        sample('later', [squiggle(20, 2000)], 5),
        sample('first', [squiggle(20, 1000)], 1),
      ]);
      expect(words.cases.map((c) => c.truth), ['first', 'later']);
    });
  });

  group('replay', () {
    // "the" is always misread as "teh"; "cat" is read right.
    List<ReplayCase> cases() => wordsFromSamples([
      for (var i = 0; i < 3; i++)
        sample('the cat', [
          squiggle(20, 1000 + i * 10000),
          squiggle(200, 2000 + i * 10000),
        ], i + 1),
    ]).cases;
    FakeEngine engine() => FakeEngine({
      for (var i = 0; i < 3; i++) ...{
        1000 + i * 10000: 'teh',
        2000 + i * 10000: 'cat',
      },
    });

    test('learning from the first correction fixes the repeats', () async {
      final e = engine();
      final r = await replay(cases(), e, CorrectionMemory());
      expect(r.steps.map((s) => s.withFeedback), [
        'teh', 'cat', 'the', 'cat', 'the', 'cat', //
      ]);
      expect(r.wer(feedback: false), 0.5);
      expect(r.wer(feedback: true), closeTo(1 / 6, 1e-9));
      // Repeated words: "the" twice (engine wrong both times, fixed both
      // times) and "cat" twice.
      expect(r.repeatedImprovement, 1);
      expect(r.steps.where((s) => s.autoReplaced), hasLength(2));
      expect(e.contexts, ['', 'the', '', 'the', '', 'the']);
    });

    test('the engine alone learns nothing', () async {
      final r = await replay(cases(), engine(), const PassThroughFeedback());
      expect(r.repeatedImprovement, 0);
    });

    test('reports progress and stops when cancelled', () async {
      final progress = <int>[];
      var stop = false;
      final r = await replay(
        cases(),
        engine(),
        CorrectionMemory(),
        onProgress: (done, total) {
          progress.add(done);
          expect(total, 6);
          if (done == 3) stop = true;
        },
        cancelled: () => stop,
      );
      expect(progress, [1, 2, 3]);
      expect(r.steps, hasLength(3));
    });
  });

  group('ReplayScreen', () {
    Future<void> pump(WidgetTester tester, FakeEngine engine) async {
      // Tall enough to show every result row at once.
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ReplayScreen(
            engine: engine,
            loadSamples: () async => [
              for (var i = 0; i < 2; i++)
                sample('the cat', [
                  squiggle(20, 1000 + i * 10000),
                  squiggle(200, 2000 + i * 10000),
                ], i + 1),
              sample('too many words', [squiggle(20, 90000)], 9),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('runs the replay and shows both error rates', (tester) async {
      await pump(
        tester,
        FakeEngine({1000: 'teh', 2000: 'cat', 11000: 'teh', 12000: 'cat'}),
      );
      expect(find.textContaining('2 sentences, 4 words'), findsOneWidget);
      expect(find.textContaining('(1 sentence left out'), findsOneWidget);
      await tester.tap(find.text('Start replay'));
      await tester.pumpAndSettle();
      expect(find.text('4 words replayed'), findsOneWidget);
      expect(find.text('Engine on its own'), findsOneWidget);
      // The engine alone, and new words with learning (the first "the").
      expect(find.text('50%'), findsNWidgets(2));
      expect(find.text('25%'), findsOneWidget, reason: 'learning');
      expect(find.text('100%'), findsOneWidget, reason: 'GATE B measure');
      expect(find.text('Replay again'), findsOneWidget);
    });

    testWidgets('says so when the engine is not ready', (tester) async {
      await pump(tester, FakeEngine(const {}, ready: false));
      expect(find.textContaining("isn't ready: No keys."), findsOneWidget);
      expect(find.text('Start replay'), findsNothing);
    });
  });
}
