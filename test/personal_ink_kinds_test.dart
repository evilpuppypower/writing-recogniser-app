import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_classifier.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/personal_ink_kinds.dart';

/// A small wavy letter at [x], [y] (6 tall), written at [t].
PageStroke letter(double x, double y, int t) => PageStroke(
  points: [
    for (var i = 0; i < 12; i++)
      PageInkPoint(x + i * 0.4, y + 3 + 3 * math.sin(i / 2), t + i * 10),
  ],
);

/// A tick mark: down and up again, about two letters across (what the
/// shape check calls writing).
PageStroke tick(double x, double y, int t, {bool arrow = false}) => PageStroke(
  points: [
    PageInkPoint(x, y + 4, t),
    PageInkPoint(x + 3, y, t + 50),
    PageInkPoint(x + 10, y + 10, t + 100),
  ],
  arrow: arrow,
);

/// A big circle, 60 across.
PageStroke circle(double cx, double cy, int t) => PageStroke(
  points: [
    for (var i = 0; i <= 40; i++)
      PageInkPoint(
        cx + 30 * math.cos(2 * math.pi * i / 40),
        cy + 30 * math.sin(2 * math.pi * i / 40),
        t + i * 10,
      ),
  ],
);

/// A page of writing (40 letters), with [ticks] ticks in the margin;
/// [seed] keeps stroke ids apart between pages.
List<PageStroke> page(int ticks, {int seed = 0}) => [
  for (var i = 0; i < 40; i++)
    letter(100.0 + (i % 20) * 6, 700.0 - (i ~/ 20) * 14, seed + i * 300),
  for (var k = 0; k < ticks; k++)
    tick(40, 700.0 - k * 14, seed + 100000 + k * 1000),
];

void main() {
  /// Marks one tick as not writing on each of [n] pages (n separate marks).
  void markTicks(PersonalInkKinds learn, int n, InkKind kind) {
    for (var m = 0; m < n; m++) {
      final p = page(1, seed: m * 1000000);
      learn.learn(p, {p.last.id}, kind);
    }
  }

  test('ticks marked as not writing 3 times are sorted that way next time', () {
    final learn = PersonalInkKinds();
    markTicks(learn, 3, InkKind.drawing);
    expect(learn.count, 3);
    final next = page(2, seed: 9000000);
    final kinds = learn.apply(next, [for (final _ in next) InkKind.writing]);
    expect(kinds.skip(40), everyElement(InkKind.drawing));
    expect(kinds.take(40), everyElement(InkKind.writing));
  });

  test('one mark of several strokes is not enough on its own', () {
    final learn = PersonalInkKinds();
    final p = page(3);
    learn.learn(p, {for (final s in p.skip(40)) s.id}, InkKind.drawing);
    final writing = [for (final _ in p) InkKind.writing];
    expect(learn.apply(p, writing), writing);
  });

  test('the newest marks win when the user changes their mind', () {
    final learn = PersonalInkKinds();
    markTicks(learn, 3, InkKind.drawing);
    markTicks(learn, 3, InkKind.writing);
    final p = page(2, seed: 9000000);
    // The letters read as writing, the ticks as drawings at first.
    final first = [
      for (var i = 0; i < p.length; i++)
        i < 40 ? InkKind.writing : InkKind.drawing,
    ];
    expect(learn.apply(p, first).skip(40), everyElement(InkKind.writing));
  });

  test(
    'circles marked on nearly empty pages never turn letters into drawings',
    () {
      final learn = PersonalInkKinds();
      for (var m = 0; m < 3; m++) {
        final sketch = [
          circle(300, 400, m * 100000),
          letter(100, 700, m * 100000 + 5000),
        ];
        learn.learn(sketch, {sketch.first.id}, InkKind.drawing);
      }
      // Not measured: too little writing round them.
      expect(learn.count, 0);
      final os = page(0);
      final writing = [for (final _ in os) InkKind.writing];
      expect(learn.apply(os, writing), writing);
    },
  );

  test('arrows teach nothing', () {
    final learn = PersonalInkKinds();
    for (var m = 0; m < 3; m++) {
      final p = [
        ...page(0, seed: m * 1000000),
        tick(40, 700, m * 1000000 + 99999, arrow: true),
      ];
      learn.learn(p, {p.last.id}, InkKind.drawing);
    }
    expect(learn.count, 0);
  });

  test('kept between sessions as numbers only', () {
    final learn = PersonalInkKinds();
    markTicks(learn, 3, InkKind.drawing);
    final json = learn.toJson();
    expect((json.first as List).first, 'drawing');
    final back = PersonalInkKinds()..load(json);
    expect(back.count, 3);
    final next = page(1, seed: 9000000);
    expect(
      back.apply(next, [for (final _ in next) InkKind.writing]).last,
      InkKind.drawing,
    );
  });
}
