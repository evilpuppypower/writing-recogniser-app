import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/pressure_response.dart';
import '../core/ink.dart';
import 'ink_controller.dart';

/// A writing surface that records pen strokes with time and pressure.
///
/// Only the stylus writes (owner decision): fingers and palms are ignored,
/// so a hand can rest on the screen. Holding the pen's side button, or
/// using the pen's eraser end, erases whole strokes.
class InkCanvas extends StatefulWidget {
  const InkCanvas({
    super.key,
    required this.controller,
    this.onPenDown,
    this.onStrokeEnd,
    this.onErase,
    this.lineSpacing = 64,
    this.pressure = const PressureResponse(),
  });

  final InkController controller;

  /// Called when a stroke starts (e.g. to cancel a pending recognition).
  final VoidCallback? onPenDown;

  /// Called with each finished stroke.
  final ValueChanged<InkStroke>? onStrokeEnd;

  /// Called when strokes were erased.
  final VoidCallback? onErase;

  /// Distance between the faint guide lines.
  final double lineSpacing;

  /// How pressure changes the line thickness (from Settings). Only the
  /// drawing changes; the recorded pressure is always kept.
  final PressureResponse pressure;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> {
  int? _activePointer;
  bool _erasing = false;

  /// Converts event timestamps (time since boot) to wall-clock ms.
  int? _clockOffsetMs;

  int _timeOf(PointerEvent e) {
    _clockOffsetMs ??=
        DateTime.now().millisecondsSinceEpoch - e.timeStamp.inMilliseconds;
    return _clockOffsetMs! + e.timeStamp.inMilliseconds;
  }

  static double _pressureOf(PointerEvent e) {
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 0.5;
    return ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
  }

  InkPoint _pointOf(PointerEvent e) => InkPoint(
    e.localPosition.dx,
    e.localPosition.dy,
    _timeOf(e),
    _pressureOf(e),
  );

  bool _isPen(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  /// Side button held, or the pen turned round to its eraser end. Android
  /// reports the pen's side button as the stylus "primary" button, other
  /// pens may use the secondary one; either erases.
  bool _isEraser(PointerEvent e) =>
      e.kind == PointerDeviceKind.invertedStylus ||
      e.buttons & (kPrimaryStylusButton | kSecondaryStylusButton) != 0;

  void _down(PointerDownEvent e) {
    if (!_isPen(e) || _activePointer != null) return; // finger, palm, 2nd pen
    _activePointer = e.pointer;
    _erasing = _isEraser(e);
    widget.onPenDown?.call();
    if (_erasing) {
      _erase(e);
    } else {
      widget.controller.startStroke(_pointOf(e));
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    if (!_erasing && _isEraser(e)) {
      // Button pressed mid-stroke: drop the part drawn so far, erase instead.
      widget.controller.cancelStroke();
      _erasing = true;
    }
    if (_erasing) {
      _erase(e);
    } else {
      widget.controller.addPoint(_pointOf(e));
    }
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    if (_erasing) {
      _erasing = false;
      return;
    }
    widget.controller.addPoint(_pointOf(e));
    final stroke = widget.controller.endStroke();
    if (stroke != null) widget.onStrokeEnd?.call(stroke);
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    _erasing = false;
    widget.controller.cancelStroke();
  }

  /// The pen reports where it is while hovering just above the screen.
  void _hover(PointerHoverEvent e) {
    if (!_isPen(e) || _activePointer != null) return;
    final p = _pointOf(e);
    widget.controller.addHover(InkPoint(p.x, p.y, p.t, 0));
  }

  void _erase(PointerEvent e) {
    if (widget.controller.eraseAt(e.localPosition.dx, e.localPosition.dy)) {
      widget.onErase?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      onPointerHover: _hover,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _InkPainter(
            widget.controller,
            ink: scheme.onSurface,
            guide: scheme.outlineVariant,
            lineSpacing: widget.lineSpacing,
            pressure: widget.pressure,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _InkPainter extends CustomPainter {
  _InkPainter(
    this.controller, {
    required this.ink,
    required this.guide,
    required this.lineSpacing,
    required this.pressure,
  }) : super(repaint: controller);

  final InkController controller;
  final Color ink;
  final Color guide;
  final double lineSpacing;
  final PressureResponse pressure;

  @override
  void paint(Canvas canvas, Size size) {
    final guidePaint = Paint()
      ..color = guide
      ..strokeWidth = 1;
    for (var y = lineSpacing; y < size.height; y += lineSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guidePaint);
    }
    final paint = Paint()
      ..color = ink
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final s in controller.strokes) {
      _drawStroke(canvas, s.points, paint);
    }
    final current = controller.current;
    if (current != null) _drawStroke(canvas, current, paint);
  }

  void _drawStroke(Canvas canvas, List<InkPoint> points, Paint paint) {
    if (points.length == 1) {
      final p = points.first;
      canvas.drawCircle(
        Offset(p.x, p.y),
        _width(p.pressure) / 2,
        paint..style = PaintingStyle.fill,
      );
      paint.style = PaintingStyle.stroke;
      return;
    }
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      paint.strokeWidth = _width((a.pressure + b.pressure) / 2);
      canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), paint);
    }
  }

  /// 3 px at normal pressure, changing with pressure as set in Settings
  /// (by default 1.8 to 4.2 px, like the PDF pen).
  double _width(double p) => 3 * pressure.factor(p);

  @override
  bool shouldRepaint(_InkPainter old) =>
      old.ink != ink ||
      old.guide != guide ||
      old.lineSpacing != lineSpacing ||
      old.pressure != pressure;
}
