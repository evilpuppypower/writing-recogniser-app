import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/feedback/correction_store.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/settings/review_writing_screen.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';

import 'ink_store_test.dart' show MemoryInkStore;
import 'review_words_test.dart' show page, word;

class MemoryCorrections implements CorrectionStore {
  final saved = <CorrectionRecord>[];
  @override
  Future<void> add(CorrectionRecord c) async => saved.add(c);
  @override
  Future<List<CorrectionRecord>> all() async => saved;
}

void main() {
  testWidgets('a word is said to be right, the next one fixed, then done', (
    tester,
  ) async {
    final ink = MemoryInkStore()
      ..pages['doc'] = {
        1: [
          const PageStroke(points: [PageInkPoint(1, 1, 1)]),
        ],
      }
      ..texts['doc'] = {
        1: page([word('cat', 'k1', unsure: true), word('dgo', 'k2')]),
      };
    final corrections = MemoryCorrections();
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewWritingScreen(
          openInk: () async => ink,
          openCorrections: () async => corrections,
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();
    expect(find.text('cat'), findsOneWidget);
    expect(find.textContaining('Word 1 of 2'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Right'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    RecognizedWord saved(int i) => RecognizedWord.fromJson(
      ((jsonDecode(ink.texts['doc']![1]!) as Map)['words'] as List)[i]
          as Map<String, Object?>,
    );
    expect(saved(0).checked, isTrue);
    expect(find.text('dgo'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'dog');
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Save this word'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(saved(1).text, 'dog');
    expect(saved(1).corrected, isTrue);
    expect(corrections.saved.single.recognized, 'dgo');
    expect(corrections.saved.single.corrected, 'dog');
    expect(corrections.saved.single.strokes, isNotEmpty, reason: 'with ink');
    expect(find.textContaining('All done for now: 2 words'), findsOneWidget);
  });

  testWidgets('nothing to review says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewWritingScreen(openInk: () async => MemoryInkStore()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing to review'), findsOneWidget);
  });
}
