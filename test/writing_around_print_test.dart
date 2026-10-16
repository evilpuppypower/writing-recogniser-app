import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/nearby_classifier.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/page_recognition.dart';
import 'package:writing_recogniser/core/printed_text.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';

var _t = 1000000;

/// A handwritten word of [letters] strokes, [h] high, starting at
/// ([x], [y]) (its foot), written now (each call writes later).
List<PageStroke> word(double x, double y, {double h = 5, int letters = 3}) {
  final out = <PageStroke>[];
  for (var s = 0; s < letters; s++) {
    out.add(
      PageStroke(
        points: [
          for (var i = 0; i < 12; i++)
            PageInkPoint(
              x + s * h * 0.8 + i * h * 0.05,
              y + h / 2 + h / 2 * math.sin(i / 2),
              _t += 5,
              0.5,
            ),
        ],
      ),
    );
    _t += 150;
  }
  _t += 300;
  return out;
}

/// A printed line of text: one box per character, 6 points apart.
List<InkBox> printedLine(double left, double right, double y, {double h = 8}) =>
    [for (var x = left; x + 5 <= right; x += 6) InkBox(x, y, x + 5, y + h)];

void main() {
  group('printed text', () {
    test('characters are joined into printed lines', () {
      final p = PrintedText([
        ...printedLine(100, 400, 700),
        ...printedLine(100, 400, 680),
      ]);
      expect(p.boxes, hasLength(2));
      expect(p.covered(150, 250, 700, 708), closeTo(100, 0.01));
      // A line just touching the band doesn't count.
      expect(p.covered(150, 250, 707, 720), 0);
      expect(p.within(const InkBox(0, 0, 50, 50)), isEmpty);
    });

    test('two margin notes at the same height stay two lines', () {
      // Big writing (letters 10 high) in both margins, 60 apart: close
      // enough to be one line without the printed column between.
      final left = word(10, 500, h: 10);
      _t += 120000; // written later
      final right = word(110, 500, h: 10);
      final strokes = [...left, ...right];
      expect(groupStrokes(strokes), hasLength(1));
      final printed = PrintedText(printedLine(45, 105, 500, h: 9));
      final lines = groupStrokes(strokes, printed: printed);
      expect(lines, hasLength(2));
    });

    test('a sentence written straight on past printed text is one line', () {
      // A printed box 150 wide (30 letters) in the way.
      final strokes = [
        ...word(10, 300),
        ...word(30, 300),
        ...word(200, 300),
        ...word(220, 300),
      ];
      expect(groupStrokes(strokes), hasLength(2));
      final printed = PrintedText([
        for (var y = 290.0; y < 320; y += 10) ...printedLine(44, 196, y, h: 8),
      ]);
      final lines = groupStrokes(strokes, printed: printed);
      expect(lines, hasLength(1));
      expect(lines.single.words, hasLength(4));
    });

    test('but not when it was written later', () {
      final strokes = [...word(10, 300), ...word(30, 300)];
      _t += 120000;
      strokes.addAll([...word(200, 300), ...word(220, 300)]);
      final printed = PrintedText(printedLine(44, 196, 300, h: 6));
      expect(groupStrokes(strokes, printed: printed), hasLength(2));
    });
  });

  test('a 10 second pause past printed text starts a new note', () {
    final strokes = [...word(10, 300), ...word(30, 300)];
    _t += 10000;
    strokes.addAll([...word(200, 300), ...word(220, 300)]);
    final printed = PrintedText(printedLine(44, 196, 300, h: 6));
    expect(groupStrokes(strokes, printed: printed), hasLength(2));
  });

  group('reading order', () {
    test('notes in two margins each follow on from their own column', () {
      // Left and right margin notes, written in turn, lines interleaved
      // in height.
      final strokes = <PageStroke>[];
      for (var l = 0; l < 3; l++) {
        strokes.addAll(word(10, 700 - l * 10.0));
        _t += 120000;
        strokes.addAll(word(500, 697 - l * 10.0));
        _t += 120000;
      }
      final printed = PrintedText([
        for (var y = 640.0; y < 720; y += 10) ...printedLine(60, 480, y),
      ]);
      final lines = groupStrokes(strokes, printed: printed);
      expect(lines, hasLength(6));
      final after = followsOn(lines, printed: printed);
      for (var l = 0; l < lines.length; l++) {
        final k = after[l];
        if (k == null) continue;
        // Same margin.
        expect(lines[k].box.left < 100, lines[l].box.left < 100);
      }
      expect(after.where((k) => k == null), hasLength(2));
    });

    test('a printed paragraph between two lines starts a new note', () {
      final strokes = [...word(100, 500), ...word(100, 490)];
      final lines = groupStrokes(strokes);
      expect(followsOn(lines)[1], 0);
      final printed = PrintedText(printedLine(90, 200, 496, h: 3));
      expect(followsOn(lines, printed: printed)[1], isNull);
    });

    test('the words just before come from the same column', () {
      final strokes = [...word(10, 700), ...word(500, 697), ...word(10, 690)];
      final first = planRecognition(strokes, const {});
      String keyAt(double x, double y) => first.jobs
          .firstWhere(
            (j) =>
                (j.word.box.left - x).abs() < 1 &&
                (j.word.box.bottom - y).abs() < 1,
          )
          .key;
      final known = {keyAt(10, 700): 'left', keyAt(500, 697): 'right'};
      final plan = planRecognition(strokes, known);
      final job = plan.jobs.single;
      expect(job.word.box.left, lessThan(100));
      expect(job.preContext, 'left');
    });
  });

  group('reading order, more', () {
    test('small writing on widely spaced lines keeps its context', () {
      // Letters 6 high on lines 28 apart (about 1 cm).
      final strokes = [
        for (var l = 0; l < 4; l++) ...word(100, 700 - l * 28.0, h: 6),
      ];
      final lines = groupStrokes(strokes);
      expect(lines, hasLength(4));
      expect(followsOn(lines), [null, 0, 1, 2]);
    });

    test('lines written at a slant follow on from each other', () {
      // Three parallel lines at 30 degrees, about 360 long, 25 apart
      // (letters 10 high).
      const angle = math.pi / 6;
      final strokes = <PageStroke>[];
      var t = 5000000;
      for (var l = 0; l < 3; l++) {
        for (var w = 0; w < 8; w++) {
          for (var k = 0; k < 4; k++) {
            final x = 100.0 + w * 46 + k * 7, y = 700.0 - l * 25;
            strokes.add(
              PageStroke(
                points: [
                  for (final p in [
                    PageInkPoint(x, y, t),
                    PageInkPoint(x + 3, y + 10, t + 40),
                    PageInkPoint(x + 6, y, t + 80),
                  ])
                    levelPoint(p, -angle, 100, 700),
                ],
              ),
            );
            t += 200;
          }
        }
      }
      final lines = groupStrokes(strokes);
      expect(lines, hasLength(3));
      expect(lines.every((l) => l.angle > 0.4), isTrue);
      expect(followsOn(lines), [null, 0, 1]);
    });
  });

  test('many margin notes beside a full printed page group quickly', () {
    // 200 short notes down the left margin, then a line in the right
    // margin, on a page of printed text.
    final strokes = <PageStroke>[];
    for (var n = 0; n < 200; n++) {
      strokes.addAll(word(5, 780 - n * 3.8, h: 3));
      _t += 120000;
    }
    for (var w = 0; w < 20; w++) {
      strokes.addAll(word(560 + w * 1.0, 400, h: 3, letters: 1));
    }
    final printed = PrintedText([
      for (var l = 0; l < 60; l++)
        for (var ch = 0; ch < 85; ch++)
          InkBox(
            40.0 + ch * 6,
            30.0 + l * 12.5,
            45.0 + ch * 6,
            38.0 + l * 12.5,
          ),
    ]);
    groupStrokes(strokes, printed: printed);
    final sw = Stopwatch()..start();
    groupStrokes(strokes, printed: printed);
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  group('sorting writing from drawing near new strokes', () {
    test('a new word sends its whole line, however long', () {
      final strokes = [
        for (var w = 0; w < 30; w++) ...word(10 + w * 18.0, 500),
      ];
      final fresh = [strokes.length - 1];
      final sent = NearbyClassifier.nearby(strokes, fresh);
      expect(sent, hasLength(strokes.length));
    });

    test('the border is the size of the writing\'s own letters', () {
      // Small margin writing (4 high) next to big writing (20 high).
      final tiny = [
        for (var w = 0; w < 4; w++) ...word(10 + w * 14.0, 400, h: 4),
      ];
      final bigNear = word(10, 360, h: 20); // 20 below the small line
      final big = [
        for (var w = 0; w < 6; w++) ...word(200 + w * 50.0, 300, h: 20),
      ];
      final bigAbove = word(450, 340, h: 20); // 20 above the big line
      final strokes = [...tiny, ...bigNear, ...big, ...bigAbove];
      // A new small stroke: its border is 3 small letters (12), so the
      // big word 20 below isn't sent.
      final tinyFresh = strokes.indexOf(tiny.last);
      final sentTiny = NearbyClassifier.nearby(strokes, [tinyFresh]);
      expect(sentTiny.any((i) => bigNear.contains(strokes[i])), isFalse);
      // A new big stroke: its border is 3 big letters (60), so the big
      // word just above is sent.
      final bigFresh = strokes.indexOf(big.last);
      final sentBig = NearbyClassifier.nearby(strokes, [bigFresh]);
      expect(sentBig.any((i) => bigAbove.contains(strokes[i])), isTrue);
    });

    test('new strokes far apart don\'t send the page between', () {
      final strokes = [
        for (var l = 0; l < 20; l++) ...word(10, 700 - l * 30.0),
      ];
      final sent = NearbyClassifier.nearby(strokes, [0, strokes.length - 1]);
      expect(sent.length, lessThan(strokes.length ~/ 4));
    });
  });
}
