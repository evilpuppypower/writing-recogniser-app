import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_correction_store.dart';

void main() {
  sqfliteFfiInit();

  late Database db;
  late SqliteCorrectionStore store;
  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    store = SqliteCorrectionStore(db);
  });
  tearDown(() => db.close());

  CorrectionRecord fix(String from, String to, int minute) => CorrectionRecord(
    recognized: from,
    corrected: to,
    previousWord: 'quick brown',
    strokes: [
      InkStroke([InkPoint(1, 2, 1000, 0.4), InkPoint(3, 4, 1010, 0.6)]),
    ],
    at: DateTime(2026, 10, 11, 12, minute),
    scope: minute == 3 ? CorrectionScope.document : CorrectionScope.global,
    documentId: minute == 3 ? 'doc-1' : null,
  );

  test('keeps every field rule 4 asks for, including the strokes', () async {
    await store.add(fix('for', 'fox', 1));
    final c = (await store.all()).single;
    expect(c.recognized, 'for');
    expect(c.corrected, 'fox');
    expect(c.previousWord, 'quick brown');
    expect(c.at, DateTime(2026, 10, 11, 12, 1));
    expect(c.count, 1);
    final p = c.strokes.single.points;
    expect([p[1].x, p[1].y, p[1].t, p[1].pressure], [3, 4, 1010, 0.6]);
  });

  test('counts repeats of the same correction, oldest first', () async {
    await store.add(fix('for', 'fox', 1));
    await store.add(fix('far', 'fox', 2));
    await store.add(fix('For', 'fox', 3));
    final all = await store.all();
    expect([for (final c in all) c.count], [1, 1, 2]);
    expect(all.last.scope, CorrectionScope.document);
    expect(all.last.documentId, 'doc-1');
  });
}
