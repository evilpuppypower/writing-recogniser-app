import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/evaluation.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/core/text_metrics.dart';

class TableEngine implements Recognizer {
  TableEngine(this.answers);
  final Map<String, String?> answers; // null = throw

  @override
  String get name => 'Table';
  @override
  bool get onDevice => true;
  @override
  Future<RecognizerStatus> status() async =>
      const RecognizerStatus(RecognizerState.ready);
  @override
  Future<void> prepare({void Function(double? p)? onProgress}) async {}

  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    final key = '${strokes.single.points.single.t}';
    final a = answers[key];
    if (a == null) throw const RecognitionException('boom');
    return [Candidate(a)];
  }
}

LabeledSample sample(int id, String text) => LabeledSample(
  id: id,
  text: text,
  strokes: [
    InkStroke([InkPoint(0, 0, id)]),
  ],
  createdAt: DateTime(2026),
);

void main() {
  group('editDistance', () {
    test('classic examples', () {
      List<String> c(String s) => s.split('');
      expect(editDistance(c('kitten'), c('sitting')), 3);
      expect(editDistance(c(''), c('abc')), 3);
      expect(editDistance(c('same'), c('same')), 0);
      expect(editDistance(['a', 'b'], ['b']), 1);
    });
  });

  group('TextErrors', () {
    test('strict counts case and punctuation; lenient ignores them', () {
      final strict = TextErrors.of(
        'Hello, world!',
        'hello world',
        Matching.strict,
      );
      final lenient = TextErrors.of(
        'Hello, world!',
        'hello world',
        Matching.lenient,
      );
      expect(strict.charEdits, 3); // H->h, comma, !
      expect(lenient.charEdits, 0);
      expect(lenient.exact, isTrue);
    });

    test('word and character error rates', () {
      final e = TextErrors.of('the cat sat', 'the hat sat', Matching.strict);
      expect(e.cer, closeTo(1 / 11, 1e-9));
      expect(e.wer, closeTo(1 / 3, 1e-9));
    });

    test('extra spaces are ignored even in strict mode', () {
      expect(TextErrors.of('a  b', ' a b ', Matching.strict).exact, isTrue);
    });
  });

  test('percentile (nearest rank)', () {
    expect(percentile([], 50), isNull);
    expect(percentile([5], 90), 5);
    expect(percentile([10, 20, 30, 40], 50), 20);
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), 9);
  });

  test('evaluate summarises accuracy, speed and failures', () async {
    final engine = TableEngine({
      '1': 'the cat sat', // exact
      '2': 'the hat sat', // 1 char, 1 word wrong
      '3': null, // fails
    });
    final progress = <int>[];
    final s = await evaluate(
      [sample(1, 'the cat sat'), sample(2, 'the cat sat'), sample(3, 'x')],
      engine,
      onProgress: (done, total) => progress.add(done),
    );
    expect(progress, [1, 2, 3]);
    expect(s.failures, 1);
    expect(s.cer(Matching.strict), closeTo(1 / 22, 1e-9));
    expect(s.wer(Matching.strict), closeTo(1 / 6, 1e-9));
    expect(s.exactRate(Matching.strict), 0.5);
    expect(s.worst(Matching.strict).single.sample.id, 2);
    expect(s.medianMs, isNotNull);
  });

  test('evaluate stops when cancelled', () async {
    var n = 0;
    final s = await evaluate(
      [sample(1, 'a'), sample(2, 'b'), sample(3, 'c')],
      TableEngine({'1': 'a', '2': 'b', '3': 'c'}),
      onProgress: (_, _) => n++,
      cancelled: () => n >= 2,
    );
    expect(s.results, hasLength(2));
  });
}
