import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_classifier.dart';
import 'package:writing_recogniser/core/nearby_classifier.dart';
import 'package:writing_recogniser/core/page_ink.dart';

/// Says "drawing" for strokes wider than 50 pt, and counts what it's sent.
class _Counting implements InkClassifier {
  final sent = <int>[];

  @override
  Future<List<InkKind>> classify(List<PageStroke> strokes) async {
    sent.add(strokes.length);
    return [
      for (final s in strokes)
        s.points.last.x - s.points.first.x > 50
            ? InkKind.drawing
            : InkKind.writing,
    ];
  }
}

PageStroke letter(double x, double y, {double width = 5}) => PageStroke(
  points: [
    PageInkPoint(x, y, 0),
    PageInkPoint(x + width / 2, y + 6, 10),
    PageInkPoint(x + width, y, 20),
  ],
);

void main() {
  test('only new strokes and the ink around them are sorted again', () async {
    final engine = _Counting();
    final c = NearbyClassifier(engine);
    // A full page: 30 lines of 18 letters (540 strokes, owner's heavy page).
    final page = [
      for (var l = 0; l < 30; l++)
        for (var k = 0; k < 18; k++) letter(40.0 + k * 30, 760.0 - l * 24),
    ];
    final first = await c.classify(page);
    expect(engine.sent.last, page.length); // a new page: all of it
    expect(first.every((k) => k == InkKind.writing), isTrue);

    // Nothing new: nothing sent.
    await c.classify(page);
    expect(engine.sent, hasLength(1));

    // One more letter, and an underline under it: only what's near them.
    final more = [
      ...page,
      letter(580, 760),
      letter(520, 754, width: 80),
    ];
    final kinds = await c.classify(more);
    expect(engine.sent.last, lessThan(40));
    expect(kinds.last, InkKind.drawing);
    expect(kinds[more.length - 2], InkKind.writing);
    expect(kinds.take(page.length), first); // the rest keep their answer
  });
}
