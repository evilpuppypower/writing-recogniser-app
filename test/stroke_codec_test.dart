import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_codec.dart';

/// What the JSON form kept, to compare with.
PageStroke viaJson(PageStroke s) => PageStroke.fromJson(
  jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>,
);

void main() {
  test('keeps exactly what the JSON form keeps, every field', () {
    final rnd = math.Random(3);
    final strokes = [
      PageStroke(
        points: [
          for (var i = 0; i < 300; i++)
            PageInkPoint(
              rnd.nextDouble() * 900,
              rnd.nextDouble() * 1200,
              1760000000000 + i * 4,
              rnd.nextDouble(),
            ),
        ],
        colorArgb: 0xFF1565C0,
        width: 2.5,
        tool: InkTool.highlighter,
        arrow: true,
        notWriting: true,
        manualWord: 'w1',
      ),
      const PageStroke(
        points: [PageInkPoint(10.004, -3.996, 5, 0.5)],
        tool: InkTool.text,
      ).withTyped('g7', 'héllo wörld ✓'),
    ];
    for (final s in strokes) {
      final back = decodeStroke(encodeStroke(s));
      expect(back.toJson(), viaJson(s).toJson());
    }
  });

  test('times far apart (a stroke held for weeks) and empty strokes', () {
    const s = PageStroke(
      points: [PageInkPoint(1, 2, 0, 0.2), PageInkPoint(3, 4, 5000000000, 1)],
    );
    expect(decodeStroke(encodeStroke(s)).toJson(), viaJson(s).toJson());
    const empty = PageStroke(points: []);
    expect(decodeStroke(encodeStroke(empty)).points, isEmpty);
  });

  test('about a third the size of the JSON form', () {
    final s = PageStroke(
      points: [
        for (var j = 0; j < 300; j++)
          PageInkPoint(
            100 + j * 0.37,
            200 + j * 0.219,
            1760000000000 + j * 4,
            (j % 100) / 100,
          ),
      ],
    );
    final json = utf8.encode(jsonEncode(s.toJson())).length;
    expect(encodeStroke(s).length, lessThan(json / 2.3));
  });

  test('damaged bytes are refused, not misread', () {
    final good = encodeStroke(
      const PageStroke(points: [PageInkPoint(1, 2, 3), PageInkPoint(4, 5, 6)]),
    );
    expect(() => decodeStroke(Uint8List(0)), throwsFormatException);
    expect(
      () => decodeStroke(Uint8List.fromList([9, ...good.skip(1)])),
      throwsFormatException,
    );
    expect(
      () => decodeStroke(Uint8List.sublistView(good, 0, good.length - 3)),
      throwsFormatException,
    );
  });
}
