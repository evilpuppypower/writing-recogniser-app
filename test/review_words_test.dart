import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/settings/review_words.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';

RecognizedWord word(
  String text,
  String key, {
  int line = 0,
  double left = 0,
  bool unsure = false,
  bool corrected = false,
  bool checked = false,
  bool ink = true,
}) => RecognizedWord(
  text: text,
  alternatives: const ['alt'],
  box: InkBox(left, 0, left + 10, 10),
  line: line,
  key: key,
  unsure: unsure,
  corrected: corrected,
  checked: checked,
  ink: ink
      ? const [
          InkStroke([InkPoint(0, 0, 0), InkPoint(5, 5, 10)]),
        ]
      : const [],
);

String page(List<RecognizedWord> words) => jsonEncode({
  'seen': ['a'],
  'words': [for (final w in words) w.toJson()],
});

void main() {
  test('unsure words first, then the rest in page order; done ones and '
      'the open PDF left out', () {
    final items = wordsToReview({
      'b': {
        2: page([word('late', 'k5', line: 1), word('early', 'k4')]),
      },
      'a': {
        1: page([
          word('right', 'k1', checked: true),
          word('fixed', 'k2', corrected: true),
          word('maybe', 'k3', unsure: true, left: 40),
          word('plain', 'k6', left: 20),
          word('noink', 'k7', ink: false),
        ]),
      },
      'open': {
        1: page([word('skip', 'k8', unsure: true)]),
      },
    }, skipDocument: 'open');
    expect(items.map((i) => i.word.text), ['maybe', 'plain', 'early', 'late']);
    expect(items.first.documentId, 'a');
    expect(items.first.page, 1);
  });

  test('"right" marks the word checked; a fix keeps the old reading', () {
    final json = page([word('cat', 'k1', unsure: true), word('dog', 'k2')]);
    final right = answerWord(json, 'k1')!;
    var w = RecognizedWord.fromJson(
      ((jsonDecode(right) as Map)['words'] as List).first
          as Map<String, Object?>,
    );
    expect(w.checked, isTrue);
    expect(w.unsure, isFalse);
    expect(w.text, 'cat');
    expect((jsonDecode(right) as Map)['seen'], ['a'], reason: 'rest kept');

    final fixed = answerWord(json, 'k2', text: ' god ')!;
    w = RecognizedWord.fromJson(
      ((jsonDecode(fixed) as Map)['words'] as List).last
          as Map<String, Object?>,
    );
    expect(w.text, 'god');
    expect(w.corrected, isTrue);
    expect(w.alternatives.first, 'dog');
    // Typing the same reading counts as "right".
    final same = answerWord(json, 'k2', text: 'dog')!;
    expect(
      RecognizedWord.fromJson(
        ((jsonDecode(same) as Map)['words'] as List).last
            as Map<String, Object?>,
      ).checked,
      isTrue,
    );
    expect(answerWord(json, 'gone'), isNull);
  });

  test(
    'a checked word stays checked when saved, until it reads differently',
    () {
      final w = word('cat', 'k', checked: true);
      expect(RecognizedWord.fromJson(w.toJson()).checked, isTrue);
      expect(w.copyWith(unsure: false).checked, isTrue);
      expect(w.copyWith(text: 'cut').checked, isFalse);
    },
  );
}
