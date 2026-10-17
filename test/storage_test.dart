import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/storage_use.dart';
import 'package:writing_recogniser/core/stored_copy.dart';
import 'package:writing_recogniser/settings/storage_screen.dart';
import 'package:writing_recogniser/storage/app_database.dart';

void main() {
  sqfliteFfiInit();

  test('biggest first; empty parts left out; shares', () {
    final use = StorageUse(const [
      StoragePart('a', 100, ''),
      StoragePart('b', 0, ''),
      StoragePart('c', 300, ''),
    ]);
    expect([for (final p in use.parts) p.name], ['c', 'a']);
    expect(use.total, 400);
    expect(use.share(use.parts.first), 0.75);
  });

  test('measures PDFs, notebooks and the database by what it holds', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    await db.insert('page_ink', {
      'document_id': 'a',
      'page': 1,
      'strokes': 'x' * 1000,
      'updated_at': 0,
    });
    await db.insert('printed_text', {
      'document_id': 'a',
      'page': 1,
      'text': 'y' * 500,
    });
    final use = await measureStorage(
      db: db,
      dbPath: '/nowhere/db',
      copies: [
        StoredCopy(
          id: '1_1_A.pdf',
          size: 5000,
          lastUsed: DateTime(2026),
          pinned: true,
        ),
        StoredCopy(id: 'nb', size: 700, lastUsed: DateTime(2026), pinned: true),
      ],
      notebooks: {'nb'},
    );
    final by = {for (final p in use.parts) p.name: p.bytes};
    expect(by['Stored PDFs'], 5000);
    expect(by['Notebooks'], 700);
    expect(by['Your writing'], 1000);
    expect(by['Search index'], 500);
    expect(use.parts.first.name, 'Stored PDFs');
  });

  testWidgets('the screen: total, parts, clearing the search index', (
    tester,
  ) async {
    var cleared = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StorageScreen(
          measure: () async => StorageUse([
            const StoragePart('Stored PDFs', 3 * 1024 * 1024, 'PDFs'),
            StoragePart('Search index', cleared ? 0 : 2048, 'Index'),
          ]),
          clearSearchIndex: () async => cleared = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('This app uses 3.0 MB'), findsOneWidget);
    expect(find.text('Search index'), findsOneWidget);
    await tester.tap(find.text('Clear the search index'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(cleared, isTrue);
    expect(find.text('Search index'), findsNothing);
  });
}
