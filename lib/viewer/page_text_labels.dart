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
  /// task 2.4).
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
        final g = widget.geometry;
        // Text size follows the page zoom: about half a letter high.
        final pxPerPt = widget.viewWidth / g.displayWidth;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final w in words)
              () {
                final r = g.rectToView(
                  PdfPageRect(
                    left: w.box.left,
                    bottom: w.box.bottom,
                    right: w.box.right,
                    top: w.box.top,
                  ),
                  widget.viewWidth,
                );
                final size = (w.box.height * pxPerPt * 0.45).clamp(9.0, 22.0);
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
                return widget.above
                    ? Positioned(
                        left: r.left,
                        bottom: null,
                        top: r.top - size * 1.15 - 3,
                        child: label,
                      )
                    : Positioned(
                        left: r.left,
                        top: r.top + r.height + 1,
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
