import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/writing_box.dart';

void main() {
  const start = WritingBoxTarget(page: 1, left: 0.05, top: 0.1, width: 0.4);

  test('moves along as the writing reaches its last fifth', () {
    expect(identical(start.follow(0.5, height: 0.1), start), isTrue);
    final along = start.follow(0.9, height: 0.1);
    expect(along.left, closeTo(0.25, 1e-9));
    expect(along.top, start.top);
  });

  test('at the end of a line, to the start of the next', () {
    var t = start;
    for (var i = 0; i < 3; i++) {
      t = t.next(height: 0.1);
    }
    // Stopped at the right edge, then the next line down.
    expect(t.left, closeTo(0.6, 1e-9));
    final line = t.next(height: 0.1);
    expect(line.left, 0.05);
    expect(line.top, closeTo(0.175, 1e-9));
    expect(t.back().left, closeTo(0.4, 1e-9));
  });

  test('past the foot of the page: onto the next page', () {
    const low = WritingBoxTarget(page: 2, left: 0.05, top: 0.95, width: 0.4);
    final next = low.overflow(height: 0.1, pageCount: 3);
    expect((next.page, next.top), (3, 0.05));
    // The last page: it stays.
    expect(low.overflow(height: 0.1, pageCount: 2).page, 2);
  });

  test('its height follows the strip\'s shape and the page\'s', () {
    // A strip 3x as wide as high on an A4-shaped page.
    expect(
      start.heightFor(1 / 3, 842 / 595),
      closeTo(0.4 / 3 * 595 / 842, 1e-9),
    );
  });
}
