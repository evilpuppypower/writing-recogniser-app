/// The writing box (owner's approved idea 12): a strip at the bottom of
/// the screen shows part of a page large, and what's written there lands
/// on the page small, where a guide shows. It moves along as the user
/// writes, like a typewriter. Pure Dart.
library;

/// Where the box is on a page: its left and top as shares (0..1) of the
/// page as shown, and its width as a share of the page's width; its height
/// follows from the strip's shape.
class WritingBoxTarget {
  const WritingBoxTarget({
    required this.page,
    required this.left,
    required this.top,
    required this.width,
  });

  final int page;
  final double left, top, width;

  /// Its height as a share of the page's height, for a strip [aspect]
  /// (height / width) on a page [pageAspect] (height / width).
  double heightFor(double aspect, double pageAspect) =>
      width * aspect / pageAspect;

  WritingBoxTarget copyWith({
    int? page,
    double? left,
    double? top,
    double? width,
  }) => WritingBoxTarget(
    page: page ?? this.page,
    left: (left ?? this.left).clamp(0.0, 1 - (width ?? this.width)),
    top: (top ?? this.top).clamp(0.0, 1.0),
    width: (width ?? this.width).clamp(0.1, 1.0),
  );

  /// Moved along by half its width; at the end of the line, to the start
  /// of the next ([newLine]).
  WritingBoxTarget next({required double height, double margin = 0.05}) {
    if (left + width >= 1 - 1e-9) {
      return newLine(height: height, margin: margin);
    }
    return copyWith(left: left + width / 2);
  }

  /// Back by half its width.
  WritingBoxTarget back() => copyWith(left: left - width / 2);

  /// The start of the next line: [margin] from the left, most of a box
  /// height lower (so the line just written stays in view at the top).
  WritingBoxTarget newLine({required double height, double margin = 0.05}) =>
      copyWith(left: margin, top: top + height * 0.75);

  /// Onto the next page (of [pageCount]) once it's gone past the foot of
  /// this one.
  WritingBoxTarget overflow({required double height, required int pageCount}) =>
      top + height > 1 + 1e-9 && page < pageCount
      ? WritingBoxTarget(page: page + 1, left: left, top: 0.05, width: width)
      : this;

  /// After a stroke ending [rightShare] of the way across the box (0..1):
  /// moved along when the writing reaches the box's last fifth.
  WritingBoxTarget follow(double rightShare, {required double height}) =>
      rightShare > 0.8 ? next(height: height) : this;
}
