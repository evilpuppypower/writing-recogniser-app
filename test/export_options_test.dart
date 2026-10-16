import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/typed_text.dart';
import 'package:writing_recogniser/viewer/export_options_dialog.dart';

void main() {
  /// Opens the dialog; returns what it will give back when closed.
  Future<Future<ExportChoice?>> open(
    WidgetTester tester, {
    ExportHandwriting startWith = ExportHandwriting.ink,
    bool anyConverted = false,
    bool anyUnconverted = false,
    bool? convertRest,
    bool darkNow = false,
    bool pagesChanged = false,
  }) async {
    late Future<ExportChoice?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showExportOptions(
              context,
              pageCount: 12,
              share: false,
              startWith: startWith,
              anyConverted: anyConverted,
              anyUnconverted: anyUnconverted,
              convertRest: convertRest,
              darkNow: darkNow,
              pagesChanged: pagesChanged,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('searchable, all pages is the default', (tester) async {
    final choice = await open(tester);
    expect(find.text('Make handwriting searchable'), findsOneWidget);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    final c = await choice;
    expect(c!.searchable, isTrue);
    expect(c.pages, isNull);
  });

  testWidgets('says, in place, what picked pages leave out', (tester) async {
    await open(tester);
    final note = find.textContaining('contents list and fill-in form boxes');
    expect(note, findsNothing, reason: 'all pages keep everything');
    await tester.tap(find.text('Only some pages'));
    await tester.pumpAndSettle();
    expect(note, findsOneWidget);
    // No box to click through: the dialog is still the only one.
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('and when pages were added or moved, for all pages too', (
    tester,
  ) async {
    await open(tester, pagesChanged: true);
    expect(find.textContaining('added, moved or taken out'), findsOneWidget);
  });

  testWidgets('dark pages: starts as on screen, and can be switched', (
    tester,
  ) async {
    var choice = await open(tester);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect((await choice)!.darkPages, isFalse);
    choice = await open(tester, darkNow: true);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect((await choice)!.darkPages, isTrue);
    choice = await open(tester, darkNow: true);
    await tester.tap(find.text('Dark pages'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect((await choice)!.darkPages, isFalse);
  });

  testWidgets('only some pages: the typed pages, or a message if wrong', (
    tester,
  ) async {
    final choice = await open(tester);
    await tester.tap(find.text('Only some pages'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '2-4, 30');
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't in this PDF (1-12)"), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2 – 4, 9');
    await tester.pump();
    // Says which pages go in before exporting.
    expect(find.text('Exports pages 2–4, 9 (4 of 12).'), findsOneWidget);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    final c = await choice;
    expect(c!.pages, {2, 3, 4, 9});
  });

  testWidgets('searchable off still lets you pick pages; Cancel gives null', (
    tester,
  ) async {
    var choice = await open(tester);
    await tester.tap(find.text('Make handwriting searchable'));
    await tester.pumpAndSettle();
    expect(find.text('All pages'), findsOneWidget, reason: 'pages stay');
    await tester.tap(find.text('Only some pages'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    final c = await choice;
    expect(c!.searchable, isFalse);
    expect(c.pages, {3});

    choice = await open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await choice, isNull);
  });

  testWidgets('converted handwriting: ink, typed text or both (2.3d)', (
    tester,
  ) async {
    var choice = await open(tester);
    expect(find.text('Handwriting'), findsNothing);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect((await choice)!.handwriting, ExportHandwriting.ink);

    choice = await open(
      tester,
      startWith: ExportHandwriting.typed,
      anyConverted: true,
    );
    expect(find.text('Handwriting'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing, reason: 'all done');
    await tester.tap(find.text(ExportHandwriting.both.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    final c = (await choice)!;
    expect(c.handwriting, ExportHandwriting.both);
    expect(c.convertRest, isFalse);
  });

  testWidgets('typed text can also convert the rest (owner\'s choice 1b)', (
    tester,
  ) async {
    // Nothing converted yet: the choice is still offered, and ticked.
    var choice = await open(tester, anyUnconverted: true);
    expect(find.text('Handwriting'), findsOneWidget);
    final tick = find.text("Also convert handwriting I haven't converted");
    expect(tick, findsNothing, reason: 'not for "My handwriting"');
    await tester.ensureVisible(find.text(ExportHandwriting.typed.label));
    await tester.tap(find.text(ExportHandwriting.typed.label));
    await tester.pumpAndSettle();
    expect(tick, findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    var c = (await choice)!;
    expect((c.handwriting, c.convertRest), (ExportHandwriting.typed, true));

    // Some converted, some not: unticked to start with.
    choice = await open(
      tester,
      startWith: ExportHandwriting.typed,
      anyConverted: true,
      anyUnconverted: true,
    );
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    await tester.ensureVisible(tick);
    await tester.pumpAndSettle();
    await tester.tap(tick);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    c = (await choice)!;
    expect(c.convertRest, isTrue);
  });

  testWidgets('the "Also convert" tick is remembered', (tester) async {
    // Last time it was unticked: starts unticked even with nothing
    // converted.
    var choice = await open(
      tester,
      startWith: ExportHandwriting.typed,
      anyUnconverted: true,
      convertRest: false,
    );
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    var c = (await choice)!;
    expect((c.convertRest, c.askedConvertRest), (false, true));

    // Not asked for "My handwriting": nothing to remember.
    choice = await open(tester, anyUnconverted: true, convertRest: true);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    c = (await choice)!;
    expect(c.askedConvertRest, isFalse);
  });
}
