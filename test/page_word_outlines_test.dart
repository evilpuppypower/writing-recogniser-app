import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/page_word_outlines.dart';

import 'ink_text_controller_test.dart' show FakeEngine, word;

void main() {
  testWidgets('each word is outlined round its strokes; a finger tap opens '
      'it, the pen goes through', (tester) async {
    final c = InkTextController(engine: FakeEngine());
    final strokes = [...word(100, 700, 3, 0), ...word(300, 700, 2, 10)];
    c.ensure(1, strokes);
    await tester.pump(const Duration(seconds: 2));
    final words = c.wordsOn(1);
    expect(words, hasLength(2));
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 306,
            height: 396,
            child: PageWordOutlines(
              pageNumber: 1,
              geometry: PageGeometry(width: 612, height: 792),
              viewWidth: 306,
              text: c,
              onTap: (w) => tapped.add(w.text),
            ),
          ),
        ),
      ),
    );
    final g = PageGeometry(width: 612, height: 792);
    final outlines = [
      for (final w in words) PageWordOutlines.outlineOf(w, g, 306),
    ];
    // Neighbouring words in different colours.
    expect(PageWordOutlines.colours[0], isNot(PageWordOutlines.colours[1]));
    // Round the word's ink, in the page's pixels (half a pixel a point).
    final b = words.first.box;
    expect(outlines.first.angle, 0);
    expect(
      outlines.first.centre.dx - outlines.first.size.width / 2,
      closeTo(b.left / 2 - 3, 0.01),
    );
    expect(
      outlines.first.size.width,
      closeTo((b.right - b.left) / 2 + 6, 0.01),
    );
    // One painter for all the words.
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.tapAt(outlines[1].centre);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tapped, [words[1].text]);
    // Between the words: nothing opens.
    await tester.tapAt(
      Offset(
        (outlines[0].centre.dx +
                outlines[0].size.width / 2 +
                outlines[1].centre.dx -
                outlines[1].size.width / 2) /
            2,
        outlines[0].centre.dy,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tapped, [words[1].text]);
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(outlines[0].centre);
    await pen.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tapped, [words[1].text], reason: 'the pen writes, never opens');
  });

  test('a word written at a slant is outlined along it', () {
    // 40 x 10 points, turned 30 degrees about its centre.
    const angle = 30 * math.pi / 180;
    const w = RecognizedWord(
      text: 'up',
      alternatives: [],
      box: InkBox(80, 80, 120, 120),
      line: 0,
      slant: (angle: angle, cx: 100, cy: 100, box: InkBox(80, 95, 120, 105)),
    );
    final g = PageGeometry(width: 612, height: 792);
    final o = PageWordOutlines.outlineOf(w, g, 612);
    expect(o.size.width, closeTo(40 + 6, 0.01));
    expect(o.size.height, closeTo(10 + 6, 0.01));
    expect(o.angle.abs(), closeTo(angle, 0.001));
    final c = g.toView(const PdfPagePoint(100, 100), 612);
    expect(o.centre.dx, closeTo(c.x, 0.01));
    expect(o.centre.dy, closeTo(c.y, 0.01));
    // Along the slant is inside; the box's level corner isn't.
    final along = Offset(math.cos(o.angle), math.sin(o.angle)) * 20;
    expect(PageWordOutlines.contains(o, o.centre + along), isTrue);
    expect(
      PageWordOutlines.contains(o, o.centre + const Offset(22, 7)),
      isFalse,
    );
  });
}
