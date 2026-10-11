import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';

void main() {
  // A4 portrait in points.
  const w = 595.0;
  const h = 842.0;

  void expectView(ViewPoint actual, double x, double y) {
    expect(actual.x, closeTo(x, 1e-9));
    expect(actual.y, closeTo(y, 1e-9));
  }

  group('unrotated page', () {
    final page = PageGeometry(width: w, height: h);

    test('corners map to the corners of the drawn page', () {
      expectView(page.toView(const PdfPagePoint(0, h), w), 0, 0);
      expectView(page.toView(const PdfPagePoint(w, h), w), w, 0);
      expectView(page.toView(const PdfPagePoint(0, 0), w), 0, h);
      expectView(page.toView(const PdfPagePoint(w, 0), w), w, h);
    });

    test('scales with zoom', () {
      // Page drawn at 2x: 1 inch from the left and top is 144 px.
      expectView(page.toView(const PdfPagePoint(72, h - 72), w * 2), 144, 144);
      // Page drawn at half size.
      expectView(page.toView(const PdfPagePoint(72, h - 72), w / 2), 36, 36);
    });

    test('display size equals page size', () {
      expect(page.displayWidth, w);
      expect(page.displayHeight, h);
    });
  });

  group('rotated pages', () {
    test('90 degrees clockwise: bottom-left goes to top-left', () {
      final page = PageGeometry(width: w, height: h, quarterTurns: 1);
      expect(page.displayWidth, h);
      expect(page.displayHeight, w);
      expectView(page.toView(const PdfPagePoint(0, 0), h), 0, 0);
      expectView(page.toView(const PdfPagePoint(0, h), h), h, 0);
      expectView(page.toView(const PdfPagePoint(w, 0), h), 0, w);
    });

    test('180 degrees: top-right goes to bottom-left', () {
      final page = PageGeometry(width: w, height: h, quarterTurns: 2);
      expectView(page.toView(const PdfPagePoint(w, h), w), 0, h);
      expectView(page.toView(const PdfPagePoint(0, 0), w), w, 0);
    });

    test('270 degrees: top-right goes to top-left', () {
      final page = PageGeometry(width: w, height: h, quarterTurns: 3);
      expectView(page.toView(const PdfPagePoint(w, h), h), 0, 0);
      expectView(page.toView(const PdfPagePoint(0, 0), h), h, w);
    });

    test('quarterTurns outside 0..3 are normalised', () {
      final a = PageGeometry(width: w, height: h, quarterTurns: 5);
      final b = PageGeometry(width: w, height: h, quarterTurns: 1);
      const p = PdfPagePoint(100, 200);
      expect(a.toView(p, 500), b.toView(p, 500));
    });
  });

  test('toPdf is the inverse of toView for every rotation and zoom', () {
    const points = [
      PdfPagePoint(0, 0),
      PdfPagePoint(72, 698),
      PdfPagePoint(300.5, 12.25),
      PdfPagePoint(w, h),
    ];
    for (var turns = 0; turns < 4; turns++) {
      final page = PageGeometry(width: w, height: h, quarterTurns: turns);
      for (final viewWidth in [100.0, 595.0, 2400.0]) {
        for (final p in points) {
          final back = page.toPdf(page.toView(p, viewWidth), viewWidth);
          expect(back.x, closeTo(p.x, 1e-9), reason: 'turns=$turns');
          expect(back.y, closeTo(p.y, 1e-9), reason: 'turns=$turns');
        }
      }
    }
  });

  test('rectToView gives a positive-size rect for every rotation', () {
    const box = PdfPageRect(left: 72, bottom: 698, right: 216, top: 770);
    final expected = {
      0: const ViewRect(left: 72, top: 72, width: 144, height: 72),
      1: const ViewRect(left: 698, top: 72, width: 72, height: 144),
      2: const ViewRect(left: 379, top: 698, width: 144, height: 72),
      3: const ViewRect(left: 72, top: 379, width: 72, height: 144),
    };
    expected.forEach((turns, e) {
      final page = PageGeometry(width: w, height: h, quarterTurns: turns);
      final r = page.rectToView(box, page.displayWidth);
      expect(r.left, closeTo(e.left, 1e-9), reason: 'turns=$turns');
      expect(r.top, closeTo(e.top, 1e-9), reason: 'turns=$turns');
      expect(r.width, closeTo(e.width, 1e-9), reason: 'turns=$turns');
      expect(r.height, closeTo(e.height, 1e-9), reason: 'turns=$turns');
    });
  });
}
