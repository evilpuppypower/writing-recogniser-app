import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/stroke_grouping.dart' show InkBox, Slant, levelPoint;
import '../core/typed_text.dart';
import 'dark_pages.dart';
import 'page_ink_layer.dart' show DocumentInkController;

/// Handwriting converted to typed text (task 2.3c), drawn where the ink is,
/// one box per line of handwriting (owner's choice F1), sized to fit it, in the ink's colour (owner's choice 3b). Shown only
/// while [showTyped] is on; the ink of converted words is hidden then.
/// Draws only: taps on a word (to edit it, choice 4a) are found with
/// [typedLineAt], so writing over typed text still works.
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

  /// Shown on a dark page: the text's colour turned round.
  bool _dark = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.showTyped]),
    builder: (context, _) {
      final strokes = widget.controller.ink.strokesOn(widget.pageNumber);
      final g = widget.geometry;
      _dark = darkPagesOf(context);
      final from = (
        _dark,
        widget.showTyped.value,
        strokes,
        (widget.viewWidth * 2).round(), // see PageTextLabels
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
    final lines = widget.showTyped.value
        ? typedLines(strokes)
        : const <TypedLine>[];
    // Text boxes always show (they have no handwriting to show instead).
    final boxes = [
      for (final s in strokes)
        if (s.isTextBox && s.points.length >= 2) s,
    ];
    if (lines.isEmpty && boxes.isEmpty) return const SizedBox.shrink();
    final scale = widget.viewWidth / widget.geometry.displayWidth;
    return IgnorePointer(
      child: Stack(
        children: [
          for (final l in lines) _line(l, scale),
          for (final b in boxes) _textBox(b, scale),
        ],
      ),
    );
  }

  /// A text box: its text from the box's top-left corner, at its size,
  /// upright on screen.
  Widget _textBox(PageStroke s, double scale) {
    final corner = PageInkPoint(
      math.min(s.points.first.x, s.points.last.x),
      math.max(s.points.first.y, s.points.last.y),
      0,
    );
    final at = widget.geometry.toView(
      PdfPagePoint(corner.x, corner.y),
      widget.viewWidth,
    );
    return Positioned(
      left: at.x,
      top: at.y,
      child: Text(
        s.typedText ?? '',
        softWrap: false,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          color: Color(_dark ? nightArgb(s.colorArgb) : s.colorArgb),
          fontSize: s.width * scale,
          height: 1.25,
        ),
      ),
    );
  }

  Widget _line(TypedLine w, double scale) {
    final geometry = widget.geometry, viewWidth = widget.viewWidth;
    final slant = w.slant;
    if (slant != null) return _slanted(w, slant, scale);
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
            color: Color(_dark ? nightArgb(w.colorArgb) : w.colorArgb),
            fontSize: shownFontSize(w.text, w.box, geometry) * scale,
            height: 1,
          ),
        ),
      ),
    );
  }

  /// A line written at a slant: the text along it, fitted to the line
  /// turned level.
  Widget _slanted(TypedLine w, Slant slant, double scale) {
    final g = widget.geometry, viewWidth = widget.viewWidth;
    final b = slant.box;
    Offset view(double x, double y) {
      final p = levelPoint(
        PageInkPoint(x, y, 0),
        -slant.angle,
        slant.cx,
        slant.cy,
      );
      final v = g.toView(PdfPagePoint(p.x, p.y), viewWidth);
      return Offset(v.x, v.y);
    }

    final corner = view(b.left, b.top);
    final along = view(b.right, b.top) - corner;
    final down = view(b.left, b.bottom) - corner;
    return Positioned(
      left: 0,
      top: 0,
      child: Transform(
        transform: Matrix4.translationValues(corner.dx, corner.dy, 0)
          ..rotateZ(math.atan2(along.dy, along.dx)),
        child: SizedBox(
          width: along.distance,
          height: down.distance,
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: Text(
              w.text,
              maxLines: 1,
              softWrap: false,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: Color(_dark ? nightArgb(w.colorArgb) : w.colorArgb),
                fontSize: w.fontSize * scale,
                height: 1,
              ),
            ),
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

/// The line of typed text at [at] (pixels in a page laid out [viewWidth]
/// wide), if any, allowing a little room around it.
TypedLine? typedLineAt(
  List<PageStroke> strokes,
  Offset at,
  PageGeometry geometry,
  double viewWidth,
) {
  final p = geometry.toPdf(ViewPoint(at.dx, at.dy), viewWidth);
  const reach = 2.0;
  for (final l in typedLines(strokes)) {
    // At a slant: measured with the line turned level.
    final slant = l.slant;
    final b = slant?.box ?? l.box;
    final PageInkPoint q = slant == null
        ? PageInkPoint(p.x, p.y, 0)
        : levelPoint(
            PageInkPoint(p.x, p.y, 0),
            slant.angle,
            slant.cx,
            slant.cy,
          );
    if (q.x >= b.left - reach &&
        q.x <= b.right + reach &&
        q.y >= b.bottom - reach &&
        q.y <= b.top + reach) {
      return l;
    }
  }
  return null;
}
