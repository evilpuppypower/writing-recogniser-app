import 'dart:convert';

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
      // Saved as builds before version 15 did: one row per page.
      Future<void> old(String doc, int page, List<PageStroke> strokes) =>
          db.insert('page_ink', {
            'document_id': doc,
            'page': page,
            'strokes': jsonEncode([for (final s in strokes) s.toJson()]),
            'updated_at': 0,
          });
      await old('doc', 1, busy);
      await old('doc', 2, [stroke(5)]); // shorter than a piece
      await old('other', 3, busy);
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
        // Saved as builds before version 15 did: one row, over 2 MB.
        final json = jsonEncode([for (final s in page) s.toJson()]);
        expect(json.length, greaterThan(2 * 1024 * 1024));
        await db.insert('page_ink', {
          'document_id': 'doc',
          'page': 1,
          'strokes': json,
          'updated_at': 0,
        });
        final back = (await store.load('doc')).strokesOn(1);
        expect(back, hasLength(650));
        expect(back.last.points, hasLength(300));
      },
    );

    test(
      'a save writes only the new strokes; erased ones are removed',
      () async {
        final a = stroke(1), b = stroke(2), c = stroke(3);
        await store.savePage('doc', 1, [a, b]);
        Future<Set<int>> rows() async => {
          for (final r in await db.query('ink_strokes', columns: ['id']))
            r['id']! as int,
        };
        final first = await rows();
        expect(first, hasLength(2));
        await store.savePage('doc', 1, [a, b, c]);
        final second = await rows();
        expect(second, hasLength(3));
        expect(
          second.containsAll(first),
          isTrue,
          reason: 'a and b not rewritten',
        );
        await store.savePage('doc', 1, [a, c]); // b rubbed out
        expect(await rows(), hasLength(2));
        // Order is kept, also when it changes.
        await store.savePage('doc', 1, [c, a]);
        final back = (await store.load('doc')).strokesOn(1);
        expect(back.map((s) => s.points.first.x), [3, 1]);
        // A new store (the app reopened) knows nothing, and still saves right.
        final again = SqliteInkStore(db);
        final loaded = (await again.load('doc')).strokesOn(1);
        await again.savePage('doc', 1, [...loaded, stroke(4)]);
        expect(await rows(), hasLength(3));
        expect(
          (await again.load('doc')).strokesOn(1).map((s) => s.points.first.x),
          [3, 1, 4],
        );
      },
    );

    test('a row changed elsewhere is never trusted from memory', () async {
      final a = stroke(1), b = stroke(2);
      await store.savePage('doc', 1, [a, b]);
      // Another part of the app rewrites the page: the old rows are gone.
      await db.delete('ink_strokes');
      await store.savePage('doc', 1, [a, b]);
      final back = (await SqliteInkStore(db).load('doc')).strokesOn(1);
      expect(back.map((s) => s.points.first.x), [1, 2]);
    });

    test('old pages move to the new form once, and stay the same', () async {
      final strokes = [stroke(5), stroke(80, arrow: true)];
      await db.insert('page_ink', {
        'document_id': 'doc',
        'page': 4,
        'strokes': jsonEncode([for (final s in strokes) s.toJson()]),
        'updated_at': 0,
      });
      final back = await store.load('doc');
      expect(back.strokesOn(4).map((s) => s.toJson()), [
        for (final s in strokes) s.toJson(),
      ]);
      expect(await db.query('page_ink'), isEmpty, reason: 'moved');
      expect(await db.query('ink_strokes'), hasLength(2));
      expect(await store.documentsWithInk(), {'doc'});
      expect(await store.hasInkOn('doc', 4), isTrue);
      final again = await SqliteInkStore(db).load('doc');
      expect(again.strokesOn(4), hasLength(2));
    });

    test(
      'an old page saved over meanwhile is not moved over the new ink',
      () async {
        await db.insert('page_ink', {
          'document_id': 'doc',
          'page': 1,
          'strokes': jsonEncode([stroke(5).toJson()]),
          'updated_at': 0,
        });
        // The viewer saves the page (new form) while something else is
        // still reading the old one.
        final reading = SqliteInkStore(db).load('doc');
        await store.savePage('doc', 1, [stroke(5), stroke(6)]);
        await reading;
        final saved = (await SqliteInkStore(db).load('doc')).strokesOn(1);
        expect(saved, hasLength(2), reason: 'the newer save is kept');
      },
    );

    test('deleting a PDF removes all of its ink', () async {
      await store.savePage('doc', 1, [stroke(1)]);
      await db.insert('page_ink', {
        'document_id': 'doc',
        'page': 2,
        'strokes': jsonEncode([stroke(2).toJson()]),
        'updated_at': 0,
      });
      await store.savePage('other', 1, [stroke(3)]);
      await store.deleteDocument('doc');
      expect((await store.load('doc')).isEmpty, isTrue);
      expect(await store.documentsWithInk(), {'other'});
      expect(
        await db.query('ink_strokes', where: "document_id = 'doc'"),
        isEmpty,
      );
    });

    test('adding a stroke to a busy page is quick (owner: the pen waited '
        'while the page was saved)', () async {
      final page = [
        for (var i = 0; i < 633; i++)
          PageStroke(
            points: [
              for (var j = 0; j < 280; j++)
                PageInkPoint(
                  i * 0.7 + j * 0.01,
                  j * 0.2,
                  1000 + i * 9000 + j * 4,
                  0.5,
                ),
            ],
          ),
      ];
      await store.savePage('doc', 1, page);
      final watch = Stopwatch()..start();
      await store.savePage('doc', 1, [...page, stroke(1)]);
      // About 200-280 ms on a desktop when the whole page was rewritten.
      expect(watch.elapsedMilliseconds, lessThan(60));
      final back = (await store.load('doc')).strokesOn(1);
      expect(back, hasLength(634));
      expect(back.first.points, hasLength(280));
    });

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
        // Ink as builds before version 15 saved it: one row per page.
        await v7.insert('page_ink', {
          'document_id': 'doc',
          'page': 1,
          'strokes': jsonEncode([stroke(1).toJson()]),
          'updated_at': 0,
        });
        await v7.execute('DROP TABLE ink_strokes');
        await v7.execute('DROP TABLE ink_pages');
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
