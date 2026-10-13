import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/stroke_grouping.dart' show InkBox;
import '../core/typed_text.dart';
import 'page_ink_layer.dart' show DocumentInkController;

/// Handwriting converted to typed text (task 2.3c), drawn where the ink is,
/// one box per line of handwriting (owner's choice F1), sized to fit it, in the ink's colour (owner's choice 3b). Shown only
/// while [showTyped] is on; the ink of converted words is hidden then.
/// Draws only: taps on a word (to edit it, choice 4a) are found with
/// [typedWordAt], so writing over typed text still works.
class PageTypedText extends StatefulWidget {
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
  State<PageTypedText> createState() => _PageTypedTextState();
}

class _PageTypedTextState extends State<PageTypedText> {
  // Built again only when this page's ink or the layout changes (any
  // page's ink changing notifies every page).
  Widget? _built;
  Object? _builtFrom;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.showTyped]),
    builder: (context, _) {
      final strokes = widget.controller.ink.strokesOn(widget.pageNumber);
      final g = widget.geometry;
      final from = (
        widget.showTyped.value,
        strokes,
        widget.viewWidth,
        g.width,
        g.height,
        g.quarterTurns,
      );
      if (_built != null && from == _builtFrom) return _built!;
      _builtFrom = from;
      return _built = _build(strokes);
    },
  );

  Widget _build(List<PageStroke> strokes) {
    if (!widget.showTyped.value) return const SizedBox.shrink();
    final lines = typedLines(strokes);
    if (lines.isEmpty) return const SizedBox.shrink();
    final scale = widget.viewWidth / widget.geometry.displayWidth;
    return IgnorePointer(
      child: Stack(children: [for (final l in lines) _line(l, scale)]),
    );
  }

  Widget _line(TypedLine w, double scale) {
    final geometry = widget.geometry, viewWidth = widget.viewWidth;
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
            fontSize: shownFontSize(w.text, w.box, geometry) * scale,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// The size (points) of [text] fitted to handwriting in [box] as it shows
/// on screen: on a page turned sideways, the handwriting's screen width is
/// its height on the page.
double shownFontSize(String text, InkBox box, PageGeometry geometry) =>
    geometry.quarterTurns.isOdd
    ? fitFontSize(text, InkBox(box.bottom, box.left, box.top, box.right))
    : fitFontSize(text, box);

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
