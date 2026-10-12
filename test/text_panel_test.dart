import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/page_recognition.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/text_panel.dart';

import 'ink_text_controller_test.dart' show FakeEngine, word;

void main() {
  Future<InkTextController> pump(
    WidgetTester tester,
    TextPanelPlace place, {
    ValueChanged<TextPanelPlace>? onPlace,
  }) async {
    final c = InkTextController(engine: FakeEngine());
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 800,
          child: TextPanelLayout(
            place: place,
            page: const ColoredBox(
              color: Colors.white,
              child: Center(child: Text('PDF')),
            ),
            panel: RecognisedTextPanel(
              text: c,
              page: ValueNotifier(1),
              place: place,
              onPlace: onPlace ?? (_) {},
            ),
          ),
        ),
      ),
    );
    c.ensure(1, word(100, 700, 3, 0));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('docked on the right: PDF on the left, page text on the right', (
    tester,
  ) async {
    final c = await pump(tester, TextPanelPlace.right);
    expect(find.text('w3'), findsOneWidget);
    expect(
      tester.getCenter(find.text('PDF')).dx,
      lessThan(tester.getCenter(find.text('Page 1 text')).dx),
    );
    c.dispose();
  });

  testWidgets('docked at the bottom', (tester) async {
    final c = await pump(tester, TextPanelPlace.bottom);
    expect(
      tester.getCenter(find.text('PDF')).dy,
      lessThan(tester.getCenter(find.text('Page 1 text')).dy),
    );
    c.dispose();
  });

  testWidgets('off: only the PDF', (tester) async {
    final c = await pump(tester, TextPanelPlace.off);
    expect(find.text('Page 1 text'), findsNothing);
    c.dispose();
  });

  testWidgets('floating window moves when its top strip is dragged', (
    tester,
  ) async {
    final c = await pump(tester, TextPanelPlace.floating);
    final before = tester.getTopLeft(find.text('Page 1 text'));
    await tester.dragFrom(
      before + const Offset(20, 5),
      const Offset(-200, 100),
    );
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(find.text('Page 1 text'));
    expect(after.dx, lessThan(before.dx - 150));
    expect(after.dy, greaterThan(before.dy + 50));
    c.dispose();
  });

  testWidgets('the panel can be moved or closed from its own buttons', (
    tester,
  ) async {
    TextPanelPlace? asked;
    final c = await pump(
      tester,
      TextPanelPlace.right,
      onPlace: (p) => asked = p,
    );
    await tester.tap(find.byTooltip('Close the text panel'));
    expect(asked, TextPanelPlace.off);
    await tester.tap(find.byTooltip('Move the text panel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Floating window'));
    await tester.pumpAndSettle();
    expect(asked, TextPanelPlace.floating);
    c.dispose();
  });

  testWidgets('lists hidden ink with a button to read it again (2.4d)', (
    tester,
  ) async {
    final text = InkTextController(engine: FakeEngine());
    final ink = DocumentInkController();
    for (final s in word(100, 700, 2, 0)) {
      ink.add(1, s);
    }
    final unhidden = <HiddenInk>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: RecognisedTextPanel(
            text: text,
            ink: ink,
            onUnhide: (page, h) {
              expect(page, 1);
              unhidden.add(h);
            },
            page: ValueNotifier(1),
            place: TextPanelPlace.right,
            onPlace: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('Hidden ink'), findsNothing);
    ink.markNotWriting(1, {for (final s in ink.ink.strokesOn(1)) s.id});
    await tester.pump();
    expect(find.textContaining('Hidden ink (1)'), findsOneWidget);
    await tester.tap(find.text('This is writing'));
    expect(unhidden.single.ids, hasLength(2));
    text.dispose();
  });
}
