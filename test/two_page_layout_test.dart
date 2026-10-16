import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/viewer/two_page_layout.dart';

void main() {
  test('bookmarks in two-page view offer both pages showing', () {
    expect(pagePair(1, 5), [1, 2]);
    expect(pagePair(2, 5), [1, 2]);
    expect(pagePair(4, 5), [3, 4]);
    expect(pagePair(5, 5), [5]);
  });

  test('pages go in pairs, side by side, each row centred', () {
    const a4 = Size(595, 842);
    final r = twoPageRects([a4, a4, a4], 8);
    expect(r.pages[0].top, r.pages[1].top, reason: '1 and 2 side by side');
    expect(r.pages[1].left, r.pages[0].right + 8);
    expect(r.pages[2].top, r.pages[0].bottom + 8, reason: '3 on the next row');
    // The odd page out is centred.
    expect(r.pages[2].center.dx, closeTo(r.document.width / 2, 1e-9));
    expect(r.document.width, 595 * 2 + 8 * 3);
    expect(r.document.height, 842 * 2 + 8 * 3);
  });

  test('a landscape page next to a portrait one is centred in its row', () {
    final r = twoPageRects([const Size(842, 595), const Size(595, 842)], 8);
    expect(r.pages[0].center.dy, closeTo(r.pages[1].center.dy, 1e-9));
  });

  test('no pages, no layout', () {
    expect(twoPageRects(const [], 8).pages, isEmpty);
  });
}
