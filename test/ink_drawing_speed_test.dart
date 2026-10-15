import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

/// A heavily written page: [words] words of 4 wavy strokes, 60 points each,
/// with changing pressure.
DocumentInk heavyPage(int words) {
  final ink = DocumentInk();
  var t = 0;
  for (var w = 0; w < words; w++) {
    final x0 = 40.0 + (w % 8) * 65, y0 = 740.0 - (w ~/ 8) * 30;
    for (var s = 0; s < 4; s++) {
      ink.add(
        1,
        PageStroke(
          points: [
            for (var i = 0; i < 60; i++)
              PageInkPoint(
                x0 + s * 12 + i * 0.2,
                y0 + 6 * math.sin(i / 6),
                t += 5,
                0.3 + 0.5 * (i % 10) / 10,
              ),
          ],
        ),
      );
    }
  }
  return ink;
}

void main() {
  test('line widths come in steps, so a stroke is a few paths', () {
    expect(widthStep(1.31), 1.25);
    expect(widthStep(1.38), 1.5);
    expect(widthStep(0.01), 0.25);
    // Wider lines: steps of 5%.
    expect((widthStep(10.2) - 10).abs(), lessThan(0.6));
  });

  testWidgets('a page with 50 words draws, and scrolls, without trouble', (
    tester,
  ) async {
    final ctl = DocumentInkController(heavyPage(50));
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 612,
            height: 792,
            child: PageInkLayer(
              pageNumber: 1,
              geometry: PageGeometry(width: 612, height: 792),
              viewWidth: 612,
              controller: ctl,
            ),
          ),
        ),
      ),
    );
    // Drawn as it is first; once settled, from a ready-made image.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Writing more after that still works (the image is made again).
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(const Offset(100, 500));
    await pen.moveTo(const Offset(120, 520));
    await tester.pump(const Duration(milliseconds: 20));
    await pen.up();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(ctl.ink.strokesOn(1), hasLength(201));
    expect(tester.takeException(), isNull);
  });
}
