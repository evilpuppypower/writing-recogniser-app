import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/ink_store.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_bookmark_store.dart';
import 'package:writing_recogniser/storage/sqlite_ink_store.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

PageStroke stroke(double x, {InkTool tool = InkTool.pen, bool arrow = false}) =>
    PageStroke(
      points: [
        PageInkPoint(x, 10, 1000, 0.4),
        PageInkPoint(x + 50, 20, 1100, 0.7),
      ],
      colorArgb: 0xFF1565C0,
      width: 2.5,
      tool: tool,
      arrow: arrow,
    );

class MemoryInkStore implements InkStore {
  final saves = <(String, int, int)>[]; // document, page, stroke count
  final pages = <String, Map<int, List<PageStroke>>>{};
  bool fail = false;

  @override
  Future<DocumentInk> load(String id) async {
    final ink = DocumentInk();
    pages[id]?.forEach(ink.setPage);
    return ink;
  }

  @override
  Future<void> savePage(String id, int page, List<PageStroke> strokes) async {
    if (fail) throw StateError('disk full');
    saves.add((id, page, strokes.length));
    (pages[id] ??= {})[page] = strokes;
  }

  @override
  Future<void> deleteDocument(String id) async => pages.remove(id);

  @override
  Future<Set<String>> documentsWithInk() async => pages.keys.toSet();

  final texts = <String, Map<int, String>>{};

  @override
  Future<Map<int, String>> loadText(String id) async => {...?texts[id]};

  @override
  Future<void> saveText(String id, int page, String? json) async {
    if (json == null) {
      texts[id]?.remove(page);
    } else {
      (texts[id] ??= {})[page] = json;
    }
  }
}

void main() {
  sqfliteFfiInit();

  group('SQLite ink store', () {
    late Database db;
    late SqliteInkStore store;

    setUp(() async {
      db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      store = SqliteInkStore(db);
    });
    tearDown(() => db.close());

    test('whether one page has ink', () async {
      await store.savePage('doc', 2, [stroke(5)]);
      expect(await store.hasInkOn('doc', 2), isTrue);
      expect(await store.hasInkOn('doc', 1), isFalse);
      expect(await store.hasInkOn('other', 2), isFalse);
    });

    test('saves and reloads every page with tool, colour, width, pressure '
        'and arrows', () async {
      await store.savePage('doc', 1, [stroke(5), stroke(80, arrow: true)]);
      await store.savePage('doc', 13, [stroke(9, tool: InkTool.highlighter)]);
      await store.savePage('other', 1, [stroke(1)]);
      final ink = await store.load('doc');
      expect(ink.pagesWithInk.toSet(), {1, 13});
      final s = ink.strokesOn(1);
      expect(s, hasLength(2));
      expect(s.last.arrow, isTrue);
      expect(s.first.colorArgb, 0xFF1565C0);
      expect(s.first.width, 2.5);
      expect(s.first.points.last.pressure, closeTo(0.7, 1e-9));
      expect(ink.strokesOn(13).single.tool, InkTool.highlighter);
      expect(await store.documentsWithInk(), {'doc', 'other'});
    });

    test('a page too big to read in one go comes back whole', () async {
      // Android can't read a row over about 2 MB at once; here pieces of
      // 37 characters stand in for that limit.
      final small = SqliteInkStore(db, pieceChars: 37);
      final busy = [
        for (var i = 0; i < 40; i++)
          PageStroke(
            points: [
              for (var j = 0; j < 30; j++)
                PageInkPoint(i + j * 0.5, j * 1.25, 1000 + j * 4, 0.5),
            ],
          ),
      ];
      await small.savePage('doc', 1, busy);
      await small.savePage('doc', 2, [stroke(5)]); // shorter than a piece
      await small.savePage('other', 3, busy);
      final back = await small.load('doc');
      expect(back.strokesOn(1).map((s) => s.toJson()), [
        for (final s in busy) s.toJson(),
      ]);
      expect(back.strokesOn(2), hasLength(1));
      // The same ink as reading it in one go.
      final whole = await store.load('doc');
      expect(
        back.strokesOn(1).map((s) => s.toJson()).toList(),
        whole.strokesOn(1).map((s) => s.toJson()).toList(),
      );
      final all = await small.allInk();
      expect(all.map((e) => e.document), ['doc', 'doc', 'other']);
      expect(all, everyElement(isA<({String document, String json})>()));
      expect(
        all.first.json,
        (await store.allInk()).first.json,
        reason: 'pieces joined back exactly',
      );
    });

    test(
      'a busy page of fast writing (over 2 MB) is saved and read back',
      () async {
        // 650 strokes of 300 samples: a full page since every sample is kept.
        final page = [
          for (var i = 0; i < 650; i++)
            PageStroke(
              points: [
                for (var j = 0; j < 300; j++)
                  PageInkPoint(
                    100 + i * 0.731 + j * 0.0137,
                    200 + j * 0.219,
                    1760000000000 + i * 2000 + j * 4,
                    (j % 100) / 100,
                  ),
              ],
            ),
        ];
        await store.savePage('doc', 1, page);
        final n =
            (await db.rawQuery('SELECT length(strokes) AS n FROM page_ink'))
                    .single['n']!
                as int;
        expect(n, greaterThan(2 * 1024 * 1024));
        final back = (await store.load('doc')).strokesOn(1);
        expect(back, hasLength(650));
        expect(back.last.points, hasLength(300));
      },
    );

    test('saving a page again replaces it; an empty page is removed', () async {
      await store.savePage('doc', 2, [stroke(1), stroke(2)]);
      await store.savePage('doc', 2, [stroke(3)]);
      expect((await store.load('doc')).strokesOn(2), hasLength(1));
      await store.savePage('doc', 2, const []);
      expect((await store.load('doc')).isEmpty, isTrue);
      expect(await store.documentsWithInk(), isEmpty);
    });

    test('deleting a document forgets only its ink', () async {
      await store.savePage('a', 1, [stroke(1)]);
      await store.savePage('b', 1, [stroke(1)]);
      await store.saveText('a', 1, '[]');
      await store.saveText('b', 1, '[]');
      await store.deleteDocument('a');
      expect(await store.documentsWithInk(), {'b'});
      expect(await store.loadText('a'), isEmpty, reason: 'and its text');
      expect(await store.loadText('b'), {1: '[]'});
    });

    test('recognised text is saved per page, replaced and removed', () async {
      await store.saveText('doc', 1, '["one"]');
      await store.saveText('doc', 3, '["three"]');
      await store.saveText('doc', 1, '["uno"]');
      expect(await store.loadText('doc'), {1: '["uno"]', 3: '["three"]'});
      await store.saveText('doc', 3, null);
      expect(await store.loadText('doc'), {1: '["uno"]'});
    });

    test('a version 4 database gains the ink table', () async {
      final path = '${await databaseFactoryFfi.getDatabasesPath()}/v4-ink.db';
      await databaseFactoryFfi.deleteDatabase(path);
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, _) => db.execute('CREATE TABLE x (id INTEGER)'),
        ),
      );
      await old.close();
      final upgraded = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      final s = SqliteInkStore(upgraded);
      await s.savePage('doc', 1, [stroke(1)]);
      expect((await s.load('doc')).strokesOn(1), hasLength(1));
      await upgraded.close();
      await databaseFactoryFfi.deleteDatabase(path);
    });

    test(
      'a version 6 database keeps its ink and gains the text table',
      () async {
        final path = '${await databaseFactoryFfi.getDatabasesPath()}/v6-ink.db';
        await databaseFactoryFfi.deleteDatabase(path);
        // Today's database, as the current build left it.
        final v7 = await AppDatabase.open(
          factory: databaseFactoryFfi,
          path: path,
        );
        await SqliteInkStore(v7).savePage('doc', 1, [stroke(1)]);
        await v7.execute('DROP TABLE page_text');
        await v7.execute('DROP TABLE bookmarks');
        await v7.execute('DROP TABLE document_colours');
        await v7.execute('DROP TABLE page_layouts');
        await v7.execute('DROP TABLE document_views');
        await v7.execute('DROP TABLE tags');
        await v7.execute('DROP TABLE document_tags');
        await v7.execute('DROP TABLE printed_text');
        await v7.execute('DROP TABLE printed_documents');
        await v7.execute('DROP TABLE scanned_text');
        await v7.setVersion(6);
        await v7.close();
        final upgraded = await AppDatabase.open(
          factory: databaseFactoryFfi,
          path: path,
        );
        final s = SqliteInkStore(upgraded);
        expect((await s.load('doc')).strokesOn(1), hasLength(1));
        await s.saveText('doc', 1, '[]');
        expect(await s.loadText('doc'), {1: '[]'});
        // And the bookmarks table (version 8).
        await SqliteBookmarkStore(upgraded).set('doc', 2, on: true);
        expect(await SqliteBookmarkStore(upgraded).pages('doc'), [2]);
        await upgraded.close();
        await databaseFactoryFfi.deleteDatabase(path);
      },
    );
  });

  group('autosave', () {
    testWidgets('saves shortly after edits, once per page for a burst of '
        'edits', (tester) async {
      // Widget tests run on a fake clock, so the wait can be stepped.
      final store = MemoryInkStore();
      final ink = DocumentInk();
      final saver = InkAutosaver(
        store: store,
        documentId: 'doc',
        pageStrokes: ink.strokesOn,
      );
      for (var i = 0; i < 5; i++) {
        ink.add(3, stroke(i.toDouble()));
        saver.changed(3); // e.g. one eraser swipe = many edits
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(store.saves, isEmpty, reason: 'still within the short wait');
      await tester.pump(const Duration(milliseconds: 500));
      expect(store.saves, [('doc', 3, 5)]);
    });

    test('flush saves at once (leaving the PDF or the app)', () async {
      final store = MemoryInkStore();
      final ink = DocumentInk()..add(1, stroke(1));
      final saver = InkAutosaver(
        store: store,
        documentId: 'doc',
        pageStrokes: ink.strokesOn,
      );
      saver.changed(1);
      await saver.flush();
      expect(store.saves, [('doc', 1, 1)]);
      expect(saver.hasPending, isFalse);
      saver.dispose();
    });

    test('a failed save is reported, not thrown', () async {
      final store = MemoryInkStore()..fail = true;
      final errors = <Object>[];
      final saver = InkAutosaver(
        store: store,
        documentId: 'doc',
        pageStrokes: (_) => [stroke(1)],
        onError: errors.add,
      );
      saver.changed(1);
      await saver.flush();
      expect(errors, hasLength(1));
    });

    test('controller edits, undo and redo reach the autosaver', () async {
      final store = MemoryInkStore();
      final c = DocumentInkController();
      final saver = InkAutosaver(
        store: store,
        documentId: 'doc',
        pageStrokes: c.ink.strokesOn,
      );
      c.onChanged = saver.changed;
      c.add(2, stroke(1));
      c.add(2, stroke(2));
      await saver.flush();
      c.undo();
      await saver.flush();
      expect(store.pages['doc']![2], hasLength(1));
      c.redo();
      await saver.flush();
      expect(store.pages['doc']![2], hasLength(2));
    });
  });

  test('saved ink goes under ink written while it loaded', () {
    final c = DocumentInkController();
    c.add(1, stroke(99)); // written before the saved ink arrived
    final saved = DocumentInk()
      ..setPage(1, [stroke(1)])
      ..setPage(4, [stroke(2)]);
    final mixed = c.restore(saved);
    expect(c.ink.strokesOn(1).map((s) => s.points.first.x), [1, 99]);
    expect(c.ink.strokesOn(4), hasLength(1));
    expect(mixed, {1});
    expect(c.canUndo, isTrue, reason: 'only the new stroke is undoable');
    c.undo();
    expect(c.ink.strokesOn(1), hasLength(1), reason: 'undo keeps saved ink');
  });
}
