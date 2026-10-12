import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/page_coordinates.dart';
import '../core/typed_text.dart';
import 'page_ink_layer.dart' show DocumentInkController;

/// Handwriting converted to typed text (task 2.3c), drawn where the ink is,
/// sized to fit it, in the ink's colour (owner's choice 3b). Shown only
/// while [showTyped] is on; the ink of converted words is hidden then.
/// Tapping a word (finger or pen) edits it (choice 4a).
class PageTypedText extends StatelessWidget {
  const PageTypedText({
    super.key,
    required this.pageNumber,
    required this.geometry,
    required this.viewWidth,
    required this.controller,
    required this.showTyped,
    required this.onEdit,
  });

  final int pageNumber;
  final PageGeometry geometry;
  final double viewWidth;
  final DocumentInkController controller;
  final ValueListenable<bool> showTyped;
  final void Function(TypedWord word) onEdit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, showTyped]),
    builder: (context, _) {
      if (!showTyped.value) return const SizedBox.shrink();
      final words = typedWords(controller.ink.strokesOn(pageNumber));
      if (words.isEmpty) return const SizedBox.shrink();
      final scale = viewWidth / geometry.displayWidth;
      return Stack(children: [for (final w in words) _word(context, w, scale)]);
    },
  );

  Widget _word(BuildContext context, TypedWord w, double scale) {
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
      child: Tooltip(
        message: 'Tap to edit "${w.text}"',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onEdit(w),
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
