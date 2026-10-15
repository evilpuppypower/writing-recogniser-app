import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:writing_recogniser/core/document_state.dart';
import 'package:writing_recogniser/core/ink_store.dart';
import 'package:writing_recogniser/viewer/pdf_viewer_screen.dart';

void main() {
  testWidgets('the screen shows "Opening…" without errors before the PDF '
      'viewer exists', (tester) async {
    // Storage that never answers keeps the PDF "opening".
    final never = Completer<Never>();
    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewerScreen(
          title: 'Big.pdf',
          documentId: 'big',
          openStore: () => never.future as Future<DocumentStateStore>,
          openInkStore: () => never.future as Future<InkStore>,
          viewerBuilder: (_, _, _) =>
              throw StateError('not opened in this test'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.text('Opening Big.pdf…'), findsOneWidget);
    expect(find.text('Big.pdf'), findsOneWidget); // the title bar
    // Search waits until the PDF is open.
    final search = find.byTooltip('Search the PDF and your handwriting');
    expect(search, findsOneWidget);
    await tester.tap(search);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('title bar and back button work while the PDF is still '
      'loading inside the viewer', (tester) async {
    final store = _MemoryStore();
    final inkNever = Completer<Never>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PdfViewerScreen(
                    title: 'Big.pdf',
                    documentId: 'big',
                    openStore: () async => store,
                    openInkStore: () => inkNever.future as Future<InkStore>,
                    // The viewer exists, but its PDF never finishes loading,
                    // so its controller is never ready.
                    viewerBuilder: (controller, params, page) => PdfViewer(
                      _neverLoads(),
                      controller: controller,
                      params: params,
                      initialPageNumber: page,
                    ),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('Big.pdf'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Big.pdf'), findsNothing);
  });

  testWidgets('a PDF that is still opening can be cancelled', (tester) async {
    final never = Completer<Never>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PdfViewerScreen(
                      title: 'Big.pdf',
                      documentId: 'big',
                      openStore: () =>
                          never.future as Future<DocumentStateStore>,
                      openInkStore: () => never.future as Future<InkStore>,
                      viewerBuilder: (_, _, _) =>
                          throw StateError('not opened in this test'),
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Opening Big.pdf…'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Opening Big.pdf…'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    // The 5 s "still opening" timer went with the screen.
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
  });
}

class _MemoryStore implements DocumentStateStore {
  @override
  Future<DocumentState?> get(String id) async => null;
  @override
  Future<Map<String, DocumentState>> all() async => {};
  @override
  Future<void> save(DocumentState state) async {}
}

/// A PDF source that never finishes loading.
PdfDocumentRef _neverLoads() => PdfDocumentRefByLoader(
  (_) => Completer<PdfDocument>().future,
  key: PdfDocumentRefKey('never-loads'),
);
