import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/viewer/export_options_dialog.dart';

void main() {
  /// Opens the dialog; returns what it will give back when closed.
  Future<Future<ExportChoice?>> open(WidgetTester tester) async {
    late Future<ExportChoice?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showExportOptions(
              context,
              pageCount: 12,
              share: false,
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
    await tester.enterText(find.byType(TextField), '2-4, 9');
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
}
