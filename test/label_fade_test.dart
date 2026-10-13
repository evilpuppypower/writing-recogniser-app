import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/label_fade.dart';
import 'package:writing_recogniser/viewer/page_text_labels.dart';

import 'ink_text_controller_test.dart' show FakeEngine, word;

void main() {
  testWidgets('labels fade 5 s after the last wake, and come back', (
    tester,
  ) async {
    final fade = LabelFade();
    expect(fade.value, isTrue);
    await tester.pump(const Duration(seconds: 4));
    fade.wake(); // writing again: the 5 s start over
    await tester.pump(const Duration(seconds: 4));
    expect(fade.value, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(fade.value, isFalse);
    fade.wake();
    expect(fade.value, isTrue);
    fade.dispose();
  });

  testWidgets('faded labels are invisible and let touches through', (
    tester,
  ) async {
    final c = InkTextController(engine: FakeEngine());
    final strokes = word(100, 700, 3, 0);
    final shown = LabelFade();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 306,
            height: 396,
            child: PageTextLabels(
              pageNumber: 1,
              geometry: PageGeometry(width: 612, height: 792),
              viewWidth: 306,
              text: c,
              strokes: () => strokes,
              shown: shown,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double opacity() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
    expect(find.text('w3'), findsOneWidget);
    expect(opacity(), 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(opacity(), 0);
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byType(AnimatedOpacity),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );
    shown.wake();
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    shown.dispose();
    c.dispose();
  });
}
