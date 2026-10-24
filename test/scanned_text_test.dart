import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/document_view.dart';
import 'package:writing_recogniser/core/handwriting_search.dart';
import 'package:writing_recogniser/core/highlights.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/printed_text.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart' show InkBox;
import 'package:writing_recogniser/core/page_layout.dart';
import 'package:writing_recogniser/core/printed_text_store.dart';
import 'package:writing_recogniser/core/scanned_text.dart';
import 'package:writing_recogniser/library/library_search_service.dart';
import 'package:writing_recogniser/platform/ocr_channel.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_ink_store.dart';
import 'package:writing_recogniser/storage/sqlite_scanned_text_store.dart';
import 'package:writing_recogniser/viewer/scanned_pages.dart';
import 'package:writing_recogniser/viewer/scanned_reading.dart';

typedef _Read = ({
  int left,
  int top,
  int right,
  int bottom,
  String text,
  double confidence,
});

class _Reader implements TextReaderService {
  _Reader(this.byWidth);

  /// What each image (told apart by its width) reads as.
  final Map<int, List<OcrLine>> byWidth;
  final reads = <String>[];

  @override
  Future<List<OcrLine>> read(String id, int w, int h, Uint8List bgra) async {
    reads.add('$id:$w');
    return byWidth[w] ?? const [];
  }

  @override
  Future<Set<String>> installed() async => {'m'};
  @override
  Future<Map<String, Map<String, String>>> fingerprints() async => const {};
  @override
  Future<void> download(model, {progress}) async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> remove(String id) async {}
}

var _freed = 0;

PageImage _image(int w) =>
    (width: w, height: 100, bgra: Uint8List(w * 400), dispose: () => _freed++);

_Read _line(String text, {double c = 0.9}) =>
    (left: 10, top: 20, right: 60, bottom: 40, text: text, confidence: c);

void main() {
  group('looksScanned', () {
    test('most sampled pages without text', () {
      expect(looksScanned([0, 0, 3, 0, 0]), isTrue);
      expect(looksScanned([0, 400, 0, 500, 0]), isFalse);
      expect(looksScanned([500]), isFalse);
      expect(looksScanned([]), isFalse);
    });

    test('counts letters and digits only', () {
      expect(textChars(' \n- ab1 . é'), 4);
    });
  });

  test('lines become shares of the page, without doubtful ones', () {
    final lines = scannedLines(
      [_line(' Hello '), _line('##', c: 0.2), _line('  ')],
      100,
      200,
    );
    expect(lines, hasLength(1));
    expect(lines.single.text, 'Hello');
    expect(lines.single.left, closeTo(0.1, 1e-9));
    expect(lines.single.top, closeTo(0.1, 1e-9));
    expect(lines.single.right, closeTo(0.6, 1e-9));
    expect(lines.single.bottom, closeTo(0.2, 1e-9));
  });

  test('lines are kept and read back; bad data is left out', () {
    final lines = scannedLines([_line('One'), _line('Two')], 100, 100);
    final back = decodeScannedLines(encodeScannedLines(lines));
    expect(back.map((l) => l.text), ['One', 'Two']);
    expect(back.first.right, closeTo(0.6, 1e-4));
    expect(decodeScannedLines('nonsense'), isEmpty);
    expect(decodeScannedLines('[[1,2],[0,0,1,1,"ok",0.9]]').single.text, 'ok');
  });

  group('readScannedPages', () {
    test('reads and keeps each page, a blank one too', () async {
      _freed = 0;
      final store = MemoryScannedTextStore();
      final reader = _Reader({
        101: [_line('Page one')],
      });
      final progress = <int>[];
      final ok = await readScannedPages(
        documentId: 'd',
        pages: [1, 2, 3],
        store: store,
        reader: reader,
        modelId: 'm',
        render: (p) async => p == 3 ? null : _image(100 + p),
        onPage: (done, total, _) => progress.add(done),
        stop: () => false,
      );
      // Page 3 couldn't be drawn: not kept, so it's tried again.
      expect(ok, isFalse);
      expect(progress, [1, 2, 3]);
      final kept = await store.load('d');
      expect(kept.keys, [1, 2]);
      expect(kept[1]!.single.text, 'Page one');
      expect(kept[2], isEmpty);
      expect(reader.reads, ['m:101', 'm:102']);
      expect(await store.pagesRead('d'), {1, 2});
      expect(_freed, 2);
    });

    test('stops before the next page', () async {
      final store = MemoryScannedTextStore();
      var stop = false;
      final ok = await readScannedPages(
        documentId: 'd',
        pages: [1, 2, 3],
        store: store,
        reader: _Reader({}),
        modelId: 'm',
        render: (p) async => _image(100),
        onPage: (done, _, _) => stop = done == 1,
        stop: () => stop,
      );
      expect(ok, isFalse);
      expect((await store.load('d')).keys, [1]);
    });
  });

  group('ScannedPagesReader', () {
    test('reads only pages not read yet, with progress', () async {
      final store = MemoryScannedTextStore();
      await store.savePage('d', 2, const []);
      final r = ScannedPagesReader(
        documentId: 'd',
        store: store,
        reader: _Reader({}),
      );
      final left = await r.pagesLeft(3);
      expect(left, [1, 3]);
      final seen = <ScanProgress?>[];
      r.progress.addListener(() => seen.add(r.progress.value));
      final result = await r.run(left, 'm', (_) async => _image(100));
      expect(result.finished, isTrue);
      expect(result.read, 2);
      expect(seen.first, (done: 0, total: 2, left: null));
      expect(seen.last, isNull);
      expect(await r.pagesLeft(3), isEmpty);
      r.dispose();
    });

    test('a reader that fails says so and keeps pages read', () async {
      final store = MemoryScannedTextStore();
      final r = ScannedPagesReader(
        documentId: 'd',
        store: store,
        reader: _Reader({}),
      );
      var n = 0;
      final result = await r.run([1, 2], 'm', (_) async {
        if (++n == 2) throw Exception('no');
        return _image(100);
      });
      expect(result.finished, isFalse);
      expect(result.error, isNotNull);
      expect(result.read, 1);
      expect((await store.load('d')).keys, [1]);
      r.dispose();
    });
  });

  group('a 400-page scan (owner: pause and resume a big scan)', () {
    test(
      'pausing holds it; resuming carries on; nothing lost or repeated',
      () async {
        final store = MemoryScannedTextStore();
        final reader = _Reader({});
        final r = ScannedPagesReader(
          documentId: 'big',
          store: store,
          reader: reader,
        );
        final pages = await r.pagesLeft(400);
        expect(pages, hasLength(400));
        var drawn = 0;
        var over = false;
        final run = r.run(pages, 'm', (p) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          drawn++;
          // Page 123 can't be drawn (a damaged page): tried again next time.
          return p == 123 ? null : _image(100);
        });
        unawaited(run.whenComplete(() => over = true));
        // Pause after about 50 pages.
        while (!over && (r.progress.value?.done ?? 0) < 50) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(over, isFalse);
        r.pause();
        final heldAt = r.progress.value!.done;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(r.progress.value!.done, lessThanOrEqualTo(heldAt + 1));
        final drawnWhilePaused = drawn;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(drawn, drawnWhilePaused, reason: 'nothing drawn while paused');
        r.resume();
        final result = await run;
        expect(result.finished, isFalse, reason: 'page 123 is still to read');
        expect(result.read, 400);
        expect(reader.reads, hasLength(399));
        final kept = await store.pagesRead('big');
        expect(kept, hasLength(399));
        expect(kept.contains(123), isFalse);
        // Next time only the page that failed is read.
        expect(await r.pagesLeft(400), [123]);
        r.dispose();
      },
    );

    test('Stop while paused ends it at once', () async {
      final r = ScannedPagesReader(
        documentId: 'big',
        store: MemoryScannedTextStore(),
        reader: _Reader({}),
      );
      final run = r.run(List.generate(400, (i) => i + 1), 'm', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return _image(100);
      });
      while ((r.progress.value?.done ?? 0) < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      r.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      r.stop();
      final result = await run.timeout(const Duration(seconds: 2));
      expect(result.finished, isFalse);
      expect(result.read, lessThan(20));
      r.dispose();
    });

    test('closing the PDF mid-way stops it without errors', () async {
      final r = ScannedPagesReader(
        documentId: 'big',
        store: MemoryScannedTextStore(),
        reader: _Reader({}),
      );
      final run = r.run(List.generate(400, (i) => i + 1), 'm', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return _image(100);
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      r.dispose();
      final result = await run.timeout(const Duration(seconds: 2));
      expect(result.finished, isFalse);
      expect(result.error, isNull);
    });
  });

  testWidgets('the card offers Pause, then Resume', (tester) async {
    var paused = false;
    Widget card() => MaterialApp(
      home: Scaffold(
        body: ScannedProgressCard(
          progress: (done: 16, total: 400, left: const Duration(minutes: 9)),
          paused: paused,
          onPause: () => paused = true,
          onResume: () => paused = false,
          onStop: () {},
        ),
      ),
    );
    await tester.pumpWidget(card());
    expect(find.textContaining('16 of 400'), findsOneWidget);
    await tester.tap(find.text('Pause'));
    await tester.pumpWidget(card());
    expect(find.textContaining('Paused'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    expect(paused, isFalse);
  });

  group('SQLite store', () {
    setUpAll(sqfliteFfiInit);

    test('keeps pages by document and forgets them', () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final s = SqliteScannedTextStore(db);
      final lines = scannedLines([_line('Hi')], 100, 100);
      await s.savePage('a', 1, lines);
      await s.savePage('a', 1, lines); // again: replaced
      await s.savePage('a', 2, const []);
      await s.savePage('b', 1, const []);
      final a = await s.load('a');
      expect(a.keys.toSet(), {1, 2});
      expect(await s.pagesRead('a'), {1, 2});
      expect(a[1]!.single.text, 'Hi');
      expect(await s.documents(), {'a', 'b'});
      await s.forget('a');
      expect(await s.load('a'), isEmpty);
      expect(await s.documents(), {'b'});
      await db.close();
    });
  });

  test('search finds scanned text where a page has none printed', () async {
    final printed = MemoryPrintedTextStore();
    await printed.save('d', (
      pages: {1: 'p. 1', 2: 'printed words that are plenty long'},
      pageCount: 2,
    ));
    final scanned = MemoryScannedTextStore();
    await scanned.savePage(
      'd',
      1,
      scannedLines([_line('Scanned Words')], 100, 100),
    );
    await scanned.savePage('d', 2, scannedLines([_line('ignored')], 100, 100));
    await scanned.savePage('gone', 1, const []);
    sqfliteFfiInit();
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final service = LibrarySearchService(
      ink: SqliteInkStore(db),
      layouts: MemoryPageLayoutStore(),
      printed: printed,
      scanned: scanned,
    );
    final pages = (await service.savedPrinted('d'))!
      ..sort((a, b) => a.page.compareTo(b.page));
    expect(pages.map((p) => p.page), [1, 2]);
    expect(pages.first.text, contains('Scanned'));
    expect(pages.last.text, isNot(contains('ignored')));
    await service.keepOnly({'d'});
    expect(await scanned.documents(), {'d'});
  });

  test('settings and each document keep the scanned choice', () {
    const s = AppSettings(scannedPdfs: ScannedChoice.leave);
    expect(AppSettings.fromMap(s.toMap()).scannedPdfs, ScannedChoice.leave);
    expect(
      AppSettings.fromMap(const AppSettings().toMap()).scannedPdfs,
      ScannedChoice.ask,
    );
    final v = const DocumentView().copyWith(readScanned: false);
    expect(DocumentView.fromJson(v.toJson()).readScanned, isFalse);
    expect(
      DocumentView.fromJson(const DocumentView().toJson()).readScanned,
      isNull,
    );
  });

  testWidgets('asks once, with "do the same for others"', (tester) async {
    ScannedAnswer? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                answer = await askReadScanned(context, haveReader: false),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('This PDF looks scanned'), findsOneWidget);
    expect(find.textContaining('text reader first'), findsOneWidget);
    await tester.tap(find.text('Do the same for other scanned PDFs'));
    await tester.tap(find.text('Get a reader'));
    await tester.pumpAndSettle();
    expect(answer, (read: true, same: true));
  });

  group('scanned text in the open PDF', () {
    // A 600 x 800 pt page; a line across the middle of its top half.
    const line = (
      left: 0.1,
      top: 0.25,
      right: 0.5,
      bottom: 0.275,
      text: 'cells divide',
      confidence: 0.9,
    );

    test('a line\'s box in PDF page coordinates', () {
      final b = scannedBox(line, 600, 800);
      expect(b.left, closeTo(60, 1e-9));
      expect(b.right, closeTo(300, 1e-9));
      expect(b.top, closeTo(600, 1e-9));
      expect(b.bottom, closeTo(580, 1e-9));
    });

    test('characters share the line, with a break between lines', () {
      final chars = scannedChars([line, line], 600, 800);
      expect(chars.map((c) => c.char).join(), 'cells divide\ncells divide');
      expect(chars.first.box.left, closeTo(60, 1e-9));
      expect(chars[11].box.right, closeTo(300, 1e-9));
      expect(chars[12].box.width, 0);
    });

    test('words for search, each with its own part of the line', () {
      final words = scannedWords([line], 600, 800);
      expect(words.map((w) => w.text), ['cells', 'divide']);
      expect(words.first.box.right, lessThan(words.last.box.left));
      final hits = searchHandwriting([
        for (final w in words)
          (page: 3, line: w.line, box: w.box, text: w.text),
      ], 'divide');
      expect(hits.single.page, 3);
      expect(hits.single.box.left, greaterThan(150));
    });

    test('a highlighter stroke over scanned text picks out its words', () {
      final chars = scannedChars([line], 600, 800);
      // Across "divide" only.
      final mark = PageStroke(
        tool: InkTool.highlighter,
        points: [PageInkPoint(190, 590, 0), PageInkPoint(300, 590, 10)],
      );
      expect(highlightedText([mark], chars).single, 'divide');
    });

    test('writing goes round scanned lines like printed ones', () {
      final printed = PrintedText([scannedBox(line, 600, 800)]);
      expect(printed.within(const InkBox(100, 585, 120, 595)), isNotEmpty);
      expect(printed.within(const InkBox(400, 585, 420, 595)), isEmpty);
    });
  });
}
