import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/pen_tap.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/page_text_labels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PenTapRules', () {
    const rules = PenTapRules();

    test('a short touch that barely moves is a tap; writing is not', () {
      expect(rules.isTap(2, 80), isTrue);
      expect(rules.isTap(20, 80), isFalse, reason: 'moved: writing');
      expect(rules.isTap(2, 600), isFalse, reason: 'held: writing');
    });

    test('two taps close in time and place make a double-tap', () {
      const first = PenTap(100, 100, 1000, 1080);
      expect(rules.isDouble(first, const PenTap(104, 98, 1250, 1320)), isTrue);
      expect(
        rules.isDouble(first, const PenTap(104, 98, 1700, 1760)),
        isFalse,
        reason: 'too slow',
      );
      expect(
        rules.isDouble(first, const PenTap(160, 100, 1250, 1320)),
        isFalse,
        reason: 'too far apart',
      );
    });
  });

  group('pen double-tap on the ink layer', () {
    late DocumentInkController ink;
    late int actions;

    // A label-like hot spot: a double-tap there runs the action.
    final hotSpot = Rect.fromLTWH(80, 80, 60, 30);

    Future<void> pump(WidgetTester tester) async {
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
                doubleTapActionAt: (at) =>
                    hotSpot.contains(at) ? () => actions++ : null,
              ),
            ),
          ),
        ),
      );
    }

    setUp(() {
      ink = DocumentInkController();
      actions = 0;
    });

    Future<void> tap(WidgetTester tester, Offset at) async {
      final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await pen.down(at);
      await tester.pump(const Duration(milliseconds: 30));
      await pen.up();
      await tester.pump(const Duration(milliseconds: 60));
    }

    int strokes() => ink.ink.strokesOn(1).length;

    testWidgets('two quick taps on a label run its action and draw nothing', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, const Offset(100, 90));
      await tap(tester, const Offset(103, 92));
      expect(actions, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(strokes(), 0, reason: 'no dots left behind');
    });

    testWidgets('a single tap on a label is still drawn, just a moment later', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, const Offset(100, 90));
      expect(strokes(), 0, reason: 'held back in case a second tap follows');
      await tester.pump(const Duration(milliseconds: 700));
      expect(strokes(), 1);
      expect(actions, 0);
    });

    testWidgets('taps away from labels are drawn straight away', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, const Offset(250, 300));
      await tap(tester, const Offset(252, 300));
      expect(strokes(), 2);
      expect(actions, 0);
    });

    testWidgets('writing across a label is drawn, not taken as a tap', (
      tester,
    ) async {
      await pump(tester);
      final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await pen.down(const Offset(90, 90));
      for (var i = 0; i < 6; i++) {
        await pen.moveBy(const Offset(8, 1));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pen.up();
      await tester.pump();
      expect(strokes(), 1);
      expect(actions, 0);
    });

    testWidgets('a held tap is drawn before the next stroke, keeping order', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, const Offset(100, 90)); // held
      await tap(tester, const Offset(250, 300)); // elsewhere: drawn now
      expect(strokes(), 2);
      final ys = ink.ink.strokesOn(1).map((s) => s.points.first.y).toList();
      expect(ys.first, greaterThan(ys.last), reason: 'label dot first');
    });
  });

  group('wordAtLabel', () {
    // A word 100-200 pt across, 600-620 pt up a US Letter page, shown at
    // 1 px per pt: on screen it spans x 100-200, y 172-192.
    final geometry = PageGeometry(width: 612, height: 792);
    final word = RecognizedWord(
      text: 'hello',
      alternatives: const [],
      box: const InkBox(100, 600, 200, 620),
      line: 0,
    );

    RecognizedWord? at(Offset p, {bool above = true}) =>
        PageTextLabels.wordAtLabel(
          [word],
          p,
          geometry: geometry,
          viewWidth: 612,
          above: above,
        );

    test('finds the word from a point on its label', () {
      expect(at(const Offset(110, 165)), same(word), reason: 'label above');
      expect(at(const Offset(110, 198), above: false), same(word));
    });

    test('misses points away from the label', () {
      expect(at(const Offset(110, 120)), isNull);
      expect(at(const Offset(400, 165)), isNull);
    });
  });
}
