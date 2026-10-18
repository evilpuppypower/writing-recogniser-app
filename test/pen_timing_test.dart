import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/pen_timing.dart';

void main() {
  test('pen-to-screen time is measured from the newest and oldest point', () {
    final pen = PenTiming();
    for (var f = 0; f < 10; f++) {
      final start = 1000000 + f * 8333; // 120 refreshes a second
      pen
        ..point(start - 6000)
        ..point(start - 2000)
        ..frameBegan(start)
        // The tablet's reading of the start is a little different.
        ..frameTimed(start + 500, start + 10000);
    }
    final s = pen.summary()!;
    expect(s['penFrames'], 10);
    expect(s['penMedianMs'], 12.0);
    expect(s['penOldestP90Ms'], 16.0);
    expect(s['writingHz'], 120);
    expect(pen.summary(), isNull, reason: 'starts again after a summary');
  });

  test('frames without new pen points, or never timed, are not counted', () {
    final pen = PenTiming()
      ..frameBegan(1000)
      ..frameTimed(1000, 9000) // nothing new was drawn
      ..point(20000)
      ..frameBegan(30000)
      ..frameTimed(90000, 99000); // a different frame
    expect(pen.summary(), isNull);
  });

  test('strokes with gaps, straightened lines and tip misses', () {
    final pen = PenTiming()
      ..stroke([0, 4, 8, 12])
      ..stroke([0, 4, 40, 44]) // 36 ms with no sample
      ..straightened()
      ..guessed(0.5)
      ..guessed(1.5)
      ..guessed(3.0);
    final s = pen.summary()!;
    expect(s['strokes'], 2);
    expect(s['pointsPerStroke'], 4);
    expect(s['strokesWithGaps'], 1);
    expect(s['worstGapMs'], 36);
    expect(s['straightened'], 1);
    expect(s['leadMissMedianPx'], 1.5);
    expect(s['leadMissP90Px'], 3.0);
    expect(s.containsKey('penFrames'), isFalse);
  });
}
