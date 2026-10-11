import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/pen_toolbar.dart';
import 'package:writing_recogniser/viewer/pen_tools_controller.dart';

void main() {
  group('arrowheads', () {
    test('point back along the stroke on both sides', () {
      final pts = [const PageInkPoint(0, 0, 0), const PageInkPoint(100, 0, 1)];
      final head = arrowheadPoints(pts, 10);
      expect(head, hasLength(2));
      for (final (x, y) in head) {
        expect(x, lessThan(100)); // behind the tip
        expect((x - 100) * (x - 100) + y * y, closeTo(100, 1e-6));
      }
      expect(head[0].$2, closeTo(-head[1].$2, 1e-9)); // symmetric
    });

    test('a flick as the pen lifts is dropped from an arrow', () {
      // Drawn right to left, then the pen flicks up and right as it lifts.
      final pts = [
        for (var x = 100.0; x >= 0; x -= 5) PageInkPoint(x, 50, 0),
        const PageInkPoint(3, 47, 0),
        const PageInkPoint(7, 45, 0),
      ];
      final trimmed = trimLiftHook(pts, 12);
      expect(trimmed.last.x, 0);
      expect(trimmed.last.y, 50);
      final head = arrowheadPoints(trimmed, 8);
      for (final (x, _) in head) {
        expect(x, greaterThan(0)); // head opens back to the right: points left
      }
    });

    test('with a time limit, only a quick flick at the very end is cut', () {
      // Leftward line 10 ms per point, then a hook in the last 20 ms.
      final pts = [
        for (var i = 0; i <= 20; i++) PageInkPoint(100.0 - i * 5, 50, i * 10),
        const PageInkPoint(3, 47, 210),
        const PageInkPoint(7, 45, 220),
      ];
      expect(trimLiftHook(pts, 12, withinMs: 70).last.x, 0);
      expect(trimLiftHook(pts, 12, withinMs: 0), same(pts)); // off

      // The same shape drawn slowly (a deliberate bend over 200 ms) stays.
      final slow = [
        ...pts.take(21),
        const PageInkPoint(3, 47, 300),
        const PageInkPoint(7, 45, 400),
      ];
      expect(trimLiftHook(slow, 12, withinMs: 70), same(slow));
    });

    test('a straight or gently curved end is kept', () {
      final pts = [
        for (var x = 0.0; x <= 100; x += 5) PageInkPoint(x, x * 0.1, 0),
      ];
      expect(trimLiftHook(pts, 12), same(pts));
    });

    test('no head without a direction', () {
      expect(arrowheadPoints(const [PageInkPoint(1, 1, 0)], 10), isEmpty);
    });

    test('arrow survives saving; partial erase keeps it only on the end', () {
      const stroke = PageStroke(
        points: [PageInkPoint(0, 0, 0), PageInkPoint(100, 0, 100)],
        arrow: true,
      );
      expect(PageStroke.fromJson(stroke.toJson()).arrow, isTrue);
      final ink = DocumentInk()..add(1, stroke);
      ink.eraseArea(1, 50, 0, 5);
      final pieces = ink.strokesOn(1);
      expect(pieces.map((p) => p.arrow), [false, true]);
    });
  });

  group('hold to snap', () {
    late DocumentInkController ink;
    late PenToolsController tools;

    Future<TestGesture> startWriting(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 306,
              height: 396,
              child: PageInkLayer(
                pageNumber: 1,
                geometry: PageGeometry(width: 612, height: 792),
                viewWidth: 306,
                controller: ink,
                tools: tools,
              ),
            ),
          ),
        ),
      );
      final at = tester.getTopLeft(find.byType(PageInkLayer));
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.down(at + const Offset(20, 100));
      // A wobbly line.
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(Offset(15, i.isEven ? 6 : -6));
        await tester.pump(const Duration(milliseconds: 16));
      }
      return g;
    }

    setUp(() {
      ink = DocumentInkController();
      tools = PenToolsController();
    });

    testWidgets('holding still straightens the stroke', (tester) async {
      final g = await startWriting(tester);
      await tester.pump(snapHoldTime + const Duration(milliseconds: 50));
      await g.up();
      await tester.pump();
      final points = ink.ink.strokesOn(1).single.points;
      expect(points, hasLength(2));
    });

    testWidgets('after snapping, the end follows the pen', (tester) async {
      final g = await startWriting(tester);
      await tester.pump(snapHoldTime + const Duration(milliseconds: 50));
      await g.moveBy(const Offset(0, 40));
      await g.up();
      await tester.pump();
      final points = ink.ink.strokesOn(1).single.points;
      expect(points, hasLength(2));
      // 40 px down at 0.5 px/pt = 80 pt lower (PDF y goes up).
      expect(points.first.y - points.last.y, greaterThan(70));
    });

    testWidgets('lifting without holding keeps the hand-drawn shape', (
      tester,
    ) async {
      final g = await startWriting(tester);
      await g.up();
      await tester.pump(snapHoldTime * 2);
      expect(ink.ink.strokesOn(1).single.points.length, greaterThan(5));
    });

    testWidgets('a short dot never snaps', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 306,
              height: 396,
              child: PageInkLayer(
                pageNumber: 1,
                geometry: PageGeometry(width: 612, height: 792),
                viewWidth: 306,
                controller: ink,
                tools: tools,
              ),
            ),
          ),
        ),
      );
      final at = tester.getTopLeft(find.byType(PageInkLayer));
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.down(at + const Offset(50, 50));
      await g.moveBy(const Offset(3, 2));
      await g.moveBy(const Offset(2, 3));
      await tester.pump(snapHoldTime * 2);
      await g.up();
      await tester.pump();
      expect(ink.ink.strokesOn(1).single.points.length, greaterThan(2));
    });

    testWidgets('arrow switch makes pen strokes end with an arrow', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PenToolbar(controller: tools)),
        ),
      );
      await tester.tap(
        find.byTooltip('Add an arrowhead to the end of pen strokes'),
      );
      await tester.pump();
      expect(tools.value.pen.arrow, isTrue);
      expect(tools.value.current!.arrow, isTrue);
      final g = await startWriting(tester);
      await g.up();
      await tester.pump();
      expect(ink.ink.strokesOn(1).single.arrow, isTrue);
    });
  });
}
