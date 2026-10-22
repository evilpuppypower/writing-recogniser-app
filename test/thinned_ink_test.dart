import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

void main() {
  // A letter written slowly: 300 samples a quarter of a point apart.
  final slow = [
    for (var i = 0; i < 300; i++)
      PageInkPoint(
        100 + 6 * math.cos(i / 20),
        100 + 6 * math.sin(i / 20),
        1000 + i * 4,
        0.5,
      ),
  ];

  test('zoomed out, points under half a pixel apart are left out', () {
    // Half a pixel at a quarter of a pixel per point: 2 points.
    final thin = thinnedPoints(slow, 2);
    expect(thin.length, lessThan(60));
    expect(thin.first, same(slow.first));
    expect(thin.last, same(slow.last));
    for (var i = 1; i < thin.length - 1; i++) {
      final dx = thin[i].x - thin[i - 1].x, dy = thin[i].y - thin[i - 1].y;
      expect(math.sqrt(dx * dx + dy * dy), greaterThanOrEqualTo(2 - 1e-9));
    }
  });

  test('zoomed in, nearly every point is drawn; off, all of them', () {
    expect(thinnedPoints(slow, 0.05).length, greaterThan(290));
    expect(thinnedPoints(slow, 0), same(slow));
    final two = slow.sublist(0, 2);
    expect(thinnedPoints(two, 5), same(two));
  });
}
