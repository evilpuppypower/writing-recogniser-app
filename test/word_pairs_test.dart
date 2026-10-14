import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/training_data.dart';
import 'package:writing_recogniser/core/word_pairs.dart';

/// A letter-like stroke: 6 pt wide, 10 tall, bottom-left at (x, y).
PageStroke letter(double x, double y, int t, {String? mark}) => PageStroke(
  points: [
    PageInkPoint(x, y, t),
    PageInkPoint(x + 3, y + 10, t + 40),
    PageInkPoint(x + 6, y, t + 80),
  ],
  manualWord: mark,
);

List<PageStroke> word(double x, int n, int t, {String? mark}) => [
  for (var i = 0; i < n; i++) letter(x + i * 7, 700, t + i * 200, mark: mark),
];

int feature(WordPair p, String name) =>
    p.features[wordPairFeatures.indexOf(name)].round();

void main() {
  test('no "One word" marks: no examples', () {
    expect(wordPairs([...word(100, 3, 0), ...word(135, 2, 1000)]), isEmpty);
  });

  test('a marked word: its strokes are one word, its edge is a boundary', () {
    final pairs = wordPairs([
      ...word(100, 3, 0, mark: 'm'),
      ...word(135, 2, 1000), // unmarked neighbour: not counted on its own
    ]);
    expect([for (final p in pairs) p.sameWord], [true, true, false]);
    expect([for (final p in pairs) feature(p, 'rulesJoin')], [1, 1, 0]);
    for (final p in pairs) {
      expect(p.features, hasLength(wordPairFeatures.length));
    }
    expect(feature(pairs[2], 'gap'), 2); // 23 pt apart / 10 pt letters
  });

  test('a mark across a gap the rules split: an example they get wrong', () {
    final pairs = wordPairs([
      ...word(100, 3, 0, mark: 'm'),
      ...word(135, 2, 1000, mark: 'm'),
    ]);
    expect(pairs, hasLength(4));
    expect(pairs.every((p) => p.sameWord), isTrue);
    expect(pairs[2].features.last, 0); // the rules said two words
  });

  test('the training file carries the pairs, without ink', () {
    final ink = [...word(100, 3, 0, mark: 'm'), ...word(135, 2, 1000)];
    final zip = encodeTrainingData(
      corrections: const [],
      samples: const [],
      exportedAt: DateTime.utc(2026, 1, 7),
      pageInk: [
        (
          document: '1234_9_Private name.pdf',
          json: jsonEncode([for (final s in ink) s.toJson()]),
        ),
        (document: 'broken', json: 'not json'),
      ],
    );
    final entry = ZipDecoder().decodeBytes(zip).findFile(trainingDataEntry)!;
    final text = utf8.decode(entry.content);
    final doc = jsonDecode(text) as Map<String, dynamic>;
    expect(doc['version'], 3);
    expect(doc['wordPairFeatures'], wordPairFeatures);
    final pairs = (doc['wordPairs'] as List).cast<Map<String, dynamic>>();
    expect(pairs, hasLength(3));
    expect(
      pairs.first.keys,
      unorderedEquals(['features', 'sameWord', 'document']),
    );
    expect(pairs.first['document'], 1);
    expect(text, isNot(contains('Private name')));
  });
}
