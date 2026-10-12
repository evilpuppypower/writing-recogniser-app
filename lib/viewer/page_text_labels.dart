import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import 'ink_text_controller.dart';

/// The recognised text of one PDF page, as small labels above (or below)
/// each handwritten word (task 2.3; owner: above by default). Never takes touches, so writing and
/// scrolling work through it.
class PageTextLabels extends StatefulWidget {
  const PageTextLabels({
    super.key,
    required this.pageNumber,
    required this.geometry,
    required this.viewWidth,
    required this.text,
    required this.strokes,
    this.above = true,
    this.onDoubleTap,
  });

  /// Called when a label is double-tapped with a finger (to correct it,
  /// task 2.4). Pen double-taps reach the ink layer instead; see
  /// [wordAtLabel].
  final void Function(RecognizedWord word)? onDoubleTap;

  /// Labels sit above the words (owner's default) or below them.
  final bool above;

  final int pageNumber;
  final PageGeometry geometry;
  final double viewWidth;
  final InkTextController text;

  /// The page's ink now (to recognise saved ink when first shown).
  final List<PageStroke> Function() strokes;

  @override
  State<PageTextLabels> createState() => _PageTextLabelsState();

  /// The word whose label is at [point] (in the page's pixels), or null.
  /// Slightly generous, so a pen tap near the edge still counts.
  static RecognizedWord? wordAtLabel(
    List<RecognizedWord> words,
    Offset point, {
    required PageGeometry geometry,
    required double viewWidth,
    required bool above,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    for (final w in words.reversed) {
      final l = _labelLayout(w, geometry, viewWidth, above);
      final painter = TextPainter(
        text: TextSpan(
          text: w.text,
          style: TextStyle(fontSize: l.fontSize, height: 1.15),
        ),
        textDirection: TextDirection.ltr,
        // Labels follow the system text size, so the hit area must too.
        textScaler: textScaler,
      )..layout();
      final rect = Rect.fromLTWH(
        l.topLeft.dx,
        l.topLeft.dy,
        painter.width + 6,
        painter.height,
      ).inflate(6);
      painter.dispose();
      if (rect.contains(point)) return w;
    }
    return null;
  }
}

/// Where a word's label goes (top-left, in the page's pixels) and its text
/// size, which follows the zoom: about half a letter high.
({Offset topLeft, double fontSize}) _labelLayout(
  RecognizedWord w,
  PageGeometry g,
  double viewWidth,
  bool above,
) {
  final r = g.rectToView(
    PdfPageRect(
      left: w.box.left,
      bottom: w.box.bottom,
      right: w.box.right,
      top: w.box.top,
    ),
    viewWidth,
  );
  final pxPerPt = viewWidth / g.displayWidth;
  final size = (w.box.height * pxPerPt * 0.45).clamp(9.0, 22.0);
  return (
    topLeft: above
        ? Offset(r.left, r.top - size * 1.15 - 3)
        : Offset(r.left, r.top + r.height + 1),
    fontSize: size,
  );
}

class _PageTextLabelsState extends State<PageTextLabels> {
  @override
  void initState() {
    super.initState();
    widget.text.ensure(widget.pageNumber, widget.strokes());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.text,
      builder: (context, _) {
        final words = widget.text.wordsOn(widget.pageNumber);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final w in words)
              () {
                final l = _labelLayout(
                  w,
                  widget.geometry,
                  widget.viewWidth,
                  widget.above,
                );
                final size = l.fontSize;
                final box = DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text(
                      w.text,
                      style: TextStyle(
                        fontSize: size,
                        height: 1.15,
                        color: scheme.onPrimaryContainer,
                        // Swapped automatically from an earlier
                        // correction (owner: underlined).
                        decoration: w.autoReplaced
                            ? TextDecoration.underline
                            : null,
                      ),
                    ),
                  ),
                );
                final tap = widget.onDoubleTap;
                final label = tap == null
                    ? IgnorePointer(child: box)
                    // Takes double-taps but lets everything else (the
                    // pen writing, fingers scrolling) through to the
                    // page underneath.
                    : _PassThrough(
                        child: GestureDetector(
                          onDoubleTap: () => tap(w),
                          child: box,
                        ),
                      );
                return Positioned(
                  left: l.topLeft.dx,
                  top: l.topLeft.dy,
                  child: label,
                );
              }(),
          ],
        );
      },
    );
  }
}

/// Hit-tests its child but reports "not hit", so whatever is underneath
/// (the ink layer, the PDF view) still gets the touch too.
class _PassThrough extends SingleChildRenderObjectWidget {
  const _PassThrough({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPassThrough();
}

class _RenderPassThrough extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    super.hitTest(result, position: position);
    return false;
  }
}
