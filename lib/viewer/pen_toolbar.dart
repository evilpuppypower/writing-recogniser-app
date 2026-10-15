import 'package:flutter/material.dart';

import '../core/page_ink.dart';
import '../core/pen_tools.dart';
import 'pen_tools_controller.dart';

/// The fixed pen toolbar (owner: like common note apps). Docks at the top or on
/// either side (chosen in Settings); every button has a tooltip.
class PenToolbar extends StatelessWidget {
  const PenToolbar({super.key, required this.controller});

  final PenToolsController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, tools, _) {
        final vertical = tools.dock != ToolbarDock.top;
        void select(PenMode mode) {
          if (tools.mode == mode) {
            // Tapping the selected tool again opens its settings.
            if (mode == PenMode.lasso || mode == PenMode.text) return;
            if (mode == PenMode.eraser) {
              showEraserSettings(context, controller);
            } else {
              showPenSettings(context, controller);
            }
          } else {
            controller.update(tools.copyWith(mode: mode));
          }
        }

        // Pen and highlighter icons are drawn in their current colour.
        Widget tool(PenMode mode, IconData icon, String tip, [PenStyle? s]) =>
            IconButton(
              tooltip: tools.mode != mode
                  ? (s == null ? tip : '${describePen(s)}. Tap to use')
                  : mode == PenMode.lasso || mode == PenMode.text
                  ? tip
                  : mode == PenMode.eraser
                  ? '$tip (tap again for eraser options)'
                  : '${s == null ? tip : describePen(s)} '
                        '(tap again for colour and size)',
              isSelected: tools.mode == mode,
              style: IconButton.styleFrom(
                backgroundColor: tools.mode == mode
                    ? scheme.secondaryContainer
                    : null,
              ),
              icon: s == null ? Icon(icon) : _ColouredIcon(icon, s),
              onPressed: () => select(mode),
            );

        final current = tools.current;
        final children = <Widget>[
          tool(PenMode.pen, Icons.edit, 'Pen', tools.pen),
          tool(
            PenMode.highlighter,
            Icons.border_color,
            'Highlighter',
            tools.highlighter,
          ),
          tool(PenMode.eraser, Icons.auto_fix_normal, 'Eraser'),
          tool(
            PenMode.lasso,
            Icons.highlight_alt,
            'Select handwriting to convert to typed text: draw a loop '
            'around it',
          ),
          tool(
            PenMode.text,
            Icons.text_fields,
            'Text box: tap the page to type, or tap a text box to edit it',
          ),
          const SizedBox(width: 8, height: 8),
          IconButton(
            tooltip: tools.mode != PenMode.pen
                ? 'Arrowheads (choose the Pen first)'
                : tools.pen.arrow
                ? 'Arrowheads on: pen strokes end with an arrow. Tap to turn off'
                : 'Add an arrowhead to the end of pen strokes',
            isSelected: tools.mode == PenMode.pen && tools.pen.arrow,
            style: IconButton.styleFrom(
              backgroundColor: tools.mode == PenMode.pen && tools.pen.arrow
                  ? scheme.secondaryContainer
                  : null,
            ),
            onPressed: tools.mode != PenMode.pen
                ? null
                : () => controller.update(
                    tools.withCurrent(
                      tools.pen.copyWith(arrow: !tools.pen.arrow),
                    ),
                  ),
            icon: const Icon(Icons.arrow_right_alt),
          ),
          IconButton(
            tooltip: current != null && tools.isFavourite(current)
                ? 'Already in favourites (long-press a favourite to remove it)'
                : 'Pin this pen to the favourites bar',
            onPressed: current == null || tools.isFavourite(current)
                ? null
                : () => controller.update(tools.pin(current)),
            icon: Icon(
              current != null && tools.isFavourite(current)
                  ? Icons.push_pin
                  : Icons.push_pin_outlined,
            ),
          ),
        ];
        return Material(
          color: scheme.surfaceContainer,
          elevation: 1,
          child: SafeArea(
            top: false,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: vertical
                  ? SingleChildScrollView(child: Column(children: children))
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: children),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// A tool icon filled with the pen's colour, with a thin outline so pale
/// colours (e.g. yellow highlighter) still show on a light toolbar.
class _ColouredIcon extends StatelessWidget {
  const _ColouredIcon(this.icon, this.style);

  final IconData icon;
  final PenStyle style;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Icon(
      icon,
      color: Color(style.colorArgb),
      shadows: [
        for (final (dx, dy) in const [
          (0.6, 0.0),
          (-0.6, 0.0),
          (0.0, 0.6),
          (0.0, -0.6),
        ])
          Shadow(color: outline, offset: Offset(dx, dy)),
      ],
    );
  }
}

/// A round colour dot (pen) or a rounded bar (highlighter).
class _PenDot extends StatelessWidget {
  const _PenDot({required this.style, this.size = 20, this.ring = false});

  final PenStyle style;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlighter = style.tool == InkTool.highlighter;
    return Container(
      width: size,
      height: highlighter ? size * 0.6 : size,
      decoration: BoxDecoration(
        color: Color(style.colorArgb),
        borderRadius: BorderRadius.circular(highlighter ? 3 : size),
        border: Border.all(
          color: ring ? scheme.primary : scheme.outline,
          width: ring ? 3 : 1,
        ),
      ),
    );
  }
}

/// Plain-language name of a colour, for tooltips.
String colourName(int argb) => _colourNames[argb] ?? 'colour';

const _colourNames = {
  0xFF1A1A1A: 'black',
  0xFF5F6368: 'grey',
  0xFF1565C0: 'blue',
  0xFF0097A7: 'teal',
  0xFF2E7D32: 'green',
  0xFFC62828: 'red',
  0xFFEF6C00: 'orange',
  0xFF6A1B9A: 'purple',
  0xFFFFEB3B: 'yellow',
  0xFF76FF03: 'green',
  0xFF40C4FF: 'blue',
  0xFFFF80AB: 'pink',
  0xFFFFAB40: 'orange',
};

/// Plain-language name of a pen, for tooltips.
String describePen(PenStyle s) {
  final colours = _colourNames;
  final tool = s.tool == InkTool.pen ? 'Pen' : 'Highlighter';
  return '$tool, ${colours[s.colorArgb] ?? 'custom colour'}, '
      '${s.width.toStringAsFixed(1)} pt${s.arrow ? ', arrow' : ''}';
}

/// Colour and size for the current pen or highlighter.
Future<void> showPenSettings(
  BuildContext context,
  PenToolsController controller,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, tools, _) {
      final style = tools.current;
      if (style == null) return const SizedBox(height: 80);
      final colours = style.tool == InkTool.pen
          ? penColours
          : highlighterColours;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                style.tool == InkTool.pen ? 'Pen' : 'Highlighter',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final c in colours)
                    Tooltip(
                      message: describePen(style.copyWith(colorArgb: c)),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => controller.update(
                          tools.withCurrent(style.copyWith(colorArgb: c)),
                        ),
                        child: _PenDot(
                          style: style.copyWith(colorArgb: c),
                          size: 36,
                          ring: c == style.colorArgb,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Thickness: ${style.width.toStringAsFixed(1)} pt'),
              Slider(
                value: style.width,
                min: style.minWidth,
                max: style.maxWidth,
                divisions: ((style.maxWidth - style.minWidth) * 10).round(),
                label: '${style.width.toStringAsFixed(1)} pt',
                onChanged: (w) => controller.update(
                  tools.withCurrent(style.copyWith(width: w)),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.push_pin_outlined),
                  label: Text(
                    tools.isFavourite(style)
                        ? 'In favourites'
                        : 'Pin to favourites',
                  ),
                  onPressed: tools.isFavourite(style)
                      ? null
                      : () => controller.update(tools.pin(style)),
                ),
              ),
            ],
          ),
        ),
      );
    },
  ),
);

/// Eraser options: whole strokes or only where it rubs, and its size. They
/// also apply to the pen side button.
Future<void> showEraserSettings(
  BuildContext context,
  PenToolsController controller,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, tools, _) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Eraser', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            const Text('Also used when you hold the pen button.'),
            const SizedBox(height: 12),
            RadioGroup<EraserKind>(
              groupValue: tools.eraser,
              onChanged: (kind) {
                if (kind != null) {
                  controller.update(tools.copyWith(eraser: kind));
                }
              },
              child: Column(
                children: [
                  for (final kind in EraserKind.values)
                    RadioListTile<EraserKind>(
                      value: kind,
                      title: Text(kind.label),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            Text('Eraser size: ${tools.eraserSize.round()}'),
            Slider(
              value: tools.eraserSize,
              min: PenToolsState.minEraserSize,
              max: PenToolsState.maxEraserSize,
              divisions:
                  (PenToolsState.maxEraserSize - PenToolsState.minEraserSize)
                      .round(),
              label: '${tools.eraserSize.round()}',
              onChanged: (v) =>
                  controller.update(tools.copyWith(eraserSize: v)),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// Floating bar of pinned pens (owner: like note-app favourites).
/// Drag its handle to move it; tap a pen to use it; long-press to unpin.
class FavouritesBar extends StatelessWidget {
  const FavouritesBar({super.key, required this.controller});

  final PenToolsController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) => ValueListenableBuilder(
        valueListenable: controller,
        builder: (context, tools, _) {
          if (tools.favourites.isEmpty) return const SizedBox.shrink();
          const barHeight = 52.0;
          final barWidth = 44.0 + tools.favourites.length * 44.0;
          final left = (box.maxWidth - barWidth) * tools.favouritesX;
          final top = (box.maxHeight - barHeight) * tools.favouritesY;
          return Stack(
            children: [
              Positioned(
                left: left.clamp(0, double.infinity),
                top: top.clamp(0, double.infinity),
                child: Material(
                  elevation: 4,
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(26),
                  child: SizedBox(
                    height: barHeight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Tooltip(
                          message: 'Drag to move the favourites bar',
                          child: GestureDetector(
                            onPanUpdate: (d) {
                              // Start from the latest position, not the one
                              // at the last redraw: the pen reports moves
                              // faster than the screen redraws, and adding
                              // each move to an old position lost most of
                              // the drag.
                              final now = controller.value;
                              final spareX = box.maxWidth - barWidth;
                              final spareY = box.maxHeight - barHeight;
                              controller.update(
                                now.copyWith(
                                  favouritesX: spareX <= 0
                                      ? 0
                                      : ((spareX * now.favouritesX +
                                                    d.delta.dx) /
                                                spareX)
                                            .clamp(0.0, 1.0),
                                  favouritesY: spareY <= 0
                                      ? 0
                                      : ((spareY * now.favouritesY +
                                                    d.delta.dy) /
                                                spareY)
                                            .clamp(0.0, 1.0),
                                ),
                              );
                            },
                            child: const SizedBox(
                              width: 36,
                              height: barHeight,
                              child: Icon(Icons.drag_indicator),
                            ),
                          ),
                        ),
                        for (final f in tools.favourites)
                          Tooltip(
                            message:
                                '${describePen(f)}. Tap to use, '
                                'long-press to unpin.',
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () =>
                                  controller.update(tools.withCurrent(f)),
                              onLongPress: () =>
                                  controller.update(tools.unpin(f)),
                              child: SizedBox(
                                width: 44,
                                height: barHeight,
                                child: Center(
                                  child: _PenDot(
                                    style: f,
                                    size: 26,
                                    ring: tools.current == f,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
