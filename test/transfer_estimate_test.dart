import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/transfer_estimate.dart';

const mb = 1024 * 1024;

void main() {
  group('TransferEstimator', () {
    test('no estimate before minElapsed', () {
      final e = TransferEstimator(totalBytes: 400 * mb);
      e.update(bytesDone: 5 * mb, elapsed: const Duration(milliseconds: 250));
      expect(e.fraction, closeTo(5 / 400, 1e-9));
      expect(e.remaining, isNull);
    });

    test('steady speed gives the expected time left', () {
      // 20 MB/s, 400 MB file: 20 s total.
      final e = TransferEstimator(totalBytes: 400 * mb);
      for (var t = 1; t <= 5; t++) {
        e.update(
          bytesDone: 20 * mb * t,
          elapsed: Duration(seconds: t),
        );
      }
      expect(e.bytesPerSecond, closeTo(20 * mb, 1));
      expect(e.remaining!.inMilliseconds, closeTo(15000, 1));
      expect(e.fraction, closeTo(0.25, 1e-9));
    });

    test('smoothing damps a sudden speed spike', () {
      final e = TransferEstimator(totalBytes: 400 * mb, smoothing: 0.3);
      e.update(bytesDone: 10 * mb, elapsed: const Duration(seconds: 1));
      // One very fast second (100 MB/s) after a 10 MB/s second.
      e.update(bytesDone: 110 * mb, elapsed: const Duration(seconds: 2));
      // 10 + 0.3 * (100 - 10) = 37 MB/s, not 100.
      expect(e.bytesPerSecond, closeTo(37 * mb, 1));
    });

    test('unknown size: no fraction or estimate, but bytes still counted', () {
      final e = TransferEstimator(totalBytes: -1);
      e.update(bytesDone: 50 * mb, elapsed: const Duration(seconds: 2));
      expect(e.sizeKnown, isFalse);
      expect(e.fraction, isNull);
      expect(e.remaining, isNull);
      expect(e.bytesDone, 50 * mb);
    });

    test('finished transfer has zero time left and fraction 1', () {
      final e = TransferEstimator(totalBytes: 10 * mb);
      e.update(bytesDone: 10 * mb, elapsed: const Duration(seconds: 1));
      expect(e.fraction, 1.0);
      expect(e.remaining, Duration.zero);
    });

    test('ignores updates that go backwards in time', () {
      final e = TransferEstimator(totalBytes: 100 * mb);
      e.update(bytesDone: 10 * mb, elapsed: const Duration(seconds: 1));
      e.update(bytesDone: 12 * mb, elapsed: const Duration(seconds: 1));
      expect(e.bytesPerSecond, closeTo(10 * mb, 1));
    });
  });

  test('formatRemaining', () {
    expect(formatRemaining(const Duration(milliseconds: 900)), 'almost done');
    expect(formatRemaining(const Duration(seconds: 12)), 'about 12 s left');
    expect(formatRemaining(const Duration(seconds: 59)), 'about 59 s left');
    expect(formatRemaining(const Duration(seconds: 150)), 'about 3 min left');
  });

  test('formatBytes', () {
    expect(formatBytes(512), '512 bytes');
    expect(formatBytes(820 * 1024), '820 KB');
    expect(formatBytes((3.4 * mb).round()), '3.4 MB');
    expect(formatBytes(400 * mb), '400 MB');
    expect(formatBytes(1288490189), '1.2 GB');
  });
}
