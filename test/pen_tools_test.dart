import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/pen_toolbar.dart';
import 'package:writing_recogniser/viewer/pen_tools_controller.dart';

const blue = PenStyle(tool: InkTool.pen, colorArgb: 0xFF1565C0, width: 2);

void main() {
  group('PenToolsState', () {
    test('pen and highlighter keep their own style', () {
      final s = const PenToolsState()
          .withCurrent(blue)
          .withCurrent(PenStyle.defaultHighlighter.copyWith(width: 12));
      expect(s.mode, PenMode.highlighter);
      expect(s.pen, blue);
      expect(s.current!.width, 12);
      expect(s.copyWith(mode: PenMode.eraser).current, isNull);
    });

    test('widths stay within limits', () {
      expect(blue.copyWith(width: 99).width, PenStyle.maxPenWidth);
      expect(
        PenStyle.defaultHighlighter.copyWith(width: 0).width,
        PenStyle.minHighlighterWidth,
      );
    });

    test('favourites: no duplicates, oldest makes room, unpin', () {
      var s = const PenToolsState().pin(blue).pin(blue);
      expect(s.favourites, [blue]);
      for (var i = 0; i < PenToolsState.maxFavourites; i++) {
        s = s.pin(blue.copyWith(width: 0.4 + i * 0.5));
      }
      expect(s.favourites, hasLength(PenToolsState.maxFavourites));
      expect(s.isFavourite(blue), isFalse);
      expect(
        s.unpin(s.favourites.first).favourites,
        hasLength(PenToolsState.maxFavourites - 1),
      );
    });

    test('saved state round trips; damaged data falls back to defaults', () {
      final s = const PenToolsState(dock: ToolbarDock.right)
          .withCurrent(blue)
          .pin(PenStyle.defaultHighlighter)
          .copyWith(favouritesX: 0.2, favouritesY: 0.1);
      final back = PenToolsState.fromJson(s.toJson());
      expect(back.toJson(), s.toJson());
      expect(PenToolsState.fromJson('nonsense').mode, PenMode.pen);
      final partial = PenToolsState.fromJson({
        'pen': {'tool': 'highlighter', 'color': 1, 'width': 1},
        'favourites': [
          {'tool': 'pen'},
          blue.toJson(),
        ],
        'favouritesX': 5,
      });
      expect(partial.pen, PenStyle.defaultPen); // wrong tool ignored
      expect(partial.favourites, [blue]); // unreadable entry skipped
      expect(partial.favouritesX, 1);
    });

    test('pen width follows pressure; highlighter does not', () {
      expect(widthAtPressure(blue, 0), closeTo(1.2, 1e-9));
      expect(widthAtPressure(blue, 1), closeTo(2.8, 1e-9));
      expect(
        widthAtPressure(PenStyle.defaultHighlighter, 1),
        PenStyle.defaultHighlighter.width,
      );
    });

    test('the pressure setting scales the effect (off = constant)', () {
      expect(widthAtPressure(blue, 1, PressureResponse.none), blue.width);
      expect(widthAtPressure(blue, 0, PressureResponse.none), blue.width);
      expect(
        widthAtPressure(blue, 1, const PressureResponse(strength: 0.5)),
        closeTo(2.4, 1e-9),
      );
    });

    test('a wider range changes thickness more, never below 10%', () {
      const wide = PressureResponse(range: 2); // ±200%
      expect(widthAtPressure(blue, 1, wide), closeTo(6, 1e-9)); // 3x
      expect(widthAtPressure(blue, 0, wide), closeTo(0.2, 1e-9)); // 10%
      expect(widthAtPressure(blue, 0.5, wide), blue.width);
      const half = PressureResponse(range: 1);
      expect(widthAtPressure(blue, 0.75, half), closeTo(3, 1e-9));
      // Thinning is capped at 90%, so a light press goes 2 -> 1.1 pt.
      expect(widthAtPressure(blue, 0.25, half), closeTo(1.1, 1e-9));
    });
  });

  group('Partial erase', () {
    PageStroke longLine() => const PageStroke(
      points: [PageInkPoint(0, 0, 0), PageInkPoint(100, 0, 100)],
      width: 1,
    );

    test('cuts a stroke in two where the eraser rubs', () {
      final ink = DocumentInk()..add(1, longLine());
      expect(ink.eraseArea(1, 50, 0, 5), isTrue);
      final pieces = ink.strokesOn(1);
      expect(pieces, hasLength(2));
      expect(pieces.first.points.first.x, 0);
      expect(pieces.first.points.last.x, lessThan(45));
      expect(pieces.last.points.first.x, greaterThan(55));
      expect(pieces.last.points.last.x, 100);
      // Time and style carry over.
      expect(pieces.last.points.last.t, 100);
      expect(pieces.first.width, 1);
    });

    test('rubbing an end shortens the stroke; far away changes nothing', () {
      final ink = DocumentInk()..add(1, longLine());
      expect(ink.eraseArea(1, 50, 40, 5), isFalse);
      expect(ink.eraseArea(1, 100, 0, 10), isTrue);
      expect(ink.strokesOn(1).single.points.last.x, lessThan(90));
    });

    test('rubbing over a whole short stroke removes it', () {
      final ink = DocumentInk()
        ..add(
          1,
          const PageStroke(
            points: [PageInkPoint(0, 0, 0), PageInkPoint(2, 0, 1)],
          ),
        );
      ink.eraseArea(1, 1, 0, 6);
      expect(ink.strokesOn(1), isEmpty);
    });

    test('eraser choice and size are remembered', () {
      final s = const PenToolsState().copyWith(
        eraser: EraserKind.area,
        eraserSize: 99,
      );
      expect(s.eraserSize, PenToolsState.maxEraserSize);
      final back = PenToolsState.fromJson(s.toJson());
      expect(back.eraser, EraserKind.area);
    });
  });

  group('Toolbar and favourites', () {
    late PenToolsController tools;

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PenToolbar(controller: tools),
                Expanded(child: FavouritesBar(controller: tools)),
              ],
            ),
          ),
        ),
      );
    }

    setUp(() => tools = PenToolsController());

    testWidgets('choose a tool; tap it again for colour and size', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.border_color));
      await tester.pumpAndSettle();
      expect(tools.value.mode, PenMode.highlighter);
      expect(find.text('Thickness: 10.0 pt'), findsNothing);

      await tester.tap(find.byIcon(Icons.border_color));
      await tester.pumpAndSettle();
      expect(find.text('Thickness: 10.0 pt'), findsOneWidget);
      await tester.tap(find.byTooltip('Highlighter, pink, 10.0 pt'));
      await tester.pumpAndSettle();
      expect(tools.value.highlighter.colorArgb, 0xFFFF80AB);
    });

    testWidgets('the pen drags the favourites bar the full distance', (
      tester,
    ) async {
      tools.value = tools.value.withCurrent(blue).pin(blue);
      await pump(tester);
      final handle = find.byIcon(Icons.drag_indicator);
      final start = tester.getCenter(handle);
      final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await pen.down(start);
      await tester.pump();
      // Pen reports arrive faster than the screen redraws.
      for (var i = 0; i < 20; i++) {
        await pen.moveBy(const Offset(10, 0));
      }
      await tester.pump();
      await pen.up();
      await tester.pumpAndSettle();
      // 200 px of movement, less the drag start threshold.
      expect(tester.getCenter(handle).dx - start.dx, greaterThan(150));
    });

    testWidgets('pin a pen, use it from the favourites bar, unpin it', (
      tester,
    ) async {
      tools.value = tools.value.withCurrent(blue);
      await pump(tester);
      await tester.tap(find.byTooltip('Pin this pen to the favourites bar'));
      await tester.pumpAndSettle();
      expect(tools.value.favourites, [blue]);

      tools.update(tools.value.withCurrent(PenStyle.defaultPen));
      await tester.pumpAndSettle();
      final fav = find.byTooltip(
        'Pen, blue, 2.0 pt. Tap to use, long-press to unpin.',
      );
      await tester.tap(fav);
      await tester.pumpAndSettle();
      expect(tools.value.pen, blue);

      await tester.longPress(fav);
      await tester.pumpAndSettle();
      expect(tools.value.favourites, isEmpty);
      expect(fav, findsNothing);
    });

    testWidgets('tap the eraser again to choose partial erase', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Eraser (tap again for eraser options)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Erase only where I rub'));
      await tester.pumpAndSettle();
      expect(tools.value.eraser, EraserKind.area);
    });

    testWidgets('pen and highlighter icons show their colour', (tester) async {
      tools.value = tools.value.withCurrent(blue);
      await pump(tester);
      final pen = tester.widget<Icon>(find.byIcon(Icons.edit));
      expect(pen.color, Color(blue.colorArgb));
      final hl = tester.widget<Icon>(find.byIcon(Icons.border_color));
      expect(hl.color, Color(PenStyle.defaultHighlighter.colorArgb));
      // Position moved to Settings; no separate colour button.
      expect(find.byTooltip('Move the toolbar'), findsNothing);
      expect(find.byTooltip('Colour and size'), findsNothing);
    });
  });

  group('Writing with the chosen tool', () {
    late DocumentInkController ink;
    late PenToolsController tools;

    Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
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

    Future<void> stroke(WidgetTester tester, {double dy = 0}) async {
      final at = tester.getTopLeft(find.byType(PageInkLayer));
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.down(at + Offset(50, 100 + dy));
      await g.moveBy(const Offset(80, 0));
      await g.up();
      await tester.pump();
    }

    setUp(() {
      ink = DocumentInkController();
      tools = PenToolsController();
    });

    testWidgets('strokes keep the tool, colour and width used', (tester) async {
      tools.value = tools.value.withCurrent(PenStyle.defaultHighlighter);
      await pumpPage(tester);
      await stroke(tester);
      final s = ink.ink.strokesOn(1).single;
      expect(s.tool, InkTool.highlighter);
      expect(s.colorArgb, PenStyle.defaultHighlighter.colorArgb);
      expect(s.width, PenStyle.defaultHighlighter.width);
    });

    testWidgets('partial eraser cuts instead of removing', (tester) async {
      await pumpPage(tester);
      await stroke(tester); // horizontal line 80 px long
      tools.value = tools.value.copyWith(
        mode: PenMode.eraser,
        eraser: EraserKind.area,
        eraserSize: 6,
      );
      final at = tester.getTopLeft(find.byType(PageInkLayer));
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.down(at + const Offset(90, 85));
      await g.moveBy(const Offset(0, 30)); // vertical rub through the middle
      await g.up();
      await tester.pump();
      expect(ink.ink.strokesOn(1), hasLength(2));
    });

    testWidgets('in eraser mode the pen tip erases', (tester) async {
      await pumpPage(tester);
      await stroke(tester);
      expect(ink.ink.strokesOn(1), hasLength(1));
      tools.value = tools.value.copyWith(mode: PenMode.eraser);
      await stroke(tester);
      expect(ink.ink.strokesOn(1), isEmpty);
    });

    testWidgets('eraser outline shows only while the pen erases', (
      tester,
    ) async {
      tools.value = tools.value.copyWith(mode: PenMode.eraser, eraserSize: 8);
      await pumpPage(tester);
      final paint = find.descendant(
        of: find.byType(PageInkLayer),
        matching: find.byType(CustomPaint),
      ); // the last is the layer for the pen's current action
      final at = tester.getTopLeft(find.byType(PageInkLayer));
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.addPointer(location: at + const Offset(40, 40));
      await g.moveTo(at + const Offset(60, 60)); // hovering, not touching
      await tester.pump();
      expect(tester.renderObject(paint.last), isNot(paints..circle()));
      await g.down(at + const Offset(60, 60)); // touching: erasing
      await g.moveTo(at + const Offset(70, 60));
      await tester.pump();
      expect(
        tester.renderObject(paint.last),
        paints..circle(x: 70, y: 60, radius: 8),
      );
      await g.up(); // lifted: gone straight away
      await tester.pump();
      expect(tester.renderObject(paint.last), isNot(paints..circle()));
      await g.removePointer();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('no eraser outline while hovering with the pen tool', (
      tester,
    ) async {
      await pumpPage(tester);
      final paint = find.descendant(
        of: find.byType(PageInkLayer),
        matching: find.byType(CustomPaint),
      );
      final at = tester.getTopLeft(find.byType(PageInkLayer));
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.addPointer(location: at + const Offset(40, 40));
      await g.moveTo(at + const Offset(60, 60));
      await tester.pump();
      expect(tester.renderObject(paint.last), isNot(paints..circle()));
      await g.removePointer();
    });
  });
}
