import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/writing_guide.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

/// A letter 6 pt wide and [h] tall, bottom at [y].
PageStroke letter(double x, double y, int t, {double h = 10}) => PageStroke(
  points: [
    PageInkPoint(x, y, t),
    PageInkPoint(x + 3, y + h, t + 40),
    PageInkPoint(x + 6, y, t + 80),
  ],
);

void main() {
  test('the guide sits under the letters of the line being written', () {
    final line = [
      for (var i = 0; i < 5; i++) letter(100 + i * 7.0, 700, i * 200),
    ];
    // A "g": its tail goes 5 pt below the others.
    final g = letter(135, 695, 1000, h: 15);
    final other = letter(100, 600, 2000); // a line further down
    final page = [...line, g, other];
    final guide = guideFor(page, g.id)!;
    expect(guide.baseline, closeTo(699, 0.01), reason: 'not pulled down');
    expect(guide.left, lessThan(100));
    expect(guide.right, greaterThan(141 + 30), reason: 'room ahead');
    expect(guideFor(page, other.id)!.baseline, lessThan(600));
  });

  test('no guide for highlighter or unknown strokes', () {
    const marker = PageStroke(
      tool: InkTool.highlighter,
      points: [PageInkPoint(0, 0, 0), PageInkPoint(50, 0, 10)],
    );
    expect(guideFor([marker], marker.id), isNull);
    expect(guideFor([marker], 'nope'), isNull);
  });

  test('pale grey by default, can be turned off, and is saved', () {
    expect(const AppSettings().writingGuide, WritingGuide.grey);
    final off = const AppSettings().copyWith(writingGuide: WritingGuide.off);
    expect(AppSettings.fromMap(off.toMap()).writingGuide, WritingGuide.off);
  });

  testWidgets('fades in while writing and out 3 s after', (tester) async {
    final ink = DocumentInkController();
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
              controller: ink,
            ),
          ),
        ),
      ),
    );
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byType(PageInkLayer),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(opacity(), 0);
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(const Offset(100, 100));
    for (final p in const [Offset(103, 90), Offset(106, 100)]) {
      await pen.moveTo(p);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await pen.up();
    await tester.pump();
    expect(ink.ink.strokesOn(1), hasLength(1));
    expect(opacity(), 1);
    await tester.pump(const Duration(seconds: 3));
    expect(opacity(), 0);
    await tester.pumpAndSettle();
  });
}
