import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/page_recognition.dart';

PageStroke letter(double x, double y, int t) => PageStroke(
  points: [
    PageInkPoint(x, y, t),
    PageInkPoint(x + 3, y + 10, t + 40),
    PageInkPoint(x + 6, y, t + 80),
  ],
);

List<PageStroke> word(double x, double y, int n, int t) => [
  for (var i = 0; i < n; i++) letter(x + i * 7, y, t + i * 200),
];

void main() {
  final page = [
    ...word(100, 700, 3, 0),
    ...word(135, 700, 2, 1000),
    ...word(100, 670, 2, 2000),
  ];

  test('everything is new at first, with no context', () {
    final plan = planRecognition(page, const {});
    expect(plan.jobs, hasLength(3));
    expect(plan.jobs.map((j) => j.line), [0, 0, 1]);
    expect(plan.jobs.every((j) => j.preContext.isEmpty), isTrue);
    expect(plan.keys, hasLength(3));
  });

  test(
    'only new or changed words are planned, with earlier text as context',
    () {
      final first = planRecognition(page, const {});
      final known = {first.jobs[0].key: 'the', first.jobs[1].key: 'fox'};
      // Add a letter to the last word.
      final more = [...page, letter(114, 670, 9000)];
      final plan = planRecognition(more, known);
      expect(plan.jobs, hasLength(1));
      expect(plan.jobs.single.line, 1);
      expect(plan.jobs.single.preContext, 'the fox');
      expect(plan.jobs.single.word.strokes, [5, 6, 7]);
    },
  );

  test('erasing a stroke makes its word new again', () {
    final first = planRecognition(page, const {});
    final known = {for (final j in first.jobs) j.key: 'w'};
    final erased = [...page]..removeAt(2); // last letter of "the"
    final plan = planRecognition(erased, known);
    expect(plan.jobs, hasLength(1));
    expect(plan.jobs.single.line, 0);
    expect(plan.keys.length, 3);
  });

  test('context is cut to the last characters', () {
    final first = planRecognition(page, const {});
    final known = {first.jobs[0].key: 'a' * 30, first.jobs[1].key: 'b' * 30};
    final plan = planRecognition(page, known);
    expect(plan.jobs.single.preContext.length, preContextChars);
    expect(plan.jobs.single.preContext.endsWith('b' * 30), isTrue);
  });

  group('hidden ink (task 2.4d)', () {
    List<PageStroke> marked(List<PageStroke> strokes) => [
      for (final s in strokes) s.copyWith(notWriting: true),
    ];

    test('marked ink is grouped like words; the rest is ignored', () {
      final tick = marked(word(100, 700, 2, 0));
      final box = marked(word(300, 700, 3, 1000));
      final strokes = [...tick, ...word(160, 700, 3, 5000), ...box];
      final hidden = hiddenInk(strokes);
      expect(hidden, hasLength(2));
      expect(hidden.first.ids, {for (final s in tick) s.id});
      expect(hidden.last.ids, {for (final s in box) s.id});
    });

    test('finds the marked ink under a tap, allowing a little room', () {
      final tick = marked(word(100, 700, 2, 0));
      final strokes = [...tick, ...word(160, 700, 3, 5000)];
      expect(hiddenInkAt(strokes, 105, 705)?.ids, {for (final s in tick) s.id});
      expect(hiddenInkAt(strokes, 98, 715), isNotNull, reason: 'just outside');
      expect(hiddenInkAt(strokes, 165, 705), isNull, reason: 'normal writing');
      expect(hiddenInkAt(strokes, 100, 600), isNull, reason: 'empty space');
    });
  });
}
