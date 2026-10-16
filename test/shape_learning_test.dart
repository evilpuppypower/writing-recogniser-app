import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/shape_learning.dart';
import 'package:writing_recogniser/core/shapes.dart';

void main() {
  test('a tidied shape taken back makes shapes like it stricter', () {
    final l = ShapeLearning();
    expect(l.accepts(ShapeKind.circle, 0.04), isTrue);
    // Once could be a slip.
    l.rejected(ShapeKind.circle, 0.04);
    expect(l.accepts(ShapeKind.circle, 0.04), isTrue);
    l.rejected(ShapeKind.circle, 0.03);
    // As rough as that one: not tidied any more; much closer: still is.
    expect(l.accepts(ShapeKind.circle, 0.04), isFalse);
    expect(l.accepts(ShapeKind.circle, 0.02), isTrue);
    // Other kinds aren't affected.
    expect(l.accepts(ShapeKind.rectangle, 0.04), isTrue);
    // Never stricter than [strictest].
    for (var i = 0; i < 10; i++) {
      l.rejected(ShapeKind.circle, 0.001);
    }
    expect(l.toleranceFor(ShapeKind.circle), ShapeLearning.strictest);
  });

  test('kept shapes slowly bring it back, and it is remembered', () {
    final l = ShapeLearning()
      ..rejected(ShapeKind.triangle, 0.03)
      ..rejected(ShapeKind.triangle, 0.03);
    final strict = l.toleranceFor(ShapeKind.triangle);
    l.kept(ShapeKind.triangle);
    expect(l.toleranceFor(ShapeKind.triangle), greaterThan(strict));
    expect(l.toleranceFor(ShapeKind.triangle), lessThan(ShapeLearning.usual));
    final back = ShapeLearning()..load(l.toJson());
    expect(
      back.toleranceFor(ShapeKind.triangle),
      l.toleranceFor(ShapeKind.triangle),
    );
    back.load('nonsense');
    expect(back.toleranceFor(ShapeKind.triangle), ShapeLearning.usual);
  });
}
