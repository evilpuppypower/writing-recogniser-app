import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/viewer/arrange_pages_screen.dart';
import 'package:writing_recogniser/viewer/export_options_dialog.dart';

void main() {
  testWidgets('pages can be left out, and blank pages added', (tester) async {
    late Future<List<int?>?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = arrangePages(context, pageCount: 3),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Arrange pages (3)'), findsOneWidget);
    // Leave page 1 out, add a blank page after page 2.
    await tester.tap(find.byTooltip('Leave this page out').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add a blank page after this one').first);
    await tester.pumpAndSettle();
    expect(find.text('Blank page'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result, [2, null, 3]);
  });

  testWidgets('the export dialog offers arranging, and needs it done', (
    tester,
  ) async {
    late Future<ExportChoice?> choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                choice = showExportOptions(context, pageCount: 2, share: false),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Arrange pages'));
    await tester.tap(find.text('Arrange pages'));
    await tester.pumpAndSettle();
    // Not arranged yet: says so instead of exporting.
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Arrange the pages first.'), findsOneWidget);
    await tester.ensureVisible(find.text('Arrange…'));
    await tester.tap(find.text('Arrange…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Leave this page out').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Arranged: 1 page (change)'), findsOneWidget);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    final c = (await choice)!;
    expect(c.pageOrder, [2]);
    expect(c.pages, isNull);
  });
}
