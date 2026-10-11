import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_event_log.dart';

void main() {
  sqfliteFfiInit();

  test('logs recognitions with engine, latency and details', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final log = SqliteEventLog(db);
    await log.log(
      LoggedEvent(
        type: 'recognition',
        at: DateTime(2026, 10, 11, 9, 30),
        engine: 'ML Kit',
        latencyMs: 912,
        data: {'top': 'hello', 'strokes': 4},
      ),
    );
    await log.log(LoggedEvent(type: 'other', at: DateTime(2026)));
    final events = await log.ofType('recognition');
    expect(events, hasLength(1));
    final e = events.single;
    expect(e.engine, 'ML Kit');
    expect(e.latencyMs, 912);
    expect(e.at, DateTime(2026, 10, 11, 9, 30));
    expect(e.data, {'top': 'hello', 'strokes': 4});
    await db.close();
  });

  test(
    'upgrading a version 1 database keeps samples and adds events',
    () async {
      final dir = await Directory.systemTemp.createTemp('wr_db_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/test.db';

      // A database as the previous app version created it.
      final v1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE samples (id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'text TEXT NOT NULL, strokes TEXT NOT NULL, '
              'created_at INTEGER NOT NULL, canvas_width REAL, '
              'canvas_height REAL)',
            );
            await db.insert('samples', {
              'text': 'kept',
              'strokes': '[]',
              'created_at': 0,
            });
          },
        ),
      );
      await v1.close();

      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      expect(await db.getVersion(), AppDatabase.version);
      expect((await db.query('samples')).single['text'], 'kept');
      await SqliteEventLog(db).log(LoggedEvent(type: 'x', at: DateTime(2026)));
      expect(await SqliteEventLog(db).ofType('x'), hasLength(1));
      await db.close();
    },
  );
}
