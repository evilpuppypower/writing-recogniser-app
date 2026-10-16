import 'dart:math' as math;
import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

/// Pages side by side in pairs (1 and 2, 3 and 4, ...), each pair centred,
/// rows one under another (owner's choice: two-page view, 2026-10-15).
({List<Rect> pages, Size document}) twoPageRects(
  List<Size> sizes,
  double margin,
) {
  final rows = <(int, int?)>[
    for (var i = 0; i < sizes.length; i += 2)
      (i, i + 1 < sizes.length ? i + 1 : null),
  ];
  double rowWidth((int, int?) r) =>
      sizes[r.$1].width + (r.$2 == null ? 0 : margin + sizes[r.$2!].width);
  final widest = rows.isEmpty ? 0.0 : rows.map(rowWidth).reduce(math.max);
  final width = widest + margin * 2;
  final rects = List<Rect>.filled(sizes.length, Rect.zero);
  var y = margin;
  for (final r in rows) {
    final second = r.$2;
    final height = math.max(
      sizes[r.$1].height,
      second == null ? 0.0 : sizes[second].height,
    );
    var x = (width - rowWidth(r)) / 2;
    for (final i in [r.$1, ?second]) {
      final s = sizes[i];
      rects[i] = Rect.fromLTWH(
        x,
        y + (height - s.height) / 2,
        s.width,
        s.height,
      );
      x += s.width + margin;
    }
    y += height + margin;
  }
  return (pages: rects, document: Size(width, y));
}

/// One page under another, each centred (the usual view).
({List<Rect> pages, Size document}) onePageRects(
  List<Size> sizes,
  double margin,
) {
  final widest = sizes.isEmpty
      ? 0.0
      : sizes.map((s) => s.width).reduce(math.max);
  final width = widest + margin * 2;
  var y = margin;
  final rects = <Rect>[];
  for (final s in sizes) {
    rects.add(Rect.fromLTWH((width - s.width) / 2, y, s.width, s.height));
    y += s.height + margin;
  }
  return (pages: rects, document: Size(width, y));
}

/// pdfrx's page layout: pairs side by side when [twoPages] says so,
/// otherwise one under another.
PdfPageLayout pageLayout(
  List<PdfPage> pages,
  PdfViewerParams params, {
  required bool twoPages,
}) {
  final sizes = [for (final p in pages) Size(p.width, p.height)];
  final r = twoPages
      ? twoPageRects(sizes, params.margin)
      : onePageRects(sizes, params.margin);
  return PdfPageLayout(pageLayouts: r.pages, documentSize: r.document);
}

/// The pages showing side by side with [page] in two-page view, first
/// first: it and the other page of its pair (1 and 2, 3 and 4, ...); just
/// it for the last page of an odd count.
List<int> pagePair(int page, int pageCount) {
  final first = page.isOdd ? page : page - 1;
  return [first, if (first + 1 <= pageCount) first + 1];
}
