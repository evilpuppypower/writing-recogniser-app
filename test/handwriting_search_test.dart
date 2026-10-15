import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/handwriting_search.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart' show InkBox;

SearchWord w(int page, int line, double x, String text) => (
  page: page,
  line: line,
  box: InkBox(x, 700.0 - line * 30, x + 20, 710.0 - line * 30),
  text: text,
);

void main() {
  final words = [
    w(1, 0, 100, 'The'),
    w(1, 0, 130, 'quick'),
    w(1, 1, 100, 'brown'),
    w(1, 1, 130, 'fox'),
    w(2, 0, 100, 'QUICK'),
    w(2, 0, 130, 'thinking'),
  ];

  test('finds words, ignoring case, on every page, top first', () {
    final hits = searchHandwriting(words, 'quick');
    expect(hits.map((h) => h.page), [1, 2]);
    expect(hits.first.box.left, 130);
  });

  test('finds part of a word, and text running across words and lines', () {
    expect(searchHandwriting(words, 'ink').single.text, 'thinking');
    final across = searchHandwriting(words, 'quick  brown').single;
    expect(across.text, 'quick brown');
    expect(across.box.left, 100);
    expect(across.box.right, 150);
  });

  test('nothing for an empty search or no match', () {
    expect(searchHandwriting(words, '  '), isEmpty);
    expect(searchHandwriting(words, 'zebra'), isEmpty);
  });
}
