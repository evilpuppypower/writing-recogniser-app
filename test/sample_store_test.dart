import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_sample_store.dart';

void main() {
  sqfliteFfiInit();

  late Database db;
  late SqliteSampleStore store;

  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    store = SqliteSampleStore(db);
  });

  tearDown(() => db.close());

  LabeledSample sample(String text) => LabeledSample(
    text: text,
    strokes: const [
      InkStroke([
        InkPoint(1, 2, 1760000000000, 0.3),
        InkPoint(3, 4, 1760000000020, 0.6),
      ]),
    ],
    createdAt: DateTime(2026, 1, 1, 12, 0),
    canvasWidth: 1200,
    canvasHeight: 600,
  );

  test('saves and reads back samples with their strokes', () async {
    final id = await store.add(sample('Hello world'));
    expect(id, greaterThan(0));
    final all = await store.all();
    expect(all, hasLength(1));
    final s = all.single;
    expect(s.id, id);
    expect(s.text, 'Hello world');
    expect(s.createdAt, DateTime(2026, 1, 1, 12, 0));
    expect(s.canvasWidth, 1200);
    expect(s.strokes.single.points.last.t, 1760000000020);
    expect(s.strokes.single.points.last.pressure, closeTo(0.6, 1e-9));
  });

  test('pen hover is saved with the sample (and may be empty)', () async {
    await store.add(
      LabeledSample(
        text: 'hover',
        strokes: sample('x').strokes,
        createdAt: DateTime(2026),
        hover: const [
          InkPoint(5, 6, 1760000000100, 0),
          InkPoint(7, 8, 1760000000110, 0),
        ],
      ),
    );
    await store.add(sample('none'));
    final all = await store.all();
    expect(all.first.hover.map((p) => [p.x, p.y, p.t]), [
      [5, 6, 1760000000100],
      [7, 8, 1760000000110],
    ]);
    expect(all.last.hover, isEmpty);
  });

  test(
    'a version 3 database gains the hover column and keeps samples',
    () async {
      final path =
          '${await databaseFactoryFfi.getDatabasesPath()}/v3-upgrade.db';
      await databaseFactoryFfi.deleteDatabase(path);
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, _) => db.execute('''
          CREATE TABLE samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL,
            strokes TEXT NOT NULL, created_at INTEGER NOT NULL,
            canvas_width REAL, canvas_height REAL)
        '''),
        ),
      );
      await old.insert('samples', {
        'text': 'old',
        'strokes': '[[[1,2,3,0.5]]]',
        'created_at': 0,
      });
      await old.close();
      final upgraded = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      final all = await SqliteSampleStore(upgraded).all();
      expect(all.single.text, 'old');
      expect(all.single.hover, isEmpty);
      await upgraded.close();
      await databaseFactoryFfi.deleteDatabase(path);
    },
  );

  test('count, order and delete', () async {
    final a = await store.add(sample('a'));
    await store.add(sample('b'));
    await store.add(sample('c'));
    expect(await store.count(), 3);
    await store.delete(a);
    expect((await store.all()).map((s) => s.text), ['b', 'c']);
  });
}
