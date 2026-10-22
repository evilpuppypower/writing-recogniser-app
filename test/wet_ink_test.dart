import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/pen_tools_controller.dart';
import 'package:writing_recogniser/viewer/wet_ink.dart';

class FakeWetInk implements WetInk {
  final calls = <String>[];
  final starts = <({int down, int color, double unitPx, Rect clip})>[];

  @override
  void start({
    required int downMicros,
    required int colorArgb,
    required double unitPx,
    required double spread,
    required double thinnest,
    required Rect clip,
    required double devicePixelRatio,
  }) {
    calls.add('start $downMicros');
    starts.add((
      down: downMicros,
      color: colorArgb,
      unitPx: unitPx,
      clip: clip,
    ));
  }

  @override
  void cancel(int downMicros) => calls.add('cancel $downMicros');

  @override
  void release(int downMicros) => calls.add('release $downMicros');
}

void main() {
  late DocumentInkController ink;
  late PenToolsController tools;
  late FakeWetInk wet;

  setUp(() {
    ink = DocumentInkController();
    tools = PenToolsController();
    wet = FakeWetInk();
    ink.wetInk = wet;
  });

  Future<Offset> pump(WidgetTester tester, {double zoom = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Transform.scale(
            scale: zoom,
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
      ),
    );
    return tester.getTopLeft(find.byType(PageInkLayer));
  }

  Future<TestGesture> write(WidgetTester tester, Offset at) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await g.down(
      at + const Offset(40, 100),
      timeStamp: const Duration(milliseconds: 5000),
    );
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(
        at + Offset(40.0 + i * 10, 100 + (i.isEven ? 4 : -4)),
        timeStamp: Duration(milliseconds: 5000 + i * 8),
      );
      await tester.pump(const Duration(milliseconds: 8));
    }
    return g;
  }

  testWidgets('a pen stroke is drawn by the platform, then released once '
      'the app has drawn it', (tester) async {
    final at = await pump(tester);
    final g = await write(tester, at);
    expect(wet.calls, ['start 5000000']);
    final s = wet.starts.single;
    expect(s.color, PenStyle.defaultPen.colorArgb);
    // Width at normal pressure: the pen's width in points, at half a pixel
    // a point, at a pixel ratio of 3 (the test screen's).
    expect(s.unitPx, closeTo(PenStyle.defaultPen.width * 0.5 * 3, 1e-6));
    // The page, where it is on the screen.
    expect(s.clip, at & const Size(306, 396));
    await g.up();
    await tester.pump();
    expect(wet.calls, ['start 5000000'], reason: 'not before it shows');
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(wet.calls, ['start 5000000', 'release 5000000']);
    expect(ink.ink.strokesOn(1), hasLength(1));
  });

  testWidgets('a straightened stroke is cancelled at once', (tester) async {
    final at = await pump(tester);
    final g = await write(tester, at);
    await tester.pump(snapHoldTime + const Duration(milliseconds: 50));
    expect(wet.calls, ['start 5000000', 'cancel 5000000']);
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(wet.calls, ['start 5000000', 'cancel 5000000']);
  });

  testWidgets('the highlighter is drawn by the app alone', (tester) async {
    tools.value = tools.value.withCurrent(PenStyle.defaultHighlighter);
    final at = await pump(tester);
    final g = await write(tester, at);
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(wet.calls, isEmpty);
    expect(ink.ink.strokesOn(1), hasLength(1));
  });

  testWidgets('without the platform layer the pen works as before', (
    tester,
  ) async {
    ink.wetInk = null;
    final at = await pump(tester);
    final g = await write(tester, at);
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(ink.ink.strokesOn(1), hasLength(1));
  });

  testWidgets('zoomed in, the line is as wide as the app draws it, and '
      'kept to where the pages show', (tester) async {
    ink.wetArea = () => const Rect.fromLTRB(0, 0, 800, 300);
    final at = await pump(tester, zoom: 2);
    final g = await write(tester, at);
    final s = wet.starts.single;
    expect(s.unitPx, closeTo(PenStyle.defaultPen.width * 0.5 * 2 * 3, 1e-6));
    final page = tester.getRect(find.byType(PageInkLayer));
    expect(s.clip, page.intersect(const Rect.fromLTRB(0, 0, 800, 300)));
    await g.up();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a see-through pen is drawn by the app alone', (tester) async {
    tools.value = tools.value.withCurrent(
      PenStyle.defaultPen.copyWith(colorArgb: 0x80FF0000),
    );
    final at = await pump(tester);
    final g = await write(tester, at);
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(wet.calls, isEmpty);
  });

  testWidgets('the page going away mid-stroke cancels it', (tester) async {
    final at = await pump(tester);
    await write(tester, at);
    await tester.pumpWidget(const SizedBox());
    expect(wet.calls, ['start 5000000', 'cancel 5000000']);
  });
}
