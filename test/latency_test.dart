import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/latency.dart';

void main() {
  test('breakdown splits pen-lift-to-text time into steps', () {
    final t = LatencyBreakdown.fromTimes(
      penLift: 1000,
      sent: 1600,
      answered: 1750,
      shown: 1766,
    );
    expect(t.waitMs, 600);
    expect(t.engineMs, 150);
    expect(t.displayMs, 16);
    expect(t.totalMs, 766);
    expect(t.toJson()['totalMs'], 766);
  });

  test('a clock going backwards never gives negative time', () {
    final t = LatencyBreakdown.fromTimes(
      penLift: 2000,
      sent: 1990,
      answered: 2100,
      shown: 2100,
    );
    expect(t.waitMs, 0);
    expect(t.engineMs, 110);
  });

  test('median and formatting', () {
    expect(medianMs([]), isNull);
    expect(medianMs([5, 1, 3]), 3);
    expect(medianMs([4, 1, 3, 2]), 3);
    expect(formatMs(85), '85 ms');
    expect(formatMs(1234), '1.23 s');
  });
}
