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
    final more = [...page, letter(580, 760), letter(520, 754, width: 80)];
    final kinds = await c.classify(more);
    expect(engine.sent.last, lessThan(40));
    expect(kinds.last, InkKind.drawing);
    expect(kinds[more.length - 2], InkKind.writing);
    expect(kinds.take(page.length), first); // the rest keep their answer
  });

  test(
    'after an engine error, the stand-in answer is kept and sorted again '
    'only with new ink near it (owner: slower and slower after 100 words)',
    () async {
      final engine = _Counting();
      var ok = false;
      final c = NearbyClassifier(engine, trusted: () => ok);
      // 30 lines of 18 letters.
      final page = [
        for (var l = 0; l < 30; l++)
          for (var k = 0; k < 18; k++) letter(40.0 + k * 30, 760.0 - l * 24),
      ];
      await c.classify(page);
      expect(c.lastFellBack, isTrue);
      // Nothing new: nothing sent again.
      await c.classify(page);
      expect(engine.sent, [page.length]);
      // One more letter on the top line: only its line and the ink near
      // it are sent, not the whole page.
      final more = [...page, letter(40.0 + 18 * 30, 760)];
      await c.classify(more);
      expect(engine.sent.last, lessThan(page.length ~/ 4));
      // Once the engine works again, what it sorts is kept, and every
      // stand-in is sorted again once (so none stays wrong).
      ok = true;
      final again = [...more, letter(40.0 + 19 * 30, 760)];
      await c.classify(again);
      expect(c.lastFellBack, isFalse);
      await c.classify(again);
      expect(engine.sent.last, greaterThan(page.length ~/ 2));
      final sentBefore = engine.sent.length;
      await c.classify(again);
      expect(engine.sent.length, sentBefore);
    },
  );

  test('the summary counts reads that fell back, and why', () {
    final r = ReadSummary(every: 2);
    expect(
      r.add({'totalMs': 5, 'sortMs': 2, 'fellBack': true, 'sortProblem': 'x'}),
      isNull,
    );
    final out = r.add({'totalMs': 5, 'sortMs': 2})!;
    expect(out['fellBack'], 1);
    expect(out['sortProblem'], 'x');
    expect(
      r.add({'totalMs': 5, 'sortMs': 2}) ?? r.add({'totalMs': 5, 'sortMs': 2})!,
      isNot(contains('fellBack')),
    );
  });

  test('reading times are logged as one summary every 20 reads', () {
    final r = ReadSummary();
    Map<String, Object?>? last;
    for (var i = 0; i < 40; i++) {
      final out = r.add({
        'strokes': 500,
        'sortMs': i,
        'sorted': 30,
        'engineCalls': 1,
        'totalMs': 100 + i,
        'queued': false,
      });
      if (i % 20 != 19) {
        expect(out, isNull);
      } else {
        last = out;
      }
    }
    expect(last!['reads'], 20);
    expect(last['worstMs'], 139);
    expect(last['engineCalls'], 20);
  });
}
