import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/shapes.dart';

/// [n] points along [at] (0..1 round the shape), with a little wobble, not
/// quite closed.
List<PageInkPoint> drawn((double, double) Function(double u) at, {int n = 80}) {
  final rng = math.Random(4);
  return [
    for (var i = 0; i < n; i++)
      () {
        final (x, y) = at(i / n * 0.97);
        return PageInkPoint(
          x + rng.nextDouble() * 3 - 1.5,
          y + rng.nextDouble() * 3 - 1.5,
          1000 + i * 10,
          0.5,
        );
      }(),
  ];
}

(double, double) Function(double) polygon(List<(double, double)> c) => (u) {
  final f = u * c.length;
  final k = f.floor() % c.length;
  final a = c[k], b = c[(k + 1) % c.length], s = f - f.floor();
  return (a.$1 + (b.$1 - a.$1) * s, a.$2 + (b.$2 - a.$2) * s);
};

void main() {
  test('a wobbly circle becomes a circle', () {
    final s = tidyShape(
      drawn(
        (u) => (
          300 + 50 * math.cos(2 * math.pi * u),
          400 + 50 * math.sin(2 * math.pi * u),
        ),
      ),
    )!;
    expect(s.kind, ShapeKind.circle);
    for (final p in s.points) {
      expect(
        math.sqrt(math.pow(p.x - 300, 2) + math.pow(p.y - 400, 2)),
        closeTo(50, 3),
      );
    }
    // Closed, with times from the first point to the last.
    expect(s.points.first.x, closeTo(s.points.last.x, 1e-6));
    expect(s.points.first.t, 1000);
  });

  test('an oval becomes an ellipse', () {
    final s = tidyShape(
      drawn(
        (u) => (
          300 + 90 * math.cos(2 * math.pi * u),
          400 + 40 * math.sin(2 * math.pi * u),
        ),
      ),
    )!;
    expect(s.kind, ShapeKind.ellipse);
  });

  test('a box becomes a rectangle', () {
    final s = tidyShape(
      drawn(polygon([(100, 500), (260, 500), (260, 420), (100, 420)])),
    )!;
    expect(s.kind, ShapeKind.rectangle);
    expect(s.points, hasLength(5));
  });

  // Owner: tilted shapes should be recognised at their tilt.
  (double, double) turned((double, double) p, double degrees) {
    final a = degrees * math.pi / 180;
    final dx = p.$1 - 200, dy = p.$2 - 450;
    return (
      200 + dx * math.cos(a) - dy * math.sin(a),
      450 + dx * math.sin(a) + dy * math.cos(a),
    );
  }

  double sideAngle(List<PageInkPoint> p) =>
      math.atan2(p[1].y - p[0].y, p[1].x - p[0].x) * 180 / math.pi;

  for (final degrees in <double>[20, 45, -30]) {
    test(
      'a box drawn at $degrees degrees becomes a rectangle at that tilt',
      () {
        final corners = [
          for (final c in [
            (120.0, 490.0),
            (280.0, 490.0),
            (280.0, 410.0),
            (120.0, 410.0),
          ])
            turned(c, degrees),
        ];
        final s = tidyShape(drawn(polygon(corners)))!;
        expect(s.kind, ShapeKind.rectangle);
        expect(s.points, hasLength(5));
        // Each corner near a corner of the drawn box.
        for (final p in s.points) {
          final near = corners
              .map(
                (c) => math.sqrt(
                  math.pow(p.x - c.$1, 2) + math.pow(p.y - c.$2, 2),
                ),
              )
              .reduce(math.min);
          expect(near, lessThan(5));
        }
        // Sides along the tilt (or square to it).
        final a = (sideAngle(s.points) - degrees) % 90;
        expect(math.min(a, 90 - a), lessThan(2));
      },
    );
  }

  test('an oval drawn at 30 degrees becomes an ellipse at that tilt', () {
    final s = tidyShape(
      drawn(
        (u) => turned((
          200 + 90 * math.cos(2 * math.pi * u),
          450 + 40 * math.sin(2 * math.pi * u),
        ), 30),
      ),
    )!;
    expect(s.kind, ShapeKind.ellipse);
    // Its longest reach from the middle points along the tilt.
    final far = s.points.reduce(
      (a, b) =>
          math.pow(a.x - 200, 2) + math.pow(a.y - 450, 2) >
              math.pow(b.x - 200, 2) + math.pow(b.y - 450, 2)
          ? a
          : b,
    );
    final angle = math.atan2(far.y - 450, far.x - 200) * 180 / math.pi % 180;
    expect(angle, closeTo(30, 4));
  });

  test('a box drawn nearly level stays level', () {
    final corners = [
      for (final c in [
        (120.0, 490.0),
        (280.0, 490.0),
        (280.0, 410.0),
        (120.0, 410.0),
      ])
        turned(c, 3),
    ];
    final s = tidyShape(drawn(polygon(corners)))!;
    expect(s.kind, ShapeKind.rectangle);
    expect(s.points[0].y, closeTo(s.points[1].y, 1e-6));
  });

  test('a triangle becomes a triangle', () {
    final s = tidyShape(drawn(polygon([(100, 400), (200, 560), (300, 400)])))!;
    expect(s.kind, ShapeKind.triangle);
    expect(s.points, hasLength(4));
  });

  test('open strokes, lines and scribbles are left alone', () {
    // Half a circle (open).
    expect(
      tidyShape(
        drawn(
          (u) => (
            300 + 50 * math.cos(math.pi * u),
            400 + 50 * math.sin(math.pi * u),
          ),
        ),
      ),
      isNull,
    );
    // A straight line.
    expect(tidyShape(drawn((u) => (100 + 200 * u, 300.0))), isNull);
    // A zigzag that comes back to the start: not close to any shape.
    expect(
      tidyShape(
        drawn(
          polygon([(100, 100), (200, 200), (120, 220), (220, 100), (150, 260)]),
        ),
      ),
      isNull,
    );
  });

  testWidgets('holding the pen still at the end of a circle tidies it', (
    tester,
  ) async {
    final ink = DocumentInkController();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 612,
            height: 792,
            child: PageInkLayer(
              pageNumber: 1,
              geometry: PageGeometry(width: 612, height: 792),
              viewWidth: 612,
              controller: ink,
            ),
          ),
        ),
      ),
    );
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    Offset at(double u) => Offset(
      300 + 60 * math.cos(2 * math.pi * u),
      300 + 60 * math.sin(2 * math.pi * u),
    );
    await pen.down(at(0));
    for (var i = 1; i <= 40; i++) {
      await pen.moveTo(at(i / 40 * 0.98));
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(milliseconds: 600)); // held still
    await pen.up();
    await tester.pump();
    final s = ink.ink.strokesOn(1).single;
    expect(s.points, hasLength(65), reason: 'a tidy circle');
    expect(s.notWriting, isTrue, reason: 'never read as a letter');
  });
}
