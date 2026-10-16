import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/writing_rhythm.dart';

/// A letter 5 wide, 6 tall, at [x], written from [t] for 100 ms.
PageStroke letter(double x, int t, {double y = 700}) => PageStroke(
  points: [
    PageInkPoint(x, y, t),
    PageInkPoint(x + 2.5, y + 6, t + 50),
    PageInkPoint(x + 5, y, t + 100),
  ],
);

/// [n] letters side by side, with [gapMs] between one ending and the next
/// starting.
void write(WritingRhythm r, int n, int gapMs) {
  var t = 0;
  var prev = letter(0, t);
  for (var i = 1; i < n; i++) {
    t += 100 + gapMs;
    final next = letter(i * 6.0, t);
    r.wrote(prev, next);
    prev = next;
  }
}

void main() {
  test('a quick writer: the pause shortens, never below 0.4 s', () {
    final r = WritingRhythm(startMs: 800);
    write(r, 200, 120);
    expect(r.pauseMs, lessThan(800));
    expect(r.pauseMs, greaterThanOrEqualTo(WritingRhythm.minMs));
  });

  test('a slow writer pausing mid-word: the pause grows, at most 2.5 s', () {
    final r = WritingRhythm(startMs: 800);
    write(r, 200, 1100);
    expect(r.pauseMs, greaterThan(1100), reason: 'words not cut in half');
    expect(r.pauseMs, lessThanOrEqualTo(WritingRhythm.maxMs));
  });

  test('not until it has seen 20 mid-word pauses', () {
    final r = WritingRhythm(startMs: 800);
    write(r, 15, 100);
    expect(r.pauseMs, 800);
  });

  test('the space between words and moving to a new line don\'t count', () {
    final r = WritingRhythm(startMs: 800);
    // A word's width apart, and a line below: neither is mid-word.
    expect(r.wrote(letter(0, 0), letter(40, 300)), isFalse);
    expect(r.wrote(letter(0, 0), letter(0, 300, y: 680)), isFalse);
    expect(r.gaps, isEmpty);
    // Right beside it: counts.
    r.wrote(letter(0, 0), letter(6, 300));
    expect(r.gaps, [200]);
  });
}
