import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/ink.dart';

/// Holds the strokes on an [InkCanvas] and notifies listeners as they change.
class InkController extends ChangeNotifier {
  final List<InkStroke> _strokes = [];
  List<InkPoint>? _current;
  final List<InkPoint> _hover = [];

  /// At most this many hover points are kept (about 3 minutes of hovering).
  static const maxHoverPoints = 30000;

  /// Where the pen hovered without touching, oldest first.
  List<InkPoint> get hover => List.unmodifiable(_hover);

  /// Records a hover position. Doesn't repaint: hover isn't drawn.
  void addHover(InkPoint p) {
    if (_hover.length < maxHoverPoints) _hover.add(p);
  }

  /// Finished strokes, oldest first.
  List<InkStroke> get strokes => List.unmodifiable(_strokes);

  /// The stroke being drawn right now, if any.
  List<InkPoint>? get current => _current;

  bool get isEmpty => _strokes.isEmpty && _current == null;

  void startStroke(InkPoint p) {
    _current = [p];
    notifyListeners();
  }

  void addPoint(InkPoint p) {
    final c = _current;
    if (c == null) return;
    c.add(p);
    notifyListeners();
  }

  /// Finishes the current stroke and returns it (null if there wasn't one).
  InkStroke? endStroke() {
    final c = _current;
    _current = null;
    if (c == null || c.isEmpty) return null;
    final stroke = InkStroke(List.unmodifiable(c));
    _strokes.add(stroke);
    notifyListeners();
    return stroke;
  }

  /// Drops the stroke in progress (e.g. when a palm touch is detected).
  void cancelStroke() {
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  /// Removes every finished stroke that passes within [radius] of (x, y),
  /// measured to the lines between its points (fast strokes have widely
  /// spaced points). Returns true if anything was erased.
  bool eraseAt(double x, double y, {double radius = 12}) {
    final before = _strokes.length;
    _strokes.removeWhere((s) => _distanceTo(s.points, x, y) <= radius);
    if (_strokes.length == before) return false;
    notifyListeners();
    return true;
  }

  static double _distanceTo(List<InkPoint> pts, double x, double y) {
    var best = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = i + 1 < pts.length ? pts[i + 1] : a;
      final dx = b.x - a.x, dy = b.y - a.y;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0
          ? 0.0
          : (((x - a.x) * dx + (y - a.y) * dy) / len2).clamp(0.0, 1.0);
      final px = a.x + t * dx - x, py = a.y + t * dy - y;
      best = math.min(best, math.sqrt(px * px + py * py));
    }
    return best;
  }

  void undo() {
    if (_strokes.isEmpty) return;
    _strokes.removeLast();
    notifyListeners();
  }

  void clear() {
    _strokes.clear();
    _hover.clear();
    _current = null;
    notifyListeners();
  }
}
