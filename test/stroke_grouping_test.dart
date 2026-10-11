import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';

/// A letter-like stroke: 6 pt wide, [h] tall, bottom-left at (x, y).
PageStroke letter(double x, double y, int t, {double h = 10}) => PageStroke(
  points: [
    PageInkPoint(x, y, t),
    PageInkPoint(x + 3, y + h, t + 40),
    PageInkPoint(x + 6, y, t + 80),
  ],
);

/// [n] letters 7 pt apart starting at x, written one after another.
List<PageStroke> word(double x, double y, int n, int t) => [
  for (var i = 0; i < n; i++) letter(x + i * 7, y, t + i * 200),
];

void main() {
  test('two lines of two words, top line first, words left to right', () {
    final strokes = [
      ...word(100, 700, 3, 0), // top line, first word
      ...word(135, 700, 2, 1000), // gap of 14 pt (> 0.6 x 10)
      ...word(100, 670, 4, 2000), // next line down
      ...word(145, 670, 1, 3000),
    ];
    final lines = groupStrokes(strokes);
    expect(lines, hasLength(2));
    expect(
      [for (final w in lines[0].words) w.strokes],
      [
        [0, 1, 2],
        [3, 4],
      ],
    );
    expect(
      [for (final w in lines[1].words) w.strokes],
      [
        [5, 6, 7, 8],
        [9],
      ],
    );
  });

  test('letters close together stay one word', () {
    final lines = groupStrokes(word(100, 700, 6, 0));
    expect(lines.single.words.single.strokes, [0, 1, 2, 3, 4, 5]);
  });

  test('coming back much later to dot an i joins the word it touches', () {
    final strokes = [
      ...word(100, 700, 3, 0),
      // A dot above the second letter, two minutes later.
      PageStroke(
        points: const [
          PageInkPoint(110, 711, 120000),
          PageInkPoint(110.5, 711, 120010),
        ],
      ),
    ];
    final words = groupStrokes(strokes).single.words;
    expect(words.single.strokes, [0, 1, 2, 3]);
  });

  test('a separate word written much later nearby starts a new word', () {
    final strokes = [
      ...word(100, 700, 3, 0),
      ...word(124, 700, 2, 200000), // 4 pt gap, but minutes later
    ];
    expect(groupStrokes(strokes).single.words, hasLength(2));
  });

  test('a note far to the side at the same height is its own line', () {
    final strokes = [...word(50, 700, 3, 0), ...word(450, 700, 3, 1000)];
    expect(groupStrokes(strokes), hasLength(2));
  });

  test('highlighter strokes and arrows are not handwriting', () {
    final strokes = [
      ...word(100, 700, 2, 0),
      const PageStroke(
        tool: InkTool.highlighter,
        points: [PageInkPoint(90, 702, 5000), PageInkPoint(200, 702, 5100)],
      ),
      const PageStroke(
        arrow: true,
        points: [PageInkPoint(100, 650, 6000), PageInkPoint(200, 650, 6100)],
      ),
    ];
    final lines = groupStrokes(strokes);
    expect(lines.single.words.single.strokes, [0, 1]);
    expect(groupStrokes(const []), isEmpty);
  });

  test('a word written right to left keeps writing order of its strokes', () {
    final strokes = [
      letter(114, 700, 0),
      letter(107, 700, 200),
      letter(100, 700, 400),
    ];
    expect(groupStrokes(strokes).single.words.single.strokes, [0, 1, 2]);
  });

  test('letter height ignores dots', () {
    final boxes = [
      for (var i = 0; i < 5; i++) const InkBox(0, 0, 6, 10),
      for (var i = 0; i < 4; i++) const InkBox(0, 0, 0.5, 0.5),
    ];
    expect(typicalLetterHeight(boxes), 10);
    expect(typicalLetterHeight(const []), 4);
  });

  test('word ink is flipped the right way up for the engines', () {
    final strokes = word(100, 700, 1, 0);
    final w = groupStrokes(strokes).single.words.single;
    final ink = wordInk(strokes, w).single.points;
    expect([ink[0].x, ink[0].y], [0, 10]); // bottom-left -> y down
    expect([ink[1].x, ink[1].y], [3, 0]); // top of the letter -> y 0
    expect(ink[1].t, 40);
  });
}
