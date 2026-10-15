import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/stroke_grouping.dart' show levelPoint;
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
    this.skip,
    this.refresh,
    this.shown,
  });

  /// Whether the labels are showing (they fade out when not, see
  /// [LabelFade]). Always shown when null.
  final ValueListenable<bool>? shown;

  /// Words whose label isn't shown (e.g. converted to typed text, which
  /// shows instead, task 2.3c), and what to listen to for changes to that.
  final bool Function(RecognizedWord word)? skip;
  final Listenable? refresh;

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
        0,
        0,
        painter.width + 6,
        painter.height,
      ).inflate(6);
      painter.dispose();
      // The point in the label's own pixels (labels can be at a slant).
      final inverse = Matrix4.tryInvert(_labelTransform(l));
      if (inverse == null) continue;
      final local = MatrixUtils.transformPoint(inverse, point);
      if (rect.contains(local)) return w;
    }
    return null;
  }
}

/// A label's text size (pixels) for a word [heightPt] points tall shown at
/// [pxPerPt]: about half the word's height, so it grows and shrinks with
/// the handwriting when zooming (owner's test feedback: no upper limit),
/// but never too small to read.
double labelFontSize(double heightPt, double pxPerPt) {
  final size = heightPt * pxPerPt * 0.45;
  return size < minLabelFontSize ? minLabelFontSize : size;
}

/// Labels are never smaller than this (pixels).
const minLabelFontSize = 9.0;

/// Where a word's label goes and its text size (see [labelFontSize]): the
/// label's top-left corner (in the page's pixels) is [anchor] moved by
/// [shift] along the word's own directions (right, down), turned by
/// [angle] (radians, clockwise on screen) to follow writing at a slant.
({Offset anchor, Offset shift, double angle, double fontSize}) _labelLayout(
  RecognizedWord w,
  PageGeometry g,
  double viewWidth,
  bool above,
) {
  final pxPerPt = viewWidth / g.displayWidth;
  final slant = w.slant;
  if (slant == null) {
    final r = g.rectToView(
      PdfPageRect(
        left: w.box.left,
        bottom: w.box.bottom,
        right: w.box.right,
        top: w.box.top,
      ),
      viewWidth,
    );
    final size = labelFontSize(w.box.height, pxPerPt);
    return (
      anchor: Offset.zero,
      shift: above
          ? Offset(r.left, r.top - size * 1.15 - 3)
          : Offset(r.left, r.top + r.height + 1),
      angle: 0,
      fontSize: size,
    );
  }
  // Along the slant: from the corner of the word turned level, back on
  // the page, and the way its line runs there on screen.
  final b = slant.box;
  final size = labelFontSize(b.height, pxPerPt);
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

  final corner = view(b.left, above ? b.top : b.bottom);
  final along = view(b.right, above ? b.top : b.bottom) - corner;
  return (
    anchor: corner,
    shift: above ? Offset(0, -size * 1.15 - 3) : const Offset(0, 1),
    angle: math.atan2(along.dy, along.dx),
    fontSize: size,
  );
}

/// The label's transform: from its own pixels (top-left at 0, 0) to the
/// page's.
Matrix4 _labelTransform(
  ({Offset anchor, Offset shift, double angle, double fontSize}) l,
) => Matrix4.translationValues(l.anchor.dx, l.anchor.dy, 0)
  ..rotateZ(l.angle)
  ..translateByDouble(l.shift.dx, l.shift.dy, 0, 1);

class _PageTextLabelsState extends State<PageTextLabels> {
  // The labels last built, and what they were built from: any change to
  // the ink or any page's text notifies every page, so most rebuilds find
  // nothing changed on this one and reuse them (owner's stutter feedback).
  Widget? _built;
  List<RecognizedWord> _builtWords = const [];
  Object? _builtSettings;

  /// The page width the labels were built for. While pinch-zooming, the
  /// labels already built are stretched to the new width and built again
  /// only once the zoom has settled a moment (building 300 labels on
  /// every frame of a zoom made it stutter).
  double _builtWidth = 0;
  Timer? _settle;
  bool _settled = false;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.text.ensure(widget.pageNumber, widget.strokes());
  }

  @override
  Widget build(BuildContext context) {
    final labels = _labels(context);
    final shown = widget.shown;
    if (shown == null) return labels;
    return ValueListenableBuilder(
      valueListenable: shown,
      child: labels,
      builder: (context, on, child) => IgnorePointer(
        ignoring: !on,
        child: AnimatedOpacity(
          opacity: on ? 1 : 0,
          duration: Duration(milliseconds: on ? 150 : 600),
          child: child,
        ),
      ),
    );
  }

  Widget _labels(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.text, ?widget.refresh]),
      builder: (context, _) {
        final skip = widget.skip;
        final words = [
          for (final w in widget.text.wordsOn(widget.pageNumber))
            if (skip == null || !skip(w)) w,
        ];
        final settings = (
          widget.above,
          widget.geometry.width,
          widget.geometry.height,
          widget.geometry.quarterTurns,
          scheme,
          MediaQuery.textScalerOf(context),
          widget.onDoubleTap != null,
        );
        final width = widget.viewWidth;
        if (_built != null &&
            settings == _builtSettings &&
            _sameWords(words, _builtWords)) {
          // Steps of half a pixel: the page's width wobbles by a hair as
          // it's moved while zoomed, which shouldn't rebuild every label.
          if ((width - _builtWidth).abs() < 0.5) {
            _settle?.cancel();
            return _scaled(1);
          }
          if (!_settled) {
            _settle?.cancel();
            _settle = Timer(const Duration(milliseconds: 200), () {
              if (!mounted) return;
              setState(() => _settled = true);
            });
            return _scaled(width / _builtWidth);
          }
        }
        _settled = false;
        _settle?.cancel();
        _builtWords = words;
        _builtSettings = settings;
        _builtWidth = width;
        _built = Stack(
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
                  left: 0,
                  top: 0,
                  child: Transform(transform: _labelTransform(l), child: label),
                );
              }(),
          ],
        );
        return _scaled(1);
      },
    );
  }

  /// The labels built, stretched by [by] (always wrapped the same way, so
  /// stretching doesn't rebuild them).
  Widget _scaled(double by) =>
      Transform.scale(scale: by, alignment: Alignment.topLeft, child: _built);
}

/// Whether [a] and [b] are the same word objects (a word that changes is
/// replaced by a new object).
bool _sameWords(List<RecognizedWord> a, List<RecognizedWord> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
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
