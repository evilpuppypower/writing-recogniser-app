import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/document_state.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/recent_pdfs.dart';
import 'package:writing_recogniser/core/stored_copy.dart';
import 'package:writing_recogniser/import/pdf_import_channel.dart';
import 'package:writing_recogniser/library/home_screen.dart';
import 'package:writing_recogniser/library/recent_store.dart';
import 'package:writing_recogniser/library/thumbnails.dart';
import 'package:writing_recogniser/settings/settings_controller.dart';

class FakeRecentStore extends RecentStore {
  FakeRecentStore(this.list);
  List<RecentPdf> list;

  @override
  Future<List<RecentPdf>> load() async => list;

  @override
  Future<void> save(List<RecentPdf> l) async => list = l;
}

class NoThumbnails extends Thumbnails {
  @override
  Future<File?> find(String cacheId) async => null;

  @override
  Future<void> ensure(
    String cacheId,
    String pdfPath, {
    List<PageStroke>? ink,
  }) async {}
}

RecentPdf recent(String name, {int day = 10}) => RecentPdf(
  uri: 'content://docs/$name',
  name: name,
  cacheId: '1_1_$name',
  lastOpened: DateTime(2026, 10, day, 12),
);

StoredCopy stored(String name, {bool pinned = false}) => StoredCopy(
  id: '1_1_$name',
  path: '/cache/imports/1_1_$name',
  size: 1,
  lastUsed: DateTime(2026, 10, 1),
  pinned: pinned,
);

void main() {
  late FakeRecentStore store;
  late List<StoredCopy> copies;
  late List<(String, bool, int)> pinCalls;
  late List<String> released;
  PickedPdf? Function(String uri) inspect = (_) => null;
  String? crash;
  Map<String, DocumentState> positions = {};
  Set<String> withInk = {};
  var crashCleared = false;

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 2560);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsScope(
        controller: SettingsController(const AppSettings(cachedPdfLimit: 5)),
        child: MaterialApp(
          home: HomeScreen(
            services: LibraryServices(
              pick: () async => null,
              inspect: (uri) async => inspect(uri),
              listCopies: () async => copies,
              setPinned: (c, pinned, keep) async =>
                  pinCalls.add((c.id, pinned, keep)),
              releaseAccess: (uri) async => released.add(uri),
              recents: store,
              thumbnails: NoThumbnails(),
              lastCrash: () async => crash,
              readingPositions: () async => positions,
              inkDocuments: () async => withInk,
              clearLastCrash: () async => crashCleared = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    store = FakeRecentStore([]);
    copies = [];
    pinCalls = [];
    released = [];
    inspect = (_) => null;
    crash = null;
    positions = {};
    crashCleared = false;
  });

  testWidgets('after a crash, offers the details once and clears them', (
    tester,
  ) async {
    crash = 'Crash at 2026-10-11\njava.lang.IllegalStateException: boom';
    await pumpHome(tester);
    expect(find.text('The app closed unexpectedly last time'), findsOneWidget);
    expect(find.textContaining('IllegalStateException: boom'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('The app closed unexpectedly last time'), findsNothing);
    expect(crashCleared, isTrue);
  });

  testWidgets('cards show where each PDF was left', (tester) async {
    store = FakeRecentStore([recent('Book.pdf'), recent('Notes.pdf', day: 9)]);
    positions = {
      '1_1_Book.pdf': DocumentState(
        id: '1_1_Book.pdf',
        lastPage: 12,
        pageCount: 450,
        updatedAt: DateTime(2026, 10, 11),
      ),
    };
    await pumpHome(tester);
    expect(find.text('p. 12/450'), findsOneWidget);
    expect(find.byTooltip('Opens on page 12'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('no crash: no dialog', (tester) async {
    await pumpHome(tester);
    expect(find.text('The app closed unexpectedly last time'), findsNothing);
    expect(crashCleared, isFalse);
  });

  testWidgets('empty library: open buttons and a hint', (tester) async {
    await pumpHome(tester);
    expect(find.text('Open a PDF from this tablet'), findsOneWidget);
    expect(find.text('Open sample PDF (300 pages)'), findsNothing);
    expect(find.text('PDFs you open will appear here.'), findsOneWidget);
    expect(find.text('Pinned'), findsNothing);
  });

  testWidgets('pinned first, then recent; stored copies get a check mark', (
    tester,
  ) async {
    store = FakeRecentStore([
      recent('B.pdf', day: 10),
      recent('C.pdf', day: 9),
      recent('A.pdf', day: 8),
    ]);
    copies = [stored('A.pdf', pinned: true), stored('B.pdf')];
    await pumpHome(tester);

    expect(find.text('Pinned'), findsOneWidget);
    // A is pinned, so it shows only under Pinned, not again under Recent.
    expect(find.text('A.pdf'), findsOneWidget);
    expect(find.text('B.pdf'), findsOneWidget);
    expect(find.text('C.pdf'), findsOneWidget);
    final pinnedY = tester.getTopLeft(find.text('A.pdf')).dy;
    final recentY = tester.getTopLeft(find.text('Recent')).dy;
    expect(pinnedY, lessThan(recentY));

    // Check marks on A and B (stored), not on C; one pin badge (A).
    expect(
      find.byTooltip('Stored in the app: opens instantly'),
      findsNWidgets(2),
    );
    expect(find.byTooltip('Pinned: always kept'), findsOneWidget);
  });

  testWidgets('a moved or deleted file says so and can be removed', (
    tester,
  ) async {
    store = FakeRecentStore([recent('Gone.pdf')]);
    await pumpHome(tester);

    await tester.tap(find.text('Gone.pdf'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Can't find Gone.pdf"), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(store.list, isEmpty);
    expect(find.text('Gone.pdf'), findsNothing);
  });

  testWidgets('a PDF with your ink is kept automatically and says why', (
    tester,
  ) async {
    store = FakeRecentStore([recent('Notes.pdf'), recent('Plain.pdf')]);
    copies = [stored('Notes.pdf'), stored('Plain.pdf')];
    withInk = {'1_1_Notes.pdf'};
    addTearDown(() => withInk = {});
    await pumpHome(tester);
    expect(pinCalls, [('1_1_Notes.pdf', true, 5)]);

    copies = [stored('Notes.pdf', pinned: true), stored('Plain.pdf')];
    await tester.longPress(find.text('Notes.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('Kept because it has your ink'), findsOneWidget);
    expect(find.text('Unpin'), findsNothing);
  });

  testWidgets('long-press a stored PDF to pin it (uses the storage limit)', (
    tester,
  ) async {
    store = FakeRecentStore([recent('B.pdf')]);
    copies = [stored('B.pdf')];
    await pumpHome(tester);

    await tester.longPress(find.text('B.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('Stored in the app: opens instantly'), findsOneWidget);
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();
    expect(pinCalls, [('1_1_B.pdf', true, 5)]);
  });

  testWidgets('long-press a PDF that is not stored: no pin, can remove', (
    tester,
  ) async {
    store = FakeRecentStore([recent('C.pdf')]);
    await pumpHome(tester);

    await tester.longPress(find.text('C.pdf'));
    await tester.pumpAndSettle();
    expect(
      find.text('Not stored: will be imported again when opened'),
      findsOneWidget,
    );
    expect(find.text('Pin'), findsNothing);
    await tester.tap(find.text('Remove from Recent'));
    await tester.pumpAndSettle();
    expect(store.list, isEmpty);
    // The app gives back its access to the original file.
    expect(released, ['content://docs/C.pdf']);
  });
}
