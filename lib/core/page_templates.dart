/// Templates of your own (owner's idea 20, "with user-made templates"):
/// any page saved as a template, its paper and what's drawn or written on
/// it, to start new pages from. Pure Dart.
library;

import 'page_ink.dart';
import 'page_layout.dart' show Paper;

class PageTemplate {
  const PageTemplate({
    required this.name,
    required this.paper,
    required this.width,
    required this.height,
    this.lineGap,
    this.strokes = const [],
  });

  /// [strokes] from a page of [width] x [height] made into a template:
  /// drawn ink is kept, and never read as handwriting on the new pages.
  factory PageTemplate.fromPage({
    required String name,
    required Paper paper,
    required double width,
    required double height,
    double? lineGap,
    required List<PageStroke> strokes,
  }) => PageTemplate(
    name: name.trim(),
    paper: paper,
    width: width,
    height: height,
    lineGap: lineGap,
    strokes: [
      for (final s in strokes)
        if (s.points.isNotEmpty) s.isTextBox ? s : s.copyWith(notWriting: true),
    ],
  );

  final String name;
  final Paper paper;
  final double width, height;
  final double? lineGap;
  final List<PageStroke> strokes;

  /// The template's ink for a new page of [w] x [h] (stretched to fit),
  /// with times from [now] so it's in order with what's written after.
  List<PageStroke> strokesFor(double w, double h, {required int now}) {
    if (strokes.isEmpty || width <= 0 || height <= 0) return const [];
    final sx = w / width, sy = h / height;
    final first = strokes
        .map((s) => s.points.first.t)
        .reduce((a, b) => a < b ? a : b);
    return [
      for (final s in strokes)
        s.copyWith(
          points: [
            for (final p in s.points)
              PageInkPoint(p.x * sx, p.y * sy, now + (p.t - first), p.pressure),
          ],
          width: s.width * (sx + sy) / 2,
        ),
    ];
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'paper': paper.name,
    'w': width,
    'h': height,
    'gap': ?lineGap,
    'strokes': [for (final s in strokes) s.toJson()],
  };

  static PageTemplate? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final paper = Paper.values.where((p) => p.name == j['paper']).firstOrNull;
      final name = j['name'];
      if (paper == null || name is! String || name.trim().isEmpty) return null;
      return PageTemplate(
        name: name,
        paper: paper,
        width: (j['w']! as num).toDouble(),
        height: (j['h']! as num).toDouble(),
        lineGap: (j['gap'] as num?)?.toDouble(),
        strokes: [
          for (final s in (j['strokes'] as List?) ?? const [])
            PageStroke.fromJson((s as Map).cast<String, Object?>()),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

/// The user's templates, by name (a new one with the same name replaces
/// the old).
class TemplateLibrary {
  final _all = <String, PageTemplate>{};

  static const prefsKey = 'templates';

  List<PageTemplate> get templates =>
      _all.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  void add(PageTemplate t) {
    _all.removeWhere((k, _) => k.toLowerCase() == t.name.toLowerCase());
    _all[t.name] = t;
  }

  void remove(String name) => _all.remove(name);

  List<Object?> toJson() => [for (final t in templates) t.toJson()];

  void load(Object? j) {
    _all.clear();
    if (j is! List) return;
    for (final e in j) {
      final t = PageTemplate.fromJson(e);
      if (t != null) add(t);
    }
  }
}
