import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/feedback/feedback_layer.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/core/replay.dart';

CorrectionRecord fix(
  String from,
  String to, {
  String prev = '',
  String? doc,
  CorrectionScope scope = CorrectionScope.global,
}) => CorrectionRecord(
  recognized: from,
  corrected: to,
  previousWord: prev,
  at: DateTime(2026, 10, 11),
  documentId: doc,
  scope: scope,
);

List<String> texts(FeedbackResult r) => [for (final c in r.candidates) c.text];

void main() {
  const fox = [Candidate('for'), Candidate('fox'), Candidate('far')];

  group('CorrectionMemory', () {
    test('no corrections: the engine\'s order is kept', () {
      final m = CorrectionMemory();
      final r = m.apply(fox, const FeedbackContext());
      expect(texts(r), ['for', 'fox', 'far']);
      expect(r.autoReplaced, isFalse);
    });

    test('after one correction the user\'s word is preferred', () {
      final m = CorrectionMemory(autoReplaceAfter: 2)..learn(fix('for', 'fox'));
      final r = m.apply(fox, const FeedbackContext());
      expect(texts(r), ['fox', 'for', 'far']);
      expect(r.autoReplaced, isFalse);
    });

    test('a corrected word the engine did not offer becomes the first '
        'alternative', () {
      final m = CorrectionMemory(autoReplaceAfter: 2)..learn(fix('for', 'fax'));
      final r = m.apply(fox, const FeedbackContext());
      expect(texts(r), ['for', 'fax', 'fox', 'far']);
    });

    test('by default it is swapped the very next time (owner)', () {
      final m = CorrectionMemory()..learn(fix('for', 'fax'));
      final r = m.apply(fox, const FeedbackContext());
      expect(r.text, 'fax');
      expect(r.autoReplaced, isTrue);
    });

    test('set to two, it waits for the same correction twice', () {
      final m = CorrectionMemory(autoReplaceAfter: 2)
        ..learn(fix('for', 'fax'))
        ..learn(fix('For', 'fax'));
      final r = m.apply(fox, const FeedbackContext());
      expect(r.text, 'fax');
      expect(r.autoReplaced, isTrue);
    });

    test('a correction after the same previous word counts double there', () {
      final m = CorrectionMemory(autoReplaceAfter: 2)
        ..learn(fix('for', 'fax', prev: 'send'));
      expect(
        m.apply(fox, const FeedbackContext(previousWord: 'send')).autoReplaced,
        isTrue,
      );
      expect(
        m.apply(fox, const FeedbackContext(previousWord: 'wait')).autoReplaced,
        isFalse,
      );
    });

    test('a correction limited to one PDF applies only there', () {
      final m = CorrectionMemory(autoReplaceAfter: 2)
        ..learn(fix('for', 'fax', doc: 'a', scope: CorrectionScope.document));
      expect(
        m.apply(fox, const FeedbackContext(documentId: 'a')).candidates[1].text,
        'fax',
      );
      expect(texts(m.apply(fox, const FeedbackContext(documentId: 'b'))), [
        'for',
        'fox',
        'far',
      ]);
    });
  });

  group('replay', () {
    // An engine that always reads "for" whatever was written.
    final engine = _Always(['for', 'far']);
    List<ReplayCase> cases(List<String> truths) => [
      for (var i = 0; i < truths.length; i++)
        ReplayCase(
          strokes: [
            InkStroke([InkPoint(0, 0, i)]),
          ],
          truth: truths[i],
          at: DateTime(2026, 10, 11, 0, 0, i),
        ),
    ];

    test('engine only never improves; with feedback it learns', () async {
      final words = ['fox', 'fox', 'fox', 'fox'];
      final base = await replay(
        cases(words),
        engine,
        const PassThroughFeedback(),
      );
      expect(base.wer(feedback: false), 1);
      expect(base.wer(feedback: true), 1);

      final learnt = await replay(cases(words), engine, CorrectionMemory());
      // Corrected once, then swapped automatically from the 2nd time.
      expect(
        [for (final s in learnt.steps) s.withFeedback],
        ['for', 'fox', 'fox', 'fox'],
      );
      expect(learnt.wer(feedback: true), 0.25);
      expect(learnt.steps.last.autoReplaced, isTrue);

      // The original plan (swap after two corrections) needs one more.
      final slower = await replay(
        cases(words),
        engine,
        CorrectionMemory(autoReplaceAfter: 2),
      );
      expect(slower.wer(feedback: true), 0.5);
    });

    test('splits new words from repeated ones and tracks corrections over '
        'time', () async {
      final r = await replay(
        cases(['fox', 'dog', 'fox', 'fox']),
        engine,
        CorrectionMemory(autoReplaceAfter: 2),
      );
      expect(
        [for (final s in r.steps) s.seenBefore],
        [false, false, true, true],
      );
      expect(r.wer(feedback: true, repeated: false), 1); // new words
      expect(r.correctionsPer100(window: 2), [100, 50]);
    });
  });
}

class _Always implements Recognizer {
  _Always(this.words);
  final List<String> words;
  @override
  String get name => 'Always';
  @override
  bool get onDevice => true;
  @override
  Future<RecognizerStatus> status() async =>
      const RecognizerStatus(RecognizerState.ready);
  @override
  Future<void> prepare({void Function(double? progress)? onProgress}) async {}
  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async => [for (final w in words) Candidate(w)];
}
