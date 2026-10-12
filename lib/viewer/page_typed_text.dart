import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/stroke_grouping.dart' show InkBox;
import '../core/typed_text.dart';
import 'page_ink_layer.dart' show DocumentInkController;

/// Handwriting converted to typed text (task 2.3c), drawn where the ink is,
/// sized to fit it, in the ink's colour (owner's choice 3b). Shown only
/// while [showTyped] is on; the ink of converted words is hidden then.
/// Draws only: taps on a word (to edit it, choice 4a) are found with
/// [typedWordAt], so writing over typed text still works.
class PageTypedText extends StatelessWidget {
  const PageTypedText({
    super.key,
    required this.pageNumber,
    required this.geometry,
    required this.viewWidth,
    required this.controller,
    required this.showTyped,
  });

  final int pageNumber;
  final PageGeometry geometry;
  final double viewWidth;
  final DocumentInkController controller;
  final ValueListenable<bool> showTyped;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, showTyped]),
    builder: (context, _) {
      if (!showTyped.value) return const SizedBox.shrink();
      final words = typedWords(controller.ink.strokesOn(pageNumber));
      if (words.isEmpty) return const SizedBox.shrink();
      final scale = viewWidth / geometry.displayWidth;
      return IgnorePointer(
        child: Stack(children: [for (final w in words) _word(w, scale)]),
      );
    },
  );

  Widget _word(TypedWord w, double scale) {
    final r = geometry.rectToView(
      PdfPageRect(
        left: w.box.left,
        bottom: w.box.bottom,
        right: w.box.right,
        top: w.box.top,
      ),
      viewWidth,
    );
    final rect = Rect.fromLTWH(r.left, r.top, r.width, r.height);
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        maxWidth: double.infinity,
        child: Text(
          w.text,
          maxLines: 1,
          softWrap: false,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            color: Color(w.colorArgb),
            fontSize: shownFontSize(w, geometry) * scale,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// [w]'s text size (points) as it shows on screen: on a page turned
/// sideways, the handwriting's screen width is its height on the page.
double shownFontSize(TypedWord w, PageGeometry geometry) =>
    geometry.quarterTurns.isOdd
    ? fitFontSize(
        w.text,
        InkBox(w.box.bottom, w.box.left, w.box.top, w.box.right),
      )
    : w.fontSize;

/// The typed word at [at] (pixels in a page laid out [viewWidth] wide), if
/// any, allowing a little room around it.
TypedWord? typedWordAt(
  List<PageStroke> strokes,
  Offset at,
  PageGeometry geometry,
  double viewWidth,
) {
  final p = geometry.toPdf(ViewPoint(at.dx, at.dy), viewWidth);
  const reach = 2.0;
  for (final w in typedWords(strokes)) {
    final b = w.box;
    if (p.x >= b.left - reach &&
        p.x <= b.right + reach &&
        p.y >= b.bottom - reach &&
        p.y <= b.top + reach) {
      return w;
    }
  }
  return null;
}
