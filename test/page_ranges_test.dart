import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ranges.dart';

void main() {
  test('single pages, ranges and open-ended ranges', () {
    expect(parsePageRanges('2', 10), {2});
    expect(parsePageRanges('1-3, 7', 10), {1, 2, 3, 7});
    expect(parsePageRanges(' 8- ', 10), {8, 9, 10});
    expect(parsePageRanges('3–4;9', 10), {3, 4, 9}, reason: 'en dash, ;');
  });

  test('any dash, spaces around it, and "to" (owner saw a wrong export)', () {
    for (final range in [
      '1-3',
      '1 - 3',
      '1 -3',
      '1- 3',
      '1\u20123', // figure dash
      '1\u20143', // em dash
      '1\u22123', // minus sign
      '1\u20113', // non-breaking hyphen
      '1 to 3',
      '1 TO 3',
      '1to3',
      '1 to3',
      '-3',
    ]) {
      expect(parsePageRanges(range, 5), {1, 2, 3}, reason: range);
    }
    expect(parsePageRanges('1 - 2, 4 to 5', 5), {1, 2, 4, 5});
    expect(parsePageRanges('4 -', 5), {4, 5});
  });

  test('pages written short for the preview', () {
    expect(describePages({1, 2, 3}), '1–3');
    expect(describePages({7, 1, 2, 3, 9, 10}), '1–3, 7, 9, 10');
    expect(describePages({5}), '5');
  });

  test('mistakes give a message to show', () {
    for (final bad in ['', 'abc', '0', '11', '5-2', '1-2-3', '-', 'to 5']) {
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
