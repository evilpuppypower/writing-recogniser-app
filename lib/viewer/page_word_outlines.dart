import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/stroke_grouping.dart' show levelPoint;
import 'ink_text_controller.dart';

/// Where a word's outline is, in the page's pixels: a box [size] big,
/// centred on [centre], turned by [angle] (radians, clockwise on screen)
/// for words written at a slant.
typedef WordOutline = ({Offset centre, Size size, double angle});

/// Which strokes are each word ("Show words", owner 2026-10-22): an
/// outline round each word the app read on the page, in turning colours so
/// neighbours stand apart, turned with words written at a slant. A finger
/// tap on an outline opens the word to fix it; the pen and scrolling go
/// through to the page. All outlines are drawn in one go, so a page with
/// many words stays smooth.
class PageWordOutlines extends StatelessWidget {
  const PageWordOutlines({
    super.key,
    required this.pageNumber,
    required this.geometry,
    required this.viewWidth,
    required this.text,
    required this.onTap,
    this.skip,
    this.refresh,
  });

  final int pageNumber;
  final PageGeometry geometry;
  final double viewWidth;
  final InkTextController text;
  final void Function(RecognizedWord word) onTap;

  /// Words not shown (e.g. shown as typed text instead).
  final bool Function(RecognizedWord word)? skip;
  final Listenable? refresh;

  /// Outline colours, taken in turn word by word.
  static const colours = [
    Color(0xFF1E88E5), // blue
    Color(0xFFE53935), // red
    Color(0xFF43A047), // green
    Color(0xFFFB8C00), // orange
    Color(0xFF8E24AA), // purple
  ];

  /// Room left round the ink (pixels).
  static const margin = 3.0;

  /// [word]'s outline, in the page's pixels: round its box, or along its
  /// slant when it's written at one.
  static WordOutline outlineOf(
    RecognizedWord word,
    PageGeometry geometry,
    double viewWidth,
  ) {
    final slant = word.slant;
    if (slant == null) {
      final b = word.box;
      final a = geometry.toView(PdfPagePoint(b.left, b.top), viewWidth);
      final c = geometry.toView(PdfPagePoint(b.right, b.bottom), viewWidth);
      final r = Rect.fromPoints(
        Offset(a.x, a.y),
        Offset(c.x, c.y),
      ).inflate(margin);
      return (centre: r.center, size: r.size, angle: 0);
    }
    // The word turned level, its corners turned back onto the page.
    Offset view(double x, double y) {
      final p = levelPoint(
        PageInkPoint(x, y, 0),
        -slant.angle,
        slant.cx,
        slant.cy,
      );
      final v = geometry.toView(PdfPagePoint(p.x, p.y), viewWidth);
      return Offset(v.x, v.y);
    }

    final b = slant.box;
    final corner = view(b.left, b.top);
    final right = view(b.right, b.top);
    final down = view(b.left, b.bottom);
    final along = right - corner;
    return (
      centre: (right + down) / 2,
      size: Size(
        along.distance + 2 * margin,
        (down - corner).distance + 2 * margin,
      ),
      angle: math.atan2(along.dy, along.dx),
    );
  }

  /// Whether [point] (page pixels) is inside [o].
  static bool contains(WordOutline o, Offset point) {
    final d = point - o.centre;
    final c = math.cos(-o.angle), s = math.sin(-o.angle);
    final x = d.dx * c - d.dy * s, y = d.dx * s + d.dy * c;
    return x.abs() <= o.size.width / 2 && y.abs() <= o.size.height / 2;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([text, ?refresh]),
    builder: (context, _) {
      final words = [
        for (final w in text.wordsOn(pageNumber))
          if (skip == null || !skip!(w)) w,
      ];
      final outlines = [
        for (final w in words) (word: w, at: outlineOf(w, geometry, viewWidth)),
      ];
      RecognizedWord? at(Offset p) {
        for (final o in outlines.reversed) {
          if (contains(o.at, p)) return o.word;
        }
        return null;
      }

      return _PassThrough(
        hits: (p) => at(p) != null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Fingers only: the pen keeps writing over words.
          supportedDevices: const {PointerDeviceKind.touch},
          onTapUp: (d) {
            final w = at(d.localPosition);
            if (w != null) onTap(w);
          },
          child: CustomPaint(
            size: Size.infinite,
            painter: _OutlinePainter(
              [for (final o in outlines) o.at],
              [
                for (final o in outlines)
                  (label: o.word.text, onTap: () => onTap(o.word)),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _OutlinePainter extends CustomPainter {
  _OutlinePainter(this.outlines, this.words);

  final List<WordOutline> outlines;
  final List<({String label, VoidCallback onTap})> words;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..style = PaintingStyle.fill;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (var i = 0; i < outlines.length; i++) {
      final o = outlines[i];
      final colour =
          PageWordOutlines.colours[i % PageWordOutlines.colours.length];
      final box = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset.zero,
          width: o.size.width,
          height: o.size.height,
        ),
        const Radius.circular(4),
      );
      canvas
        ..save()
        ..translate(o.centre.dx, o.centre.dy)
        ..rotate(o.angle)
        ..drawRRect(box, fill..color = colour.withValues(alpha: 0.06))
        ..drawRRect(box, line..color = colour.withValues(alpha: 0.8))
        ..restore();
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (var i = 0; i < outlines.length; i++)
          CustomPainterSemantics(
            rect: _bounds(outlines[i]),
            properties: SemanticsProperties(
              button: true,
              label: 'Word read as ${words[i].label}. Tap to fix.',
              textDirection: TextDirection.ltr,
              onTap: words[i].onTap,
            ),
          ),
      ];

  static Rect _bounds(WordOutline o) {
    final c = math.cos(o.angle).abs(), s = math.sin(o.angle).abs();
    return Rect.fromCenter(
      center: o.centre,
      width: o.size.width * c + o.size.height * s,
      height: o.size.width * s + o.size.height * c,
    );
  }

  @override
  bool shouldRepaint(_OutlinePainter old) => !_same(old);

  @override
  bool shouldRebuildSemantics(_OutlinePainter old) => !_same(old);

  bool _same(_OutlinePainter old) {
    if (old.outlines.length != outlines.length) return false;
    for (var i = 0; i < outlines.length; i++) {
      if (old.outlines[i] != outlines[i] ||
          old.words[i].label != words[i].label) {
        return false;
      }
    }
    return true;
  }
}

/// Takes touches only where [hits] says (on a word), and even then reports
/// "not hit", so the page underneath (the ink layer, scrolling) still gets
/// the touch too.
class _PassThrough extends SingleChildRenderObjectWidget {
  const _PassThrough({required this.hits, required super.child});

  final bool Function(Offset position) hits;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPassThrough(hits);

  @override
  void updateRenderObject(BuildContext context, _RenderPassThrough r) =>
      r.hits = hits;
}

class _RenderPassThrough extends RenderProxyBox {
  _RenderPassThrough(this.hits);

  bool Function(Offset position) hits;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hits(position)) super.hitTest(result, position: position);
    return false;
  }
}
