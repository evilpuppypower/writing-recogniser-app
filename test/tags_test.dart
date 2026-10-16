import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/tags.dart';
import 'package:writing_recogniser/library/tags_sheet.dart';

void main() {
  group('suggestions', () {
    test('known tags in the name first, then words from the name', () {
      final s = suggestTags(
        name: 'Lecture 3 - Cell Biology (final).pdf',
        known: ['biology', 'Chemistry'],
      );
      expect(s.first, 'biology');
      expect(s, contains('Lecture'));
      expect(s, contains('Cell'));
      expect(s, isNot(contains('Chemistry')));
      expect(s.any((t) => t.toLowerCase() == 'final'), isFalse);
      expect(s.any((t) => t.toLowerCase() == 'pdf'), isFalse);
    });

    test('words the writing uses a lot, and known tags it mentions', () {
      final s = suggestTags(
        name: 'Notebook 16 Oct 2026, 09.15',
        contents: 'mitosis mitosis Mitosis mitosis chemistry chemistry the the',
        known: ['Chemistry'],
      );
      expect(s, ['Chemistry', 'Mitosis']);
    });

    test('its own tags aren\'t suggested again', () {
      final s = suggestTags(
        name: 'Biology notes',
        known: ['Biology'],
        current: {'Biology'},
      );
      expect(s, isEmpty);
    });

    test('handwriting text from saved pages', () {
      expect(
        handwritingText([
          '{"words":[{"text":"cell","x":1},{"text":"wall"}]}',
          '{"words":[{"text":"osmosis"}]}',
        ]).trim(),
        'cell wall osmosis',
      );
    });
  });

  test('a store keeps tags and documents\' tags', () async {
    final s = MemoryTagStore();
    await s.setDocumentTags(
      'a',
      {'Biology'},
      newTags: [const Tag('Biology', 1)],
    );
    expect(await s.tags(), [const Tag('Biology', 1)]);
    expect(await s.documentTags(), {
      'a': {'Biology'},
    });
    await s.deleteTag('Biology');
    expect(await s.tags(), isEmpty);
    expect(await s.documentTags(), isEmpty);
  });

  testWidgets('choosing tags: a suggestion, a new one with a colour', (
    tester,
  ) async {
    TagsChoice? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => chosen = await showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => const TagsSheet(
                documentName: 'Cell Biology.pdf',
                known: [Tag('Exams', 0xFF1E88E5)],
                current: {},
                suggestions: ['Biology'],
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Biology'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Year 2');
    await tester.tap(find.byTooltip('Colour: green'));
    await tester.pump();
    await tester.tap(find.byTooltip('Add this tag'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(chosen!.names, {'Biology', 'Year 2'});
    final made = {for (final t in chosen!.newTags) t.name: t.colourArgb};
    expect(made['Year 2'], tagColours[1]);
    expect(made.containsKey('Biology'), isTrue);
  });

  testWidgets('suggestions read from the writing follow', (tester) async {
    final more = Completer<List<String>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TagsSheet(
            documentName: 'Notes.pdf',
            known: const [],
            current: const {},
            suggestions: const ['Notes'],
            moreSuggestions: more.future,
          ),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    more.complete(['Notes', 'Osmosis']);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Osmosis'), findsOneWidget);
  });

  testWidgets('long-press on a tag opens it; deleting asks first', (
    tester,
  ) async {
    Tag? edited;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TagFilterRow(
            tags: const [Tag('Exams', 0xFF1E88E5)],
            selected: null,
            onSelected: (_) {},
            onEdit: (t) => edited = t,
          ),
        ),
      ),
    );
    await tester.longPress(find.text('Exams'));
    await tester.pumpAndSettle();
    expect(edited?.name, 'Exams');

    Object? result = 'none';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showModalBottomSheet<Object>(
              context: context,
              builder: (_) => const TagColourSheet(
                tag: Tag('Exams', 0xFF1E88E5),
                usedBy: 3,
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete this tag'));
    await tester.pumpAndSettle();
    expect(find.textContaining('all 3 documents'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this tag'), findsOneWidget);
    await tester.tap(find.text('Delete this tag'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(result, TagColourSheet.delete);
  });
}
