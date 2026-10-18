import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/document_state.dart';
import 'package:writing_recogniser/core/ink_store.dart';
import 'package:writing_recogniser/viewer/adaptive_actions.dart';
import 'package:writing_recogniser/viewer/pdf_viewer_screen.dart';

/// The viewer's title bar as it is once a PDF is open (owner: in portrait
/// the buttons covered the back button and the title), with the widest
/// buttons it can have.
List<BarItem> _items(List<String> tapped) {
  BarItem icon(IconData i, String name) => BarItem(
    bar: IconButton(
      tooltip: name,
      icon: Icon(i),
      onPressed: () => tapped.add(name),
    ),
    menu: () => [barMenuItem(i, name, () => tapped.add(name))],
  );
  return [
    icon(Icons.search, 'Search'),
    BarItem(
      bar: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(icon: const Icon(Icons.undo), onPressed: () {}),
          IconButton(icon: const Icon(Icons.redo), onPressed: () {}),
        ],
      ),
      menu: () => [barMenuItem(Icons.undo, 'Undo', () {})],
    ),
    BarItem(
      bar: TextButton.icon(
        icon: const Icon(Icons.find_in_page_outlined),
        label: const Text('Page 400 / 400'),
        onPressed: () {},
      ),
      menu: () => [barMenuItem(Icons.find_in_page, 'Go to a page', () {})],
    ),
    icon(Icons.bookmark_border, 'Bookmark this page'),
    icon(Icons.grid_view, 'All pages'),
    icon(Icons.toc, 'Contents and bookmarks'),
    icon(Icons.keyboard, 'Convert'),
    BarItem(
      bar: TypedSwitchButton(showTyped: ValueNotifier(false)),
      menu: () => [barMenuItem(Icons.text_snippet, 'Show typed', () {})],
    ),
    icon(Icons.text_fields, 'Labels'),
    icon(Icons.notes, 'Text panel'),
    icon(Icons.zoom_in_map, 'Writing box'),
    icon(Icons.auto_stories, 'Two pages'),
    icon(Icons.summarize_outlined, 'Highlights and notes'),
    icon(Icons.note_add_outlined, 'Add a blank page'),
    icon(Icons.pause_circle_outline, 'Read later'),
    icon(Icons.ios_share, 'Export'),
    icon(Icons.battery_saver, 'Battery saver is on'),
    const BarItem(bar: Text('400%'), menu: _none),
  ];
}

List<PopupMenuEntry<VoidCallback>> _none() => const [];

void main() {
  // Tablet sizes in portrait and landscape, a phone, and a large screen.
  const sizes = [
    Size(600, 960),
    Size(720, 1152),
    Size(800, 1280),
    Size(1152, 720),
    Size(1280, 800),
    Size(1920, 1200),
    Size(360, 780),
  ];
  for (final size in sizes) {
    for (final textScale in [1.0, 1.3]) {
      testWidgets('title bar fits at ${size.width.toInt()} x '
          '${size.height.toInt()}, text x$textScale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final tapped = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(textScale),
              ),
              child: Builder(
                builder: (context) => Scaffold(
                  appBar: AppBar(
                    leading: const BackButton(),
                    title: const Text(
                      'A rather long document name.pdf',
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [AdaptiveActions(items: _items(tapped))],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'nothing overflows');
        // ignore: avoid_print
        print(
          'W ${size.width} x$textScale: actions ${tester.getRect(find.byType(AdaptiveActions))} back ${tester.getRect(find.byType(BackButton))} '
          'title ${tester.getRect(find.text('A rather long document name.pdf'))} '
          'page ${find.text('Page 400 / 400').evaluate().isEmpty ? '-' : tester.getRect(find.ancestor(of: find.text('Page 400 / 400'), matching: find.byType(TextButton)).first).width} '
          'typed ${find.byType(TypedSwitchButton).evaluate().isEmpty ? '-' : tester.getRect(find.byType(TypedSwitchButton)).width} '
          'icon ${tester.getRect(find.byTooltip('Search')).width}',
        );
        final back = tester.getRect(find.byType(BackButton));
        final title = tester.getRect(
          find.text('A rather long document name.pdf'),
        );
        final actions = tester.getRect(find.byType(AdaptiveActions));
        expect(back.left, greaterThanOrEqualTo(0));
        expect(
          actions.left,
          greaterThanOrEqualTo(back.right),
          reason: 'buttons never cover the back button',
        );
        expect(actions.right, lessThanOrEqualTo(size.width));
        expect(title.width, greaterThan(80), reason: 'the title shows');
        expect(title.right, lessThanOrEqualTo(actions.left + 1));
        // Search is always on the bar.
        expect(find.byTooltip('Search').hitTestable(), findsOneWidget);
        // Whatever isn't on the bar is in "More", and works from there.
        final more = find.byTooltip('More').hitTestable();
        if (more.evaluate().isNotEmpty) {
          await tester.tap(more);
          await tester.pumpAndSettle();
          final entry = find.text('Battery saver is on');
          expect(entry, findsOneWidget);
          await tester.ensureVisible(entry);
          await tester.pumpAndSettle();
          await tester.tap(entry);
          await tester.pumpAndSettle();
          expect(tapped, ['Battery saver is on']);
        } else {
          expect(size.width, greaterThan(1300));
        }
      });
    }
  }

  testWidgets('buttons hidden in "More" can\'t be reached with a keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            leading: const BackButton(),
            title: const Text('Doc'),
            actions: [AdaptiveActions(items: _items([]))],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // The last item ("400%") doesn't fit: it's kept from the keyboard.
    expect(find.text('400%').hitTestable(), findsNothing);
    expect(
      find.ancestor(of: find.text('400%'), matching: find.byType(ExcludeFocus)),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byTooltip('Search'),
        matching: find.byType(ExcludeFocus),
      ),
      findsNothing,
    );
  });

  testWidgets('the real viewer\'s title bar fits in portrait', (tester) async {
    tester.view.physicalSize = const Size(720, 1152);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final never = Completer<Never>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PdfViewerScreen(
                  title: 'A rather long document name.pdf',
                  documentId: 'doc',
                  sourcePath: '/nowhere/doc.pdf',
                  openStore: () => never.future as Future<DocumentStateStore>,
                  openInkStore: () => never.future as Future<InkStore>,
                  viewerBuilder: (_, _, _) =>
                      throw StateError('not opened in this test'),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    final back = tester.getRect(find.byType(BackButton));
    final actions = tester.getRect(find.byType(AdaptiveActions));
    expect(actions.left, greaterThanOrEqualTo(back.right));
    expect(
      tester.getRect(find.text('A rather long document name.pdf')).width,
      greaterThan(80),
    );
    expect(find.byTooltip('More').hitTestable(), findsOneWidget);
  });
}
