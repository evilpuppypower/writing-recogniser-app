import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/stored_copy.dart';
import 'package:writing_recogniser/settings/settings_controller.dart';
import 'package:writing_recogniser/settings/stored_copies_screen.dart';

const mb = 1024 * 1024;

void main() {
  late List<StoredCopy> copies;
  late List<String> deleted;
  late List<(String, bool, int)> pinCalls;
  late SettingsController settings;
  late Set<String> inkIds;
  late List<String> inkDeleted;

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 2560);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsScope(
        controller: settings,
        child: MaterialApp(
          home: StoredCopiesScreen(
            listCopies: () async => copies,
            deleteCopy: (c) async {
              deleted.add(c.id);
              copies = copies.where((x) => x.id != c.id).toList();
            },
            inkDocuments: () async => inkIds,
            deleteInk: (id) async => inkDeleted.add(id),
            setPinned: (c, pinned, keep) async {
              pinCalls.add((c.id, pinned, keep));
              copies = [
                for (final x in copies)
                  x.id == c.id
                      ? StoredCopy(
                          id: x.id,
                          size: x.size,
                          lastUsed: x.lastUsed,
                          pinned: pinned,
                        )
                      : x,
              ];
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    settings = SettingsController(const AppSettings(cachedPdfLimit: 4));
    deleted = [];
    inkIds = {};
    inkDeleted = [];
    pinCalls = [];
    copies = [
      StoredCopy(
        id: '${400 * mb}_1_Textbook.pdf',
        size: 400 * mb,
        lastUsed: DateTime(2026, 10, 10, 14, 0),
        pinned: false,
      ),
      StoredCopy(
        id: '${5 * mb}_2_Lecture 3.pdf',
        size: 5 * mb,
        lastUsed: DateTime(2026, 10, 9, 10, 0),
        pinned: true,
      ),
    ];
  });

  testWidgets('lists copies, pinned first, with size, date and total', (
    tester,
  ) async {
    await pumpScreen(tester);
    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title! as Text).data)
        .toList();
    expect(titles, ['Lecture 3.pdf', 'Textbook.pdf']);
    expect(
      find.text('5.0 MB · last opened 9 Oct 2026, 10:00 · pinned'),
      findsOneWidget,
    );
    expect(
      find.text('400 MB · last opened 10 Oct 2026, 14:00'),
      findsOneWidget,
    );
    expect(find.text('Total: 405 MB for 2 copies.'), findsOneWidget);
    expect(find.textContaining('your limit of 4'), findsOneWidget);
  });

  testWidgets('pinning passes the current limit and updates the list', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Pin (always keep this copy)'));
    await tester.pumpAndSettle();
    expect(pinCalls, [('${400 * mb}_1_Textbook.pdf', true, 4)]);
    expect(find.byTooltip('Pin (always keep this copy)'), findsNothing);
  });

  testWidgets('deleting one copy asks first', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Delete this copy').last);
    await tester.pumpAndSettle();
    expect(find.text('Delete this copy?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);

    await tester.tap(find.byTooltip('Delete this copy').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, ['${400 * mb}_1_Textbook.pdf']);
    expect(find.text('Textbook.pdf'), findsNothing);
    expect(find.text('Total: 5.0 MB for 1 copy.'), findsOneWidget);
  });

  testWidgets('"Don\'t ask again" deletes and skips the question next time', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Delete this copy').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't ask again"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, ['${400 * mb}_1_Textbook.pdf']);
    expect(settings.value.confirmDeleteCopy, isFalse);

    // Next delete happens straight away, with no question.
    await tester.tap(find.byTooltip('Delete this copy'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this copy?'), findsNothing);
    expect(deleted, hasLength(2));
    expect(find.text('Deleted the copy of Lecture 3.pdf'), findsOneWidget);
  });

  testWidgets('a PDF with ink: kept by default, or deleted if ticked', (
    tester,
  ) async {
    const textbook = '${400 * mb}_1_Textbook.pdf';
    inkIds = {textbook};
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Delete this copy').last);
    await tester.pumpAndSettle();
    expect(find.text('Also delete my ink on this PDF'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, [textbook]);
    expect(inkDeleted, isEmpty);
    expect(find.textContaining('Your ink is kept'), findsOneWidget);
  });

  testWidgets('ticking "Also delete my ink" deletes it', (tester) async {
    const textbook = '${400 * mb}_1_Textbook.pdf';
    inkIds = {textbook};
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Delete this copy').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Also delete my ink on this PDF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(inkDeleted, [textbook]);
    expect(find.textContaining('and your ink on it'), findsOneWidget);
  });

  testWidgets('setting off: the box starts ticked; no ink: no box', (
    tester,
  ) async {
    settings = SettingsController(
      const AppSettings(cachedPdfLimit: 4, keepInkOnDelete: false),
    );
    inkIds = {'${400 * mb}_1_Textbook.pdf'};
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Delete this copy').last);
    await tester.pumpAndSettle();
    final box = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Also delete my ink on this PDF'),
    );
    expect(box.value, isTrue);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete this copy').first); // no ink
    await tester.pumpAndSettle();
    expect(find.text('Also delete my ink on this PDF'), findsNothing);
  });

  testWidgets('empty list says so', (tester) async {
    copies = [];
    await pumpScreen(tester);
    expect(find.text('No stored copies.'), findsOneWidget);
  });
}
