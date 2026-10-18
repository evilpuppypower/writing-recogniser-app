import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_prediction.dart';

/// Feeds [p] with a pen moving along [path] (pixels at time ms), sampled
/// at 240 a second, for [ms]; returns the time of the last sample (µs).
int feed(
  InkPredictor p,
  (double, double) Function(double ms) path, {
  double ms = 60,
}) {
  var t = 0;
  for (var at = 0.0; at <= ms; at += 1000 / 240) {
    final (x, y) = path(at);
    t = (at * 1000).round();
    p.add(x, y, t);
  }
  return t;
}

double dist((double, double) a, (double, double) b) =>
    math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

void main() {
  test('a straight line is continued where the pen is going', () {
    final p = InkPredictor();
    // 0.5 px per ms to the right, 0.25 down.
    (double, double) path(double ms) => (10 + ms * 0.5, 20 + ms * 0.25);
    final t = feed(p, path);
    final guess = p.predict(12000);
    expect(guess, isNotEmpty);
    final end = guess.last;
    expect(dist(end, path(t / 1000 + 12)), lessThan(0.05));
    // Several points, so the tip is a smooth line, not one jump.
    expect(guess.length, greaterThanOrEqualTo(3));
  });

  test('a circle (an "o") is followed round, not shot off along a tangent', () {
    // A 40 px circle once every 400 ms: brisk handwriting.
    const r = 20.0, period = 400.0;
    (double, double) path(double ms) => (
      100 + r * math.cos(2 * math.pi * ms / period),
      100 + r * math.sin(2 * math.pi * ms / period),
    );
    final p = InkPredictor();
    final t = feed(p, path, ms: 200);
    final now = t / 1000;
    final end = p.predict(16000).last;
    final truth = path(now + 16);
    // Where a guess along the tangent alone would land.
    final speed = 2 * math.pi * r / period; // px per ms
    final a = 2 * math.pi * now / period;
    final tangent = (
      path(now).$1 - math.sin(a) * speed * 16,
      path(now).$2 + math.cos(a) * speed * 16,
    );
    expect(dist(end, truth), lessThan(dist(tangent, truth)));
    expect(dist(end, truth), lessThan(1.0));
    // It stays near the circle.
    expect(dist(end, (100, 100)), closeTo(r, 1.0));
  });

  test('noisy samples give a guess within a couple of pixels', () {
    final rnd = math.Random(7);
    (double, double) path(double ms) => (ms * 0.6, 50 + 10 * math.sin(ms / 50));
    final p = InkPredictor();
    var errors = <double>[];
    p.onError = errors.add;
    for (var at = 0.0; at <= 400; at += 1000 / 240) {
      final (x, y) = path(at);
      p.add(
        x + (rnd.nextDouble() - 0.5),
        y + (rnd.nextDouble() - 0.5),
        (at * 1000).round(),
      );
      p.predict(12000);
    }
    errors.sort();
    expect(errors.length, greaterThan(50));
    expect(errors[errors.length ~/ 2], lessThan(2.0));
  });

  test('the guess never runs further than its limit', () {
    final p = InkPredictor(maxPixels: 10);
    final t = feed(p, (ms) => (ms * 5, 0)); // a very fast flick
    final end = p.predict(30000).last;
    final last = (t / 1000 * 5, 0.0);
    expect(dist(end, last), closeTo(10, 0.01));
  });

  test('no guess when the pen stands still, pauses, or just started', () {
    final still = InkPredictor();
    feed(still, (ms) => (5, 5));
    expect(still.predict(12000), isEmpty);

    final paused = InkPredictor()
      ..add(0, 0, 0)
      ..add(1, 0, 4000)
      ..add(2, 0, 8000)
      ..add(30, 0, 60000); // 52 ms without a point
    expect(paused.predict(12000), isEmpty);

    final fresh = InkPredictor()
      ..add(0, 0, 0)
      ..add(1, 0, 4000);
    expect(fresh.predict(12000), isEmpty, reason: 'two points');

    final off = InkPredictor();
    feed(off, (ms) => (ms, 0));
    expect(off.predict(0), isEmpty, reason: 'lead turned off');
  });

  test('points at the same moment, and reset, are handled', () {
    final p = InkPredictor()
      ..add(0, 0, 0)
      ..add(2, 0, 4000)
      ..add(3, 0, 4000) // same time: replaces the one before
      ..add(6, 0, 8000)
      ..add(9, 0, 12000);
    expect(p.predict(8000), isNotEmpty);
    p.reset();
    expect(p.predict(8000), isEmpty);
  });

  test('each guess is checked against where the pen really went', () {
    final p = InkPredictor();
    final misses = <double>[];
    p.onError = misses.add;
    feed(p, (ms) => (ms * 0.5, 0), ms: 40);
    p.predict(12000);
    // The pen carried straight on: the guess was right.
    p.add(40 * 0.5 + 4.16 * 0.5, 0, 44167);
    expect(misses, hasLength(1));
    expect(misses.single, lessThan(0.1));
    // A point after the guess's reach isn't compared.
    p.predict(4000);
    p.add(30, 0, 60000);
    expect(misses, hasLength(1));
  });
}
