import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/pen_tools.dart';
import '../core/writing_box.dart';
import 'page_ink_layer.dart' show PageInkPreview;

/// The writing box's strip (see WritingBoxTarget): part of [page] shown
/// large, with its ink; the pen writes here and each stroke goes to
/// [onStroke] in PDF page coordinates.
class WritingBoxPanel extends StatefulWidget {
  const WritingBoxPanel({
    super.key,
    required this.document,
    required this.page,
    required this.geometry,
    required this.ink,
    required this.target,
    required this.style,
    required this.onStroke,
    required this.onMove,
    required this.onClose,
    this.decorate,
    this.dark = false,
  });

  final PdfDocument document;
  final PdfPage page;
  final PageGeometry geometry;
  final List<PageStroke> ink;
  final WritingBoxTarget target;

  /// The pen to write with (null: the tool in use can't write here).
  final PenStyle? style;
  final void Function(PageStroke stroke, double rightShare) onStroke;
  final void Function(WritingBoxTarget target) onMove;
  final VoidCallback onClose;

  /// Puts something over the page, under the ink (its paper).
  final Widget Function(Widget page)? decorate;
  final bool dark;

  @override
  State<WritingBoxPanel> createState() => _WritingBoxPanelState();
}

const _night = ColorFilter.matrix([
  -0.875, 0, 0, 0, 255, //
  0, -0.875, 0, 0, 255, //
  0, 0, -0.875, 0, 255, //
  0, 0, 0, 1, 0,
]);

class _WritingBoxPanelState extends State<WritingBoxPanel> {
  final _points = ValueNotifier<List<Offset>>(const []);
  final _pressures = <double>[];
  final _times = <int>[];
  int? _pointer;

  @override
  void dispose() {
    _points.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh,
      child: LayoutBuilder(
        builder: (context, box) {
          final g = widget.geometry;
          final t = widget.target;
          final w = box.maxWidth, h = box.maxHeight - 48;
          if (w <= 0 || h <= 0) return const SizedBox.shrink();
          // The whole page as large as the box shows it.
          final pageW = w / t.width;
          final pageH = pageW * g.displayHeight / g.displayWidth;
          final dx = -t.left * pageW, dy = -t.top * pageH;
          final height = t.heightFor(h / w, g.displayHeight / g.displayWidth);
          Widget pdf = PdfPageView(
            document: widget.document,
            pageNumber: widget.page.pageNumber,
            decoration: const BoxDecoration(color: Colors.white),
          );
          // Dark like the page behind (see PageThumbnail).
          if (widget.dark) {
            pdf = ColorFiltered(colorFilter: _night, child: pdf);
          }
          if (widget.decorate != null) pdf = widget.decorate!(pdf);
          return Column(
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.style == null
                            ? 'Choose the pen or highlighter to write here'
                            : 'Writing box: page ${t.page}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Move the box back',
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => widget.onMove(t.back()),
                    ),
                    IconButton(
                      tooltip: 'Move the box along',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => widget.onMove(t.next(height: height)),
                    ),
                    IconButton(
                      tooltip: 'Next line',
                      icon: const Icon(Icons.keyboard_return),
                      onPressed: () => widget.onMove(t.newLine(height: height)),
                    ),
                    IconButton(
                      tooltip: 'Move the box up',
                      icon: const Icon(Icons.keyboard_arrow_up),
                      onPressed: () =>
                          widget.onMove(t.copyWith(top: t.top - height / 2)),
                    ),
                    IconButton(
                      tooltip: 'Move the box down',
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: () =>
                          widget.onMove(t.copyWith(top: t.top + height / 2)),
                    ),
                    IconButton(
                      tooltip: 'Close the writing box',
                      icon: const Icon(Icons.close),
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: w,
                height: h,
                child: ClipRect(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) => _down(e),
                    onPointerMove: (e) => _move(e),
                    onPointerUp: (e) => _up(e, w, pageW, dx, dy),
                    onPointerCancel: (_) => _cancel(),
                    child: Stack(
                      children: [
                        Positioned(
                          left: dx,
                          top: dy,
                          width: pageW,
                          height: pageH,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              pdf,
                              PageInkPreview(
                                strokes: widget.ink,
                                geometry: g,
                                dark: widget.dark,
                              ),
                            ],
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ValueListenableBuilder(
                              valueListenable: _points,
                              builder: (_, pts, _) => CustomPaint(
                                painter: _Writing(
                                  pts,
                                  widget.style,
                                  pageW / g.displayWidth,
                                ),
                              ),
                            ),
                          ),
                        ),
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

  bool _isPen(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus && widget.style != null;

  void _down(PointerDownEvent e) {
    if (!_isPen(e) || _pointer != null) return;
    _pointer = e.pointer;
    _pressures
      ..clear()
      ..add(_pressure(e));
    _times
      ..clear()
      ..add(DateTime.now().millisecondsSinceEpoch);
    _points.value = [e.localPosition];
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _pressures.add(_pressure(e));
    _times.add(DateTime.now().millisecondsSinceEpoch);
    _points.value = [..._points.value, e.localPosition];
  }

  void _up(PointerUpEvent e, double w, double pageW, double dx, double dy) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final pts = _points.value;
    _points.value = const [];
    final style = widget.style;
    if (pts.isEmpty || style == null) return;
    final g = widget.geometry;
    final points = [
      for (var i = 0; i < pts.length; i++)
        () {
          final p = g.toPdf(ViewPoint(pts[i].dx - dx, pts[i].dy - dy), pageW);
          return PageInkPoint(p.x, p.y, _times[i], _pressures[i]);
        }(),
    ];
    var right = 0.0;
    for (final p in pts) {
      if (p.dx > right) right = p.dx;
    }
    widget.onStroke(
      PageStroke(
        points: points,
        colorArgb: style.colorArgb,
        width: style.width,
        tool: style.tool,
      ),
      (right / w).clamp(0.0, 1.0),
    );
  }

  void _cancel() {
    _pointer = null;
    _points.value = const [];
  }

  static double _pressure(PointerEvent e) {
    final range = e.pressureMax - e.pressureMin;
    return range <= 0
        ? 0.5
        : ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0).toDouble();
  }
}

class _Writing extends CustomPainter {
  _Writing(this.points, this.style, this.scale);

  final List<Offset> points;
  final PenStyle? style;

  /// Screen pixels per PDF point in the box.
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = style;
    if (points.isEmpty || s == null) return;
    final paint = Paint()
      ..color = Color(s.colorArgb)
      ..strokeWidth = s.width * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (points.length == 1) {
      canvas.drawCircle(points.first, s.width * scale / 2, paint);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_Writing old) =>
      old.points != points || old.style != style || old.scale != scale;
}
