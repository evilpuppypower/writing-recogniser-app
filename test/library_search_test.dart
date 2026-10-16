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
      await s.save('a', {1: 'hello', 3: 'there'});
      await s.save('nb', const {});
      expect(await s.load('a'), {1: 'hello', 3: 'there'});
      expect(await s.load('nb'), isEmpty);
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
        readPdf: (path, onPage, stop) async {
          reads++;
          if (stop()) return null;
          onPage(1, 1);
          return {1: 'printed words'};
        },
      );
      expect((await service.handwriting('a')).single.text, 'osmosis');
      expect(await service.savedPrinted('a'), isNull);
      expect(await service.readPrinted('a', 'f', (_, _) {}, () => true), false);
      expect(await service.savedPrinted('a'), isNull);
      expect(await service.readPrinted('a', 'f', (_, _) {}, () => false), true);
      expect((await service.savedPrinted('a'))!.single.text, 'printed words');
      expect(reads, 2);
      await service.keepOnly({'b'});
      expect(await service.savedPrinted('a'), isNull);
    });
  });

  testWidgets('search screen: reads printed text once, finds, opens', (
    tester,
  ) async {
    final printed = MemoryPrintedTextStore();
    final reading = Completer<Map<int, String>?>();
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
        readPdf: (path, onPage, stop) {
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
      i < 20 && find.byType(LinearProgressIndicator).evaluate().isEmpty;
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

    reading.complete({1: 'chlorophyll is green'});
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
    expect(await printed.load('n'), isEmpty);
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
