import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/ink.dart';
import '../core/ink_classifier.dart';
import '../core/page_ink.dart';
import '../core/stroke_grouping.dart';
import 'myscript_offline_recognizer.dart' show encodeStrokesFlat;

/// MyScript's own writing/drawing sorting ("Raw Content", task 2.2b), on
/// the tablet. Falls back to [fallback] (the shape check) whenever MyScript
/// can't answer (files missing from the build, an error), so recognition
/// always has an answer. No MyScript imports here: it talks to
/// MyScriptOffline.kt over the same channel as the recognizer.
class MyScriptInkClassifier implements InkClassifier, ExplainsFallback {
  MyScriptInkClassifier({
    this.fallback = const ShapeInkClassifier(),
    MethodChannel? channel,
  }) : channel =
           channel ??
           const MethodChannel('writing_recogniser/myscript_offline');

  final InkClassifier fallback;
  final MethodChannel channel;

  /// Why MyScript isn't sorting (so the shape check is used), if so.
  @override
  String? problem;

  @override
  Future<List<InkKind>> classify(List<PageStroke> strokes) async {
    if (strokes.isEmpty) return const [];
    try {
      final ink = pageInkForEngine(strokes);
      final jiix = await channel.invokeMethod<String>('classify', {
        'strokes': encodeStrokesFlat(ink),
      });
      final kinds = jiix == null ? null : kindsFromJiix(jiix, ink);
      if (kinds != null) {
        problem = null;
        return kinds;
      }
      problem =
          "MyScript's answer couldn't be read (${jiix == null ? 'none' : describeJiix(jiix)})";
    } on PlatformException catch (e) {
      problem = e.message ?? e.code;
    } on MissingPluginException {
      problem = 'MyScript is not in this build';
    }
    return fallback.classify(strokes);
  }
}

/// A whole page's strokes for an engine: the right way up (y down) and
/// about screen size (typical letter about 50 px).
List<InkStroke> pageInkForEngine(List<PageStroke> strokes) {
  final boxes = [
    for (final s in strokes)
      if (s.points.isNotEmpty) InkBox.of(s),
  ];
  final scale = 50 / typicalLetterHeight(boxes);
  var top = -double.infinity, left = double.infinity;
  for (final b in boxes) {
    if (b.top > top) top = b.top;
    if (b.left < left) left = b.left;
  }
  // Points under half a unit apart (a letter is about 50) add nothing for
  // sorting: since every pen sample is kept there are many (the first and
  // last of each stroke always stay).
  const gap = 0.5;
  return [
    for (final s in strokes)
      () {
        final out = <InkPoint>[];
        final pts = s.points;
        for (var i = 0; i < pts.length; i++) {
          final p = pts[i];
          final x = (p.x - left) * scale, y = (top - p.y) * scale;
          if (out.isNotEmpty && i < pts.length - 1) {
            final dx = x - out.last.x, dy = y - out.last.y;
            if (dx * dx + dy * dy < gap * gap) continue;
          }
          out.add(InkPoint(x, y, p.t, p.pressure));
        }
        return InkStroke(out);
      }(),
  ];
}

/// Reads MyScript's Raw Content answer: each element is text or a drawing,
/// with a bounding box in MyScript's own units (millimetres). Strokes are
/// matched to elements by where they sit relative to the whole page of
/// ink, so the units don't matter. Null if the answer can't be used.
List<InkKind>? kindsFromJiix(String jiix, List<InkStroke> ink) {
  Object? root;
  try {
    root = jsonDecode(jiix);
  } on FormatException {
    return null;
  }
  if (root is! Map) return null;
  final elements = <({InkKind kind, double x, double y, double w, double h})>[];
  void walk(Object? node) {
    if (node is Map) {
      final type = '${node['type'] ?? ''}'.toLowerCase();
      final box = node['bounding-box'];
      if (box is Map && type.isNotEmpty && type != 'raw content') {
        num n(String k) => box[k] is num ? box[k] as num : 0;
        elements.add((
          kind: type.contains('text') ? InkKind.writing : InkKind.drawing,
          x: n('x').toDouble(),
          y: n('y').toDouble(),
          w: n('width').toDouble(),
          h: n('height').toDouble(),
        ));
        return; // a text block's words are inside it: no need to go deeper
      }
      for (final v in node.values) {
        walk(v);
      }
    } else if (node is List) {
      for (final v in node) {
        walk(v);
      }
    }
  }

  walk(root);
  if (elements.isEmpty) return null;

  // The extent of the elements and of our ink, to compare positions.
  double minOf(Iterable<double> v) => v.reduce((a, b) => a < b ? a : b);
  double maxOf(Iterable<double> v) => v.reduce((a, b) => a > b ? a : b);
  final ex0 = minOf(elements.map((e) => e.x));
  final ey0 = minOf(elements.map((e) => e.y));
  final ex1 = maxOf(elements.map((e) => e.x + e.w));
  final ey1 = maxOf(elements.map((e) => e.y + e.h));
  final pts = [for (final s in ink) ...s.points];
  if (pts.isEmpty) return null;
  final ix0 = minOf(pts.map((p) => p.x)), ix1 = maxOf(pts.map((p) => p.x));
  final iy0 = minOf(pts.map((p) => p.y)), iy1 = maxOf(pts.map((p) => p.y));
  double fx(double x, double a, double b) => b - a <= 0 ? 0 : (x - a) / (b - a);

  return [
    for (final s in ink)
      () {
        // Vote: which element holds most of this stroke's points.
        final votes = <InkKind, int>{};
        for (final p in s.points) {
          final px = fx(p.x, ix0, ix1), py = fx(p.y, iy0, iy1);
          for (final e in elements) {
            final x0 = fx(e.x, ex0, ex1), x1 = fx(e.x + e.w, ex0, ex1);
            final y0 = fx(e.y, ey0, ey1), y1 = fx(e.y + e.h, ey0, ey1);
            const m = 0.02; // allow for rounding at the edges
            if (px >= x0 - m && px <= x1 + m && py >= y0 - m && py <= y1 + m) {
              votes[e.kind] = (votes[e.kind] ?? 0) + 1;
            }
          }
        }
        // Unsure (no element, or a tie): writing, so nothing is dropped.
        final d = votes[InkKind.drawing] ?? 0, w = votes[InkKind.writing] ?? 0;
        return d > w ? InkKind.drawing : InkKind.writing;
      }(),
  ];
}

/// What an answer looks like, for the diagnostics when it can't be used:
/// its size, its field names and how many elements of each type it has.
/// Never its words or positions.
String describeJiix(String jiix) {
  Object? root;
  try {
    root = jsonDecode(jiix);
  } on FormatException {
    return 'not JSON, ${jiix.length} chars';
  }
  if (root is! Map) return 'not an object, ${jiix.length} chars';
  final types = <String, int>{};
  var boxes = 0;
  void walk(Object? node, int depth) {
    if (depth > 12) return;
    if (node is Map) {
      final t = node['type'];
      if (t is String && t.length <= 30) types[t] = (types[t] ?? 0) + 1;
      if (node['bounding-box'] is Map) boxes++;
      for (final v in node.values) {
        walk(v, depth + 1);
      }
    } else if (node is List) {
      for (final v in node) {
        walk(v, depth + 1);
      }
    }
  }

  walk(root, 0);
  final keys = [
    for (final k in root.keys)
      if ('$k'.length <= 30) '$k',
  ]..sort();
  final kinds = [for (final e in types.entries) '${e.key} ${e.value}'];
  return '${jiix.length} chars; boxes: $boxes; '
      'types: ${kinds.take(6).join(', ')}; fields: ${keys.take(8).join(', ')}';
}
