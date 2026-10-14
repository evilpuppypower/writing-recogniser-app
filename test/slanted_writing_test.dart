import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_export_plan.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_recognition.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/core/typed_text.dart';
import 'package:writing_recogniser/core/word_pairs.dart';
import 'package:writing_recogniser/core/writing_guide.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/page_text_labels.dart';

/// A level letter 6 pt wide, 10 tall, bottom-left at (x, y).
List<PageInkPoint> letter(double x, double y, int t) => [
  PageInkPoint(x, y, t),
  PageInkPoint(x + 3, y + 10, t + 40),
  PageInkPoint(x + 6, y, t + 80),
];

/// Two words ("3 letters", gap, "4 letters"), written at [degrees] from
/// level, turned about (100, 700).
List<PageStroke> sentence(double degrees, {String? typed}) {
  final a = degrees * math.pi / 180;
  final xs = [0, 7, 14, 32, 39, 46, 53];
  return [
    for (var i = 0; i < xs.length; i++)
      PageStroke(
        points: [
          for (final p in letter(100.0 + xs[i], 700, i * 200))
            levelPoint(p, -a, 100, 700),
        ],
        typedGroup: typed == null ? null : '$typed${i < 3 ? 1 : 2}',
        typedText: typed != null && (i == 0 || i == 3)
            ? (i == 0 ? 'the' : 'bird')
            : null,
      ),
  ];
}

double degreesOf(double radians) => radians * 180 / math.pi;

void main() {
  test('writing at 25 degrees is one line of two words, at that slant', () {
    final strokes = sentence(25);
    final lines = groupStrokes(strokes);
    expect(lines, hasLength(1));
    expect(degreesOf(lines.single.angle), closeTo(25, 1));
    expect(
      [for (final w in lines.single.words) w.strokes],
      [
        [0, 1, 2],
        [3, 4, 5, 6],
      ],
    );
    // On the page, the word's box is where the slanted ink is.
    final first = lines.single.words.first;
    expect(first.box.height, greaterThan(12));
    // The engine gets it level: about one letter high.
    final ink = wordInk(strokes, first);
    final ys = [
      for (final s in ink)
        for (final p in s.points) p.y,
    ];
    expect(ys.reduce(math.max) - ys.reduce(math.min), closeTo(10, 0.5));
  });

  test('writing going down to the right works too', () {
    final lines = groupStrokes(sentence(-20));
    expect(lines, hasLength(1));
    expect(degreesOf(lines.single.angle), closeTo(-20, 1));
    expect(lines.single.words, hasLength(2));
  });

  test('writing within 10 degrees of level is treated as level', () {
    final lines = groupStrokes(sentence(5));
    expect(lines, hasLength(1));
    expect(lines.single.angle, 0);
    expect(lines.single.words.first.slant, isNull);
  });

  test('the guide runs along a slanted line', () {
    final strokes = sentence(25);
    final g = guideFor(strokes, strokes.last.id)!;
    final (start, end) = ends(g);
    final slope = (end.y - start.y) / (end.x - start.x);
    expect(degreesOf(math.atan(slope)), closeTo(25, 1));
    // Carrying on along the slant brings it back; level to the right doesn't.
    final on = levelPoint(PageInkPoint(170, 705, 0), -g.angle, 100, 700);
    expect(nearLineEnd(g, on.x, on.y), isTrue);
    expect(nearLineEnd(g, 170, 705), isFalse);
  });

  test('at 45 degrees, typed text follows the line', () {
    final lines = typedLines(sentence(45, typed: 'g'));
    expect(lines, hasLength(1));
    final line = lines.single;
    expect(line.text, 'the bird');
    expect(degreesOf(line.slant!.angle), closeTo(45, 1));
    // Fitted to the line turned level (one letter high), not to its
    // much taller box on the page.
    expect(line.slant!.box.height, closeTo(10, 0.5));
    expect(line.box.height, greaterThan(30));
    final export = typedForExport(
      sentence(45, typed: 'g'),
      ExportHandwriting.typed,
    ).single;
    expect(degreesOf(export.angle), closeTo(45, 1));
    final back = ExportWord.fromMessage(export.toMessage());
    expect(back.angle, export.angle);
    expect(back.cx, export.cx);
  });

  test('a text matrix turned to the slant', () {
    const level = (a: 2.0, b: 0.0, c: 0.0, d: 2.0, e: 110.0, f: 700.0);
    final m = atSlant(level, math.pi / 2, 100, 700);
    // Turned a quarter anticlockwise about (100, 700): right becomes up.
    expect(m.a, closeTo(0, 1e-9));
    expect(m.b, closeTo(2, 1e-9));
    expect(m.c, closeTo(-2, 1e-9));
    expect(m.e, closeTo(100, 1e-9));
    expect(m.f, closeTo(710, 1e-9));
    expect(atSlant(level, 0, 100, 700), level);
  });

  test('a word at a slant keeps its slant when saved', () {
    final w = RecognizedWord(
      text: 'bird',
      alternatives: const [],
      box: const InkBox(80, 600, 160, 680),
      line: 0,
      slant: (
        angle: 0.7,
        cx: 100,
        cy: 640,
        box: const InkBox(90, 630, 150, 642),
      ),
    );
    final back = RecognizedWord.fromJson(w.toJson());
    expect(back.slant!.angle, 0.7);
    expect(back.slant!.box.top, 642);
    expect(
      RecognizedWord.fromJson({...w.toJson()..remove('slant')}).slant,
      isNull,
    );
  });

  test("a slanted word's label is along the slant, and takes taps there", () {
    final geometry = PageGeometry(width: 612, height: 792);
    final w = RecognizedWord(
      text: 'hello',
      alternatives: const [],
      box: const InkBox(80, 600, 170, 700),
      line: 0,
      slant: (
        angle: math.pi / 4,
        cx: 100,
        cy: 600,
        box: const InkBox(100, 600, 200, 620),
      ),
    );
    RecognizedWord? at(Offset p) => PageTextLabels.wordAtLabel(
      [w],
      p,
      geometry: geometry,
      viewWidth: 612,
      above: true,
    );
    // The label's corner: the level word's top-left, turned back, on
    // screen (y down); a point 20 px along the label and a little in.
    final c = levelPoint(
      const PageInkPoint(100, 620, 0),
      -math.pi / 4,
      100,
      600,
    );
    final corner = Offset(c.x, 792 - c.y);
    const r = math.sqrt1_2;
    Offset local(double x, double y) =>
        corner + Offset(x * r + y * r, -x * r + y * r);
    expect(at(local(20, -8)), same(w));
    // Where a level label would be, there's nothing.
    expect(at(const Offset(150, 75)), isNull);
  });

  test('level writing with tall letters and tails stays level', () {
    // "the gap pull": tall t, h, l, l; tails on g, p, p (5 pt below).
    PageStroke at(double x, double bottom, double h, int t) => PageStroke(
      points: [
        PageInkPoint(x, bottom, t),
        PageInkPoint(x + 3, bottom + h, t + 40),
        PageInkPoint(x + 6, bottom, t + 80),
      ],
    );
    final letters = [
      (0.0, 700.0, 15.0), (7.0, 700.0, 15.0), (14.0, 700.0, 10.0), // the
      (32.0, 695.0, 15.0), (39.0, 700.0, 10.0), (46.0, 695.0, 15.0), // gap
      (64.0, 695.0, 15.0), (71.0, 700.0, 10.0), // pu
      (78.0, 700.0, 15.0), (85.0, 700.0, 15.0), // ll
    ];
    final strokes = [
      for (var i = 0; i < letters.length; i++)
        at(100 + letters[i].$1, letters[i].$2, letters[i].$3, i * 200),
    ];
    final lines = groupStrokes(strokes);
    expect(lines, hasLength(1));
    expect(lines.single.angle, 0);
    // And the same with only the tall end: "small".
    final small = [
      for (final (i, h) in [10.0, 10.0, 10.0, 15.0, 15.0].indexed)
        at(100 + i * 7.0, 700, h, i * 200),
    ];
    expect(groupStrokes(small).single.angle, 0);
  });

  /// Level letters at [xs] (and an optional [extra] stroke), all turned
  /// [degrees] about (100, 700); letter i written at t = t0 + i * 200.
  List<PageStroke> turned(
    double degrees,
    List<double> xs, {
    int t0 = 0,
    String? mark,
  }) {
    final a = degrees * math.pi / 180;
    return [
      for (var i = 0; i < xs.length; i++)
        PageStroke(
          points: [
            for (final p in letter(100 + xs[i], 700, t0 + i * 200))
              levelPoint(p, -a, 100, 700),
          ],
          manualWord: mark,
        ),
    ];
  }

  List<double> spaced(int n, [double from = 0]) => [
    for (var i = 0; i < n; i++) from + i * 7,
  ];

  test('a dot added after a slanted word joins it', () {
    final a = 30 * math.pi / 180;
    final word = turned(30, spaced(8));
    // The dot of an i over the third letter, a little later.
    final dot = PageStroke(
      points: [
        for (final p in [
          const PageInkPoint(117, 714, 2000),
          const PageInkPoint(118, 714.5, 2010),
        ])
          levelPoint(p, -a, 100, 700),
      ],
    );
    final lines = groupStrokes([...word, dot]);
    expect(lines, hasLength(1));
    expect(lines.single.words.single.strokes, contains(8));
  });

  test('carrying on a slanted line after a pause stays on it', () {
    final first = turned(30, spaced(8));
    final later = turned(30, spaced(3, 70), t0: 20000);
    final lines = groupStrokes([...first, ...later]);
    expect(lines, hasLength(1));
    expect(degreesOf(lines.single.angle), closeTo(30, 2));
    expect(lines.single.words, hasLength(2));
  });

  test(
    'a level word followed straight away by slanted writing stays level',
    () {
      final level = [
        for (var i = 0; i < 4; i++)
          PageStroke(points: letter(40.0 + i * 7, 700, i * 200)),
      ];
      // Starts right after the level word (turned about its end).
      final a = 30 * math.pi / 180;
      final slanted = [
        for (var i = 0; i < 8; i++)
          PageStroke(
            points: [
              for (final p in letter(76.0 + i * 7, 700, 800 + i * 200))
                levelPoint(p, -a, 76, 700),
            ],
          ),
      ];
      final lines = groupStrokes([...level, ...slanted]);
      final levelLine = lines.firstWhere(
        (l) => l.words.any((w) => w.strokes.contains(0)),
      );
      expect(levelLine.angle, 0);
      final slantLine = lines.firstWhere(
        (l) => l.words.any((w) => w.strokes.contains(6)),
      );
      expect(degreesOf(slantLine.angle), closeTo(30, 2));
    },
  );

  test('a word read before its slant was noticed can be read again', () {
    final strokes = turned(30, [0, 7, 14, 32, 39, 46, 53]);
    final first = groupStrokes(strokes).single.words.first;
    final key = wordKey(strokes, first);
    final plan = planRecognition(strokes, {
      key: 'tbe',
    }, reread: (k, w) => k == key && w.slant != null);
    expect(plan.jobs.map((j) => j.key), contains(key));
    expect(
      planRecognition(strokes, {key: 'the'}).jobs.map((j) => j.key),
      isNot(contains(key)),
    );
  });

  test('training numbers for a slanted line are measured level', () {
    // One marked word, then a gap of 2 letter heights, at 45 degrees.
    final strokes = [
      ...turned(45, spaced(4), mark: 'm'),
      ...turned(45, spaced(3, 47), t0: 1000),
    ];
    final pairs = wordPairs(strokes);
    final edge = pairs.firstWhere((p) => !p.sameWord);
    final gap = edge.features[wordPairFeatures.indexOf('gap')];
    expect(gap, closeTo(2, 0.3));
  });
}
