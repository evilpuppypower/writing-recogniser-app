import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
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

  test('the pen near the end of the line counts as carrying it on', () {
    const g = (left: 100.0, right: 200.0, baseline: 700.0, letter: 10.0);
    expect(nearLineEnd(g, 230, 705), isTrue);
    expect(nearLineEnd(g, 150, 705), isFalse, reason: 'mid-line');
    expect(nearLineEnd(g, 230, 650), isFalse, reason: 'a line further down');
    expect(nearLineEnd(g, 400, 705), isFalse, reason: 'far to the side');
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
    final tools = ValueNotifier(const PenToolsState());
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
              tools: tools,
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
    // A pen stroke, then straight away the highlighter (no guide for it):
    // the guide still fades.
    await pen.down(const Offset(120, 100));
    await pen.moveTo(const Offset(123, 90));
    await tester.pump(const Duration(milliseconds: 40));
    await pen.moveTo(const Offset(126, 100));
    await pen.up();
    await tester.pump();
    expect(opacity(), 1);
    tools.value = tools.value.copyWith(mode: PenMode.highlighter);
    await pen.down(const Offset(100, 300));
    await pen.moveTo(const Offset(200, 300));
    await tester.pump(const Duration(milliseconds: 40));
    await pen.up();
    await tester.pump(const Duration(seconds: 3));
    expect(opacity(), 0);
    await tester.pumpAndSettle();
  });

  testWidgets('no guide on a page turned sideways', (tester) async {
    final ink = DocumentInkController();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 792,
            height: 612,
            child: PageInkLayer(
              pageNumber: 1,
              geometry: PageGeometry(width: 612, height: 792, quarterTurns: 1),
              viewWidth: 792,
              controller: ink,
            ),
          ),
        ),
      ),
    );
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(const Offset(100, 100));
    await pen.moveTo(const Offset(103, 90));
    await tester.pump(const Duration(milliseconds: 40));
    await pen.moveTo(const Offset(106, 100));
    await pen.up();
    await tester.pump();
    expect(ink.ink.strokesOn(1), hasLength(1));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.descendant(
              of: find.byType(PageInkLayer),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity,
      0,
    );
  });
}
