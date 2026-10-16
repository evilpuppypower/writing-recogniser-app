import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/core/writing_profile.dart';
import 'package:writing_recogniser/settings/your_writing_screen.dart';

var _t = 1000000;

/// A line of [words] words with letters [h] high at height [y].
List<PageStroke> line(int words, double y, {double h = 10}) => [
  for (var w = 0; w < words; w++)
    for (var k = 0; k < 3; k++)
      PageStroke(
        points: [
          PageInkPoint(20.0 + w * 50 + k * 8, y, _t += 40),
          PageInkPoint(24.0 + w * 50 + k * 8, y + h, _t += 40),
          PageInkPoint(28.0 + w * 50 + k * 8, y, _t += 40),
        ],
      ),
];

void main() {
  test('learns the usual letter height, each line once', () {
    final p = WritingProfile();
    final strokes = [...line(4, 700), ...line(5, 650)];
    final lines = groupStrokes(strokes);
    final seen = <String>{};
    p.learnNew(strokes, lines, seen);
    expect(p.lines, 2);
    expect(p.letterHeight, closeTo(10, 1.5));
    expect(p.slantDegrees!.abs(), lessThan(3));
    // The same page read again doesn't count twice.
    p.learnNew(strokes, groupStrokes(strokes), seen);
    expect(p.lines, 2);
  });

  test('set by the user, then learning carries on from there', () {
    final p = WritingProfile()..set(letterHeight: 20, slantDegrees: 5);
    expect(p.letterHeight, 20);
    expect(p.setAt, isNot(0));
    final strokes = line(4, 700);
    p.learn(groupStrokes(strokes));
    // One line of 10-point writing moves it only a little.
    expect(p.letterHeight, lessThan(20));
    expect(p.letterHeight, greaterThan(18));
    final back = WritingProfile()..load(p.toJson());
    expect(back.letterHeight, p.letterHeight);
    expect(back.setAt, p.setAt);
    back.load('nonsense');
    expect(back.letterHeight, isNull);
  });

  test('a page with little writing uses the usual size', () {
    // Two small strokes 6 apart: a letter height measured from them
    // alone would split them; with the usual size they're one word.
    final strokes = [
      PageStroke(points: [PageInkPoint(10, 10, 1), PageInkPoint(12, 13, 2)]),
      PageStroke(points: [PageInkPoint(18, 10, 3), PageInkPoint(20, 13, 4)]),
    ];
    final usual = groupStrokes(
      strokes,
      params: const GroupingParams(usualLetter: 20),
    );
    expect(usual.single.words, hasLength(1));
    expect(groupStrokes(strokes).single.words, hasLength(2));
  });

  testWidgets('Your writing: shown, set and saved', (tester) async {
    WritingProfile? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: YourWritingScreen(
          load: () async => WritingProfile(),
          save: (p) async => saved = p,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Not learned yet'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?.letterHeight, closeTo(mmToPoints(4), 1e-9));
    expect(find.textContaining('Learning carries on'), findsWidgets);
  });
}
