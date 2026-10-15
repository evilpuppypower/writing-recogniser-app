import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/bookmarks.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_bookmark_store.dart';
import 'package:writing_recogniser/storage/sqlite_ink_store.dart';
import 'package:writing_recogniser/viewer/contents_sheet.dart';

void main() {
  test(
    'bookmarks are kept per PDF, first page first, and go with it',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      final store = SqliteBookmarkStore(db);
      await store.set('a', 12, on: true);
      await store.set('a', 3, on: true);
      await store.set('b', 5, on: true);
      expect(await store.pages('a'), [3, 12]);
      await store.set('a', 12, on: false);
      expect(await store.pages('a'), [3]);
      // Deleting the PDF's stored copy removes its bookmarks too.
      await SqliteInkStore(db).deleteDocument('a');
      expect(await store.pages('a'), isEmpty);
      expect(await store.pages('b'), [5]);
    },
  );

  test('the in-memory store works the same', () async {
    final store = MemoryBookmarkStore();
    await store.set('a', 7, on: true);
    await store.set('a', 2, on: true);
    expect(await store.pages('a'), [2, 7]);
  });

  testWidgets('the contents sheet lists bookmarks and the PDF\'s contents', (
    tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showModalBottomSheet<int>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const ContentsSheet(
                bookmarks: [4],
                outline: [
                  PdfOutlineNode(
                    title: 'Chapter 1',
                    dest: PdfDest(2, PdfDestCommand.fit, null),
                    children: [
                      PdfOutlineNode(
                        title: 'Section 1.1',
                        dest: PdfDest(3, PdfDestCommand.fit, null),
                        children: [],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Page 4'), findsOneWidget);
    expect(find.text('Section 1.1'), findsOneWidget);
    await tester.tap(find.text('Section 1.1'));
    await tester.pumpAndSettle();
    expect(picked, 3);
  });
}
