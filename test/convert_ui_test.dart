import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart' show InkBox;
import 'package:writing_recogniser/core/typed_text.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/page_typed_text.dart';

import 'typed_text_test.dart' show letter;

void main() {
  group('lasso selection (task 2.3c)', () {
    // A square loop around (100..200, 600..700) in PDF points.
    const loop = [
      PageInkPoint(100, 600, 0),
      PageInkPoint(200, 600, 0),
      PageInkPoint(200, 700, 0),
      PageInkPoint(100, 700, 0),
    ];

    test('inside or outside the loop', () {
      expect(insideLoop(loop, 150, 650), isTrue);
      expect(insideLoop(loop, 250, 650), isFalse);
    });

    test('takes strokes mostly inside, not ones it clips', () {
      final inside = letter(140, 640, 0);
      final clipped = letter(198, 640, 1000); // 2 of 3 points outside
      final outside = letter(300, 640, 2000);
      final picked = strokesInLoop([inside, clipped, outside], loop);
      expect(picked, {inside.id});
    });

    testWidgets('the lasso tool selects instead of drawing', (tester) async {
      final ink = DocumentInkController();
      List<PageInkPoint>? drawn;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 306,
              height: 396,
              child: PageInkLayer(
                pageNumber: 1,
                geometry: PageGeometry(width: 612, height: 792),
                viewWidth: 306,
                controller: ink,
                tools: ValueNotifier(const PenToolsState(mode: PenMode.lasso)),
                onLasso: (l) => drawn = l,
              ),
            ),
          ),
        ),
      );
      final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await pen.down(const Offset(50, 50));
      for (final p in const [
        Offset(150, 50),
        Offset(150, 150),
        Offset(50, 150),
      ]) {
        await pen.moveTo(p);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pen.up();
      await tester.pump();
      expect(drawn, isNotNull);
      expect(drawn!.length, greaterThanOrEqualTo(4));
      expect(ink.ink.strokesOn(1), isEmpty, reason: 'no ink drawn');
    });

    testWidgets('a pen tap on typed text runs its action, no dot', (
      tester,
    ) async {
      final ink = DocumentInkController();
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 306,
              height: 396,
              child: PageInkLayer(
                pageNumber: 1,
                geometry: PageGeometry(width: 612, height: 792),
                viewWidth: 306,
                controller: ink,
                tapActionAt: (at) => at.dx < 100 ? () => taps++ : null,
              ),
            ),
          ),
        ),
      );
      Future<void> tap(Offset at) async {
        final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
        await pen.down(at);
        await tester.pump(const Duration(milliseconds: 30));
        await pen.up();
        await tester.pump();
      }

      await tap(const Offset(50, 50));
      expect(taps, 1);
      expect(ink.ink.strokesOn(1), isEmpty);
      await tap(const Offset(200, 50)); // elsewhere: a dot
      expect(ink.ink.strokesOn(1), hasLength(1));
    });

    test('the lasso is drawn dotted, closed back to the start', () {
      // An L-shaped path 20 + 10 px long, then back to the start (~22 px).
      const path = [Offset(0, 0), Offset(20, 0), Offset(20, 10), Offset(0, 0)];
      final d = dashes(path, dash: 6, gap: 4);
      // 6 on, 4 off along the first side: dashes at 0..6, 10..16.
      expect(d[0], (const Offset(0, 0), const Offset(6, 0)));
      expect(d[1], (const Offset(10, 0), const Offset(16, 0)));
      // The dash at 20 starts on the corner and runs down the second side.
      expect(d[2], (const Offset(20, 0), const Offset(20, 6)));
      // Some dashes are on the closing line.
      expect(d.where((s) => s.$1.dy < 10 && s.$1.dx < 20), isNotEmpty);
      final drawn = d.fold(0.0, (t, s) => t + (s.$2 - s.$1).distance);
      final total = 30 + const Offset(20, 10).distance;
      expect(drawn, closeTo(total * 0.6, 4), reason: '6 of every 10 px');
    });

    test('the lasso is not remembered as the tool for next time', () {
      final saved = const PenToolsState(mode: PenMode.lasso).toJson();
      expect(PenToolsState.fromJson(saved).mode, PenMode.pen);
    });
  });

  group('typed text on the page (task 2.3c)', () {
    late DocumentInkController ink;
    late ValueNotifier<bool> showTyped;

    Future<void> pump(WidgetTester tester) async {
      ink = DocumentInkController();
      final cat = [letter(100, 700, 0), letter(107, 700, 200)];
      for (final s in cat) {
        ink.add(1, s);
      }
      ink.convert(1, {
        {for (final s in cat) s.id}: 'cat',
      });
      showTyped = ValueNotifier(true);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 612,
              height: 792,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: PageTypedText(
                      pageNumber: 1,
                      geometry: PageGeometry(width: 612, height: 792),
                      viewWidth: 612,
                      controller: ink,
                      showTyped: showTyped,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows over the handwriting; taps find it', (tester) async {
      await pump(tester);
      expect(find.text('cat'), findsOneWidget);
      final at = tester.getTopLeft(find.text('cat'));
      expect(at.dx, closeTo(100, 1));
      // PDF y 700..710 is screen y 82..92 at 1 px per point.
      final geometry = PageGeometry(width: 612, height: 792);
      final strokes = ink.ink.strokesOn(1);
      expect(
        typedLineAt(strokes, const Offset(105, 87), geometry, 612)?.text,
        'cat',
      );
      expect(
        typedLineAt(strokes, const Offset(300, 87), geometry, 612),
        isNull,
      );
    });

    test('text size on a page turned sideways follows the screen', () {
      // Written across the screen of a page turned 90°: tall on the page.
      const box = InkBox(100, 500, 120, 600);
      final upright = PageGeometry(width: 612, height: 792);
      final sideways = PageGeometry(width: 612, height: 792, quarterTurns: 1);
      expect(
        shownFontSize('hello', box, upright),
        lessThan(shownFontSize('hello', box, sideways)),
      );
      expect(shownFontSize('hello', box, sideways), 16, reason: '80% of 20 pt');
    });

    testWidgets('hidden while the handwriting is shown', (tester) async {
      await pump(tester);
      showTyped.value = false;
      await tester.pump();
      expect(find.text('cat'), findsNothing);
      showTyped.value = true;
      await tester.pump();
      expect(find.text('cat'), findsOneWidget);
    });

    testWidgets('follows edits and undo', (tester) async {
      await pump(tester);
      final group = typedWords(ink.ink.strokesOn(1)).single.group;
      ink.setTypedText(1, group, 'cart');
      await tester.pump();
      expect(find.text('cart'), findsOneWidget);
      ink.undo();
      await tester.pump();
      expect(find.text('cat'), findsOneWidget);
      ink.undo();
      await tester.pump();
      expect(find.text('cat'), findsNothing, reason: 'conversion undone');
    });
  });
}
