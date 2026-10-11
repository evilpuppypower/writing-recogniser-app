import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/handwriting/ink_canvas.dart';
import 'package:writing_recogniser/handwriting/ink_controller.dart';

void main() {
  late InkController ink;
  late List<InkStroke> ended;
  late int erased;

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InkCanvas(
          controller: ink,
          onStrokeEnd: ended.add,
          onErase: () => erased++,
        ),
      ),
    ),
  );

  setUp(() {
    ink = InkController();
    ended = [];
    erased = 0;
  });

  Future<void> draw(
    WidgetTester tester,
    PointerDeviceKind kind, {
    Offset from = const Offset(100, 100),
    int buttons = kPrimaryButton,
  }) async {
    final g = await tester.createGesture(kind: kind, buttons: buttons);
    await g.down(from);
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(40, 10));
    await g.up();
    await tester.pump();
  }

  testWidgets('the pen writes a stroke with time and pressure', (tester) async {
    await pump(tester);
    await draw(tester, PointerDeviceKind.stylus);
    expect(ended, hasLength(1));
    final pts = ended.single.points;
    expect(pts.length, greaterThanOrEqualTo(3));
    expect(pts.first.x, closeTo(100, 1));
    expect(pts.last.t, greaterThanOrEqualTo(pts.first.t));
    expect(pts.every((p) => p.pressure >= 0 && p.pressure <= 1), isTrue);
  });

  testWidgets('fingers and palms do not write', (tester) async {
    await pump(tester);
    await draw(tester, PointerDeviceKind.touch);
    expect(ended, isEmpty);
    expect(ink.isEmpty, isTrue);
  });

  testWidgets('holding the pen button erases whole strokes', (tester) async {
    await pump(tester);
    await draw(tester, PointerDeviceKind.stylus);
    await draw(tester, PointerDeviceKind.stylus, from: const Offset(100, 300));
    expect(ink.strokes, hasLength(2));

    await draw(
      tester,
      PointerDeviceKind.stylus,
      from: const Offset(130, 290),
      buttons: kPrimaryButton | kSecondaryStylusButton,
    );
    expect(ink.strokes, hasLength(1));
    expect(erased, 1);
    expect(ended, hasLength(2)); // erasing doesn't create a stroke
  });

  testWidgets('the pen side button (stylus primary button) erases', (
    tester,
  ) async {
    await pump(tester);
    await draw(tester, PointerDeviceKind.stylus);
    await draw(
      tester,
      PointerDeviceKind.stylus,
      from: const Offset(130, 90),
      buttons: kPrimaryButton | kPrimaryStylusButton,
    );
    expect(ink.strokes, isEmpty);
    expect(ended, hasLength(1));
  });

  testWidgets('pressing the button mid-stroke switches to erasing', (
    tester,
  ) async {
    await pump(tester);
    await draw(tester, PointerDeviceKind.stylus, from: const Offset(100, 300));
    final g = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: 7,
    );
    await g.down(const Offset(100, 100));
    await g.moveBy(const Offset(20, 0));
    await g.updateWithCustomEvent(
      PointerMoveEvent(
        kind: PointerDeviceKind.stylus,
        pointer: 7,
        position: const Offset(130, 310),
        buttons: kPrimaryButton | kPrimaryStylusButton,
      ),
    );
    await g.up();
    await tester.pump();
    expect(ink.strokes, isEmpty); // the earlier stroke was erased
    expect(ended, hasLength(1)); // the half-drawn one was dropped
  });

  testWidgets("the pen's eraser end erases too", (tester) async {
    await pump(tester);
    await draw(tester, PointerDeviceKind.stylus);
    await draw(tester, PointerDeviceKind.invertedStylus);
    expect(ink.strokes, isEmpty);
  });

  testWidgets('pen hover between strokes is recorded, not drawn', (
    tester,
  ) async {
    await pump(tester);
    final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await g.addPointer(location: const Offset(50, 50));
    await g.moveTo(const Offset(60, 55));
    await g.moveTo(const Offset(70, 60));
    await g.removePointer();
    expect(ink.hover.map((p) => [p.x, p.y]), [
      [60, 55],
      [70, 60],
    ]);
    expect(ink.hover.every((p) => p.pressure == 0), isTrue);
    expect(ink.strokes, isEmpty);

    // Finger hover (e.g. a mouse) is ignored; clearing resets it.
    final m = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await m.addPointer(location: const Offset(10, 10));
    await m.moveTo(const Offset(20, 20));
    await m.removePointer();
    expect(ink.hover, hasLength(2));
    ink.clear();
    expect(ink.hover, isEmpty);
  });
}
