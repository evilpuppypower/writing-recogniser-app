import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/feedback/personal_dictionary.dart';
import 'package:writing_recogniser/core/library_search.dart';
import 'package:writing_recogniser/core/page_layout.dart';
import 'package:writing_recogniser/core/printed_text_store.dart';
import 'package:writing_recogniser/library/library_search_screen.dart';
import 'package:writing_recogniser/library/library_search_service.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_ink_store.dart';
import 'package:writing_recogniser/storage/sqlite_printed_text_store.dart';

String words(List<String> texts) => jsonEncode({
  'words': [
    for (var i = 0; i < texts.length; i++) {'text': texts[i], 'key': 's$i'},
  ],
});

void main() {
  sqfliteFfiInit();

  group('searching every document', () {
    const docs = [
      SearchableDocument(
        id: 'a',
        name: 'Cell biology.pdf',
        tags: ['Exams'],
        pages: [
          (page: 2, kind: FoundIn.printed, text: 'The cell wall holds'),
          (page: 1, kind: FoundIn.handwriting, text: 'osmosis and the cell'),
        ],
      ),
      SearchableDocument(
        id: 'b',
        name: 'Notes.pdf',
        pages: [(page: 4, kind: FoundIn.handwriting, text: 'cell cell  CELL')],
      ),
      SearchableDocument(id: 'c', name: 'Recipes.pdf'),
    ];

    test('names and tags first, then most matches; pages in order', () {
      final r = searchLibrary(docs, '  Cell ');
      expect([for (final m in r) m.id], ['a', 'b']);
      expect(r[0].inName, isTrue);
      expect([for (final p in r[0].pages) p.page], [1, 2]);
      expect(r[1].pages.single.count, 3);
      expect(searchLibrary(docs, 'exams').single.tags, ['Exams']);
      expect(searchLibrary(docs, ''), isEmpty);
      expect(searchLibrary(docs, 'nowhere'), isEmpty);
    });

    test('a piece of text round the first match', () {
      final long = '${'x' * 60} the word here ${'y' * 60}';
      final m = searchLibrary([
        SearchableDocument(
          id: 'd',
          name: 'd',
          pages: [(page: 1, kind: FoundIn.printed, text: long)],
        ),
      ], 'WORD').single.pages.single;
      expect(m.match, 'word');
      expect(m.before, startsWith('…'));
      expect(m.before, endsWith('the '));
      expect(m.after, endsWith('…'));
    });

    test('handwriting: words read, shorthand written out too', () {
      final d = PersonalDictionary()..addShorthand('w/', 'with');
      final text = pageHandwriting(
        wordsJson: words(['tea', 'w/', 'milk']),
        expand: d.expand,
      );
      expect(text, contains('w/'));
      expect(text, contains('with'));
      expect(pageHandwriting(wordsJson: 'not json'), '');
    });

    test('shorthand: a phrase as written or written out, counted once', () {
      final d = PersonalDictionary()..addShorthand('brb', 'be right back');
      final text = pageHandwriting(
        wordsJson: words(['brb', 'see', 'brb']),
        expand: d.expand,
      );
      final doc = SearchableDocument(
        id: 'd',
        name: 'd',
        pages: [(page: 1, kind: FoundIn.handwriting, text: text)],
      );
      expect(searchLibrary([doc], 'brb see').single.pages.single.count, 1);
      expect(searchLibrary([doc], 'back see').single.pages.single.count, 1);
      expect(searchLibrary([doc], 'brb').single.pages.single.count, 2);
      // Not across the two.
      expect(searchLibrary([doc], 'brb be right'), isEmpty);
    });

    test('a snippet never splits an emoji', () {
      final text = '${'a' * 39}\u{1F600}x match';
      final m = searchLibrary(
        [
          SearchableDocument(
            id: 'e',
            name: 'e',
            pages: [(page: 1, kind: FoundIn.printed, text: text)],
          ),
        ],
        'match',
        around: 8,
      ).single.pages.single;
      expect(m.before.runes.every((r) => r < 0xD800 || r > 0xDFFF), isTrue);
    });

    test('pages by where they are shown', () {
      final layout = PageLayout(const [
        LaidOutPage.pdf(2),
        LaidOutPage.blank(1000001, paper: Paper.plain, width: 1, height: 1),
        LaidOutPage.copyOf(1000002, 2),
      ], pdfPageCount: 3);
      expect(byPosition({2: 'a', 1000001: 'b', 1: 'gone'}, layout), {
        1: 'a',
        2: 'b',
      });
      expect(printedByPosition({1: 'one', 2: 'two'}, layout), {
        1: 'two',
        3: 'two',
      });
      expect(byPosition({5: 'x'}, null), {5: 'x'});
    });
  });

  group('printed text kept', () {
    late Database db;
    setUp(() async {
      db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
    });
    tearDown(() => db.close());

    test('read once, kept, and forgotten', () async {
      final s = SqlitePrintedTextStore(db);
      expect(await s.load('a'), isNull);
      await s.save('a', (pages: {1: 'hello', 3: 'there'}, pageCount: 4));
      await s.save('nb', (pages: const {}, pageCount: 0));
      expect((await s.load('a'))!.pages, {1: 'hello', 3: 'there'});
      expect((await s.load('a'))!.pageCount, 4);
      expect((await s.load('nb'))!.pages, isEmpty);
      expect(await s.documents(), {'a', 'nb'});
      await s.forget('a');
      expect(await s.load('a'), isNull);
    });

    test('the service: handwriting, printed text, stopping', () async {
      final ink = SqliteInkStore(db);
      await ink.saveText('a', 1, words(['osmosis']));
      var reads = 0;
      final service = LibrarySearchService(
        ink: ink,
        layouts: MemoryPageLayoutStore(),
        printed: MemoryPrintedTextStore(),
        readPdf: (path, onPage, stop, pause) async {
          reads++;
          await pause();
          if (stop()) return null;
          onPage(1, 1);
          return (pages: {1: 'printed words'}, pageCount: 1);
        },
      );
      expect((await service.handwriting('a')).single.text, 'osmosis');
      expect(await service.savedPrinted('a'), isNull);
      expect(await service.readPrinted('a', 'f', (_, _) {}, () => true), false);
      expect(await service.savedPrinted('a'), isNull);
      expect(await service.readPrinted('a', 'f', (_, _) {}, () => false), true);
      expect((await service.savedPrinted('a'))!.single.text, 'printed words');
      expect(reads, 2);
      // Pages of its own that don't fit the PDF any more are ignored, as
      // the viewer does.
      final layouts = MemoryPageLayoutStore();
      await layouts.save(
        'a',
        PageLayout(const [
          LaidOutPage.pdf(2),
          LaidOutPage.pdf(1),
        ], pdfPageCount: 2),
      );
      final checked = LibrarySearchService(
        ink: ink,
        layouts: layouts,
        printed: service.printed,
      );
      expect((await checked.savedPrinted('a'))!.single.page, 1);
      await service.keepOnly({'b'});
      expect(await service.savedPrinted('a'), isNull);
    });
  });

  testWidgets('search screen: names can be searched while loading', (
    tester,
  ) async {
    final slow = Completer<void>();
    late LibrarySearchService service;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      service = _SlowService(SqliteInkStore(db), slow.future);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: LibrarySearchScreen(
          service: () async => service,
          entries: const [
            SearchEntry(id: 'a', name: 'Biology.pdf'),
            SearchEntry(id: 'b', name: 'History.pdf'),
          ],
          onOpen: (id, page, q) async {},
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.textContaining('You can type to search now'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'biology');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Biology.pdf'), findsOneWidget);
    expect(
      find.textContaining('Still getting documents ready'),
      findsOneWidget,
    );
    slow.complete();
    for (
      var i = 0;
      i < 20 &&
          find.textContaining('Still getting documents').evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.textContaining('Still getting documents'), findsNothing);
    expect(find.text('Biology.pdf'), findsOneWidget);
  });

  testWidgets('search screen: reads printed text once, finds, opens', (
    tester,
  ) async {
    final printed = MemoryPrintedTextStore();
    final reading = Completer<PrintedPages?>();
    final opened = <(String, int?, String)>[];
    late LibrarySearchService service;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final ink = SqliteInkStore(db);
      await ink.saveText('a', 2, words(['photosynthesis']));
      service = LibrarySearchService(
        ink: ink,
        layouts: MemoryPageLayoutStore(),
        printed: printed,
        readPdf: (path, onPage, stop, pause) {
          onPage(1, 2);
          return reading.future;
        },
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: LibrarySearchScreen(
          service: () async => service,
          entries: const [
            SearchEntry(id: 'a', name: 'Biology.pdf', path: 'a.pdf', size: 10),
            SearchEntry(id: 'n', name: 'Notebook', notebook: true),
          ],
          onOpen: (id, page, q) async => opened.add((id, page, q)),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (
      var i = 0;
      i < 20 && find.textContaining('Reading printed').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.textContaining('Reading printed text'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'photo');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Page 2 · handwriting'), findsOneWidget);

    reading.complete((pages: {1: 'chlorophyll is green'}, pageCount: 2));
    for (
      var i = 0;
      i < 20 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.textContaining('Reading printed text'), findsNothing);
    expect((await printed.load('n'))!.pages, isEmpty);
    await tester.enterText(find.byType(TextField), 'chlorophyll');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Page 1 · printed'), findsOneWidget);
    await tester.tap(find.text('Page 1 · printed'));
    await tester.pump();
    expect(opened.first, ('a', 1, 'chlorophyll'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });
}

/// Each document's handwriting takes until [wait] completes.
class _SlowService extends LibrarySearchService {
  _SlowService(SqliteInkStore ink, this.wait)
    : super(
        ink: ink,
        layouts: MemoryPageLayoutStore(),
        printed: MemoryPrintedTextStore(),
      );

  final Future<void> wait;

  @override
  Future<List<PageText>> handwriting(String id) async {
    await wait;
    return const [];
  }
}
