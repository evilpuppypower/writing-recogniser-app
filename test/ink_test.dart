import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/handwriting/ink_controller.dart';

void main() {
  group('ink model', () {
    test('strokes survive a JSON round trip (position, time, pressure)', () {
      final strokes = [
        const InkStroke([
          InkPoint(10.123, 20.456, 1760000000000, 0.4321),
          InkPoint(11, 21, 1760000000016, 0.5),
        ]),
        const InkStroke([InkPoint(30, 40, 1760000000500)]),
      ];
      final back = strokesFromJson(
        jsonDecode(jsonEncode(strokesToJson(strokes))) as List,
      );
      expect(back, hasLength(2));
      final p = back.first.points.first;
      expect(p.x, closeTo(10.12, 1e-9));
      expect(p.y, closeTo(20.46, 1e-9));
      expect(p.t, 1760000000000);
      expect(p.pressure, closeTo(0.432, 1e-9));
      expect(back.last.points.single.pressure, 0.5);
    });

    test('bounds', () {
      final b = InkBounds.of([
        const InkStroke([InkPoint(5, 7, 0), InkPoint(20, 3, 1)]),
        const InkStroke([InkPoint(-2, 9, 2)]),
      ])!;
      expect([b.left, b.top, b.right, b.bottom], [-2, 3, 20, 9]);
      expect(InkBounds.of([]), isNull);
    });
  });

  group('InkController', () {
    test('records a stroke from start to end', () {
      final c = InkController();
      c.startStroke(const InkPoint(0, 0, 0));
      c.addPoint(const InkPoint(1, 1, 10));
      final s = c.endStroke()!;
      expect(s.points, hasLength(2));
      expect(c.strokes, hasLength(1));
      expect(c.current, isNull);
    });

    test('cancel drops the stroke in progress', () {
      final c = InkController()..startStroke(const InkPoint(0, 0, 0));
      c.cancelStroke();
      expect(c.isEmpty, isTrue);
    });

    test('eraseAt removes whole strokes it touches, nothing else', () {
      final c = InkController();
      for (final x in [0.0, 100.0]) {
        c.startStroke(InkPoint(x, 0, 0));
        c.addPoint(InkPoint(x + 10, 0, 1));
        c.endStroke();
      }
      expect(c.eraseAt(50, 50), isFalse);
      expect(c.eraseAt(105, 4), isTrue);
      expect(c.strokes, hasLength(1));
      expect(c.strokes.single.points.first.x, 0);
    });

    test('eraseAt catches the line between widely spaced points', () {
      final c = InkController()
        ..startStroke(const InkPoint(0, 0, 0))
        ..addPoint(const InkPoint(200, 0, 1));
      c.endStroke();
      // Far from both points, but right on the line between them.
      expect(c.eraseAt(100, 5), isTrue);
      expect(c.strokes, isEmpty);
    });

    test('undo and clear', () {
      final c = InkController();
      for (var i = 0; i < 3; i++) {
        c.startStroke(InkPoint(i.toDouble(), 0, i));
        c.endStroke();
      }
      c.undo();
      expect(c.strokes, hasLength(2));
      c.clear();
      expect(c.isEmpty, isTrue);
    });
  });
}
