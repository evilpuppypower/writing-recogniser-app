import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_classifier.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/personal_ink_kinds.dart';

/// A small wavy letter at [x], [y] (6 tall).
PageStroke letter(double x, double y) => PageStroke(
  points: [
    for (var i = 0; i < 12; i++)
      PageInkPoint(x + i * 0.4, y + 3 + 3 * math.sin(i / 2), i * 10),
  ],
);

/// A tick mark: down and up again, about two letters across (what the
/// shape check calls writing).
PageStroke tick(double x, double y, int t) => PageStroke(
  points: [
    PageInkPoint(x, y + 4, t),
    PageInkPoint(x + 3, y, t + 50),
    PageInkPoint(x + 10, y + 10, t + 100),
  ],
);

void main() {
  // A page of writing, with ticks in the margin.
  List<PageStroke> page(int ticks) => [
    for (var i = 0; i < 40; i++)
      letter(100.0 + (i % 20) * 6, 700.0 - (i ~/ 20) * 14),
    for (var k = 0; k < ticks; k++) tick(40, 700.0 - k * 14, 100000 + k * 1000),
  ];

  test(
    'ticks the user marked as not writing are sorted that way next time',
    () {
      final learn = PersonalInkKinds();
      final first = page(3);
      final ids = {for (final s in first.skip(40)) s.id};
      learn.learn(first, ids, InkKind.drawing);
      expect(learn.count, 3);

      // A new page: letters and two more ticks, all called writing at first.
      final next = page(2);
      final kinds = learn.apply(next, [for (final _ in next) InkKind.writing]);
      expect(kinds.skip(40), everyElement(InkKind.drawing));
      expect(kinds.take(40), everyElement(InkKind.writing));
    },
  );

  test('needs a few marks that agree, and "This is writing" teaches back', () {
    final learn = PersonalInkKinds();
    final p = page(3);
    final ticks = [for (final s in p.skip(40)) s.id];
    learn.learn(p, {ticks[0], ticks[1]}, InkKind.drawing);
    final writing = [for (final _ in p) InkKind.writing];
    expect(learn.apply(p, writing), writing, reason: 'only two marks yet');
    learn.learn(p, {ticks[2]}, InkKind.drawing);
    learn.learn(p, {ticks[0], ticks[1], ticks[2]}, InkKind.writing);
    // The newest marks say writing: they win.
    expect(learn.apply(p, writing), writing);
    final drawn = [for (final _ in p) InkKind.drawing];
    expect(learn.apply(p, drawn).skip(40), everyElement(InkKind.writing));
  });

  test('kept between sessions as numbers only', () {
    final learn = PersonalInkKinds();
    final p = page(3);
    learn.learn(p, {for (final s in p.skip(40)) s.id}, InkKind.drawing);
    final json = learn.toJson();
    expect(json.first, isA<List<Object?>>());
    expect((json.first as List).first, 'drawing');
    final back = PersonalInkKinds()..load(json);
    expect(back.count, 3);
  });
}
