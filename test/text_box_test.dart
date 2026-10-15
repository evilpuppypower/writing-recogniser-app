import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_export_plan.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/core/typed_text.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/pdf_viewer_screen.dart'
    show TextBoxDialog;

void main() {
  final box = textBox(
    'Hello\nthere',
    100,
    700,
    size: 10,
    colorArgb: 0xFF0D47A1,
    nowMs: 5000,
  );

  test('a text box: its corners, size and text; never read as writing', () {
    expect(box.isTextBox, isTrue);
    expect(box.points.first.x, 100);
    expect(box.points.first.y, 700);
    expect(box.points.last.y, closeTo(700 - 2 * 12.5, 1e-9), reason: '2 lines');
    expect(box.width, 10);
    expect(isWriting(box), isFalse);
    expect(groupStrokes([box]), isEmpty);
    // Hit anywhere in the box, near it, but not far off.
    expect(box.distanceTo(110, 690), 0);
    expect(box.distanceTo(100, 705), closeTo(5, 1e-9));
    // Saved and loaded as it was.
    final back = PageStroke.fromJson(box.toJson());
    expect(back.isTextBox, isTrue);
    expect(back.typedText, 'Hello\nthere');
  });

  test('erasing over a text box takes it whole', () {
    final ink = DocumentInk()..add(1, box);
    expect(ink.eraseArea(1, 110, 690, 3), isTrue);
    expect(ink.strokesOn(1), isEmpty);
  });

  test('exported as text, one line each at its size; not as ink lines', () {
    expect(exportLines([box]), isEmpty);
    final words = textBoxesForExport([box]);
    expect(words.map((w) => w.text), ['Hello', 'there']);
    expect(words.first.fontSize, 10);
    expect(typedSizeOnPage(words.first, 1), 10, reason: 'fixed size');
    expect(words.first.top, 700);
    expect(words.last.top, closeTo(687.5, 1e-9));
    final back = ExportWord.fromMessage(words.first.toMessage());
    expect(back.fixedSize, isTrue);
  });

  testWidgets('the Text tool: a pen tap asks for a text box there', (
    tester,
  ) async {
    final taps = <PdfPagePoint>[];
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
              controller: DocumentInkController(),
              tools: ValueNotifier(const PenToolsState(mode: PenMode.text)),
              onTextTap: taps.add,
            ),
          ),
        ),
      ),
    );
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(const Offset(100, 92));
    await pen.up();
    await tester.pump();
    expect(taps.single.x, closeTo(100, 0.01));
    expect(taps.single.y, closeTo(700, 0.01));
    // A drag isn't a tap.
    await pen.down(const Offset(200, 200));
    await pen.moveTo(const Offset(260, 200));
    await pen.up();
    await tester.pump();
    expect(taps, hasLength(1));
  });

  testWidgets('the text box dialog gives the text and size', (tester) async {
    ({String text, double size})? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => got = await showDialog(
              context: context,
              builder: (_) =>
                  const TextBoxDialog(text: '', size: 12, editing: false),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Note');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(got?.text, 'Note');
    expect(got?.size, 12);
  });
}
