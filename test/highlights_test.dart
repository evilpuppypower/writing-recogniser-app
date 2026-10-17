import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/highlights.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/viewer/highlights_sheet.dart';

/// [text] printed on one line at height [y], 6 points a character.
List<PrintedChar> line(String text, double y, {double x0 = 50}) => [
  for (var i = 0; i < text.length; i++)
    (char: text[i], box: InkBox(x0 + i * 6, y, x0 + i * 6 + 5, y + 10)),
];

PageStroke marker(double x1, double x2, double y) => PageStroke(
  tool: InkTool.highlighter,
  width: 12,
  points: [PageInkPoint(x1, y, 0), PageInkPoint(x2, y, 1)],
);

void main() {
  test('highlighted words, made out to whole words', () {
    final chars = line('The cell wall holds water', 100);
    // Over "ell wa" (characters 5..10): becomes "cell wall".
    final h = highlightedText([marker(50 + 5 * 6, 50 + 10 * 6, 105)], chars);
    expect(h, ['cell wall']);
  });

  test('pen strokes and strokes elsewhere are not highlights', () {
    final chars = line('The cell wall', 100);
    final pen = PageStroke(
      points: [PageInkPoint(50, 105, 0), PageInkPoint(120, 105, 1)],
    );
    expect(highlightedText([pen], chars), isEmpty);
    expect(highlightedText([marker(50, 120, 300)], chars), isEmpty);
  });

  test('two lines highlighted are two passages, in reading order', () {
    final chars = [
      ...line('First line here', 200),
      (char: '\n', box: const InkBox(0, 0, 0, 0)),
      ...line('Second line too', 180),
    ];
    final h = highlightedText([
      marker(50, 50 + 4 * 6, 205),
      marker(50, 50 + 5 * 6, 185),
    ], chars);
    expect(h, ['First', 'Second']);
  });

  test('a note with the printed line it is next to', () {
    final printed = printedLines([
      ...line('Osmosis moves water', 300),
      ...line('Diffusion moves gas', 200),
    ]);
    expect(printed.first.text, 'Osmosis moves water');
    final notes = notesNextToPrint([
      (text: 'exam!', box: const InkBox(400, 198, 440, 212)),
      (text: 'far away', box: const InkBox(400, 20, 440, 34)),
    ], printed);
    expect(notes[0], (note: 'exam!', nextTo: 'Diffusion moves gas'));
    expect(notes[1].nextTo, isNull);
  });

  test('as text to copy or save', () {
    final text = highlightsText('Biology.pdf', const [
      PageHighlights(page: 1),
      PageHighlights(
        page: 3,
        highlights: ['cell wall'],
        notes: [(note: 'exam!', nextTo: 'Diffusion moves gas')],
      ),
    ]);
    expect(text, contains('Biology.pdf: highlights and notes'));
    expect(text, isNot(contains('Page 1')));
    expect(text, contains('Page 3'));
    expect(text, contains('“cell wall”'));
    expect(text, contains('Note: exam!  (next to: “Diffusion moves gas”)'));
    expect(
      highlightsText('X', const []),
      contains('Nothing highlighted or noted yet.'),
    );
  });

  testWidgets('the sheet: pages, go to, copy and save', (tester) async {
    final went = <int>[];
    var copied = false, saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HighlightsSheet(
            pages: const [
              PageHighlights(page: 1),
              PageHighlights(
                page: 4,
                highlights: ['cell wall'],
                notes: [(note: 'exam!', nextTo: 'Diffusion moves gas')],
              ),
            ],
            onGoTo: went.add,
            onCopy: () => copied = true,
            onSave: () => saved = true,
          ),
        ),
      ),
    );
    expect(find.text('Page 1'), findsNothing);
    expect(find.text('Page 4'), findsOneWidget);
    expect(find.text('Next to: “Diffusion moves gas”'), findsOneWidget);
    await tester.tap(find.text('cell wall'));
    expect(went, [4]);
    await tester.tap(find.text('Copy'));
    await tester.tap(find.text('Save'));
    expect(copied && saved, isTrue);
  });
}
