import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:writing_recogniser/viewer/zoom_out_sizing.dart';

void main() {
  test('zooms out to half of what fills the screen', () {
    // A 600 x 800 page in an 1200-wide view: filling the width is 2x.
    final layout = PdfPageLayout(
      pageLayouts: [const Rect.fromLTWH(0, 0, 600, 800)],
      documentSize: const Size(600, 800),
    );
    PdfViewerLayoutMetrics metrics(PdfViewerSizeDelegateProvider p) =>
        p.create().calculateMetrics(
          viewSize: const Size(1200, 4000),
          layout: layout,
          pageNumber: 1,
          pageMargin: 0,
          boundaryMargin: null,
        );
    final usual = metrics(const PdfViewerSizeDelegateProviderLegacy());
    final ours = metrics(const ZoomOutSizing());
    expect(ours.minScale, closeTo(usual.minScale / 2, 1e-9));
    expect(ours.maxScale, usual.maxScale);
    expect(ours.coverScale, usual.coverScale);
    expect(const ZoomOutSizing(), const ZoomOutSizing());
  });
}
