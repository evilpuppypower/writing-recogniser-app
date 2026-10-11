/// Conversion between PDF page coordinates and on-screen page coordinates.
///
/// Pure Dart (no Flutter or platform imports) so it can be reused on Windows
/// and by the annotation storage, export and recognition code.
///
/// Two coordinate systems are involved:
///
/// * **PDF page coordinates** ([PdfPagePoint]): points (1/72 inch) in the
///   page's own, *unrotated* space. Origin at the bottom-left, y grows upward.
///   This is what we store, because it doesn't depend on zoom, scroll, screen
///   size or how the page is rotated for display.
/// * **View coordinates** ([ViewPoint]): logical pixels relative to the
///   top-left corner of the page as currently drawn on screen. y grows
///   downward. These change every time the user zooms or scrolls.
library;

/// A point in PDF page coordinates (unrotated, origin bottom-left, y up).
class PdfPagePoint {
  const PdfPagePoint(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is PdfPagePoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'PdfPagePoint($x, $y)';
}

/// A point relative to the top-left of the page as drawn on screen.
class ViewPoint {
  const ViewPoint(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is ViewPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'ViewPoint($x, $y)';
}

/// An axis-aligned rectangle in PDF page coordinates.
class PdfPageRect {
  const PdfPageRect({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  final double left;
  final double bottom;
  final double right;
  final double top;
}

/// An axis-aligned rectangle in view coordinates.
class ViewRect {
  const ViewRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  @override
  String toString() => 'ViewRect($left, $top, $width x $height)';
}

/// The size and display rotation of one PDF page.
class PageGeometry {
  PageGeometry({
    required this.width,
    required this.height,
    this.quarterTurns = 0,
  }) : assert(width > 0 && height > 0);

  /// Unrotated page width in points.
  final double width;

  /// Unrotated page height in points.
  final double height;

  /// Clockwise display rotation in 90 degree steps (the PDF /Rotate value
  /// divided by 90). Normalised to 0..3.
  final int quarterTurns;

  int get _turns => quarterTurns & 3;

  bool get _isSideways => _turns.isOdd;

  /// Page width in points as displayed (after rotation).
  double get displayWidth => _isSideways ? height : width;

  /// Page height in points as displayed (after rotation).
  double get displayHeight => _isSideways ? width : height;

  /// Converts a PDF point to view coordinates, for a page drawn
  /// [viewWidth] logical pixels wide.
  ViewPoint toView(PdfPagePoint p, double viewWidth) {
    final s = viewWidth / displayWidth;
    return switch (_turns) {
      0 => ViewPoint(p.x * s, (height - p.y) * s),
      1 => ViewPoint(p.y * s, p.x * s),
      2 => ViewPoint((width - p.x) * s, p.y * s),
      _ => ViewPoint((height - p.y) * s, (width - p.x) * s),
    };
  }

  /// Converts a view point back to PDF coordinates. Inverse of [toView].
  PdfPagePoint toPdf(ViewPoint v, double viewWidth) {
    final s = viewWidth / displayWidth;
    final x = v.x / s;
    final y = v.y / s;
    return switch (_turns) {
      0 => PdfPagePoint(x, height - y),
      1 => PdfPagePoint(y, x),
      2 => PdfPagePoint(width - x, y),
      _ => PdfPagePoint(width - y, height - x),
    };
  }

  /// Converts a PDF rectangle to the view rectangle covering it.
  ViewRect rectToView(PdfPageRect r, double viewWidth) {
    final a = toView(PdfPagePoint(r.left, r.bottom), viewWidth);
    final b = toView(PdfPagePoint(r.right, r.top), viewWidth);
    final left = a.x < b.x ? a.x : b.x;
    final top = a.y < b.y ? a.y : b.y;
    return ViewRect(
      left: left,
      top: top,
      width: (a.x - b.x).abs(),
      height: (a.y - b.y).abs(),
    );
  }
}
