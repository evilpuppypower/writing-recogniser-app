import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart';
import '../core/page_ink.dart';
import '../core/page_recognition.dart' show HiddenInk, hiddenInk;
import 'ink_text_controller.dart';
import 'page_ink_layer.dart' show DocumentInkController;

/// The recognised text of the current page (task 2.3), in a panel docked
/// beside the PDF or in a floating window. Updates as words are read and
/// corrected.
class RecognisedTextPanel extends StatelessWidget {
  const RecognisedTextPanel({
    super.key,
    required this.text,
    required this.page,
    required this.place,
    required this.onPlace,
    this.ink,
    this.onUnhide,
  });

  final InkTextController text;

  /// The page's ink, to list what was marked "This isn't writing" (task
  /// 2.4d), and what to do when one is marked as writing again.
  final DocumentInkController? ink;
  final void Function(int page, HiddenInk hidden)? onUnhide;
  final ValueListenable<int?> page;
  final TextPanelPlace place;

  /// Move the panel (or close it, with [TextPanelPlace.off]).
  final ValueChanged<TextPanelPlace> onPlace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: ListenableBuilder(
        listenable: Listenable.merge([text, page, ?ink]),
        builder: (context, _) {
          final n = page.value ?? 1;
          final t = text.textOf(n);
          final strokes = ink?.ink.strokesOn(n) ?? const <PageStroke>[];
          final hidden = onUnhide == null
              ? const <HiddenInk>[]
              : hiddenInk(strokes);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Page $n text',
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: "Copy this page's text",
                      icon: const Icon(Icons.copy, size: 20),
                      onPressed: t.isEmpty
                          ? null
                          : () => Clipboard.setData(ClipboardData(text: t)),
                    ),
                    PopupMenuButton<TextPanelPlace>(
                      tooltip: 'Move the text panel',
                      icon: const Icon(Icons.open_with, size: 20),
                      onSelected: onPlace,
                      itemBuilder: (_) => [
                        for (final p in TextPanelPlace.values)
                          if (p != TextPanelPlace.off && p != place)
                            PopupMenuItem(value: p, child: Text(p.label)),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Close the text panel',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => onPlace(TextPanelPlace.off),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    t.isEmpty
                        ? 'Nothing recognised on this page yet. Write with '
                              'the pen and pause.'
                        : t,
                    style: t.isEmpty
                        ? theme.textTheme.bodySmall
                        : theme.textTheme.bodyLarge,
                  ),
                ),
              ),
              if (hidden.isNotEmpty)
                _HiddenInkList(
                  hidden: hidden,
                  strokes: strokes,
                  onUnhide: (h) => onUnhide!(n, h),
                ),
              if (text.problem != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    "Handwriting can't be read right now: ${text.problem}",
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Ink on the page marked "This isn't writing" (task 2.4d), each with a
/// small picture and a button to read it as writing again.
class _HiddenInkList extends StatelessWidget {
  const _HiddenInkList({
    required this.hidden,
    required this.strokes,
    required this.onUnhide,
  });

  final List<HiddenInk> hidden;
  final List<PageStroke> strokes;
  final ValueChanged<HiddenInk> onUnhide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              'Hidden ink (${hidden.length}): marked as not writing, so not '
              'read',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final h in hidden)
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: CustomPaint(
                            painter: _InkPreview(
                              [
                                for (final s in strokes)
                                  if (h.ids.contains(s.id)) s,
                              ],
                              h,
                              theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => onUnhide(h),
                        child: const Text('This is writing'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws [strokes] fitted into the space, keeping their shape.
class _InkPreview extends CustomPainter {
  _InkPreview(this.strokes, this.hidden, this.color);

  final List<PageStroke> strokes;
  final HiddenInk hidden;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final b = hidden.box;
    final w = b.width <= 0 ? 1.0 : b.width, h = b.height <= 0 ? 1.0 : b.height;
    final scale = [
      size.width / w,
      size.height / h,
      4.0,
    ].reduce((a, c) => a < c ? a : c);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (final s in strokes) {
      final path = Path();
      for (var i = 0; i < s.points.length; i++) {
        final p = s.points[i];
        // PDF y grows upward; the screen's grows downward.
        final x = (p.x - b.left) * scale, y = (b.top - p.y) * scale;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      if (s.points.length == 1) {
        final p = s.points.first;
        path.addOval(
          Rect.fromCircle(
            center: Offset((p.x - b.left) * scale, (b.top - p.y) * scale),
            radius: 1,
          ),
        );
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_InkPreview old) =>
      old.strokes != strokes || old.color != color;
}

/// Puts [panel] beside [page] (docked) or over it (floating, movable and
/// resizable) according to [place].
class TextPanelLayout extends StatefulWidget {
  const TextPanelLayout({
    super.key,
    required this.place,
    required this.page,
    required this.panel,
  });

  final TextPanelPlace place;
  final Widget page;
  final Widget panel;

  @override
  State<TextPanelLayout> createState() => _TextPanelLayoutState();
}

class _TextPanelLayoutState extends State<TextPanelLayout> {
  /// Floating window position and size, as fractions of the space.
  Offset _at = const Offset(0.55, 0.08);
  Size _size = const Size(0.4, 0.35);

  static const _dockShare = 0.3;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final divider = VerticalDivider(
        width: 1,
        color: Theme.of(context).dividerColor,
      );
      final hDivider = Divider(
        height: 1,
        color: Theme.of(context).dividerColor,
      );
      final side = SizedBox(width: w * _dockShare, child: widget.panel);
      final band = SizedBox(height: h * _dockShare, child: widget.panel);
      switch (widget.place) {
        case TextPanelPlace.off:
          return widget.page;
        case TextPanelPlace.right:
          return Row(
            children: [
              Expanded(child: widget.page),
              divider,
              side,
            ],
          );
        case TextPanelPlace.left:
          return Row(
            children: [
              side,
              divider,
              Expanded(child: widget.page),
            ],
          );
        case TextPanelPlace.top:
          return Column(
            children: [
              band,
              hDivider,
              Expanded(child: widget.page),
            ],
          );
        case TextPanelPlace.bottom:
          return Column(
            children: [
              Expanded(child: widget.page),
              hDivider,
              band,
            ],
          );
        case TextPanelPlace.floating:
          final pw = (_size.width * w).clamp(200.0, w);
          final ph = (_size.height * h).clamp(140.0, h);
          final left = (_at.dx * w).clamp(0.0, w - pw);
          final top = (_at.dy * h).clamp(0.0, h - ph);
          return Stack(
            children: [
              Positioned.fill(child: widget.page),
              Positioned(
                left: left,
                top: top,
                width: pw,
                height: ph,
                child: Material(
                  elevation: 6,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Positioned.fill(child: widget.panel),
                      // Drag the top strip to move the window.
                      Positioned(
                        left: 0,
                        right: 120,
                        top: 0,
                        height: 40,
                        child: Tooltip(
                          message: 'Drag to move the text window',
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onPanUpdate: (d) => setState(() {
                              _at = Offset(
                                ((left + d.delta.dx) / w).clamp(0.0, 1.0),
                                ((top + d.delta.dy) / h).clamp(0.0, 1.0),
                              );
                            }),
                          ),
                        ),
                      ),
                      // Drag the corner to resize it.
                      Positioned(
                        right: 0,
                        bottom: 0,
                        width: 32,
                        height: 32,
                        child: Tooltip(
                          message: 'Drag to resize the text window',
                          child: GestureDetector(
                            onPanUpdate: (d) => setState(() {
                              _size = Size(
                                ((pw + d.delta.dx) / w).clamp(0.2, 1.0),
                                ((ph + d.delta.dy) / h).clamp(0.15, 1.0),
                              );
                            }),
                            child: const Icon(Icons.open_in_full, size: 18),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
      }
    },
  );
}
