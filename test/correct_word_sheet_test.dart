import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/viewer/correct_word_sheet.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/page_text_labels.dart';

import 'ink_text_controller_test.dart' show FakeEngine, word;

const _w = RecognizedWord(
  text: 'for',
  alternatives: ['fox', 'far'],
  box: InkBox(100, 700, 120, 710),
  line: 0,
  key: 'k',
);

Future<WordFix?> _open(WidgetTester tester, RecognizedWord w) async {
  WordFix? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await showCorrectWordSheet(context, w),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('tap an alternative', (tester) async {
    WordFix? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                got = await showCorrectWordSheet(context, _w),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Read as “for”'), findsOneWidget);
    await tester.tap(find.text('fox'));
    await tester.pumpAndSettle();
    expect(got, isA<UseText>().having((f) => f.text, 'text', 'fox'));
  });

  testWidgets('type the right word, or say it is not writing', (tester) async {
    WordFix? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                got = await showCorrectWordSheet(context, _w),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' fax ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(got, isA<UseText>().having((f) => f.text, 'text', 'fax'));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("This isn't writing"));
    await tester.pumpAndSettle();
    expect(got, isA<NotWriting>());
  });

  testWidgets('a word with a "?" can be said to be right', (tester) async {
    const unsure = RecognizedWord(
      text: 'gneiss',
      alternatives: ['guess'],
      box: InkBox(100, 700, 120, 710),
      line: 0,
      key: 'k',
      unsure: true,
    );
    WordFix? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                got = await showCorrectWordSheet(context, unsure),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not sure about this one'), findsOneWidget);
    await tester.tap(find.text("It's right: “gneiss”"));
    await tester.pumpAndSettle();
    expect(got, isA<LooksRight>());
    // Not offered for words it's sure of.
    await _open(tester, _w);
    expect(find.textContaining("It's right"), findsNothing);
  });

  testWidgets('a swap to one of the user\'s words says so', (tester) async {
    const swapped = RecognizedWord(
      text: 'basalt',
      alternatives: ['basel'],
      box: InkBox(100, 700, 120, 710),
      line: 0,
      key: 'k',
      engineText: 'basel',
      autoReplaced: true,
      fromYourWords: true,
    );
    await _open(tester, swapped);
    expect(find.textContaining('a word you often write'), findsOneWidget);
  });

  testWidgets('an automatic swap can be undone', (tester) async {
    const swapped = RecognizedWord(
      text: 'fox',
      alternatives: ['for'],
      box: InkBox(100, 700, 120, 710),
      line: 0,
      key: 'k',
      engineText: 'for',
      autoReplaced: true,
    );
    await _open(tester, swapped);
    expect(find.textContaining('Changed automatically'), findsOneWidget);
    expect(find.text('Undo: use “for”'), findsOneWidget);
  });

  testWidgets('double-tapping a label with a finger opens the correction', (
    tester,
  ) async {
    final c = InkTextController(engine: FakeEngine());
    final strokes = word(100, 700, 3, 0);
    RecognizedWord? tapped;
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
              onDoubleTap: (w) => tapped = w,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('w3'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('w3'));
    await tester.pumpAndSettle();
    expect(tapped?.text, 'w3');
    c.dispose();
  });

  testWidgets('a word it isn\'t sure of shows "?", and one tap asks', (
    tester,
  ) async {
    final c = InkTextController(engine: FakeEngine());
    final strokes = word(100, 700, 3, 0);
    c.inkChanged(1, strokes, const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    RecognizedWord? tapped;
    Future<void> show({required bool ask}) => tester.pumpWidget(
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
              showUnsure: ask,
              onDoubleTap: (w) => tapped = w,
            ),
          ),
        ),
      ),
    );
    await show(ask: true);
    await tester.pumpAndSettle();
    expect(find.text(' ?'), findsOneWidget);
    await tester.tap(find.text(' ?'));
    // Past the wait for a second tap (a double-tap).
    await tester.pump(const Duration(milliseconds: 400));
    expect(tapped?.text, 'w3');
    // Turned off in Settings: no "?".
    await show(ask: false);
    await tester.pumpAndSettle();
    expect(find.text(' ?'), findsNothing);
    c.dispose();
  });
}
