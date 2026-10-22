import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/page_coordinates.dart';
import 'ink_text_controller.dart';

/// Which strokes are each word ("Show words", owner 2026-10-22): an
/// outline round each word the app read on the page, in turning colours so
/// neighbours stand apart. A finger tap on an outline opens the word to
/// fix it; the pen and scrolling go through to the page.
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

  /// [word]'s outline, in the page's pixels.
  static Rect outlineOf(
    RecognizedWord word,
    PageGeometry geometry,
    double viewWidth,
  ) {
    final b = word.box;
    final a = geometry.toView(PdfPagePoint(b.left, b.top), viewWidth);
    final c = geometry.toView(PdfPagePoint(b.right, b.bottom), viewWidth);
    return Rect.fromPoints(Offset(a.x, a.y), Offset(c.x, c.y)).inflate(3);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([text, ?refresh]),
    builder: (context, _) {
      final words = [
        for (final w in text.wordsOn(pageNumber))
          if (skip == null || !skip!(w)) w,
      ];
      return Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < words.length; i++)
            () {
              final w = words[i];
              final r = outlineOf(w, geometry, viewWidth);
              final colour = colours[i % colours.length];
              return Positioned.fromRect(
                rect: r,
                child: _PassThrough(
                  child: Semantics(
                    button: true,
                    label: 'Word read as ${w.text}. Tap to fix.',
                    child: GestureDetector(
                      // Fingers only: the pen keeps writing over words.
                      supportedDevices: const {PointerDeviceKind.touch},
                      onTap: () => onTap(w),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colour.withValues(alpha: 0.06),
                          border: Border.all(
                            color: colour.withValues(alpha: 0.8),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }(),
        ],
      );
    },
  );
}

/// Hit-tests its child but reports "not hit", so the page underneath (the
/// ink layer, scrolling) still gets the touch too.
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
