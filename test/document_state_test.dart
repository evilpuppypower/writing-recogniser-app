import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/document_state.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_document_store.dart';

void main() {
  sqfliteFfiInit();

  DocumentState state(String id, int page, {int pages = 450}) => DocumentState(
    id: id,
    lastPage: page,
    pageCount: pages,
    updatedAt: DateTime(2026, 1, 1, 9, page % 60),
  );

  group('reopening where the user left off', () {
    test('resumes at the saved page', () {
      expect(state('a', 120).resumePageFor(450), 120);
    });

    test('stays inside a file that now has fewer pages', () {
      expect(state('a', 120).resumePageFor(80), 80);
      expect(state('a', 0).resumePageFor(80), 1);
      expect(state('a', 5).resumePageFor(0), 1);
    });
  });

  group('Go to page input', () {
    test('accepts pages of the document', () {
      expect(parsePageNumber('1', 450), 1);
      expect(parsePageNumber(' 450 ', 450), 450);
    });

    test('rejects anything else', () {
      for (final text in ['', '0', '451', '-3', '12a', '3.5']) {
        expect(parsePageNumber(text, 450), isNull, reason: text);
      }
    });
  });

  group('SQLite store', () {
    test('saves, replaces and lists positions', () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final store = SqliteDocumentStore(db);
      expect(await store.get('a'), isNull);
      await store.save(state('a', 12));
      await store.save(state('a', 30));
      await store.save(state('b', 2, pages: 9));
      final a = await store.get('a');
      expect(a!.lastPage, 30);
      expect(a.pageCount, 450);
      expect(a.updatedAt, DateTime(2026, 1, 1, 9, 30));
      expect((await store.all()).keys, unorderedEquals(['a', 'b']));
      await db.close();
    });

    test(
      'upgrading a version 2 database keeps data and adds documents',
      () async {
        final dir = await Directory.systemTemp.createTemp('wr_db');
        final path = '${dir.path}/v2.db';
        final old = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, _) async {
              await db.execute(
                'CREATE TABLE samples (id INTEGER PRIMARY KEY, text TEXT)',
              );
              await db.insert('samples', {'text': 'kept'});
            },
          ),
        );
        await old.close();
        final db = await AppDatabase.open(
          factory: databaseFactoryFfi,
          path: path,
        );
        expect((await db.query('samples')).single['text'], 'kept');
        await SqliteDocumentStore(db).save(state('a', 3));
        expect((await SqliteDocumentStore(db).get('a'))!.lastPage, 3);
        await db.close();
        await dir.delete(recursive: true);
      },
    );
  });
}
