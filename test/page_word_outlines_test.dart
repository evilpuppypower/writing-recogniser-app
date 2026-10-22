import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
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
    final boxes = find.byType(DecoratedBox);
    expect(boxes, findsNWidgets(2));
    // Neighbouring words in different colours.
    Color colour(int i) =>
        ((tester.widget<DecoratedBox>(boxes.at(i)).decoration as BoxDecoration)
                    .border!
                as Border)
            .top
            .color;
    expect(colour(0), isNot(colour(1)));
    // Round the word's ink, in the page's pixels (half a pixel a point).
    final rect = PageWordOutlines.outlineOf(
      words.first,
      PageGeometry(width: 612, height: 792),
      306,
    );
    final b = words.first.box;
    expect(rect.left, closeTo(b.left / 2 - 3, 0.01));
    expect(rect.width, closeTo((b.right - b.left) / 2 + 6, 0.01));
    await tester.tapAt(tester.getCenter(boxes.at(1)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tapped, [words[1].text]);
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(tester.getCenter(boxes.at(0)));
    await pen.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tapped, [words[1].text], reason: 'the pen writes, never opens');
  });
}
