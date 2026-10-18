import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

PageStroke line(double x0, double y0, double x1, double y1) => PageStroke(
  points: [PageInkPoint(x0, y0, 1000, 0.3), PageInkPoint(x1, y1, 1010, 0.7)],
);

void main() {
  group('DocumentInk', () {
    test('keeps strokes per page', () {
      final ink = DocumentInk()
        ..add(1, line(0, 0, 10, 0))
        ..add(3, line(0, 0, 10, 0))
        ..add(3, line(0, 50, 10, 50));
      expect(ink.strokesOn(1), hasLength(1));
      expect(ink.strokesOn(2), isEmpty);
      expect(ink.strokesOn(3), hasLength(2));
      expect(ink.pagesWithInk, unorderedEquals([1, 3]));
    });

    test('erasing removes whole strokes near the point, on that page only', () {
      final ink = DocumentInk()
        ..add(1, line(0, 0, 100, 0))
        ..add(1, line(0, 50, 100, 50))
        ..add(2, line(0, 0, 100, 0));
      expect(ink.eraseAt(1, 50, 30, 5), isEmpty); // nothing close
      final removed = ink.eraseAt(1, 50, 3, 5); // near the middle of line 1
      expect(removed, hasLength(1));
      expect(ink.strokesOn(1).single.points.first.y, 50);
      expect(ink.strokesOn(2), hasLength(1));
    });

    test('"not writing" marks are kept by id, saved, and survive a split', () {
      // Real strokes start at different times, so their ids differ.
      final ink = DocumentInk()
        ..add(1, line(0, 0, 100, 0))
        ..add(
          1,
          const PageStroke(
            points: [PageInkPoint(0, 50, 2000), PageInkPoint(100, 50, 2010)],
          ),
        );
      final target = ink.strokesOn(1).last;
      expect(ink.markNotWriting(1, {target.id}), isTrue);
      expect(ink.markNotWriting(1, {target.id}), isFalse, reason: 'no change');
      expect(ink.strokesOn(1).map((s) => s.notWriting), [false, true]);
      final back = DocumentInk.fromJson(ink.toJson());
      expect(back.strokesOn(1).map((s) => s.notWriting), [false, true]);
      // Rubbing out the middle splits the stroke; both pieces keep the mark.
      back.eraseArea(1, 50, 50, 5);
      final pieces = back.strokesOn(1).where((s) => s.points.first.y == 50);
      expect(pieces, hasLength(2));
      expect(pieces.every((s) => s.notWriting), isTrue);
    });

    test('undoing other edits keeps the "not writing" mark', () {
      final c = DocumentInkController();
      final a = line(0, 0, 100, 0);
      const b = PageStroke(
        points: [PageInkPoint(0, 50, 2000), PageInkPoint(100, 50, 2010)],
      );
      c.add(1, a);
      c.add(1, b);
      c.markNotWriting(1, {a.id});
      c.undo(); // takes b away; a must stay marked
      expect(c.ink.strokesOn(1).single.notWriting, isTrue);
      c.redo();
      expect(c.ink.strokesOn(1).map((s) => s.notWriting), [true, false]);
    });

    test('"This is writing" takes the mark off again (task 2.4d)', () {
      final c = DocumentInkController();
      final a = line(0, 0, 100, 0);
      const b = PageStroke(
        points: [PageInkPoint(0, 50, 2000), PageInkPoint(100, 50, 2010)],
      );
      final changed = <int>[];
      c.onChanged = changed.add;
      c.add(1, a);
      c.add(1, b);
      c.markNotWriting(1, {a.id, b.id});
      expect(c.ink.markWriting(1, {'nothing'}), isFalse, reason: 'no change');
      c.markWriting(1, {a.id});
      expect(c.ink.strokesOn(1).map((s) => s.notWriting), [false, true]);
      expect(changed.last, 1, reason: 'saved and read again');
      c.undo(); // takes b away; a must stay unmarked
      expect(c.ink.strokesOn(1).single.notWriting, isFalse);
    });

    test('JSON round trip keeps points, time, pressure, colour and width', () {
      final ink = DocumentInk()
        ..add(
          2,
          const PageStroke(
            points: [PageInkPoint(1.25, 700.5, 1000, 0.4)],
            colorArgb: 0xFF0055AA,
            width: 2.5,
            tool: InkTool.highlighter,
          ),
        );
      final back = DocumentInk.fromJson(ink.toJson());
      final s = back.strokesOn(2).single;
      expect(s.colorArgb, 0xFF0055AA);
      expect(s.width, 2.5);
      expect(s.tool, InkTool.highlighter);
      final p = s.points.single;
      expect([p.x, p.y, p.t, p.pressure], [1.25, 700.5, 1000, 0.4]);
    });
  });

  test('the pen stays down until every page holding it lets go', () async {
    final c = DocumentInkController();
    c.penOn();
    c.penOn(); // two pages under the pen
    c.penOff();
    await Future<void>.delayed(Duration.zero);
    expect(c.penDown.value, isTrue);
    c.penOff();
    c.penOff(); // a page that never had the pen: no harm
    await Future<void>.delayed(Duration.zero);
    expect(c.penDown.value, isFalse);
  });

  test('pen times stay in order after a busy moment', () {
    final c = DocumentInkController();
    // Events reported 10 ms apart but handled at once (a busy moment):
    // the later event never gets an earlier time.
    var last = c.timeOf(const Duration(milliseconds: 1000));
    for (var t = 1010; t <= 1100; t += 10) {
      final now = c.timeOf(Duration(milliseconds: t));
      expect(now, greaterThanOrEqualTo(last));
      last = now;
    }
  });

  group('PageInkLayer', () {
    late DocumentInkController ink;
    late TransformationController view;

    // A US Letter page (612 x 792 pt) laid out 306 px wide (0.5 px per pt),
    // inside a zoomable viewer like the real PDF viewer.
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 306,
              height: 396,
              child: InteractiveViewer(
                transformationController: view,
                child: SizedBox(
                  width: 306,
                  height: 396,
                  child: PageInkLayer(
                    pageNumber: 4,
                    geometry: PageGeometry(width: 612, height: 792),
                    viewWidth: 306,
                    controller: ink,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    setUp(() {
      ink = DocumentInkController();
      view = TransformationController();
    });

    Future<void> drag(
      WidgetTester tester,
      PointerDeviceKind kind, {
      int buttons = kPrimaryButton,
      Offset by = const Offset(60, 20),
    }) async {
      final topLeft = tester.getTopLeft(find.byType(PageInkLayer));
      final g = await tester.createGesture(kind: kind, buttons: buttons);
      await g.down(topLeft + const Offset(100, 100));
      for (var i = 0; i < 6; i++) {
        await g.moveBy(by / 6);
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    testWidgets('points keep the time the pen was there, and the pen is '
        'known to be down while writing', (tester) async {
      await pump(tester);
      final topLeft = tester.getTopLeft(find.byType(PageInkLayer));
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.down(
        topLeft + const Offset(100, 100),
        timeStamp: const Duration(milliseconds: 1000),
      );
      expect(ink.penDown.value, isTrue);
      for (var i = 1; i <= 4; i++) {
        await g.moveTo(
          topLeft + Offset(100.0 + i * 8, 100),
          timeStamp: Duration(milliseconds: 1000 + i * 4),
        );
        // A busy moment between points: the times don't change.
        await tester.pump(const Duration(milliseconds: 60));
      }
      await g.up(timeStamp: const Duration(milliseconds: 1020));
      await tester.pumpAndSettle();
      expect(ink.penDown.value, isFalse);
      final ts = ink.ink.strokesOn(4).single.points.map((p) => p.t).toList();
      final gaps = [for (var i = 1; i < ts.length; i++) ts[i] - ts[i - 1]];
      expect(gaps, everyElement(4));
      // Still a clock time (ms since 1970), not time since the tablet
      // started.
      expect(
        (ts.first - DateTime.now().millisecondsSinceEpoch).abs(),
        lessThan(60000),
      );
    });

    testWidgets('the pen writes in PDF page coordinates and does not scroll', (
      tester,
    ) async {
      await pump(tester);
      await drag(tester, PointerDeviceKind.stylus);
      final strokes = ink.ink.strokesOn(4);
      expect(strokes, hasLength(1));
      final first = strokes.single.points.first;
      // View (100, 100) at 0.5 px/pt = PDF (200, 792 - 200).
      expect(first.x, closeTo(200, 0.01));
      expect(first.y, closeTo(592, 0.01));
      expect(view.value, Matrix4.identity());
    });

    testWidgets('a finger moves the page and writes nothing', (tester) async {
      await pump(tester);
      view.value = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      await tester.pump();
      await drag(tester, PointerDeviceKind.touch, by: const Offset(-60, -60));
      expect(ink.ink.strokesOn(4), isEmpty);
      expect(view.value, isNot(Matrix4.identity()..scaleByDouble(2, 2, 1, 1)));
    });

    testWidgets('the pen side button erases whole strokes', (tester) async {
      await pump(tester);
      await drag(tester, PointerDeviceKind.stylus);
      expect(ink.ink.strokesOn(4), hasLength(1));
      await drag(
        tester,
        PointerDeviceKind.stylus,
        buttons: kPrimaryButton | kPrimaryStylusButton,
      );
      expect(ink.ink.strokesOn(4), isEmpty);
    });
  });

  // pdfrx draws page overlays *on top of* its scroll/zoom view (siblings in
  // a Stack), not inside it, so the ink layer must let fingers through.
  group('PageInkLayer over the viewer (as pdfrx stacks it)', () {
    testWidgets('fingers reach the viewer underneath; the pen writes', (
      tester,
    ) async {
      final ink = DocumentInkController();
      var viewerDrags = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 306,
              height: 396,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleUpdate: (_) => viewerDrags++,
                    ),
                  ),
                  Positioned.fill(
                    child: PageInkLayer(
                      pageNumber: 1,
                      geometry: PageGeometry(width: 612, height: 792),
                      viewWidth: 306,
                      controller: ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final centre = tester.getCenter(find.byType(PageInkLayer));

      Future<void> drag(PointerDeviceKind kind) async {
        final g = await tester.createGesture(kind: kind);
        await g.down(centre);
        for (var i = 1; i <= 5; i++) {
          await g.moveTo(centre + Offset(i * 10, i * 6));
          await tester.pump();
        }
        await g.up();
        await tester.pump();
      }

      await drag(PointerDeviceKind.touch);
      expect(viewerDrags, greaterThan(0));
      expect(ink.ink.strokesOn(1), isEmpty);

      viewerDrags = 0;
      await drag(PointerDeviceKind.stylus);
      expect(viewerDrags, 0);
      expect(ink.ink.strokesOn(1), hasLength(1));
    });
  });

  testWidgets('erasing with the pen, then hovering, works without errors', (
    tester,
  ) async {
    final ink = DocumentInkController()
      ..add(
        1,
        const PageStroke(
          points: [PageInkPoint(300, 400, 0), PageInkPoint(320, 400, 10)],
        ),
      );
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
              tools: ValueNotifier(const PenToolsState(mode: PenMode.eraser)),
            ),
          ),
        ),
      ),
    );
    final page = tester.getTopLeft(find.byType(PageInkLayer));
    // PDF (300..320, 400) is view (150..160, 196) at half size.
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.addPointer(location: page + const Offset(100, 196));
    await pen.moveTo(page + const Offset(140, 196)); // hovering: no outline
    await tester.pump();
    await pen.down(page + const Offset(150, 196));
    await pen.moveTo(page + const Offset(160, 196));
    await tester.pump();
    await pen.up();
    await tester.pump(const Duration(milliseconds: 300));
    await pen.removePointer();
    await tester.pump();
    expect(ink.ink.strokesOn(1), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
