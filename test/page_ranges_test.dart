import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ranges.dart';

void main() {
  test('single pages, ranges and open-ended ranges', () {
    expect(parsePageRanges('2', 10), {2});
    expect(parsePageRanges('1-3, 7', 10), {1, 2, 3, 7});
    expect(parsePageRanges(' 8- ', 10), {8, 9, 10});
    expect(parsePageRanges('3–4;9', 10), {3, 4, 9}, reason: 'en dash, ;');
  });

  test('mistakes give a message to show', () {
    for (final bad in ['', 'abc', '0', '11', '5-2', '1-2-3']) {
      expect(
        () => parsePageRanges(bad, 10),
        throwsA(isA<FormatException>()),
        reason: bad,
      );
    }
    expect(
      () => parsePageRanges('12', 10),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('1-10'),
        ),
      ),
    );
  });
}
